/// The unlock's cadence, as constants: the driver's, where `RestoreLimits` bounds the opposite
/// direction ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md) D3).
enum UnlockLimits {

    /// The pause between two steps of one engagement. No turn is held across it (D7), so § 3's
    /// reads and every restore are admitted between steps.
    static let pollInterval: Duration = .milliseconds(100)

    /// How long an engagement waits for the firmware to yield before it undoes and refuses: run
    /// 1's 3.5 s, so at most 35 steps. Sized to the client rather than to the report — it leaves
    /// `HelperClientDeadlines.gatedVerb`'s 5 s room for the target write and its read-back — and
    /// a budget that proves too short fails safe.
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

    /// No live lease covers the fan: ADR 0009 D2, through #180's per-fan query.
    case leaseNotLive(fan: Int)

    /// `UnlockLimits.yieldBudget` elapsed with the firmware still holding the fan.
    case yieldDidNotArrive(fan: Int, steps: Int)

    /// Whether the fan is no longer the caller's to hold — a higher level has it, or no lease
    /// covers it — rather than refused by the firmware. § 5 hands such a fan back instead of
    /// spending another attempt on it.
    var yieldsTheFan: Bool {
        switch self {
        case .preempted, .leaseNotLive: return true
        case .yieldDidNotArrive: return false
        }
    }
}

/// The cadence of an engagement: the entitlement before and after every step, the poll interval
/// and yield budget between steps, the § 3 registration, and the undo (ADR 0014 D2, D4).
///
/// The sequence — which keys, which values, what an answer means — is the plane's, one step per
/// turn. This owns everything around the steps, and nothing holds a turn across them.
///
/// ## Its sources are stored, never arguments
///
/// The lease core's per-fan liveness query, § 3's latch, its writer's level, and § 3's
/// registration role are set at composition. So its verb takes one permit and nothing else, and
/// it always asks about **the permit's own index**: the fan whose lease is checked cannot differ
/// from the fan being written.
///
/// ## What it checks, and what is left
///
/// Before each step, a live lease must cover the fan and `SafetyArbiter` must permit the
/// writer's level against § 3's latch. For § 5 the check before the first step is the
/// pre-engage ruling #181 asks for. Inside each step the plane checks its restore epoch, so no
/// forward write lands after a restore requested first. After `.engaged`, the fan is registered
/// with § 3 and the entitlement asked again.
///
/// **The checks are not atomic with the write, and saying the window is closed would be the
/// more dangerous spelling** (ADR 0009 D1): a lease can end, or § 3 latch, between a check and
/// the step's turn. That residual is discharged by acting and then checking — the after-check,
/// then the undo — and the undo is a write the firmware can refuse. Registering with § 3
/// **before** the after-check is what covers a refused undo: the fan stays in the registry § 3's
/// next latched cycle bridges, until a read confirms it automatic.
///
/// ## The undo
///
/// On any throw once a step has been issued, the fan is handed back (`handBack(fanAt:)`). Two
/// throws have nothing of this engagement's to undo, and get no restore: an entitlement refused
/// before the first step, and a first step refused as `.notAutomatic` — the fan was someone
/// else's, and writing it back to automatic would be ADR 0011's contest.
struct EngagementDriver<Plane: FanControlPlane>: Sendable {

    private let writer: SafetyActorWriter<Plane>
    private let level: SafetyActorLevel
    private let leases: LeaseAuthority
    private let latch: ThermalEmergencyLatch
    private let emergency: any ThermalEmergencyRegistering
    private let clock: any MonotonicClock
    private let log: SafetyLog

    /// - Parameters:
    ///   - writer: the writer whose step verb this drives, and whose restore is the undo. Its
    ///     level is the one the arbiter is asked about.
    ///   - leases: the lease core, asked `hasLiveLease(coveringFan:)` about the permit's fan.
    ///   - latch: § 3's latch, read for the arbiter's incumbent.
    ///   - emergency: § 3's registration role, told of every fan this engages and hands back.
    ///   - clock: what the poll interval and the yield budget are measured on. The composition's
    ///     own, so a test that moves the lease clock moves this one with it.
    ///   - log: where refusals, undo failures and engagements are reported.
    init(
        writer: SafetyActorWriter<Plane>,
        leases: LeaseAuthority,
        latch: ThermalEmergencyLatch,
        emergency: any ThermalEmergencyRegistering,
        clock: any MonotonicClock,
        log: SafetyLog = SafetyLog()
    ) {
        self.writer = writer
        level = writer.level.level
        self.leases = leases
        self.latch = latch
        self.emergency = emergency
        self.clock = clock
        self.log = log
    }

    /// Takes one fan off automatic control, a step at a time, or refuses having handed it back.
    ///
    /// Returns once the plane answered `.engaged`, the fan is registered with § 3, and the
    /// entitlement still holds. Throws `EngagementRefusal` for the driver's own refusals and
    /// whatever the plane threw for its; in both cases the undo has already run.
    func engageManualControl(of fan: CommandableFan) async throws {
        let index = fan.index
        try await requireEntitlement(for: fan)

        let began = clock.now
        let deadline = began + UnlockLimits.yieldBudget
        var steps = 0
        do {
            steps += 1
            while try await writer.engageManualControl(of: fan) == .awaitingYield {
                let next = clock.now + UnlockLimits.pollInterval
                guard next < deadline else {
                    throw EngagementRefusal.yieldDidNotArrive(fan: index, steps: steps)
                }
                try await clock.sleep(until: next)
                try await requireEntitlement(for: fan)
                steps += 1
            }
            await emergency.manualControlEngaged(fan)
            try await requireEntitlement(for: fan)
        } catch {
            if case .notAutomatic? = error as? FanControlPlaneError {
                log.engagementRefused(fan: index, steps: steps, detail: String(describing: error))
                throw error
            }
            do {
                try await handBack(fanAt: index)
            } catch let undo {
                log.engagementUndoRefused(fan: index, detail: String(describing: undo))
            }
            log.engagementRefused(fan: index, steps: steps, detail: String(describing: error))
            throw error
        }
        log.engagementEngaged(fan: index, steps: steps, waited: began.duration(to: clock.now))
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

    /// The entitlement: § 3's latch through `SafetyArbiter`, then the lease table, both asked
    /// now and both about the permit's own index.
    ///
    /// Asked before and after every step, and by § 5 before a re-assert's command on a fan that
    /// needs no mode write — the same question, so the two cannot come to differ.
    func requireEntitlement(for fan: CommandableFan) async throws {
        let index = fan.index
        let incumbent: SafetyActorLevel? = await latch.isActive ? .thermalEmergency : nil
        if case .preempted(let by) = SafetyArbiter.ruling(for: level, incumbent: incumbent) {
            throw EngagementRefusal.preempted(fan: index, by: by)
        }
        guard await leases.hasLiveLease(coveringFan: index) else {
            throw EngagementRefusal.leaseNotLive(fan: index)
        }
    }
}
