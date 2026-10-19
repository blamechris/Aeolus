import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// The client's deadlines, and the one of them that is derived rather than guessed.
///
/// `.timeLimit` because the two slow-peer tests wait on a real round trip: a client whose
/// deadline was deleted outright hangs rather than fails, and a suite that hangs is worse than
/// one that goes red.
@Suite("The XPC client's deadlines", .timeLimit(.minutes(1)))
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

    /// `apply`'s per-fan figure is the helper's own bound on one fan's engagement, and the copy
    /// cannot drift from it silently.
    ///
    /// The handshake's shape, for its reason: `FanExaminationGate.examinationWait` and
    /// `WatchdogLimits.gateWaiterAlarm` are the root daemon's, so the client restates their sum as
    /// `HelperClientDeadlines.applyPerFan`, and only this target can hold the two to each other
    /// ([#325](https://github.com/blamechris/Aeolus/issues/325), ADR 0014's #410 amendment).
    ///
    /// - **The copy moves**, or never followed: the first expectation.
    /// - **The helper's bounds move**: the second, against the 52 s the figure's documentation,
    ///   ADR 0014 and the 57 s and 109 s below state. Without it, a change to G or `lawfulHold`
    ///   reddens only the first, which copying the new sum fixes while every stated figure stays
    ///   wrong.
    ///
    /// **Mutation:** set `HelperClientDeadlines.applyPerFan` to `.seconds(5)`, `gatedVerb`'s figure
    /// copied. Run: red on the first expectation and on the 57 s and 109 s lines. **Mutation:** in
    /// a scratch build, set `WatchdogLimits.gateWaiterAlarm` to `roundTrip * 3`, or
    /// `FanExaminationGate.lawfulHold` to `WatchdogLimits.gateWaiterAlarm * 4`. Run: red on the
    /// first two expectations, the literal's included.
    @Test("The apply deadline is derived from the helper's own bounds")
    func theApplyDeadlineIsDerivedFromTheHelpersOwnBounds() {
        let helpersBound = FanExaminationGate.examinationWait + WatchdogLimits.gateWaiterAlarm * 2
        #expect(
            HelperClientDeadlines.applyPerFan == helpersBound,
            """
            the client allows \(HelperClientDeadlines.applyPerFan) per fan for an `apply` the \
            helper may lawfully spend \(helpersBound) on — `examinationWait` plus two \
            `gateWaiterAlarm` turns. Below it, the client cuts off an `apply` the helper is still \
            honouring and its lease ends (#325); the copy exists only because this target may \
            not link the daemon.
            """)
        #expect(
            helpersBound == .seconds(52),
            """
            the helper's bound for one fan's engagement is now \(helpersBound), not the 52 s \
            `applyPerFan`'s documentation, ADR 0014 and the deadlines below state.
            """)
        #expect(HelperClientDeadlines.default.applyPerFan == HelperClientDeadlines.applyPerFan)

        let oneFan = [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_000))]
        let twoFans = oneFan + [FanSetting(fanIndex: 1, control: .fixed(rpm: 2_000))]
        #expect(HelperClientDeadlines.default.applyDeadline(naming: oneFan) == .seconds(57))
        #expect(HelperClientDeadlines.default.applyDeadline(naming: twoFans) == .seconds(109))
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

    /// **No harness *default* imposes a deadline tighter than the product's** — which is
    /// narrower than "no harness does", and the gap is stated below rather than left to a
    /// reader's optimism.
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
    /// **What this covers, exactly.** Every deadline a test can *inherit*, and there is one:
    /// `ClientListenerHarness.defaultDeadlines`, which eighteen tests take and which
    /// `FanctlAutoTests.run`, `FanctlStatusTests` and `FanctlResetTests.emitted(over:waiting:)`
    /// take by reference. `grep 'HelperClientDeadlines('` over `Tests/` finds no default written
    /// as a literal. The one construction deliberately *looser* than the product's,
    /// `FanctlResetTests.stallTolerant`, is `private` to the suite that passes it, so no other
    /// suite can inherit it ([#443](https://github.com/blamechris/Aeolus/issues/443)); that suite
    /// holds its three terms itself, in
    /// `theAnsweringDeadlinesAreTheProductsPlusTheStallCeiling`. So no test can acquire a tighter
    /// bound than the product's without naming one.
    ///
    /// **What it compares is a value against itself, and that is what it is for.**
    /// `ClientListenerHarness.defaultDeadlines` *is* `HelperClientDeadlines.default`
    /// (`HelperClientHarness.swift`). This is therefore a **source tripwire**: it cannot fail
    /// while the default is defined by reference, and it goes red the moment a literal is written
    /// back into it — which is the only way #250 returns. It is asserted as *equality* for that
    /// reason: there is no reason for the default the tests inherit to differ from the product in
    /// either direction, and equality catches a literal that merely *differs* rather than only
    /// one that is tighter.
    ///
    /// **What it does not cover, and what now does.** Eleven constructions pass a deadline
    /// explicitly, and this test reads none of them. A bound below the product's is legitimate at
    /// a site where the expiry *is* the assertion — `aMessageNobodyAnswersHasItsOwnError`'s 250 ms
    /// gated verb, `theHandshakeIsSentWithinItsOwnDeadline`'s 1 ns handshake,
    /// `FanctlResetTests.aHelperThatNeverAnswersIsReportedAsUnknown`'s 2 s panic path — and that
    /// is what those sites are for. What this comment used to enumerate beside them was five
    /// terms that were *not*: handshake terms below the product's 15 s at all three of
    /// `HelperClientTeardownTests`' short sites, and panic terms at half the product's 10 s, on
    /// round trips those tests require to succeed or never send at all.
    ///
    /// [#255](https://github.com/blamechris/Aeolus/issues/255) closed that category and decided
    /// the scan question it left open: `HelperClientDeadlineLiteralTests` holds every term of
    /// every explicit construction under `Tests/` to the product's bound, or to a named licence
    /// saying what asserts the tighter one. So the enumeration that lived here is not maintained
    /// here any more — a list in a doc comment is what let the panic column survive the issue the
    /// comment pointed at. This test is still cover for the *defaults* alone and must not be read
    /// as more.
    ///
    /// **It is also a relative check, deliberately, and that leaves a second route open.**
    /// Both sides move together if `HelperClientDeadlines` itself is tightened — a reachable
    /// change, since `gatedVerb` and `panicVerb` are documented as unmeasured guesses — so
    /// lowering the product's own bound would tighten eighteen tests with this test still
    /// green. The relation is still the right thing to assert here (a harness may be *looser*
    /// than the product, so an absolute floor on a harness constant would be wrong), and the two
    /// slow-peer tests below are the absolute floor that closes the other route — one per bound
    /// a test inherits, `aPeerASecondSlowToAnswerHelloStillRoundTrips` for the handshake and
    /// `aPeerASecondSlowToAnswerAGatedVerbStillRoundTrips` for everything behind it.
    ///
    /// **Mutation:** set `ClientListenerHarness.defaultDeadlines` back to
    /// `HelperClientDeadlines(gatedVerb: .milliseconds(750), panicVerb: .milliseconds(750),
    /// handshakeVerb: .milliseconds(750))`. Run: red on the first expectation, naming all three
    /// harness bounds and the shipping trio they undercut.
    @Test("No harness default imposes a tighter deadline than the product")
    func noHarnessDefaultImposesATighterDeadlineThanTheProduct() {
        let shipping = HelperClientDeadlines.default

        // Equality rather than `>=`: this is the default eighteen tests inherit, and it has no
        // business differing from the product in either direction. In the shipped tree it is
        // defined *as* `HelperClientDeadlines.default`, so this compares a value with itself and
        // can only fail once a literal is written back in — which is how #250 arose, twice.
        let harnessDeadlines = ClientListenerHarness.defaultDeadlines
        #expect(
            harnessDeadlines == shipping,
            """
            `ClientListenerHarness.defaultDeadlines` allows gated \(harnessDeadlines.gatedVerb) \
            / panic \(harnessDeadlines.panicVerb) / handshake \(harnessDeadlines.handshakeVerb) \
            where the product ships \(shipping.gatedVerb) / \(shipping.panicVerb) / \
            \(shipping.handshakeVerb) — the handshake being `reconciliationBudget + \
            spawnAllowance + gatedVerb`, the whole of the helper's cold start. Every test \
            taking this default asserts something other than a deadline, so a bound below the \
            product's can only fail them on a slow machine (#250), and a literal here is how \
            the 750 ms triple got in.
            """)
    }

    /// How long the peer is made to sit on a message in the two tests below.
    ///
    /// Longer than the 750 ms this suite's harness used to allow, because a lag *shorter* than
    /// that would leave both tests green under the exact constant #250 was about. Short enough
    /// that it is a second of suite wall clock and not five. That floor is asserted by
    /// `theConstructedPeerLagStillExceedsTheBoundBehind250`, once, rather than inside whichever
    /// of the two tests happened to be written first.
    private static let peerLag = Duration.seconds(1)

    /// The lag both slow-peer tests are built on is still longer than the bound #250 was about.
    ///
    /// **A tripwire over a constant, not a behaviour**, and it is labelled as one: it compares
    /// two compile-time values and cannot fail at runtime. It exists because `peerLag` is the
    /// one number that decides whether either test below is a test at all — shortened under
    /// 750 ms to save suite wall clock, both would pass against the very constant they were
    /// written to catch — and because a floor read by two tests belongs where both of them can
    /// point at it rather than asserted in one and absent from the other, which is how it was
    /// first written.
    ///
    /// **Mutation:** set `peerLag` to `.milliseconds(500)`. Run: red here, naming 0.5 seconds,
    /// while `aPeerASecondSlowToAnswerHelloStillRoundTrips` and
    /// `aPeerASecondSlowToAnswerAGatedVerbStillRoundTrips` both stay green — which is exactly
    /// the asymmetry this test exists to make visible.
    @Test("The constructed peer lag still exceeds the bound #250 was about")
    func theConstructedPeerLagStillExceedsTheBoundBehind250() {
        #expect(
            Self.peerLag > .milliseconds(750),
            """
            the lag is \(Self.peerLag), which does not exceed the 750 ms bound #250 was about — \
            so both slow-peer tests would have passed under the constant they exist to catch. \
            Shortening it to save suite wall clock is how they stop being tests.
            """)
    }

    /// **A peer a second slow to answer `hello` still round-trips.** The failure, exercised —
    /// not the constant, compared.
    ///
    /// `noHarnessDefaultImposesATighterDeadlineThanTheProduct` is a relation between two
    /// constants, so it is blind to tightening `HelperClientDeadlines` itself: both of its sides
    /// move together, it stays green, and eighteen tests inherit the tighter bound anyway.
    /// **That is the route this test closes**, because it reads no constant — it builds the
    /// thing [#250](https://github.com/blamechris/Aeolus/issues/250) actually was, a helper that
    /// answers one second later than a quiet machine would, and requires the client under the
    /// default deadlines to survive it. Whichever side of the relation moved below a second,
    /// this goes red and names the bound it went red at.
    ///
    /// **It is not a guard over the whole category either, and the honest limit is: it exercises
    /// `ClientListenerHarness`.** A *new* harness written with a fresh 750 ms literal of its own
    /// is still not caught by either test here. What catches it now is the source scan
    /// [#255](https://github.com/blamechris/Aeolus/issues/255) settled on —
    /// `HelperClientDeadlineLiteralTests`, which reads the literal rather than the round trip —
    /// and that has its own limit in the other direction: it cannot see a bound expressed as a
    /// local whose value it does not know, which is why each of those is licensed by name.
    ///
    /// The lag is constructed rather than raced, by the harness's existing
    /// `holdingHandshakeReplies` signal: `hello` reaches the real session, the handshake is
    /// negotiated, and only the answer waits. A contended runner is the same shape with the
    /// delay in libxpc instead, which is why one second of held reply stands in for it.
    ///
    /// **Mutations.**
    /// - Set `ClientListenerHarness.defaultDeadlines` to the 750 ms triple. Run: red, thrown
    ///   `helperNeverAnswered(after: 0.75 seconds)` — #250's own signature.
    /// - Set `HelperClientDeadlines.handshakeVerb` to `.milliseconds(500)` — the *product*
    ///   tightened, the route the relation cannot see. Run: red here with
    ///   `helperNeverAnswered(after: 0.5 seconds)`, while
    ///   `noHarnessDefaultImposesATighterDeadlineThanTheProduct` stays green. That pair is the
    ///   whole reason this test exists beside it. (The two derivation tests above go red on that
    ///   mutation too, because replacing the sum with a literal is also the drift they watch;
    ///   the route neither of them covers is the one below.)
    @Test("A peer a second slow to answer hello still round-trips")
    func aPeerASecondSlowToAnswerHelloStillRoundTrips() async throws {
        let releaseHandshake = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), holdingHandshakeReplies: releaseHandshake)
        let client = harness.client()

        let snapshot = Task { try await client.snapshot() }
        try await waitUntil("the handshake reached the helper and is being held") {
            harness.arrivals == ["hello"]
        }
        try await Task.sleep(for: Self.peerLag)
        await releaseHandshake.signal()

        _ = try await snapshot.value

        #expect(await client.health == .handshaken)
        #expect(
            harness.sessions.count == 1,
            """
            the client reached \(harness.sessions.count) sessions. One is the whole point — and \
            reading the harness here is also what pins it past the `client()` line, #239.
            """)
        // The floor under `peerLag` — the thing that makes a green run here mean anything — is
        // `theConstructedPeerLagStillExceedsTheBoundBehind250`, which the gated-verb test below
        // reads the same constant under.
    }

    /// **A peer a second slow to answer a *gated verb* still round-trips.** The same floor, on
    /// the other bound a test inherits.
    ///
    /// `handshakeVerb` is derived; `gatedVerb` is documented in `HelperClientDeadlines` as an
    /// unmeasured guess, which makes it the term most likely to be revised downward — and a
    /// revision to anything under a second would hand eighteen tests a bound tighter than the
    /// 750 ms that produced [#250](https://github.com/blamechris/Aeolus/issues/250), with the
    /// harness-versus-product relation still green because both of its sides moved. So the
    /// gated verb gets its own floor rather than sharing the handshake's.
    ///
    /// The lag is in the **helper's authority**, parked on `LeaseGrantingAuthority`'s
    /// `snapshotGate`, so the message is genuinely in flight and unanswered — a slow helper
    /// rather than a slow handshake, which is the state `gatedVerb` is the bound for.
    ///
    /// **Mutation:** set `HelperClientDeadlines.gatedVerb` to `.milliseconds(500)`. Run: red
    /// here with `helperNeverAnswered(after: 0.5 seconds)`, while
    /// `noHarnessDefaultImposesATighterDeadlineThanTheProduct` and
    /// `aPeerASecondSlowToAnswerHelloStillRoundTrips` both stay green — the first because both
    /// its sides moved, the second because `handshakeVerb` stays above the lag at 10.5 s.
    @Test("A peer a second slow to answer a gated verb still round-trips")
    func aPeerASecondSlowToAnswerAGatedVerbStillRoundTrips() async throws {
        let releaseSnapshot = AsyncSignal()
        let authority = LeaseGrantingAuthority(
            lease: Lease(
                id: UUID(),
                holderDescription: "test client",
                expiresAt: Date(timeIntervalSince1970: 1_000_030),
                timeToLive: 30),
            snapshotGate: releaseSnapshot)
        let harness = ClientListenerHarness(authority: authority)
        let client = harness.client()

        let snapshot = Task { try await client.snapshot() }
        try await waitUntil("the snapshot reached the helper and is parked in its authority") {
            await authority.hasBeenAskedForSnapshot
        }
        try await Task.sleep(for: Self.peerLag)
        await releaseSnapshot.signal()

        _ = try await snapshot.value

        #expect(await client.health == .handshaken)
        #expect(
            harness.sessions.count == 1,
            """
            the client reached \(harness.sessions.count) sessions. One is the whole point — and \
            reading the harness here is also what pins it past the `client()` line, #239.
            """)
    }
}
