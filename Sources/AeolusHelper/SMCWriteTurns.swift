import FanKit
import SMCCore

// The Apple Silicon write plane's turns: an engagement step, a target command, a restore and the
// preparation step's reads, each one synchronous job on an `isolated` channel inside one scheduler
// write turn ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s B1 amendment).
// `SMCFanControlPlane` takes the turn — `SMCReadScheduler.withWriteTurn(at:on:_:)`, at its own
// admission — and hands the job one of these; nothing else calls them.
//
// **Below the seam.** These are the bodies of the plane's write verbs, not verbs, and they decide
// nothing `PlaneWriteLedger` and `EngagementRules` do not, so the scripted double and this plane
// decide every answer by the same code. They take fan indices and numbers the plane read out of
// its permits, with one exception: an engagement step takes its fan's permit, so that the turn
// which reads back engaged holds the permit's own floor, decided by
// `EngagementRules.engagedTarget(reading:of:)` exactly as the double decides it (ADR 0014's P1′
// amendment, decision 4). The step writes only the permit's fan. No `FanRestoreScope` case is
// named in this file: a restore is planned by `ledger.plan(for:)` from the scope the plane passes
// in.
//
// **One job per turn, nothing suspended.** Every function here is synchronous on the channel's
// executor, so between the ledger's admission — the first statement of every turn — and the last
// write, nothing else runs on the connection and nothing can cancel the job (U15; C12).
//
// **Round trips.** `WatchdogLimits.engagedStepRoundTrips` (9) bounds the step that reads back
// `.engaged`, whatever it writes and whatever the key-info cache holds. Raising its fan to the
// floor it is eight with `F<n>Tg`'s key info cached — key info, pre-state, mode write, read-back,
// the target's read, its fresh key info, the floor's write and its read-back — and nine when the
// target's read takes the key info itself, because the preparation step's priming (`survey`) and
// every grant's control-state read carry a failure rather than throw it. Holding, it is five and
// six. `WatchdogLimits.writeTurnRoundTrips` (5) bounds every other turn: a first step on the
// force-key path is five (key info, pre-state, mode write, the key's info, its write); a command
// is three; a restore is one per key, three on `Mac16,5`; § 3's bridge job is a command and a
// `.fan(n)` restore, at most five.

/// The write plane's turn bodies (ADR 0014 D2–D5, D7, and the B1 amendment's rulings).
enum SMCWriteTurns {

    // MARK: - Settled by P1′

    /// The answer the firmware gives `READ_KEYINFO` for a key it does not have — the one answer
    /// that classifies `Ftst` as absent (the B1 amendment: "`Ftst` will be absent only on the
    /// firmware's not-found answer").
    ///
    /// **Unprobed, and `nil`.** No such answer has been observed on any machine this project has,
    /// and P1 did not probe one (ADR 0014's P1′ amendment, "What remains"). So **no failure
    /// classifies `Ftst` as absent**: every one is `.unknown`, which D5 treats as present — a
    /// restore writes it one zero byte and the preparation step issues its machine-wide restore.
    /// That fails safe; on a machine that truly lacks the key (M1/M2, untested) it costs one logged
    /// machine-wide restore at every start.
    static let forceKeyNotFoundAnswer: SMCError? = nil

    // MARK: - An engagement step (D3)

    /// One step of an engagement of `fan`: admitted first, then — in this one turn — the mode
    /// key's fresh key info, its raw pre-state, `F<n>Md = 1`, and the read-back, the force key, or
    /// nothing, as `EngagementRules` decides from the answer. A read-back of `1` is followed, in
    /// the same turn, by the floor hold (`holdFloor`), and only once that holds is the fan
    /// recorded engaged and the step answered `.engaged`.
    ///
    /// - A **first** step decides on its pre-state (`requireAutomatic`: a byte in Apple's set,
    ///   `0` or `3`), and a failure before its write call — the key info, a declared type that is
    ///   not the observed `ui8` of one byte, the pre-state read — is `.failedBeforeFirstWrite`,
    ///   with nothing written.
    /// - A **later** step is a Y-write: it reads the pre-state too, for D8's record, but logs a
    ///   failed read rather than throwing it, and a key-info failure is `.readFailed`. The poll
    ///   stays Y-write (ADR 0014's P1′ amendment, decision 3).
    /// - Every throw after admission records the step refused, so no later step is admitted under
    ///   it (`recordStepRefused(fanAt:)`), and leaves the fan out of the engaged set: the fan is
    ///   engaged only when the step answers `.engaged`, as on the scripted plane.
    ///
    /// The permit is taken for the floor alone. Its index is the fan written, so the step cannot
    /// raise one fan to another's floor (ADR 0008).
    static func step(
        _ fan: CommandableFan, ledger: PlaneWriteLedger, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) throws -> EngagementStep {
        let index = fan.index
        let first = try ledger.admitStep(fanAt: index) == .first
        var trace = StepTrace(fan: index, firstStep: first)
        let began = ContinuousClock.now
        defer { log.safety.planeStepped(trace, took: ContinuousClock.now - began) }
        do {
            let step = try unlockStep(
                fanAt: index, trace: &trace, ledger: ledger, log: log, on: channel)
            if step == .engaged {
                try holdFloor(of: fan, log: log, on: channel)
                ledger.recordEngaged(fanAt: index)
            }
            trace.outcome = "\(step)"
            return step
        } catch {
            ledger.recordStepRefused(fanAt: index)
            trace.outcome = "threw \(error)"
            throw error
        }
    }

    /// D3 for one admitted step — whether it is the engagement's first is `trace.firstStep` —
    /// every throw recorded refused by `step`. A read-back of `1` answers `.engaged` here and is
    /// recorded by `step`, after the floor hold.
    private static func unlockStep(
        fanAt index: Int, trace: inout StepTrace, ledger: PlaneWriteLedger, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) throws -> EngagementStep {
        let first = trace.firstStep
        let (modeKey, engagedMode) = try beforeTheModeWrite(
            fanAt: index, firstStep: first, trace: &trace, on: channel)

        // Recorded before the call, whatever it answers: from here the fan may be off automatic
        // control, so a machine-wide restore writes it (D2, D5).
        ledger.recordModeWriteIssued(fanAt: index)
        let answer = issue(engagedMode, to: modeKey, log: log, on: channel)
        trace.modeWrite = describe(answer)

        let next = try EngagementRules.afterModeWrite(
            answer, firstStep: first, forceKey: ledger.forceKey, forceKeySet: ledger.isForceKeySet)
        switch next {
        case .readBack:
            let readBack: UInt8
            do {
                readBack = try rawByte(of: modeKey, on: channel)
            } catch {
                throw FanControlPlaneError.readFailed(
                    detail: "the read-back of \(modeKey): \(error)")
            }
            trace.after = hex(readBack)
            return try EngagementRules.afterReadBack(rawMode: readBack, fanAt: index)
        case .setForceKey:
            return try setForceKey(fanAt: index, ledger: ledger, log: log, on: channel)
        case .awaitYield:
            return .awaitingYield
        }
    }

    /// Everything a step does before its mode write: the key, its fresh key info and declared
    /// type, its raw pre-state, and the bytes it will write, in that order (the B1 amendment's
    /// ruling: key info first, so the mode key costs the same round trips whatever the cache
    /// holds). **The exception** is the engaged step's target read in `holdFloor`: a cold `F<n>Tg`
    /// makes a raise nine, which `WatchdogLimits.engagedStepRoundTrips` counts (ADR 0012's
    /// 2026-10-31 amendment kept the cold path rather than reorder a body the command shares).
    private static func beforeTheModeWrite(
        fanAt index: Int, firstStep first: Bool, trace: inout StepTrace,
        on channel: isolated any SMCWriteChannel
    ) throws -> (key: SMCKey, bytes: [UInt8]) {
        let key: SMCKey
        let bytes: [UInt8]
        do {
            guard let modeKey = SMCKey.fanMode(index) else {
                throw FanControlPlaneError.fanNotAddressable(index: index)
            }
            key = modeKey
            let info = try channel.freshKeyInfo(for: key)
            try requireObserved(.ui8, size: 1, info)
            bytes = try encoded(1, as: info, on: channel)
        } catch {
            guard first else { throw readFailed("\(index)'s mode key info", error) }
            throw FanControlPlaneError.failedBeforeFirstWrite(index: index, detail: "\(error)")
        }

        let rawMode: UInt8
        do {
            rawMode = try rawByte(of: key, on: channel)
        } catch {
            trace.before = "unreadable (\(error))"
            guard first else { return (key, bytes) }
            throw FanControlPlaneError.failedBeforeFirstWrite(
                index: index, detail: "the pre-state read of \(key): \(error)")
        }
        trace.before = hex(rawMode)
        if first { try EngagementRules.requireAutomatic(rawMode: rawMode, fanAt: index) }
        return (key, bytes)
    }

    /// D3 step 3: a first step's mode write was held (`0x82`) and the plane's force-key flag is
    /// clear. In the same turn: the key's fresh info, then the epoch re-checked **immediately
    /// before the write call** (`.supersededAfterWrite` if a restore was requested since this
    /// engagement began), then `Ftst = 1`, recorded issued before the call whatever it answers.
    private static func setForceKey(
        fanAt index: Int, ledger: PlaneWriteLedger, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) throws -> EngagementStep {
        let key = SMCKey.forceTest
        let bytes: [UInt8]
        do {
            let info = try channel.freshKeyInfo(for: key)
            try requireObserved(.ui8, size: 1, info)
            bytes = try encoded(1, as: info, on: channel)
        } catch {
            throw readFailed("the force key's info", error)
        }
        guard ledger.isCurrent(fanAt: index) else {
            throw FanControlPlaneError.supersededAfterWrite
        }
        ledger.recordForceKeyIssued()
        return try EngagementRules.afterForceKeyWrite(issue(bytes, to: key, log: log, on: channel))
    }

    /// The engaged turn's floor hold (ADR 0014's P1′ amendment, decision 4): after the read-back
    /// of `1`, in the same turn, `F<n>Tg` is read and judged by
    /// `EngagementRules.engagedTarget(reading:of:)`, the rule the scripted plane decides by.
    ///
    /// - **At or above the floor** — under load, where Apple's target already is: nothing more
    ///   is written.
    /// - **Below it** — `0` at rest, where Apple's stopped state leaves it: the permit's target
    ///   at its floor is written by the command turn's own body (`writeTarget`) — the key's fresh
    ///   info and its observed `flt` of four bytes, the encoding, the write, and a read-back within
    ///   `ReclamationLimits.targetToleranceRPM` — with no admission of its own: the step's
    ///   admission is this turn's. A refusal, an unanswered write or a read-back that does not
    ///   hold it throws.
    /// - **Unreadable, undecodable or not finite:** it throws. There is no floor to judge it by.
    ///
    /// Every throw ends the step refused, and the driver undoes. No epoch re-check precedes the
    /// raise: it lands inside this admitted turn, so a restore requested since is issued after it
    /// and its mode write is the last word on the fan (D4: "That order is correct").
    ///
    /// The line it logs is run 1's record: the raw target, the floor written, if any, and how it
    /// was answered.
    private static func holdFloor(
        of fan: CommandableFan, log: PlaneWriteLog, on channel: isolated any SMCWriteChannel
    ) throws {
        guard let key = SMCKey.fanTargetRPM(fan.index) else {
            throw FanControlPlaneError.fanNotAddressable(index: fan.index)
        }
        var hold = FloorHoldTrace(fan: fan.index, key: key)
        defer { log.safety.planeHeldFloor(hold) }
        do {
            let reading: FanRPMReadback
            do {
                let value = try channel.read(key)
                hold.raw = hex(value.bytes)
                guard let scalar = try value.scalar() else {
                    throw FanControlPlaneError.readFailed(detail: "\(key) did not decode")
                }
                (hold.decodedRPM, reading) = (scalar, .rpm(scalar))
            } catch {
                reading = .unreadable(reason: "\(error)")
            }
            switch try EngagementRules.engagedTarget(reading: reading, of: fan) {
            case .holds:
                hold.outcome = "held at or above its floor; nothing written"
            case .raise(let floor):
                hold.floorRaisedTo = FanControlPlaneValue.wholeRPM(floor.rpm)
                let readBack = try writeTarget(
                    TargetCommand(
                        fan: floor.fanIndex, rpm: floor.rpm, floor: floor.lowestCommandableRPM),
                    log: log, on: channel)
                hold.outcome = "answered 0x00 and read back \(readBack) RPM"
            }
        } catch {
            hold.outcome = "threw \(error)"
            throw error
        }
    }

    // MARK: - A target command (D7; #410 item 5)

    /// `F<n>Tg = target.rpm` for `target.fan`, read back in the same turn.
    ///
    /// Admitted first (`admitCommand()`, the exit's seal), then `writeTarget`. Within
    /// `ReclamationLimits.targetToleranceRPM` it returns the commanded rpm, never the read-back.
    static func command(
        _ target: TargetCommand, ledger: PlaneWriteLedger, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) throws -> CommandedTarget {
        try ledger.admitCommand()
        _ = try writeTarget(target, log: log, on: channel)
        return CommandedTarget(fanIndex: target.fan, rpm: target.rpm)
    }

    /// `F<n>Tg = target.rpm` for `target.fan`, and its read-back, with no admission: the command
    /// turn's body after its admission, and the engaged turn's floor raise. Returns the read-back.
    ///
    /// `CLAUDE.md` rule 3 at the last hop: a target below `target.floor` — the permit's
    /// `lowestCommandableRPM`, and never below `FanSafetyLimits.minimumManualRPM` whatever is
    /// passed — is refused before anything is read or encoded. `rpm` came through
    /// `FanControlEnvelope`'s clamp, so this refuses nothing a permit can carry; it is here because
    /// `encode` accepts zero, negatives and subnormals, and rule 3 must not rest on one function's
    /// arithmetic three files away. Then the key's fresh info and its declared type (`flt`, four
    /// bytes, as observed), the encoding, the write, and the read-back: outside
    /// `ReclamationLimits.targetToleranceRPM` it throws `.targetNotConfirmed`.
    private static func writeTarget(
        _ target: TargetCommand, log: PlaneWriteLog, on channel: isolated any SMCWriteChannel
    ) throws -> Double {
        let (index, rpm, floor) = (target.fan, target.rpm, target.floor)
        guard let key = SMCKey.fanTargetRPM(index) else {
            throw FanControlPlaneError.fanNotAddressable(index: index)
        }
        let lowest = max(floor, FanSafetyLimits.minimumManualRPM)
        guard rpm >= lowest else {
            throw WriteTurnRefusal(
                key: key,
                detail: "\(rpm) RPM is below the lowest commandable \(lowest) RPM; nothing written")
        }

        let bytes: [UInt8]
        do {
            let info = try channel.freshKeyInfo(for: key)
            try requireObserved(.flt, size: 4, info)
            bytes = try encoded(rpm, as: info, on: channel)
        } catch let refusal as WriteTurnRefusal {
            throw refusal
        } catch {
            throw readFailed("\(key)'s key info", error)
        }

        let answer = issue(bytes, to: key, log: log, on: channel)
        guard answer == .accepted else {
            throw FanControlPlaneError.firmwareRefusedControl(
                detail: "\(key) = \(rpm) RPM answered \(describe(answer))")
        }

        let readBack: Double
        do {
            guard let scalar = try channel.read(key).scalar() else {
                throw FanControlPlaneError.readFailed(detail: "\(key) did not decode")
            }
            readBack = try FanControlPlaneValue.finite(scalar, describing: key.rawValue).get()
        } catch {
            throw readFailed("the read-back of \(key)", error)
        }
        guard abs(readBack - rpm) <= ReclamationLimits.targetToleranceRPM else {
            throw FanControlPlaneError.targetNotConfirmed(
                index: index, commandedRPM: rpm, readBackRPM: readBack)
        }
        return readBack
    }

    // MARK: - A restore (D5, D7)

    /// The restore of `scope`, issued in this turn: `ledger.plan(for:)` first — the issue that
    /// empties the engaged set and decides the force key — then every planned write, each one zero
    /// bytes of the size the preparation step recorded (`restorePayload(for:)`), each attempted
    /// whatever the others answered (`RestorePlan.attemptEvery`), throwing only after all of them.
    /// An `Ftst = 0` answered accepted pays the clear the ledger's flag says is owed, and no other
    /// answer does (#678). **No read**: the keystone takes no trusted data (ADR 0007), and an
    /// absent key is never in the plan to be written.
    static func keystone(
        _ scope: FanRestoreScope, ledger: PlaneWriteLedger, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) throws {
        let plan = ledger.plan(for: scope)
        try plan.attemptEvery { planned in
            let key: SMCKey
            switch planned {
            case .mode(let fan):
                guard let modeKey = SMCKey.fanMode(fan) else {
                    throw FanControlPlaneError.fanNotAddressable(index: fan)
                }
                key = modeKey
            case .forceKey:
                key = SMCKey.forceTest
            }
            let answer = issue(ledger.restorePayload(for: planned), to: key, log: log, on: channel)
            guard answer == .accepted else {
                throw FanControlPlaneError.firmwareRefusedControl(
                    detail: "\(key)'s restore answered \(describe(answer))")
            }
            if case .forceKey = planned { ledger.recordForceKeyCleared() }
        }
    }

    // MARK: - The one write call

    /// `bytes` to `key`, once: **the write plane's one call of the channel's write**, timed and
    /// logged whatever it answered (C23; U8 is measured from these lines, never by a test).
    ///
    /// The answer, as D3 distinguishes them: `0x00` is `.accepted`; a non-zero result byte is
    /// `.heldBySystem` when it is `0x82` (`SMCError.isCommandRejection`) and `.refused` otherwise;
    /// **every other failure is `.unanswered`** — counted as issued and possibly landed, never
    /// retried, thrown, and undone (the B1 amendment). That covers both causes of
    /// `SMCConnection.call(_:)`'s `connectionFailed` — a handle that was never opened, and a kernel
    /// call that failed — and nothing here tells them apart, because no caller may act on the
    /// difference: either may follow a write the firmware took.
    private static func issue(
        _ bytes: [UInt8], to key: SMCKey, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) -> FirmwareWriteAnswer {
        let began = ContinuousClock.now
        let answer: FirmwareWriteAnswer
        do {
            try channel.write(bytes, to: key)
            answer = .accepted
        } catch let error as SMCError {
            answer = Self.answer(to: error)
        } catch {
            answer = .unanswered(detail: "\(error)")
        }
        log.safety.planeWrote(
            key: key, bytes: hex(bytes), answer: describe(answer),
            roundTrip: ContinuousClock.now - began)
        return answer
    }

    /// What one failed write call answered. Only a result byte is an answer; anything else is
    /// none.
    static func answer(to error: SMCError) -> FirmwareWriteAnswer {
        guard case .firmware(let code) = error else { return .unanswered(detail: "\(error)") }
        return error.isCommandRejection ? .heldBySystem : .refused(code: code)
    }
}
