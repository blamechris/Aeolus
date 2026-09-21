import FanKit
import SMCCore

/// `docs/SAFETY.md` § 3, and the precedence engine's first consumer.
///
/// ## Why it ships with the engine
///
/// An arbiter with no actors is a declared mechanism nothing calls, and its tests pass
/// without being able to fail — which is
/// [#121](https://github.com/blamechris/Aeolus/issues/121)'s shape exactly, and this
/// repository's most expensive recurring defect. So level 2 is a real actor that really
/// writes, rather than an enum case.
///
/// **Be precise about how much that buys, because an earlier draft was not.** What this
/// type consumes is `SafetyActorLevel.Ungoverned` — the half of the precedence engine that
/// keeps § 8 away from a safety write, and which the compiler enforces here. It does **not**
/// consult `SafetyArbiter.ruling(for:incumbent:)`: with one actor implemented there is no
/// incumbent to be pre-empted by, so the arbiter still has no production caller and
/// replacing its body with `return .commands` fails only its own tests. That half becomes
/// load-bearing when the reclamation watchdog
/// ([#126](https://github.com/blamechris/Aeolus/issues/126)) and sleep/wake
/// ([#103](https://github.com/blamechris/Aeolus/issues/103)) arrive to contend with it.
///
/// ## The failure asymmetry, which decides every uncertain branch below
///
/// **Over-firing returns fans to automatic — safe and noisy, acceptable. Under-firing is
/// the dangerous direction.** That is not a sentiment, it is the tie-breaker, and each of
/// these three branches resolves by it rather than by taste:
///
/// - A max write the firmware refuses does **not** skip the restore that follows it. The
///   restore is the destination and needs no trusted data at all (ADR 0007's keystone).
/// - A cycle that produced no reading never **releases** a latch. A latch released on a
///   cycle that could not see is a lease granted into a machine nobody is watching.
/// - The emergency fires every fan under manual control, not a fan it has attributed the
///   heat to. A CPU package temperature is not attributable to a fan — see `fire(_:)`.
///
/// The one branch that is *not* decided by the asymmetry is the ceiling comparison itself,
/// which is `>` and not `>=`. Exact equality is not uncertainty: the ceiling is the highest
/// safe temperature rather than the lowest unsafe one, and `ThermalCeiling`'s own
/// documentation already spells the comparison that way.
///
/// ## What it needs of the machine, and what it deliberately does not
///
/// It reads temperatures. It does **not** read an envelope, ever, and that is the property
/// `FanWriteAuthorisation.swift` says permits do not expire for: `manualControlEngaged(_:)`
/// takes the `CommandableFan` minted when the fan came off automatic control, so the
/// maximum write needs no read while the machine is above ceiling — which is exactly the
/// moment reading may be the thing that has failed.
///
/// ## What the user is told, and the gap that is not papered over
///
/// `isThermalEmergencyActive` on the snapshot, rendered by the app at 1 Hz, plus the log.
/// **A root daemon cannot post user notifications**, so a `fanctl`-held lease with no app
/// running gets no visual notification: the machine getting loud is the physical signal,
/// and the next `fanctl` invocation reports. The as-built rewrite of `SAFETY.md` belongs to
/// [#104](https://github.com/blamechris/Aeolus/issues/104).
///
/// - Note: this file is over SwiftLint's 400-line warning, as `LeaseAuthority.swift` and
///   `Fan.swift` already are. Splitting it means either moving the write sequence into an
///   extension in another file — which does not compile without widening the actor's
///   `private` state to the whole module, and that state is exactly what makes
///   `fire(_:from:)`'s reentrancy reasoning checkable — or cutting doc comments that are
///   load-bearing. [#128](https://github.com/blamechris/Aeolus/issues/128) owns the split,
///   and splitting a safety-critical file in the change that adds the safety mechanism is
///   the wrong order.
actor ThermalEmergency<Plane: FanControlPlane> {

    private let telemetry: any CriticalTemperatureSensing

    /// Where every cycle's reading is left for the grant path to prove sightedness from.
    ///
    /// **Write-only from here, and the type is what makes that true.**
    /// `CriticalTemperatureRecording` has two methods — `beganReading()` and
    /// `record(_:since:)` — and neither reads, so `sighting()` is not reachable from this
    /// actor at all. Declaring the concrete `CriticalTemperatureCache`
    /// here — as this field first did — left the cycle one line away from deciding a thermal
    /// emergency on a reading up to `maxAge` old, with only a doc comment in the way: exactly
    /// the outcome `SightednessProving` says must never happen, arrived at from the side the
    /// original trick did not cover.
    ///
    /// The exclusion runs in the other direction too: `CriticalTemperatureCache` is not a
    /// `CriticalTemperatureSensing`, so it cannot be handed to `telemetry` above by mistake.
    /// See `SightednessProving`, `CriticalTemperatureRecording`, and
    /// [ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md).
    ///
    /// **Required, with no default**, for the reason `LeaseAuthority` gives about its latch:
    /// a defaulted cache would compile and record into something no grant reads, which is a
    /// coalescing mechanism that silently does nothing while every test still passes.
    private let sightings: any CriticalTemperatureRecording
    private let writer: SafetyActorWriter<Plane>
    private let leases: LeaseAuthority
    private let latch: ThermalEmergencyLatch
    private let log: SafetyLog

    /// The fresh `F<n>Md` read that decides whether a fan owed one may be forgotten (#295).
    ///
    /// **Required, with no default**, for `sightings`' reason: a defaulted reader would
    /// compile and answer from something no firmware stands behind, and every owed fan
    /// would either clear on nothing or never clear, with every test still passing. The
    /// composition root passes `StartupReconciliation`, whose plane reads are `.supervisor`.
    private let handbackReadBack: any HandbackReadingBack

    /// The ceiling this instance compares against, after the downward-only rule.
    ///
    /// `nonisolated` because it is immutable and `Sendable`: it is settled in the
    /// initialiser and cannot change, so requiring an actor hop to read a compiled-in
    /// number would buy nothing and would put a suspension point in front of every log
    /// line and assertion that mentions it.
    nonisolated let ceilingCelsius: Double

    /// The temperature at or below which the latch releases.
    ///
    /// `ceilingCelsius - ThermalCeiling.releaseHysteresisCelsius`, derived once here rather
    /// than recomputed at each comparison — a margin subtracted in two places is a margin
    /// that can disagree with itself.
    nonisolated let releaseThresholdCelsius: Double

    /// Whether the previous cycle failed to read anything at all.
    ///
    /// Collapses the blind path to one line per transition. `DegradationMemo` sits inside
    /// `CuratedCriticalTemperatures` and is only reached *after* a successful gate, so it
    /// cannot see this path — and a supervisor at 1 Hz that logged every blind cycle would
    /// emit ~86,400 lines a day, one variant of them at `.fault`, burying
    /// `thermalEmergencyEngaged`. That is #124's forward constraint applied to the lines
    /// this type added rather than only to the one it inherited: an unrecognised Mac
    /// resolves to the empty curated set, whose read throws **every cycle, forever**, and
    /// that is the documented steady state for every unmeasured machine rather than an edge
    /// case.
    private var lastCycleWasUnreadable = false

    /// The permit for every fan currently off Apple's thermal management.
    ///
    /// Keyed by index so a second registration of the same fan replaces rather than
    /// duplicates. Empty is the ordinary state: no lease, nothing to take back.
    private var engagedFans: [Int: CommandableFan] = [:]

    /// Fans in `engagedFans` whose handback the firmware **accepted**, each owed a read-back
    /// before this registry forgets it (#295). See `handbackAccepted(fanAt:)`.
    ///
    /// **Invariant: its keys are always a subset of `engagedFans`' keys.** A fan enters only
    /// through `handbackAccepted(fanAt:)`, which refuses one that is not registered, and every
    /// path that removes a fan from `engagedFans` goes through `forget(fanAt:)`, which removes
    /// it here too. `manualControlEngaged(_:)` drops the entry as well, without dropping the
    /// registration: a fan engaged again is held again, and owes nothing.
    private var handbackOwed: [Int: OwedReadBack] = [:]

    /// Fans § 3 bridged and restored **itself**, kept until a read shows the restore took
    /// (#300). See `restoredByEmergency(_:)`.
    ///
    /// **Invariant: it never shares a fan with `engagedFans`.** A fan enters only through
    /// `restoredByEmergency(_:)`, which forgets it from `engagedFans` first, and
    /// `manualControlEngaged(_:)` removes it here as it registers it there.
    ///
    /// **Only `fire(_:from:)` bridges these, and that is the bound.** `fire` runs once per
    /// episode — `latch.engage(by:answering:)` admits one caller per clear-to-engaged
    /// transition — so a fan that keeps reading manual is bridged at most once per episode.
    /// Take-back runs on every latched cycle and never reads this map: a fan in it that
    /// reads manual would otherwise be bridged at loop rate, which is ADR 0011 D2's standing
    /// fight.
    private var restoredUnconfirmed: [Int: RestoredFan] = [:]

    /// Stamps every `handbackAccepted(fanAt:)`, so a read that began before a newer handback
    /// cannot clear it. Monotonic for the life of the actor; `&+=` because a wrap after
    /// 2⁶⁴ handbacks is not a case, and a trap in a root daemon's safety actor would be.
    private var handbackGeneration: UInt64 = 0

    /// Which `manualControlEngaged(_:)` each registered fan's entry in `engagedFans` came from,
    /// so a bridge can tell whether its fan was engaged **again** while it awaited (#305).
    ///
    /// A stamp, not a comparison of permits: `CommandableFan` is a value, and engaging the
    /// same fan again mints an equal one from the same envelope — the two registrations are
    /// indistinguishable by the permit alone. Monotonic, drawn from `engagementGeneration`,
    /// so a later registration never carries an earlier stamp — that, not the clearing, is
    /// what the guard relies on. Keys track `engagedFans`': set with it in
    /// `manualControlEngaged(_:)`, cleared with it in `forget(fanAt:)`. A stale stamp left
    /// behind would change no decision, since any new registration outnumbers it, so the
    /// clearing is bookkeeping and no test can make it fail.
    private var engagedAt: [Int: UInt64] = [:]

    /// The source of `engagedAt`'s stamps. `&+=` for `handbackGeneration`'s reason.
    private var engagementGeneration: UInt64 = 0

    /// One fan § 3 restored itself: the permit the next emergency bridges it with, and what
    /// has been logged about its read-back — `OwedReadBack`'s sticky rule, per restore.
    ///
    /// **No generation, unlike `OwedReadBack`, because nothing could restamp one during a
    /// read.** Only `fire(_:from:)` and take-back create an entry, both run inside `cycle()`,
    /// and so does the read — which `isCycling` keeps to one at a time. A generation compared
    /// here would be a guard no test could make fail. What *can* change during the read is
    /// membership — `manualControlEngaged(_:)` removes the entry — and that is re-checked.
    private struct RestoredFan {
        let fan: CommandableFan
        var reported: Set<ReportedReadBack> = []
    }

    /// One owed read-back: which acceptance it answers, and what has already been logged
    /// about it — so a fan that reads manual at 1 Hz is one line, not one per second.
    ///
    /// **A set, not a last-reported value, and each outcome is sticky for the generation.**
    /// A single value flapped: a fan that stays manual while its read intermittently throws
    /// alternated manual, unreadable, manual, and logged a `.fault`/`.notice` pair every two
    /// cycles. Each outcome is now logged at most once per handback, whatever comes between;
    /// a new handback is a new `OwedReadBack` and starts empty.
    private struct OwedReadBack {
        let generation: UInt64
        var reported: Set<ReportedReadBack> = []
    }

    /// A non-clearing outcome already logged for an owed fan. See `OwedReadBack`.
    private enum ReportedReadBack: Hashable {
        case manual
        case unreadable
    }

    /// `requestedCeilingCelsius` is what a *configuration* asked the ceiling to be, and it
    /// runs through `ThermalCeiling.effective(requested:default:)` here rather than being
    /// trusted: `CLAUDE.md` rules 5 and 7 put the check on the side that acts. A request to
    /// *raise* the ceiling is rejected rather than honoured, and a request that is not a
    /// temperature falls back to the compiled default rather than disabling the mechanism —
    /// `min(_:_:)` alone would return NaN and a NaN ceiling makes `temperature > ceiling`
    /// false at every temperature.
    init(
        telemetry: some CriticalTemperatureSensing,
        sightings: some CriticalTemperatureRecording,
        writer: SafetyActorWriter<Plane>,
        leases: LeaseAuthority,
        latch: ThermalEmergencyLatch,
        handbackReadBack: some HandbackReadingBack,
        requestedCeilingCelsius: Double = ThermalCeiling.cpuCelsius,
        log: SafetyLog = SafetyLog()
    ) {
        self.telemetry = telemetry
        self.sightings = sightings
        self.writer = writer
        self.leases = leases
        self.latch = latch
        self.handbackReadBack = handbackReadBack
        self.log = log
        ceilingCelsius = ThermalCeiling.effective(
            requested: requestedCeilingCelsius, default: ThermalCeiling.cpuCelsius)
        releaseThresholdCelsius = ceilingCelsius - ThermalCeiling.releaseHysteresisCelsius
    }

    // MARK: - What is under manual control

    /// Registers the permit for a fan that has just been taken off automatic control.
    ///
    /// Called by whoever performs `FanControlPlane.engageManualControl(of:)` — E3's control
    /// plane, once it exists. That call already requires a `CommandableFan`, so the permit
    /// this needs is always in the caller's hand at exactly the moment it is needed, and
    /// there is never a reason for this type to read one for itself.
    ///
    /// ## The same ordering as § 5, and it costs less to get wrong here
    ///
    /// `ReclamationWatchdog.manualControlEngaged(_:)` mandates that both registrations
    /// happen **after** the `F<n>Md` write lands, and states the argument at length. E3's
    /// author will be looking at one call site with two calls on it, so the constraint is
    /// restated here rather than left to be found in the sibling file.
    ///
    /// What differs is the consequence of disobeying it. § 5 judges a fan the instant it
    /// appears in its registry, so an early registration there costs a client its lease. This
    /// registry is only ever *read* by `fire(_:from:)`, and an early registration means at
    /// worst that a thermal emergency firing inside that same window bridges a fan whose
    /// mode write has not landed — a write against a fan on automatic control, which the
    /// firmware ignores, followed by the restore `fire(_:from:)` performs anyway. The
    /// opposite ordering error, registering late, is bounded to one cycle by
    /// `takeBackAnythingEngagedSinceFiring()`, which exists for exactly that.
    ///
    /// So this is a correctness nicety here and a safety rule there, and the two are stated
    /// together so nobody has to derive that difference at the call site.
    ///
    /// **A fan engaged again owes no read-back** (#295). Its entry in `handbackOwed` is
    /// dropped, so a read already in flight for an earlier handback of it — which may yet
    /// come back automatic, describing the moment before this engagement — finds nothing to
    /// clear, and the fan stays held. Likewise a fan § 3 restored itself (#300): it leaves
    /// `restoredUnconfirmed` as it enters `engagedFans`, so the two never share a fan.
    func manualControlEngaged(_ fan: CommandableFan) {
        engagedFans[fan.index] = fan
        engagementGeneration &+= 1
        engagedAt[fan.index] = engagementGeneration
        handbackOwed[fan.index] = nil
        restoredUnconfirmed[fan.index] = nil
    }

    /// Marks a registered fan whose handback the firmware **accepted** as owed a read-back.
    /// It stays registered — and bridgeable — until § 3's own cycle reads it automatic.
    ///
    /// **Called by `HelperFanRestorer.restoreToAutomatic(fans:because:)`**, after the write
    /// and only for the fans the firmware did not refuse. Every lease teardown path —
    /// released, expired, connection death, revoked, the panic verb — ends in that restorer.
    ///
    /// ## Why accepted is not enough to forget a fan
    ///
    /// Until #295 this was `manualControlReleased(fanAt:)` and dropped the entry outright.
    /// But a write the firmware accepted is not a fan in automatic (#291): firmware can take
    /// `F<n>Md = 0` and leave the fan manual — `ScriptedControlPlane.WriteBehaviour.reverted`
    /// scripts exactly that — and § 3 then forgot a fan still off Apple's thermal management,
    /// which is under-firing: the direction this type's header calls dangerous.
    ///
    /// ## Why the read is not taken here, or by the restorer
    ///
    /// The restorer's path is awaited by § 4's sleep handback and by SIGTERM's teardown, and
    /// each issues the machine-wide keystone only after it returns (ADR 0007). A read there
    /// holds the keystone for as long as the scheduler takes to answer — #294's review
    /// removed exactly such a read from `LeaseAuthority.restore(_:because:)`. So this only
    /// marks, synchronously, and `cycle()` reads from inside § 3's own cycle, which nothing
    /// awaits before a keystone. See `readBackAcceptedHandbacks()`.
    ///
    /// ## What it may not do
    ///
    /// **It never registers.** A fan not in `engagedFans` is ignored: marking one would mint
    /// a registration — and a bridge — for a fan § 3 was never given a permit for, such as
    /// one startup reconciliation handed back (ADR 0011 declines that contest). Each call
    /// stamps a fresh generation, so a read in flight for an older acceptance cannot clear
    /// this one.
    func handbackAccepted(fanAt index: Int) {
        guard engagedFans[index] != nil else { return }
        handbackGeneration &+= 1
        handbackOwed[index] = OwedReadBack(generation: handbackGeneration)
    }

    /// Removes a fan from the registry **and** from the owed set, together.
    ///
    /// The one way anything leaves `engagedFans`, which is what keeps `handbackOwed` a subset
    /// of it: an owed entry for an unregistered fan would be a read issued for nothing and,
    /// worse, a later `forget` cleared by a read about a registration that no longer exists.
    private func forget(fanAt index: Int) {
        engagedFans[index] = nil
        engagedAt[index] = nil
        handbackOwed[index] = nil
    }

    /// Moves a fan § 3 has just bridged and restored out of `engagedFans` and into
    /// `restoredUnconfirmed`, owed a read-back (#300).
    ///
    /// ## Why § 3's own restore is not enough to forget a fan either
    ///
    /// `handbackAccepted(fanAt:)` gives the argument for a restore someone else issued, and
    /// it holds for this one: the firmware can accept `F<n>Md = 0` and leave the fan manual.
    /// Forgotten outright, as it was until #300, the fan was then in no registry at all —
    /// § 5 deregistered it before the restorer's write, the restorer's `handbackAccepted`
    /// found nothing to mark, and the lease core records only fans it had already
    /// abandoned — so no later emergency would bridge it. Under-firing again.
    ///
    /// ## Why it does not stay in `engagedFans`, owed, as a handback does
    ///
    /// Take-back bridges `engagedFans` on every latched cycle, so a fan kept there that reads
    /// manual would be bridged every cycle of the episode it was just bridged in. Kept here,
    /// only the next `fire(_:from:)` bridges it — once, in the next episode.
    private func restoredByEmergency(_ fan: CommandableFan) {
        forget(fanAt: fan.index)
        // A fresh entry, so a fan restored again in a later episode is reported afresh.
        restoredUnconfirmed[fan.index] = RestoredFan(fan: fan)
    }

    /// The fans this instance would fire, for tests and diagnostics.
    var fansUnderManualControl: Set<Int> { Set(engagedFans.keys) }

    /// The registered fans still owed a read-back after an accepted handback, for tests and
    /// diagnostics. Always a subset of `fansUnderManualControl`.
    var fansOwedHandbackReadBack: Set<Int> { Set(handbackOwed.keys) }

    /// The fans § 3 restored itself and has not yet read automatic, for tests and
    /// diagnostics. Never shares a fan with `fansUnderManualControl`.
    var fansRestoredUnconfirmed: Set<Int> { Set(restoredUnconfirmed.keys) }

    // MARK: - One cycle

    /// Whether a cycle is in flight. See `cycle()`'s "one cycle at a time".
    private var isCycling = false

    /// Samples the curated critical set once and acts on it.
    ///
    /// Never throws. There is nobody to report to: the supervisor driving this is a loop in
    /// a root daemon, and an error escaping here would either kill the loop or be swallowed
    /// at the call site — the same reasoning `FanRestoring` gives for its own signature.
    /// Every failure below becomes a decision plus a log line instead.
    ///
    /// - Note: the driver is `ThermalSupervisor`. Its cadence, and whether these reads take
    ///   priority over a client snapshot on the single SMC connection, is
    ///   [#127](https://github.com/blamechris/Aeolus/issues/127)'s to settle — which is why
    ///   this method takes no clock and schedules nothing.
    ///
    /// ## One cycle at a time, by construction
    ///
    /// This actor is reentrant and carries state across its awaits —
    /// `lastCycleWasUnreadable`, the registry, and the pair of latch reads the
    /// episode-boundary guard below compares across `readCriticalTemperatures()` — so two
    /// cycles in flight at once are two decisions taken from one sample's worth of evidence.
    /// `ThermalSupervisor.stop()` cancels without awaiting, so a stop-then-start across
    /// sleep/wake reaches exactly that: the incoming loop's first `cycle()` runs while the
    /// outgoing one is still suspended inside its read
    /// ([#144](https://github.com/blamechris/Aeolus/issues/144)).
    ///
    /// A second entrant returns having done nothing, rather than waiting its turn — and it
    /// is dropped to serialise the mechanism, not because its evidence is stale. The cycle
    /// already in flight is acting on a reading it has taken; the entrant has taken none,
    /// so an entrant that queued would read *after* the incumbent returned and would hold
    /// the fresher sample of the two. What makes dropping it right is that it has nothing
    /// to add: § 3 is driven at a fixed cadence, an entrant exists at all only because a
    /// stop-then-start overlapped two loops, and queueing would run cycles back to back —
    /// spending two supervisor turns on the single SMC connection inside an interval
    /// budgeted for one, on a machine whose temperature cannot have moved far between them.
    ///
    /// Nothing is carried past the return, which is what makes it safe to drop: `cycle()`
    /// takes its own `readCriticalTemperatures()` below on every entry and keeps no sample
    /// between calls, so the next scheduled cycle asks "is it cool enough to release?"
    /// against a reading taken after this one finished rather than against anything this
    /// entrant would have brought.
    func cycle() async {
        guard !isCycling else { return }
        isCycling = true
        defer { isCycling = false }

        // Read **before** the report, and compared against the episode read after it. A
        // release is only ever decided against a temperature this cycle actually measured,
        // and an episode that began during the read below was never measured — see the
        // episode-boundary guard.
        let episodeBeforeRead = await latch.holding

        // Every real read of the curated set is left where the grant path can prove
        // sightedness from it — **successes and failures both**, which is what makes a retry
        // storm free during blindness as well as during health. A cache written only on
        // success would leave every retry issuing its own read on precisely the machine that
        // can least afford one, and each of those reads would fail. See ADR 0010.
        // Taken **before** the read, and handed back with its outcome. The instant is the
        // cache's own — see `CriticalTemperatureRecording` for why it is not this type's to
        // stamp — and it is what lets the cache tell this reading from a fresher one
        // recorded while the read below was in flight.
        //
        // The placement is the assertion, not an incidental line. Moved under the read it is
        // never older than anything recorded during it, so the comparison silently becomes a
        // no-op and every grant is served a sighting taken before the machine stopped
        // answering ([#280](https://github.com/blamechris/Aeolus/issues/280)). Pinned by the
        // clock advance in `aCycleDoesNotOverwriteABlindnessRecordedDuringItsRead`.
        let readingStart = await sightings.beganReading()

        let report: CriticalTemperatureReport
        do {
            report = try await telemetry.readCriticalTemperatures()
            await sightings.record(.sighted(report), since: readingStart)
        } catch {
            // Through the same call as the success path. A blindness bypasses the comparison
            // — that is the cache's invariant, argued at `record(_:since:)`, and it is no
            // longer a second entry point this `catch` has to know to choose.
            await sightings.record(.blind(error), since: readingStart)
            await cycleSawNothing(String(describing: error))
            return
        }

        // `CriticalTemperatureReport` cannot be constructed empty, so this is unreachable —
        // and it is treated as a cycle that saw nothing rather than as a quiet `return`,
        // because the failure asymmetry decides unreachable branches too. A `return` here
        // would be a released latch on a machine nobody read.
        guard let hottest = report.readings.max(by: { $0.celsius < $1.celsius }) else {
            await cycleSawNothing("a critical temperature report arrived with no readings")
            return
        }

        if lastCycleWasUnreadable {
            lastCycleWasUnreadable = false
            log.thermalEmergencyTelemetryRecovered(answered: report.readings.count)
        }

        // The bit and the key set qualifying it come out of the latch **together**, in one
        // isolated step. Two hops, or a qualifier cached here while the bit lived over
        // there, is #150's shape exactly.
        guard let episode = await latch.holding else {
            if hottest.celsius > ceilingCelsius {
                await fire(hottest, from: report)
            } else {
                // Last, and only here: the latch is clear and this cycle did not fire. See
                // `readBackAcceptedHandbacks()` for why every other path skips it.
                await readBackAcceptedHandbacks()
            }
            return
        }

        // Latched — but is it the episode this cycle read the temperature of? The report was
        // gathered before the latch was looked at, so an episode that engaged in between is
        // *younger than the reading in hand*, and the reading in hand describes the machine
        // before it went over its ceiling. Judging that episode against it is releasing on a
        // measurement of the wrong episode: `acquireLease` stops refusing, and the client
        // that was just revoked retries into the workload that fired the emergency a
        // millisecond ago.
        //
        // The answer is not to re-read the temperature — the cycle has one report and it is
        // stale for this episode, whatever it says. It is to decline to judge, hold, and let
        // the next cycle decide on a reading taken after the episode began. Holding one extra
        // cycle is the over-firing direction; releasing is not.
        //
        // `nil` before and an episode after is the ordinary shape of this: the latch was
        // clear when the report was taken, so the report is a measurement of a machine that
        // was not in an emergency.
        guard episode.sequence == episodeBeforeRead?.sequence else {
            log.thermalEmergencyHeldAcrossEpisodeBoundary()
            await takeBackAnythingEngagedSinceFiring()
            return
        }

        // Before asking whether it is cool enough to let go, ask whether this cycle can
        // still see everything it could see when it fired. A shrinking view reads exactly
        // like a cooling machine, and only one of those is safe to act on — see
        // `ThermalEmergencyLatch.Episode.keysAnsweringAtEngage`.
        let answeringNow = Set(report.readings.map(\.key))
        let keysAnsweringAtEngage = episode.keysAnsweringAtEngage
        guard keysAnsweringAtEngage.isSubset(of: answeringNow) else {
            log.thermalEmergencyHeldThroughDegradedCycle(
                missing: keysAnsweringAtEngage.subtracting(answeringNow).count,
                atEngage: keysAnsweringAtEngage.count)
            await takeBackAnythingEngagedSinceFiring()
            return
        }

        // Asked against a *fresh* reading — a latch tested against the reading that engaged
        // it would never release. Nothing is cleared here: the key set went with the episode
        // inside `release(ifStill:)`, which is the whole of #150's fix.
        //
        // `ifStill:` closes the last hop in the chain. The guard above establishes that the
        // episode is older than the report; this establishes that it is still the episode by
        // the time the clear actually lands, one more suspension point later. A `release()`
        // that cleared whatever it found would take the boundary case the guard above exists
        // to refuse and reintroduce it between the decision and the act.
        //
        // **A refused compare-and-clear falls through to the take-back below rather than
        // into a branch of its own.** It means the episode ended and, if anything is holding
        // now, a newer one began — so this cycle's decision was about something that no
        // longer exists, and the safe reading of "I do not know what is holding" is the same
        // take-back the still-hot path already does. Written as its own `else` body it was a
        // *duplicate* of that statement which no test could reach: only a second cycle
        // running concurrently can move the latch inside this one hop, and
        // `ThermalSupervisor` is the sole driver until
        // [#127](https://github.com/blamechris/Aeolus/issues/127) — so `fatalError()` could
        // stand in that body, and the take-back could be deleted from it, with the whole
        // suite green. An unreachable copy of a reachable statement is exactly where #152's
        // shape reappears unnoticed. One statement, then, and deleting it goes red.
        if hottest.celsius <= releaseThresholdCelsius, await latch.release(ifStill: episode) {
            log.thermalEmergencyReleased(hottest: hottest, threshold: releaseThresholdCelsius)
            return
        }

        // Still holding — above the release threshold, or judged against an episode that has
        // since moved on. `fire(_:)` empties the registry as it goes, so anything in it now
        // came under manual control **after** the emergency fired — a fan whose lease was
        // granted in the window described on `LeaseAuthority.revokeEveryLease(because:)`,
        // or one engaged under a lease that raced the latch. Without this the emergency is
        // one-shot per episode: `fire(_:)` is unreachable while latched, so such a fan
        // would never be bridged, never restored, and its lease never revoked, with the
        // machine above its ceiling the whole time. Idempotent, and silent on an empty
        // table.
        await takeBackAnythingEngagedSinceFiring()
    }

    /// Bridges and hands back fans that came under manual control while § 3 was already
    /// holding, and revokes whatever lease covered them.
    ///
    /// Idempotent and normally a no-op: while the latch holds, `acquireLease` is refused,
    /// so in the ordinary case nothing new can be engaged and the registry stays empty.
    private func takeBackAnythingEngagedSinceFiring() async {
        guard !engagedFans.isEmpty else {
            // Still revoke, because a lease can exist without a fan having been engaged
            // under it yet — that is the case the registry cannot see.
            await leases.revokeEveryLease(because: .thermalEmergency)
            return
        }
        let engagedSince = engagedFans.values.sorted { $0.index < $1.index }
        log.thermalEmergencyTakingBackLateEngagement(fans: engagedSince.map(\.index))
        // `engagedFans` only. `restoredUnconfirmed` is `fire(_:from:)`'s alone — see it.
        for fan in engagedSince {
            await bridgeThenFileRestored(fan)
        }
        await leases.revokeEveryLease(because: .thermalEmergency)
    }

    // MARK: - Accepted handbacks (#295)

    /// Reads every fan owed a read-back once — handed back (`handbackOwed`) or restored by
    /// § 3 itself (`restoredUnconfirmed`, #300) — and forgets each that reads automatic.
    ///
    /// ## Where it runs, and where it does not
    ///
    /// **Only on a sighted cycle with the latch clear that did not fire, and last.** The
    /// other paths already act on an owed fan without a read, or must not spend a turn on
    /// one: a firing cycle bridges and restores every registered and every restored fan, and
    /// moves each into `restoredUnconfirmed` whatever those writes did; a latched cycle
    /// takes back whatever is registered, the same way; and a blind cycle is a machine whose
    /// SMC is not answering, where one more `.supervisor` read would only fail. A read that
    /// never runs keeps the fan owed — a machine blind between episodes still bridges it in
    /// the next one. Taken last so it
    /// never delays a decision the cycle exists to make. It runs inside `isCycling`, so an
    /// overlapping entrant cannot issue a second read.
    ///
    /// **No retry, and it is not on a keystone's path.** A fan that does not read stays owed
    /// until the next eligible cycle asks again; nothing awaits this cycle before issuing a
    /// restore — which is the whole reason the read lives here and not in
    /// `HelperFanRestorer` (see `handbackAccepted(fanAt:)`).
    ///
    /// ## What it may conclude
    ///
    /// Only *forget*, and only a fan that read automatic **and** whose owed entry still
    /// carries the generation this read was asked for. The set is snapshotted before the
    /// await and re-checked after it, on `ReclamationWatchdog.cycle()`'s rule: a fan engaged
    /// again while the read was out has no entry, and one handed back again has a newer
    /// generation, and in both cases this read describes a moment that has been superseded.
    /// A fan in `restoredUnconfirmed` is re-checked by membership alone — see `RestoredFan`
    /// for why no generation is needed there.
    /// A fan that reads manual, will not read, or is absent from the answer keeps its
    /// registration and its entry. Nothing is ever added from a read, and nothing reaches
    /// `LeaseAuthority` — this is § 3's registry and no one else's.
    ///
    /// ## No cap, deliberately
    ///
    /// A fan that keeps reading manual — a firmware that never took the handback, or another
    /// program that has since taken the fan — stays owed for as long as it does, at one read
    /// per eligible cycle. `F<n>Md` names no owner, so the two are indistinguishable, and the
    /// costs are not symmetrical. Wrongly *keeping* it costs one bridge in the next
    /// emergency, after which `fire(_:from:)` moves it to `restoredUnconfirmed`, where only
    /// the emergency after that bridges it again: one act per emergency, bounded by
    /// `fire`'s once-per-episode guard, never ADR 0011's standing fight. Wrongly *dropping*
    /// it is #295 and #300 — a fan off automatic control that no emergency will bridge.
    /// Throttling the read is a later cost optimisation, not a safety question.
    private func readBackAcceptedHandbacks() async {
        guard !handbackOwed.isEmpty || !restoredUnconfirmed.isEmpty else { return }
        let asked = handbackOwed.mapValues(\.generation)
        let askedRestored = Set(restoredUnconfirmed.keys)
        // One call for both: the two maps never share a fan, so the union loses nothing.
        let readings = await handbackReadBack.handbackReadings(
            of: Set(asked.keys).union(askedRestored))

        for fan in askedRestored.sorted() {
            // Re-fetched after the await, never carried across it: a fan engaged again while
            // the read was out has left this map for `engagedFans`, and writing a carried
            // copy back would put it in both. See `RestoredFan` for why membership suffices.
            guard var restored = restoredUnconfirmed[fan] else { continue }
            switch readings[fan] ?? .unreadable(detail: "the read-back did not answer for it") {
            case .automatic:
                restoredUnconfirmed[fan] = nil
                log.thermalEmergencyRestoreConfirmed(fan: fan)
            case .manual:
                guard restored.reported.insert(.manual).inserted else { continue }
                restoredUnconfirmed[fan] = restored
                log.thermalEmergencyRestoreStillManual(fan: fan)
            case .unreadable(let detail):
                guard restored.reported.insert(.unreadable).inserted else { continue }
                restoredUnconfirmed[fan] = restored
                log.thermalEmergencyRestoreUnreadable(fan: fan, detail: detail)
            }
        }

        for (fan, generation) in asked.sorted(by: { $0.key < $1.key }) {
            // Re-fetched after the await, never carried across it.
            guard var owed = handbackOwed[fan], owed.generation == generation else { continue }
            switch readings[fan] ?? .unreadable(detail: "the read-back did not answer for it") {
            case .automatic:
                forget(fanAt: fan)
                log.thermalEmergencyHandbackConfirmed(fan: fan)
            case .manual:
                guard owed.reported.insert(.manual).inserted else { continue }
                handbackOwed[fan] = owed
                log.thermalEmergencyHandbackStillManual(fan: fan)
            case .unreadable(let detail):
                guard owed.reported.insert(.unreadable).inserted else { continue }
                handbackOwed[fan] = owed
                log.thermalEmergencyHandbackUnreadable(fan: fan, detail: detail)
            }
        }
    }

    // MARK: - Firing

    /// Engages the latch, bridges every held fan to maximum, releases them to automatic,
    /// and revokes the leases that covered them.
    ///
    /// ## The order is the design
    ///
    /// 1. **Latch first, before any write.** The latch is what refuses the next
    ///    `acquireLease`, and a client asking during the writes below would otherwise be
    ///    granted a lease over a fan this method is in the middle of taking back.
    /// 2. **Maximum, as one write.** A fail-safe bridge across however long the OS takes to
    ///    re-assume control of a fan that was sitting at whatever speed a user chose.
    ///    Ungoverned: see `SafetyWriters.swift` for why that is structural and
    ///    `RampGovernor` for the 22-second arithmetic that makes it necessary.
    /// 3. **Restore to automatic.** The destination. Attempted whether or not step 2
    ///    landed.
    /// 4. **Revoke every live lease, whole** — not per-fan surgery, and not one revocation
    ///    per bridged fan. A lease is a claim over a set of fans, and a client left holding
    ///    a lease over a *subset* it can no longer command would be told it has control it
    ///    does not have, which is `CLAUDE.md` rule 6. Selecting on the bridged fans instead
    ///    left a lease alive through an emergency whenever the client had not yet engaged
    ///    manual control under it; `LeaseAuthority.revokeEveryLease(because:)` records that
    ///    defect and the grant-time window it also closes. The restore revocation triggers
    ///    is idempotent, and is deliberately the second one: ADR 0007's keystone makes the
    ///    restore this actor's own terminal action, never something it delegates to the
    ///    lease core.
    ///
    /// ## Every fan, not "the affected fan"
    ///
    /// The curated set is package and die temperatures with no per-fan attribution — and
    /// none is available, because a Mac's fans cool a shared thermal mass rather than one
    /// component each. Firing every fan under manual control is therefore the honest
    /// reading of "the affected fan", and it is the over-firing direction, which this
    /// mechanism resolves toward by design.
    private func fire(
        _ hottest: CriticalTemperature, from report: CriticalTemperatureReport
    ) async {
        // `engage(by:answering:)` reports whether it engaged a latch that was **clear**, and
        // that answer is decided inside the latch actor — so exactly one caller can get
        // `true` however many cycles are in flight. Guarding on it here is what keeps this
        // method from running twice.
        //
        // `cycle()` already found `latch.holding` empty before calling this, and that check
        // is not enough on its own: reading the latch is a suspension point, this actor is
        // reentrant across it, and two overlapping cycles could both find it clear and both
        // fire. The supervisor awaits each cycle before sleeping so its own loop cannot
        // produce that interleaving, but `cycle()` is reachable from anywhere and #127 may
        // yet drive it on a different schedule. Same reasoning as `acquireLease`'s
        // straight-line region: a check separated from the act it guards is not a check.
        //
        // Firing twice would not be *dangerous* — over-firing is the safe direction, and
        // both writes are idempotent — but it would log § 3's one `.fault` line twice for
        // one event, which is exactly the reader-hostile shape #124's forward constraint is
        // about.
        //
        // **No test drives that interleaving, and this sentence is here so nobody deletes
        // the guard believing one does.** Dropping the `guard else { return }` and letting
        // `engage(by:answering:)`'s `@discardableResult` swallow the answer leaves the whole
        // suite green — checked by mutation, not assumed. Forcing the losing order needs both
        // cycles to read the latch before either engages it, and nothing available to a test
        // can arrange that:
        // a gated telemetry double gets both past the read and cannot order what they do
        // next, a gate inside the latch would mean instrumenting production code for a
        // test, and a repeat-until-it-races loop would be flaky, which #109 is already open
        // about. A test asserting "two concurrent cycles produce one write" was written and
        // then **deleted**, because it passed with this guard removed — a test that cannot
        // fail is worse than no test, since it retires the question.
        //
        // What *is* tested is the atomicity this relies on:
        // `ThermalEmergencyTests.theLatchReportsTransitionsNotState` pins
        // `engage(by:answering:)` reporting the transition rather than the state, and that
        // decision happens inside the latch actor, so exactly one of any number of concurrent
        // callers is told `true`.
        // `LeaseAuthority.restore(_:because:)` carries the same admission about its
        // `releasing` count, for the same reason and in the same words.
        guard
            await latch.engage(by: hottest, answering: Set(report.readings.map(\.key)))
        else { return }

        // Every registered fan **and** every fan an earlier episode restored without the
        // restore being seen to take (#300). This is the only place the second map is
        // bridged, and the guard above is what bounds it to once per episode — see
        // `restoredUnconfirmed`. The two never share a fan, so nothing is bridged twice.
        let held = (Array(engagedFans.values) + restoredUnconfirmed.values.map(\.fan))
            .sorted { $0.index < $1.index }
        log.thermalEmergencyEngaged(
            hottest: hottest, ceiling: ceilingCelsius, fansHeld: held.count)

        for fan in held {
            await bridgeThenFileRestored(fan)
        }
        // Every lease, not one per bridged fan. A client can hold a live lease without
        // having engaged manual control under it yet, and such a fan is in no registry —
        // selecting on `engagedFans` here left exactly that lease alive through an
        // emergency. See `LeaseAuthority.revokeEveryLease(because:)`.
        await leases.revokeEveryLease(because: .thermalEmergency)
    }

    /// Bridges one fan, then files it as restored by § 3 — **unless it was engaged again
    /// while the bridge awaited** (#305).
    ///
    /// The bridge is two writes, and this actor is reentrant across both. A
    /// `manualControlEngaged(_:)` for the same fan that lands after the restore write is a
    /// client taking the fan off automatic *after* § 3 put it back, and filing the fan as
    /// restored would forget that newer registration: take-back reads only `engagedFans`, so
    /// the fan would go unbridged for the rest of the episode. Left registered, the next
    /// latched cycle's take-back bridges it — the over-firing direction. Registration already
    /// moved it out of `restoredUnconfirmed`, so the two maps still never share a fan.
    ///
    /// "Engaged again" means a registration carrying a stamp other than the one captured
    /// before the bridge. A fan with no stamp now — nothing registers it, whether it came
    /// from `restoredUnconfirmed` or was forgotten — is filed as before.
    private func bridgeThenFileRestored(_ fan: CommandableFan) async {
        let registration = engagedAt[fan.index]
        await bridgeToMaximumThenRelease(fan)
        if let now = engagedAt[fan.index], now != registration { return }
        restoredByEmergency(fan)
    }

    /// One fan: maximum in a single write, then back to automatic.
    ///
    /// Neither failure stops the other. A firmware that refuses the maximum write is
    /// exactly the machine that most needs the restore attempted, and swallowing either
    /// error would convert "the fans are still pinned" into "the emergency completed" —
    /// the inversion this subsystem exists to prevent, which is why this repository's
    /// `no_silent_write_failure` rule refuses `try?` outright.
    private func bridgeToMaximumThenRelease(_ fan: CommandableFan) async {
        do {
            let commanded = try await writer.commandMaximum(of: fan)
            log.emergencyCommandedMaximum(fan: fan.index, rpm: commanded.rpm)
        } catch {
            log.emergencyWriteFailed(
                verb: "command maximum on", fan: fan.index, detail: String(describing: error))
        }

        do {
            try await writer.restoreToAutomatic(.fan(fan.index))
        } catch {
            log.emergencyWriteFailed(
                verb: "restore", fan: fan.index, detail: String(describing: error))
        }
    }

    /// A cycle that obtained no temperature at all.
    ///
    /// It changes **the latch** not at all. A latch stays latched — the asymmetry's second
    /// branch — and a clear latch stays clear, because firing on one unreadable cycle would
    /// take the fans from a client on a transient. Persistent read failure is divergence,
    /// and the reconnect-then-restore-and-report escalation belongs to
    /// [#126](https://github.com/blamechris/Aeolus/issues/126); until then this is the line
    /// that makes the condition visible rather than silent.
    ///
    /// ## It does still take back what it finds, and that is not the same thing
    ///
    /// `LeaseAuthority.revokeEveryLease(because:)` names a grant-time window it cannot close
    /// from its own side, and the mitigation it names is *"the emergency taking back whatever
    /// it finds, every cycle it holds."* This branch used to return before reaching that, so
    /// the sentence was false on exactly the machine where it matters most: the SMC stops
    /// answering, every cycle returns here, and the lease granted in the window survives —
    /// renewed indefinitely, because `renewLease` consults neither the latch nor telemetry.
    /// A client holding manual control through an emergency the mechanism believes it took
    /// back is `CLAUDE.md` rule 6.
    ///
    /// It needs no reading to do it, and `revokeEveryLease` is idempotent and silent on an
    /// empty table, so the steady blind state costs nothing and logs nothing. The latch read
    /// can go stale across its hop like any other; the direction it can be wrong in is
    /// over-firing, against declining to take back on a machine nobody can read.
    ///
    /// - Note: [#152](https://github.com/blamechris/Aeolus/issues/152).
    private func cycleSawNothing(_ detail: String) async {
        let wasAlreadyUnreadable = lastCycleWasUnreadable
        lastCycleWasUnreadable = true
        let holding = await latch.isActive

        // Log the transition, not the state. See `lastCycleWasUnreadable`.
        if !wasAlreadyUnreadable {
            if holding {
                log.thermalEmergencyHeldThroughUnreadableCycle(detail: detail)
            } else {
                log.thermalEmergencyCycleUnreadable(detail: detail)
            }
        }

        guard holding else { return }
        await takeBackAnythingEngagedSinceFiring()
    }

    /// Whether § 3 is currently holding, for a supervisor that needs to say so on its way
    /// out. Reads the latch rather than caching it.
    var isHolding: Bool {
        get async { await latch.isActive }
    }
}
