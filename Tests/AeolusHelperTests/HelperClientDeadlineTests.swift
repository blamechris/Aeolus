import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// The client's deadlines, and the one of them that is derived rather than guessed.
@Suite("The XPC client's deadlines")
struct HelperClientDeadlineTests {

    /// The handshake deadline is the helper's own startup budget plus what comes before it,
    /// and the two constants cannot drift apart silently.
    ///
    /// `AeolusXPCClient` must not link the root daemon, so `ReconciliationLimits.budget`
    /// cannot be read where it is used — it is restated as
    /// `HelperClientDeadlines.reconciliationBudget`. A restated constant with nothing
    /// checking it is the defect class this repository keeps paying for; this test is what
    /// makes it a derivation instead. The test target imports both modules, which is the
    /// one place in the tree that can hold them to each other.
    ///
    /// **Mutation:** change `ReconciliationLimits.budget` to `.seconds(8)`, or
    /// `HelperClientDeadlines.reconciliationBudget` to `.seconds(3)`. Run: red on the first
    /// expectation, naming both values.
    @Test("The handshake deadline is derived from the helper's own startup budget")
    func theHandshakeDeadlineIsDerivedFromTheHelpersOwnBudget() {
        #expect(
            HelperClientDeadlines.reconciliationBudget == ReconciliationLimits.budget,
            """
            the client waits \(HelperClientDeadlines.reconciliationBudget) for a \
            reconciliation the helper budgets \(ReconciliationLimits.budget) for. One of \
            these moved without the other; the client's copy exists only because this target \
            may not link the daemon, and it is only honest while this holds.
            """)

        #expect(
            HelperClientDeadlines.handshakeVerb
                == ReconciliationLimits.budget
                + HelperClientDeadlines.spawnAllowance
                + HelperClientDeadlines.gatedVerb,
            "the handshake deadline is no longer the sum its own documentation states")
    }

    /// The handshake is allowed longer than a verb on a connection that already exists.
    ///
    /// The defect C1 named: `gatedVerb` was the handshake's deadline too, at exactly
    /// `ReconciliationLimits.budget` — the reconciliation *alone*, with nothing left for
    /// launchd's spawn, the authorisation file I/O or SMC enumeration in front of it. The
    /// ordinary cold-start path could therefore time out against a helper that was working.
    ///
    /// **Mutation:** in `HelperClient.performHandshake(generation:)`, send `hello` within
    /// `deadlines.gatedVerb` again. Run: this test stays green — it pins the constants, and
    /// `HelperClientTests.theHandshakeIsSentWithinItsOwnDeadline` pins the wiring.
    @Test("The handshake deadline is larger than a gated verb's")
    func theHandshakeDeadlineIsLargerThanAGatedVerbs() {
        #expect(HelperClientDeadlines.handshakeVerb > HelperClientDeadlines.gatedVerb)
        #expect(HelperClientDeadlines.default.handshakeVerb == HelperClientDeadlines.handshakeVerb)
    }
}
