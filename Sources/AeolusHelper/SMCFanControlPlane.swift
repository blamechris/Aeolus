import SMCCore

/// The production `FanControlPlane`: real reads, and writes that refuse.
///
/// ## The write side is modelled and unimplemented, deliberately
///
/// `engageManualControl(of:)`, `commandTarget(_:)` and `restoreToAutomatic(_:)`
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
/// ## The reads are real, they are subset reads, and they go first
///
/// `readAll()` is never called from here — not for discovery, not for a refresh, not once.
/// [ADR 0006](../../docs/ADR/0006-single-smc-reader.md) puts the helper's 1 Hz snapshot on
/// the same single SMC connection this uses, and on `Mac16,5` a warm snapshot costs ~0.5 s
/// against 2929 keys. The supervisor's reads are a handful of keys and must not queue
/// behind that, which is why every operation below names exactly the keys it needs.
///
/// Naming the keys is what made the ordering *possible*; it is not the ordering.
/// [#127](https://github.com/blamechris/Aeolus/issues/127) supplies that: every read below
/// goes through `SMCReadScheduler` at `.supervisor`, which admits it ahead of a waiting
/// snapshot turn. Before that, a subset read was merely *small*, and a small read still
/// waits for a big one on a connection that grants no turns.
///
/// **What that bounds, exactly.** A read issued here waits at most two turns — ~22 ms —
/// *while it is the only supervisor-priority read outstanding*, against the ~500 ms a
/// snapshot-length occupation costs. It does not bound the wait when several are
/// outstanding, which `LeaseAuthority.refuseIfBlind` already makes possible today; the
/// scheduler's own documentation carries the general form, and this comment stated the
/// two-turn figure unconditionally until a review panel produced the counterexample.
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

    private let scheduler: SMCReadScheduler

    /// Takes the scheduler rather than a `SensorProvider`, so that **this type names its
    /// own priority** at the point each read is issued. A `SensorProvider` carries no
    /// priority in its signature, so a prioritised one would be a value whose behaviour
    /// cannot be read off its type — and the safety path is the one place that matters.
    /// Passing this plane a snapshot-priority reader is not a mistake there is a way to
    /// make.
    init(scheduler: SMCReadScheduler) {
        self.scheduler = scheduler
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
        guard let modeKey = SMCKey.fanMode(index), let targetKey = SMCKey.fanTargetRPM(index),
            let actualKey = SMCKey.fanActualRPM(index)
        else {
            throw FanControlPlaneError.fanNotAddressable(index: index)
        }

        // One turn, three keys. A second read verb for `F<n>Ac` would be a second
        // `.supervisor` waiter per fan per cycle, which is the count `SMCReadScheduler`'s
        // starvation arithmetic is sensitive to — see the seam's own note on this method.
        let outcomes = try await readSubset(
            [modeKey, targetKey, actualKey], context: "fan \(index) control")

        let modeValue = try Self.reading(for: modeKey, in: outcomes).get()
        let mode = Self.mode(from: modeValue)

        // Both RPM keys are carried, not thrown: reconciliation only needs the mode, and a
        // fan whose mode reads fine while its target does not is still a fan that can be
        // restored. The reclamation watchdog is the caller that cannot proceed without a
        // target, and it can see from these values that it did not get one.
        return FanControlState(
            index: index,
            mode: mode,
            target: Self.readback(for: targetKey, in: outcomes),
            actualRPM: Self.readback(for: actualKey, in: outcomes))
    }

    // MARK: - Recovery, not built

    /// Throws `.reconnectNotBuilt`, always.
    ///
    /// Rebuilding the connection is `SMCConnection.close()` then `open()`, and neither is
    /// reachable from here: this type holds an `SMCReadScheduler`, which holds a
    /// `SensorProvider`, which is a **public** protocol every unprivileged client links.
    /// Widening it to carry a reconnect verb — for one helper-internal caller, on a path
    /// nothing has yet exercised on hardware — is a decision about a shipped public API,
    /// and `SMCConnection`'s own cache note already assigns it: wiring recovery to a
    /// lifecycle event "is a decision for whoever owns that lifecycle, not this cache."
    /// [#103](https://github.com/blamechris/Aeolus/issues/103) owns sleep/wake and therefore
    /// owns [#68](https://github.com/blamechris/Aeolus/issues/68), the stale `io_connect_t`
    /// this verb exists for.
    ///
    /// What ships today is that `ReclamationWatchdog` really does attempt the reconnect,
    /// really does see it fail, and really does go on to restore and report — the branch is
    /// written and covered rather than deferred with the mechanism.
    func reconnect() async throws {
        throw FanControlPlaneError.reconnectNotBuilt
    }

    // MARK: - Writes, all refused

    /// Refuses **without reading anything.** See this type's documentation: the absence of
    /// a read here is the part that ships today.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        throw FanControlPlaneError.controlPathNotBuilt
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        throw FanControlPlaneError.controlPathNotBuilt
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
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

    /// One RPM key as a readback: the value, or the reason there is not one.
    ///
    /// Never throws. Both callers want to carry the failure rather than lose the whole
    /// read to it — see `readControlState(ofFan:)`.
    private static func readback(
        for key: SMCKey, in outcomes: [String: SensorReadOutcome]
    ) -> FanRPMReadback {
        switch Self.reading(for: key, in: outcomes) {
        case .success(let rpm): return .rpm(rpm)
        case .failure(let error): return .unreadable(reason: String(describing: error))
        }
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
            outcomes = try await scheduler.read(keys: keys.map(\.rawValue), at: .supervisor)
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
