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
    ///
    /// `garblingHandshakeReplies` answers `hello` through the **real** session — so the
    /// helper records the handshake, and refuses every later `hello` on that connection —
    /// but replaces the reply payload with bytes no client can decode. It is the only way to
    /// reach a peer that has negotiated and a client that does not know it, which is the
    /// state a permanently wedged connection starts from.
    ///
    /// `holdingHandshakeReplies` withholds each `hello` reply until that signal fires. The
    /// message still reaches the real session, so the arrival is recorded and the handshake
    /// is negotiated; only the answer waits. It is what makes "a second verb arrived while
    /// the handshake was still unanswered" a *constructed* state rather than a raced one.
    init(
        authority: any FanAuthority,
        helperRange: ProtocolVersionRange = AeolusXPCVersion.supportedRange,
        capabilities: [String] = HelperListenerDelegate.advertisedCapabilities,
        garblingHandshakeReplies: Bool = false,
        holdingHandshakeReplies: AsyncSignal? = nil
    ) {
        delegate = ClientListenerDelegate(
            authority: authority,
            helperRange: helperRange,
            capabilities: capabilities,
            garblingHandshakeReplies: garblingHandshakeReplies,
            holdingHandshakeReplies: holdingHandshakeReplies
        )
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
    }

    /// **Measured, because #250 turned on it.** `NSXPCListenerEndpoint` does not retain the
    /// listener, so ARC is *permitted* to release a harness whose last use is the
    /// `client()` line and leave that client talking to a listener this `deinit` has already
    /// invalidated — the reading [#239](https://github.com/blamechris/Aeolus/issues/239)
    /// raises and the one #250 was filed expecting.
    ///
    /// **It did not happen on the development machine, in either configuration CI builds —
    /// which is not the same statement as "it does not happen on CI", and the difference is
    /// the point.** Instrumenting this `deinit` and `shouldAcceptNewConnection`, every test in
    /// `HelperClientTests` and `HelperClientConnectionTests` — the ones #250 lists among its
    /// failures included — logs the connection attempt **before** the harness deinitialises,
    /// under `swift test` and under `swift test -c release -Xswiftc -enable-testing` alike.
    /// Both of those are configurations CI builds; the machine was `Mac16,5` / macOS 26.6.2 /
    /// Swift 6.2, and **the runner's own toolchain was never probed.** These are `async`
    /// functions and the locals live in the async frame, so release lands at frame exit rather
    /// than at last use — an optimiser's liberty, not a language guarantee, and the optimiser
    /// measured was not the runner's.
    ///
    /// So this settles one thing and not another. It is enough to say that #250's block of
    /// `helperNeverAnswered(after: 0.75 seconds)` was a shared constant rather than a dead
    /// listener: a dead listener cannot fail eighteen tests at *precisely* the bound the
    /// constant names, and driving this constant far enough down to expire on *this* machine
    /// reproduces #250's shape — the same two suites, every failure
    /// `helperNeverAnswered(after: …)`, including the derived-state ones (`health == .refused`,
    /// `health == .versionMismatched`). **Matched by assertion, not by line number**: 750 ms
    /// does not expire on a quiet `Mac16,5` at all, which is the whole point of #250, so the
    /// reproduction runs at `.nanoseconds(1)`, and the line numbers in #250's list are from a
    /// tree several comment inserts ago.
    ///
    /// It was not enough to retire #239, and the portable guard is the one the tests that care
    /// now use at both sites: pin the harness past the last call by asserting the **precondition**
    /// it can observe. `sessions.isEmpty` in `aRefusingHelperIsPromptAndNamesBothPossibilities`
    /// is the pattern, and `EmptyReplyListenerHarness.acceptedConnections` — read by
    /// `HelperClientTests.emptyReplyIsAProtocolViolation` — is the other, that harness having had
    /// nothing observable to read until #239 was closed. Both hold whatever ARC is permitted to
    /// do, which is why they are the answer rather than another measurement of this toolchain.
    ///
    /// `withExtendedLifetime` is not an alternative at either site: its closure is not `async`
    /// and the bodies that need extending over are.
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

    /// The deadlines a client gets when the test does not name its own: **the shipping
    /// trio**, not a tighter one.
    ///
    /// This was `.milliseconds(750)` on all three verbs, and
    /// [#250](https://github.com/blamechris/Aeolus/issues/250) is what that cost. The
    /// justification written here was that "two of these tests assert on the deadline
    /// expiring, and five seconds of a suite's wall clock to observe a constant is a cost
    /// with no assertion in it" — which is true, and is an argument for those two tests
    /// passing their own deadline, which both of them already do. It is not an argument for
    /// the *default*, and as a default it protected nothing while making a 750 ms bound
    /// load-bearing for eighteen tests that never intended to measure a deadline.
    ///
    /// On a contended GitHub runner a cold anonymous-listener round trip exceeds 750 ms, and
    /// because all eighteen shared this one constant they failed **together, at the identical
    /// bound** — which read as a teardown race and was not one. A test that asserts a fault
    /// round-trips has no business failing because a round trip was slow.
    ///
    /// So the default is `HelperClientDeadlines.default`: the numbers the product ships, the
    /// handshake's derived from the helper's own reconciliation budget by
    /// `HelperClientDeadlines.reconciliationBudget`. That is the only bound whose expiry is a
    /// real defect rather than an artefact of the machine the suite is running on — a client
    /// that cannot get an answer inside it is broken for a user too.
    ///
    /// **What holds this value there, and exactly how far that reaches.**
    /// `HelperClientDeadlineTests.noHarnessDefaultImposesATighterDeadlineThanTheProduct`
    /// requires this constant to **equal** the shipping trio, and `FanctlResetTests.unhurried`
    /// to be no tighter than it. Those two are every *default* in the test target, so no test
    /// inherits a bound tighter than the product's without that test going red.
    ///
    /// It still says nothing about a deadline a test passes **explicitly** at its call site —
    /// eleven constructions do — but that half is no longer uncovered either.
    /// [#255](https://github.com/blamechris/Aeolus/issues/255) settled it with a source scan:
    /// `HelperClientDeadlineLiteralTests` requires every term of every such construction under
    /// `Tests/` to resolve to a bound no tighter than the product's, or to be licensed by name
    /// with what asserts it. The **eight** terms that were below the product's bound on a verb
    /// their test does not assert are gone rather than documented: all six of
    /// `HelperClientTeardownTests`' handshake and panic terms, plus two panic terms in
    /// `HelperClientTests`. Not the "five" this paragraph counted before the scan existed, which
    /// is itself the argument for the scan.
    ///
    /// Because this constant is *defined* as the product's trio, the comparison is a value
    /// against itself: it is a source tripwire that fires when a literal is written back in, not
    /// a runtime check, and it is blind to tightening `HelperClientDeadlines` itself. The
    /// absolute floor comes from two other tests —
    /// `HelperClientDeadlineTests.aPeerASecondSlowToAnswerHelloStillRoundTrips` and
    /// `aPeerASecondSlowToAnswerAGatedVerbStillRoundTrips` hold a message for a second and
    /// require the round trip to survive it — which redden whichever side moved.
    ///
    /// It costs nothing on a healthy run: everything here answers in milliseconds and never
    /// reaches the deadline at all. It costs the shipping deadline on a *failing* run, which
    /// is a slower red and still a red — the suite's `.timeLimit` bounds it either way.
    static let defaultDeadlines = HelperClientDeadlines.default

    /// A client wired to this harness, with no requirement.
    func client(
        description: String = "test client",
        pinning: any HelperConnectionPinning = UnenforcedClientPinning(),
        deadlines: HelperClientDeadlines = ClientListenerHarness.defaultDeadlines
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
    private let garblingHandshakeReplies: Bool
    private let holdingHandshakeReplies: AsyncSignal?
    private let record = OrderRecord<String>()

    private let lock = NSLock()
    private var mintedSessions: [HelperConnectionSession] = []
    private var connections: [NSXPCConnection] = []
    private var admitting = true

    init(
        authority: any FanAuthority,
        helperRange: ProtocolVersionRange,
        capabilities: [String],
        garblingHandshakeReplies: Bool,
        holdingHandshakeReplies: AsyncSignal?
    ) {
        self.authority = authority
        self.helperRange = helperRange
        self.capabilities = capabilities
        self.garblingHandshakeReplies = garblingHandshakeReplies
        self.holdingHandshakeReplies = holdingHandshakeReplies
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
            wrapping: HelperXPCService(session: session),
            record: record,
            garblingHandshakeReplies: garblingHandshakeReplies,
            holdingHandshakeReplies: holdingHandshakeReplies)
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
    private let garblingHandshakeReplies: Bool
    private let holdingHandshakeReplies: AsyncSignal?

    init(
        wrapping service: HelperXPCService,
        record: OrderRecord<String>,
        garblingHandshakeReplies: Bool = false,
        holdingHandshakeReplies: AsyncSignal? = nil
    ) {
        self.service = service
        self.record = record
        self.garblingHandshakeReplies = garblingHandshakeReplies
        self.holdingHandshakeReplies = holdingHandshakeReplies
    }

    private func replied(_ message: String) { record.append("\(message)→replied") }

    func hello(request: Data, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        record.append("hello")
        service.hello(request: request) { [self] data, error in
            // The real session has already recorded the handshake by the time this runs —
            // that is the whole point, and it is why only the payload is replaced.
            let payload =
                garblingHandshakeReplies && error == nil
                ? Data("not a HelloReply".utf8) : data

            // The reply marker is recorded where the reply actually leaves, not where it was
            // computed, so a withheld handshake reads as withheld in `arrivals`.
            guard let gate = holdingHandshakeReplies else {
                replied("hello")
                reply(payload, error)
                return
            }
            Task { [self] in
                try? await gate.wait()
                replied("hello")
                reply(payload, error)
            }
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
