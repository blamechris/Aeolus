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
// only decides what a restore covers, and a restore takes no permit. D3's rules, the functions both
// conformers decide each answer by, are `EngagementRules`, in a file of their own.

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
    /// No answer: the call failed in the kernel, or its reply was cut short. The write was
    /// issued and may have landed (ADR 0014's #410 refused-hand-back amendment, "issued, not
    /// landed"), so it is never retried and never read as `0x82`: it is thrown, and the driver
    /// undoes it.
    case unanswered(detail: String)
}

/// The restore epoch, the engaged set, the touched set, the force-key flag and what the
/// preparation step recorded (D4, D5), lock-guarded under `SMCRoundTripMonitor`'s discipline so a
/// plane that is a `struct` can hold it.
///
/// - **The epoch** moves when a restore is *requested* (`restoreRequested(_:)`), before it waits
///   for its turn. An engagement takes it as its ticket before its entitlement, and no step is
///   admitted under an older one, whichever fan the restore covered (`admitStep(fanAt:)`).
/// - **The seal** is set when `.forExit` is requested, and never cleared: no step or target
///   command is admitted after it, and every restore still is.
/// - **The engaged set** holds a fan from its confirmed read-back until a restore covering it
///   is *issued* — inside the restore's turn, whatever the firmware then answers.
/// - **The touched set** holds every addressable fan this plane issued a mode write to or
///   restored by index, and never shrinks: a machine-wide restore writes it whatever the
///   enumeration knew.
/// - **The force-key flag** is set when this plane's `Ftst = 1` is accepted or goes unanswered,
///   and cleared when a restore issues `Ftst = 0`.
/// - **The declared sizes** are each restore key's, as the preparation step's key-info reads
///   answered: what a restore writes zeros of (`restorePayload(for:)`).
///
/// **What the epoch cannot see.** An engagement's epoch is taken before its entitlement
/// (`beginEngagement(fanAt:)`), so a restore requested after the engagement began supersedes its
/// first step at admission. What is left is ADR 0009 D1's narrower residual: a lease that ends with
/// its restore not yet requested when the step is admitted. The restore that follows covers that
/// write, and the driver's after-check undoes it. At the exit the plane is also sealed: see
/// `.forExit`.
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
        /// The epoch each engagement took before its entitlement, until its first step consumes it.
        var tickets: [Int: UInt64] = [:]
        /// Set by `.forExit`'s request, and never cleared.
        var sealed = false
        var engaged: Set<Int> = []
        var touched: Set<Int> = []
        var forceKeySet = false
        /// `nil` until the preparation step enumerated the fans, and after it failed to.
        var enumerated: Set<Int>?
        var forceKey: ForceKeyPresence
        /// Each restore key's declared size, by key. A key with none is written one zero byte.
        var declaredSizes: [SMCKey: Int]
    }

    private let state: OSAllocatedUnfairLock<State>

    /// A ledger as the preparation step left it. The defaults are a plane nothing has prepared:
    /// no fan set, an unknown key and no sizes, so a machine-wide restore writes what it was
    /// touched with and the key, one zero byte each, and says the rest is unknown.
    init(
        enumerated: Set<Int>? = nil, forceKey: ForceKeyPresence = .unknown,
        declaredSizes: [SMCKey: Int] = [:]
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                enumerated: enumerated, forceKey: forceKey, declaredSizes: declaredSizes))
    }

    // MARK: - What the preparation step recorded

    /// What the preparation step found (D5 steps 1 and 2): the fan set, the force key's presence,
    /// and the declared size of each restore key whose key-info read answered — every enumerated
    /// `F<n>Md`, and `Ftst` when it is present (`WritePathPreparation.declaredSizes`).
    func recordPreparation(
        enumerated: Set<Int>?, forceKey: ForceKeyPresence, declaredSizes: [SMCKey: Int]
    ) {
        state.withLock {
            $0.enumerated = enumerated
            $0.forceKey = forceKey
            $0.declaredSizes = declaredSizes
        }
    }

    /// The bytes a restore writes for `write`: zeros, as many as the preparation step recorded
    /// for its key, or one when it recorded none (D5, D7; ADR 0014's B1 amendment). Pure: no read,
    /// and never `encode`, because zero is all-zero bytes in every numeric type and either byte
    /// order, so the keystone gains no way to fail. A recorded size no SMC payload can carry,
    /// outside one to 32 bytes, is not a size a write can be made with, and is taken as unknown.
    func restorePayload(for write: RestorePlan.Write) -> [UInt8] {
        let key: SMCKey?
        switch write {
        case .mode(let index): key = SMCKey.fanMode(index)
        case .forceKey: key = SMCKey.forceTest
        }
        let recorded = state.withLock { state in key.flatMap { state.declaredSizes[$0] } }
        guard let size = recorded, (1...32).contains(size) else { return [0] }
        return Array(repeating: 0, count: size)
    }

    var forceKey: ForceKeyPresence { state.withLock { $0.forceKey } }
    var isForceKeySet: Bool { state.withLock { $0.forceKeySet } }
    var engagedFans: Set<Int> { state.withLock { $0.engaged } }
    var touchedFans: Set<Int> { state.withLock { $0.touched } }

    // MARK: - Engagement

    /// An engagement of `index` begins: its ticket is the current epoch, taken before the
    /// entitlement (ADR 0014's #410 ticket-and-seal amendment). It clears the fan's in-progress
    /// record, which under the fan's gate can only be one an earlier engagement's undo left.
    func beginEngagement(fanAt index: Int) {
        state.withLock {
            $0.inProgress[index] = nil
            $0.tickets[index] = $0.epoch
        }
    }

    /// Admits one step for `index`, or throws `.superseded`, first in the step's turn. Sealed:
    /// refused. In progress: continued unless a restore was requested since its first step.
    /// Otherwise the ticket is consumed, and only a current one admits `.first`, recorded.
    func admitStep(fanAt index: Int) throws -> Admission {
        try state.withLock { state in
            guard !state.sealed else {
                state.tickets[index] = nil
                state.inProgress[index] = nil
                throw FanControlPlaneError.superseded
            }
            if let recorded = state.inProgress[index] {
                guard recorded == state.epoch else {
                    state.inProgress[index] = nil
                    throw FanControlPlaneError.superseded
                }
                return .continuing
            }
            guard state.tickets.removeValue(forKey: index) == state.epoch else {
                throw FanControlPlaneError.superseded
            }
            state.inProgress[index] = state.epoch
            return .first
        }
    }

    /// Admits one target command, first in its turn, or throws `.superseded` once `.forExit` was
    /// requested. No ticket: after an ordinary restore a command moves no fan's mode.
    func admitCommand() throws {
        try state.withLock { state in
            guard !state.sealed else { throw FanControlPlaneError.superseded }
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

    /// This plane's `Ftst = 1` was answered, recorded before D3 decides on the answer. Accepted, or
    /// unanswered — issued and possibly landed — sets the flag, so the restore that undoes the
    /// engagement clears the key it may have set (D5; ADR 0014's B1 amendment). A refusal does not.
    func recordForceKeyWrite(answered answer: FirmwareWriteAnswer) {
        switch answer {
        case .accepted, .unanswered: state.withLock { $0.forceKeySet = true }
        case .heldBySystem, .refused: break
        }
    }

    // MARK: - Restores

    /// A restore of `scope` was requested, synchronously, before it waits for a turn: the epoch
    /// moves, and `.forExit` seals, in one lock. What it writes is decided when issued.
    func restoreRequested(_ scope: FanRestoreScope) {
        state.withLock { state in
            state.epoch &+= 1
            switch scope {
            case .forExit: state.sealed = true
            case .fan, .everyFan: break
            }
        }
    }

    /// Issues a restore of `scope` inside its turn, never refused, sealed or not: every plane
    /// decides by this, so no two disagree. `.everyFan` and `.forExit` are the machine-wide one.
    func plan(for scope: FanRestoreScope) -> RestorePlan {
        switch scope {
        case .fan(let index): return issueRestore(fanAt: index)
        case .everyFan, .forExit: return issueMachineWideRestore()
        }
    }

    /// Issues a `.fan(index)` restore, inside its turn: the fan's mode write, then the force
    /// key's clear if nothing depends on the key any more — never while another engaged fan
    /// does, including one whose engagement completed after this restore was requested, and
    /// never while an engagement under the **current** epoch is still waiting for its yield: it
    /// began after this restore was requested, so this restore does not supersede it, and it
    /// may be the one that set the key. One under an older epoch is superseded anyway.
    private func issueRestore(fanAt index: Int) -> RestorePlan {
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
    private func issueMachineWideRestore() -> RestorePlan {
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
    /// Each restore key's declared size, as its key-info read answered (D5 step 2): what a
    /// restore writes zeros of. A key whose read failed, or a fan the enumeration did not find,
    /// is absent, and a restore writes it one zero byte (`PlaneWriteLedger.restorePayload(for:)`).
    var declaredSizes: [SMCKey: Int] = [:]

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
