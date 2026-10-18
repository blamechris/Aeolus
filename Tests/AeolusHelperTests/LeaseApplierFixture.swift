import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Level 6 on a `ReclamationMachine`: the real `LeaseApplier`, wired to the machine's lease core,
/// § 3's latch, the fans' examination gate and § 5 as `HelperComposition.init` wires it, and
/// writing through `writes`, the machine's own plane or a double over it.
///
/// Its driver is level 6's own, at `.controlLoop`, stepping through a `SafetyActorWriter` whose
/// level is provenance nothing reads (`.leaseExpiry` here: the lease is what level 6 writes
/// under); the driver's clock is the lease core's, as § 5's is. Its lines go to the machine's
/// `safetyLog`, so a scenario reads level 6's and § 5's in one order.
struct LevelSix<Writes: FanControlPlane>: Sendable {
    let applier: LeaseApplier<Writes>
    /// The governed writer `applier` holds, for the ramp memory's assertions.
    let writer: GovernedFanWriter<Writes>
    /// The connection the machine's leases are bound to.
    let holder: ConnectionID

    /// `applier.apply(settings, leaseID: lease, from: holder)`.
    func apply(_ settings: [FanSetting], under lease: UUID) async throws {
        try await applier.apply(settings, leaseID: lease, from: holder)
    }
}

extension ReclamationMachine {

    /// Level 6 over this machine, writing through `writes`.
    ///
    /// - Parameters:
    ///   - writes: the plane level 6's writer and driver write through.
    ///   - reclamation: § 5 as level 6 sees it; the machine's watchdog unless a scenario wraps it.
    ///   - envelopes: where envelopes are read; `writes` unless a scenario refuses them.
    ///   - capability: what the write path reports; `writes` unless a scenario asks `.notBuilt`.
    ///   - registration: § 3's registration role as level 6's driver reaches it; the machine's § 3
    ///     unless a scenario records what the driver tells it.
    /// - Returns: level 6, wired to this machine.
    func levelSix<Applies: FanControlPlane>(
        writingThrough writes: Applies,
        reclamation: (any ReclamationRegistrationRole)? = nil,
        envelopes: (any FanEnvelopeReading)? = nil,
        capability: (any FanWriteCapabilityReporting)? = nil,
        registration: (any ThermalEmergencyRegistering)? = nil
    ) -> LevelSix<Applies> {
        let log = SafetyLog(recording: { [safetyLog] in safetyLog.append($0, $1) })
        let writer = GovernedFanWriter(plane: writes)
        let driver = EngagementDriver(
            writer: SafetyActorWriter(plane: writes, level: .leaseExpiry), leases: leases,
            latch: latch, emergency: registration ?? emergency, clock: leaseClock,
            level: .controlLoop, log: log)
        let applier = LeaseApplier(
            writer: writer, engagement: driver, gate: gate, envelopes: envelopes ?? writes,
            reclamation: reclamation ?? watchdog, leases: leases, latch: latch,
            writeCapability: capability ?? writes, log: log)
        return LevelSix(applier: applier, writer: writer, holder: holder)
    }

    /// Level 6 writing through the machine's own plane.
    func levelSix() -> LevelSix<ScriptedControlPlane> {
        levelSix(writingThrough: plane)
    }

    /// The machine's live lease, which every level-6 scenario applies under.
    func leaseID() async throws -> UUID {
        try #require(await leases.activeLease(), "no lease to apply under").id
    }
}

/// `.fixed(rpm:)` settings, one per `(fan, rpm)`, in the order given.
func fixed(_ targets: (fan: Int, rpm: Double)...) -> [FanSetting] {
    targets.map { FanSetting(fanIndex: $0.fan, control: .fixed(rpm: $0.rpm)) }
}

/// Level 6 for an authority a test builds by hand to drive something other than `apply`: the
/// panic verb, the snapshot's sighting. It records an issue if it is asked, so a suite that meant
/// to leave `apply` alone cannot pass by reaching it. The authority the composition builds holds
/// the real `LeaseApplier` (ADR 0014's A6 PR-3 amendment).
struct NoLevelSix: LeaseApplying {
    func apply(
        _ settings: [FanSetting], leaseID lease: UUID, from connection: ConnectionID
    ) async throws {
        Issue.record("an authority built to test something other than apply was asked to apply")
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }
}

/// § 5 for an authority a test builds by hand with no § 5 behind it: no fan is held, so no target
/// is recorded. The composition's authority holds the real watchdog (#410).
actor NothingRecorded: ReclamationReporting {
    func recordedTargets(under lease: UUID) -> [Int: Double] { [:] }
}

/// A write path that reports itself not built, for item 5's `.notBuilt` row. A state only a test
/// can produce: a lease granted on a capability the write path does not share.
struct NotBuiltWritePath: FanWriteCapabilityReporting {
    var writeCapability: FanWriteCapability { .notBuilt }
}

/// The fault an `invalidParameter(name: "settings")` refusal carries.
func settingsRefused(_ detail: String) -> AeolusXPCFault {
    .invalidParameter(name: "settings", detail: detail)
}

/// What a scenario saw from inside a write or a step, in order.
actor Sightings<Value: Sendable> {
    private(set) var seen: [Value] = []

    func record(_ value: Value) { seen.append(value) }
}
