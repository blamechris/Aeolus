import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

/// The app's one lease on the fans: it asks for them, keeps proving it is alive, gives them back,
/// and says so when it can no longer show it holds them (`CLAUDE.md` rules 2 and 6, #155).
///
/// **Built by `AppComposition`, and taken through it on a click.** A build with a helper constructs
/// one, over the app's control connection, and wires quit, logout, wake, fast user switching and
/// the last control window to it. The main window's control for all fans calls `take(_:)` for a
/// percentage and `selectAutomatic()` for Auto (#153's PR 6b); nothing calls `adjust(_:)` until
/// PR 8's slider. Until the write plane exists (#9) the helper refuses every grant, so the
/// shipping app is refused any lease it asks for.
///
/// ## States
///
///     idle ──take──▶ acquiring ──granted──▶ held(applying ⇄ confirmed)
///                      │                      │                 │
///                      │ refusal              │ release, Auto   │ renewal, apply,
///                      ▼                      ▼                 │ snapshot, health
///                    refused              releasing             ▼
///                                             │ └─unconfirmed─▶ lost
///                                    answered ▼
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
/// `SystemSnapshot.controlLoss(leaseID:covering:)` is non-nil; a heartbeat whose wait failed; and
/// a release the helper refused or did not answer, with no `take` queued behind it (see
/// "Release"). After any loss but the last, the driver sends one release for the lease, because
/// it cannot tell from here whether the helper still has it, and a release of a lease the helper
/// no longer holds is refused (`.leaseUnknown`, `.leaseExpired`, `.leaseNotHeldByThisConnection`)
/// and changes nothing. Then it never renews and never acquires on its own.
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
/// **`released` says what the driver is doing, not what the fans are.** It holds no lease and
/// renews none; what the fans are doing is the next snapshot's to report. An `apply` sent before
/// it can still be in flight: Auto during an `apply` releases at once and leaves the `apply` to
/// answer. It is reached after an answered release, and also on paths where no answer is kept: a
/// release asked for while acquiring whose request granted nothing, and an acquisition queued
/// behind a release, which does not keep that release's answer. Even an answered release does not
/// show the fans are automatic: the helper's `releaseLease` removes the lease and then awaits a
/// restore that does not throw, so its reply means "accepted", not "done" (ADR 0015). So no
/// renderer reads the fans as automatic from `released`: only from a snapshot read after it (see
/// "When a snapshot may show the fans automatic").
///
/// A release the helper refused, or that went unanswered, with no `take` queued behind it, ends in
/// `lost` with `LeaseLoss.Cause.releaseUnconfirmed`. That is a status line, true where it is
/// emitted, and no claim depends on it. A `take` queued behind that release is acquired all the
/// same: a second grant is the helper's to refuse, and the release's answer is not kept.
///
/// ## When a snapshot may show the fans automatic (ADR 0015 D2)
///
/// Every state change passes through `transition(to:)`, and the states in which the driver has
/// stopped acting, `released`, `lost` and `refused`, set a read-timing floor there, chosen by an
/// exhaustive switch. The floor is a ticket minted from the same epoch `beginSnapshotRead()` reads,
/// so a read ticketed before it is older and one ticketed after it is not. It is published with
/// the state, as one `LeaseDriverReport`, so a renderer never pairs a state with an older floor.
/// `idle` sets none: the driver has never acted.
///
/// **The floor waits for every `apply` to answer (#498's S2).** An `apply` in flight under a lease
/// whose release has answered can still land one target write after the restore: never a mode
/// write, which the step ticket refuses, but `F<n>Tg` on an automatic fan, which ADR 0014
/// calls reported harmless on Apple Silicon and untested on Intel. That is a hardware claim nobody
/// has observed, so a stop with an `apply` unanswered publishes `noRead`, and the floor is minted
/// when the last `apply` has answered, as a new report with the same state. A read sent after that
/// answer is, on ADR 0015's assumption about two connections, served after that `apply` finished.
///
/// **Minting cannot change what `observe(_:readWith:)` decides.** Each mint advances the epoch by
/// one, and a ticket is the epoch when it was taken, so a ticket is at or past a mint exactly when
/// it was taken after that mint, however many other mints there are. The grant's
/// `leaseJudgedFrom` and the first `apply`'s `fansJudgedFrom` keep that meaning beside the
/// floor's. And the floor is minted only where nothing is held, where `observe` judges nothing.
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

    private let control: any HelperLeaseControlling
    private let clock: any HeartbeatClock
    private let holder: String
    private let releaseBound: Duration

    private var current: LeaseDriverState = .idle
    /// Which reads may show a fan automatic, as last published with `current`.
    private var evidence: LeaseDriverReport.AutomaticEvidence = .anyRead
    /// Who follows `stateUpdates()` and `reportUpdates()`. Published to only by `transition(to:)`
    /// and `applyAnswered()`, each after any floor its state sets is minted, only on this actor.
    private var publisher = LeaseDriverPublisher()
    /// How many `apply` calls have been sent and not answered, under any lease. An `apply` is left
    /// to answer when its lease ends (#419), so this can be non-zero in any state.
    private var appliesUnanswered = 0

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
        LeaseDriverPublisher.stream(of: self) { driver, observer, token in
            driver.publisher.addStateObserver(observer, as: token, startingWith: driver.current)
        } remove: { driver, token in
            driver.publisher.removeStateObserver(token)
        }
    }

    /// The state now, with which reads may show a fan automatic beside it (ADR 0015 D2).
    public var report: LeaseDriverReport {
        LeaseDriverReport(state: current, automaticEvidence: evidence)
    }

    /// The same, as a stream that starts with the value now: one element for each change of the
    /// state, and one when the evidence changes with the state unchanged, as it does when the last
    /// unanswered `apply` answers after the driver stopped acting. What a renderer that claims
    /// Automatic follows; `stateUpdates()` is for consumers that need the state alone.
    nonisolated public func reportUpdates() -> AsyncStream<LeaseDriverReport> {
        LeaseDriverPublisher.stream(of: self) { driver, observer, token in
            driver.publisher.addReportObserver(observer, as: token, startingWith: driver.report)
        } remove: { driver, token in
            driver.publisher.removeReportObserver(token)
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
    ///
    /// `Comparable` for ordering only: a ticket is less than another when it was taken before a
    /// moment the other was taken after. The count itself stays in this file.
    public struct SnapshotTicket: Sendable, Hashable, Comparable {
        fileprivate let epoch: UInt64

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.epoch < rhs.epoch }
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
        scheduleApplies(pending.target, under: lease.id)
        return nil
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
            scheduleApplies(target, under: held.lease.id)
        }
    }

    /// Starts `runApplies` on a task of its own, its first `apply` counted unanswered **now**, in
    /// the turn that decided to send it, not when the task starts. Between the two the actor can
    /// run other jobs, a snapshot judged lost (`observe(_:readWith:)`) among them; a stop counted
    /// only at the task's start would set its floor and then send the `apply` (#498's S2). Both
    /// places that schedule an `apply`, the grant and a confirmed lease's re-`apply`, come here.
    ///
    /// **No test orders that gap.** Default actors run equal-priority jobs in the order enqueued,
    /// and every loss from the driver's own tasks suspends first, so only a higher-priority job
    /// enqueued during the scheduling turn overtakes the task, which a suite cannot place there.
    private func scheduleApplies(_ first: LeaseTarget, under leaseID: UUID) {
        appliesUnanswered += 1
        Task { await self.runApplies(first, under: leaseID) }
    }

    /// The one `apply` in flight under `leaseID`, then whatever was queued behind it.
    ///
    /// **Every `apply` is counted once before it is sent, and uncounted once when it answers.** The
    /// first by `scheduleApplies`; a queued one in the turn that takes it from the queue. Each
    /// answer is uncounted before anything acts on it, so a loss it causes, and that loss's floor,
    /// see it answered. The loop sends before it can return, so no count is left behind.
    private func runApplies(_ first: LeaseTarget, under leaseID: UUID) async {
        var sending = first
        while true {
            let failure: (any Error)?
            do {
                try await control.apply(sending.settings, leaseID: leaseID)
                failure = nil
            } catch {
                failure = error
            }
            applyAnswered()
            if let failure {
                lose(leaseID, .apply(HelperFailure(failure)))
                return
            }
            guard let next = applyAccepted(sending, under: leaseID) else { return }
            appliesUnanswered += 1
            sending = next
        }
    }

    /// An `apply` answered, whatever it answered. When it was the last one unanswered and the
    /// driver has stopped acting with no read yet admitted, the floor is minted now and published
    /// with the state unchanged (#498's S2; see "When a snapshot may show the fans automatic").
    private func applyAnswered() {
        appliesUnanswered -= 1
        guard appliesUnanswered == 0, case .noRead = evidence, Self.hasStoppedActing(current)
        else { return }
        evidence = .readFrom(mintFloor())
        publisher.publishEvidenceChange(report)
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
                self.releaseAnswered(id, unconfirmed: nil)
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
        let unconfirmed: (lease: Lease, failure: HelperFailure)?
        do {
            try await control.releaseLease(id: lease.id)
            outcome = .released
            unconfirmed = nil
        } catch {
            let failure = HelperFailure(error)
            outcome = .failed(failure)
            unconfirmed = (lease, failure)
        }
        releaseAnswered(id, unconfirmed: unconfirmed)
        return outcome
    }

    /// The release `id` came back: `releasing` → `lost` when the helper refused it or did not
    /// answer (`unconfirmed`), otherwise `released`, or on to the acquisition `wanted` either way.
    /// A release sent after a loss leaves `lost` as it is. `nil` for `unconfirmed` also covers a
    /// release asked for while acquiring whose request granted nothing, so nothing was sent. So
    /// `released` does not say the helper answered (see "Release").
    ///
    /// The loss's `afterWake` is `false`: `beginRelease` ended the lease, and with it the wake
    /// mark, before the release was sent.
    private func releaseAnswered(
        _ id: UInt64, unconfirmed: (lease: Lease, failure: HelperFailure)?
    ) {
        if pendingRelease?.id == id { pendingRelease = nil }
        guard case .releasing = current, pendingRelease == nil else { return }
        if let wanted, !shuttingDown {
            self.wanted = nil
            startAcquisition(of: wanted)
        } else if let unconfirmed {
            wanted = nil
            transition(
                to: .lost(
                    LeaseLoss(
                        lease: unconfirmed.lease, cause: .releaseUnconfirmed(unconfirmed.failure),
                        afterWake: false)))
        } else {
            wanted = nil
            transition(to: .released)
        }
    }

}

// MARK: - Publishing

extension LeaseDriver {

    /// The one place every state change passes through. Entering a state in which the driver has
    /// stopped acting sets the read-timing floor, **before** anything is published, so the report
    /// published with the state carries the floor set for it (ADR 0015 D2).
    private func transition(to state: LeaseDriverState) {
        guard state != current else { return }
        current = state
        if Self.hasStoppedActing(state) {
            // An `apply` still unanswered may write after this; see "When a snapshot may show the
            // fans automatic". `applyAnswered()` mints the floor when the last one answers.
            evidence = appliesUnanswered == 0 ? .readFrom(mintFloor()) : .noRead
        }
        publisher.publishStateChange(report)
    }

    /// Whether the driver has stopped acting in `state`: it holds nothing and is not acquiring or
    /// releasing. The states that set a floor. Exhaustive, with no `default:`, so a state added
    /// later has to be decided here.
    private static func hasStoppedActing(_ state: LeaseDriverState) -> Bool {
        switch state {
        case .released, .lost, .refused:
            return true
        case .idle, .acquiring, .held, .releasing:
            return false
        }
    }

    /// A ticket no read has been given yet: the first read ticketed after this is at or past it,
    /// and every read ticketed before it is older.
    private func mintFloor() -> SnapshotTicket {
        epoch &+= 1
        return SnapshotTicket(epoch: epoch)
    }
}
