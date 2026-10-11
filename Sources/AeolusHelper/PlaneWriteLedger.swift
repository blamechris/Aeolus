import SMCCore
import os

// What a plane that can write must remember between calls, and the rules it decides by
// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D3 to D5). Bookkeeping and pure
// functions only: the conformer performs every read and every write, so nothing here can reach
// the firmware, the keystone gains no input, and no restore consumes trusted data.
//
// **Below the seam.** It is held by the plane that writes — `ScriptedControlPlane` on `main`,
// `SMCFanControlPlane` from the E4 branch's B1 — and by nothing above it, which is how "above
// the seam, nothing writes, reads or names `Ftst`" stays true while two conformers share one
// set of rules. It takes fan indices rather than permits for the same reason: an index here
// only decides what a restore covers, and a restore takes no permit.

/// Whether the firmware declares the Apple Silicon force key, as the bring-up preparation step
/// recorded it (D5).
enum ForceKeyPresence: Sendable, Hashable {
    case present
    /// The firmware reported no such key. It is never read or written again.
    case absent
    /// The key-info read failed. Treated as present: D3 may set it, and a restore writes it one
    /// zero byte.
    case unknown
}

/// What the firmware answered to one write, as D3 distinguishes the answers.
enum FirmwareWriteAnswer: Sendable, Hashable {
    /// `0x00`.
    case accepted
    /// `0x82`: the reported answer while the thermal manager is asserting control.
    case heldBySystem
    /// Anything else, including the codes this machine has returned to reads (`0x89`, `0xc7`,
    /// `0xcb`, `0xd8`). D3 retries none of them.
    case refused(code: UInt8)
}

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
    /// `0x82` only means the yield has not arrived yet.
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
        }
    }

    /// Step 2's read-back: raw `1` is engagement, because the same turn read `0` before the
    /// write (or an earlier step did, under the same epoch).
    static func afterReadBack(rawMode: UInt8, fanAt index: Int) throws -> EngagementStep {
        guard rawMode == 1 else {
            throw FanControlPlaneError.engagementNotConfirmed(index: index, rawMode: rawMode)
        }
        return .engaged
    }

    /// Step 3's force-key write: accepted sets the plane's flag; anything else is refused.
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

/// The restore epoch, the engaged set, the touched set, the force-key flag and what the
/// preparation step recorded (D4, D5), lock-guarded under `SMCRoundTripMonitor`'s discipline so a
/// plane that is a `struct` can hold it.
///
/// - **The epoch** moves when a restore is *requested* (`restoreRequested()`), synchronously,
///   before the restore waits for its turn. An engagement records it at its first step, and a
///   later step admitted under an older one writes nothing (`admitStep(fanAt:)`). That holds for
///   a restore of any fan, the engaging fan's own and a machine-wide one included: a restore
///   leaves the engagement's record as it was, and the mismatch is what supersedes it.
/// - **The engaged set** holds a fan from its confirmed read-back until a restore covering it
///   is *issued* — inside the restore's turn, whatever the firmware then answers.
/// - **The touched set** holds every addressable fan this plane issued a mode write to or
///   restored by index, and never shrinks: a machine-wide restore writes it whatever the
///   enumeration knew.
/// - **The force-key flag** is set when this plane's `Ftst = 1` is accepted and cleared when a
///   restore issues `Ftst = 0`.
///
/// **What the epoch cannot see: an engagement's first step.** The epoch is recorded *at* that
/// step, so a restore requested between the driver's entitlement check and the first step's
/// turn does not supersede it. That is ADR 0009 D1's residual — the check is not atomic with the
/// write — and it is discharged the way D1 prescribes: every genuine restore path either ends
/// the lease (immediately before or right after the restore) or latches § 3, and the driver
/// asks both again after the step and undoes.
final class PlaneWriteLedger: Sendable {

    /// How a step was admitted: an engagement's first step records the epoch it runs under.
    enum Admission: Sendable, Hashable {
        case first
        case continuing
    }

    private struct State: Sendable {
        var epoch: UInt64 = 0
        /// The epoch each engagement in progress recorded at its first step. A restore never
        /// erases one; a step finding it out of date throws `.superseded` and removes it.
        var inProgress: [Int: UInt64] = [:]
        var engaged: Set<Int> = []
        var touched: Set<Int> = []
        var forceKeySet = false
        /// `nil` until the preparation step enumerated the fans, and after it failed to.
        var enumerated: Set<Int>?
        var forceKey: ForceKeyPresence
    }

    private let state: OSAllocatedUnfairLock<State>

    /// A ledger as the preparation step left it. The defaults are a plane nothing has prepared:
    /// no fan set and an unknown key, so a machine-wide restore writes what it was touched with
    /// and the key, and says the rest is unknown.
    init(enumerated: Set<Int>? = nil, forceKey: ForceKeyPresence = .unknown) {
        state = OSAllocatedUnfairLock(
            initialState: State(enumerated: enumerated, forceKey: forceKey))
    }

    // MARK: - What the preparation step recorded

    func recordPreparation(enumerated: Set<Int>?, forceKey: ForceKeyPresence) {
        state.withLock {
            $0.enumerated = enumerated
            $0.forceKey = forceKey
        }
    }

    var forceKey: ForceKeyPresence { state.withLock { $0.forceKey } }
    var isForceKeySet: Bool { state.withLock { $0.forceKeySet } }
    var engagedFans: Set<Int> { state.withLock { $0.engaged } }
    var touchedFans: Set<Int> { state.withLock { $0.touched } }

    // MARK: - Engagement

    /// Admits one step for `index`, or throws `.superseded` when a restore was requested after
    /// the engagement's first step. Called first in the step's turn, before any read or write,
    /// so a superseded step has written nothing.
    ///
    /// A record found out of date is removed as it refuses. A *fresh* engagement can find one —
    /// left by an earlier engagement of the same fan, whose undo is itself a restore — and the
    /// driver retries its first step once for that reason, after asking the entitlement again.
    func admitStep(fanAt index: Int) throws -> Admission {
        try state.withLock { state in
            guard let recorded = state.inProgress[index] else {
                state.inProgress[index] = state.epoch
                return .first
            }
            guard recorded == state.epoch else {
                state.inProgress[index] = nil
                throw FanControlPlaneError.superseded
            }
            return .continuing
        }
    }

    /// Whether no restore has been requested since this engagement began: D3 step 3's re-check
    /// inside the turn, before the force-key write.
    func isCurrent(fanAt index: Int) -> Bool {
        state.withLock { $0.inProgress[index] == $0.epoch }
    }

    /// A mode write was issued to `index`: from here the fan may be off automatic control, so a
    /// machine-wide restore must write it whatever the enumeration knows.
    func recordModeWriteIssued(fanAt index: Int) {
        state.withLock { _ = $0.touched.insert(index) }
    }

    /// The step read back raw `1`: the fan joins the engaged and touched sets.
    func recordEngaged(fanAt index: Int) {
        state.withLock {
            $0.inProgress[index] = nil
            $0.engaged.insert(index)
            $0.touched.insert(index)
        }
    }

    /// The step threw. The engagement is over; the driver's undo is what restores the fan.
    func recordStepRefused(fanAt index: Int) {
        state.withLock { _ = $0.inProgress.removeValue(forKey: index) }
    }

    /// This plane's `Ftst = 1` was accepted.
    func recordForceKeyAccepted() {
        state.withLock { $0.forceKeySet = true }
    }

    // MARK: - Restores

    /// A restore was requested: the epoch moves, and every engagement in progress is superseded.
    /// Called synchronously when `restoreToAutomatic(_:)` is called, before it waits for a turn,
    /// so no forward write lands after a restore that was requested first. It decides nothing
    /// else: what the restore writes is decided when it is issued.
    func restoreRequested() {
        state.withLock { $0.epoch &+= 1 }
    }

    /// Issues a `.fan(index)` restore, inside its turn: the fan's mode write, then the force
    /// key's clear if nothing depends on the key any more — never while another engaged fan
    /// does, including one whose engagement completed after this restore was requested, and
    /// never while an engagement under the **current** epoch is still waiting for its yield: it
    /// began after this restore was requested, so this restore does not supersede it, and it
    /// may be the one that set the key. One under an older epoch is superseded anyway.
    func issueRestore(fanAt index: Int) -> RestorePlan {
        state.withLock { state in
            state.engaged.remove(index)
            if SMCKey.fanMode(index) != nil { state.touched.insert(index) }
            let current = state.epoch
            let clearsKey =
                state.forceKeySet && state.engaged.isEmpty
                && !state.inProgress.values.contains(current)
            if clearsKey { state.forceKeySet = false }
            return RestorePlan(modeFans: [index], clearsForceKey: clearsKey, fanSetUnknown: false)
        }
    }

    /// Issues a machine-wide restore, inside its turn: every enumerated fan and every touched
    /// fan, then the force key unless it is recorded absent. A failed enumeration is reported
    /// by the plan, after every write it can name.
    func issueMachineWideRestore() -> RestorePlan {
        state.withLock { state in
            state.engaged.removeAll()
            state.forceKeySet = false
            let fans = (state.enumerated ?? []).union(state.touched)
            return RestorePlan(
                modeFans: fans.sorted(), clearsForceKey: state.forceKey != .absent,
                fanSetUnknown: state.enumerated == nil)
        }
    }
}

/// One restore's writes, in the order they must be issued: the unlock reversed (D5).
///
/// Every `F<n>Md = 0` first, then `Ftst = 0`, so each mode write is issued in the force-key state
/// in which its forward write was accepted. Every write is attempted whatever the others
/// answered, and the restore throws only after all of them were.
struct RestorePlan: Sendable, Hashable {

    enum Write: Sendable, Hashable {
        /// `F<n>Md = 0`.
        case mode(fan: Int)
        /// `Ftst = 0`.
        case forceKey
    }

    let writes: [Write]

    /// The machine-wide restore's fan set was unknown: what it wrote is all it could name.
    let fanSetUnknown: Bool

    init(modeFans: [Int], clearsForceKey: Bool, fanSetUnknown: Bool) {
        writes = modeFans.map { Write.mode(fan: $0) } + (clearsForceKey ? [.forceKey] : [])
        self.fanSetUnknown = fanSetUnknown
    }

    /// Issues every write through `issue`, then reports: `.fanSetUnknown` when the fan set was
    /// unknown, otherwise the first refusal, if any. Synchronous, because a plane issues the
    /// whole restore inside one turn.
    func attemptEvery(_ issue: (Write) throws -> Void) throws {
        var firstRefusal: (write: Write, error: any Error)?
        for each in writes {
            do {
                try issue(each)
            } catch {
                if firstRefusal == nil { firstRefusal = (each, error) }
            }
        }
        if fanSetUnknown {
            throw FanControlPlaneError.fanSetUnknown(
                refusedWrite: firstRefusal.map { "\($0.write): \($0.error)" })
        }
        if let firstRefusal { throw firstRefusal.error }
    }
}

/// What the bring-up preparation step found and did (D5), for `HelperComposition` to log.
struct WritePathPreparation: Sendable, Hashable {

    /// What the step learned about the force key.
    enum ForceKey: Sendable, Hashable {
        /// The firmware reported no such key.
        case absent
        /// The key-info read failed.
        case unknown(detail: String)
        /// Present, and its raw value read as this.
        case reads(UInt8)
        /// Present, and its value read failed.
        case unreadable(detail: String)

        var presence: ForceKeyPresence {
            switch self {
            case .absent: return .absent
            case .unknown: return .unknown
            case .reads, .unreadable: return .present
            }
        }
    }

    /// The machine-wide restore the step issued, as it answered.
    enum MachineWideRestore: Sendable, Hashable {
        case landed
        case refused(detail: String)
    }

    /// The enumerated fans, or `nil` when the enumeration failed. D8's start-0 check reads it.
    let enumeratedFans: Set<Int>?
    let forceKey: ForceKey
    /// `nil` when none was issued, which on a quiescent machine is the ordinary case.
    let machineWideRestore: MachineWideRestore?

    /// D5 step 4: one machine-wide restore when the key reads set, is unknown, or will not
    /// read. An absent key is never read or written again, and one reading `0` needs nothing.
    static func needsMachineWideRestore(_ forceKey: ForceKey) -> Bool {
        switch forceKey {
        case .absent: return false
        case .reads(let raw): return raw != 0
        case .unknown, .unreadable: return true
        }
    }
}
