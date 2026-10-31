import SMCCore

/// The production `FanControlPlane`: real reads, and — on a plane that holds a write channel —
/// the Apple Silicon write path.
///
/// ## Write capability is what the plane holds
///
/// The plane takes an optional `SMCWriteChannel`
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s B1 amendment, "write capability is
/// what the plane holds"), which `HelperComposition.production`
/// passes only when `AeolusHelperMain` asks, over the daemon's own connection. **`.built` holds
/// exactly when the plane holds a channel**: a plane given none — every test composition over the
/// real SMC, and the daemon below macOS 14 — answers `.notBuilt`, and every write verb refuses
/// with `.controlPathNotBuilt` without reading anything, as it did before the write path existed.
///
/// A plane that holds one runs each write verb as **one synchronous job on the channel inside one
/// scheduler write turn**, taken at this plane's `admission` (`SMCReadScheduler.withWriteTurn`),
/// whose first statement is the ledger's admission or the restore's issue (`SMCWriteTurns`). Its
/// state between calls is one `PlaneWriteLedger` — the restore epoch, the exit's seal, the engaged
/// and touched sets, the force-key flag and what the preparation step recorded — which every view
/// of the plane shares by reference, so `ScriptedControlPlane` and this plane decide every answer
/// by the same code (`PlaneWriteLedger`, `EngagementRules`, `RestorePlan`).
///
/// **Every use of the stored channel is the channel argument of one write turn.** Each write verb
/// unwraps it and hands it to `withWriteTurn(at: admission, on:)` in the same statement block, and
/// nothing else reads it but `holdsWriteChannel`. `PlaneWriteChannelTests` holds each mention to
/// one of those shapes.
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
/// goes through `SMCReadScheduler` at this plane's admission — `.supervisor`, which admits it
/// ahead of a waiting snapshot turn, or § 3's lane on the view § 3 is given. Before that, a
/// subset read was merely *small*, and a small read still waits for a big one on a connection
/// that grants no turns.
///
/// ## A view at § 3's admission is this plane
///
/// `admitted(at:)` copies this value with a different `admission` and nothing else, so the view
/// holds the one scheduler and the one connection, and every stored property added later is
/// shared by the copy as long as it is a reference: an actor, a class or an existential of one
/// (`PlaneViewTests` fails on a stored value that is not). The write path's channel, its
/// `PlaneWriteLedger` and its log are all three, so every view writes through the one channel,
/// decides by the one ledger and logs through the one log.
///
/// **What that bounds, exactly.** *While it is the only supervisor-priority read outstanding*, a
/// read issued here waits for the turn in flight, at most one snapshot turn the overtake quota
/// forces, and at most one of § 3's lane turns **at each turn boundary it waits through** (ADR
/// 0012's 2026-10-18 amendment): the lane is admitted ahead of every waiting turn, and § 3
/// re-queues only after its turn is handed on. So at most four turns ahead of it — in flight, a
/// lane turn, the forced snapshot turn, a lane turn — against the ~500 ms a snapshot-length
/// occupation costs; the two without the lane are ~22 ms. It does not bound the wait when several
/// are outstanding, which `LeaseAuthority.refuseIfBlind` already makes possible today; the
/// scheduler's own documentation carries the general form, and this comment stated the
/// two-turn figure unconditionally until a review panel produced the counterexample.
///
/// ## Restore issues no read, and that is the property to keep
///
/// `restoreToAutomatic(_:)` touches no provider and reads nothing through its channel: its turn
/// is the ledger's plan and one zero-byte write per key (`SMCWriteTurns.keystone`). `.everyFan`
/// resolves from the fan set the preparation step established at startup and the fans this
/// process touched, never from a read issued at restore time.
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s keystone is that the terminal
/// action of every safety mechanism stays available when reading is precisely what has
/// failed, and a restore that reads first is a restore that is missing in the one case it
/// exists for. `SMCFanControlPlaneTests` asserts the provider records no request on a plane that
/// cannot write, and `SMCWriteTurnBodyTests` that a keystone turn over the fake makes no read.
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

    /// The admission every turn this plane takes is admitted at: `.supervisor` for the plane the
    /// composition builds, § 3's lane for the view § 3 is given (`admitted(at:)`). Set by nothing
    /// else, so a plane's admission is fixed when the view is made. The write turns take it too: a
    /// view's admission is its turns', reads and writes alike (ADR 0012's #440 amendment, B1).
    private(set) var admission: PlaneAdmission = .supervisor

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
    ///
    /// `channel` **is** defaulted, to `nil`: a plane nobody gave a channel can never write, and
    /// every construction that predates it means what it meant. In the daemon it is
    /// `AeolusHelperMain`'s `DaemonWriteChannel`, over the same connection; `SMCConnection` itself
    /// is not a channel (ADR 0014's B1 seam amendment). In a test it is `FirmwareSMC`, and only
    /// over a scheduler reading the same fake.
    ///
    /// `log` is where the write turns log every write and every step (`SMCWriteTurns`); the
    /// composition's default is the helper's safety log.
    init(
        scheduler: SMCReadScheduler, connection: some SMCConnectionRecycling,
        channel: (any SMCWriteChannel)? = nil, log: SafetyLog = SafetyLog()
    ) {
        self.scheduler = scheduler
        self.connection = connection
        self.writeChannel = channel
        self.writeLog = PlaneWriteLog(log)
    }

    /// The channel the plane's write turns run on, or `nil` for a plane that cannot write. See this
    /// type's documentation: every use is the channel argument of one write turn.
    private let writeChannel: (any SMCWriteChannel)?

    /// The plane's write state between calls (ADR 0014 D4, D5): one instance, stored here and
    /// copied into every view by reference, so a restore through § 3's view supersedes a step
    /// through the plane and the reverse. A plane that cannot write holds one too, and touches it
    /// only to forward an engagement's ticket.
    private let ledger = PlaneWriteLedger()

    /// Where the write turns log, shared by every view.
    private let writeLog: PlaneWriteLog

    /// Whether this plane was given a write channel: what `writeCapability` answers from. A fact
    /// for tests beyond that, surfaced over no XPC message, in no snapshot and in no log line.
    var holdsWriteChannel: Bool { writeChannel != nil }

    /// This plane at `admission`: a copy with every stored reference shared and the admission
    /// changed. See this type's documentation, and `FanControlPlane.admitted(at:)`.
    func admitted(at admission: PlaneAdmission) -> SMCFanControlPlane {
        var view = self
        view.admission = admission
        return view
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
    /// **Except the snapshot's read of the same fact**
    /// ([#360](https://github.com/blamechris/Aeolus/issues/360)). `SnapshotFanModeReads` decodes
    /// `F<n>Md` on its own, and since #360 a mode it cannot read is refused `.supervisorBlind`
    /// on a seam that can write. A platform branch added here — Intel's `FS!` bit — must be
    /// taken there too, or the decode shared, **in the same change**: otherwise every fan on
    /// that platform reads `.supervisorBlind` for ever while the grant, reading through this
    /// method, grants.
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

    // MARK: - Writes

    /// `.built` exactly when this plane holds a write channel (ADR 0014's B1 amendment), and the
    /// same fact the verbs below act on: a plane given none answers `.notBuilt` and every verb
    /// refuses with `.controlPathNotBuilt`, so `LeaseAuthority`, which asks this **before**
    /// spending an SMC read on a grant, never grants a fan nothing can command (`CLAUDE.md` rule
    /// 6). Computed rather than stored, so no initialiser can be given a different answer.
    var writeCapability: FanWriteCapability { holdsWriteChannel ? .built : .notBuilt }

    /// Requests the restore — the epoch moves and `.forExit` seals, synchronously, **before** it
    /// waits for a turn (D4) — then issues it in one turn at this plane's admission: the ledger's
    /// plan for `scope`, one zero-byte write per key, no read (`SMCWriteTurns.keystone`).
    ///
    /// A plane that cannot write refuses **without reading anything** and without requesting the
    /// restore: it has nothing a request could supersede.
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        guard let writeChannel else { throw FanControlPlaneError.controlPathNotBuilt }
        ledger.restoreRequested(scope)
        try await scheduler.withWriteTurn(at: admission, on: writeChannel) { channel in
            try SMCWriteTurns.keystone(scope, ledger: ledger, log: writeLog, on: channel)
        }
    }

    /// The engagement's ticket, forwarded to the ledger: synchronous, index-only, and write-free
    /// (ADR 0014's #410 ticket-and-seal amendment). A plane that cannot write forwards it too; its
    /// step refuses before the ledger is asked.
    func beginEngagement(fanAt index: Int) {
        ledger.beginEngagement(fanAt: index)
    }

    /// One step of D3, in one turn at this plane's admission (`SMCWriteTurns.step`): admitted
    /// first, then the mode key's info, its raw pre-state, `F<n>Md = 1`, and the read-back, the
    /// force key or nothing; a read-back of `1` then holds `F<n>Tg` at or above the permit's floor
    /// before the step answers `.engaged` (ADR 0014's P1′ amendment, decision 4). The permit goes
    /// into the turn for that floor, and its fan is the one written. Uncancellable once queued:
    /// the turn's wait is not cancellable and the job is synchronous, so an admitted step never
    /// throws a `CancellationError`.
    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        guard let writeChannel else { throw FanControlPlaneError.controlPathNotBuilt }
        return try await scheduler.withWriteTurn(at: admission, on: writeChannel) { channel in
            try SMCWriteTurns.step(fan, ledger: ledger, log: writeLog, on: channel)
        }
    }

    /// `F<n>Tg`, in one turn at this plane's admission (`SMCWriteTurns.command`): admitted first
    /// (the exit's seal), refused below the permit's floor, then the key's info, the encoded
    /// target, its write and its read-back. Returns the permit's rpm once the read-back holds it.
    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        guard let writeChannel else { throw FanControlPlaneError.controlPathNotBuilt }
        let command = TargetCommand(
            fan: target.fanIndex, rpm: target.rpm, floor: target.lowestCommandableRPM)
        return try await scheduler.withWriteTurn(at: admission, on: writeChannel) { channel in
            try SMCWriteTurns.command(command, ledger: ledger, log: writeLog, on: channel)
        }
    }

    /// § 3's bridge for one fan, as one job: the `.fan(n)` restore **requested first**, before the
    /// job waits for its turn (D4), then — in one turn at this plane's admission — the command's
    /// body and the restore's, the second whatever the first answered
    /// (`BridgeOutcome.attempting`). The bodies are the command turn's and the restore turn's, with
    /// no second copy of either. It never throws.
    ///
    /// A plane that cannot write refuses both halves **without reading anything**, and without
    /// requesting the restore.
    func bridgeThenRestore(_ target: AuthorisedFanTarget) async -> BridgeOutcome {
        guard let writeChannel else {
            return BridgeOutcome.attempting(
                maximum: { throw FanControlPlaneError.controlPathNotBuilt },
                thenRestore: { throw FanControlPlaneError.controlPathNotBuilt })
        }
        let command = TargetCommand(
            fan: target.fanIndex, rpm: target.rpm, floor: target.lowestCommandableRPM)
        let scope = FanRestoreScope.fan(target.fanIndex)
        ledger.restoreRequested(scope)
        do {
            return try await scheduler.withWriteTurn(at: admission, on: writeChannel) { channel in
                BridgeOutcome.attempting(
                    maximum: {
                        try SMCWriteTurns.command(
                            command, ledger: ledger, log: writeLog, on: channel)
                    },
                    thenRestore: {
                        try SMCWriteTurns.keystone(
                            scope, ledger: ledger, log: writeLog, on: channel)
                    })
            }
        } catch {
            // Unreachable: the job throws nothing, and the turn's wait is not cancellable. Stated
            // as both halves failing rather than assumed away, so the verb stays total.
            return BridgeOutcome(maximum: .failure(error), restore: .failure(error))
        }
    }

    /// The write path's preparation step (ADR 0014 D5), on a plane that can write; `nil`, with no
    /// enumeration, no read and no write, on one that cannot.
    ///
    /// 1. Enumerates the fans through `fans`, the composition's own enumeration.
    /// 2. and 3. In one turn, its reads (`SMCWriteTurns.survey`): each fan's mode key info, for the
    ///    declared size a restore writes zeros of, and its target key info; then `Ftst`'s key info
    ///    and, when it answered, its raw value. `Ftst` is absent only on the firmware's not-found
    ///    answer, which P1 did not probe (`SMCWriteTurns.forceKeyNotFoundAnswer`, `nil`), so every
    ///    failure is unknown.
    /// 4. Records what it found in the ledger, then issues `restoreToAutomatic(.everyFan)` once if
    ///    the key read non-zero, is unknown, or would not read
    ///    (`WritePathPreparation.needsMachineWideRestore`).
    ///
    /// **U14 holds** (P1: `Ftst` read `0` on every sample, through two loads and their soaks): a
    /// non-zero `Ftst` at start is taken as a dead holder's, so the step clears it. It does not read
    /// `F<n>Md`, so a fan Apple has stopped, raw `3`, asks for no restore here.
    ///
    /// It never throws: what it found and did is returned for the composition to log.
    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        guard let writeChannel else { return nil }
        let enumerated: Set<Int>?
        do {
            enumerated = try await fans.enumeratedFanIndices()
        } catch {
            enumerated = nil
        }
        let notFound = SMCWriteTurns.forceKeyNotFoundAnswer
        let survey: SMCWriteTurns.Survey
        do {
            survey = try await scheduler.withWriteTurn(at: admission, on: writeChannel) { channel in
                SMCWriteTurns.survey(fans: enumerated, notFound: notFound, on: channel)
            }
        } catch {
            // Unreachable: the job throws nothing. A survey that found nothing is the honest
            // record of it: no sizes, and a key that is unknown.
            survey = SMCWriteTurns.Survey(
                declaredSizes: [:], forceKey: .unknown(detail: "\(error)"))
        }
        ledger.recordPreparation(
            enumerated: enumerated, forceKey: survey.forceKey.presence,
            declaredSizes: survey.declaredSizes)

        var restore: WritePathPreparation.MachineWideRestore?
        if WritePathPreparation.needsMachineWideRestore(survey.forceKey) {
            do {
                try await restoreToAutomatic(.everyFan)
                restore = .landed
            } catch {
                restore = .refused(detail: String(describing: error))
            }
        }
        return WritePathPreparation(
            enumeratedFans: enumerated, forceKey: survey.forceKey, machineWideRestore: restore,
            declaredSizes: survey.declaredSizes)
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
            outcomes = try await scheduler.read(keys: keys.map(\.rawValue), at: admission.priority)
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

/// The production recycler: `SMCConnection`'s own `close()` and `open()`, one call each.
///
/// A wrapper rather than an `extension SMCConnection: SMCConnectionRecycling {}`, though that
/// conformance would be harmless — both verbs are `public`. The helper declares no extension of
/// `SMCConnection` at all, in any form (ADR 0014's B1 seam amendment): a conformance is visible
/// wherever its protocol is, and the empty `SMCWriteChannel` conformance that let every `@testable`
/// test write was exactly this shape. A rule with no exception is one a scan can hold
/// (`WritePathAbsenceTests.noHelperFileOpensSMCConnectionsIsolation`).
struct SMCConnectionRecycler: SMCConnectionRecycling {
    let connection: SMCConnection

    func close() async { await connection.close() }

    func open() async throws { try await connection.open() }
}
