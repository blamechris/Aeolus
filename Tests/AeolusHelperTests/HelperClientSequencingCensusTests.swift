import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// Which messages the client counts as sequenced, and which message each of its sends says it is
/// ([#413](https://github.com/blamechris/Aeolus/issues/413)).
///
/// A sequenced message's deadline starts at its turn (`InFlightMessages`), so two facts decide
/// every deadline in the client: which messages are on `HelperMessage.sequenced`, and which
/// message each send names at its gate. Both are claims about source that no single round trip
/// can check, so both are checked here.
@Suite("What the XPC client counts as sequenced")
struct HelperClientSequencingCensusTests {

    /// **The client's sequenced list is the helper's own.**
    ///
    /// The helper has no list to import. Its membership is which of `HelperXPCService`'s seven
    /// methods hands its message to `MessageSequencer`, so this reads the membership the way
    /// `LeaseHeartbeatStarvationTests.theSequencedVerbsAreTheOnesAClientPipelines` reads it,
    /// through the same `helperRoutes()`, and requires the client's copy to match both routes.
    /// That test pins the helper's routes to the four and the three; this one holds the client to
    /// whatever they are, so moving a verb between routes on the helper's side fails here until
    /// the client moves it too. Both modules are imported, as
    /// `HelperClientDeadlineTests.theApplyDeadlineIsDerivedFromTheHelpersOwnBounds` imports both
    /// to hold `applyPerFan` to the helper's bounds.
    ///
    /// **Mutation:** drop `.acquireLease` from `HelperMessage.sequenced`. Run: red on both
    /// expectations, naming `acquireLease` on each side.
    @Test("The client's sequenced list is the helper's own")
    func theClientsSequencedListIsTheHelpersOwn() throws {
        let helper = try LeaseHeartbeatStarvationTests.helperRoutes()
        let clientSequenced = HelperMessage.allCases.filter(\.isSequenced).map(\.rawValue).sorted()
        let clientUnsequenced =
            HelperMessage.allCases.filter { !$0.isSequenced }.map(\.rawValue).sorted()

        #expect(
            helper.sequenced.count + helper.dispatched.count == HelperMessage.allCases.count,
            """
            the helper's routes name \(helper.sequenced.count + helper.dispatched.count) verbs and \
            the protocol has \(HelperMessage.allCases.count). A scan that found fewer is a scan \
            that stopped reading a route, and the two comparisons below would agree over less.
            """)
        #expect(
            clientSequenced == helper.sequenced,
            """
            the client counts \(clientSequenced) as sequenced and the helper sequences \
            \(helper.sequenced). A sequenced message the client does not count starts its \
            deadline at its send and is cut off behind a lawful `apply`, which ends the lease \
            (#413); one it counts that the helper does not waits for a turn nothing is taking.
            """)
        #expect(
            clientUnsequenced == helper.dispatched,
            """
            the client starts \(clientUnsequenced) at their send and the helper dispatches \
            \(helper.dispatched) at once. These are the unlocks — the panic path and the two \
            lease verbs (#229) — and a deadline that waits behind the queue is a heartbeat that \
            reports a lapsed lease late.
            """)
    }

    /// One gate call, as written: the message it names, the rest of its arguments, and the
    /// message its closure sends.
    private struct GateCall: Equatable {
        let gate: String
        let named: String
        let arguments: String
        let sent: String
    }

    /// Every gate call in the client, read whole: the message it names, its arguments, and the
    /// message its trailing closure sends.
    ///
    /// Over comment-stripped, whitespace-collapsed source, so the formatter's line breaks are not
    /// part of the pattern. The three gates are `withHandshakenProxy`, `withProxy`, and the
    /// handshake's own `exchange`. Each call's argument list is read to its matching `)`, so an
    /// argument that is itself a closure, `within: { … }`, is read rather than ending the list.
    /// The two gates pass their own `message` parameter on to `exchange`; `forwarding` counts
    /// those, and any other call that does not name its message with a literal is `unreadable`,
    /// so a send that names its message some other way is reported rather than skipped.
    private static func gateCalls() throws -> GateCensus {
        let code = try HelperClientSources.all()
            .map { SeamScanner.collapsingWhitespace($0.code) }
            .joined(separator: " ")
        let gate = try NSRegularExpression(
            pattern: #"(?<!func )\b(withHandshakenProxy|withProxy|exchange)\("#)
        let closure = try NSRegularExpression(
            pattern: #"^ ?\{ ?proxy, resolve in proxy\.([A-Za-z]+)"#)
        var census = GateCensus()

        for match in gate.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let whole = Range(match.range, in: code),
                let name = Range(match.range(at: 1), in: code),
                let close = closingParenthesis(in: code, after: whole.upperBound)
            else {
                census.unreadable.append("a gate call at offset \(match.range.location)")
                continue
            }
            let arguments = code[whole.upperBound..<close].trimmingCharacters(in: .whitespaces)
            if arguments.hasPrefix("message,") {
                census.forwarding += 1
                continue
            }
            let tag =
                arguments.hasPrefix(".")
                ? String(arguments.dropFirst().prefix { $0.isLetter }) : ""
            let rest = String(code[code.index(after: close)...].prefix(200))
            let sent = closure.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest))
                .flatMap { Range($0.range(at: 1), in: rest) }
                .map { String(rest[$0]) }
            guard !tag.isEmpty, let sent else {
                census.unreadable.append("\(code[name])(\(arguments)) \(rest.prefix(60))")
                continue
            }
            census.calls.append(
                GateCall(
                    gate: String(code[name]), named: tag,
                    arguments: String(arguments.dropFirst(tag.count + 1)), sent: sent))
        }
        return census
    }

    /// The `)` that closes the argument list opened just before `start`, at its own depth.
    private static func closingParenthesis(
        in code: String, after start: String.Index
    ) -> String.Index? {
        var depth = 1
        var index = start
        while index < code.endIndex {
            switch code[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// What `gateCalls()` found: the calls it could read, the calls that forward a gate's own
    /// `message`, and the calls it could not read.
    private struct GateCensus {
        var calls: [GateCall] = []
        var forwarding = 0
        var unreadable: [String] = []
    }

    /// **Every send names the message it sends, and each of the seven is named once.**
    ///
    /// The tag is what decides a send's deadline, and the gate cannot check it: it is handed a
    /// closure, not a message. `acquireLease` tagged `.renewLease` would start its deadline at its
    /// send and be cut off behind a lawful `apply`, with every behavioural test in the package
    /// green, because each of them sends a different verb.
    ///
    /// **Mutation:** in `HelperClient.acquireLease(_:)`, tag the gate `.renewLease`. Run: red on
    /// the mismatch, naming the call, and on the census, `renewLease` twice and `acquireLease`
    /// never.
    @Test("Every send names the message it sends")
    func everySendNamesTheMessageItSends() throws {
        let census = try Self.gateCalls()
        let calls = census.calls

        #expect(
            census.unreadable.isEmpty,
            """
            \(census.unreadable) name their message some other way than a literal at the gate. A \
            name this census cannot read is a deadline nobody checked.
            """)
        #expect(
            census.forwarding == 2,
            "\(census.forwarding) calls forward a message; the two gates are the two")

        let mismatched = calls.filter { $0.named != $0.sent }
        #expect(
            mismatched.isEmpty,
            """
            \(mismatched.map { "\($0.gate)(.\($0.named)…) sends \($0.sent)" }) — the message a \
            send names decides when its deadline starts, so a wrong name is a wrong deadline.
            """)
        #expect(
            calls.map(\.named).sorted() == HelperMessage.allCases.map(\.rawValue).sorted(),
            """
            the sends name \(calls.map(\.named).sorted()). Each of the protocol's seven messages \
            is sent from exactly one place in the client.
            """)
    }

    /// **`apply` alone chooses its own deadline** ([#415](https://github.com/blamechris/Aeolus/issues/415)).
    ///
    /// `withHandshakenProxy` lets any verb pass `within:`, and nothing else checks that only
    /// `apply` does. A heartbeat given `apply`'s 57 s against a wedged helper outlives the 30 s
    /// TTL it is renewing, so the client keeps reporting a lease that has lapsed (rule 6) and
    /// `fanctl`'s "control lost" arrives about 52 s late. The handshake's `exchange` names its own
    /// deadline too, and is left out: it is the handshake's, not a verb's.
    ///
    /// **Mutation:** in `HelperClient.renewLease(id:)`, pass `within: { $0.gatedVerb +
    /// $0.applyPerFan }`. Run: red, naming `renewLease` beside `apply`.
    @Test("apply alone chooses its own deadline")
    func applyAloneChoosesItsOwnDeadline() throws {
        let choosing = try Self.gateCalls().calls
            .filter { $0.gate == "withHandshakenProxy" && $0.arguments.contains("within:") }
            .map(\.named)

        #expect(
            choosing == ["apply"],
            """
            \(choosing) choose their own deadline. Only `apply` may: it is the one gated verb \
            whose lawful wait grows with what it names, and every other verb's bound is \
            `gatedVerb`.
            """)
    }
}
