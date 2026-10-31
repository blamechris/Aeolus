import SMCCore

@testable import AeolusHelper

/// `fanProvider(fanCount:)`'s machine, with each fan's `F<n>Md`, `F<n>Mn` and `F<n>Mx` answered by
/// the scripted firmware the composed helper's plane reads
/// ([#360](https://github.com/blamechris/Aeolus/issues/360),
/// [#270](https://github.com/blamechris/Aeolus/issues/270)).
///
/// The composed fixtures modelled a machine that cannot exist. The grant reads a fan's mode
/// through `ScriptedControlPlane`; the snapshot reads `F<n>Md` through its provider
/// (`SnapshotFanModeReads`), and `fanKeyResults(fanCount:extraKeys:)` has no such key, so every
/// composed snapshot reported every fan's mode unread while the plane answered it. Behind #178's
/// fold that was invisible: an unread mode is reported automatic. Once step 5 of the availability
/// ladder judges an unread mode as the grant does, it is not.
///
/// So the mode key is the firmware's, through `ScriptedControlPlane.firmwareRawMode(ofFan:)`, which
/// shares `readControlState(ofFan:)`'s rule and records no attempt: a scripted fan's raw byte
/// reads here as the byte, for the snapshot's own decode to fold, a stage that leaves its mode
/// unanswered fails here, and a fan the firmware does not have is an unknown key.
///
/// **The bound keys are the firmware's too, since #270**, for the same reason one step on: the
/// grant now reads `F<n>Mn` and `F<n>Mx` through `readEnvelope(ofFan:)`, and an agreement test
/// whose snapshot read bounds from `fanProvider` while its grant read them from the firmware
/// would assert that two scripts agree. Both come from `ScriptedControlPlane.firmwareBound(_:
/// ofFan:)`, which shares `readEnvelope(ofFan:)`'s rule — raw here, because the snapshot's
/// provider applies no finiteness check — so a scenario scripts a fan's bounds, or a bound that
/// will not read, on the firmware (`Stage.maximumReads`) and both sides read that one value.
/// There is no `extraKeys` here, deliberately: a key scripted beside the firmware is the
/// disagreement this type exists to prevent. Every other key is `fanProvider`'s.
actor PlaneBackedProvider: SensorProvider {
    nonisolated let identifier = "plane-backed"

    private let firmware: ScriptedControlPlane
    private let fans: FakeSensorProvider

    /// `F<n>Md` per fan index this provider answers from the firmware.
    private let modeKeys: [String: Int]

    /// `F<n>Mn` and `F<n>Mx` per fan index and bound, answered from the firmware (#270).
    private let boundKeys: [String: (fan: Int, bound: ScriptedControlPlane.Bound)]

    /// How many `F<n>Md` reads the firmware answered, for a test that has to prove a snapshot
    /// read a mode rather than infer it from a mode an unread key would also produce.
    private(set) var answeredModeReads = 0

    init(over firmware: ScriptedControlPlane, fanCount: Int) {
        self.firmware = firmware
        fans = fanProvider(fanCount: fanCount)
        var modeKeys: [String: Int] = [:]
        var boundKeys: [String: (fan: Int, bound: ScriptedControlPlane.Bound)] = [:]
        for index in 0..<fanCount {
            if let key = SMCKey.fanMode(index) { modeKeys[key.rawValue] = index }
            boundKeys[SMCFanEnumeration.minimumKey(forFan: index)] = (index, .minimum)
            boundKeys[SMCFanEnumeration.maximumKey(forFan: index)] = (index, .maximum)
        }
        self.modeKeys = modeKeys
        self.boundKeys = boundKeys
    }

    var isAvailable: Bool {
        get async { await fans.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        try await fans.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        var outcomes: [SensorReadOutcome] = []
        for outcome in try await fans.read(keys: keys) {
            if let index = modeKeys[outcome.key] {
                let result = await mode(ofFan: index, key: outcome.key)
                outcomes.append(SensorReadOutcome(key: outcome.key, result: result))
            } else if let entry = boundKeys[outcome.key] {
                let result = await reading(entry.bound, ofFan: entry.fan, key: outcome.key)
                outcomes.append(SensorReadOutcome(key: outcome.key, result: result))
            } else {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    private func mode(
        ofFan index: Int, key: String
    ) async -> Result<SensorReading, SensorReadFailure> {
        do {
            // The byte, as the SMC answers it, so the snapshot's own decode folds it
            // (`SnapshotFanModeReads`): Apple's stopped `3` reaches the fold as `3`.
            let raw = try await firmware.firmwareRawMode(ofFan: index)
            answeredModeReads += 1
            return .reading(key, Double(raw))
        } catch FanControlPlaneError.fanNotAddressable {
            return .failure(.unknownKey(key))
        } catch {
            return .failure(.readFailed(reason: String(describing: error)))
        }
    }

    private func reading(
        _ bound: ScriptedControlPlane.Bound, ofFan index: Int, key: String
    ) async -> Result<SensorReading, SensorReadFailure> {
        do {
            return .reading(key, try await firmware.firmwareBound(bound, ofFan: index))
        } catch FanControlPlaneError.fanNotAddressable {
            return .failure(.unknownKey(key))
        } catch {
            return .failure(.readFailed(reason: String(describing: error)))
        }
    }
}
