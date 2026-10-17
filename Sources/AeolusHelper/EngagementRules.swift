// D3's rules: what each answer the firmware gives an engagement step means, as pure functions
// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D3). Moved from `PlaneWriteLedger.swift`
// unchanged, so that file stays inside `file_length`'s warning.
//
// **Below the seam,** with the ledger: the plane that writes — `ScriptedControlPlane` on `main`,
// `SMCFanControlPlane` from the E4 branch's B1 — decides by these, so the two cannot come to decide
// differently. Above it, level 6 reads one rule, `EngagementRules.isEngagedMode`, a predicate on a
// value the driver's refusal carried.

/// D3's decisions, as functions of what the firmware answered.
///
/// The plane performs each read and write inside its step's one turn; these say what each answer
/// means, so the production plane and the scripted one cannot come to decide differently. The
/// sequence they encode is the hypothesis under test, not a specification (D3).
enum EngagementRules {

    /// What the plane does next, in the same turn, after its mode write was answered.
    enum AfterModeWrite: Sendable, Hashable {
        /// Read raw `F<n>Md` back.
        case readBack
        /// Re-check the restore epoch, take a fresh key info, and write `Ftst = 1`.
        case setForceKey
        /// Write nothing more. The fan waits for its yield under a key already set.
        case awaitYield
    }

    /// Step 1: a fan whose raw mode is not `0` is not Aeolus's to take, and nothing is written.
    static func requireAutomatic(rawMode: UInt8, fanAt index: Int) throws {
        guard rawMode == 0 else {
            throw FanControlPlaneError.notAutomatic(index: index, rawMode: rawMode)
        }
    }

    /// Steps 2 to 4. `firstStep` is the engagement's first; a later one is a Y-write, whose
    /// `0x82` only means the yield has not arrived yet. A write with no answer throws on every
    /// step: it is never read as `0x82`, so never retried and never a reason to set the key, and
    /// the driver undoes it as a write that may have landed (ADR 0014's B1 amendment).
    static func afterModeWrite(
        _ answer: FirmwareWriteAnswer, firstStep: Bool, forceKey: ForceKeyPresence,
        forceKeySet: Bool
    ) throws -> AfterModeWrite {
        switch answer {
        case .accepted:
            return .readBack
        case .heldBySystem:
            // A Y-write, or a second fan engaging while another holds the key: wait under it.
            guard firstStep, !forceKeySet else { return .awaitYield }
            guard forceKey != .absent else {
                throw FanControlPlaneError.firmwareRefusedControl(
                    detail: "the mode write was held (0x82) and this firmware has no force key")
            }
            return .setForceKey
        case .refused(let code):
            throw FanControlPlaneError.firmwareRefusedControl(
                detail: "the mode write answered \(hex(code)); D3 retries no such answer")
        case .unanswered(let detail):
            throw FanControlPlaneError.firmwareRefusedControl(
                detail: "the mode write was not answered (\(detail)); D3 retries no such write")
        }
    }

    /// Raw `1`, the value an engagement writes (U4): what step 2 confirms it by, and what level 6
    /// reads a fan whose hand-back was refused by (ADR 0014's #410 refused-hand-back amendment).
    static func isEngagedMode(_ rawMode: UInt8) -> Bool { rawMode == 1 }

    /// Step 2's read-back: `isEngagedMode(_:)` is engagement, because the same turn read `0`
    /// before the write (or an earlier step did, under the same epoch).
    static func afterReadBack(rawMode: UInt8, fanAt index: Int) throws -> EngagementStep {
        guard isEngagedMode(rawMode) else {
            throw FanControlPlaneError.engagementNotConfirmed(index: index, rawMode: rawMode)
        }
        return .engaged
    }

    /// Step 3's force-key write: accepted awaits the yield; anything else is thrown, an unanswered
    /// write included. The plane records the answer first (`PlaneWriteLedger.recordForceKeyWrite`),
    /// whose flag an unanswered write also sets, so the undo clears a key it may have set.
    static func afterForceKeyWrite(_ answer: FirmwareWriteAnswer) throws -> EngagementStep {
        guard answer == .accepted else {
            throw FanControlPlaneError.firmwareRefusedControl(
                detail: "Ftst = 1 answered \(answer)")
        }
        return .awaitingYield
    }

    private static func hex(_ code: UInt8) -> String {
        "0x" + String(code, radix: 16, uppercase: false)
    }
}
