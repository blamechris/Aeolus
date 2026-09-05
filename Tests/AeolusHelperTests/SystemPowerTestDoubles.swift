import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

// The doubles `SystemPowerTests` drives `docs/SAFETY.md` § 4 through.
//
// Their own file rather than a second half of the suite, for the reason `LeaseTestDoubles`
// and `HelperTestDoubles` are their own files: three of the five here are firmware doubles
// that differ from `ScriptedControlPlane` in exactly one verb, and one of them —
// `ThreadBlockingRestorePlane` — is a hazard other suites will eventually want. Splitting
// also keeps the suite itself under SwiftLint's file length, which the combined file was not.

/// The seam § 4 is driven through, with no power management root anywhere near it.
///
/// It records **when** each acknowledgement happened rather than only that it did, because the
/// property under test is an ordering: `observing` runs inside the acknowledgement, before it
/// is recorded, so a test can capture what the firmware had already been asked for at that
/// instant.
final class ScriptedPowerObserver: SystemPowerObserving, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable (SystemPowerNotification) async -> Void)?
    private var recorded: [SystemPowerEvent] = []

    /// Fires on the first acknowledgement, so a test can await one without awaiting the
    /// handler that produced it. That distinction is the whole of the budget test.
    let didAcknowledge = AsyncSignal()

    private var observing: @Sendable () async -> Void

    init(observing: @escaping @Sendable () async -> Void = {}) {
        self.observing = observing
    }

    /// Installs the inside-the-acknowledgement observation **after** construction.
    ///
    /// The graph and the observer are mutually dependent — `HelperComposition` needs the
    /// observer to be built, and an observation about the graph needs the graph — so one of
    /// the two has to be closed afterwards. Doing it here rather than by handing the closure a
    /// mutable box keeps the ordering claim readable at the call site, which is the whole
    /// point of observing from inside the acknowledgement in the first place.
    func whenAcknowledging(_ observing: @escaping @Sendable () async -> Void) {
        lock.withLock { self.observing = observing }
    }

    /// Whether anything has installed a handler. `HelperComposition.bringUp()`'s outcome.
    var isObserving: Bool { lock.withLock { handler != nil } }

    /// The events acknowledged, in order.
    var acknowledgements: [SystemPowerEvent] { lock.withLock { recorded } }

    func observe(_ handler: @escaping @Sendable (SystemPowerNotification) async -> Void) throws {
        lock.withLock { self.handler = handler }
    }

    /// Delivers one event and returns when the responder is done with it.
    func deliver(_ event: SystemPowerEvent) async throws {
        let handler = try #require(
            lock.withLock { self.handler }, "nothing is observing this seam")
        await handler(notification(for: event))
    }

    /// Delivers one event on a task of its own, for a responder that will not come back.
    func deliverWithoutWaiting(_ event: SystemPowerEvent) throws -> Task<Void, Never> {
        let handler = try #require(
            lock.withLock { self.handler }, "nothing is observing this seam")
        let notification = notification(for: event)
        return Task { await handler(notification) }
    }

    private func notification(for event: SystemPowerEvent) -> SystemPowerNotification {
        SystemPowerNotification(event: event) { [self] in
            await lock.withLock { observing }()
            lock.withLock { recorded.append(event) }
            await didAcknowledge.signal()
        }
    }
}

/// A seam that will not deliver anything, for the one bring-up step allowed to fail.
struct RefusingPowerObserver: SystemPowerObserving {

    func observe(_ handler: @escaping @Sendable (SystemPowerNotification) async -> Void) throws {
        throw SystemPowerObservationFailure.registrationRefused
    }
}

/// What the firmware had already been asked for at the instant the power change was allowed.
///
/// Only the **first** acknowledgement is kept. A second one would overwrite the observation
/// this suite exists to make, and `SleepAcknowledgement` promises there is never a second —
/// `acknowledgements` is what lets a test say so rather than assume it.
actor AcknowledgementWitness {

    private(set) var attempts: [ScriptedControlPlane.Attempt] = []

    /// How many leases the helper still held at the instant it let the machine sleep.
    ///
    /// `nil` until something records one, so a test cannot pass by never having looked.
    /// Afterwards is useless for this: the lease is gone either way by the time the responder
    /// returns, and on a wedged connection the responder does not return at all.
    private(set) var leaseCount: Int?

    private(set) var acknowledgements = 0

    func record(_ attempts: [ScriptedControlPlane.Attempt]) {
        if acknowledgements == 0 { self.attempts = attempts }
        acknowledgements += 1
    }

    func record(leaseCount: Int) {
        if acknowledgements == 0 { self.leaseCount = leaseCount }
        acknowledgements += 1
    }
}

/// The firmware that takes the keystone restore and never comes back.
///
/// [#68](https://github.com/blamechris/Aeolus/issues/68)'s stale `io_connect_t`, which
/// `FanRestoreAttempting` names as the case no attempt budget can bound: *"a single
/// synchronous IOKit call that never comes back on a wedged connection parks
/// `revokeEveryLease(because:)`"*. `BoundedFanRestorer` runs each attempt inside a `Task` that
/// does not inherit cancellation, so the caller cannot escape by being cancelled either — which
/// is exactly why § 4 needs a budget rather than a `withTimeout`.
///
/// It wraps `ScriptedControlPlane` rather than replacing it, for `RegistryObservingPlane`'s
/// reason: the firmware underneath is the shipped mock, and only the one verb behaves
/// differently.
///
/// **It models a restore that never returns *cooperatively*, which is not quite #68's shape.**
/// `try await held.wait()` suspends and yields its thread; a synchronous IOKit call that never
/// comes back occupies a cooperative-pool thread for as long as it is stuck. A review was
/// right that the budget test therefore proved the budget beats an *awaiting* restore rather
/// than a blocking one. `ThreadBlockingRestorePlane` below is the other half, and
/// `theBudgetSurvivesARestoreThatBlocksItsThread` is what makes the stronger claim.
actor WedgedRestorePlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private let held = AsyncSignal()

    /// Every scope the restore was asked for, recorded before it parks.
    private(set) var restoreScopes: [FanRestoreScope] = []

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Lets the parked restore finish, so a test leaves nothing suspended behind it.
    func release() async {
        await held.signal()
    }

    // MARK: - The wedged verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        restoreScopes.append(scope)
        try await held.wait()
        try await wrapped.restoreToAutomatic(scope)
    }

    // MARK: - Straight delegation

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await wrapped.readControlState(ofFan: index)
    }

    func reconnect() async throws {
        try await wrapped.reconnect()
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}

/// The firmware whose restore blocks a thread instead of suspending it.
///
/// [#68](https://github.com/blamechris/Aeolus/issues/68)'s real shape, as far as a test can
/// reach it: `IOConnectCallStructMethod` on a stale `io_connect_t` is a synchronous kernel
/// call, so a task stuck in one occupies the cooperative-pool thread it is running on and
/// never yields it. `WedgedRestorePlane` above suspends instead, which is a weaker model —
/// the budget's `clock.sleep` and the acknowledgement it leads to are the *other* task, and a
/// suspending wedge leaves them a thread by construction.
///
/// **It is deliberately not a `Task.detached`-and-block.** `BoundedFanRestorer` already runs
/// each attempt inside a `Task` of its own, so the block lands where it would in production:
/// on a pool thread the restorer's own task occupies, with the lease actor merely *suspended*
/// awaiting it. That is why § 4 can still record the abandonment from inside the budget's
/// acknowledgement — a reentrant call into `LeaseAuthority` needs the actor free, not the
/// thread that its restorer went into.
///
/// The semaphore is released by `release()` exactly as the wedge above is, so a test leaves
/// no thread parked behind it. A `DispatchSemaphore` rather than an `AsyncSignal` precisely
/// because blocking is the property under test.
final class ThreadBlockingRestorePlane: FanControlPlane, @unchecked Sendable {

    private let wrapped: ScriptedControlPlane
    private let held = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var scopes: [FanRestoreScope] = []

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Every scope the restore was asked for, recorded before it blocks.
    var restoreScopes: [FanRestoreScope] { lock.withLock { scopes } }

    /// Lets every blocked restore through. Called once, from the test's own task.
    func release() {
        // One signal per possible waiter. `signal()` on a semaphore nobody is waiting on
        // simply raises its count, so over-signalling is harmless and under-signalling would
        // leave a thread parked past the end of the test — which is the failure mode a
        // blocking double has and a suspending one does not.
        for _ in 0..<8 { held.signal() }
    }

    // MARK: - The blocking verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        lock.withLock { scopes.append(scope) }
        blockThisThreadUntilReleased()
        try await wrapped.restoreToAutomatic(scope)
    }

    /// The block itself, in a synchronous function.
    ///
    /// Not a stylistic split: `DispatchSemaphore.wait()` is `noasync`, so calling it directly
    /// from the `async` verb above does not compile. That annotation exists to stop exactly
    /// what this double is *for* — occupying a cooperative-pool thread — and a synchronous
    /// frame is how the shipped code reaches the same state, because `IOConnectCallStructMethod`
    /// is synchronous too. This is the honest spelling of the hazard rather than a way around
    /// the diagnostic.
    private func blockThisThreadUntilReleased() {
        held.wait()
    }

    // MARK: - Straight delegation

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await wrapped.readControlState(ofFan: index)
    }

    func reconnect() async throws {
        try await wrapped.reconnect()
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}

/// The firmware whose critical-temperature read is held open until a test says otherwise.
///
/// It exists to make one interleaving deterministic: `LeaseAuthority.acquireLease` awaits this
/// read inside `refuseIfBlind`, which is the **last** suspension point before its straight-line
/// region, so a request parked here and resumed after § 4 has emptied the lease table is
/// exactly the race `sleepSeal` closes. Racing the scheduler to produce it would be a test that
/// is green for reasons nobody chose — `AsyncSignal`'s own doc makes the argument.
///
/// `readHasStarted` fires on entry and `letTheReadFinish()` releases it, so a test can say
/// "the request is parked" and "now let it through" as two statements rather than as a sleep.
/// Only the **first** read is held: § 5's watchdog and § 3's supervisor are not started in the
/// test that uses this, but a second read arriving from anywhere must not deadlock a suite.
actor ParkedTelemetryPlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private var hasParked = false

    /// Fires when the first read enters. Awaiting it is how a test knows the request is in
    /// the window rather than merely on its way to it.
    let readHasStarted = AsyncSignal()

    private let mayFinish = AsyncSignal()

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Lets the parked read answer.
    func letTheReadFinish() async {
        await mayFinish.signal()
    }

    // MARK: - The parked verb

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        if !hasParked {
            hasParked = true
            await readHasStarted.signal()
            try await mayFinish.wait()
        }
        return try await wrapped.readCriticalTemperatures(keys)
    }

    // MARK: - Straight delegation

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await wrapped.restoreToAutomatic(scope)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await wrapped.readControlState(ofFan: index)
    }

    func reconnect() async throws {
        try await wrapped.reconnect()
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}
