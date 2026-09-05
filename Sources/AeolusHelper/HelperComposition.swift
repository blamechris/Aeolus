import FanKit
import SMCCore

/// The composition root: every E5 mechanism, wired once, in one place a reviewer can read
/// top to bottom.
///
/// Until #163 this graph did not exist. `AeolusHelperMain` built a scheduler, a latch and a
/// ledger — *the bits, but no mechanism* — and served `ReadOnlyFanAuthority`, so
/// `LeaseAuthority`, `ThermalEmergency`, `ReclamationWatchdog`, `SMCFanControlPlane` and both
/// supervisors were constructed only under `Tests/`. Everything E5 had merged was inert in
/// production. That finding is what reopened
/// [#103](https://github.com/blamechris/Aeolus/issues/103), and its adjudication (decision
/// A1, 2026-09-04) settles the shape below.
///
/// ## One connection, one scheduler, one plane
///
/// `SMCSensorProvider` holds the `SMCConnection`; `SMCReadScheduler` holds the provider;
/// `SMCFanControlPlane` holds **that** scheduler and the snapshot path reads through
/// `scheduler.snapshotReader`. Two schedulers arbitrate nothing while looking exactly like
/// one that does — each grants turns against a queue the other cannot see — so #127's
/// machinery would be present, tested and bypassed. `HelperCompositionTests` asserts at the
/// source that exactly one is ever constructed, because `main()` ends in `dispatchMain()` and
/// there is no seam to observe this from at runtime.
///
/// ## Generic over the plane, so the graph itself is testable
///
/// `production(log:)` is the only thing that names hardware. Everything else takes a
/// `FanControlPlane` and a `SensorProvider`, so a test composes the **same wiring** over
/// `ScriptedControlPlane` and a canned provider and drives a lease through it end to end.
/// That is the difference between testing the composition and testing a paraphrase of it:
/// `HelperRestorerTests` acquires a real lease against the real `LeaseAuthority`, tears it
/// down through the real `HelperFanRestorer`, and asserts on the real registries.
///
/// ## What it deliberately does not do
///
/// No startup reconciliation ([#164](https://github.com/blamechris/Aeolus/issues/164)), no
/// restart policy ([#165](https://github.com/blamechris/Aeolus/issues/165)), no signal
/// handlers ([#166](https://github.com/blamechris/Aeolus/issues/166)) and no connection
/// health or reconnect ([#168](https://github.com/blamechris/Aeolus/issues/168)). `bringUp()`
/// names where the first of those goes.
///
/// Sleep and wake ([#167](https://github.com/blamechris/Aeolus/issues/167)) *is* here, and is
/// the one lifecycle event this graph acts on: `powerObserver` and `powerResponder`, wired
/// last in `bringUp()`. See `SystemPowerResponder` for why it holds no supervisor.
struct HelperComposition<Plane: FanControlPlane>: Sendable {

    /// The single control plane. Every safety mechanism's reads and writes go through it, at
    /// `.supervisor` priority.
    let plane: Plane

    /// The snapshot path: fan enumeration, the discovered sensor set, `F<n>Md` per fan.
    ///
    /// Also the lease core's `FanEnumerating` — one enumeration of the machine, shared, so
    /// the fan set a lease is validated against is the same one a client is shown.
    let reading: ReadOnlyFanAuthority

    /// § 3's curated critical set, **shared** between the thermal emergency's cycle and the
    /// cache the lease core's grant-time blindness gate proves sightedness from.
    ///
    /// One instance, deliberately. `DegradationMemo` is per instance, so two of these would
    /// each log the same partial sensor loss on their own schedule — the collapse
    /// `CuratedCriticalTemperatures` documents *"is only global if the lease core and the
    /// supervisor are handed the same `CuratedCriticalTemperatures`"*, stated there in the
    /// future tense because no code did it. This is the code.
    ///
    /// Since #134 the lease core reaches it **through `sightings`** rather than directly, so
    /// the sharing runs one level deeper rather than being given up: a grant that finds no
    /// fresh reading reads through this same instance, memo and all.
    let telemetry: CuratedCriticalTemperatures<Plane>

    /// § 3's most recent reading, written by the cycle and read by the grant-time
    /// sightedness check — **one instance, handed to both**.
    ///
    /// A second cache would be a grant path proving sightedness from a reading no cycle ever
    /// wrote, so every grant would read the SMC for itself and #134's storm would be back
    /// with the coalescing machinery present, tested and bypassed. That is the same hazard
    /// shape as two `SMCReadScheduler`s, and `HelperCompositionTests` guards it the same way:
    /// at the source, because `main()` ends in `dispatchMain()` and there is nothing to
    /// observe this from at runtime.
    ///
    /// Nothing here can be swapped, and each exclusion is the compiler's rather than a
    /// reviewer's. `LeaseAuthority` takes `SightednessProving`; `ThermalEmergency`'s
    /// `telemetry:` takes `CriticalTemperatureSensing`, which this type is not; and its
    /// `sightings:` takes `CriticalTemperatureRecording`, which has no `sighting()` — so the
    /// cycle can write here and cannot read from here. See
    /// [ADR 0010](../../docs/ADR/0010-coalesced-supervisor-reads.md).
    let sightings: CriticalTemperatureCache

    /// § 3's bit. Read by the snapshot, by `acquireLease`, and by § 5 to decide the
    /// incumbent; written only by `ThermalEmergency`.
    let latch: ThermalEmergencyLatch

    /// § 5's ledger, read by the snapshot and written by the watchdog.
    let ledger: ReclamationLedger

    /// The lease core's terminal action, and the only `FanRestoring` in `Sources/`.
    let restorer: HelperFanRestorer<Plane>

    let leases: LeaseAuthority
    let thermalEmergency: ThermalEmergency<Plane>
    let reclamationWatchdog: ReclamationWatchdog<Plane>

    let thermalSupervisor: ThermalSupervisor<Plane>
    let reclamationSupervisor: ReclamationSupervisor<Plane>

    /// § 1's TTL loop — ADR 0005's *independent* path back to automatic control.
    ///
    /// **Started here even though #163's brief named only the two safety supervisors**, and
    /// the reason is the defect this whole issue exists to correct: a mechanism that is
    /// constructed and never driven is inert, and the TTL is the one the lease's contract
    /// rests on. It costs one wake per second against an empty table today, because no lease
    /// can be granted while `writeCapability` is `.notBuilt`. It costs a pinned fan with
    /// nobody counting if it is still unstarted on the day that changes.
    let leaseExpirySupervisor: LeaseExpirySupervisor

    /// What the listener is given. Replaces `ReadOnlyFanAuthority` in that role.
    let authority: SupervisedFanAuthority

    /// § 4's responder: release, restore, then allow the power change. See
    /// `SystemPowerResponder`.
    let powerResponder: SystemPowerResponder<Plane>

    /// The seam § 4 hears the system through, or `nil` for a graph that hears nothing.
    ///
    /// Optional because the production conformer registers with the real power management
    /// root the moment it is asked to observe, and most tests compose this graph to drive
    /// something else entirely. `production(log:)` supplies one; a § 4 test supplies a
    /// scripted one; everything else composes a helper that never hears a power event, which
    /// is the same state as a machine that never sleeps.
    let powerObserver: (any SystemPowerObserving)?

    /// Wires the graph. Constructs nothing that touches hardware — see `production(log:)`.
    ///
    /// The order below is A1's, and it is the order of the dependencies rather than a
    /// preference: plane, then the latch and the ledger both the snapshot and the mechanisms
    /// read, then the restorer, then the lease core, then the two safety actors, then the
    /// loops, then the authority.
    ///
    /// `snapshotProvider` is the reader the client-facing snapshot takes its turns from, and
    /// it is the one parameter worth a paragraph. The fan read and the `F<n>Md` read are both
    /// built from **this single value** below, so a snapshot assembled from two connections is
    /// not a mistake a caller can make — a stronger guarantee than the source tripwire that
    /// used to enforce it, and the reason
    /// `HelperCompositionTests.theModeReadIsBuiltFromTheSameProviderAsTheFanRead` is now
    /// narrower than it was.
    ///
    /// `clock` is the lease core's own, defaulted to the one that ships and injected by
    /// nothing in `Sources/`. It is here for one property no other seam can reach:
    /// `SupervisedFanAuthority.snapshot()` reads the machine and *then* the lease, so that a
    /// lease lapsing during the ~0.5 s of subset reads is reported as gone rather than as
    /// live. Demonstrating that requires time to pass **inside** the read, which is a
    /// `TestClock` and a provider that advances it — see
    /// `SupervisedFanAuthorityTests.theLeaseIsReadAfterTheMachineNotBefore`. The alternative
    /// was a source tripwire on statement order, which is what this repository reaches for
    /// when there is no seam; here one defaulted parameter buys the behavioural test instead,
    /// and `CLAUDE.md` rule 6 is worth that much.
    init(
        plane: Plane,
        snapshotProvider: some SensorProvider,
        criticalSensors: CriticalSensorSet,
        clock: some MonotonicClock = SystemMonotonicClock(),
        powerObserver: (any SystemPowerObserving)? = nil,
        acknowledgementBudget: Duration = SystemPowerLimits.acknowledgementBudget,
        log: HelperLog = HelperLog(),
        leaseLog: LeaseLog = LeaseLog(),
        safetyLog: SafetyLog = SafetyLog()
    ) {
        self.plane = plane
        self.powerObserver = powerObserver

        // Built as locals and then handed round, because each is read by several mechanisms
        // and written by one, and because a stored property cannot be read while the rest of
        // this initialiser is still assigning. Constructing a fresh `ThermalEmergencyLatch()`
        // at each use site would give every mechanism a private latch nothing else can see —
        // the defect `LeaseAuthority`'s own field documentation records as *"a defaulted
        // latch would compile and report a bit nothing sets"*.
        let latch = ThermalEmergencyLatch()
        let ledger = ReclamationLedger()
        self.latch = latch
        self.ledger = ledger

        let reading = ReadOnlyFanAuthority(
            provider: snapshotProvider,
            fanMode: SnapshotFanModeReads(provider: snapshotProvider),
            log: log,
            thermalEmergency: latch,
            reclamation: ledger)
        self.reading = reading

        let telemetry = CuratedCriticalTemperatures(
            plane: plane, set: criticalSensors, log: safetyLog)
        self.telemetry = telemetry

        // The one cache. `source:` is the same curated conformer § 3's cycle reads through,
        // so a grant that finds nothing fresh asks the machine the identical question the
        // cycle would have. `maxAge` is not passed: its default is derived from
        // `ThermalSupervisor.defaultInterval`, and a value supplied here would be the second
        // constant ADR 0010 forbids.
        //
        // `clock` is the lease core's, and it is passed for the reason the parameter's own
        // documentation gives: an age bound nothing composed can advance is an age bound no
        // composed test can exercise. Before this the cache built its own
        // `SystemMonotonicClock` and the staleness rule was reachable only by constructing a
        // cache by hand — so the graph the daemon runs had no test that a sighting ages out
        // at all. `HelperSightednessTests` is the one that needs it.
        let sightings = CriticalTemperatureCache(source: telemetry, clock: clock)
        self.sightings = sightings

        // The keystone write, bounded per #110, at the lease core's own actor level.
        //
        // `.leaseExpiry` is ADR 0007's level for the lease core, and it is **provenance that
        // nothing on this path currently reads**: `SafetyActorWriter` does not log it and
        // `SafetyArbiter.ruling(for:incumbent:)` is not consulted by a restore. The
        // auditable fact — which mechanism handed the fans back — travels separately, as the
        // `FanRestoreCause` every teardown path supplies and `LeaseLog` records. Whoever
        // makes the arbiter govern restores must revisit this: a `.allLeasesDropped` restore
        // is § 7's level 1, not level 5.
        let restorer = HelperFanRestorer(
            writer: SafetyActorWriter(plane: plane, level: .leaseExpiry), log: leaseLog)
        self.restorer = restorer

        let leases = LeaseAuthority(
            enumeration: reading,
            restorer: restorer,
            writeCapability: plane,
            telemetry: sightings,
            thermalEmergency: latch,
            clock: clock,
            log: leaseLog)
        self.leases = leases

        let thermalEmergency = ThermalEmergency(
            telemetry: telemetry,
            sightings: sightings,
            writer: SafetyActorWriter(plane: plane, level: .thermalEmergency),
            leases: leases,
            latch: latch,
            log: safetyLog)
        let reclamationWatchdog = ReclamationWatchdog(
            sensing: plane,
            writer: SafetyActorWriter(plane: plane, level: .reclamationWatchdog),
            leases: leases,
            latch: latch,
            ledger: ledger,
            log: safetyLog)
        self.thermalEmergency = thermalEmergency
        self.reclamationWatchdog = reclamationWatchdog

        thermalSupervisor = ThermalSupervisor(emergency: thermalEmergency, log: safetyLog)
        reclamationSupervisor = ReclamationSupervisor(
            watchdog: reclamationWatchdog, log: safetyLog)
        leaseExpirySupervisor = LeaseExpirySupervisor(authority: leases, log: leaseLog)

        authority = SupervisedFanAuthority(reading: reading, leases: leases, log: log)

        // § 4, at ADR 0007's level 4 and through `SafetyActorWriter` like every other
        // ungoverned actor. It is handed the lease core and a writer and **no supervisor**,
        // which is decision A5's "neither event stops or starts a supervisor" as a property
        // of the graph rather than a rule about a method body.
        powerResponder = SystemPowerResponder(
            leases: leases, writer: SafetyActorWriter(plane: plane, level: .sleepWake),
            clock: clock, acknowledgementBudget: acknowledgementBudget, log: safetyLog)
    }

    // MARK: - Bring-up

    /// The one ordered bring-up. Everything that must be true before a client can reach the
    /// helper happens here, and `AeolusHelperMain` advertises the Mach service only after it
    /// returns.
    ///
    /// ## Why the order is the design
    ///
    /// 1. **Bind the safety registries to the restorer.** It is first because every step
    ///    after it can cause a restore: a supervisor's cycle can revoke a lease, and an
    ///    advertised service can be handed one to release. `HelperFanRestorer` explains why
    ///    the binding is late at all — the graph is circular, and this is the edge that is
    ///    safest to close last.
    /// 2. **Startup reconciliation goes here** — `#164`, E5.4b. Between the bind and the
    ///    supervisors, because a fan restored by reconciliation must not be read by § 5's
    ///    first cycle as a reclamation, and because the restore it performs needs the
    ///    registries bound. It is a seam and not a call: nothing reconciles yet, and an empty
    ///    method that looks like it does would be worse than a marker that says it does not.
    /// 3. **Start the supervisors.** § 3 first: it is the higher-precedence actor, and its
    ///    first cycle is what establishes whether this machine can be seen at all.
    /// 4. **Hear the system's power events** — `#167`, E5.4e. Last, because § 4's first act
    ///    on a `.willSleep` is to drop every lease and restore, and both need the registries
    ///    bound; and because a sleep arriving before the supervisors are running would leave
    ///    the handback unwatched by § 5. It is also the one step allowed to fail and carry
    ///    on: a helper that cannot hear the system still has § 1's TTL, which is the backstop
    ///    § 4 was always measured against.
    ///
    /// A1 states the property this buys: *"an advertised Mach service is a client that can
    /// acquire a lease over a fan whose reconciliation restore is still in flight."*
    ///
    /// ## If this never returns, nothing is served
    ///
    /// The listener is resumed by the caller, after this. A bring-up that hung would leave a
    /// daemon that answers no connections — which is the fail-safe direction and is
    /// deliberately not guarded here: refusing to serve is safe, serving over unreconciled
    /// fans is not. Making the daemon recover from it is the restart policy's job
    /// ([#165](https://github.com/blamechris/Aeolus/issues/165)).
    func bringUp() async {
        await bindSafetyRegistries()

        // TODO(E5): startup reconciliation — #164 restores any fan found in manual with no
        // live lease, exactly once, before either supervisor starts. See A2 on #103 for why
        // it is unconditional and why a fan later observed manual is foreign control rather
        // than a reclamation.

        await thermalSupervisor.start()
        await reclamationSupervisor.start()
        await leaseExpirySupervisor.start()

        observeSystemPower()
    }

    /// Points § 4 at the system, if this graph was given something to hear it through.
    ///
    /// Synchronous, because `SystemPowerObserving.observe(_:)` registers and returns —
    /// nothing is awaited and nothing is written here. What is stored is a closure, and the
    /// closure's whole body is one `await` of `SystemPowerResponder.respond(to:)`.
    ///
    /// **A failure is logged and swallowed, deliberately.** Every other bring-up step is a
    /// precondition of serving clients — decision A1's rule that a hung bring-up serves
    /// nothing is the fail-safe direction — and this one is not: § 4 is an *improvement* on
    /// the TTL, not a replacement for it, so a daemon that cannot register for power events
    /// is strictly better running than not. The `.fault` line says which of the two states
    /// this process is in.
    ///
    /// Its own method rather than four lines inside `bringUp()` so that a § 4 test can
    /// install the observer without also starting three loops that would read the same
    /// scripted firmware underneath its assertions — the same reason
    /// `bindSafetyRegistries()` is its own method.
    func observeSystemPower() {
        guard let powerObserver else {
            // Said out loud rather than returned from silently. The doc above promises three
            // distinguishable states — observing, refused, absent — and a bare `return` gave
            // the third no line at all: a graph composed with no observer looked in `log show`
            // exactly like one whose registration succeeded. That is the "fails silently and
            // completely" shape this file's own comments name as the reason the IOKit message
            // numbers are derived rather than written down, one layer up.
            powerResponder.wasGivenNothingToObserve()
            return
        }
        let responder = powerResponder
        do {
            try powerObserver.observe { notification in
                await responder.respond(to: notification)
            }
        } catch {
            powerResponder.couldNotObserve(error)
        }
    }

    /// Closes the one circular edge in the graph: the restorer learns which registries to
    /// keep in step with the firmware.
    ///
    /// Its own method rather than two lines inside `bringUp()` so a test can compose the
    /// graph, bind it exactly as the daemon does, and then drive a lease through it without
    /// also starting three loops that would read the same scripted firmware underneath the
    /// assertions. `HelperRestorerTests` is that test; `HelperCompositionTests` separately
    /// asserts that `bringUp()` is what calls this in the daemon.
    func bindSafetyRegistries() async {
        await restorer.bind(
            thermalEmergency: thermalEmergency, reclamationWatchdog: reclamationWatchdog)
    }

    /// Stops the three loops.
    ///
    /// **Stops, and nothing else.** Neither the latch nor either registry is cleared and no
    /// fan is restored: `ThermalSupervisor.stop()` and `ReclamationSupervisor.stop()` each
    /// document at length why their own mechanism's state must survive being stopped, and
    /// those arguments run in opposite directions on purpose. The teardown that *does*
    /// restore is E5.4d's signal path
    /// ([#166](https://github.com/blamechris/Aeolus/issues/166)); this is what a test uses to
    /// leave no loops running behind it.
    func shutDown() async {
        await thermalSupervisor.stop()
        await reclamationSupervisor.stop()
        await leaseExpirySupervisor.stop()
    }
}

// MARK: - The hardware wiring

extension HelperComposition where Plane == SMCFanControlPlane {

    /// The daemon's graph, over the real SMC.
    ///
    /// The **only** place in `Sources/AeolusHelper` that constructs an `SMCSensorProvider` or
    /// an `SMCReadScheduler`, and `HelperCompositionTests` asserts both counts across the
    /// whole tree. A helper-side read that takes no turn is invisible to the safety cycle,
    /// and a second scheduler arbitrates nothing while looking exactly like one that does.
    ///
    /// The critical set is resolved from `HardwareIdentity.current()`, so an unrecognised Mac
    /// gets `CriticalSensorSet.unidentifiedHardware` — the empty set, whose read throws every
    /// cycle. That is the documented steady state for an unmeasured machine rather than an
    /// edge case: § 3 being a precondition of § 1 means such a machine refuses leases, which
    /// is the honest answer and not a degradation to be papered over.
    static func production(log: HelperLog = HelperLog()) -> HelperComposition<SMCFanControlPlane> {
        let scheduler = SMCReadScheduler(provider: SMCSensorProvider())
        let plane = SMCFanControlPlane(scheduler: scheduler)
        return HelperComposition(
            plane: plane,
            snapshotProvider: scheduler.snapshotReader,
            criticalSensors: CriticalSensorSet.resolve(for: .current()),
            powerObserver: IOKitSystemPowerObserver(),
            log: log)
    }
}
