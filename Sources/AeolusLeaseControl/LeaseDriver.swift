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
///     idle ──take──▶ acquiring ──granted──▶ held(applying ⇄ confirmed)
///                      │                      │                 │
///                      │ refusal              │ release, Auto   │ renewal, apply,
///                      ▼                      ▼                 │ snapshot, health
///                    refused              releasing             ▼
///                                             │               lost
///                                             ▼
///                                         released
///
/// ## Two ways to ask for a speed, and the UI must use the right one
///
/// - **`take(_:)`** is a deliberate user action: a click on a speed, or a fan put into Custom. It
///   is the only call that starts an acquisition, from `idle`, `released`, `refused` or `lost`.
/// - **`adjust(_:)`** is everything else: a slider moving, a stepper, a value typed while the
///   lease is held. It refines the target of a lease that is acquiring or held, over the same
///   fans, and is **ignored** in every other state. It never acquires.
///
/// The split is what keeps a loss final. A slider wired to `take` would, on the first tick after
/// § 3 revoked the lease, ask for the fans again and apply the speed the user was dragging, and the
/// user would never see that control had ended; from `refused`, every tick would be another
/// acquire, an unpaced retry of a refusal (ADR 0010).
///
/// ## Renewal
///
/// Every third of the shorter of the TTL asked for and the TTL the helper granted, so two missed
/// beats are tolerated before the helper lets go (`docs/SAFETY.md` § 1), and a helper that
/// granted less than was asked is still renewed in time. A granted TTL outside
/// `AeolusXPCValidation.leaseTTLRange` is not believed, so a malformed grant can never make the
/// heartbeat spin. The schedule starts at the instant taken **before `acquireLease` is sent**,
/// which cannot be later than the grant the helper's TTL starts from, and each renewal is stamped
/// before it is sent, so a slow answer never makes the next one late. The heartbeat starts when
/// the grant arrives, before the first `apply` is sent, and runs **during** it: an `apply` may
/// take 57 s for one fan, and the helper's thirty seconds started at the grant. `renewLease` is
/// not sequenced at the helper, so a renewal is not queued behind the `apply`.
///
/// No step of a renewal passes through the main actor, deliberately: a hung UI keeps the lease
/// and a busy one never loses it. Making this type `@MainActor`, or hopping to it in `beat()`,
/// reverses `docs/SAFETY.md` § 1 and is a safety review.
///
/// ## Loss is final
///
/// Each of these ends the lease as `lost` (`LeaseLoss.Cause`): an acquire that failed without the
/// helper saying no; a renewal refused or unanswered; an `apply` refused or unanswered; the
/// control connection leaving `.handshaken`; a snapshot for which
/// `SystemSnapshot.controlLoss(leaseID:covering:)` is non-nil; and a heartbeat whose wait failed.
/// After `lost` the driver sends one release for the lease, because it cannot tell from here
/// whether the helper still has it, and a release of a lease the helper no longer holds is
/// refused (`.leaseUnknown`, `.leaseExpired`, `.leaseNotHeldByThisConnection`) and changes
/// nothing. Then it never renews and never acquires on its own.
///
/// **Wake** is the same: `systemDidWake()` brings the next renewal forward so a lease that did not
/// survive the sleep is reported at once, and it never asks for the fans again. `docs/SAFETY.md`
/// § 4 leaves that to the maintainer, and never is the default (#153).
///
/// ## One `apply` in flight, latest wins
///
/// A new target over the same fans is a re-`apply` under the same lease. While one is in flight a
/// newer target replaces any queued one, and nothing is sent until it answers. `apply` is
/// sequenced, so a second one sent on this connection would wait at the helper behind the first,
/// up to its whole deadline, and arrive with a target the user has already moved past; every
/// sequenced message behind it, such as a change of fans' acquire, would wait too. Level 6 also
/// admits one at a time, but through XPC it never sees two under one lease. A change to **which**
/// fans are held is a release, then an acquire, then an apply. The acquire goes ahead whatever the
/// release answered: a release refused as `.leaseUnknown` means the old lease had already gone,
/// and that answer is not kept.
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
/// ## A snapshot is judged only on what it could show
///
/// Snapshots come from the read connection, and nothing between two connections is ordered. One
/// requested before the grant was answered can arrive after it without the lease, and one
/// requested before the first `apply` was answered can arrive after it with the fans not yet held;
/// judging either would end, for good, a lease that was fine. So a reader takes a `SnapshotTicket`
/// from `beginSnapshotRead()` immediately before it sends `snapshot`, and `observe(_:readWith:)`
/// acts on what the ticket's moment can prove:
///
/// - **From the grant's answer:** that the lease is not listed, or that § 3's emergency holds
///   while it is. `controlLoss` decides those before it looks at a fan, so a revocation during a
///   57 s first `apply` is shown at the next snapshot rather than at the next renewal.
/// - **From the first accepted `apply`:** everything else, which is about the fans.
///
/// The driver mints the ticket, so a caller cannot forge one; it can still take one at the wrong
/// moment, which only the wiring can get right.
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
    /// **Two seconds, stated rather than measured.** It bounds how long a quit, a logout or a
    /// window close waits. Past it the release is still in flight, and the lease ends on the
    /// helper's answer or, at the latest, at its TTL, since nothing renews it any more; on a quit
    /// the teardown that follows ends it at once. Shorter than `HelperClientDeadlines.gatedVerb`,
    /// so it is this bound, not the client's, that lets a quit go.
    public static let releaseBound: Duration = .seconds(2)

    /// What the app calls itself in a lease: `Aeolus.app` and its `CFBundleShortVersionString`.
    public static func holderDescription(shortVersion: String?) -> String {
        guard let shortVersion, !shortVersion.isEmpty else { return "Aeolus.app" }
        return "Aeolus.app \(shortVersion)"
    }

    /// The grant the driver holds: the lease, its fans, and the schedule it is renewed on.
    private struct Grant {
        var lease: Lease
        let fans: [Int]
        let interval: Duration
        /// The ticket epoch from which a snapshot is evidence about this lease itself: set when
        /// the grant arrives.
        let leaseJudgedFrom: UInt64
        /// The ticket epoch from which a snapshot is evidence about this lease's fans: set when the
        /// first `apply` under it is answered with success, `nil` until then.
        var fansJudgedFrom: UInt64?
    }

    /// A release in flight: which one, of which lease, and its task.
    private struct PendingRelease {
        let id: UInt64
        /// `nil` for a release asked for while the lease was still being acquired.
        let lease: Lease?
        let task: Task<ReleaseOutcome, Never>
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
    private var pendingRelease: PendingRelease?
    private var releases: UInt64 = 0
    /// What to acquire once the release in flight has answered: a change of fans, or a `take`
    /// while releasing.
    private var wanted: LeaseTarget?
    /// Counts the moments a snapshot's ticket is compared against. Never reset, so a ticket taken
    /// under one lease can never be read as taken under the next.
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

    /// A heartbeat that can be waited for, and nothing else.
    ///
    /// **It holds no `Task`.** The beat's `Task` would hand its holder `cancel()`, and a cancelled
    /// beat sends no renewal and reports no loss: the helper lets the lease go at its TTL while
    /// the driver goes on drawing `held` (`CLAUDE.md` rule 6, #486). So the handle keeps only a
    /// closure that waits for the beat, and no change to its access levels can hand the cancel
    /// back. Only this file can make one.
    struct HeartbeatHandle: Sendable {
        private let wait: @Sendable () async -> Void

        fileprivate init(_ beat: Task<Void, Never>) {
            wait = { await beat.value }
        }

        /// Returns once the beat has finished, whatever it did.
        ///
        /// **Not cancellable.** It waits on the beat's `Task.value`, which does not end when the
        /// waiting task is cancelled, so a time limit cannot end a test stuck here. Call it from
        /// a task of its own (`LeaseScene.run`), never directly from a test.
        func finished() async { await wait() }
    }

    /// The heartbeat running now, as a handle that can only be waited for, for a suite that has
    /// to know when a beat has finished.
    ///
    /// `internal`, for the suite alone: a test about a renewal that must **not** be sent has no
    /// event to wait for, and waiting for the beat itself is the only end it has. Unlike
    /// `HelperClient.deadlinesRunning`, which is a count, it reaches a task the driver owns, so it
    /// hands out a wait rather than the task.
    ///
    /// **The module boundary keeps it in the suite (#489).** This file is in `AeolusLeaseControl`,
    /// so `AeolusUI`, the app and every other module are refused at compile time: `internal` does
    /// not cross a module. Only a deliberate `@testable import AeolusLeaseControl` reaches it,
    /// which `AeolusUITests` does.
    ///
    /// **A production `@testable import` is refused by a Release build, and CI runs one (#491).**
    /// A Debug build, which builds with testability, accepts it anywhere and reaches the
    /// accessor. The `Build (release, without testability)` step of CI's workflow
    /// (`swift build -c release`) refuses it in every SwiftPM target, so it fails the pull
    /// request. It does not see `Sources/Aeolus/main.swift`, which only the Xcode app target
    /// compiles and CI builds in Monitor Debug alone.
    ///
    /// What the failure says depends on the build system. SwiftPM's native one names the file
    /// that wrote the import: `<offending file>:1:18: error: module 'AeolusLeaseControl' was not
    /// compiled for testing [#ModuleNotTestable]`. Swift 6.4's default build system says
    /// `unable to resolve Swift module dependency to a compatible module: 'AeolusLeaseControl'`
    /// at the first file in path order that imports the module, which is not always the offender
    /// (`LeaseLifecycle.swift`, for one that sorts after it). Either way, search `Sources/` for
    /// `@testable`.
    ///
    /// The compiler keeps the accessor from every module that imports this one plainly. It holds
    /// nothing inside this target, so the files in `AeolusLeaseControl` are reviewed together: no
    /// code in this target other than their declarations names `runningHeartbeat` or
    /// `HeartbeatHandle`. What the compiler does hold, `scripts/lending-probes/check.sh` checks on
    /// every CI run: `refused-heartbeat-accessor.swift` and `refused-heartbeat-handle.swift` fail
    /// if the accessor or the handle is widened to `package` or `public`, and the script's own
    /// check that SwiftPM still has the target fails if the target is folded back into
    /// `AeolusUI`.
    ///
    /// Reflection: `Mirror(reflecting:)` on the driver reads `heartbeat` itself, from any module;
    /// no access level stops that, and no accidental edit takes that route.
    var runningHeartbeat: HeartbeatHandle? { heartbeat.map(HeartbeatHandle.init) }

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

    /// Takes control of `target`'s fans at its speeds: a deliberate user action, and the only
    /// call that starts an acquisition.
    ///
    /// From `idle`, `released`, `refused` or `lost` it acquires. While acquiring it replaces the
    /// target the grant will be applied with. While held over the same fans it is a re-`apply`;
    /// over other fans, a release, then an acquire, then an apply. While releasing it is
    /// acquired once the release has answered. Ignored once `shutDown()` has begun.
    public func take(_ target: LeaseTarget) {
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

    /// Moves the speed of a lease that is acquiring or held, over the same fans. **Never
    /// acquires:** in `idle`, `released`, `refused` and `lost`, and over other fans, it does
    /// nothing. While releasing it refines only a `take` already waiting on that release.
    public func adjust(_ target: LeaseTarget) {
        guard !shuttingDown else { return }
        switch current {
        case .acquiring:
            guard acquisition?.target.fans == target.fans else { return }
            acquisition?.target = target
        case .held(let held) where held.fans == target.fans:
            requestApply(target, in: held)
        case .releasing:
            guard wanted?.fans == target.fans else { return }
            wanted = target
        case .held, .idle, .released, .refused, .lost:
            return
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
    ///
    /// **Not named `release()`.** `ThermalEmergencyStalenessTests` holds every bare `release()`
    /// call in `Sources/` to be § 3's latch clearing an episode it never named, and fails on one;
    /// that scan is a safety tripwire, so this name keeps out of it rather than narrowing it.
    @discardableResult
    public func releaseFans() async -> ReleaseOutcome {
        // The bound is measured from this call.
        let deadline = clock.now.advanced(by: releaseBound)
        guard let task = requestRelease() else { return .nothingHeld }
        return await Self.outcome(of: task, until: deadline, bound: releaseBound, on: clock)
    }

    /// Releases, then tears the control connection down. The quit path: after it begins, nothing
    /// is acquired again.
    public func shutDown() async {
        shuttingDown = true
        await releaseFans()
        await control.disconnect()
    }

    /// The Mac woke. If a lease is held, the next renewal is sent now, so a lease that did not
    /// survive the sleep is reported as lost at once. **Never asks for the fans again.**
    ///
    /// Returns once the heartbeat it replaced has finished, so that when it returns, that beat can
    /// no longer change the state. `beat`'s `Task.isCancelled` checks are what keep the replaced
    /// beat's cancelled renewal from being read as a loss, and an answer it already had from being
    /// counted.
    ///
    /// **How long that takes:** at once, unless the replaced renewal is waiting on the connection's
    /// handshake, which does not end on cancellation: up to `HelperClientDeadlines.handshakeVerb`.
    /// Call it from a task of its own, never from the main actor's own path.
    public func systemDidWake() async {
        guard case .held(let held) = current, let grant else { return }
        wokeSinceRenewal = true
        let replaced = heartbeat
        let due = clock.now.advanced(by: .zero - grant.interval)
        startHeartbeat(for: held.lease.id, every: grant.interval, from: due)
        await replaced?.value
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

    /// Judges `snapshot` against the lease held, on what the ticket's moment can prove: the lease
    /// itself from its grant's answer, its fans from its first accepted `apply`. A loss ends the
    /// lease (`lost`), with the snapshot's emergency flag kept beside it.
    public func observe(_ snapshot: SystemSnapshot, readWith ticket: SnapshotTicket) {
        guard case .held(let held) = current, let grant, grant.lease.id == held.lease.id,
            ticket.epoch >= grant.leaseJudgedFrom
        else { return }
        guard let loss = snapshot.controlLoss(leaseID: held.lease.id, covering: grant.fans) else {
            return
        }
        switch loss {
        case .leaseNotListed, .thermalEmergency:
            break
        case .fanNotReported, .reclaimedBySystem, .fanNotHeld:
            guard let fansJudgedFrom = grant.fansJudgedFrom, ticket.epoch >= fansJudgedFrom
            else { return }
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
            // Unreachable as written: an acquisition starts only with none in flight, so the one
            // answering is always the one recorded. Kept so a change that broke that would give
            // the grant back, tracked like any other release, rather than leave it unrenewed.
            startRelease(of: lease)
            return nil
        }
        acquisition = nil
        if pending.releaseOnArrival { return lease }
        guard pending.target.fans == request.fanIndices else {
            wanted = pending.target
            _ = beginRelease(of: lease)
            return nil
        }
        let interval = Self.heartbeatInterval(asked: request.timeToLive, granted: lease.timeToLive)
        epoch &+= 1
        grant = Grant(
            lease: lease, fans: request.fanIndices, interval: interval, leaseJudgedFrom: epoch)
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

    /// A third of the shorter TTL. A granted TTL outside the range the helper validates is not
    /// believed, so a malformed grant cannot make the heartbeat spin.
    private static func heartbeatInterval(
        asked: TimeInterval, granted: TimeInterval
    ) -> Duration {
        let believed = AeolusXPCValidation.leaseTTLRange.contains(granted) ? granted : asked
        return Duration.seconds(min(asked, believed)) / 3
    }

    private func acquireFailed(_ failure: HelperFailure, acquisition id: UInt64) async {
        // A refusal is the helper's answer, on a connection that is working. Anything else is no
        // answer the driver could read, so whether a lease was granted is unknown, and tearing the
        // connection down ends any lease on it. For `clientCannotVerifyHelper` it is known that
        // nothing was sent, and the teardown finds no connection to end.
        if !failure.isRefusal { await control.disconnect() }
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
        if grant?.fansJudgedFrom == nil {
            epoch &+= 1
            grant?.fansJudgedFrom = epoch
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
            let renewed: Lease
            do {
                renewed = try await control.renewLease(id: leaseID)
            } catch {
                // A beat that was stopped, by a release, a loss or a wake, was cancelled: its
                // renewal's failure says nothing about the lease.
                if !Task.isCancelled { lose(leaseID, .renewal(HelperFailure(error))) }
                return
            }
            // A beat stopped while its renewal was in flight does not count the answer: after a
            // wake, the helper may have given it before the sleep.
            guard !Task.isCancelled else { return }
            guard renewalAccepted(renewed, for: leaseID) else { return }
        }
    }

    /// Records a renewal's answer, and says whether the beat goes on.
    ///
    /// **The lease held is the one the helper renewed**, so `HeldLease.lease.expiresAt` is the
    /// helper's latest word rather than the grant's. An answer that names another lease is no
    /// proof this one is alive, and ends it.
    ///
    /// Only a beat that has not been stopped reaches here. An answer a wake-replaced beat already
    /// had is not counted: the helper may have given it before the sleep, and the wake's own
    /// renewal is what says whether the lease survived. A renewal answered after a release, or
    /// after a loss, is likewise not counted, so `held` is never drawn again for control the user
    /// gave back or the helper ended.
    ///
    /// **No lease-id check of its own, so the cancellation is load-bearing.** What keeps an old
    /// lease's answer off a new one is `endLease()`'s `heartbeat?.cancel()`. Every end of a lease
    /// cancels its beat, and `beat`'s `guard !Task.isCancelled` after the renewal stops the
    /// cancelled beat before its answer reaches here. A wake cancels the beat it replaces the
    /// same way (`startHeartbeat`). `everyEndStopsTheHeartbeat` pins the cancel on all five ends,
    /// and `staleRenewalUnderAnOldLease` and `staleRenewalAfterAGrantOverOtherFans` pin the guard.
    /// Without either, an old lease's renewal answered after a new grant replaces the new lease
    /// in `held`, and the new lease's beat, finding it no longer held, stops renewing it. An id
    /// check here would sit behind both, and no test could see it act unless one of them were
    /// deleted. The `case .held` below is only how `held` is reached.
    private func renewalAccepted(_ renewed: Lease, for leaseID: UUID) -> Bool {
        guard case .held(let held) = current else { return false }
        guard renewed.id == leaseID else {
            lose(leaseID, .renewal(.other("the helper renewed a different lease")))
            return false
        }
        grant?.lease = renewed
        wokeSinceRenewal = false
        transition(to: .held(held.with(lease: renewed)))
        return true
    }

    private func startHealthWatch(for leaseID: UUID) {
        healthWatch?.cancel()
        let updates = control.healthUpdates()
        healthWatch = Task { await self.watch(updates, for: leaseID) }
    }

    /// The control connection's health, for as long as `leaseID` is held. No check of its own
    /// that the lease is still held: `endLease()` cancels this watch, but a value buffered before
    /// the cancel can still arrive after it; `lose(_:_:)`'s lease-id check is what makes it
    /// harmless.
    private func watch(_ updates: AsyncStream<HelperConnectionHealth>, for leaseID: UUID) async {
        for await health in updates where health != .handshaken {
            lose(leaseID, .connection(health))
            return
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

    /// Stops everything that belongs to the held lease: its heartbeat, its health watch, and its
    /// grant.
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
        pendingRelease = PendingRelease(id: id, lease: nil, task: task)
        return task
    }

    @discardableResult
    private func startRelease(of lease: Lease) -> Task<ReleaseOutcome, Never> {
        releases &+= 1
        let id = releases
        let task = Task { await self.send(release: lease, as: id) }
        pendingRelease = PendingRelease(id: id, lease: lease, task: task)
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
