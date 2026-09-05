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

    /// The seam a staleness scenario acts inside, on § 3's own read.
    ///
    /// The real curated conformer with one suspension a test can act at. With no effect
    /// installed it delegates and returns, so every scenario that does not ask for
    /// interference behaves exactly as it did before this existed.
    let emergencyTelemetry: InterferingCriticalTemperatures

    /// The same seam on the lease core's blindness check.
    ///
    /// Separate from `emergencyTelemetry` because the two reads are the two halves of the
    /// grant-time window `LeaseAuthority.revokeEveryLease(because:)` documents: the latch is
    /// read, and then a real 34-key read is awaited, and § 3 can engage across it. One shared
    /// interferer could not fire inside the lease core's read without also firing inside the
    /// emergency's, which is the cycle the scenario is trying to script.
    let leaseTelemetry: InterferingCriticalTemperatures

    /// Everything § 3 said about itself, with levels. Empty unless a test asked for it.
    let safetyLog = RecordedLog()

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

        let curated = CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
        emergencyTelemetry = InterferingCriticalTemperatures(curated)
        leaseTelemetry = InterferingCriticalTemperatures(curated)
        leases = LeaseFixture.authority(
            restorer: restorer, telemetry: leaseTelemetry, thermalEmergency: latch)
        emergency = ThermalEmergency(
            telemetry: emergencyTelemetry,
            writer: SafetyActorWriter(plane: plane, level: .thermalEmergency),
            leases: leases,
            latch: latch,
            requestedCeilingCelsius: requestedCeilingCelsius,
            log: SafetyLog(recording: { [safetyLog] in safetyLog.append($0, $1) })
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

    /// Acquires a lease and **does not** register any permit with the emergency.
    ///
    /// The state a client is in between `acquireLease` and its first write: the lease is
    /// live, and the fan is still on Apple's thermal management, so it appears in no
    /// registry of engaged fans. `lease(fans:from:)` does both; this does only the first,
    /// because an emergency that selected on the registry left exactly this lease alive.
    @discardableResult
    func acquireWithoutEngaging(
        fans: [Int] = [0], from connection: ConnectionID = ConnectionID()
    ) async throws -> Lease {
        try await leases.acquireLease(LeaseFixture.request(fans: fans), from: connection)
    }

    /// Registers a permit with the emergency without going through `acquireLease`.
    ///
    /// What E3's control plane does at the moment it engages manual control.
    func engageManualControl(fan index: Int) async throws {
        let condition = try #require(fanConditions[index])
        await emergency.manualControlEngaged(try commandableFan(index, declaring: condition))
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
                // A reconnect is recovery of the read path, not a write. It belongs with
                // the reads for the same reason `readControlState` does: an ordering
                // assertion about what a mechanism *wrote* must not shift because it also
                // tried to see again.
                case .readCriticalTemperatures, .readEnvelope, .readControlState, .reconnect:
                    return false
                }
            }
        }
    }
}

/// Runs an arbitrary side effect **inside** a critical-temperature read, so that "§ 3 changed
/// episode while this cycle was reading" is a scenario rather than an argument.
///
/// The § 5 twin is `InterferingFanStateSensing`, and the argument for both is the same:
/// `ScriptedControlPlane`'s methods contain no suspension point a test can act inside, so a
/// scenario built on stages alone can only change the machine *between* cycles, while every
/// staleness defect happens *within* one. A repeat-until-it-races loop would be the flakiness
/// [#109](https://github.com/blamechris/Aeolus/issues/109) is open about.
///
/// **The effect fires after the delegated read, not before**, which is where it differs from
/// its § 5 twin. The scenarios here are about a report gathered *before* an episode boundary
/// and acted on *after* it, so the report has to be taken first and the world has to move
/// second. Firing first would hand the caller a report of the post-boundary machine, which is
/// a different — and harmless — story. It fires on the throwing path too, because "the
/// machine moved while the SMC was refusing to answer" is one of the scenarios.
///
/// It fires **once**, on the first read. An effect that ran on every read would make a
/// scenario that loops untestable, and would recurse the moment the effect drove a cycle of
/// its own.
actor InterferingCriticalTemperatures: CriticalTemperatureSensing {

    private let wrapped: any CriticalTemperatureSensing
    private var effect: (@Sendable () async -> Void)?
    private var hasFired = false

    /// Whether the effect actually ran.
    ///
    /// Asserted by every test using this type. A double whose interference silently never
    /// fired would leave the test passing for the wrong reason — the "test that cannot fail"
    /// shape this repository keeps producing — so the scenario proves its own setup happened.
    private(set) var didFire = false

    init(_ wrapped: any CriticalTemperatureSensing) {
        self.wrapped = wrapped
    }

    /// Sets what happens inside the read. Assigned after construction because the effect
    /// usually needs the machine, which needs this.
    func interfere(with effect: @escaping @Sendable () async -> Void) {
        self.effect = effect
    }

    func readCriticalTemperatures() async throws -> CriticalTemperatureReport {
        do {
            let report = try await wrapped.readCriticalTemperatures()
            await fireOnce()
            return report
        } catch {
            await fireOnce()
            throw error
        }
    }

    private func fireOnce() async {
        guard !hasFired, let effect else { return }
        hasFired = true
        await effect()
        didFire = true
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

    /// A stage whose curated keys do **not** all read the same thing.
    ///
    /// `temperatures(_:)` writes one value into all 34 keys, and every § 3 scenario used it
    /// — so `max` and `min` over the readings were the same value and
    /// `ThermalEmergency.cycle()`'s hottest-reading selector could be inverted with the
    /// whole suite green. An adversarial review found that by mutation; this is what makes
    /// it findable by a test.
    ///
    /// The spread is not arbitrary. `docs/SMC-RESEARCH.md`, quoted in `CriticalSensorSet`,
    /// measured this die cluster at 53.17–56.07 °C under load and 55.85–62.40 °C at peak —
    /// an intra-cluster spread of roughly 3–6.5 °C. A wrong selector is therefore not a
    /// theoretical concern: it would let the latch release while the hottest curated key was
    /// still several degrees above the ceiling.
    ///
    /// - Parameters:
    ///   - baseline: what most curated keys read.
    ///   - peak: what `hotKeyCount` of them read instead.
    ///   - hotKeyCount: how many keys read `peak` rather than `baseline`.
    /// - Returns: a stage whose curated keys are not all the same temperature.
    static func field(baseline: Double, peak: Double, hotKeyCount: Int = 1) -> Self {
        var readings = temperatures(baseline)
        for key in CriticalSensorSet.mac16x5.keys.prefix(hotKeyCount) {
            readings[key.rawValue] = peak
        }
        return .nominal(temperatures: readings)
    }

    /// A stage where only some curated keys answer at all, and those that do read `celsius`.
    ///
    /// **Degraded, not blind** — the distinction #124 built `CriticalSensorSet` around. A
    /// key absent from a stage's dictionary is one the firmware does not answer, so this is
    /// the machine that has lost sensors while keeping enough to produce a report. It is the
    /// state § 3's release path had no test for, and the one where releasing on `max()` of
    /// the survivors is indistinguishable from the machine cooling down.
    ///
    /// - Parameters:
    ///   - answering: how many of the curated keys report.
    ///   - celsius: what each of those reads.
    /// - Returns: a stage whose report is partial rather than empty.
    static func partial(answering: Int, at celsius: Double) -> Self {
        var readings: [String: Double] = [:]
        for key in CriticalSensorSet.mac16x5.keys.prefix(answering) {
            readings[key.rawValue] = celsius
        }
        return .nominal(temperatures: readings)
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

extension ScriptedControlPlane.Attempt {

    /// The speed a `.commandTarget` carried, or `nil` for any other call.
    ///
    /// Assertions about § 3's bridge are about the **value** written, not merely that a
    /// write happened — an emergency that issued one write of the wrong speed is the exact
    /// failure a governed bridge would produce.
    var commandedRPM: Double? {
        if case .commandTarget(_, let rpm) = self { return rpm }
        return nil
    }
}
