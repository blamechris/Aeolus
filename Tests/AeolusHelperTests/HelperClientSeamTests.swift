import Foundation
import Testing

/// The client's structural claims — the ones with nothing to observe at runtime, asserted
/// against the source tree instead.
///
/// A source tripwire is this repository's last resort, and each one below says why the
/// behavioural test it would rather be does not exist. All three are about **absence**: a
/// second caller, a second conformer, a second way of taking the proxy. Absence is what no
/// green run can demonstrate, because the thing that would fail is the thing nobody wrote
/// yet.
@Suite("What the XPC client's sources must and must not contain")
struct HelperClientSeamTests {

    private static let target = "AeolusXPCClient"

    private static func sources() throws -> [(file: String, code: String)] {
        try SeamScanner.swiftFiles(under: target).map {
            (
                file: $0.lastPathComponent,
                code: SeamScanner.strippingComments(try String(contentsOf: $0, encoding: .utf8))
            )
        }
    }

    /// `restoreAllToAutomatic` is the only verb that reaches a proxy without a handshake,
    /// and the count is what keeps it so.
    ///
    /// Two occurrences of the name: the declaration, and the one call. A behavioural test
    /// can show that *today's* verbs handshake — `helloRunsOncePerConnection` and
    /// `thePanicPathNeedsNoHandshake` between them do — but it cannot fail for a verb added
    /// next year, and the whole point of the gate is that exempting yourself from it is not
    /// a decision an author gets to take quietly.
    ///
    /// The bare name rather than the name with its opening parenthesis, because the one
    /// call site passes a trailing closure and so is not followed by one at all — a detail
    /// that made the first version of this tripwire fire on a correct tree.
    /// `withHandshakenProxy` does not contain this name, so the two gates cannot be
    /// confused for one another.
    ///
    /// **Mutations, one per direction.** Route `restoreAllToAutomatic` through
    /// `withHandshakenProxy` instead: red at one. Route `releaseLease` — a gated verb —
    /// through the unhandshaken gate: red at three. The second is the one no behavioural
    /// test in this suite catches, because every test that calls `releaseLease` has already
    /// handshaken on that connection for an earlier verb; a verb added next year that is
    /// *only* ever called first would not even have that.
    @Test("The unhandshaken proxy has exactly one caller")
    func theUnhandshakenProxyHasExactlyOneCaller() throws {
        var found: [String] = []
        for source in try Self.sources() {
            let occurrences = source.code.components(separatedBy: "withProxy").count - 1
            found.append(contentsOf: Array(repeating: source.file, count: occurrences))
        }

        #expect(
            found.count == 2,
            """
            the unhandshaken gate is named \(found.count) times in Sources/\(Self.target) \
            (\(found.sorted())). Exactly two are correct: the declaration, and \
            `restoreAllToAutomatic`'s single call. Anything else is a verb exempting itself \
            from the handshake gate on the client's side of a boundary whose design is that \
            gates are not optional.
            """)
    }

    /// Exactly one thing in `Sources` can acquire a connection's code-signing requirement,
    /// and it is the one that pins the helper.
    ///
    /// The suite drives the client through a policy that applies no requirement at all,
    /// declared in the test target where production code cannot name it. That arrangement is
    /// only worth anything while `Sources` has no equivalent: a "no requirement" conformer
    /// living beside the real one would be one mis-wired initialiser away from a client that
    /// talks to whoever answered, and every test here would stay green.
    ///
    /// This is the client-side mirror of `ConnectionAdmission`'s own rule, and it is checked
    /// rather than documented because #72's review found the documented version of the same
    /// claim in three files while the diff did not stand behind it.
    ///
    /// **Mutation:** add `struct UnpinnedConnection: HelperConnectionPinning { … }` anywhere
    /// under `Sources`. Run: red.
    @Test("Exactly one connection-pinning policy ships in Sources")
    func exactlyOnePinningPolicyShipsInSources() throws {
        let conformers = try SeamScanner.declarations(
            matching: #"(?:struct|final class|class|actor|enum|extension)\s+\w+\s*:"#
                + #"[^{\n]*\bHelperConnectionPinning\b"#)

        #expect(
            conformers.map(\.text) == ["struct SignedHelperPinning: HelperConnectionPinning"],
            """
            Sources declares \(conformers.map(\.text)). Exactly one conformer may ship, and \
            it is the one that derives, compiles and applies the requirement. A conformer \
            that skipped it would leave every test in this target green while the client \
            trusted whoever answered the mach name.
            """)
    }

    /// The proxy is never taken without an error handler.
    ///
    /// `AeolusXPCProtocol` is explicit that a dropped reply block is the failure case that
    /// matters most: when the connection fails, the block passed with the message is simply
    /// dropped and only the error handler runs. A client that took a bare
    /// `remoteObjectProxy` would have no failure path for exactly that case, and its symptom
    /// is a caller that waits rather than a caller that is told.
    ///
    /// Counted rather than pattern-matched for absence, because
    /// `remoteObjectProxyWithErrorHandler` *contains* the forbidden spelling: the assertion
    /// is that the two counts are equal, so every occurrence of the shorter name is part of
    /// a longer one.
    ///
    /// **Mutation:** change one `remoteObjectProxyWithErrorHandler` to `remoteObjectProxy`.
    /// Run: red — and `aMessageInFlightWhenTheHelperDiesIsARestart` goes red with it, which
    /// is the behavioural half.
    @Test("Every proxy in the client carries an error handler")
    func everyProxyCarriesAnErrorHandler() throws {
        var bare = 0
        var handled = 0
        for source in try Self.sources() {
            bare += source.code.components(separatedBy: "remoteObjectProxy").count - 1
            handled +=
                source.code.components(separatedBy: "remoteObjectProxyWithErrorHandler").count - 1
        }

        #expect(handled > 0, "the client takes no proxy at all")
        #expect(
            bare == handled,
            """
            \(bare - handled) bare `remoteObjectProxy` use(s) in Sources/\(Self.target). When \
            the connection fails, the reply block is dropped and only the error handler runs \
            — a client without one has no failure path for the case that matters most.
            """)
    }
}
