import FanKit
import SMCCore

// The Apple Silicon write plane's turns: an engagement step, a target command, a restore and the
// preparation step's reads, each one synchronous job on an `isolated` channel inside one scheduler
// write turn ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s B1 amendment).
// `SMCFanControlPlane` takes the turn — `SMCReadScheduler.withWriteTurn(at:on:_:)`, at its own
// admission — and hands the job one of these; nothing else calls them.
//
// **Below the seam.** These are the bodies of the plane's write verbs, not verbs: they take fan
// indices and numbers the plane read out of its permits, never a permit, and they decide nothing
// `PlaneWriteLedger` and `EngagementRules` do not, so the scripted double and this plane decide
// every answer by the same code. No `FanRestoreScope` case is named in this file: a restore is
// planned by `ledger.plan(for:)` from the scope the plane passes in.
//
// **One job per turn, nothing suspended.** Every function here is synchronous on the channel's
// executor, so between the ledger's admission — the first statement of every turn — and the last
// write, nothing else runs on the connection and nothing can cancel the job (U15; C12).
//
// **Round trips.** `WatchdogLimits.writeTurnRoundTrips` (5) bounds every step, command and
// restore turn: a first step on the force-key path is five (key info, pre-state, mode write, the
// key's info, its write); one that reads back `.engaged` is five (key info, pre-state, mode write,
// read-back, the target logged — one round trip because the preparation step took that key's
// info, see `survey`); a command is three; a restore is one per key, three on `Mac16,5`; § 3's
// bridge job is a command and a `.fan(n)` restore, at most five.

/// The write plane's turn bodies (ADR 0014 D2–D5, D7, and the B1 amendment's rulings).
enum SMCWriteTurns {

    // MARK: - What waits on P1

    /// The answer the firmware gives `READ_KEYINFO` for a key it does not have — the one answer
    /// that classifies `Ftst` as absent (the B1 amendment: "`Ftst` will be absent only on the
    /// firmware's not-found answer").
    ///
    /// **Waits on P1.** No such answer has been observed on any machine this project has: the
    /// owner-present read-only pre-flight probes `READ_KEYINFO` of a key `Mac16,5` lacks to define
    /// it. Until then it is `nil`, so **no failure classifies `Ftst` as absent**: every one is
    /// `.unknown`, which D5 treats as present — a restore writes it one zero byte and the
    /// preparation step issues its machine-wide restore. That fails safe; on a machine that truly
    /// lacks the key (M1/M2, untested) it costs one logged machine-wide restore at every start.
    static let forceKeyNotFoundAnswer: SMCError? = nil

    // MARK: - An engagement step (D3)

    /// One step of an engagement of fan `index`: admitted first, then — in this one turn — the
    /// mode key's fresh key info, its raw pre-state, `F<n>Md = 1`, and the read-back, the force
    /// key, or nothing, as `EngagementRules` decides from the answer.
    ///
    /// - A **first** step decides on its pre-state (`requireAutomatic`), and a failure before its
    ///   write call — the key info, a declared type that is not the observed `ui8` of one byte,
    ///   the pre-state read — is `.failedBeforeFirstWrite`, with nothing written.
    /// - A **later** step is a Y-write: it reads the pre-state too, for D8's record, but logs a
    ///   failed read rather than throwing it, and a key-info failure is `.readFailed`.
    ///   **Waits on P1**: Y-write is the poll the ADR builds until the pre-flight chooses the
    ///   yield signal (D3); a non-zero raw mode under Apple's management would make it Y-read.
    /// - Every throw after admission records the step refused, so no later step is admitted under
    ///   it (`recordStepRefused(fanAt:)`).
    ///
    /// **Waits on P1** (U0, U14): `0` before the write and `1` after it are what D3 takes as
    /// automatic and engaged. Any other raw value under Apple's own management re-decides D3 and
    /// D5 before run 1, and these two decisions are where it lands.
    static func step(
        fanAt index: Int, ledger: PlaneWriteLedger, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) throws -> EngagementStep {
        let first = try ledger.admitStep(fanAt: index) == .first
        var trace = StepTrace(fan: index, firstStep: first)
        let began = ContinuousClock.now
        defer { log.safety.planeStepped(trace, took: ContinuousClock.now - began) }
        do {
            let step = try unlockStep(
                fanAt: index, trace: &trace, ledger: ledger, log: log, on: channel)
            trace.outcome = "\(step)"
            return step
        } catch {
            ledger.recordStepRefused(fanAt: index)
            trace.outcome = "threw \(error)"
            throw error
        }
    }

    /// D3 for one admitted step — whether it is the engagement's first is `trace.firstStep` —
    /// every throw recorded refused by `step`.
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
            let step = try EngagementRules.afterReadBack(rawMode: readBack, fanAt: index)
            ledger.recordEngaged(fanAt: index)
            readEngagedTarget(fanAt: index, log: log, on: channel)
            return step
        case .setForceKey:
            return try setForceKey(fanAt: index, ledger: ledger, log: log, on: channel)
        case .awaitYield:
            return .awaitingYield
        }
    }

    /// Everything a step does before its mode write: the key, its fresh key info and declared
    /// type, its raw pre-state, and the bytes it will write, in that order (the B1 amendment's
    /// ruling: key info first, so every step takes the same round trips whatever the cache holds).
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

    /// The raw `F<n>Tg` of a fan whose step just read back `.engaged`, logged and nothing more
    /// (ADR 0014's A6 amendment, D3: run 1 logs it). A read that fails is logged as such and
    /// changes nothing: the step has engaged, and this is a record, not a check.
    private static func readEngagedTarget(
        fanAt index: Int, log: PlaneWriteLog, on channel: isolated any SMCWriteChannel
    ) {
        guard let key = SMCKey.fanTargetRPM(index) else { return }
        let raw: String
        do {
            raw = hex(try channel.read(key).bytes)
        } catch {
            raw = "unreadable (\(error))"
        }
        log.safety.planeReadEngagedTarget(fan: index, key: key, raw: raw)
    }

    // MARK: - A target command (D7; #410 item 5)

    /// `F<n>Tg = target.rpm` for `target.fan`, read back in the same turn.
    ///
    /// Admitted first (`admitCommand()`, the exit's seal). Then `CLAUDE.md` rule 3 at the last hop:
    /// a target below `target.floor` — the permit's `lowestCommandableRPM`, and never below
    /// `FanSafetyLimits.minimumManualRPM` whatever is passed — is refused before anything is read
    /// or encoded. `rpm` came through `FanControlEnvelope`'s clamp, so this refuses nothing a
    /// permit can carry; it is here because `encode` accepts zero, negatives and subnormals, and
    /// rule 3 must not rest on one function's arithmetic three files away. Then the key's fresh
    /// info and its declared type (`flt`, four bytes, as observed), the encoding, the write, and
    /// the read-back: within `ReclamationLimits.targetToleranceRPM` it returns the commanded rpm,
    /// never the read-back; otherwise `.targetNotConfirmed`.
    static func command(
        _ target: TargetCommand, ledger: PlaneWriteLedger, log: PlaneWriteLog,
        on channel: isolated any SMCWriteChannel
    ) throws -> CommandedTarget {
        try ledger.admitCommand()
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
        return CommandedTarget(fanIndex: index, rpm: rpm)
    }

    // MARK: - A restore (D5, D7)

    /// The restore of `scope`, issued in this turn: `ledger.plan(for:)` first — the issue that
    /// empties the engaged set and decides the force key — then every planned write, each one zero
    /// bytes of the size the preparation step recorded (`restorePayload(for:)`), each attempted
    /// whatever the others answered (`RestorePlan.attemptEvery`), throwing only after all of them.
    /// **No read**: the keystone takes no trusted data (ADR 0007), and an absent key is never in
    /// the plan to be written.
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

/// What one engagement step saw, for its log line (D3's "raw values read before and after").
struct StepTrace: Sendable {
    let fan: Int
    let firstStep: Bool
    var before = "not read"
    var modeWrite = "not issued"
    var after = "not read"
    var outcome = "unfinished"
}

/// A forward write the turn refused by its own rule, before its write call: a target below the
/// fan's floor, or a value that did not encode. Nothing was written. Every caller treats it as it
/// treats a refused command — the bridge restores, level 6 hands back, § 5 restores — and a
/// first step never throws it: before its first write call, a step's refusal is
/// `.failedBeforeFirstWrite`.
struct WriteTurnRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    let key: SMCKey
    let detail: String

    var description: String { "\(key): \(detail)" }
}

/// A target command's numbers, as the plane reads them out of its permit: the fan, the clamped
/// speed, and the floor the speed was clamped above (`AuthorisedFanTarget.lowestCommandableRPM`).
/// Not a permit: the turn body below the seam takes what the permit says, and
/// `WriteVerbAllowlistTests` holds every permit to the plane's verbs, which hand these on and keep
/// nothing.
struct TargetCommand: Sendable, Hashable {
    let fan: Int
    let rpm: Double
    let floor: Double
}

/// Where the write turns log, held by reference so every view of the plane logs through the one
/// instance (`PlaneViewTests` fails on a stored value a view would copy).
final class PlaneWriteLog: Sendable {
    let safety: SafetyLog

    init(_ safety: SafetyLog) {
        self.safety = safety
    }
}
