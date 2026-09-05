import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 4, driven through the **composed** helper with no hardware.
///
/// Every test here builds `HelperComposition` — the same type `AeolusHelperMain` builds — over
/// `ScriptedControlPlane` and a scripted power observer, then delivers `.willSleep` or
/// `.didWake` and asserts what reached the firmware, in what order, and what did not. That is
/// the whole reason `SystemPowerObserving` exists: the production conformer registers with a
/// real power management root and only behaves when a real machine really sleeps, so
/// everything above the seam has to be reachable without one.
///
/// ## What is *not* covered here, stated rather than implied
///
/// `IOKitSystemPowerObserver` itself. No automated test in this project can call
/// `IORegisterForSystemPower` and then make the machine sleep, so its correctness rests on
/// three things instead: the message numbers are derived from the SDK and pinned below rather
/// than written down; the dispatch-queue delivery is the documented alternative to a CFRunLoop
/// source in a `dispatchMain()` daemon; and the lid-close row on the hardware checklist is
/// what finally proves both. A suite that claimed otherwise would be the failure this
/// repository has the most of.
@Suite("§ 4's sleep and wake supervision", .timeLimit(.minutes(1)))
struct SystemPowerTests {

    static let helperLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "SystemPower")

    /// A machine whose one fan is already under manual control at a plausible speed, with
    /// every curated sensor answering — so a lease can be granted over it.
    static func machine(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured
    ) -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: [0: .held(at: 2_400)],
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
            ])
    }

    /// The daemon's graph over a scripted machine and a scripted power observer.
    ///
    /// Generic over the plane so the wedged-firmware test composes the *same* wiring rather
    /// than a paraphrase of it — the argument `HelperRestorerTests` makes at length, and the
    /// one that matters most for a mechanism whose entire content is an ordering.
    static func composed<Plane: FanControlPlane>(
        plane: Plane,
        observer: any SystemPowerObserving,
        budget: Duration = SystemPowerLimits.acknowledgementBudget,
        safetyLog: RecordedLog
    ) -> HelperComposition<Plane> {
        HelperComposition(
            plane: plane,
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            powerObserver: observer,
            acknowledgementBudget: budget,
            log: helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { [safetyLog] in safetyLog.append($0, $1) }))
    }

    // MARK: - Sleep

    /// The restore is on the wire **before** the system is told it may sleep.
    ///
    /// This is the whole of § 4's *"release-before-sleep is the load-bearing half"*, and it is
    /// an ordering rather than an outcome — which is why the assertion is made from **inside**
    /// the acknowledgement rather than after it. Afterwards the two orders are
    /// indistinguishable: the leases are dropped and the restore has landed either way, and a
    /// test that looked at the end state would agree with a helper that acknowledged first and
    /// handed the fans back to a machine that had already stopped running it. The same
    /// argument `RegistryObservingPlane` makes for observing inside a write.
    ///
    /// Both halves of the handback are asserted, because they are different acts:
    /// `.restoreToAutomatic(.fan(0))` is the lease teardown going through `HelperFanRestorer`,
    /// and `.restoreToAutomatic(.everyFan)` is the machine-wide keystone that additionally
    /// clears the Apple Silicon force key.
    ///
    /// **Mutation:** in `SystemPowerResponder.allowSleepAfterHandback(_:)`, move
    /// `await acknowledgement.acknowledge(.handedBack)` above `await handBackEveryFan()`.
    /// Run: red.
    @Test("Sleep hands every fan back before it allows the power change")
    func sleepHandsTheFansBackBeforeAllowingThePowerChange() async throws {
        let plane = Self.machine()
        let witness = AcknowledgementWitness()
        let observer = ScriptedPowerObserver(observing: { await witness.record(plane.attempts) })
        let helper = Self.composed(plane: plane, observer: observer, safetyLog: RecordedLog())

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        let connection = ConnectionID()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        #expect(await helper.leases.leaseCount == 1)

        try await observer.deliver(.willSleep)

        let atAcknowledgement = await witness.attempts
        #expect(
            atAcknowledgement.contains(.restoreToAutomatic(.everyFan)),
            """
            the system was told it may sleep before the machine-wide restore was issued. \
            The fans cross the sleep wherever the lease left them, which is the failure \
            docs/SAFETY.md § 4 calls the load-bearing half.
            """)
        #expect(
            atAcknowledgement.contains(.restoreToAutomatic(.fan(0))),
            "the lease's own fan was not handed back before the acknowledgement")
        #expect(await helper.leases.leaseCount == 0, "a lease survived the sleep")
        #expect(observer.acknowledgements == [.willSleep])
    }

    // MARK: - Wake

    /// Waking writes nothing. Not a re-assert, not a reconciliation, not a read.
    ///
    /// `docs/SAFETY.md` § 4: *"After wake: **nothing.** The helper does not re-assert."*
    /// `SystemPowerResponder` holds a `SafetyActorWriter` and could write — the branch is what
    /// is under test, not a structural impossibility — so this asserts the firmware was not
    /// touched **at all**, rather than that no restore was issued. A reconciliation reads
    /// before it writes, and a test that only counted writes would go green on the half of it
    /// that runs first.
    ///
    /// The supervisors are deliberately not started: three 1 Hz loops over the same scripted
    /// firmware would put reads in `attempts` that have nothing to do with waking, and an
    /// assertion that had to allow for them could not say "nothing".
    ///
    /// **Mutation:** in `SystemPowerResponder.respond(to:)`, replace the `.didWake` branch's
    /// body with `await handBackEveryFan()`. Run: red.
    @Test("Waking writes nothing at all")
    func wakingWritesNothingAtAll() async throws {
        let plane = Self.machine()
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = Self.composed(plane: plane, observer: observer, safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()
        #expect(await plane.attempts.isEmpty, "the fixture touched the firmware before waking")

        try await observer.deliver(.didWake)

        #expect(
            await plane.attempts.isEmpty,
            """
            the helper touched the firmware on wake. § 4 forbids a write of any kind there, \
            and a read is how a reconciliation starts: what it reads it acts on.
            """)
        #expect(log.lines(containing: "System woke").count == 1)
        #expect(log.faults.isEmpty, "waking is not a fault")
    }

    // MARK: - The budget

    /// A restore that never lands cannot hold the machine awake.
    ///
    /// The case is real and is named in `FanRestoreAttempting`: a synchronous IOKit call that
    /// never returns on a wedged connection ([#68](https://github.com/blamechris/Aeolus/issues/68))
    /// parks its caller, and `BoundedFanRestorer` deliberately makes each attempt
    /// uncancellable, so nothing below § 4 can bound it. Five seconds in production; fifty
    /// milliseconds here, because what is under test is the bound rather than its size.
    ///
    /// The delivery is spawned rather than awaited, and that is the point rather than a
    /// convenience: the handback is still parked when this test finishes asserting, exactly as
    /// it would be on a wedged machine. What must have happened is the *acknowledgement*, and
    /// that is what is awaited.
    ///
    /// **Mutation:** delete the `let budget = Task { … }` block from
    /// `SystemPowerResponder.allowSleepAfterHandback(_:)` (and the `budget.cancel()` that
    /// follows). Run: red, on the suite's time limit — nothing acknowledges, ever.
    @Test("A handback that never returns still lets the machine sleep, and says so")
    func theAcknowledgementIsBoundedByItsBudget() async throws {
        let plane = WedgedRestorePlane(Self.machine())
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = Self.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        let delivery = try observer.deliverWithoutWaiting(.willSleep)
        try await observer.didAcknowledge.wait()

        #expect(observer.acknowledgements == [.willSleep])
        #expect(
            await plane.restoreScopes == [.everyFan],
            "the keystone restore was never issued, so the budget bounded nothing")
        #expect(
            log.faults.contains { $0.contains("handback still outstanding") },
            """
            the system was allowed to sleep on the budget without a fault-level line. \
            A bound that is not reported is indistinguishable from a handback that worked.
            """)

        // Let the wedged write finish, so nothing is left parked behind this test — and so
        // the late `.handedBack` proves `SleepAcknowledgement` really is once-only.
        await plane.release()
        await delivery.value
        #expect(observer.acknowledgements == [.willSleep], "the system was acknowledged twice")
    }

    // MARK: - Supervisors

    /// Neither event stops or starts a supervisor.
    ///
    /// Decision A5, and the reason it is a decision: stopping § 3 or § 5 around a sleep would
    /// put this issue's correctness downstream of
    /// [#131](https://github.com/blamechris/Aeolus/issues/131) and
    /// [#144](https://github.com/blamechris/Aeolus/issues/144), which are about a supervisor
    /// that does not come back. § 4 removes the exposure instead of depending on their fixes.
    ///
    /// `SystemPowerResponder` is handed no supervisor at all, so the composition root is where
    /// a lifecycle event could reach one — which is where the mutation goes.
    ///
    /// **Mutation:** in `HelperComposition.observeSystemPower()`, capture
    /// `let supervisor = thermalSupervisor` and add
    /// `if notification.event == .willSleep { await supervisor.stop() }` to the observing
    /// closure. Run: red.
    @Test("Sleep and wake leave every supervisor exactly as they found it")
    func neitherSleepNorWakeTouchesASupervisor() async throws {
        let observer = ScriptedPowerObserver()
        let helper = Self.composed(
            plane: Self.machine(), observer: observer, safetyLog: RecordedLog())

        await helper.bringUp()
        #expect(await helper.thermalSupervisor.isRunning)
        #expect(await helper.reclamationSupervisor.isRunning)
        #expect(await helper.leaseExpirySupervisor.isRunning)

        try await observer.deliver(.willSleep)

        #expect(await helper.thermalSupervisor.isRunning, "§ 3 stopped when the machine slept")
        #expect(await helper.reclamationSupervisor.isRunning, "§ 5 stopped when the machine slept")
        #expect(
            await helper.leaseExpirySupervisor.isRunning,
            "§ 1's TTL loop stopped when the machine slept, and the TTL is § 4's own backstop")

        try await observer.deliver(.didWake)

        #expect(await helper.thermalSupervisor.isRunning, "§ 3 stopped when the machine woke")
        #expect(await helper.reclamationSupervisor.isRunning, "§ 5 stopped when the machine woke")
        #expect(await helper.leaseExpirySupervisor.isRunning, "§ 1's TTL loop stopped on wake")

        await helper.shutDown()
    }

    // MARK: - Wiring

    /// The daemon's bring-up is what points § 4 at the system.
    ///
    /// Behavioural rather than a source tripwire, because there is a seam to observe it
    /// through — which is the whole reason `SystemPowerObserving` exists.
    /// `HelperCompositionTests` covers the half no runtime can see: that `bringUp()` completes
    /// before `listener.resume()` advertises the Mach service.
    ///
    /// **Mutation:** delete `observeSystemPower()` from `HelperComposition.bringUp()`. Run:
    /// red.
    @Test("Bring-up installs the power observer")
    func bringUpInstallsThePowerObserver() async throws {
        let observer = ScriptedPowerObserver()
        let helper = Self.composed(
            plane: Self.machine(), observer: observer, safetyLog: RecordedLog())

        #expect(observer.isObserving == false, "nothing may observe before bring-up")

        await helper.bringUp()

        #expect(
            observer.isObserving,
            """
            nothing is listening for a sleep, so no fan is handed back before one — and \
            § 1's TTL is the only path back, silently.
            """)

        await helper.shutDown()
    }

    /// A helper that cannot register for power events still comes up.
    ///
    /// The one bring-up step allowed to fail. Every other one is a precondition of serving a
    /// client at all — decision A1's rule that a hung bring-up serves nothing is the fail-safe
    /// direction — and this one is not: § 4 improves on § 1's TTL rather than replacing it, so
    /// a daemon that cannot hear the system is strictly better running than not. What it may
    /// not do is fail quietly.
    ///
    /// **Mutation:** replace the `catch` body in `HelperComposition.observeSystemPower()` with
    /// nothing. Run: red on the fault.
    @Test("A refused power registration is a logged fault, not a failed bring-up")
    func aRefusedRegistrationIsLoggedAndSurvived() async throws {
        let log = RecordedLog()
        let helper = Self.composed(
            plane: Self.machine(), observer: RefusingPowerObserver(), safetyLog: log)

        await helper.bringUp()

        #expect(await helper.thermalSupervisor.isRunning, "bring-up did not complete")
        #expect(
            log.faults.contains { $0.contains("Could not register for system power") },
            """
            the helper cannot hear a sleep and said nothing about it. Nothing will hand the \
            fans back before this machine sleeps and the log gives no reason.
            """)

        await helper.shutDown()
    }

    // MARK: - The message numbers

    /// The three IOKit message numbers § 4 keys on are the ones `IOKit/IOMessage.h` documents.
    ///
    /// They cannot be imported — the header spells each as a macro over two further macros, and
    /// Swift reports *"macro unavailable: structure not supported"* — so `SystemPowerMessage`
    /// recovers the shared base from `kIOReturnError`, which is built by the same composition
    /// and does import. This pins the arithmetic against the values the header's own
    /// `iokit_common_msg(0x270 / 0x280 / 0x300)` produce.
    ///
    /// It is **not** circular: the derivation reads the SDK and the expectation is written
    /// out, so a wrong base, a wrong message number, or an SDK that changed the composition
    /// all fail here. What it cannot prove is that the kernel still *sends* these — no test
    /// can, without sleeping the machine, which is the lid-close hardware row.
    ///
    /// **Mutation:** change `systemWillSleep`'s message number from `0x280` to `0x290`
    /// (`kIOMessageSystemWillNotSleep`, one line away in the same header). Run: red — and
    /// green everywhere else in the repository, which is the whole reason this test is here.
    @Test("The power message numbers are the ones IOMessage.h documents")
    func theMessageNumbersAreTheOnesIOKitSends() {
        #expect(SystemPowerMessage.base == 0xE000_0000)
        #expect(SystemPowerMessage.canSystemSleep == 0xE000_0270)
        #expect(SystemPowerMessage.systemWillSleep == 0xE000_0280)
        #expect(SystemPowerMessage.systemHasPoweredOn == 0xE000_0300)
    }
}

// MARK: - Doubles

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

    private let observing: @Sendable () async -> Void

    init(observing: @escaping @Sendable () async -> Void = {}) {
        self.observing = observing
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
            await observing()
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
    private(set) var acknowledgements = 0

    func record(_ attempts: [ScriptedControlPlane.Attempt]) {
        if acknowledgements == 0 { self.attempts = attempts }
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
