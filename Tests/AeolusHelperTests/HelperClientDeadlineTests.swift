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

    /// **No test harness imposes a deadline tighter than the product's.**
    ///
    /// This is the invariant [#250](https://github.com/blamechris/Aeolus/issues/250) was the
    /// absence of. `ClientListenerHarness.client()` defaulted all three verbs to
    /// `.milliseconds(750)`, and `EmptyReplyListenerHarness` carried its own copy of the same
    /// triple. Eighteen tests across `HelperClientTests` and `HelperClientConnectionTests`
    /// take that default and **none of them asserts a deadline**: they assert that a fault
    /// round-trips as itself, that a version mismatch carries both ranges, that a refusal is
    /// named. On a contended GitHub runner a cold anonymous-listener round trip exceeds
    /// 750 ms, so all eighteen failed at once, every one of them reporting
    /// `helperNeverAnswered(after: 0.75 seconds)` in place of the value it expected. One
    /// shared constant is what made a block of failures at an identical bound look like a
    /// shared teardown race.
    ///
    /// A deadline is the product's statement about how long a *user* waits. A harness that
    /// tightens it is not testing the product; it is testing the runner, and it fails on a
    /// slow one while the client under it is behaving correctly. So the relation is asserted
    /// rather than the number: a harness default may be looser than the shipping deadline —
    /// tolerating a slower machine is never the defect — and never tighter. A test that
    /// genuinely wants expiry passes its own, explicitly, at its own call site, which is
    /// where a reader can see that the short bound *is* the assertion;
    /// `HelperClientTests.theHandshakeIsSentWithinItsOwnDeadline` and
    /// `aMessageNobodyAnswersHasItsOwnError` are both that shape already, and always were.
    ///
    /// **Mutation:** set `ClientListenerHarness.defaultDeadlines` back to
    /// `HelperClientDeadlines(gatedVerb: .milliseconds(750), panicVerb: .milliseconds(750),
    /// handshakeVerb: .milliseconds(750))`. Run: red on all three expectations, each naming
    /// the harness bound and the shipping one it undercuts.
    @Test("No harness imposes a tighter deadline than the product")
    func noHarnessImposesATighterDeadlineThanTheProduct() {
        let harnessDeadlines = ClientListenerHarness.defaultDeadlines
        let shipping = HelperClientDeadlines.default

        #expect(
            harnessDeadlines.gatedVerb >= shipping.gatedVerb,
            """
            the harness allows a gated verb \(harnessDeadlines.gatedVerb) where the product \
            allows \(shipping.gatedVerb). Every test taking this default asserts something \
            other than a deadline, so a bound below the product's can only fail them on a \
            slow machine — #250.
            """)
        #expect(
            harnessDeadlines.panicVerb >= shipping.panicVerb,
            """
            the harness allows the panic path \(harnessDeadlines.panicVerb) where the product \
            allows \(shipping.panicVerb).
            """)
        #expect(
            harnessDeadlines.handshakeVerb >= shipping.handshakeVerb,
            """
            the harness allows a handshake \(harnessDeadlines.handshakeVerb) where the \
            product allows \(shipping.handshakeVerb) — which is \
            `reconciliationBudget + spawnAllowance + gatedVerb`, the whole of the helper's \
            cold start. A harness that undercuts it is asserting that the runner is fast, not \
            that the client is correct.
            """)
    }
}
