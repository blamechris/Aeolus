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

    /// The lease table is empty at the acknowledgement, and the fan left behind is refused.
    ///
    /// Two properties of the same wedged sleep, asserted together because they are the two
    /// halves of what § 4 owes a fan whose handback never lands.
    ///
    /// **The ordering.** `handBackEveryFan()` drops every lease *before* it issues the
    /// keystone, and that was documented as load-bearing while nothing pinned it: swapping the
    /// two statements left the whole suite green, and on a wedged connection the swapped
    /// version sleeps the machine with every lease live and every fan in manual. So the lease
    /// count is read from **inside** the acknowledgement, exactly as the plane's attempts are
    /// in `sleepHandsTheFansBackBeforeAllowingThePowerChange` — afterwards is useless, because
    /// on a wedged connection the responder never gets there at all.
    ///
    /// **The abandonment.** Decision D17. When the budget wins there is no lease left to
    /// expire — the same function destroyed it — so § 1's TTL cannot be the backstop the log
    /// line used to name. What survives instead is the durable `.restoreToAutomaticFailed`
    /// refusal, recorded before the system is told it may sleep. It is asserted **after** the
    /// wedge is released and the wake delivered, which is the whole point of the word durable:
    /// the restore landing late does not undo it, and neither does the sleep ending.
    ///
    /// The lease's own fan is what wedges here, not the keystone, which is why `restoreScopes`
    /// is `[.fan(0)]` rather than `[.everyFan]` — the keystone is not reached until the wedge
    /// lets go. That is the honest shape of a machine whose `io_connect_t` went stale while a
    /// client held a fan.
    ///
    /// **Mutation A:** in `handBackEveryFan()`, move `await leases.releaseEveryLease()` below
    /// the `do { try await writer.restoreToAutomatic(.everyFan) … }` block. Run: red on the
    /// lease count.
    /// **Mutation B:** delete `let abandoned = await leases.abandonOutstandingHandbacks()` from
    /// `SleepAcknowledgement.acknowledge(_:)`'s `.budgetExpired` branch, passing `[]` to the
    /// log line instead. Run: red on the refusal.
    @Test("A wedged handback drops the lease first and records the fan as abandoned")
    func aWedgedHandbackDropsTheLeaseFirstAndRecordsTheFanAsAbandoned() async throws {
        let plane = WedgedRestorePlane(Self.machine())
        let observer = ScriptedPowerObserver()
        let witness = AcknowledgementWitness()
        let log = RecordedLog()
        let helper = Self.composed(
            plane: plane, observer: observer, budget: .milliseconds(50), safetyLog: log)
        observer.whenAcknowledging { [leases = helper.leases] in
            await witness.record(leaseCount: leases.leaseCount)
        }

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(await helper.leases.leaseCount == 1)

        let delivery = try observer.deliverWithoutWaiting(.willSleep)
        try await observer.didAcknowledge.wait()

        #expect(
            await witness.leaseCount == 0,
            """
            the system was told it may sleep with a lease still live. The keystone restore \
            preceded the lease teardown, and on a wedged connection that means every fan \
            crosses the sleep in manual with a client still holding them.
            """)
        #expect(
            await plane.restoreScopes == [.fan(0)],
            "the lease's own fan is what wedged, so the keystone cannot have been reached yet")
        #expect(
            log.faults.contains { $0.contains("handback still outstanding") },
            "the system was allowed to sleep on the budget without a fault-level line")

        // The wedge lets go and the machine wakes: the two events that would undo this
        // refusal if it were transient. The expectation below is what says it is not.
        await plane.release()
        await delivery.value
        try await observer.deliver(.didWake)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed),
            """
            a fan whose handback was still outstanding when the machine slept can be leased \
            again. Nothing confirmed it went back to automatic control, so a lease over it is \
            CLAUDE.md rule 6 — claiming control nothing is honouring.
            """
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    /// The budget also beats a restore that *blocks* rather than suspends.
    ///
    /// `WedgedRestorePlane` parks on `try await held.wait()`, which yields its thread — and a
    /// review was right that this is not #68's shape. A stale `io_connect_t` is stuck inside
    /// `IOConnectCallStructMethod`, a synchronous kernel call, so the task holding it occupies
    /// a cooperative-pool thread and gives nothing back. A budget that beat only the
    /// cooperative version would be proving something weaker than the doc comment claimed.
    ///
    /// This is the same episode against `ThreadBlockingRestorePlane`. What it demonstrates is
    /// that the acknowledgement does not need the blocked thread: the budget runs on a task of
    /// its own, and `BoundedFanRestorer` already puts each attempt in a task of its own, so the
    /// block lands where it would in production rather than on the actor that has to answer.
    ///
    /// It still cannot prove the case on a machine whose whole cooperative pool is occupied,
    /// and no test can — that is the lid-close hardware row against
    /// [#68](https://github.com/blamechris/Aeolus/issues/68), and the doc comments now say so
    /// rather than implying this covers it.
    ///
    /// **Mutation:** delete the `let budget = Task { … }` block and the `budget.cancel()` that
    /// follows, from `SystemPowerResponder.allowSleepAfterHandback(_:)`. Run: red, on the
    /// suite's time limit.
    @Test("The budget lands even when the restore blocks its thread instead of suspending")
    func theBudgetSurvivesARestoreThatBlocksItsThread() async throws {
        let plane = ThreadBlockingRestorePlane(Self.machine())
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
            plane.restoreScopes == [.everyFan],
            "the keystone restore was never issued, so the budget bounded nothing")
        #expect(
            log.faults.contains { $0.contains("handback still outstanding") },
            """
            a restore that occupied its thread let the machine sleep without the fault line. \
            That is the case #68 actually produces, and it is the one an operator will read.
            """)

        plane.release()
        await delivery.value
        #expect(observer.acknowledgements == [.willSleep], "the system was acknowledged twice")
    }

    /// A firmware that refuses the restore still lets the machine sleep, and says so.
    ///
    /// The `catch` in `handBackEveryFan()` is the **only** branch of § 4's write path that
    /// executes on a build with no SMC write path — every shipped helper today takes it, on
    /// every sleep, with `controlPathNotBuilt` — and it had no test: emptying its body left the
    /// whole suite green and took with it the one line saying the pre-sleep handback did not
    /// land.
    ///
    /// Two claims, and the second is the one worth having: the fault is written, **and** the
    /// refusal does not hold the sleep open. A helper that treated a refused restore as a
    /// reason to keep waiting would be answering a question `docs/SAFETY.md` § 4 gives it no
    /// authority to answer.
    ///
    /// **Mutation:** replace the `catch` body in `handBackEveryFan()` with nothing. Run: red.
    @Test("A refused restore still lets the machine sleep, and says it did not land")
    func aRefusedRestoreStillLetsTheMachineSleep() async throws {
        let plane = Self.machine(writes: .refused(reason: "the firmware would not take it"))
        let observer = ScriptedPowerObserver()
        let log = RecordedLog()
        let helper = Self.composed(plane: plane, observer: observer, safetyLog: log)

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        try await observer.deliver(.willSleep)

        #expect(
            observer.acknowledgements == [.willSleep],
            """
            a refused restore either held the sleep open or answered the system twice. \
            Neither is § 4's to do: the kernel sleeps the machine on its own timeout, and \
            this process learns less by being cut off than by giving up deliberately.
            """)
        #expect(
            log.faults.contains { $0.contains("did not land") },
            """
            the machine-wide restore was refused and nothing said so at fault level. On a \
            build with no write path that is every sleep, so a reader would see a helper \
            that handed the fans back when it could not.
            """)
        #expect(
            log.levels(containing: "did not land") == [.fault],
            """
            the line is there but not at the level SafetyLog reserves for a write on its \
            path that did not land.
            """)
    }

    // MARK: - The sleep window

    /// A lease request already in flight when the sleep arrives is refused, not granted.
    ///
    /// This is the window nothing else in § 4 closes, driven as the race it is rather than as a
    /// property of a flag. `acquireLease` parks on `refuseIfBlind`'s 34-key telemetry read — a
    /// real suspension point in the shipped method, and the last one before its straight-line
    /// region — and the sleep is delivered *while it is parked*. When the read finally answers,
    /// the table is empty, no fan is mid-handback and every other refusal in that region has
    /// nothing to say: without the seal the grant proceeds, and a client engages manual control
    /// on a machine that has already been told it may stop running this process.
    ///
    /// `ParkedTelemetryPlane` makes the interleaving deterministic rather than likely, which is
    /// the standing rule for the concurrency tests here — a test that had to win a race in
    /// order to set up a race is green for reasons nobody chose.
    ///
    /// The wake half is asserted in the same test on purpose. A seal that is never cleared
    /// refuses every lease for the life of the process, which is safe and useless; the pair is
    /// the mechanism.
    ///
    /// **Mutation:** delete the `guard !sleepSeal` block from `LeaseAuthority.acquireLease`.
    /// Run: red — the parked request is granted.
    @Test("A lease request parked across the sleep is refused until the machine wakes")
    func aLeaseParkedAcrossTheSleepIsRefusedUntilTheWake() async throws {
        let plane = ParkedTelemetryPlane(Self.machine())
        let observer = ScriptedPowerObserver()
        let helper = Self.composed(plane: plane, observer: observer, safetyLog: RecordedLog())

        await helper.bindSafetyRegistries()
        helper.observeSystemPower()

        let parked = Task { [leases = helper.leases] in
            try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        try await plane.readHasStarted.wait()

        try await observer.deliver(.willSleep)
        await plane.letTheReadFinish()

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .systemSleeping),
            """
            a lease was granted over a fan on a machine that has already been told it may \
            sleep. § 4 handed every fan back before this request resumed, so nothing will \
            hand this one back — the fan crosses the sleep pinned, by the one path § 4's \
            ordering cannot cover.
            """
        ) {
            _ = try await parked.value
        }

        try await observer.deliver(.didWake)

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(
            await helper.leases.leaseCount == 1,
            """
            the machine woke and manual control is still refused. The seal is a window, not a \
            latch: a helper that never reopened it would refuse every lease for the rest of \
            its life on the strength of one sleep.
            """)
    }

    // MARK: - The bound itself

    /// Five seconds is inside the kernel's window, and this is what says so.
    ///
    /// `SystemPowerLimits.acknowledgementBudget`'s whole argument is that it *keeps the
    /// decision this helper's own*: the kernel gives a process on the order of thirty seconds
    /// to acknowledge `kIOMessageSystemWillSleep` and then sleeps regardless, so a budget at or
    /// past that window is not a bound at all — the timeout that fires first is one this
    /// process cannot see, learns nothing from and writes no line about. Nothing pinned that,
    /// so raising the constant to ten minutes left the suite green while the mechanism stopped
    /// being one.
    ///
    /// The lower bound is asserted too, and it is not ceremony: a zero budget expires before
    /// the handback can start, which turns the `.fault` line into noise on healthy machines and
    /// makes the D17 abandonment refuse every fan on every sleep.
    ///
    /// **Mutation:** `static let acknowledgementBudget: Duration = .seconds(600)`. Run: red.
    @Test("The acknowledgement budget sits inside the kernel's own sleep window")
    func theBudgetSitsInsideTheKernelsWindow() {
        #expect(
            SystemPowerLimits.acknowledgementBudget < .seconds(30),
            """
            the budget is at or past the ~30 s the kernel allows before sleeping regardless, \
            so the first timeout to fire is one this helper cannot see. A bound overtaken by \
            the thing it was measured against bounds nothing.
            """)
        #expect(
            SystemPowerLimits.acknowledgementBudget > .zero,
            "a budget of zero expires before the handback can begin, on every sleep")
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

    /// A graph composed with no observer says so, rather than returning silently.
    ///
    /// `observeSystemPower()`'s `guard let powerObserver else { return }` was the third of the
    /// three states its own doc comment claims are distinguishable — observing, refused,
    /// absent — and it was the one with no line at all: a helper built without § 4 read in
    /// `log show` exactly like one whose registration succeeded. That is the "fails silently
    /// and completely" shape this file's header names as the reason the IOKit message numbers
    /// are derived rather than written down, one layer up and with a worse consequence, since
    /// the message numbers at least have a test.
    ///
    /// `.fault` and not `.notice`, deliberately: the consequence is identical to a refused
    /// registration — nothing hands the fans back before a sleep — and a quieter level would
    /// make the *absence* of the mechanism the one state that does not announce itself.
    ///
    /// **Mutation:** replace the `guard`'s body with a bare `return`. Run: red.
    @Test("A helper composed with no power observer says so at fault level")
    func aMissingPowerObserverIsAFaultRatherThanASilentReturn() async throws {
        let log = RecordedLog()
        let helper = HelperComposition(
            plane: Self.machine(),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            log: Self.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { [log] in log.append($0, $1) }))

        helper.observeSystemPower()

        #expect(
            log.faults.contains { $0.contains("no system power observer") },
            """
            a graph with no way to hear a sleep came up saying nothing about it. Nothing \
            will return the fans to automatic control before this machine sleeps, and \
            neither CI nor log show can tell that state from a working one.
            """)
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
