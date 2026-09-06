import Foundation
import Security
import Testing

@testable import AeolusXPC

// A second negative-control probe, and the one clause of damage it gives the control teeth
// against (#87).
//
// ## Why a second probe
//
// The startup negative control probes `/bin/ls` — Apple-team platform code — so the only
// requirements it can catch are ones that admit Apple platform binaries. Measured on this
// tree, three separate pieces of clause-level damage leave it silent, all reporting a plain
// requirement failure (`errSecCSReqFailed`, -67050): deleting the Team ID clause, deleting
// the certificate chain clauses, and unparenthesising the identifier disjunction.
//
// The third is not cosmetic. `and` binds tighter than `or` in the requirement language, so
//
//     … and certificate leaf[subject.OU] = "…" and identifier "com.blamechris.Aeolus"
//     or identifier "com.blamechris.fanctl" and !entitlement["…"]
//
// parses as `(everything and Aeolus) or (fanctl and not-debuggable)`. The second alternative
// carries no anchor, no chain, and no team, so **any** ad-hoc-signed binary that calls itself
// `com.blamechris.fanctl` satisfies the whole requirement. Verified here rather than argued:
// `probeIsAdmittedByAnUnparenthesisedDisjunction` builds exactly that text out of the
// production text and watches the probe sail through it.
//
// ## What this suite does not close
//
// Only the precedence class. A probe built without a signing identity is ad-hoc, so it fails
// `anchor apple generic`, so every requirement that still *conjoins* that clause rejects it —
// which is why deleting the Team ID clause and deleting the chain clauses both leave this
// suite green, measured, not assumed (see `probeCannotSeeConjunctiveClauseDeletion`). Going
// the other way does not help either: a probe that satisfies `anchor apple generic` is code we
// did not sign, so its identifier is not ours and the identifier clause rejects it. Between
// those two, no probe buildable on a machine with no Developer ID can observe the loss of a
// single conjunct.
//
// So clause-level coverage still lives in `ClientRequirementTextTests`' exact-match tests, and
// this suite is a second, independent net under the one class those tests would have been the
// sole defence against. Neither replaces E2.5's hardware checklist.
//
// ## Why this is a test and not a startup control
//
// The production negative control runs as root at daemon startup. A probe of this shape would
// need a writable directory and a `codesign` invocation at that moment — a subprocess spawned
// by root during authorisation setup, over a file an attacker may be able to reach. That is a
// new attack surface, not a control. The probe is built here, where the cost of being wrong is
// a red test.

/// The clause-level probe: an ad-hoc client wearing an Aeolus identifier.
@Suite(
    "Client authorisation — an ad-hoc client wearing our identifier",
    .enabled(if: AdHocSignedFixtures.isAvailable, "codesign is not present on this host")
)
struct AeolusIdentifiedProbeTests {

    /// Vacuity guard for everything below.
    ///
    /// Every other test in this suite says the probe is *refused*, and a probe that is
    /// malformed, unreadable, or wearing the wrong identifier is refused too — for reasons
    /// that would make the rest of the suite prove nothing. So: it evaluates (no
    /// `errSecCSUnsigned`, no `errSecCSStaticCodeNotFound`), and it really does claim to be
    /// one of our clients.
    ///
    /// The identifier asserted here is read from `AeolusClientIdentifier`, the production
    /// constant, and deliberately **not** from the fixture. Asking the fixture what it signed
    /// itself as would make this guard agree with whatever the fixture did, which is exactly
    /// the shape of a test that cannot fail.
    @Test("The probe is evaluable and really does wear an Aeolus client identifier")
    func probeIsEvaluableAndClaimsToBeOurs() throws {
        let probe = try AeolusIdentifiedProbeFixture.make()
        defer { probe.remove() }

        let identifier = AeolusClientIdentifier.commandLine
        let claimsToBeUs = try ClientAuthorisationFixtures.compile("identifier \"\(identifier)\"")
        #expect(
            ClientAuthorisationFixtures.checkValidity(claimsToBeUs, probe.path) == errSecSuccess
        )

        // And it is genuinely not Apple's code any more, which is the half `/bin/ls` cannot
        // supply: the requirement's anchor is the clause that carries the probe's refusal
        // below, and a probe that still satisfied it would be testing something else.
        let appleAnchored = try ClientAuthorisationFixtures.compile("anchor apple generic")
        #expect(
            ClientAuthorisationFixtures.checkValidity(appleAnchored, probe.path)
                == errSecCSReqFailed
        )
    }

    /// The assertion itself, through the production evaluation path rather than a parallel
    /// one: `RequirementNegativeControl.evaluate`, the same call the helper makes at startup,
    /// pointed at this probe instead of `/bin/ls`.
    @Test(
        "The production requirement refuses an ad-hoc client wearing our identifier",
        arguments: ClientAuthorisationFixtures.variants
    )
    func productionRequirementRefusesTheProbe(variant: ClientRequirementVariant) throws {
        let probe = try AeolusIdentifiedProbeFixture.make()
        defer { probe.remove() }

        let requirement = try ClientAuthorisationFixtures.compiledRequirement(variant: variant)
        let control = RequirementNegativeControl(probePath: probe.path)
        #expect(control.evaluate(requirement) == .rejectedProbe)
    }

    /// The teeth. Without this the test above is a requirement being asserted against a probe
    /// that nothing could ever admit.
    ///
    /// The widened text is derived from the production text by removing exactly one pair of
    /// parentheses, so this is the real requirement with one real defect in it, not a
    /// hand-written imitation of one.
    @Test(
        "Unparenthesising the identifier disjunction admits the probe outright",
        arguments: ClientAuthorisationFixtures.variants
    )
    func probeIsAdmittedByAnUnparenthesisedDisjunction(
        variant: ClientRequirementVariant
    ) throws {
        let probe = try AeolusIdentifiedProbeFixture.make()
        defer { probe.remove() }

        let widenedText = try ClientAuthorisationFixtures.unparenthesisedIdentifierDisjunction(
            variant: variant
        )
        let widened = try ClientAuthorisationFixtures.compile(widenedText)
        let control = RequirementNegativeControl(probePath: probe.path)
        #expect(control.evaluate(widened) == .admittedProbe)
    }

    /// The same widened text, run all the way through the decision the helper actually makes,
    /// so that "the probe notices" and "the helper refuses to serve anybody" are the same
    /// fact rather than two adjacent ones.
    @Test("A helper whose requirement admits the probe refuses every connection")
    func admittedProbeEndsInRefuseAll() throws {
        let probe = try AeolusIdentifiedProbeFixture.make()
        defer { probe.remove() }

        let widenedText = try ClientAuthorisationFixtures.unparenthesisedIdentifierDisjunction(
            variant: .release
        )
        let outcome = ClientAuthorisationBuilder.seal(
            text: widenedText,
            teamIdentifier: ClientAuthorisationFixtures.team,
            variant: .release,
            negativeControl: RequirementNegativeControl(probePath: probe.path)
        )
        #expect(outcome == .refuseAll(.negativeControlAdmittedForeignCode))
        #expect(!outcome.permitsAnyConnection)
    }

    /// The measurement this whole file rests on, pinned so it cannot quietly stop being true:
    /// the *startup* control, probing `/bin/ls`, does not see the precedence defect. If this
    /// ever fails, the startup control grew teeth it did not have and this suite's premise —
    /// and its doc comment — need rewriting rather than the assertion relaxing.
    @Test(
        "The startup control is blind to the defect this suite catches",
        arguments: ClientAuthorisationFixtures.variants
    )
    func startupControlIsBlindToThePrecedenceDefect(variant: ClientRequirementVariant) throws {
        let widenedText = try ClientAuthorisationFixtures.unparenthesisedIdentifierDisjunction(
            variant: variant
        )
        let widened = try ClientAuthorisationFixtures.compile(widenedText)
        #expect(RequirementNegativeControl.system.evaluate(widened) == .rejectedProbe)
    }

    /// The honest limit, measured rather than asserted in prose: this probe cannot see a
    /// *conjunct* being deleted, because it fails `anchor apple generic` and every such
    /// requirement still conjoins that clause. Deleting the Team ID clause or the certificate
    /// chain clauses therefore leaves the probe refused exactly as before.
    ///
    /// Pinned as a test so the limit is a fact on the record rather than a claim in a comment,
    /// and so that a future probe that *does* see one of these makes this test fail and
    /// forces the comment above to be corrected.
    @Test(
        "The probe cannot see a deleted conjunct, and this file says so",
        arguments: ClientAuthorisationFixtures.deletableConjuncts
    )
    func probeCannotSeeConjunctiveClauseDeletion(conjunct: String) throws {
        let probe = try AeolusIdentifiedProbeFixture.make()
        defer { probe.remove() }

        let damagedText = try ClientAuthorisationFixtures.releaseTextDeleting(conjunct)
        let damaged = try ClientAuthorisationFixtures.compile(damagedText)
        let control = RequirementNegativeControl(probePath: probe.path)
        #expect(control.evaluate(damaged) == .rejectedProbe)
    }
}
