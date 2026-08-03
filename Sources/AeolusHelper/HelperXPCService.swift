import AeolusXPC
import Foundation

/// The object `NSXPCConnection` vends to one client: seven methods, each of which does
/// nothing except hand the message to that connection's `HelperConnectionSession` and
/// deliver whatever comes back.
///
/// ## Deliberately empty of judgement
///
/// There is no state here, no validation, no branch that could refuse or admit anything.
/// Every method has the same three lines, and that uniformity is the point: this is the
/// one type in the helper that libxpc calls directly, on threads it owns, and a decision
/// taken here would be a decision taken outside the actor that serialises this
/// connection's state. Anything that looks like policy appearing in this file is a bug in
/// the layering, not a shortcut.
///
/// `Sendable` with only immutable, `Sendable` stored properties — permitted for a `final`
/// class whose superclass is `NSObject` — rather than an unchecked conformance, which
/// `CLAUDE.md` rule 10 and this repository's own SwiftLint rule both treat as a claim
/// requiring review. There is nothing here to race on.
///
/// ## Every reply block is called exactly once
///
/// `PayloadReply` and `AcknowledgementReply` are what make that structural: each has one
/// `deliver(to:)`, each `deliver(to:)` calls the block once on every path, and no method
/// here can reach a `return` without going through one. `AeolusXPCProtocol` calls
/// `(nil, nil)` a protocol violation rather than an empty success, and this is where that
/// is enforced rather than remembered.
final class HelperXPCService: NSObject, AeolusXPCProtocol, Sendable {

    private let session: HelperConnectionSession

    init(session: HelperConnectionSession) {
        self.session = session
    }

    func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task { [session] in await session.hello(payload: request).deliver(to: reply) }
    }

    func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task { [session] in await session.snapshot().deliver(to: reply) }
    }

    func acquireLease(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task { [session] in await session.acquireLease(payload: request).deliver(to: reply) }
    }

    func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task { [session] in await session.renewLease(id: id).deliver(to: reply) }
    }

    func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void) {
        Task { [session] in await session.releaseLease(id: id).deliver(to: reply) }
    }

    func apply(settings: Data, leaseID: String, reply: @escaping @Sendable (Error?) -> Void) {
        Task { [session] in
            await session.apply(settings: settings, leaseID: leaseID).deliver(to: reply)
        }
    }

    func restoreAllToAutomatic(reply: @escaping @Sendable (Error?) -> Void) {
        Task { [session] in await session.restoreAllToAutomatic().deliver(to: reply) }
    }
}
