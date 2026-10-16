import SMCCore

@testable import AeolusHelper

/// `fanProvider(fanCount:extraKeys:)`'s machine, with each fan's `F<n>Md` answered by the scripted
/// firmware the composed helper's plane reads
/// ([#360](https://github.com/blamechris/Aeolus/issues/360)).
///
/// The composed fixtures modelled a machine that cannot exist. The grant reads a fan's mode
/// through `ScriptedControlPlane`; the snapshot reads `F<n>Md` through its provider
/// (`SnapshotFanModeReads`), and `fanKeyResults(fanCount:extraKeys:)` has no such key, so every
/// composed snapshot reported every fan's mode unread while the plane answered it. Behind #178's
/// fold that was invisible: an unread mode is reported automatic. Once step 5 of the availability
/// ladder judges an unread mode as the grant does, it is not.
///
/// So the mode key is the firmware's, through `ScriptedControlPlane.firmwareMode(ofFan:)`, which
/// shares `readControlState(ofFan:)`'s rule and records no attempt: a scripted fan in manual
/// reads manual here, a stage that leaves its mode unanswered fails here, and a fan the firmware
/// does not have is an unknown key. Every other key is `fanProvider`'s, `extraKeys` included, so
/// a test that scripts a fan's bounds still does so there.
actor PlaneBackedProvider: SensorProvider {
    nonisolated let identifier = "plane-backed"

    private let firmware: ScriptedControlPlane
    private let fans: FakeSensorProvider

    /// `F<n>Md` per fan index this provider answers from the firmware.
    private let modeKeys: [String: Int]

    /// How many `F<n>Md` reads the firmware answered, for a test that has to prove a snapshot
    /// read a mode rather than infer it from a mode an unread key would also produce.
    private(set) var answeredModeReads = 0

    init(
        over firmware: ScriptedControlPlane, fanCount: Int,
        extraKeys: [String: Result<SensorReading, SensorReadFailure>] = [:]
    ) {
        self.firmware = firmware
        fans = fanProvider(fanCount: fanCount, extraKeys: extraKeys)
        var modeKeys: [String: Int] = [:]
        for index in 0..<fanCount {
            if let key = SMCKey.fanMode(index) { modeKeys[key.rawValue] = index }
        }
        self.modeKeys = modeKeys
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
            guard let index = modeKeys[outcome.key] else {
                outcomes.append(outcome)
                continue
            }
            let result = await mode(ofFan: index, key: outcome.key)
            outcomes.append(SensorReadOutcome(key: outcome.key, result: result))
        }
        return outcomes
    }

    private func mode(
        ofFan index: Int, key: String
    ) async -> Result<SensorReading, SensorReadFailure> {
        do {
            let mode = try await firmware.firmwareMode(ofFan: index)
            answeredModeReads += 1
            return .reading(key, mode == .automatic ? 0 : 1)
        } catch FanControlPlaneError.fanNotAddressable {
            return .failure(.unknownKey(key))
        } catch {
            return .failure(.readFailed(reason: String(describing: error)))
        }
    }
}
