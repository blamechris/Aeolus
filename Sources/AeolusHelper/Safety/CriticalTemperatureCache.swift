import FanKit
import SMCCore

/// **Can `docs/SAFETY.md` § 3 currently see?** — asked by the grant path, answered from
/// § 3's own most recent reading.
///
/// ## Why this is not `CriticalTemperatureSensing`
///
/// The two protocols ask questions that sound alike and are not the same question, and
/// [ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md) turns on the
/// difference. `CriticalTemperatureSensing.readCriticalTemperatures()` means *read the
/// curated set, once, now*: § 3's cycle needs a temperature it measured itself, because it
/// is about to decide whether to take a user's fans away on the strength of it. This one
/// means *is the mechanism that protects a leased fan sighted*, and the authoritative
/// answer to that is the cycle's own last reading — sharing it is not an approximation of
/// the answer, it **is** the answer.
///
/// ## The compile error is the point, in both directions
///
/// `CriticalTemperatureCache` conforms to this and **not** to `CriticalTemperatureSensing`;
/// `CuratedCriticalTemperatures` conforms to that and **not** to this. So handing the cycle
/// the cache does not compile, and neither does handing the lease core the raw curated
/// telemetry. The first would let § 3 decide a thermal emergency from a reading up to a
/// cycle old — the staleness this design deliberately accepts on the grant path and must
/// never accept on the decision path. The second would silently reinstate the storm this
/// exists to bound.
///
/// It is `FanStateSensing`'s trick, applied to a read rather than a write: *what a consumer
/// can be given* is expressed as a type, so the exclusion is a thing the compiler refuses
/// rather than a thing a future edit must remember. Two method names rather than one is
/// what makes it work — a shared name with two conformances would let either value satisfy
/// either parameter.
///
/// ## What a conformer may not do
///
/// Refuse in the unsafe direction. A conformer with nothing to serve must **read**, and one
/// serving a remembered failure must **throw** — see `CriticalTemperatureCache.sighting()`.
/// A conformer that answered "sighted" from an empty memory would be the
/// `isThermalEmergencyActive: false` literal again, one seam over.
protocol SightednessProving: Sendable {

    /// Proves the helper can see a critical temperature, from the freshest evidence
    /// available.
    ///
    /// - Returns: the reading the proof rests on. The lease core discards it — see
    ///   `CriticalTemperatureSensing` for why a report is returned rather than a `Bool` —
    ///   but it is what makes the claim inspectable rather than assertable.
    /// - Throws: whatever a real read of the curated set would throw, including a
    ///   *remembered* failure. Blindness is the fail-safe answer and it is served from
    ///   memory exactly as a sighting is.
    func sighting() async throws -> CriticalTemperatureReport
}

/// What one real read of the curated critical set produced — the unit this cache remembers.
///
/// Deliberately not `CriticalTemperatureReport?`. A `nil` report and a thrown error are the
/// same fact at this seam — *the helper could not see* — but only one of them can be
/// replayed to a later caller as a refusal, and an optional would quietly turn the other
/// into "nothing recorded yet", which this cache answers by **reading**. The failure has to
/// survive being remembered, because a storm during blindness is exactly the case
/// [#134](https://github.com/blamechris/Aeolus/issues/134) is about.
enum CriticalTemperatureSighting: Sendable {

    /// The curated set answered, and this is what it said.
    case sighted(CriticalTemperatureReport)

    /// The read failed. Replaying this refuses the grant, which is the safe direction.
    case blind(any Error)

    /// Hands the recorded outcome to a caller exactly as the read that produced it would
    /// have.
    func replayed() throws -> CriticalTemperatureReport {
        switch self {
        case .sighted(let report): return report
        case .blind(let error): throw error
        }
    }

    /// Whether this outcome is a statement about the **machine**, and therefore worth
    /// remembering.
    ///
    /// `CancellationError` is not one, and `LeaseAuthority.refuseIfBlind` already says why
    /// at length: a cancelled request says the caller went away, and says nothing about
    /// whether the SMC answered. Remembering it would be strictly worse here than there —
    /// there it produces one misleading refusal for the client that was cancelled, here it
    /// would be replayed as a cancellation to *other* clients, for up to a cycle, none of
    /// whom was cancelled at all. Not recording it costs one real read on the next grant,
    /// which is the fail-safe direction.
    var isAboutTheMachine: Bool {
        switch self {
        case .sighted: return true
        case .blind(let error): return !(error is CancellationError)
        }
    }
}

/// § 3's most recent reading, shared with the grant path — coalesced and age-bounded.
///
/// ## The problem, in one paragraph
///
/// `LeaseAuthority.refuseIfBlind` costs a real 34-key `.supervisor` read per `acquireLease`,
/// each in its own `Task`, paced by nothing but how fast a client retries. `SMCReadScheduler`
/// is FIFO within `.supervisor`, so with *N* of those outstanding § 3's own cycle is admitted
/// `N + (N - 1) / maxConsecutiveOvertakes` turns after it queues — and the expensive part is
/// the quota-forced **snapshot** turn dragged along once every `maxConsecutiveOvertakes`, at
/// ~11 ms against a supervisor turn's ~0.5 ms. A revoked client retrying in a tight loop
/// therefore delays the one mechanism that would take its fans back, while looking to the
/// scheduler exactly like the safety cycle it is delaying.
///
/// ## Why coalescing rather than a third priority level
///
/// [ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md) records the decision and
/// the rejected alternative in full. In one sentence: a third level fixes the *cycle's place
/// in line* under an unbounded *N* and leaves the single SMC connection saturated by an
/// unprivileged client — the snapshot starves, the § 5 sweep stretches — so it makes read
/// amplification survivable rather than impossible. This removes the amplification instead.
///
/// ## What it guarantees
///
/// - **At most one grant-time read is ever outstanding.** Concurrent callers share one
///   flight; a caller arriving to an unexpired sighting takes no turn at all.
/// - **Staleness is bounded by `maxAge`**, which is one § 3 cycle period — already the
///   granularity at which blindness is detected, so nothing is lost that was ever promised.
/// - **A remembered failure refuses.** Successes and failures are both recorded, so a storm
///   arriving *during* blindness costs one read rather than one per retry, and every retry
///   is refused.
/// - **A cold cache reads.** A stopped supervisor, or the first grant after launch, degrades
///   to one real read per grant — still single-flight. Nothing here can answer "sighted"
///   without evidence.
///
/// ## What it is not
///
/// It is not § 3's telemetry, and `SightednessProving` is what stops it being mistaken for
/// it. The cycle reads for itself, every cycle, and hands the outcome here on its way past —
/// so this type is *downstream* of every decision § 3 makes and upstream of none.
actor CriticalTemperatureCache: SightednessProving {

    /// How long a sighting is worth serving: **one § 3 cycle period**.
    ///
    /// Derived from `ThermalSupervisor.defaultInterval` and never restated. A second
    /// constant here would be a staleness bound that silently disagreed with the cadence it
    /// is supposed to describe — and the disagreement would be invisible, because both
    /// numbers would look correct in isolation.
    ///
    /// A concrete plane has to be named to reach a `static` on a generic type, and
    /// `defaultInterval` does not depend on `Plane` — it is `.seconds(1)` for every
    /// instantiation. Naming the production one is the honest spelling of "the interval the
    /// daemon actually runs § 3 at".
    static var defaultMaxAge: Duration { ThermalSupervisor<SMCFanControlPlane>.defaultInterval }

    /// The real read, for when there is nothing worth serving.
    ///
    /// The **same** conformer § 3's cycle reads through, in the composition root: the
    /// curated key list and the plausibility gate are on this path exactly as they are on
    /// that one, so a cold-cache grant and a cycle ask the machine the identical question.
    private let source: any CriticalTemperatureSensing
    private let maxAge: Duration
    private let clock: any MonotonicClock

    /// The last outcome worth serving, and when it was recorded.
    ///
    /// Stamped inside this actor rather than by the caller, so ordering is the actor's
    /// serialisation rather than a claim two mechanisms have to keep in step. The reading is
    /// therefore at most one read-latency (~0.5 ms) older than its stamp, against a bound of
    /// one second — stated because it is a real approximation, and dismissed because it is
    /// three orders of magnitude inside the thing it approximates.
    private var recorded: (sighting: CriticalTemperatureSighting, at: ContinuousClock.Instant)?

    /// The real read in flight right now, handed to every caller that arrives during it.
    ///
    /// `ReadOnlyFanAuthority.discoverSensorKeys()`'s pattern, for its reason: a second
    /// opinion about the machine is worth less than the one already being obtained, and
    /// obtaining it costs the scarcest thing the helper has.
    private var inFlight: Task<CriticalTemperatureReport, any Error>?

    /// How many `sighting()` calls were answered without issuing a read of their own —
    /// served from an unexpired sighting, or joined to one already in flight.
    ///
    /// An observation, not a control, exactly as `SMCReadScheduler.queuedTurns(at:)` is: the
    /// coalescing is otherwise invisible from outside, and a test that inferred it from
    /// timing would report a regression as a CI timeout rather than a red assertion
    /// ([#109](https://github.com/blamechris/Aeolus/issues/109)). ADR 0010 names it as the
    /// counter E5.4f's `SchedulerObserving` hook should surface for
    /// [#133](https://github.com/blamechris/Aeolus/issues/133).
    private(set) var coalescedSightings = 0

    /// How many real reads `sighting()` has issued — the other half of the same
    /// observation, and the one a single-flight assertion is actually about.
    private(set) var readsIssued = 0

    init(
        source: some CriticalTemperatureSensing,
        maxAge: Duration = CriticalTemperatureCache.defaultMaxAge,
        clock: some MonotonicClock = SystemMonotonicClock()
    ) {
        self.source = source
        self.maxAge = maxAge
        self.clock = clock
    }

    // MARK: - Recording

    /// Remembers what a real § 3 cycle read produced.
    ///
    /// Called by `ThermalEmergency.cycle()` on **both** paths, which is what makes the grant
    /// path free during blindness as well as during health. A cache written only on success
    /// would leave every retry of a storm issuing its own read on exactly the machine that
    /// can least afford one — and each of those reads would fail, so the amplification would
    /// be pure cost.
    ///
    /// Synchronous and returning nothing: the cycle owes this no attention, and a result it
    /// could branch on would be a result it might one day wait for.
    func record(_ sighting: CriticalTemperatureSighting) {
        guard sighting.isAboutTheMachine else { return }
        recorded = (sighting, clock.now)
    }

    // MARK: - Proving

    /// § 3's freshest evidence, read if there is none.
    ///
    /// The order is the whole design: serve an unexpired sighting, else join the read
    /// already running, else run one. Only the caller that *started* a read records its
    /// outcome — a joiner has nothing of its own to contribute, and recording from each
    /// would restamp one reading as several progressively fresher ones.
    func sighting() async throws -> CriticalTemperatureReport {
        if let unexpired = unexpiredSighting() {
            coalescedSightings += 1
            return try unexpired.replayed()
        }

        if let joined = inFlight {
            coalescedSightings += 1
            // Not recorded here, and not re-checked afterwards: the caller that started this
            // flight records it on its way out, and a joiner that then consulted `recorded`
            // could be handed a *different* reading to the one it waited for.
            return try await joined.value
        }

        let source = self.source
        let flight = Task<CriticalTemperatureReport, any Error> {
            try await source.readCriticalTemperatures()
        }
        inFlight = flight
        readsIssued += 1

        // Identity-compared, `ReadOnlyFanAuthority.discoverSensorKeys()`'s reason: a caller
        // that merely joined must never clear a newer flight. Unreachable today — everything
        // from the resume below to this `defer` is straight-line — and cheap insurance
        // against the day it is not.
        defer { if inFlight == flight { inFlight = nil } }

        do {
            let report = try await flight.value
            record(.sighted(report))
            return report
        } catch {
            record(.blind(error))
            throw error
        }
    }

    /// The recorded outcome, if it is still inside the age bound.
    ///
    /// `<=` rather than `<`: the bound is "one cycle period old", and a reading at exactly
    /// that age is one the cycle that produced it would still be acting on.
    private func unexpiredSighting() -> CriticalTemperatureSighting? {
        guard let recorded, clock.now - recorded.at <= maxAge else { return nil }
        return recorded.sighting
    }
}
