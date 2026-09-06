import SMCCore

/// The production `FanControlPlane`: real reads, and writes that refuse.
///
/// ## The write side is modelled and unimplemented, deliberately
///
/// `engageManualControl(of:)`, `commandTarget(_:)` and `restoreToAutomatic(_:)`
/// all throw `FanControlPlaneError.controlPathNotBuilt`. That is not a stub waiting to be
/// filled in by whoever gets here next — it is the ordering `CLAUDE.md` rule 1 mandates.
/// E5 is the epic that gates E3 and E4, so it may not pre-empt them: `SMCConnection.write`
/// stays behind the `FanWrite` SPI group and keeps throwing, and no write selector exists
/// anywhere in `Sources` (the read selectors are 5, 8 and 9, and
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

    /// The connection underneath the scheduler's provider — held only so `reconnect()` can
    /// recycle it.
    ///
    /// **It must be the same one the provider reads through**, and nothing in the type
    /// system says so: `SMCReadScheduler` holds a `SensorProvider`, which is a public
    /// protocol that discloses no connection. Recycling a connection the reads do not use
    /// would be a reconnect that fixes nothing while reporting that it worked —
    /// `CLAUDE.md` rule 6 at the level below the fans. What holds it is the composition
    /// root building both from one local, and
    /// `HelperCompositionTests.theProviderAndThePlaneShareOneConnection` failing if a second
    /// one is ever constructed in the helper.
    private let connection: any SMCConnectionRecycling

    /// Takes the scheduler rather than a `SensorProvider`, so that **this type names its
    /// own priority** at the point each read is issued. A `SensorProvider` carries no
    /// priority in its signature, so a prioritised one would be a value whose behaviour
    /// cannot be read off its type — and the safety path is the one place that matters.
    /// Passing this plane a snapshot-priority reader is not a mistake there is a way to
    /// make.
    ///
    /// `connection` is separate and is deliberately **not** defaulted. A defaulted
    /// `SMCConnection()` would compile everywhere and be wrong everywhere: it would be a
    /// second connection, so the recycle would leave the one being read through untouched.
    /// Making the caller name it is what forces the composition root to have one local to
    /// name.
    init(scheduler: SMCReadScheduler, connection: some SMCConnectionRecycling) {
        self.scheduler = scheduler
        self.connection = connection
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

    // MARK: - Recovery

    /// Recycles the `io_connect_t`: `close()`, then `open()`, under an **exclusive**
    /// scheduler turn.
    ///
    /// [#103](https://github.com/blamechris/Aeolus/issues/103)'s decision A6, and the answer
    /// to [#68](https://github.com/blamechris/Aeolus/issues/68) — the stale handle after
    /// wake, where every read fails, nothing else about the machine is wrong, and the fans
    /// stay wherever a lease left them.
    ///
    /// ## The exclusive turn is the whole of the difficulty
    ///
    /// Closing a handle another task is reading through invalidates it *mid-request*, and
    /// the read reports a firmware failure nothing on this machine caused — a fault that
    /// looks exactly like the one being recovered from, produced by the recovery. So the
    /// recycle takes a turn like any other read, and holds it across both calls:
    /// `SMCReadScheduler.withExclusiveAccess(_:)` is that verb, and its documentation is
    /// precise about what it does and does not hold off.
    ///
    /// Neither call is reachable through `SensorProvider`, which is a **public** protocol
    /// every unprivileged client links; widening it to carry a recycle verb, for one
    /// helper-internal caller, would be a decision about a shipped public API taken for a
    /// private need. This type holds the connection directly instead, and
    /// `SMCConnectionRecycling` is the two verbs it needs and nothing else.
    ///
    /// ## What a clean return proves
    ///
    /// That the handle was rebuilt. Not that reading works — no read has been issued since,
    /// and `SMCConnection.close()` deliberately keeps its metadata cache, so a reopen that
    /// succeeds says nothing about whether the firmware is answering. Every caller treats it
    /// that way: `ReclamationWatchdog` restores and reports regardless, and `ConnectionHealth`
    /// waits for the next read rather than declaring recovery.
    ///
    /// - Throws: `FanControlPlaneError.readFailed` when the reopen fails, carrying the
    ///   underlying `SMCError`. Not its own case: the attempt was made and the machine did
    ///   not come back, which is exactly what `.readFailed` means here — and the case that
    ///   used to mean "no attempt was possible", `.reconnectNotBuilt`, is gone rather than
    ///   left to be thrown by nothing.
    func reconnect() async throws {
        let connection = self.connection
        do {
            try await scheduler.withExclusiveAccess {
                await connection.close()
                try await connection.open()
            }
        } catch {
            throw FanControlPlaneError.readFailed(
                detail: "reconnect: \(String(describing: error))")
        }
    }

    // MARK: - Writes, all refused

    /// `.notBuilt`, and it is the same fact the three verbs below throw — stated once, where
    /// a mechanism can ask it **before** spending an SMC read on a grant it will refuse.
    ///
    /// Computed rather than stored so no initialiser can be given a different answer. It
    /// moves to `.built` in the change that gives `restoreToAutomatic(_:)`,
    /// `engageManualControl(of:)` and `commandTarget(_:)` bodies, and not before: a plane
    /// that claims a write path it does not have would have `LeaseAuthority` grant a lease
    /// over a fan nothing can command, which is `CLAUDE.md` rule 6 reached through a
    /// one-line lie.
    var writeCapability: FanWriteCapability { .notBuilt }

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

    /// The one decode of `F<n>Md`, which lives on `FirmwareFanMode` rather than here.
    ///
    /// It moved when the snapshot path started reading the same key
    /// ([#148](https://github.com/blamechris/Aeolus/issues/148)): two spellings of "is this
    /// fan on automatic control" is two answers, and the supervisor and the client reporting
    /// different ones about the same fan is the defect, not the duplication.
    private static func mode(from value: Double) -> FirmwareFanMode {
        FirmwareFanMode(declaredByFirmware: value)
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
            return .failure(.readFailed(detail: "\(key): \(failure.readableDescription)"))
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
}

// MARK: - The connection, at its narrowest

/// The two lifecycle verbs `SMCFanControlPlane.reconnect()` needs of an SMC connection, and
/// nothing else.
///
/// ## Why not just hold an `SMCConnection`
///
/// Because then the reconnect path could only be exercised on hardware. `SMCConnection.open()`
/// is `IOServiceGetMatchingService` plus `IOServiceOpen`; CI runs on GitHub's macOS VMs, which
/// have no SMC at all, so a test of "the recycle is serialised against a read in flight" or of
/// "a stale handle reads again after a reconnect" would be a test that never runs where it
/// matters. Behind this protocol both are ordinary, deterministic tests — see
/// `ConnectionRecoveryTests`, whose fake SMC is one actor recording an ordered log.
///
/// ## It is deliberately two verbs, not one `recycle()`
///
/// A single verb would put the close-then-open sequence inside the `SMCConnection`
/// conformance, where a test double replaces it wholesale — so the *order* would be asserted
/// against a double's copy of the sequence rather than against the code that ships.
/// `reconnect()` performing both calls is what makes "skip the `open()`" and "skip the
/// `close()`" mutations of the production body, each red in `ConnectionRecoveryTests`.
///
/// ## The idempotence of `open()` is load-bearing
///
/// `SMCConnection.open()` returns without doing anything when a connection is already open,
/// and `SMCSensorProvider.read(keys:)` calls it before every subset read. So the recycle is
/// only a recycle because the `close()` comes first: an `open()` on its own is a no-op against
/// a live-but-stale handle. The fake in `ConnectionRecoveryTests` models that exactly, which
/// is what makes the skipped-`close()` mutation red rather than merely redundant.
protocol SMCConnectionRecycling: Sendable {

    /// Releases the `io_connect_t`. Safe when already closed.
    func close() async

    /// Opens a connection, or returns unchanged if one is already open.
    func open() async throws
}

/// The production conformance. Both verbs already exist and are `public`; this states that
/// the pair of them is what a recycle means, without adding anything to `SMCCore`.
extension SMCConnection: SMCConnectionRecycling {}
