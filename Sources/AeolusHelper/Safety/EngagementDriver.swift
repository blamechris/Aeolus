import Foundation

/// The unlock's cadence, as constants: the driver's, where `RestoreLimits` bounds the opposite
/// direction ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md) D3).
enum UnlockLimits {

    /// The pause between two steps of one engagement. No turn is held across it (D7), so § 3's
    /// reads and every restore are admitted between steps.
    static let pollInterval: Duration = .milliseconds(100)

    /// How long an engagement waits for the firmware to yield before it undoes and refuses: run
    /// 1's 3.5 s, so at most 35 steps. Sized to the report (U3). `apply`'s client deadline is
    /// derived from the gate's bounds, which count this, so raising it needs no client change
    /// while it stays within `WatchdogLimits.gateWaiterAlarm`. Past that it lengthens
    /// `FanExaminationGate.lawfulHold`, and `HelperClientDeadlineTests` requires the client's copy
    /// to follow. A budget that proves too short fails safe.
    static let yieldBudget: Duration = .milliseconds(3_500)
}

/// § 3's half of what an engagement owes it
/// ([#181](https://github.com/blamechris/Aeolus/issues/181)): the registry its emergency
/// bridges, and the mark that hands a fan back to § 3's own read-back. `ThermalEmergency`'s two
/// verbs, as a role, so the driver can be handed § 3 without its cycle.
protocol ThermalEmergencyRegistering: Sendable {

    /// A fan just came off automatic control under `fan`'s permit.
    func manualControlEngaged(_ fan: CommandableFan) async

    /// The firmware accepted this fan's restore. § 3 keeps it registered until its own cycle
    /// reads it automatic (#295); a fan never told this stays bridgeable.
    func handbackAccepted(fanAt index: Int) async
}

extension ThermalEmergency: ThermalEmergencyRegistering {}

/// Why the driver refused an engagement around a step.
enum EngagementRefusal: Error, Sendable, Hashable {

    /// § 3's latch outranks the driver's level: ADR 0009 D1's ruling, read at the write.
    case preempted(fan: Int, by: SafetyActorLevel)

    /// The lease the act runs under is not live or does not cover the fan, or the driver was
    /// never bound to one: ADR 0009 D2, asked about that lease and no other (#357).
    case leaseNotLive(fan: Int)

    /// `UnlockLimits.yieldBudget` elapsed with the firmware still holding the fan.
    case yieldDidNotArrive(fan: Int, steps: Int)

    /// Whether the fan is no longer the caller's to hold — a higher level has it, or the lease it
    /// is held under is not live — rather than refused by the firmware. § 5 hands such a fan back
    /// instead of spending another attempt on it.
    var yieldsTheFan: Bool {
        switch self {
        case .preempted, .leaseNotLive: return true
        case .yieldDidNotArrive: return false
        }
    }
}

/// What became of the writes of an engagement that was refused, for the log.
enum EngagementAftermath: Sendable, Hashable {
    /// Nothing was written.
    case nothingWritten
    /// The fan was registered with § 3 and handed back, and the restore was accepted.
    case undone
    /// The hand-back was refused: the fan may still be off automatic control.
    case undoRefused
}

/// The cadence of an engagement: the entitlement before and after every step, the poll interval
/// and yield budget between steps, the § 3 registration, and the undo (ADR 0014 D2, D4).
///
/// The sequence — which keys, which values, what an answer means — is the plane's, one step per
/// turn. This owns everything around the steps, and nothing holds a turn across them.
///
/// ## Its sources are stored, never arguments
///
/// The lease core, § 3's latch, its arbiter level, and § 3's registration role are set at
/// composition. The lease is the one exception: the caller binds it per engagement with
/// `under(lease:)`, and the composed driver is bound to none, so it refuses every step (#357).
/// Its verbs still take one permit and nothing else, and the lease is always judged against
/// **the permit's own index**: the fan whose lease is checked cannot differ from the fan being
/// written.
///
/// ## Two drivers, one per caller, each at its own level
///
/// § 5's is composed at `.reclamationWatchdog` and level 6's at `.controlLoop` (ADR 0014's A6
/// amendments). The level is the driver's own, passed in and stored, and never read from its
/// writer: level 6's driver holds a `SafetyActorWriter`, whose level is one of the five that
/// bypass § 8, for the step and the undo alone, and the arbiter must be asked about the control
/// loop, not about whatever provenance that writer carries. The driver exposes no target verb, so
/// the control loop holds no writer it can command a target through but `GovernedFanWriter`.
///
/// ## What it checks, and what is left
///
/// Before each step, the bound lease must be live and cover the fan, and `SafetyArbiter` must
/// permit the driver's level against § 3's latch. For § 5 the check before the first step is the
/// pre-engage ruling #181 asks for. Inside each later step the plane checks its restore epoch,
/// so no later step writes after a restore requested first. After `.engaged`, the fan is
/// registered with § 3 and the entitlement asked again.
///
/// **The checks are not atomic with the write, and saying the window is closed would be the more
/// dangerous spelling** (ADR 0009 D1): a lease can end, or § 3 latch, between a check and the
/// step's turn — and the epoch, which an engagement records *at* its first step, does not see a
/// restore requested before that turn. That residual is discharged by acting and then checking:
/// every genuine restore ends the lease (immediately before or right after the restore) or latches
/// § 3, the entitlement is asked again after the step, and the fan is undone. It asks about the
/// engagement's own lease, so one granted over the fan once that restore returned does not answer
/// for it (ADR 0014's 2026-10-15 amendment). The undo is a write the firmware can refuse, so the
/// fan is registered with § 3 **before** it — after `.engaged`, before the after-check; otherwise
/// just before the undo — and stays in the registry § 3's next latched cycle bridges, until a read
/// confirms it automatic.
///
/// ## The undo
///
/// On any throw once a step may have written, the fan is registered with § 3 and handed back
/// (`handBack(fanAt:)`) — `.supersededAfterWrite` included, whose mode write may have landed. A
/// throw before any step answered gets neither when nothing was written: the entitlement
/// refused before the first step or its retry, a first step superseded at its admission twice,
/// or a first step refused as `.notAutomatic` — the fan was someone else's, and writing it back
/// to automatic would be ADR 0011's contest.
struct EngagementDriver<Plane: FanControlPlane>: Sendable {

    private let writer: SafetyActorWriter<Plane>
    /// The level `SafetyArbiter` is asked about: the caller's, stored at composition.
    let level: SafetyActorLevel
    private let leases: LeaseAuthority
    private let latch: ThermalEmergencyLatch
    private let emergency: any ThermalEmergencyRegistering
    private let clock: any MonotonicClock
    private let log: SafetyLog
    /// The lease this engagement runs under. `nil` at composition, which refuses every step.
    private var lease: UUID?

    /// - Parameters:
    ///   - writer: the writer whose step verb this drives, and whose restore is the undo. Its
    ///     level is provenance only, and the arbiter is never asked about it.
    ///   - leases: the lease core, asked `hasLiveLease(id:coveringFan:)` about the bound lease
    ///     and the permit's fan.
    ///   - latch: § 3's latch, read for the arbiter's incumbent.
    ///   - emergency: § 3's registration role, told of every fan this engages and hands back.
    ///   - clock: what the poll interval and the yield budget are measured on. The composition's
    ///     own, so a test that moves the lease clock moves this one with it.
    ///   - level: the level the arbiter is asked about before and after every step:
    ///     `.reclamationWatchdog` for § 5, `.controlLoop` for level 6. Required, with no default,
    ///     so no driver is composed at a level nobody chose (#362).
    ///   - log: where refusals, undo failures and engagements are reported.
    init(
        writer: SafetyActorWriter<Plane>,
        leases: LeaseAuthority,
        latch: ThermalEmergencyLatch,
        emergency: any ThermalEmergencyRegistering,
        clock: any MonotonicClock,
        level: SafetyActorLevel,
        log: SafetyLog = SafetyLog()
    ) {
        self.writer = writer
        self.level = level
        self.leases = leases
        self.latch = latch
        self.emergency = emergency
        self.clock = clock
        self.log = log
    }

    /// This driver, bound to the lease an engagement runs under: § 5's record's, or the one
    /// level 6's `apply` authorised (ADR 0014, 2026-10-15 amendment). Synchronous and
    /// permit-free; it writes nothing.
    func under(lease id: UUID) -> EngagementDriver {
        var bound = self
        bound.lease = id
        return bound
    }

    /// Takes one fan off automatic control, a step at a time, or refuses having handed it back.
    ///
    /// Returns once the plane answered `.engaged`, the fan is registered with § 3, and the
    /// entitlement still holds. Throws `EngagementRefusal` for the driver's own refusals and
    /// whatever the plane threw for its; in both cases the undo, if one was owed, has run.
    func engageManualControl(of fan: CommandableFan) async throws {
        let index = fan.index
        // The ticket, then the entitlement, with no suspension between them: a restore requested
        // after the entitlement answered is then one the first step's admission sees.
        writer.beginEngagement(fanAt: index)
        try await requireEntitlement(for: fan)

        let began = clock.now
        let deadline = began + UnlockLimits.yieldBudget
        var steps = 1
        var answered = false
        var registered = false
        do {
            var answer = try await firstStep(of: fan)
            answered = true
            while answer == .awaitingYield {
                let next = clock.now + UnlockLimits.pollInterval
                guard next < deadline else {
                    throw EngagementRefusal.yieldDidNotArrive(fan: index, steps: steps)
                }
                try await clock.sleep(until: next)
                try Task.checkCancellation()
                try await requireEntitlement(for: fan)
                steps += 1
                answer = try await writer.engageManualControl(of: fan)
            }
            await emergency.manualControlEngaged(fan)
            registered = true
            try await requireEntitlement(for: fan)
        } catch {
            guard answered || !Self.wroteNothing(error) else {
                log.engagementRefused(
                    fan: index, steps: steps, detail: String(describing: error),
                    aftermath: .nothingWritten)
                throw error
            }
            if !registered { await emergency.manualControlEngaged(fan) }
            var aftermath = EngagementAftermath.undone
            do {
                try await handBack(fanAt: index)
            } catch let undo {
                aftermath = .undoRefused
                log.engagementUndoRefused(fan: index, detail: String(describing: undo))
            }
            log.engagementRefused(
                fan: index, steps: steps, detail: String(describing: error), aftermath: aftermath)
            throw error
        }
        log.engagementEngaged(fan: index, steps: steps, waited: began.duration(to: clock.now))
    }

    /// The first step, retried **once** when the plane's admission answers `.superseded`.
    ///
    /// `.superseded` is thrown only by the step's admission, before it reads or writes anything,
    /// so the first step wrote nothing. A first step is superseded there when a restore of any fan
    /// was requested after its ticket, or when the plane is sealed for exit; the stale record an
    /// earlier engagement's undo left no longer does it, because the ticket clears it (ADR 0014's
    /// #410 amendment). The retry takes a fresh ticket, then asks the entitlement again, in that
    /// order: a restore that was real ended the lease (immediately before or right after the
    /// restore: a lease teardown, § 4, § 7, § 6's exit, § 5's `finaliseRelease`) or came with
    /// § 3's latch, and either refuses here. A second `.superseded` is a restore requested during
    /// the retry itself, or the exit's seal, and stops the engagement with nothing written.
    ///
    /// **`.supersededAfterWrite` is never retried.** It is found after the step's mode write,
    /// which may have landed, so it goes to the undo like any other refusal of a step that wrote.
    private func firstStep(of fan: CommandableFan) async throws -> EngagementStep {
        do {
            return try await writer.engageManualControl(of: fan)
        } catch FanControlPlaneError.superseded {
            log.engagementFirstStepRetried(fan: fan.index)
            writer.beginEngagement(fanAt: fan.index)
            try await requireEntitlement(for: fan)
            return try await writer.engageManualControl(of: fan)
        }
    }

    /// Whether a throw before any step answered left nothing of this engagement's written: the
    /// retry's entitlement refusal, or a first step refused before its write — at its admission
    /// (`.superseded`) or at its pre-state (`.notAutomatic`). `.supersededAfterWrite` is not one.
    private static func wroteNothing(_ error: any Error) -> Bool {
        if error is EngagementRefusal { return true }
        switch error as? FanControlPlaneError {
        case .superseded?, .notAutomatic?: return true
        default: return false
        }
    }

    /// The undo, and the hand-back § 5 issues for a fan it gives up: restore, then tell § 3 the
    /// handback was accepted so it reads the fan back before forgetting it (#181, #295).
    ///
    /// A refused restore tells § 3 nothing, so a fan this driver registered stays where the next
    /// emergency bridges it. Takes the fan's index and never its permit: it reaches a write only
    /// through `restoreToAutomatic`.
    func handBack(fanAt index: Int) async throws {
        try await writer.restoreToAutomatic(.fan(index))
        await emergency.handbackAccepted(fanAt: index)
    }

    /// The entitlement: § 3's latch through `SafetyArbiter`, then the lease table about the
    /// bound lease, both asked now and both about the permit's own index. An unbound driver is
    /// refused here, so it never steps.
    ///
    /// Asked before and after every step, and by § 5 before a re-assert's command on a fan that
    /// needs no mode write — the same question, so the two cannot come to differ.
    func requireEntitlement(for fan: CommandableFan) async throws {
        let index = fan.index
        let incumbent: SafetyActorLevel? = await latch.isActive ? .thermalEmergency : nil
        if case .preempted(let by) = SafetyArbiter.ruling(for: level, incumbent: incumbent) {
            throw EngagementRefusal.preempted(fan: index, by: by)
        }
        guard let lease, await leases.hasLiveLease(id: lease, coveringFan: index) else {
            throw EngagementRefusal.leaseNotLive(fan: index)
        }
    }
}
