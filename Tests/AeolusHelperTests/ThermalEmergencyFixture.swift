import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// One machine, wired the way the composition root will wire it: one scripted plane behind
/// the telemetry *and* the writer, one latch shared by the emergency and the lease core,
/// one recording restorer on the lease side.
///
/// Sharing the plane is what makes a scenario legible. `advance()` moves the temperature
/// the emergency reads **and** the firmware behaviour its writes meet, so "the machine got
/// hot and then the firmware started refusing writes" is two stages rather than two
/// unrelated doubles that have to be kept in step by hand.
///
/// The lease side keeps its own `RecordingFanRestorer` because `FanRestoring` has no
/// conformer that reaches a `FanControlPlane` yet — #102 owns that adapter, and
/// `FanRestoring.swift` says why bridging them is a decision about who owns a failed
/// restore rather than a signature adjustment. Until it exists, the split is also useful:
/// the plane records what § 3 wrote, and the restorer records what the lease core did about
/// it, so a test can tell the two apart.
struct ThermalMachine {

    let plane: ScriptedControlPlane
    /// The declared state each fan started in, kept so `lease(fans:from:)` can mint the
    /// permit E3's control plane will mint from its own `readEnvelope` — without reaching
    /// into the mock's `private` state, which would make the fixture depend on a detail the
    /// mock deliberately does not expose.
    let fanConditions: [Int: ScriptedControlPlane.FanCondition]
    let latch: ThermalEmergencyLatch
    let restorer: RecordingFanRestorer
    let leases: LeaseAuthority
    let emergency: ThermalEmergency<ScriptedControlPlane>

    /// - Parameters:
    ///   - stages: the scenario. The last stage repeats forever.
    ///   - fans: which fans the machine has, and their firmware state.
    ///   - requestedCeilingCelsius: what a configuration asked § 3's ceiling to be. Left at
    ///     the compiled default unless a test is about the downward-only rule.
    init(
        stages: [ScriptedControlPlane.Stage],
        fans: [Int: ScriptedControlPlane.FanCondition] = [0: .nominal, 1: .nominal],
        requestedCeilingCelsius: Double = ThermalCeiling.cpuCelsius
    ) {
        plane = ScriptedControlPlane(fans: fans, stages: stages)
        fanConditions = fans
        latch = ThermalEmergencyLatch()
        restorer = RecordingFanRestorer()

        let telemetry = CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
        leases = LeaseFixture.authority(
            restorer: restorer, telemetry: telemetry, thermalEmergency: latch)
        emergency = ThermalEmergency(
            telemetry: telemetry,
            writer: SafetyActorWriter(plane: plane, level: .thermalEmergency),
            leases: leases,
            latch: latch,
            requestedCeilingCelsius: requestedCeilingCelsius,
            log: SafetyLog(recording: { _ in })
        )
    }

    /// Takes a lease over `fans` and registers each one's permit with the emergency, which
    /// is what E3's control plane will do when it engages manual control.
    @discardableResult
    func lease(
        fans: [Int] = [0], from connection: ConnectionID = ConnectionID()
    ) async throws -> Lease {
        let lease = try await leases.acquireLease(
            LeaseFixture.request(fans: fans), from: connection)
        for index in fans {
            let condition = try #require(fanConditions[index])
            await emergency.manualControlEngaged(
                try commandableFan(index, declaring: condition))
        }
        return lease
    }

    /// Every call the firmware saw, in order.
    var attempts: [ScriptedControlPlane.Attempt] {
        get async { await plane.attempts }
    }

    /// Just the write attempts, which is what an ordering assertion is usually about.
    var writes: [ScriptedControlPlane.Attempt] {
        get async {
            await plane.attempts.filter {
                switch $0 {
                case .commandTarget, .restoreToAutomatic, .engageManualControl: return true
                case .readCriticalTemperatures, .readEnvelope, .readControlState: return false
                }
            }
        }
    }
}

/// Stage constructors for § 3's scenarios.
///
/// On `Stage` rather than on `ThermalMachine`, so `.at(96)` resolves inside the array
/// literal a scenario is written as — which is the whole readability argument
/// `ScriptedControlPlane` makes for stages over flags.
extension ScriptedControlPlane.Stage {

    /// Every curated key reading the same temperature.
    ///
    /// The whole set, not one key: `CriticalSensorSet.mac16x5` is what the production
    /// conformer asks for, and a stage naming a single key would leave the other 33 in
    /// `unreadableKeys` — a degraded cycle, which is a different scenario from a hot one.
    static func temperatures(_ celsius: Double) -> [String: Double] {
        Dictionary(
            uniqueKeysWithValues: CriticalSensorSet.mac16x5.keys.map {
                ($0.rawValue, celsius)
            })
    }

    /// A stage where the machine reads `celsius` everywhere and the firmware honours writes.
    static func at(_ celsius: Double) -> ScriptedControlPlane.Stage {
        .nominal(temperatures: temperatures(celsius))
    }

    /// A stage that reads `celsius` and whose firmware does something other than honour a
    /// write.
    static func at(
        _ celsius: Double, writes: ScriptedControlPlane.WriteBehaviour
    ) -> ScriptedControlPlane.Stage {
        ScriptedControlPlane.Stage(
            temperatures: temperatures(celsius), writes: writes)
    }
}
