import Foundation

/// What the orderly teardown managed to do, and therefore what the process exits with.
///
/// The exit code is a **contract with launchd**, not a diagnostic.
/// [#103](https://github.com/blamechris/Aeolus/issues/103)'s decision A3 pairs
/// `KeepAlive = { SuccessfulExit = false }` with this enum: a teardown that put the fans
/// back is finished and must not be restarted, and one that could not is a machine with a
/// fan possibly still off automatic control, which is exactly the case where the helper
/// should come back and reconcile. Naming the outcomes rather than passing an `Int32` around
/// keeps that pairing readable at both ends.
///
/// ## Why "nothing to restore" is a third case and not a fourth reading of the other two
///
/// Ruling D15 on [#197](https://github.com/blamechris/Aeolus/pull/197): a
/// `FanControlPlaneError.controlPathNotBuilt` refusal of the keystone is **proof there was
/// nothing to hand back**, not a failed handback. A build with no write path cannot have put
/// a fan into manual — `LeaseAuthority` refuses every grant on `writeCapability`, and
/// `SMCFanControlPlane` throws before touching IOKit — so exiting non-zero would only make
/// #165's `SuccessfulExit = false` restart the helper after every `launchctl bootout` or app
/// quit on a pre-E3 build. It carries the *same exit code* as `.restored` and a *different
/// name*, because the two say different things to a reader of `log show` and the same thing
/// to launchd.
///
/// The distinction is sourced from the thrown error case and never from `writeCapability` or
/// a literal: consulting the capability would reintroduce the `FanWriteCapability` literal
/// that type was created to delete, and it would survive into the E3/E4 build where the same
/// refusal means something entirely different.
///
/// The raw-value backing is gone with it. Two cases cannot share a raw value, and the exit
/// code is not an identity — it is a mapping, and `exitCode` is where it lives so that a
/// test can execute it. See `TeardownExit`.
enum TeardownOutcome: Sendable, Hashable, CaseIterable {

    /// Every lease released and `restoreToAutomatic(.everyFan)` accepted by the firmware.
    case restored

    /// The keystone was refused with `.controlPathNotBuilt`: this build has no write path,
    /// so no fan can be off automatic control because of Aeolus. Zero, deliberately.
    case nothingToRestore

    /// The machine-wide restore threw something else. Non-zero, deliberately.
    case restoreFailed

    /// The code the process ends with, and the whole of A3's launchd contract.
    ///
    /// A pure function of the outcome rather than a `switch` inside the terminating closure,
    /// for one reason: a closure whose body calls `exit` cannot be executed by a test, so a
    /// mapping written there is a contract nothing can check. Inverting this switch reddens
    /// `theOutcomesCarryTheExitCodesTheRestartPolicyReads`.
    var exitCode: Int32 {
        switch self {
        case .restored, .nothingToRestore: 0
        case .restoreFailed: 1
        }
    }
}

/// The **only** place in `Sources/AeolusHelper` that ends the process.
///
/// A3 makes a zero exit mean one specific thing — *the orderly teardown ran and no fan is
/// left off automatic control by Aeolus* — so it may be reached on one path and nowhere
/// else. `SignalTeardownTests` asserts that at the source, because a second `exit` added
/// anywhere would still compile, still pass every behavioural test, and quietly tell launchd
/// not to restart a helper that never restored anything.
///
/// ## Nothing here to invert
///
/// The body is one expression. It used to be a `switch` over the outcome, which is the whole
/// of A3's contract written in the one place a test cannot execute: `exit` returns `Never`,
/// so a suite that ran this closure would end the `swift test` process, and inverting the
/// switch therefore survived every test in the repository. The mapping now lives on
/// `TeardownOutcome.exitCode`, which is a pure function under test, and what is left here is
/// a call with no branch in it. The tripwire in `SignalTeardownTests` keeps it that way: this
/// is the only file under `Sources/AeolusHelper` that may name `exit`, and no literal exit
/// code may be written anywhere, because a literal is a second mapping competing with the
/// one above.
///
/// It is a value rather than a function so that it can be the default argument of
/// `SignalTeardown.init`, and so a test can substitute a recorder for it. In the shipping
/// daemon nothing after the terminate call in `SignalTeardown.run(stoppingSupervisorsWith:)`
/// runs at all; under a recorder it returns, which is what lets a test observe the exit as an
/// ordered event beside the restores rather than by inspecting a return value.
enum TeardownExit {

    /// Ends the process with the code `outcome` names.
    static let process: @Sendable (TeardownOutcome) async -> Void = { exit($0.exitCode) }
}

/// Where the signals come from, so the handler body can be run without raising one.
///
/// A test that had to `kill` its own process to exercise the teardown would be a test that
/// cannot assert anything afterwards. A4 asks for the seam by name — *"driven through an
/// injectable signal source so a test invokes the handler body directly"* — and this is it:
/// `DispatchSignalSources` is the daemon's, and a recording double is what the suite
/// installs so that `swift test` never changes the disposition of a signal in its own
/// process.
protocol SignalSourcing: Sendable {

    /// Arranges for `handler` to run, in normal execution context, whenever any of
    /// `signals` is delivered.
    func serve(_ signals: [Int32], with handler: @escaping @Sendable () -> Void) async
}

/// The two seams the orderly teardown needs in order to be exercisable at all, in one
/// parameter so the composition root grows one line rather than two.
///
/// Both defaults are the shipping ones, and both have to be overridable for the same blunt
/// reason: `HelperComposition.bringUp()` installs the teardown, tests call `bringUp()`, and
/// the production pair would replace the disposition of `SIGTERM` in the `swift test`
/// process and then end it with the successful-exit call when anything fired. A seam that
/// only production can supply is a mechanism only production can run.
struct TeardownSeams: Sendable {

    /// Where the three orderly signals come from.
    let sources: any SignalSourcing

    /// What ends the process. `TeardownExit.process` in every shipping build.
    let terminate: @Sendable (TeardownOutcome) async -> Void

    init(
        sources: any SignalSourcing = DispatchSignalSources(),
        terminate: @escaping @Sendable (TeardownOutcome) async -> Void = TeardownExit.process
    ) {
        self.sources = sources
        self.terminate = terminate
    }
}

/// The daemon's signal sources: each signal ignored, then served by a `DispatchSourceSignal`.
///
/// ## Why the signal is ignored first
///
/// `signal(_, SIG_IGN)` replaces the *default disposition*, which for `SIGTERM`, `SIGINT`
/// and `SIGHUP` is to terminate the process immediately. Without it the kernel would kill
/// the helper before a `DispatchSourceSignal` ever ran, because the source observes delivery
/// rather than intercepting it. `SIG_IGN` is also what keeps the handler body out of signal
/// context: the block below runs on an ordinary dispatch queue, where `IOConnectCallStructMethod`,
/// a lock and a heap allocation are all legal — none of which is true of a `sigaction`
/// handler, which is the correction `docs/SAFETY.md` § 6 records against its own first draft.
///
/// ## Why the sources are kept
///
/// A `DispatchSourceSignal` released by ARC is cancelled, so a source nobody holds is a
/// signal nobody serves — and the failure is silent, at exactly the moment the machine is
/// shutting down. They live here, in an actor `HelperComposition` holds for the life of the
/// process, rather than in a local of the function that installed them.
///
/// ## Why a private queue rather than the main one
///
/// `AeolusHelperMain.main()` ends in `dispatchMain()`, so the main queue is where the
/// listener's own work lands. A teardown that had to queue behind an in-flight snapshot —
/// ~0.5 s of subset reads on this machine — would be spending the window launchd gives it
/// before `SIGKILL` waiting on a client's request. A serial queue of its own costs one
/// thread and removes that coupling entirely.
actor DispatchSignalSources: SignalSourcing {

    private let queue = DispatchQueue(label: "dev.aeolus.AeolusHelper.signals")

    /// Held, not observed. See the note above on ARC and cancellation.
    private var sources: [any DispatchSourceSignal] = []

    func serve(_ signals: [Int32], with handler: @escaping @Sendable () -> Void) async {
        for number in signals {
            // The result is the previous disposition, which nothing here restores: this
            // daemon's only orderly exit is through the handler being installed.
            _ = signal(number, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }
}

/// `docs/SAFETY.md` § 6's orderly exit path: gate, release, restore, stop, exit.
///
/// ## The order is the design, and every step of it is A4's
///
/// 1. **Close the control gate.** New `acquireLease`, `renewLease` and `apply` messages are
///    refused from here on. The Mach service stays advertised — nothing in `Sources/`
///    un-advertises it — so without this a client could take a lease *after* the release
///    below had emptied the table, and hold fans in a process that has stopped counting a
///    TTL for them.
/// 2. **`LeaseAuthority.releaseEveryLease()`.** The lease core's own teardown: the table is
///    emptied synchronously and each dropped lease's fans then go back through
///    `HelperFanRestorer`, so both safety registries are told rather than left describing a
///    machine that has moved.
/// 3. **`restoreToAutomatic(.everyFan)`, unconditionally.** ADR 0007's keystone at its
///    widest. It takes no reading, no bound and no lease, so there is nothing for a helper
///    on its way out to fail to gather — which is the whole reason the keystone is defined
///    the way it is. It covers what step 2 cannot: a fan engaged by a lease granted in the
///    gap between the gate closing and the release (the gate covers arrival, not flight),
///    and a fan the previous process left behind.
/// 4. **Stop the supervisors**, after the writes rather than before them. A supervisor
///    stopped first is § 3 and § 5 not watching while the last two writes of the process's
///    life are issued.
/// 5. **Re-issue the keystone, and take the exit code from *that* write.** Ruling D19 on
///    [#197](https://github.com/blamechris/Aeolus/pull/197). `stop()` cancels the three
///    supervisors; it does not await a cycle already in flight. A § 3 fire or a § 5
///    re-assert that began before step 4 can therefore land its `engageManualControl` write
///    *after* step 3 has run, and the process would then exit `0` — "every fan is back" —
///    over a fan it had just put into manual. The keystone takes no reading, no bound and no
///    lease, so re-issuing it is idempotent and cheap, and it narrows the window — a write
///    landing between this restore and the exit is still possible — without reordering
///    anything A4 fixed. Step 3 is not redundant with it: a restore issued only
///    after the supervisors stop is a restore that has not happened while § 3 and § 5 are
///    still running, which is the ordering step 4's own paragraph exists to protect.
/// 6. **Exit**, `0` if the final restore landed or there was nothing to restore, and
///    non-zero if it failed. See `TeardownOutcome`.
///
/// ## What this build actually does today, said plainly
///
/// `SMCFanControlPlane.restoreToAutomatic(_:)` throws `.controlPathNotBuilt` unconditionally,
/// so on the shipping helper the keystone is refused by the *build* rather than by the
/// firmware — and ruling D15 is that this is `.nothingToRestore` and **exits `0`**. The
/// argument is `TeardownOutcome`'s and is not repeated here; the consequence is worth stating
/// plainly, because the previous draft of this paragraph promised the opposite. Once #165
/// lands `KeepAlive = { SuccessfulExit = false }`, `kill -TERM` on today's helper lets it
/// stay down, exactly as `launchctl bootout` does, rather than restarting a helper that had
/// nothing to hand back. Any *other* refusal — a firmware that says no on an E3 build — is
/// still non-zero, and is still the case where launchd should bring the helper back so that
/// reconciliation can clear whatever is left in manual.
///
/// ## No crash handler, no mach exception port, no `atexit`
///
/// Deliberately absent, and `SignalTeardownTests` fails if any of the three appears.
/// `SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGABRT`/`SIGFPE` get nothing: a crash is exactly when heap
/// and lock state are unknown, and § 6 already rules that crash coverage is restart plus
/// reconciliation. `atexit` is ruled out for a *different* reason and the two are worth not
/// conflating — an `atexit` body is synchronous, every step above is `async`, and the only
/// way to bridge that is to block an exiting process on a semaphore. ADR 0007 permitted the
/// belt when it was written; the amendment in that ADR records why it may not stay.
actor SignalTeardown<Plane: FanControlPlane> {

    /// The three orderly signals, and only those. A4 names them; `SIGQUIT` is a crash signal
    /// by convention and is not one of them.
    ///
    /// Computed rather than stored because Swift has no static stored properties in a
    /// generic type.
    static var served: [Int32] { [SIGTERM, SIGINT, SIGHUP] }

    private let gate: ControlMessageGate
    private let leases: LeaseAuthority

    /// The keystone write, at § 7's level. `.panicRestore` is the highest-precedence
    /// ungoverned actor there is, which is the right provenance for the last write of the
    /// process's life — and, as `HelperComposition` records of the lease core's own writer,
    /// it is provenance nothing currently *reads*: `SafetyArbiter` is not consulted by a
    /// restore. Whoever makes the arbiter govern restores inherits both notes at once.
    private let restore: SafetyActorWriter<Plane>

    private let seams: TeardownSeams
    private let log: HelperLog

    /// Whether a teardown has already started. Read and set with no `await` between them,
    /// which is what makes the guard atomic on an otherwise reentrant actor.
    private var hasBegun = false

    init(
        gate: ControlMessageGate,
        leases: LeaseAuthority,
        restore: SafetyActorWriter<Plane>,
        seams: TeardownSeams = TeardownSeams(),
        log: HelperLog = HelperLog()
    ) {
        self.gate = gate
        self.leases = leases
        self.restore = restore
        self.seams = seams
        self.log = log
    }

    /// Serves the three orderly signals with `run(stoppingSupervisorsWith:)`.
    ///
    /// The supervisors are supplied here rather than at construction because the thing that
    /// stops them is `HelperComposition.shutDown()`, and the composition cannot hand itself
    /// to something it is in the middle of building. The closure and this actor then retain
    /// each other for the life of the process, which is the same deliberate immortality the
    /// signal sources have: the only path out of this process runs through the handler being
    /// installed, so there is nothing here that may be deallocated.
    func install(stoppingSupervisorsWith stop: @escaping @Sendable () async -> Void) async {
        await seams.sources.serve(Self.served) { [self] in
            // The one bridge from a synchronous handler to an `async` teardown. The body
            // does nothing but hand off, which is the property `WriteVerbAllowlistTests`
            // requires of every unstructured `Task` in this target.
            Task { await self.run(stoppingSupervisorsWith: stop) }
        }
    }

    /// The handler body. Idempotent, and safe to call directly — which is how it is tested.
    ///
    /// The second signal is dropped rather than served. `SIGTERM` followed by `SIGINT` is an
    /// ordinary thing for a dying daemon to receive, and two teardowns racing would run
    /// `releaseEveryLease()` and the keystone write concurrently and then call `exit` twice.
    /// The first one already restores every fan, so the second has nothing to add.
    func run(stoppingSupervisorsWith stop: @Sendable () async -> Void) async {
        guard !hasBegun else {
            log.teardownAlreadyRunning()
            return
        }
        hasBegun = true

        await gate.close()
        await leases.releaseEveryLease()

        // Step 3. Its outcome is logged and deliberately not returned: the exit code comes
        // from the write below, after the supervisors have stopped writing.
        _ = await keystone()

        await stop()

        // Step 5, ruling D19. The one whose answer launchd reads.
        let outcome = await keystone()
        log.teardownFinished(outcome: outcome)
        await seams.terminate(outcome)
    }

    /// `restoreToAutomatic(.everyFan)`, and what its answer means for the exit code.
    ///
    /// The `.controlPathNotBuilt` clause is ruling D15's, and it is sourced from the thrown
    /// case: this is a build with no write path, so the refusal is proof there is nothing to
    /// hand back rather than a failure to hand it back. Consulting `writeCapability` here
    /// instead would be the `FanWriteCapability` literal all over again, and it would still
    /// be here on the E3 build where the same refusal means the firmware said no.
    private func keystone() async -> TeardownOutcome {
        do {
            try await restore.restoreToAutomatic(.everyFan)
            return .restored
        } catch FanControlPlaneError.controlPathNotBuilt {
            log.teardownFoundNothingToRestore()
            return .nothingToRestore
        } catch {
            log.teardownRestoreFailed(detail: String(describing: error))
            return .restoreFailed
        }
    }
}
