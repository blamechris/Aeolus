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
    private let writer: SafetyActorWriter<Plane>
    private let leases: LeaseAuthority
    private let latch: ThermalEmergencyLatch
    private let log: SafetyLog

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

    /// `requestedCeilingCelsius` is what a *configuration* asked the ceiling to be, and it
    /// runs through `ThermalCeiling.effective(requested:default:)` here rather than being
    /// trusted: `CLAUDE.md` rules 5 and 7 put the check on the side that acts. A request to
    /// *raise* the ceiling is rejected rather than honoured, and a request that is not a
    /// temperature falls back to the compiled default rather than disabling the mechanism —
    /// `min(_:_:)` alone would return NaN and a NaN ceiling makes `temperature > ceiling`
    /// false at every temperature.
    init(
        telemetry: some CriticalTemperatureSensing,
        writer: SafetyActorWriter<Plane>,
        leases: LeaseAuthority,
        latch: ThermalEmergencyLatch,
        requestedCeilingCelsius: Double = ThermalCeiling.cpuCelsius,
        log: SafetyLog = SafetyLog()
    ) {
        self.telemetry = telemetry
        self.writer = writer
        self.leases = leases
        self.latch = latch
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
    func manualControlEngaged(_ fan: CommandableFan) {
        engagedFans[fan.index] = fan
    }

    /// Forgets a fan that has gone back to Apple's thermal management.
    ///
    /// **Nothing calls this yet, and that is an obligation on E3 rather than dead code.**
    /// `fire(_:)` clears the registry for every fan it takes back, so the registry cannot
    /// grow without bound today; but a lease released, expired, or torn down by connection
    /// death restores its fans through `LeaseAuthority` without telling this actor, so a
    /// stale permit can sit here for a fan that is already automatic. The consequence is
    /// bounded and in the safe direction — the emergency would bridge a fan that is already
    /// on Apple's management, which is a redundant write and then a redundant restore, not
    /// an unsafe state — but it makes `fire(_:)`'s "every fan under manual control" read
    /// more precisely than the registry can currently deliver.
    ///
    /// `LeaseAuthority` deliberately holds no reference to the emergency (see
    /// `ThermalEmergencyLatch`), so the notification belongs to whoever owns both: E3's
    /// control plane, at the same point it calls `manualControlEngaged(_:)`.
    func manualControlReleased(fanAt index: Int) {
        engagedFans[index] = nil
    }

    /// The fans this instance would fire, for tests and diagnostics.
    var fansUnderManualControl: Set<Int> { Set(engagedFans.keys) }

    // MARK: - One cycle

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
    func cycle() async {
        // Read **before** the report, and compared against the episode read after it. A
        // release is only ever decided against a temperature this cycle actually measured,
        // and an episode that began during the read below was never measured — see the
        // episode-boundary guard.
        let episodeBeforeRead = await latch.holding

        let report: CriticalTemperatureReport
        do {
            report = try await telemetry.readCriticalTemperatures()
        } catch {
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
            if hottest.celsius > ceilingCelsius { await fire(hottest, from: report) }
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
        if hottest.celsius <= releaseThresholdCelsius {
            guard await latch.release(ifStill: episode) else {
                // The episode ended and, if anything is holding now, a newer one began — in
                // either case this cycle's decision was about something that no longer
                // exists, and the safe reading of "I do not know what is holding" is to take
                // back whatever is engaged. Idempotent, and silent on an empty table.
                await takeBackAnythingEngagedSinceFiring()
                return
            }
            log.thermalEmergencyReleased(hottest: hottest, threshold: releaseThresholdCelsius)
            return
        }

        // Still holding. `fire(_:)` empties the registry as it goes, so anything in it now
        // came under manual control **after** the emergency fired — a fan whose lease was
        // granted in the window described on `LeaseAuthority.revokeEveryLease(because:)`,
        // or one engaged under a lease that raced the latch. Without this the emergency is
        // one-shot per episode: `fire(_:)` is unreachable while latched, so such a fan
        // would never be bridged, never restored, and its lease never revoked, with the
        // machine above its ceiling the whole time.
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
        for fan in engagedSince {
            await bridgeToMaximumThenRelease(fan)
            engagedFans[fan.index] = nil
        }
        await leases.revokeEveryLease(because: .thermalEmergency)
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
        log.thermalEmergencyEngaged(
            hottest: hottest, ceiling: ceilingCelsius, fansHeld: engagedFans.count)

        let held = engagedFans.values.sorted { $0.index < $1.index }
        for fan in held {
            await bridgeToMaximumThenRelease(fan)
            engagedFans[fan.index] = nil
        }
        // Every lease, not one per bridged fan. A client can hold a live lease without
        // having engaged manual control under it yet, and such a fan is in no registry —
        // selecting on `engagedFans` here left exactly that lease alive through an
        // emergency. See `LeaseAuthority.revokeEveryLease(because:)`.
        await leases.revokeEveryLease(because: .thermalEmergency)
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
