import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

/// The app's one lease on the fans: it asks for them, keeps proving it is alive, gives them back,
/// and says so when it can no longer show it holds them (`CLAUDE.md` rules 2 and 6, #155).
///
/// **Nothing constructs one yet.** This is the logic and its tests; the wiring into `AeolusApp`
/// lands with the first control, so nothing in the shipping app can acquire a lease through it.
///
/// ## States
///
///     idle ──hold──▶ acquiring ──granted──▶ held(applying ⇄ confirmed)
///                      │                      │                 │
///                      │ refusal              │ release, Auto   │ renewal, apply,
///                      ▼                      ▼                 │ snapshot, health
///                    refused              releasing             ▼
///                                             │               lost
///                                             ▼
///                                         released
///
/// `refused`, `lost` and `released` wait for the user: `hold(_:)` from any of them starts a new
/// acquisition, and nothing else does.
///
/// ## Renewal
///
/// Every `timeToLive / 3` of the TTL asked for, which is the TTL the helper grants (it stores the
/// request's), so two missed beats are tolerated before the helper lets go (`docs/SAFETY.md` § 1).
/// The schedule starts at the instant taken **before `acquireLease` is sent**, which cannot be
/// later than the grant the helper's TTL starts from, and each renewal is stamped before it is
/// sent, so a slow answer never makes the next one late. The heartbeat starts when the grant
/// arrives, before the first `apply` is sent, and runs **during** it: an `apply` may take 57 s for
/// one fan, and the helper's thirty seconds started at the grant. `renewLease` is not sequenced at
/// the helper, so a renewal is not queued behind the `apply`.
///
/// ## Loss is final
///
/// Each of these ends the lease as `lost`: a renewal refused or unanswered; an `apply` refused or
/// unanswered; the control connection leaving `.handshaken`; and a snapshot for which
/// `SystemSnapshot.controlLoss(leaseID:covering:)` is non-nil. After `lost` the driver sends one
/// release for the lease, because giving fans back is never wrong and it cannot tell from here
/// whether the helper still has them, and then it never renews and never acquires on its own.
///
/// **Wake** is the same: `systemDidWake()` brings the next renewal forward so a lease that did not
/// survive the sleep is reported at once, and it never asks for the fans again. `docs/SAFETY.md`
/// § 4 leaves that to the maintainer, and never is the default (#153).
///
/// ## One `apply` in flight, latest wins
///
/// A new target over the same fans is a re-`apply` under the same lease. While one is in flight a
/// newer target replaces any queued one and nothing is sent concurrently: level 6 admits one
/// `apply` at a time and refuses a second rather than queueing it. A change to **which** fans are
/// held is a release, then an acquire, then an apply.
///
/// ## Auto is a release
///
/// The helper refuses `.automatic` inside `apply`, so Auto is `releaseLease`, sent at once even
/// with an `apply` in flight: it is not sequenced behind it. The `apply` is left to answer; its
/// answer is then ignored.
///
/// ## Release
///
/// One idempotent call with a bounded wait. A second caller joins the release in flight rather
/// than sending another, and every caller is let go within `releaseBound` whether or not the
/// helper answers. `shutDown()` releases first and only then tears the connection down, so a quit
/// never relies on the helper's invalidation path alone.
///
/// ## A snapshot is judged only after what it could show
///
/// Snapshots come from the read connection, and nothing between two connections is ordered. One
/// requested before the grant, or before the first `apply` was answered, can arrive after it and
/// show the fans not yet held, and judging it would end a lease that was fine, for good. So a
/// reader takes a `SnapshotTicket` from `beginSnapshotRead()` immediately before it sends
/// `snapshot`, and `observe(_:readWith:)` judges only snapshots whose ticket was taken after this
/// lease's first `apply` was answered. The driver mints the ticket, so a caller cannot forge one;
/// it can still take one at the wrong moment, which only the wiring can get right.
///
/// ## It never cancels a sequenced verb (#419)
///
/// `acquireLease` and `apply` are left to answer, whatever happens meanwhile, and an answer that
/// arrives for a lease no longer held is ignored. A cancelled sequenced message stays in flight
/// at the helper with its deadline running, and every sequenced message behind it waits for it;
/// a driver that cancelled and re-sent would pile those up. Only renewals, which are not
/// sequenced, are ever cancelled.
public actor LeaseDriver {

    /// How long a release waits for the helper's answer before its caller is let go.
    ///
    /// **Two seconds, stated rather than measured.** It bounds how long a quit or a logout waits,
    /// and losing nothing past it is what makes it safe to keep short: the release was already
    /// sent, and the quit that follows tears the connection down, which the helper treats as a
    /// release in its own right. Shorter than `HelperClientDeadlines.gatedVerb`, so it is this
    /// bound, not the client's, that lets a quit go.
    public static let releaseBound: Duration = .seconds(2)

    /// What the app calls itself in a lease: `Aeolus.app` and its `CFBundleShortVersionString`.
    public static func holderDescription(shortVersion: String?) -> String {
        guard let shortVersion, !shortVersion.isEmpty else { return "Aeolus.app" }
        return "Aeolus.app \(shortVersion)"
    }

    /// The grant the driver holds: the lease, its fans, and the schedule it is renewed on.
    private struct Grant {
        let lease: Lease
        let fans: [Int]
        let interval: Duration
        /// The ticket epoch from which a snapshot is evidence about this lease's fans: set when the
        /// first `apply` under it is answered with success, `nil` until then.
        var judgedFrom: UInt64?
    }

    /// An acquisition in flight.
    private struct Acquisition {
        let id: UInt64
        /// The latest target asked for while the request is in flight.
        var target: LeaseTarget
        /// Whether a release was asked for while the request was in flight.
        var releaseOnArrival = false
    }

    private let control: any HelperLeaseControlling
    private let clock: any HeartbeatClock
    private let holder: String
    private let releaseBound: Duration

    private var current: LeaseDriverState = .idle
    private var observers: [UUID: AsyncStream<LeaseDriverState>.Continuation] = [:]

    private var acquisition: Acquisition?
    private var acquiring: Task<Lease?, Never>?
    private var acquisitions: UInt64 = 0
    private var grant: Grant?
    private var heartbeat: Task<Void, Never>?
    private var healthWatch: Task<Void, Never>?
    /// The release in flight, of whichever lease: a user's, a quit's, or the one sent after a loss.
    /// `lease` is `nil` for a release asked for while the lease was still being acquired.
    private var pendingRelease: (id: UInt64, lease: Lease?, task: Task<ReleaseOutcome, Never>)?
    private var releases: UInt64 = 0
    /// What to acquire once the release in flight has answered: a change of fans, or a target
    /// asked for while releasing.
    private var wanted: LeaseTarget?
    private var epoch: UInt64 = 0
    private var wokeSinceRenewal = false
    private var shuttingDown = false

    /// - Parameters:
    ///   - control: The app's control connection.
    ///   - holderDescription: `holderDescription(shortVersion:)` of the app's bundle.
    ///   - clock: What the heartbeat and the release bound are measured on.
    ///   - releaseBound: How long a release waits for an answer.
    public init(
        control: any HelperLeaseControlling,
        holderDescription: String,
        clock: any HeartbeatClock = SystemHeartbeatClock(),
        releaseBound: Duration = LeaseDriver.releaseBound
    ) {
        self.control = control
        self.holder = holderDescription
        self.clock = clock
        self.releaseBound = releaseBound
    }

    // MARK: - What a caller may ask

    /// Where the lease stands now.
    public var state: LeaseDriverState { current }

    /// The same, as a stream that starts with the value now.
    nonisolated public func stateUpdates() -> AsyncStream<LeaseDriverState> {
        AsyncStream { continuation in
            let token = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unsubscribe(token) }
            }
            Task { await self.subscribe(continuation, as: token) }
        }
    }

    // MARK: - What a user does

    /// Holds `target`'s fans at its speeds: a new user action.
    ///
    /// From `idle`, `released`, `refused` or `lost` it starts a new acquisition. While held over
    /// the same fans it is a re-`apply`; over other fans, a release, then an acquire, then an
    /// apply. Ignored once `shutDown()` has begun.
    public func hold(_ target: LeaseTarget) {
        guard !shuttingDown else { return }
        switch current {
        case .idle, .released, .refused, .lost:
            startAcquisition(of: target)
        case .acquiring:
            acquisition?.target = target
            transition(to: .acquiring(fans: target.fans))
        case .held(let held) where held.fans == target.fans:
            requestApply(target, in: held)
        case .held(let held):
            wanted = target
            _ = beginRelease(of: held.lease)
        case .releasing:
            wanted = target
        }
    }

    /// Auto: the lease is released, at once, whatever is in flight. Returns without waiting.
    public func selectAutomatic() {
        _ = requestRelease()
    }

    /// Releases whatever is held and waits at most `releaseBound` for the helper's answer.
    ///
    /// Idempotent: a call while a release is in flight joins it, and a call with nothing held
    /// sends nothing. The entry point for closing the last control window and for logout
    /// (`LeaseLifecycle`).
    @discardableResult
    public func release() async -> ReleaseOutcome {
        // The bound starts before the release is sent, so it cannot start late.
        let deadline = clock.now.advanced(by: releaseBound)
        guard let task = requestRelease() else { return .nothingHeld }
        return await Self.outcome(of: task, until: deadline, bound: releaseBound, on: clock)
    }

    /// Releases, then tears the control connection down. The quit path: after it begins, nothing
    /// is acquired again.
    public func shutDown() async {
        shuttingDown = true
        await release()
        await control.disconnect()
    }

    /// The Mac woke. If a lease is held, the next renewal is sent now, so a lease that did not
    /// survive the sleep is reported as lost at once. **Never asks for the fans again.**
    public func systemDidWake() {
        guard case .held(let held) = current, let grant else { return }
        wokeSinceRenewal = true
        let due = clock.now.advanced(by: .zero - grant.interval)
        startHeartbeat(for: held.lease.id, every: grant.interval, from: due)
    }

    // MARK: - Snapshots from the read connection

    /// When a snapshot was asked for, as the driver counts it. Only the driver mints one.
    public struct SnapshotTicket: Sendable, Hashable {
        fileprivate let epoch: UInt64
    }

    /// Take immediately before sending `snapshot` on the read connection, and hand back with it.
    public func beginSnapshotRead() -> SnapshotTicket {
        SnapshotTicket(epoch: epoch)
    }

    /// Judges `snapshot` against the lease held, if the ticket shows it was asked for after the
    /// lease's first `apply` was answered. A loss ends the lease (`lost`), with the snapshot's
    /// emergency flag kept beside it.
    public func observe(_ snapshot: SystemSnapshot, readWith ticket: SnapshotTicket) {
        guard case .held(let held) = current, let grant, grant.lease.id == held.lease.id,
            let judgedFrom = grant.judgedFrom, ticket.epoch >= judgedFrom
        else { return }
        guard let loss = snapshot.controlLoss(leaseID: held.lease.id, covering: grant.fans) else {
            return
        }
        lose(
            held.lease.id,
            .snapshot(loss, isThermalEmergencyActive: snapshot.isThermalEmergencyActive))
    }

}

// MARK: - Acquiring

extension LeaseDriver {

    private func startAcquisition(of target: LeaseTarget) {
        acquisitions &+= 1
        let id = acquisitions
        let previous = pendingRelease?.task
        acquisition = Acquisition(id: id, target: target)
        transition(to: .acquiring(fans: target.fans))
        acquiring = Task { await self.acquire(id, after: previous) }
    }

    /// Sends the request once any release in flight has answered, and handles the answer.
    ///
    /// - Returns: A lease granted after a release was asked for, for the release to give back.
    private func acquire(
        _ id: UInt64, after previous: Task<ReleaseOutcome, Never>?
    ) async -> Lease? {
        if let previous { _ = await previous.value }
        guard let pending = acquisition, pending.id == id, !pending.releaseOnArrival else {
            return nil
        }
        let request = LeaseRequest(
            holderDescription: holder, fanIndices: pending.target.fans,
            timeToLive: Lease.defaultTimeToLive, isSelfRenewing: false)
        // Taken before the request is sent: the renewal schedule starts here.
        let requestedAt = clock.now
        do {
            let lease = try await control.acquireLease(request)
            return granted(lease, for: request, requestedAt: requestedAt, acquisition: id)
        } catch {
            await acquireFailed(HelperFailure(error), acquisition: id)
            return nil
        }
    }

    private func granted(
        _ lease: Lease, for request: LeaseRequest, requestedAt: ContinuousClock.Instant,
        acquisition id: UInt64
    ) -> Lease? {
        guard let pending = acquisition, pending.id == id else {
            giveBack(lease)
            return nil
        }
        acquisition = nil
        if pending.releaseOnArrival { return lease }
        guard pending.target.fans == request.fanIndices else {
            wanted = pending.target
            _ = beginRelease(of: lease)
            return nil
        }
        let interval = Duration.seconds(request.timeToLive) / 3
        grant = Grant(lease: lease, fans: request.fanIndices, interval: interval)
        wokeSinceRenewal = false
        transition(
            to: .held(
                HeldLease(
                    lease: lease, fans: request.fanIndices,
                    phase: .applying(pending.target, queued: nil))))
        startHeartbeat(for: lease.id, every: interval, from: requestedAt)
        startHealthWatch(for: lease.id)
        Task { await self.runApplies(pending.target, under: lease.id) }
        return nil
    }

    private func acquireFailed(_ failure: HelperFailure, acquisition id: UInt64) async {
        if case .refused = failure {
        } else {
            // No answer the driver could read, so whether a lease was granted is unknown. Tearing
            // the connection down ends any lease on it.
            await control.disconnect()
        }
        guard let pending = acquisition, pending.id == id else { return }
        acquisition = nil
        if pending.releaseOnArrival { return }
        switch failure {
        case .refused(let fault):
            transition(to: .refused(fault))
        case .failed, .other:
            transition(
                to: .lost(
                    LeaseLoss(lease: nil, cause: .acquireUnanswered(failure), afterWake: false)))
        }
    }

}

// MARK: - Applying

extension LeaseDriver {

    private func requestApply(_ target: LeaseTarget, in held: HeldLease) {
        switch held.phase {
        case .applying(let sending, _):
            // Latest wins: a newer target replaces the queued one, and one equal to the target
            // in flight needs nothing queued.
            let queued = target == sending ? nil : target
            transition(to: .held(held.with(.applying(sending, queued: queued))))
        case .confirmed(let confirmed):
            guard target != confirmed else { return }
            transition(to: .held(held.with(.applying(target, queued: nil))))
            Task { await self.runApplies(target, under: held.lease.id) }
        }
    }

    /// The one `apply` in flight under `leaseID`, then whatever was queued behind it.
    private func runApplies(_ first: LeaseTarget, under leaseID: UUID) async {
        var sending = first
        while true {
            do {
                try await control.apply(sending.settings, leaseID: leaseID)
            } catch {
                lose(leaseID, .apply(HelperFailure(error)))
                return
            }
            guard let next = applyAccepted(sending, under: leaseID) else { return }
            sending = next
        }
    }

    /// Records an accepted `apply`, and returns the target queued behind it, if any.
    private func applyAccepted(_ target: LeaseTarget, under leaseID: UUID) -> LeaseTarget? {
        guard case .held(let held) = current, held.lease.id == leaseID else { return nil }
        if grant?.judgedFrom == nil {
            epoch &+= 1
            grant?.judgedFrom = epoch
        }
        if case .applying(_, let queued?) = held.phase {
            transition(to: .held(held.with(.applying(queued, queued: nil))))
            return queued
        }
        transition(to: .held(held.with(.confirmed(target))))
        return nil
    }

}

// MARK: - Proving the lease is alive

extension LeaseDriver {

    private func startHeartbeat(
        for leaseID: UUID, every interval: Duration, from anchor: ContinuousClock.Instant
    ) {
        heartbeat?.cancel()
        heartbeat = Task { await self.beat(leaseID, every: interval, from: anchor) }
    }

    private func beat(
        _ leaseID: UUID, every interval: Duration, from anchor: ContinuousClock.Instant
    ) async {
        var renewedAt = anchor
        while true {
            do {
                try await clock.sleep(until: renewedAt.advanced(by: interval))
            } catch {
                if !Task.isCancelled { lose(leaseID, .heartbeatFailed) }
                return
            }
            guard !Task.isCancelled, isHeld(leaseID) else { return }
            // Stamped before it is sent: a slow answer must not make the next one late.
            renewedAt = clock.now
            do {
                _ = try await control.renewLease(id: leaseID)
            } catch {
                if !Task.isCancelled { lose(leaseID, .renewal(HelperFailure(error))) }
                return
            }
            guard !Task.isCancelled, isHeld(leaseID) else { return }
            wokeSinceRenewal = false
        }
    }

    private func startHealthWatch(for leaseID: UUID) {
        healthWatch?.cancel()
        let updates = control.healthUpdates()
        healthWatch = Task { await self.watch(updates, for: leaseID) }
    }

    private func watch(_ updates: AsyncStream<HelperConnectionHealth>, for leaseID: UUID) async {
        for await health in updates {
            guard !Task.isCancelled, isHeld(leaseID) else { return }
            if health != .handshaken {
                lose(leaseID, .connection(health))
                return
            }
        }
    }

    private func isHeld(_ leaseID: UUID) -> Bool {
        if case .held(let held) = current { return held.lease.id == leaseID }
        return false
    }

    /// Ends the lease as lost, if it is the one held, and sends its one release.
    private func lose(_ leaseID: UUID, _ cause: LeaseLoss.Cause) {
        guard case .held(let held) = current, held.lease.id == leaseID else { return }
        let afterWake = wokeSinceRenewal
        endLease()
        wanted = nil
        transition(to: .lost(LeaseLoss(lease: held.lease, cause: cause, afterWake: afterWake)))
        startRelease(of: held.lease)
    }

    private func endLease() {
        heartbeat?.cancel()
        heartbeat = nil
        healthWatch?.cancel()
        healthWatch = nil
        grant = nil
        wokeSinceRenewal = false
    }

}

// MARK: - Releasing

extension LeaseDriver {

    /// Starts a release if one is needed, and returns the release in flight, if any.
    private func requestRelease() -> Task<ReleaseOutcome, Never>? {
        wanted = nil
        switch current {
        case .held(let held):
            return beginRelease(of: held.lease)
        case .acquiring:
            return releaseOnArrival()
        case .releasing, .released, .lost, .refused, .idle:
            return pendingRelease?.task
        }
    }

    /// `held` → `releasing`, and the release sent.
    private func beginRelease(of lease: Lease) -> Task<ReleaseOutcome, Never> {
        endLease()
        transition(to: .releasing)
        return startRelease(of: lease)
    }

    /// `acquiring` → `releasing`: whatever the request in flight is granted is given straight
    /// back, never applied.
    private func releaseOnArrival() -> Task<ReleaseOutcome, Never>? {
        guard let acquiring else { return nil }
        acquisition?.releaseOnArrival = true
        transition(to: .releasing)
        releases &+= 1
        let id = releases
        let task = Task { () -> ReleaseOutcome in
            guard let lease = await acquiring.value else {
                self.releaseAnswered(id)
                return .nothingHeld
            }
            return await self.send(release: lease, as: id)
        }
        pendingRelease = (id, nil, task)
        return task
    }

    @discardableResult
    private func startRelease(of lease: Lease) -> Task<ReleaseOutcome, Never> {
        releases &+= 1
        let id = releases
        let task = Task { await self.send(release: lease, as: id) }
        pendingRelease = (id, lease, task)
        return task
    }

    private func send(release lease: Lease, as id: UInt64) async -> ReleaseOutcome {
        let outcome: ReleaseOutcome
        do {
            try await control.releaseLease(id: lease.id)
            outcome = .released
        } catch {
            outcome = .failed(HelperFailure(error))
        }
        releaseAnswered(id)
        return outcome
    }

    /// The release `id` answered: `releasing` → `released`, or on to the acquisition `wanted`.
    /// A release sent after a loss leaves `lost` as it is.
    private func releaseAnswered(_ id: UInt64) {
        if pendingRelease?.id == id { pendingRelease = nil }
        guard case .releasing = current, pendingRelease == nil else { return }
        if let wanted, !shuttingDown {
            self.wanted = nil
            startAcquisition(of: wanted)
        } else {
            wanted = nil
            transition(to: .released)
        }
    }

    /// A grant nobody is waiting for: given straight back, with no change of state.
    private func giveBack(_ lease: Lease) {
        Task { try? await self.control.releaseLease(id: lease.id) }
    }

    /// Waits for `release`, or until `deadline` on `clock`, whichever is first.
    private static func outcome(
        of release: Task<ReleaseOutcome, Never>, until deadline: ContinuousClock.Instant,
        bound: Duration, on clock: any HeartbeatClock
    ) async -> ReleaseOutcome {
        await withCheckedContinuation { continuation in
            let first = FirstAnswer(continuation)
            let timer = Task {
                do { try await clock.sleep(until: deadline) } catch { return }
                await first.resume(returning: .notAnswered(within: bound))
            }
            Task {
                let outcome = await release.value
                timer.cancel()
                await first.resume(returning: outcome)
            }
        }
    }

}

// MARK: - Publishing

extension LeaseDriver {

    private func transition(to state: LeaseDriverState) {
        guard state != current else { return }
        current = state
        for continuation in observers.values { continuation.yield(state) }
    }

    private func subscribe(
        _ continuation: AsyncStream<LeaseDriverState>.Continuation, as token: UUID
    ) {
        observers[token] = continuation
        continuation.yield(current)
    }

    private func unsubscribe(_ token: UUID) {
        observers[token] = nil
    }
}

/// Resumes a continuation once, with whichever answer reaches it first.
private actor FirstAnswer {
    private var continuation: CheckedContinuation<ReleaseOutcome, Never>?

    init(_ continuation: CheckedContinuation<ReleaseOutcome, Never>) {
        self.continuation = continuation
    }

    func resume(returning outcome: ReleaseOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
