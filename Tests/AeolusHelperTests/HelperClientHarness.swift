import AeolusXPC
import FanKit
import Foundation
import Security

@testable import AeolusHelper
@testable import AeolusXPCClient

/// A real `NSXPCListener` with the helper's real `HelperConnectionSession` behind it, whose
/// sessions the test can read and whose admission it can flip.
///
/// **It mirrors `HelperListenerDelegate` and does not test it.** Three things the
/// production delegate deliberately does not expose are exactly what a client test needs:
/// the sessions it minted (so `messageCount` and `handshakeState` can be read back), a
/// helper protocol range other than this build's (so version mismatch is reachable in
/// *both* directions), and the server's own side of each connection (so the helper can be
/// made to die under a client that is mid-call). `AnonymousListenerTests` is what covers the
/// production delegate; nothing here should be read as covering it.
///
/// Not `Sendable` by inheritance from its delegate's lock, and not meant to be shared: one
/// test owns one harness for its duration.
final class ClientListenerHarness {

    let listener: NSXPCListener
    private let delegate: ClientListenerDelegate

    /// `NSXPCListener` holds its delegate weakly; without this it would deallocate
    /// immediately and every connection would arrive with nothing to configure it.
    init(
        authority: any FanAuthority,
        helperRange: ProtocolVersionRange = AeolusXPCVersion.supportedRange,
        capabilities: [String] = HelperListenerDelegate.advertisedCapabilities
    ) {
        delegate = ClientListenerDelegate(
            authority: authority,
            helperRange: helperRange,
            capabilities: capabilities
        )
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
    }

    deinit {
        delegate.invalidateConnections()
        listener.invalidate()
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    /// Every session this listener minted, oldest first. One per accepted connection.
    var sessions: [HelperConnectionSession] { delegate.sessions }

    /// Every message that reached an exported object, and every reply that left one, in the
    /// order libxpc delivered them. See `ArrivalRecordingService`.
    var arrivals: [String] { delegate.arrivals }

    /// Whether new connections are accepted. Flipping this to `false` is how a client meets
    /// a helper that refuses every connection — ADR 0005's fail-closed rows.
    var isAdmitting: Bool {
        get { delegate.isAdmitting }
        set { delegate.isAdmitting = newValue }
    }

    /// Kills the helper's side of every live connection, which is what a client observes as
    /// **interruption**: the connection object survives and libxpc reconnects it to a new
    /// session on the next message.
    ///
    /// Measured on `Mac16,5` / macOS 26.6.2 and reproduced on CI's older macOS: the client's
    /// `interruptionHandler` fires, a message in flight fails with `NSCocoaErrorDomain` 4097,
    /// and the next message on the same connection object reaches a freshly minted session.
    ///
    /// Killing the **listener** is deliberately not offered beside this. It looked like the
    /// way to reach the invalidation path and is not portable: on `Mac16,5` it interrupted
    /// and then invalidated the client's connection, and on CI it left that connection
    /// working. A test that has to assert one of those is a test that fails on a machine
    /// where the client is correct.
    func killHelperSideOfEveryConnection() {
        delegate.invalidateConnections()
    }

    /// A client wired to this harness, with no requirement and short deadlines.
    ///
    /// Short deadlines because two of these tests assert on the deadline expiring, and five
    /// seconds of a suite's wall clock to observe a constant is a cost with no assertion in
    /// it. Everything else here answers in milliseconds.
    func client(
        description: String = "test client",
        pinning: any HelperConnectionPinning = UnenforcedClientPinning(),
        deadlines: HelperClientDeadlines = HelperClientDeadlines(
            gatedVerb: .milliseconds(750), panicVerb: .milliseconds(750))
    ) -> HelperClient {
        HelperClient(
            transport: .endpoint(endpoint),
            pinning: pinning,
            clientDescription: description,
            deadlines: deadlines
        )
    }
}

/// The listener delegate `ClientListenerHarness` is built around. See that type.
private final class ClientListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    private let authority: any FanAuthority
    private let helperRange: ProtocolVersionRange
    private let capabilities: [String]
    private let record = OrderRecord<String>()

    private let lock = NSLock()
    private var mintedSessions: [HelperConnectionSession] = []
    private var connections: [NSXPCConnection] = []
    private var admitting = true

    init(
        authority: any FanAuthority,
        helperRange: ProtocolVersionRange,
        capabilities: [String]
    ) {
        self.authority = authority
        self.helperRange = helperRange
        self.capabilities = capabilities
    }

    var sessions: [HelperConnectionSession] {
        lock.lock()
        defer { lock.unlock() }
        return mintedSessions
    }

    var arrivals: [String] { record.entries }

    var isAdmitting: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return admitting
        }
        set {
            lock.lock()
            admitting = newValue
            lock.unlock()
        }
    }

    func invalidateConnections() {
        lock.lock()
        let live = connections
        connections = []
        lock.unlock()
        for connection in live { connection.invalidate() }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard isAdmitting else { return false }

        let session = HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperRange: helperRange,
            helperBuild: "test",
            capabilities: capabilities,
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "ClientTests")
        )
        connection.exportedInterface = NSXPCInterface(with: AeolusXPCProtocol.self)
        connection.exportedObject = ArrivalRecordingService(
            wrapping: HelperXPCService(session: session), record: record)
        connection.invalidationHandler = {
            Task.detached { await session.invalidate() }
        }
        connection.resume()

        lock.lock()
        mintedSessions.append(session)
        connections.append(connection)
        lock.unlock()
        return true
    }
}

/// Records when each message **arrived** at the exported object and when each reply left
/// it, then forwards to the real one.
///
/// This is the only place the client's send discipline is observable. libxpc invokes an
/// exported object synchronously, on delivery, and this sits *upstream* of
/// `HelperXPCService`'s sequencer — so what it records is the order the client's messages
/// reached the helper, before anything on the helper's side could reorder them.
///
/// The reply markers are what make it an assertion rather than a note. `hello` and a gated
/// verb arrive in the same order whether or not the client pipelined them; what differs is
/// where *`hello`'s reply* sits between the two. A client that waits records
/// `hello, hello→replied, snapshot`; a client that pipelines records
/// `hello, snapshot, hello→replied`.
private final class ArrivalRecordingService: NSObject, AeolusXPCProtocol, @unchecked Sendable {

    private let service: HelperXPCService
    private let record: OrderRecord<String>

    init(wrapping service: HelperXPCService, record: OrderRecord<String>) {
        self.service = service
        self.record = record
    }

    private func replied(_ message: String) { record.append("\(message)→replied") }

    func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        record.append("hello")
        service.hello(request: request) { [self] data, error in
            replied("hello")
            reply(data, error)
        }
    }

    func snapshot(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        record.append("snapshot")
        service.snapshot { [self] data, error in
            replied("snapshot")
            reply(data, error)
        }
    }

    func acquireLease(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        record.append("acquireLease")
        service.acquireLease(request: request) { [self] data, error in
            replied("acquireLease")
            reply(data, error)
        }
    }

    func renewLease(id: String, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        record.append("renewLease")
        service.renewLease(id: id) { [self] data, error in
            replied("renewLease")
            reply(data, error)
        }
    }

    func releaseLease(id: String, reply: @escaping @Sendable (Error?) -> Void) {
        record.append("releaseLease")
        service.releaseLease(id: id) { [self] error in
            replied("releaseLease")
            reply(error)
        }
    }

    func apply(settings: Data, leaseID: String, reply: @escaping @Sendable (Error?) -> Void) {
        record.append("apply")
        service.apply(settings: settings, leaseID: leaseID) { [self] error in
            replied("apply")
            reply(error)
        }
    }

    func restoreAllToAutomatic(reply: @escaping @Sendable (Error?) -> Void) {
        record.append("restoreAllToAutomatic")
        service.restoreAllToAutomatic { [self] error in
            replied("restoreAllToAutomatic")
            reply(error)
        }
    }
}
