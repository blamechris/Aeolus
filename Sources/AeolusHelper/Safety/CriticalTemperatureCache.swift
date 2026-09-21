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
/// ## The compile error is the point, in every direction
///
/// `CriticalTemperatureCache` conforms to this and **not** to `CriticalTemperatureSensing`;
/// `CuratedCriticalTemperatures` conforms to that and **not** to this. So handing the cycle
/// the cache does not compile, and neither does handing the lease core the raw curated
/// telemetry. The first would let § 3 decide a thermal emergency from a reading up to a
/// cycle old — the staleness this design deliberately accepts on the grant path and must
/// never accept on the decision path. The second would silently reinstate the storm this
/// exists to bound.
///
/// A third direction was missing until an adversarial review pointed at it, and it is the
/// one a *future edit* reaches rather than a present call site: `ThermalEmergency` has to
/// hold the cache in order to write to it, and while it held the concrete type `sighting()`
/// was one line away from the cycle. `CriticalTemperatureRecording` closes that, so the
/// cycle can write to the cache and cannot read from it.
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

/// **Where a real reading is left**, as opposed to where one is asked for.
///
/// The other half of `SightednessProving`'s trick, and it is needed for the same reason in
/// the mirror direction. `ThermalEmergency` holds the cache only to *write* to it: a cycle
/// decides whether to take a user's fans away, and it must decide on a temperature it
/// measured itself rather than on one up to `maxAge` old. Holding the concrete
/// `CriticalTemperatureCache` there left `sighting()` in reach of a future edit, with nothing
/// but a doc comment between the cycle and the exact outcome `SightednessProving` says must
/// never happen.
///
/// Narrowing the field to this makes that a compile error rather than a thing to remember —
/// symmetric with the exclusion already enforced on the reading side, and for the same
/// argument: *what a consumer may be given* is expressed as a type.
///
/// ## Two calls, because *when a reading was taken* is not the caller's to assert
///
/// A recorder has to know the instant a reading was taken at, or it cannot tell a stale
/// reading from a fresh one — and the unsafe direction of getting that wrong is a sighting
/// displacing a blindness, which grants leases on a helper already found unable to see
/// ([#280](https://github.com/blamechris/Aeolus/issues/280)).
///
/// The instant is therefore **minted by the conformer**, not supplied by the caller: a
/// reader calls `beganReading()` before it reads and hands the result back with the
/// outcome. `CriticalTemperatureReadingStart` is opaque and constructible only inside
/// `CriticalTemperatureCache.swift`, so there is no way to record against an instant this
/// cache did not observe.
///
/// The alternative — a `ContinuousClock.Instant` parameter the caller stamps — was
/// rejected, and the reason is not aesthetic. It makes the comparison correct only while
/// two mechanisms hold *the same clock instance*, which nothing in the type system
/// expresses. Under test each would be given its own frozen `TestClock`, every instant
/// would compare equal, and the guard would pass every assertion while being a no-op in the
/// daemon. That is the exact shape of the defect
/// [#279](https://github.com/blamechris/Aeolus/issues/279) shipped and
/// `aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway` now pins. One clock, held by the
/// thing that does the comparing, has no such failure mode.
protocol CriticalTemperatureRecording: Sendable {

    /// Marks the instant a real read of the curated set is **about to be taken**.
    ///
    /// Call this *before* the read, and hand the result to `record(_:since:)` afterwards.
    /// The start — not the finish, and not the moment the outcome reaches the recorder — is
    /// the only instant the recorder knows the reading to be no fresher than.
    func beganReading() async -> CriticalTemperatureReadingStart

    /// Remembers what a real read of the curated set produced, unless something newer
    /// landed while the read was away.
    ///
    /// - Parameters:
    ///   - sighting: what the read produced.
    ///   - start: what `beganReading()` returned before the read this is the outcome of.
    ///
    /// Whether `start` is consulted at all depends on the outcome, and the asymmetry is
    /// deliberate — see `CriticalTemperatureCache.record(_:since:)`. There is no unguarded
    /// entry point on this protocol on purpose: the guard is not something a caller can
    /// forget, because there is nothing else to call.
    func record(
        _ sighting: CriticalTemperatureSighting, since start: CriticalTemperatureReadingStart
    ) async
}

/// The instant a real read of the curated set began, as observed by the cache that will
/// remember its outcome.
///
/// Opaque, and mintable only inside this file: the initialiser and the instant are both
/// `fileprivate`, so `CriticalTemperatureCache.beganReading()` is the only way to obtain
/// one. A caller can hold one and hand it back; it cannot manufacture one from a clock of
/// its own, which is what makes "the reading is no fresher than this" a fact the cache
/// observed rather than a claim the caller made.
///
/// It is `FanStateSensing`'s trick once more, applied to an *instant*: the thing a caller
/// may not do is expressed as a type it cannot construct.
struct CriticalTemperatureReadingStart: Sendable {

    fileprivate let instant: ContinuousClock.Instant

    fileprivate init(_ instant: ContinuousClock.Instant) {
        self.instant = instant
    }
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
actor CriticalTemperatureCache: SightednessProving, CriticalTemperatureRecording {

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

    /// Remembers what a real read of the curated set produced.
    ///
    /// Its only caller is `record(_:since:)`, on both of that method's branches. Reaching it
    /// requires being inside this file, which is the point — see below. Every *writer* still
    /// records on both its own paths, success and failure alike, which is what makes the
    /// grant path free during blindness as well as during health: a cache written only on
    /// success would leave every retry of a storm issuing its own read on exactly the machine
    /// that can least afford one, and each of those reads would fail.
    ///
    /// **`private`**, and that is the whole of
    /// [#280](https://github.com/blamechris/Aeolus/issues/280)'s fix. This is the unguarded
    /// store; every writer — the cycle and `sighting()`'s own
    /// flight alike — reaches it through `record(_:since:)`, which decides whether this
    /// outcome may displace what is already here. While it was the protocol's only
    /// requirement, § 3's cycle recorded a `.sighted` across its read with no comparison at
    /// all, so a reading taken *before* a flight's failure could be stamped *after* it and
    /// displace the blindness.
    ///
    /// Synchronous and returning nothing: the cycle owes this no attention, and a result it
    /// could branch on would be a result it might one day wait for.
    private func record(_ sighting: CriticalTemperatureSighting) {
        guard sighting.isAboutTheMachine else { return }
        recorded = (sighting, clock.now)
    }

    /// The instant a caller's read began, stamped by **this actor's** clock.
    ///
    /// The one clock in the comparison, which is the property `CriticalTemperatureRecording`
    /// is shaped around: a caller that stamped its own would be correct only while it held
    /// the same clock instance this does, and wrong — silently, and green under test —
    /// the moment it did not.
    ///
    /// Not `nonisolated`, though `clock` is an immutable `Sendable` and it could be — and
    /// the honest reason is **accuracy, not safety**. The first version of this comment said
    /// the hop was load-bearing against a start stamped before a record already queued here.
    /// That reading runs the *safe* way: a `nonisolated` stamp is taken earlier, so
    /// `recorded.at >= start.instant` fires more often, so more sightings are dropped, which
    /// is over-refusal — the same cost the `.blind` bypass already accepts, bounded by
    /// `maxAge`.
    ///
    /// What the hop actually buys is not spuriously discarding a cycle's sighting that is
    /// genuinely newer than a record queued ahead of it. Stated correctly because a wrong
    /// reason on a right mechanism is this repository's recorded way of losing the
    /// mechanism: a later reader who works out that `nonisolated` is conservative would
    /// conclude this paragraph is simply wrong, remove the isolation, and be right about the
    /// safety direction while losing the property the paragraph was protecting.
    func beganReading() -> CriticalTemperatureReadingStart {
        CriticalTemperatureReadingStart(clock.now)
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
        // Stamped **before** the flight, and the only thing this caller's own *sighting* is
        // allowed to be newer than — a blindness bypasses the comparison inside
        // `record(_:since:)`. The placement is the assertion, not an incidental line: taken
        // at the resume instead it is never older than anything the cycle recorded during
        // the flight, so the guard silently becomes a no-op. Pinned by the clock advance in
        // `aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway`; see `record(_:since:)`.
        let startedAt = beganReading()
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
            record(.sighted(report), since: startedAt)
            return report
        } catch {
            // Both arms go through the same call, and it is `record(_:since:)` that knows a
            // blindness bypasses the comparison — see its last section. The asymmetry used
            // to live here, as a second entry point this `catch` chose instead; it is an
            // invariant of the cache rather than a decision each caller re-takes, so it
            // belongs on the one side that can enforce it.
            record(.blind(error), since: startedAt)
            throw error
        }
    }

    /// A reader's own outcome, dropped if anything landed on this actor while it was away.
    ///
    /// `record(_:)` stamps with `clock.now`, which for a reader is the instant it
    /// **resumes** rather than the instant its read finished — and nothing orders a resumed
    /// continuation against a fresh call arriving at the same actor. So a read that began
    /// before another mechanism's can resume after it and stamp the older of the two
    /// readings as the newer one.
    ///
    /// That is not merely a stale answer. The reading is then served for a full `maxAge`
    /// measured from a moment it was never taken at, so the bound ADR 0010 promises — *"at
    /// most one cycle period old"* — is quietly exceeded, and the direction that matters is
    /// the unsafe one: a sighting overwriting a blindness recorded in the interval grants
    /// leases on a helper that has already been found unable to see.
    ///
    /// The test is the read's **start**, not its finish, because the start is the only
    /// instant this actor knows the reading to be no fresher than. Anything recorded at or
    /// after it came from a mechanism that looked at the machine no earlier, so it stays.
    ///
    /// `>=` rather than `>`: a record landed at exactly `start` would have been unexpired
    /// when `sighting()` looked, so it cannot be a leftover a flight was started to replace
    /// — under any clock whose resolution makes the two instants equal, keeping it is the
    /// correct answer and dropping the reader's costs one read.
    ///
    /// ## Only a **sighting** is compared
    ///
    /// The whole argument above is about one direction: a sighting overwriting a blindness
    /// grants leases on a helper already found unable to see. Run the same guard over a
    /// `.blind` and it works the other way — a failed read is discarded, and what stays is
    /// whatever was recorded during it.
    ///
    /// **That is an honesty defect, not a read storm, and the distinction is worth being
    /// exact about because the first version of this comment got it wrong.** The guard only
    /// fires when something *is* recorded — that is its precondition — so the next grant is
    /// served from memory and issues no read either way. Nothing is amplified. What happens
    /// instead is that the record left standing can be a `.sighted`, so the cache answers
    /// "the helper can see" while the most recent real read of the machine **failed**, and
    /// the next `acquireLease` is granted on the strength of it. `docs/SAFETY.md`'s rule is
    /// that no lease is granted while the helper is blind; CLAUDE.md's rule 6 is that we
    /// never claim control we do not have. This is that claim, at the one seam where it is
    /// about the safety mechanism rather than about a fan.
    ///
    /// So a `.blind` bypasses the comparison. The cost is over-refusal: a blindness can
    /// displace a sighting that genuinely was newer, and grants are refused for up to
    /// `maxAge`. That is the fail-safe direction and it clears itself on the same bound as
    /// everything else — `unexpiredSighting()` serves without restamping, so a blindness
    /// cannot perpetuate itself off the grants it refuses; it ages out, and the next grant
    /// reads the machine for itself.
    ///
    /// ## Why the bypass lives here rather than at each caller
    ///
    /// It used to be the caller's: `sighting()`'s `catch` called an unguarded `record(_:)`
    /// while its success path called the guarded one, and `ThermalEmergency.cycle()` called
    /// the unguarded one on **both** paths — so the cycle's `.sighted` was never compared
    /// against anything. That was
    /// [#280](https://github.com/blamechris/Aeolus/issues/280), and it was reachable for the
    /// whole duration of the cycle's read rather than for the actor hop after it: a cycle
    /// reading taken before a flight's failure could be recorded after it and displace the
    /// blindness. The window widened exactly when it mattered, since an SMC slow enough to
    /// lengthen the cycle's read is the one whose flights fail.
    ///
    /// Moving the asymmetry inside means there is no unguarded entry point to choose, so
    /// the property is one this type enforces rather than one every writer must re-derive.
    /// `CriticalTemperatureRecording` has no other requirement that records.
    func record(
        _ sighting: CriticalTemperatureSighting, since start: CriticalTemperatureReadingStart
    ) {
        switch sighting {
        case .blind:
            record(sighting)
        case .sighted:
            if let recorded, recorded.at >= start.instant { return }
            record(sighting)
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
