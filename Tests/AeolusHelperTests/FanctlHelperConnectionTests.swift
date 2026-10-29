import Foundation
import Testing

@testable import AeolusXPCClient
@testable import fanctl

/// `HelperConnection`'s client maker ([#583](https://github.com/blamechris/Aeolus/issues/583)):
/// the one member a suite can substitute that is not where to look, who may answer or how long to
/// wait, so what it is handed is held to those three and the name `fanctl` logs itself under.
///
/// The maker is how the in-process `fanctl` suites count a command's deadlines on a clock only
/// they move. `FanctlAutoClearanceTests` is what shows the clock reaching the client; this is what
/// shows the connection handing the maker nothing but its own parts, so a suite that substitutes
/// the clock cannot also have substituted the deadline, the pinning or the endpoint the command
/// chose.
@Suite("fanctl's helper connection makes its client from its own parts")
struct FanctlHelperConnectionTests {

    /// What a maker was called with.
    private struct Made: @unchecked Sendable {
        let endpoint: NSXPCListenerEndpoint?
        let pinning: any HelperConnectionPinning
        let description: String
        let deadlines: HelperClientDeadlines
    }

    /// `client()` calls the maker, once, with the connection's transport, pinning and deadlines
    /// and the name every `fanctl` command logs itself under, and returns what it made.
    ///
    /// **Mutation:** in `HelperConnection.client()`, call `Self.shippingClient` instead of
    /// `makeClient`. Run: red, the maker was never called.
    /// **Mutation:** in the same function, pass `.default` for `deadlines`. Run: red on the
    /// deadlines.
    @Test("client() hands the maker the connection's parts and returns what it made")
    func clientHandsTheMakerTheConnectionsParts() throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        // Once: the harness makes a new endpoint object each time it is asked for one.
        let endpoint = harness.endpoint
        let deadlines = HelperClientDeadlines(
            gatedVerb: .seconds(11), panicVerb: .seconds(12),
            handshakeVerb: HelperClientDeadlines.handshakeVerb)
        let calls = Calls()
        let made = HelperClient(
            transport: .endpoint(endpoint),
            pinning: UnenforcedClientPinning(),
            clientDescription: "the maker's",
            deadlines: deadlines)
        let connection = HelperConnection(
            transport: .endpoint(endpoint),
            pinning: UnenforcedClientPinning(),
            deadlines: deadlines,
            makeClient: { transport, pinning, description, deadlines in
                var endpoint: NSXPCListenerEndpoint?
                if case .endpoint(let given) = transport { endpoint = given }
                calls.record(
                    Made(
                        endpoint: endpoint, pinning: pinning, description: description,
                        deadlines: deadlines))
                return made
            })

        let client = connection.client()

        let recorded = calls.all
        #expect(recorded.count == 1, "the maker was called \(recorded.count) times")
        let call = try #require(recorded.first)
        #expect(call.endpoint === endpoint)
        #expect(call.pinning is UnenforcedClientPinning)
        #expect(call.description == HelperConnection.clientDescription)
        #expect(call.deadlines == deadlines)
        #expect(client === made, "client() returned something other than what the maker made")
    }

    /// What the maker saw, behind a lock: it is `@Sendable` and runs on whatever calls `client()`.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [Made] = []

        func record(_ call: Made) {
            lock.lock()
            made.append(call)
            lock.unlock()
        }

        var all: [Made] {
            lock.lock()
            defer { lock.unlock() }
            return made
        }
    }
}
