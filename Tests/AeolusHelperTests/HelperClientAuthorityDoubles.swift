import AeolusXPC
import FanKit
import Foundation
import Security

@testable import AeolusHelper
@testable import AeolusXPCClient

/// A `FanAuthority` that answers every message with one chosen fault.
///
/// The vocabulary round-trip needs an authority that can raise *any* refusal, including one
/// this build does not recognise. `RecordingFanAuthority` answers with the single fault E2
/// can actually reach today, which is the right double for the helper's own tests and the
/// wrong one for asking whether the client loses anything on the way back.
actor FaultThrowingAuthority: FanAuthority {

    private let fault: AeolusXPCFault

    init(throwing fault: AeolusXPCFault) {
        self.fault = fault
    }

    func snapshot() async throws -> SystemSnapshot { throw fault }

    func acquireLease(
        _ request: LeaseRequest, from connection: ConnectionID
    ) async throws -> Lease {
        throw fault
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        throw fault
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws { throw fault }

    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        throw fault
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws { throw fault }

    func connectionDidInvalidate(_ connection: ConnectionID) async {}
}

/// A `FanAuthority` that grants whatever lease it is asked for, so the client's typed
/// wrappers can be exercised on their success path.
///
/// Nothing here writes to a fan and nothing pretends to: E5 owns the real authority, and
/// what these tests assert is that a DTO crosses the boundary and comes back equal — not
/// that manual control works.
actor LeaseGrantingAuthority: FanAuthority {

    private let lease: Lease
    private let snapshotGate: AsyncSignal?
    private(set) var applied: [FanSetting] = []
    private(set) var released: [UUID] = []

    /// Every connection this authority was told had died.
    ///
    /// This is the call that releases what a connection was holding, so it is where the
    /// consequence of a client tearing a connection down actually lands. A test that wants
    /// to assert a lease *survived* something asserts on this.
    private(set) var invalidatedConnections: [ConnectionID] = []

    /// Set before `snapshot` parks, so "the slow message has started" is observable rather
    /// than inferred from a sleep.
    private(set) var hasBeenAskedForSnapshot = false

    /// - Parameters:
    ///   - lease: the lease every `acquireLease` and `renewLease` answers with.
    ///   - snapshotGate: when given, `snapshot` parks on it — so a test can hold a gated
    ///     verb open on a connection whose lease it is watching.
    init(lease: Lease, snapshotGate: AsyncSignal? = nil) {
        self.lease = lease
        self.snapshotGate = snapshotGate
    }

    func snapshot() async throws -> SystemSnapshot {
        hasBeenAskedForSnapshot = true
        if let snapshotGate { try? await snapshotGate.wait() }
        return .empty
    }

    func acquireLease(
        _ request: LeaseRequest, from connection: ConnectionID
    ) async throws -> Lease {
        lease
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease { lease }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        released.append(id)
    }

    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        applied = settings
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws {}

    func connectionDidInvalidate(_ connection: ConnectionID) async {
        invalidatedConnections.append(connection)
    }
}

/// A peer that answers a payload message with **neither a payload nor a refusal**.
///
/// `AeolusXPCProtocol` calls `(nil, nil)` a protocol violation rather than an empty success,
/// and the helper cannot produce one — `PayloadReply` makes it unrepresentable on that side.
/// So the only way to put a client in front of that answer is a rogue exported object, which
/// is what this is. It is not a claim that the helper might do this; it is the contract's own
/// statement that a client may not assume the peer is well-behaved.
///
/// `hello` is answered properly, because the case under test is a *gated verb* answering
/// emptily and a client that never got past the handshake would never reach one.
final class EmptyReplyListenerHarness {

    let listener: NSXPCListener
    private let delegate: EmptyReplyListenerDelegate

    init() {
        delegate = EmptyReplyListenerDelegate()
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
    }

    deinit { listener.invalidate() }

    func client() -> HelperClient {
        HelperClient(
            transport: .endpoint(listener.endpoint),
            pinning: UnenforcedClientPinning(),
            clientDescription: "test client",
            deadlines: HelperClientDeadlines(
                gatedVerb: .milliseconds(750),
                panicVerb: .milliseconds(750),
                handshakeVerb: .milliseconds(750))
        )
    }
}

private final class EmptyReplyListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AeolusXPCProtocol.self)
        connection.exportedObject = EmptyReplyService()
        connection.resume()
        return true
    }
}

private final class EmptyReplyService: NSObject, AeolusXPCProtocol, Sendable {

    func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let helloReply = HelloReply(
            helperProtocolRange: AeolusXPCVersion.supportedRange,
            helperBuild: "rogue",
            capabilities: []
        )
        reply(try? AeolusXPCCoding.encoder().encode(helloReply), nil)
    }

    func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void) { reply(nil, nil) }

    func acquireLease(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        reply(nil, nil)
    }

    func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        reply(nil, nil)
    }

    func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }

    func apply(settings: Data, leaseID: String, reply: @escaping @Sendable (Error?) -> Void) {
        reply(nil)
    }

    func restoreAllToAutomatic(reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
}

/// A `FanAuthority` whose **panic path** parks until a signal fires.
///
/// The mirror image of `GatedSnapshotAuthority`, and it exists for a case that one cannot
/// reach: a helper that *accepted* `restoreAllToAutomatic` and never answered it. That is
/// `docs/SAFETY.md` § 4's wedged `io_connect_t` — the state the panic path is most likely to
/// meet, since a control plane that cannot talk to the SMC is exactly why a user is running
/// it — and it is the one outcome where neither "restored" nor "failed" is a statement
/// anything observed.
///
/// Parking the panic path parks nothing else: since D27 `HelperXPCService` dispatches it
/// outside the per-connection sequencer, so a message sent after it is unaffected.
actor GatedRestoreAuthority: FanAuthority {

    private let gate: AsyncSignal

    /// Set when the panic path has reached this authority — before it parks, so "the helper
    /// accepted it" is observable rather than inferred from a sleep.
    private(set) var hasBeenAsked = false

    init(gate: AsyncSignal) {
        self.gate = gate
    }

    func snapshot() async throws -> SystemSnapshot { .empty }

    func acquireLease(
        _ request: LeaseRequest, from connection: ConnectionID
    ) async throws -> Lease {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func apply(
        _ settings: [FanSetting], leaseID: UUID, from connection: ConnectionID
    ) async throws {
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        hasBeenAsked = true
        try? await gate.wait()
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {}
}
