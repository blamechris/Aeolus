import AeolusXPC
import FanKit
import Foundation

/// Level 6's `apply`: a client's `.fixed(rpm:)` settings, written under the lease it holds, one
/// fan at a time under that fan's examination gate
/// ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)'s A6 and A6 PR-2 amendments).
///
/// ## Built only by tests
///
/// `HelperComposition` does not build this and `SupervisedFanAuthority.apply` does not reach it:
/// A6's next step wires it to the privilege boundary, and nothing on `main` can observe it. On a
/// `.notBuilt` build it is unreachable however it is wired, because no lease is granted there and
/// `apply` asks `heldLease(id:from:)` before anything else.
///
/// ## The order is the design
///
/// 1. `heldLease(id:from:)`, the ownership check: another connection's lease, or one that has
///    lapsed, never reaches the driver (item 1), and its faults are the client's answer.
/// 2. The write capability, `.writePathNotBuilt`.
/// 3. Item 0, `LeaseApplyRules.goals(of:coveredBy:)`: only `.fixed(rpm:)` is honoured, checked
///    before anything is read or written.
/// 4. Each fan, in index order, through `step(_:toFanAt:under:engaging:)`: its envelope read and
///    its permit, then its gate, and under that one hold the whole of its step.
/// 5. Item 4: the lease and § 3's latch again, so the reply never says applied under a lease
///    that has ended or a latch that has set.
///
/// A refusal in step 4 undoes what this `apply` engaged (`undo(_:under:)`), outside every gate,
/// and is answered by item 5's table (`refusal(for:leaseID:from:)`).
///
/// ## One hold per fan, one gate at a time, and no hand-back under one
///
/// Under a fan's gate: engage it if this lease has not, register it with § 5, ask the entitlement,
/// write its target whole, and report what the write returned. Nothing else: no envelope read, no
/// other fan, no second gate and no hand-back. A registration under the gate is before any
/// examination of the fan, never inside one, so it stands no re-assert down (#381); a report under
/// it is what the next examination judges against, so the comparison is exact in both orders
/// (#383); and an engagement under it cannot overlap § 5's re-engage, which runs under § 5's hold
/// (#389). The undo runs after the gate is left and enters none, because a hand-back held up by a
/// holder is a hand-back that does not happen.
///
/// ## What it holds, and what it never names
///
/// `GovernedFanWriter` for targets; an `EngagementDriver` of its own at `.controlLoop`, for the
/// engagement, the entitlement and the undo; the gate; the envelope read; § 5 through
/// `ReclamationRegistrationRole`; the lease core; and § 3's latch. It never names a
/// `SafetyActorWriter`: its driver holds one and exposes no target verb, so the only target verb
/// level 6 holds is the governed writer's. `LeaseApplierTripwireTests` holds that by census.
///
/// ## Reentrancy
///
/// An actor, and every `await` is a point another `apply` can run at. Its one piece of state is
/// `engagements`, keyed by lease and reached only through its transitions, so an `apply` under a
/// lease that has ended cannot disturb a newer lease's account. What one call needs, its lease,
/// its bound driver and the fans it engaged, is local to the call.
actor LeaseApplier<Plane: FanControlPlane> {

    /// The only holder of a target verb here: `hold(_:of:)` writes each fixed setting whole.
    private let writer: GovernedFanWriter<Plane>

    /// Level 6's own driver, composed at `.controlLoop`, and bound per call to the lease `apply`
    /// authorised. Its undo is the hand-back.
    private let engagement: EngagementDriver<Plane>

    /// The fans' examination gate: the composition's one instance, which § 5 takes too.
    private let gate: FanExaminationGate

    /// Where each fan's envelope is read, afresh, before its gate is taken.
    private let envelopes: any FanEnvelopeReading

    /// § 5, as the three calls level 6 makes.
    private let reclamation: any ReclamationRegistrationRole

    /// The lease core, for `heldLease(id:from:)` before anything else and again before replying.
    private let leases: LeaseAuthority

    /// § 3's bit, read before replying (item 4).
    private let latch: ThermalEmergencyLatch

    /// Whether the build behind the writer can write at all: the plane itself, in composition.
    private let writeCapability: any FanWriteCapabilityReporting

    private let log: SafetyLog

    /// Which fans this has engaged under which lease, and not handed back since: risk 14's
    /// authority for "this lease has engaged the fan".
    private var engagements = LeaseEngagements()

    /// Every parameter is required, with no default (#362): a gate, a latch or a § 5 of its own
    /// would be one nothing else consults.
    init(
        writer: GovernedFanWriter<Plane>,
        engagement: EngagementDriver<Plane>,
        gate: FanExaminationGate,
        envelopes: any FanEnvelopeReading,
        reclamation: any ReclamationRegistrationRole,
        leases: LeaseAuthority,
        latch: ThermalEmergencyLatch,
        writeCapability: any FanWriteCapabilityReporting,
        log: SafetyLog
    ) {
        self.writer = writer
        self.engagement = engagement
        self.gate = gate
        self.envelopes = envelopes
        self.reclamation = reclamation
        self.leases = leases
        self.latch = latch
        self.writeCapability = writeCapability
        self.log = log
    }

    /// The level `engagement` asks the arbiter about, `.controlLoop`, for the test that pins it.
    nonisolated var engagementLevel: SafetyActorLevel { engagement.level }

    // MARK: - Applying

    /// Writes `settings` under `leaseID`, in the order this type's documentation gives, or
    /// refuses having undone what it engaged.
    func apply(
        _ settings: [FanSetting], leaseID lease: UUID, from connection: ConnectionID
    ) async throws {
        let record = try await leases.heldLease(id: lease, from: connection)
        guard writeCapability.writeCapability == .built else {
            throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        }
        let goals = try LeaseApplyRules.goals(of: settings, coveredBy: record.fanIndices)

        var engaged: [Int] = []
        do {
            for goal in goals {
                try await step(goal.rpm, toFanAt: goal.fan, under: lease, engaging: &engaged)
            }
        } catch {
            await undo(engaged, under: lease)
            log.controlLoopApplyRefused(handingBack: engaged, detail: String(describing: error))
            throw await refusal(for: error, leaseID: lease, from: connection)
        }

        _ = try await leases.heldLease(id: lease, from: connection)
        guard await !latch.isActive else { throw AeolusXPCFault.thermalEmergencyActive }
    }

    /// One fan's step: the envelope and the permit, then the gate, and under it the engagement if
    /// this lease has not engaged the fan, § 5's registration, the entitlement, the whole write
    /// and its report.
    ///
    /// `engaged` gains the fan as soon as the driver's engagement returns, so a refusal after it
    /// undoes it with the rest (item 2, and risk 7's half-landed engagement). The ramp memory is
    /// reset at the engagement, so nothing later ramps from a target written before the fan last
    /// went back to automatic. The permit never leaves this function: a verb that took it beside
    /// the lease would carry a value that can disagree with it (ADR 0008).
    private func step(
        _ rpm: Double, toFanAt index: Int, under lease: UUID, engaging engaged: inout [Int]
    ) async throws {
        let envelope: FanEnvelope
        do {
            envelope = try await envelopes.readEnvelope(ofFan: index)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw AeolusXPCFault.manualControlUnavailable(reason: .supervisorBlind)
        }
        let permit: CommandableFan
        switch envelope.commandable {
        case .success(let commandable):
            permit = commandable
        case .failure(let implausible):
            throw AeolusXPCFault.boundsImplausible(
                fanIndex: index, detail: String(describing: implausible))
        }

        guard let pass = await gate.enterForStep(fanAt: index) else {
            throw LeaseApplyRules.GateNotGranted()
        }
        defer { gate.leave(pass) }
        let driver = engagement.under(lease: lease)
        if !engagements.contains(index, under: lease) {
            try await driver.engageManualControl(of: permit)
            engagements.insert(index, under: lease)
            engaged.append(index)
            await writer.fanReturnedToAutomatic(index: index)
        }
        try await reclamation.manualControlEngaged(permit, under: lease)
        try await driver.requireEntitlement(for: permit)
        let commanded = try await writer.hold(rpm, of: permit)
        await reclamation.commandedTarget(commanded, under: lease)
    }

    /// Hands back every fan in `fans`, the ones this `apply` engaged, in the order it engaged
    /// them: § 5's record first, under the lease, so § 5 never reads the restore as a
    /// reclamation and re-engages a fan the client was told was refused; then the driver's
    /// hand-back, which restores the fan and tells § 3, and leaves one whose restore is refused in
    /// § 3's registry; then the ramp memory and `engagements`. Outside every gate, and waiting for
    /// none (items 2 and 7, risk 5).
    private func undo(_ fans: [Int], under lease: UUID) async {
        for index in fans {
            await reclamation.manualControlHandedBack(fanAt: index, under: lease)
            do {
                try await engagement.handBack(fanAt: index)
            } catch {
                log.controlLoopHandBackRefused(fan: index, detail: String(describing: error))
            }
            await writer.fanReturnedToAutomatic(index: index)
            engagements.remove(index, under: lease)
        }
    }

    /// Item 5's answer to a refusal from the per-fan loop: `LeaseApplyRules.answer(to:)`, with the
    /// one row that needs the lease core asked here. A superseded step, a gate not granted or a
    /// lease that was not live is `.releaseInProgress` while the lease still stands, and otherwise
    /// the fault `heldLease(id:from:)` throws now.
    private func refusal(
        for error: any Error, leaseID lease: UUID, from connection: ConnectionID
    ) async -> any Error {
        switch LeaseApplyRules.answer(to: error) {
        case .unchanged:
            return error
        case .fault(let fault):
            return fault
        case .releaseInProgressUnlessTheLeaseHasGone:
            do {
                _ = try await leases.heldLease(id: lease, from: connection)
            } catch {
                return error
            }
            return AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)
        }
    }
}

// MARK: - Item 0 and item 5, as values

/// What `LeaseApplier.apply` refuses before it reads anything, and what it answers a refusal with:
/// items 0 and 5 of ADR 0014's A6 amendment, as values a test drives directly. Not generic over the
/// plane, so the fixed details are stored once.
enum LeaseApplyRules {

    /// What a fan's step answers when its gate was not granted: `stepWait` ran out, or the wait
    /// was cancelled. Never crosses the boundary: `answer(to:)` maps it.
    struct GateNotGranted: Error, Sendable {}

    /// Item 5's table, for a refusal from the per-fan loop.
    enum Answer: Sendable, Hashable {
        /// Thrown as it is: a fault already in the client's vocabulary, or a cancellation, which
        /// says nothing about the machine.
        case unchanged
        /// This fault.
        case fault(AeolusXPCFault)
        /// `.releaseInProgress` while the lease stands, and otherwise the lease's own fault.
        case releaseInProgressUnlessTheLeaseHasGone
    }

    /// The fixed details of the faults this answers with: helper-authored, and quoting nothing a
    /// client sent.
    enum Detail {
        static let noSettings = "no fan settings were given"
        static let automatic = "an automatic setting is not applied: release the lease instead"
        static let curve = "a curve setting is not honoured until the curve evaluator exists"
        static let uncovered = "a setting names a fan the lease does not cover"
        static let duplicate = "a setting names the same fan twice"
        static let yieldDidNotArrive =
            "the firmware did not yield the fan to manual control in time"
        static let firmwareRefused = "the firmware refused a write to the fan"
        static let notConfirmed = "the firmware did not confirm manual control of the fan"
        static let unexpected = "the fan's write did not complete"
    }

    /// Item 0: each fan's goal, in index order, or `invalidParameter(name: "settings")`.
    ///
    /// Checked in this order: an empty list; then, setting by setting, `.automatic`, `.curve`, a
    /// fan the lease does not cover, and a fan named twice. `.curve` has no evaluator until #17,
    /// and `.automatic` is the lease's release, not a setting.
    static func goals(
        of settings: [FanSetting], coveredBy fans: Set<Int>
    ) throws -> [(fan: Int, rpm: Double)] {
        guard !settings.isEmpty else { throw refused(Detail.noSettings) }
        var goals: [Int: Double] = [:]
        for setting in settings {
            let rpm: Double
            switch setting.control {
            case .fixed(let fixed): rpm = fixed
            case .automatic: throw refused(Detail.automatic)
            case .curve: throw refused(Detail.curve)
            }
            guard fans.contains(setting.fanIndex) else { throw refused(Detail.uncovered) }
            guard goals[setting.fanIndex] == nil else { throw refused(Detail.duplicate) }
            goals[setting.fanIndex] = rpm
        }
        return goals.sorted { $0.key < $1.key }.map { (fan: $0.key, rpm: $0.value) }
    }

    private static func refused(_ detail: String) -> AeolusXPCFault {
        .invalidParameter(name: "settings", detail: detail)
    }

    /// Item 5's table, as a value. `.helperFailed` stands for the D3 outcomes R1 has not observed
    /// yet, and for anything the table does not name: no new reason crosses the boundary before R1
    /// (D3).
    static func answer(to error: any Error) -> Answer {
        switch error {
        case is AeolusXPCFault, is CancellationError:
            return .unchanged
        case is GateNotGranted:
            return .releaseInProgressUnlessTheLeaseHasGone
        case let refusal as EngagementRefusal:
            switch refusal {
            case .preempted: return .fault(.thermalEmergencyActive)
            case .leaseNotLive: return .releaseInProgressUnlessTheLeaseHasGone
            case .yieldDidNotArrive: return .fault(.helperFailed(detail: Detail.yieldDidNotArrive))
            }
        case let plane as FanControlPlaneError:
            switch plane {
            case .superseded, .supersededAfterWrite:
                return .releaseInProgressUnlessTheLeaseHasGone
            case .notAutomatic:
                return .fault(.manualControlUnavailable(reason: .foreignManualControl))
            case .firmwareRefusedControl:
                return .fault(.helperFailed(detail: Detail.firmwareRefused))
            case .engagementNotConfirmed:
                return .fault(.helperFailed(detail: Detail.notConfirmed))
            default:
                return .fault(.helperFailed(detail: Detail.unexpected))
            }
        default:
            return .fault(.helperFailed(detail: Detail.unexpected))
        }
    }
}

// MARK: - Which fans this lease has engaged

/// Which fans level 6 has engaged under which lease, and not handed back since: risk 14's authority
/// for "this lease has engaged the fan", as a value (ADR 0014's A6 PR-2 amendment).
///
/// Keyed by lease. A fan joins when the driver's engagement returns under that lease, and leaves
/// when the undo hands it back. The first engagement under a lease drops every other lease's fans:
/// one live lease covers a fan at a time, so a lease that engages has outlived every other. Dropped
/// when `apply` is authorised instead, a call whose lease ended between `heldLease` answering and
/// its resumption would erase the account of the lease granted since, whose next re-apply would
/// then re-engage its own fans and be refused `.notAutomatic`; a call under an ended lease cannot
/// engage, because its driver's entitlement refuses it. A fan a teardown, § 3 or § 5 handed back
/// under a lease that is still live stays here: #381's one-cycle residual.
struct LeaseEngagements: Sendable {

    private var fans: [UUID: Set<Int>] = [:]

    /// Whether `index` was engaged under `lease` and not handed back since.
    func contains(_ index: Int, under lease: UUID) -> Bool {
        fans[lease]?.contains(index) == true
    }

    /// The leases with a fan engaged, for tests.
    var leases: Set<UUID> { Set(fans.keys) }

    /// An engagement of `index` under `lease` returned.
    mutating func insert(_ index: Int, under lease: UUID) {
        fans = fans.filter { $0.key == lease }
        fans[lease, default: []].insert(index)
    }

    /// `index` was handed back under `lease`.
    mutating func remove(_ index: Int, under lease: UUID) {
        fans[lease]?.remove(index)
        if fans[lease]?.isEmpty == true { fans[lease] = nil }
    }
}
