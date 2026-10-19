import AeolusXPC
import FanKit
import Foundation

// Whether a snapshot says a client has lost the control its lease gave it: one definition, for
// `fanctl set` and for the app (#153). `fanctl set` wrote the first one, as
// `SetCommand.loss(in:leaseID:covering:)` on #324, and the app is about to need the same
// judgement. Two copies would be two definitions of "still held", and the day they disagreed one
// client would say "holding" over a fan the other had already called lost.
//
// **Here, and not in `AeolusXPC`.** It is a client's reading of a snapshot, not part of the
// contract the snapshot travels under. `AeolusXPC` is what the root helper links, and a client's
// policy does not belong in the module that *is* the privilege boundary. Both clients link this
// target already, or will.
//
// **Pure, and it keeps nothing.** A function of one snapshot and the caller's own lease
// identifier, both passed in: it stores neither, renews nothing and acquires nothing, so it adds
// no state to a target whose rule is that it holds no fan state and never re-acquires a lease.
// What the caller does about a loss is the caller's; ADR 0007's answer is that it never asks for
// the fans again on its own.
//
// Nothing here crosses the wire. No `@objc`, no DTO, no payload field: `AeolusXPCVersion` does not
// move for it.

/// Why a snapshot says a lease is no longer proof of control.
///
/// Every case is something the helper reported, in its own words. None of them is a guess from
/// `FanState.mode` (see `SystemSnapshot.controlLoss(leaseID:covering:)`).
public enum ControlLoss: Sendable, Hashable {
    /// The snapshot does not list the caller's lease. `listed` is the lease it lists instead,
    /// another client's, or `nil` when it lists none.
    ///
    /// **`listed.holderDescription` is another client's text**, chosen by that client and stored
    /// by the helper. A caller that renders it removes what its medium cannot show safely, as
    /// `fanctl` does with `DisplayText.sanitised(_:)`. It is carried verbatim here because what is
    /// safe to show depends on where it is shown.
    case leaseNotListed(listed: Lease?)
    /// The helper reports a thermal emergency. Its override outranks manual control, so the
    /// helper's thermal protection, not the lease, decides what the fans do.
    case thermalEmergency
    /// The snapshot no longer reports a fan the lease covers, so nothing says it is held.
    case fanNotReported(fan: Int)
    /// The helper reports a fan the lease covers as reclaimed by the system
    /// (`FanState.isReclaimedBySystem`).
    case reclaimedBySystem(fan: Int)
    /// The snapshot lists the lease and states **no held target** for a fan it covers: the
    /// helper does not say the fan is held.
    case fanNotHeld(fan: Int)
}

extension SystemSnapshot {

    /// Whether this snapshot says the lease `leaseID` is no longer proof of control over the fans
    /// it covers, and if so why. `nil` means the snapshot is evidence that every covered fan is
    /// held under that lease; it is the one judgement behind saying "holding" at all.
    ///
    /// **In this order**, and the first that applies is the answer:
    ///
    /// 1. The lease is not listed, or a different one is. First, because the lease is the proof
    ///    of control: until the snapshot lists the caller's lease, nothing else in it is about
    ///    the caller's control, and this is the only answer that can say which lease the helper
    ///    lists instead.
    /// 2. A thermal emergency is active. Its override outranks a lease the helper still lists.
    /// 3. For each covered fan, in the order given: it is not reported at all, it is reclaimed by
    ///    the system, or it carries **no held target**. Reclamation is named before the missing
    ///    target because a reclaimed fan states none either, and reclamation is the more
    ///    specific thing to say about it.
    ///
    /// **The held target is the evidence that a fan is held.** `FanState.targetRPM` is non-nil
    /// only while the same snapshot shows the fan in manual under the live lease, with no
    /// reclamation and no thermal override (#426). A fan beside a listed lease that carries none,
    /// because the firmware took it back and the reclamation watchdog has not marked it yet, is
    /// not held. A target that is not positive is no target: nothing is ever held at 0 RPM.
    ///
    /// **`mode` is not read.** The helper reports an unreadable `F<n>Md` as `automatic`
    /// ([#178](https://github.com/blamechris/Aeolus/issues/178)), so a fan that reads automatic
    /// beside a listed lease is as often an unread register as anything else, and a fan that
    /// reads manual with no held target is not held. The held target already says what the mode
    /// could not.
    ///
    /// Fans the lease does not cover are not its business: another fan reclaimed is not this
    /// lease's loss. An empty `covered` therefore judges only the lease and the emergency.
    ///
    /// - Parameters:
    ///   - leaseID: The lease the caller was granted. Compared by identity, never by holder: a
    ///     lease with the caller's holder string and another identifier is someone else's.
    ///   - covered: The fans that lease covers.
    /// - Returns: Why the lease is no longer proof of control, or `nil` when this snapshot shows
    ///   every covered fan held under it.
    public func controlLoss(leaseID: UUID, covering covered: [Int]) -> ControlLoss? {
        guard let listed = activeLease, listed.id == leaseID else {
            return .leaseNotListed(listed: activeLease)
        }
        if isThermalEmergencyActive { return .thermalEmergency }
        for index in covered {
            guard let fan = fans.first(where: { $0.index == index }) else {
                return .fanNotReported(fan: index)
            }
            if fan.isReclaimedBySystem { return .reclaimedBySystem(fan: index) }
            guard let held = fan.targetRPM, held > 0 else { return .fanNotHeld(fan: index) }
        }
        return nil
    }
}
