// D3's rules: what each answer the firmware gives an engagement step means, as pure functions
// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D3). Moved from `PlaneWriteLedger.swift`
// unchanged, so that file stays inside `file_length`'s warning.
//
// **Below the seam,** with the ledger: the plane that writes — `ScriptedControlPlane` on `main`,
// `SMCFanControlPlane` from the E4 branch's B1 — decides by these, so the two cannot come to decide
// differently. Above it, level 6 reads one rule, `EngagementRules.isEngagedMode`, a predicate on a
// value the driver's refusal carried.
//
// **Apple's management is a set of raw values** (ADR 0014's P1′ amendment): the pre-state admits
// what `FirmwareFanMode(rawByte:)` calls automatic, and the engaged value stays outside that set.

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

    /// Step 1: a fan whose raw mode the fold does not call automatic is not Aeolus's to take, and
    /// nothing is written. Apple's management reads `0` or `3`
    /// (`FirmwareFanMode.systemManagedRawModes`; ADR 0014's P1′ amendment), so a fan Apple has
    /// stopped, this machine's rest state, is admitted, and `1` or any byte outside the set is
    /// refused.
    ///
    /// The same fold the grant reads, `FirmwareFanMode(rawByte:)`, so a fan the grant called
    /// automatic is never refused here as not automatic, and the reverse.
    static func requireAutomatic(rawMode: UInt8, fanAt index: Int) throws {
        guard FirmwareFanMode(rawByte: rawMode) == .automatic else {
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

    /// Raw `1`, the value an engagement writes (U4) and the only one. It stays outside
    /// `FirmwareFanMode.systemManagedRawModes`, so a read-back of it is the plane's own write and
    /// never Apple's (ADR 0014's P1′ amendment).
    static let engagedRawMode: UInt8 = 1

    /// `engagedRawMode`: what step 2 confirms an engagement by, and what level 6 reads a fan whose
    /// hand-back was refused by (ADR 0014's #410 refused-hand-back amendment).
    static func isEngagedMode(_ rawMode: UInt8) -> Bool { rawMode == engagedRawMode }

    /// Step 2's read-back: `isEngagedMode(_:)` is engagement, because the same turn read a value in
    /// Apple's set before the write (or an earlier step did, under the same epoch), and Apple's set
    /// never holds it.
    static func afterReadBack(rawMode: UInt8, fanAt index: Int) throws -> EngagementStep {
        guard isEngagedMode(rawMode) else {
            throw FanControlPlaneError.engagementNotConfirmed(index: index, rawMode: rawMode)
        }
        return .engaged
    }

    /// Step 3's force-key write: accepted awaits the yield; anything else is thrown, an unanswered
    /// write included. The plane recorded the write as issued before making it
    /// (`PlaneWriteLedger.recordForceKeyIssued()`), so the undo clears a key it may have set.
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
