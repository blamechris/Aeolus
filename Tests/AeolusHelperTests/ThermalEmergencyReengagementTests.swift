import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// A fan engaged again while § 3 is bridging it stays registered
/// ([#305](https://github.com/blamechris/Aeolus/issues/305)).
///
/// The bridge is two awaited writes, and `ThermalEmergency` is reentrant across both. A
/// `manualControlEngaged(_:)` for the same fan that lands after the restore write is a newer
/// registration than the one § 3 is bridging; filing the fan as restored would forget it, and
/// take-back — which reads only `engagedFans` — would leave the fan unbridged for the rest of
/// the episode.
///
/// `ScriptedControlPlane` has no suspension point a test can act inside, so these tests put
/// the writer on a `RestoreInterferingPlane`, which runs the re-engagement **inside** the
/// restore write, after the firmware has taken it. Telemetry and the read-back use the
/// scripted plane directly: only the write is interfered with.
@Suite("The thermal emergency's bridge of a fan engaged again mid-bridge", .timeLimit(.minutes(1)))
struct ThermalEmergencyReengagementTests {

    /// One machine, hot throughout, so every cycle after the first is latched. Fan 0 nominal
    /// and on automatic, every write honoured.
    private struct Machine {
        let plane: ScriptedControlPlane
        let writes: RestoreInterferingPlane
        let emergency: ThermalEmergency<RestoreInterferingPlane>

        init() {
            plane = ScriptedControlPlane(
                fans: [0: .nominal],
                stages: [.at(96)])
            writes = RestoreInterferingPlane(plane)
            let latch = ThermalEmergencyLatch()
            let clock = TestClock()
            let curated = CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
            let sightings = CriticalTemperatureCache(source: curated, clock: clock)
            emergency = ThermalEmergency(
                telemetry: curated,
                sightings: sightings,
                writer: SafetyActorWriter(plane: writes, level: .thermalEmergency),
                leases: LeaseFixture.authority(
                    telemetry: sightings, thermalEmergency: latch, clock: clock),
                latch: latch,
                handbackReadBack: LeaseFixture.reconciliation(over: plane))
        }

        func permit() throws -> CommandableFan {
            try commandableFan(0, declaring: .nominal)
        }

        /// Registers fan 0 again from inside its next restore write, once.
        func reengageDuringNextRestore() async throws {
            let fan = try permit()
            await writes.onNextRestore(ofFan: 0) { [emergency] in
                await emergency.manualControlEngaged(fan)
            }
        }

        /// Every maximum command fan 0 was sent.
        func bridges() async -> Int {
            await plane.attempts.filter {
                if case .commandTarget(fan: 0, _) = $0 { return true }
                return false
            }.count
        }
    }

    /// `fire` bridges fan 0, the client engages it again after the restore write, and the fan
    /// stays registered — so the next latched cycle's take-back bridges it.
    ///
    /// **Mutation:** in `ThermalEmergency.bridgeThenFileRestored(_:)`, delete the line
    /// `if let now = engagedAt[fan.index], now != registration { return }`. Run: red — fan 0
    /// is filed in `fansRestoredUnconfirmed`, `fansUnderManualControl` is empty, and take-back
    /// never bridges it a second time.
    @Test("A fan engaged again during fire's bridge of it is still bridged by take-back")
    func reengagedDuringFireStaysRegistered() async throws {
        let machine = Machine()
        await machine.emergency.manualControlEngaged(try machine.permit())
        try await machine.reengageDuringNextRestore()

        await machine.emergency.cycle()
        #expect(await machine.emergency.isHolding, "the emergency never fired")
        #expect(await machine.writes.interferencesRun == 1, "the re-engagement never ran")
        #expect(await machine.bridges() == 1)
        #expect(
            await machine.emergency.fansUnderManualControl == [0],
            "fire filed a fan engaged again mid-bridge as restored")
        #expect(await machine.emergency.fansRestoredUnconfirmed.isEmpty)

        await machine.emergency.cycle()
        #expect(
            await machine.bridges() == 2,
            "take-back did not bridge a fan a client engaged again after § 3's restore")
    }

    /// The same, when take-back is the bridge: the emergency fires with nothing registered,
    /// fan 0 is engaged while it holds, and take-back's restore of it meets another
    /// engagement.
    ///
    /// **Mutation:** in `ThermalEmergency.takeBackAnythingEngagedSinceFiring()`, replace
    /// `await bridgeThenFileRestored(fan)` with `await bridgeToMaximumThenRelease(fan)`
    /// followed by `restoredByEmergency(fan)`. Run: red — fan 0 leaves `engagedFans` and the
    /// third cycle does not bridge it.
    @Test("A fan engaged again during take-back's bridge of it is bridged again")
    func reengagedDuringTakeBackStaysRegistered() async throws {
        let machine = Machine()
        await machine.emergency.cycle()
        #expect(await machine.emergency.isHolding, "the emergency never fired")
        #expect(await machine.bridges() == 0)

        await machine.emergency.manualControlEngaged(try machine.permit())
        try await machine.reengageDuringNextRestore()
        await machine.emergency.cycle()
        #expect(await machine.writes.interferencesRun == 1, "the re-engagement never ran")
        #expect(await machine.bridges() == 1, "take-back never bridged the late engagement")
        #expect(
            await machine.emergency.fansUnderManualControl == [0],
            "take-back filed a fan engaged again mid-bridge as restored")
        #expect(await machine.emergency.fansRestoredUnconfirmed.isEmpty)

        await machine.emergency.cycle()
        #expect(await machine.bridges() == 2)
    }

    /// The guard is about a **newer** registration, not about any registration: a fan whose
    /// bridge nothing interrupted is filed as restored, as before #305.
    ///
    /// **Mutation:** in `bridgeThenFileRestored(_:)`, return whenever the fan is registered
    /// after the bridge — `if engagedAt[fan.index] != nil { return }`. Run: red — fan 0 stays
    /// in `fansUnderManualControl` and take-back bridges it on every latched cycle.
    @Test("A fan whose bridge nothing interrupted is filed as restored")
    func anUninterruptedBridgeFilesTheFanAsRestored() async throws {
        let machine = Machine()
        await machine.emergency.manualControlEngaged(try machine.permit())

        await machine.emergency.cycle()
        #expect(await machine.emergency.isHolding, "the emergency never fired")
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
        #expect(await machine.emergency.fansRestoredUnconfirmed == [0])

        await machine.emergency.cycle()
        #expect(await machine.bridges() == 1, "take-back bridged a fan § 3 had already restored")
    }
}

/// Scripted firmware whose restore write can run one side effect **after** the firmware has
/// taken it, while the caller is still awaiting — the only place #305's interleaving exists.
///
/// Every verb delegates to the wrapped `ScriptedControlPlane`, so its record of attempts is
/// the record of what the writer did.
actor RestoreInterferingPlane: FanControlPlane {

    let wrapped: ScriptedControlPlane
    private var pending: (fan: Int, effect: @Sendable () async -> Void)?

    /// How many installed effects have run.
    private(set) var interferencesRun = 0

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Runs `effect` inside the next restore of `fan`, once.
    func onNextRestore(ofFan fan: Int, _ effect: @escaping @Sendable () async -> Void) {
        pending = (fan, effect)
    }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await wrapped.restoreToAutomatic(scope)
        guard let pending, case .fan(let index) = scope, index == pending.fan else { return }
        self.pending = nil
        await pending.effect()
        interferencesRun += 1
    }

    // MARK: - Straight delegation

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await wrapped.readControlState(ofFan: index)
    }

    func reconnect() async throws {
        try await wrapped.reconnect()
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}
