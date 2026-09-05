import Foundation

/// What the orderly teardown managed to do, and therefore what the process exits with.
///
/// The exit code is a **contract with launchd**, not a diagnostic.
/// [#103](https://github.com/blamechris/Aeolus/issues/103)'s decision A3 pairs
/// `KeepAlive = { SuccessfulExit = false }` with this enum: a teardown that put the fans
/// back is finished and must not be restarted, and one that could not is a machine with a
/// fan possibly still off automatic control, which is exactly the case where the helper
/// should come back and reconcile. Naming the two outcomes rather than passing an `Int32`
/// around keeps that pairing readable at both ends.
enum TeardownOutcome: Int32, Sendable, Hashable, CaseIterable {

    /// Every lease released and `restoreToAutomatic(.everyFan)` accepted by the firmware.
    case restored = 0

    /// The machine-wide restore threw. Non-zero, deliberately: see `TeardownExit`.
    case restoreFailed = 1
}

/// The **only** place in `Sources/AeolusHelper` that ends the process.
///
/// A3 makes `exit(0)` mean one specific thing — *the orderly teardown ran and the fans are
/// back* — so it may appear on one path and nowhere else. `SignalTeardownTests` asserts
/// that at the source, because a second `exit(0)` added anywhere would still compile, still
/// pass every behavioural test, and quietly tell launchd not to restart a helper that never
/// restored anything.
///
/// It is a value rather than a function so that it can be the default argument of
/// `SignalTeardown.init`, and so a test can substitute a recorder for it. `exit` returns
/// `Never`, so in the shipping daemon nothing after the terminate call in
/// `SignalTeardown.run(stoppingSupervisorsWith:)` runs at all; under a recorder it returns,
/// which is what lets a test observe the exit as an ordered event beside the restores rather
/// than by inspecting a return value.
enum TeardownExit {

    /// Ends the process with the code `outcome` names.
    static let process: @Sendable (TeardownOutcome) async -> Void = { outcome in
        switch outcome {
        case .restored:
            exit(0)
        case .restoreFailed:
            exit(TeardownOutcome.restoreFailed.rawValue)
        }
    }
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
/// process and then end it with `exit(0)` when anything fired. A seam that only production
/// can supply is a mechanism only production can run.
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
/// 5. **Exit**, `0` if the restore landed and non-zero if it did not.
///
/// ## What this build actually does today, said plainly
///
/// `SMCFanControlPlane.restoreToAutomatic(_:)` throws `.controlPathNotBuilt`
/// unconditionally, so **on the shipping helper step 3 always fails and this path always
/// exits non-zero.** That is not a bug being deferred; it is the honest reading of A4's
/// "unconditionally … non-zero if the restore failed". A build with no write path cannot
/// verify that the fans are automatic, and the exit code says exactly that to launchd. The
/// tempting alternative — consult `writeCapability` and call a `.notBuilt` plane's refusal a
/// success — reintroduces the capability *literal* `FanWriteCapability` was created to
/// delete, and it would survive into the E3/E4 build where the same refusal means something
/// entirely different.
///
/// The consequence, so nobody meets it as a surprise: once #165 lands
/// `KeepAlive = { SuccessfulExit = false }`, `kill -TERM` on today's helper makes launchd
/// start it again. `launchctl bootout` unloads the job and is unaffected, and once E3 gives
/// the plane a real write path a successful restore exits `0` and nothing restarts.
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

        let outcome: TeardownOutcome
        do {
            try await restore.restoreToAutomatic(.everyFan)
            outcome = .restored
        } catch {
            log.teardownRestoreFailed(detail: String(describing: error))
            outcome = .restoreFailed
        }

        await stop()
        log.teardownFinished(outcome: outcome)
        await seams.terminate(outcome)
    }
}
