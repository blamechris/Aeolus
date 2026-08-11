import FanKit
import SMCCore

/// The production `FanControlPlane`: real reads, and writes that refuse.
///
/// ## The write side is modelled and unimplemented, deliberately
///
/// `engageManualControl(ofFan:)`, `commandTarget(_:ofFan:)` and `restoreToAutomatic(_:)`
/// all throw `FanControlPlaneError.controlPathNotBuilt`. That is not a stub waiting to be
/// filled in by whoever gets here next — it is the ordering `CLAUDE.md` rule 1 mandates.
/// E5 is the epic that gates E3 and E4, so it may not pre-empt them: `SMCConnection.write`
/// stays `package`-scoped and keeps throwing, and no write selector exists anywhere in
/// `Sources` (the read selectors are 5, 8 and 9, and
/// `Tests/AeolusHelperTests/WritePathAbsenceTests` is the tripwire on that).
///
/// What ships today is the *shape*: every E5 mechanism can be written, reviewed and tested
/// against this seam now, and E3/E4 supply three method bodies later rather than a design.
///
/// ## The reads are real, and they are subset reads
///
/// `readAll()` is never called from here — not for discovery, not for a refresh, not once.
/// [ADR 0006](../../docs/ADR/0006-single-smc-reader.md) puts the helper's 1 Hz snapshot on
/// the same single SMC connection this uses, and on `Mac16,5` a snapshot costs ~0.5 s
/// against 2929 keys. The supervisor's reads are a handful of keys and must not queue
/// behind that, which is why every operation below names exactly the keys it needs.
///
/// ## Restore issues no read, and that is the property to keep
///
/// `restoreToAutomatic(_:)` refuses without touching the provider at all. When E3/E4
/// implement it, that must stay true: `.everyFan` resolves from the fan set the helper
/// established at startup, never from a read issued at restore time.
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s keystone is that the terminal
/// action of every safety mechanism stays available when reading is precisely what has
/// failed, and a restore that reads first is a restore that is missing in the one case it
/// exists for. `SMCFanControlPlaneTests` asserts the provider records no request.
struct SMCFanControlPlane: FanControlPlane {

    private let provider: any SensorProvider

    init(provider: some SensorProvider) {
        self.provider = provider
    }

    // MARK: - Reads

    /// - Note: The reading's `SensorReading.Kind` is deliberately not checked against
    ///   `.temperatureCelsius`. `SMCSensorProvider` classifies conservatively — only the
    ///   fan-key naming convention counts as known, so every `T*` key reports `.unknown` —
    ///   and a gate on the kind would therefore refuse every temperature key on the machine.
    ///   That a key belongs in the critical set is #102's curated, in-code judgement, and it
    ///   is the only judgement available: nothing in the firmware declares a key's physical
    ///   unit.
    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        let outcomes = try await readSubset(keys, context: "critical temperatures")

        var readings: [CriticalTemperature] = []
        readings.reserveCapacity(keys.count)
        var unreadable: [SMCKey] = []

        // Per-key, never all-or-nothing: losing one thermistor is a degraded cycle, and
        // failing the whole read because of it would blind the supervisor over a sensor it
        // could have done without. Losing *all* of them is the blindness case, and
        // `CriticalTemperatureReport`'s initialiser is what refuses to call that a success.
        for key in keys {
            switch Self.reading(for: key, in: outcomes) {
            case .success(let celsius):
                readings.append(CriticalTemperature(key: key, celsius: celsius))
            case .failure:
                unreadable.append(key)
            }
        }

        return try CriticalTemperatureReport(readings: readings, unreadableKeys: unreadable)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        guard let minimumKey = SMCKey(SMCFanEnumeration.minimumKey(forFan: index)),
            let maximumKey = SMCKey(SMCFanEnumeration.maximumKey(forFan: index))
        else {
            throw FanControlPlaneError.fanNotAddressable(index: index)
        }

        let outcomes = try await readSubset(
            [minimumKey, maximumKey], context: "fan \(index) envelope")

        // Both or neither. An envelope with one end missing is not an envelope, and the
        // caller's next move — clamp a target into it — has no meaning with half of one.
        let minimum = try Self.reading(for: minimumKey, in: outcomes).get()
        let maximum = try Self.reading(for: maximumKey, in: outcomes).get()
        return FanEnvelope(index: index, minimumRPM: minimum, maximumRPM: maximum)
    }

    /// Reads the mode from `F<n>Md` alone, which is the Apple Silicon half of the answer.
    ///
    /// Intel expresses the same fact as bit *n* of the `FS!` bitmask, and M3-or-newer Apple
    /// Silicon carries a machine-wide `Ftst` force flag alongside the per-fan mode. Both are
    /// **conformer-internal**: `FirmwareFanMode` is one bit per fan on every architecture,
    /// so E4 and the Intel path each add a branch here and change nothing above. That is
    /// `CLAUDE.md` rule 9 — one code path keyed on what the SMC declares, never on
    /// `uname -m` — applied to the seam rather than asserted about it.
    ///
    /// `Ftst` is deliberately not read here. It is a *write-side* key: set as part of the
    /// M3+ unlock sequence and cleared as part of a restore, per `SMCKey.forceTest` and
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s keystone. It says nothing
    /// about whether any particular fan is in manual, and its meaning is a community report
    /// this project has not yet verified on hardware (`docs/SMC-RESEARCH.md`). Reading it
    /// here would encode an E4 hypothesis into the seam E4 is gated on.
    func readControlState(ofFan index: Int) async throws -> FanControlState {
        guard let modeKey = SMCKey.fanMode(index), let targetKey = SMCKey.fanTargetRPM(index)
        else {
            throw FanControlPlaneError.fanNotAddressable(index: index)
        }

        let outcomes = try await readSubset([modeKey, targetKey], context: "fan \(index) control")

        let modeValue = try Self.reading(for: modeKey, in: outcomes).get()
        let mode = Self.mode(from: modeValue)

        // The target is carried, not thrown: reconciliation only needs the mode, and a fan
        // whose mode reads fine while its target does not is still a fan that can be
        // restored. The reclamation watchdog is the caller that cannot proceed without a
        // target, and it can see from this value that it did not get one.
        let target: FanTargetReadback
        switch Self.reading(for: targetKey, in: outcomes) {
        case .success(let rpm):
            target = .rpm(rpm)
        case .failure(let error):
            target = .unreadable(reason: String(describing: error))
        }

        return FanControlState(index: index, mode: mode, target: target)
    }

    // MARK: - Writes, all refused

    /// Refuses **without reading anything.** See this type's documentation: the absence of
    /// a read here is the part that ships today.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        throw FanControlPlaneError.controlPathNotBuilt
    }

    func engageManualControl(ofFan index: Int) async throws {
        throw FanControlPlaneError.controlPathNotBuilt
    }

    @discardableResult
    func commandTarget(_ target: FanTargetRPM, ofFan index: Int) async throws -> CommandedTarget {
        throw FanControlPlaneError.controlPathNotBuilt
    }

    // MARK: - Decoding

    /// `F<n>Md` is a flag key: zero is the system's thermal management, and **anything else
    /// is manual.**
    ///
    /// Not rounded, and that is the load-bearing part. A value of `0.4` — a decode artefact
    /// rather than anything firmware would intend — reads as manual here, and would read as
    /// automatic if this rounded first. The asymmetry decides it: reading a manual fan as
    /// automatic leaves it pinned with reconciliation satisfied that there is nothing to do,
    /// which is exactly the failure this epic exists to prevent. Reading an automatic fan as
    /// manual costs one redundant restore write to a fan that is already automatic.
    private static func mode(from value: Double) -> FirmwareFanMode {
        value == 0 ? .automatic : .manual
    }

    /// One key's value, with the seam's finiteness rule applied.
    private static func reading(
        for key: SMCKey, in outcomes: [String: SensorReadOutcome]
    ) -> Result<Double, FanControlPlaneError> {
        guard let outcome = outcomes[key.rawValue] else {
            return .failure(.readFailed(detail: "\(key) produced no outcome"))
        }
        switch outcome.result {
        case .failure(let failure):
            return .failure(.readFailed(detail: "\(key): \(describe(failure))"))
        case .success(let reading):
            return FanControlPlaneValue.finite(reading.value, describing: key.rawValue)
        }
    }

    /// One subset read, with a whole-request failure named for the operation that asked.
    private func readSubset(
        _ keys: [SMCKey], context: String
    ) async throws -> [String: SensorReadOutcome] {
        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: keys.map(\.rawValue))
        } catch {
            throw FanControlPlaneError.readFailed(
                detail: "\(context): \(String(describing: error))")
        }

        var byKey: [String: SensorReadOutcome] = [:]
        byKey.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            byKey[outcome.key] = outcome
        }
        return byKey
    }

    /// Diagnostic rendering of a per-key failure. Never parsed or matched on.
    ///
    /// A private function rather than an `extension SensorReadFailure` property because
    /// `fanctl` and `AeolusUI` each already declare a `readableDescription` of their own,
    /// and `SMCFanEnumeration` keeps its copy private for the same reason.
    private static func describe(_ failure: SensorReadFailure) -> String {
        switch failure {
        case .unknownKey(let key): return "\(key) is not present on this machine"
        case .readFailed(let reason): return reason
        case .notDecodable(let reason): return reason
        }
    }
}
