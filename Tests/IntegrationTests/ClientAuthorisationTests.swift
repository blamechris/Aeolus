import Foundation
import Security
import Testing

@testable import AeolusXPC

// Tests for the client authorisation module (E2.2), per ADR 0005.
//
// ## The line these tests do not cross
//
// Everything here runs with **no signing identity and no SMC**, which is what CI has.
// That is enough to test the *builder* exhaustively — both requirement variants, every
// fail-closed row, and a negative control that is itself mutation-tested.
//
// It is not enough to test the *requirement*. Whether the production text admits the real
// signed Aeolus.app and `fanctl` and refuses everything else cannot be established without
// a Developer ID signature, which exists on exactly one machine. That is E2.5's manual
// `Mac16,5` checklist, whose load-bearing item is "an ad-hoc-built client is refused by the
// installed helper".
//
// So: a green run here means the builder is correct. It does not mean the boundary holds.
// Do not add a test that appears to close that gap without closing it — a test that cannot
// fail is worse than an absent one, and this project has already shipped five of them.

/// The startup negative control, and proof that it can fire.
@Suite("Client authorisation — negative control")
struct RequirementNegativeControlTests {

    @Test(
        "An Aeolus client requirement rejects /bin/ls",
        arguments: ClientAuthorisationFixtures.variants
    )
    func realRequirementRejectsAppleBinary(variant: ClientRequirementVariant) throws {
        let requirement = try ClientAuthorisationFixtures.compiledRequirement(variant: variant)
        #expect(RequirementNegativeControl.system.evaluate(requirement) == .rejectedProbe)
    }

    /// The mutation. `anchor apple` is a requirement that compiles perfectly and admits
    /// every binary Apple ships — exactly the class of mistake the control exists to catch.
    /// If this returns anything but `.admittedProbe`, the control is decorative and the
    /// test above proves nothing.
    @Test("A requirement that admits any Apple binary is caught")
    func brokenRequirementIsCaught() throws {
        let requirement = try ClientAuthorisationFixtures.compile("anchor apple")
        #expect(RequirementNegativeControl.system.evaluate(requirement) == .admittedProbe)
    }

    @Test("A missing probe binary is inconclusive, and inconclusive is not a pass")
    func missingProbeIsRefused() throws {
        let requirement = try ClientAuthorisationFixtures.compiledRequirement(variant: .release)
        let control = RequirementNegativeControl(probePath: "/var/empty/aeolus-no-such-probe")
        guard case .probeUnavailable = control.evaluate(requirement) else {
            Issue.record("A missing probe must be reported unavailable, never as a pass")
            return
        }
    }

    /// The failure that is *not* a missing file: a probe the Security framework opens
    /// happily and then declines to evaluate. `SecStaticCodeCheckValidity` returns
    /// `errSecCSUnsigned` without ever consulting the requirement, so an unsigned probe
    /// says nothing at all about whether the requirement discriminates.
    ///
    /// This is driven with `anchor apple` on purpose. That is the module's canonical broken
    /// requirement — the one `brokenRequirementIsCaught` proves the control catches — so if
    /// "the probe could not be evaluated" is ever folded back into "the probe was rejected",
    /// this test shows the control reporting a pass for a requirement that admits every
    /// binary Apple ships.
    @Test("A probe that cannot be evaluated is inconclusive, not a rejection")
    func unsignedProbeIsInconclusive() throws {
        let fixture = try UnsignedBinaryFixture.make()
        defer { fixture.remove() }

        let control = RequirementNegativeControl(probePath: fixture.path)
        let broken = try ClientAuthorisationFixtures.compile("anchor apple")
        #expect(control.evaluate(broken) == .probeUnavailable(errSecCSUnsigned))

        // And the same for a requirement that is not broken: the distinction is a property
        // of the probe, not of what it was checked against.
        let real = try ClientAuthorisationFixtures.compiledRequirement(variant: .release)
        #expect(control.evaluate(real) == .probeUnavailable(errSecCSUnsigned))
    }

    /// A genuine rejection is `errSecCSReqFailed` and nothing else. Pinned because the whole
    /// correctness of `evaluate` rests on that status meaning what it is taken to mean: if
    /// the framework ever reported a plain requirement mismatch some other way, the control
    /// would start refusing every startup, and it should be this test that says so rather
    /// than a helper that will not talk to anybody.
    @Test(
        "A real rejection is a requirement failure, not some other error",
        arguments: ClientAuthorisationFixtures.variants
    )
    func rejectionIsAGenuineRequirementFailure(variant: ClientRequirementVariant) throws {
        let requirement = try ClientAuthorisationFixtures.compiledRequirement(variant: variant)
        let status = ClientAuthorisationFixtures.checkValidity(
            requirement,
            RequirementNegativeControl.systemProbePath
        )
        #expect(status == errSecCSReqFailed)
    }

    /// `.noNetworkAccess` is not decoration. Without it a root daemon's startup can depend
    /// on the machine resolving DNS for revocation and notarization checks, which is the
    /// difference between "bounded and local" and "bounded and local when the network is
    /// up". Nothing else in the suite fails if it is deleted, so this does.
    @Test("Validation is pinned to no network access")
    func validationDoesNotReachTheNetwork() {
        #expect(RequirementNegativeControl.validationFlags.contains(.noNetworkAccess))
    }
}

/// The fail-closed table from ADR 0005, one test per row, driven end to end through the
/// builder so every row produces a real `ClientAuthorisationOutcome`.
@Suite("Client authorisation — fail closed")
struct ClientAuthorisationBuilderTests {

    private static let team = ClientAuthorisationFixtures.team

    @Test("A signed helper of a valid team enforces a requirement")
    func happyPathEnforces() {
        let outcome = ClientAuthorisationBuilder.build(
            inspection: .teamIdentifier(Self.team),
            variant: .release,
            negativeControl: .system
        )
        guard case .enforce(let requirement) = outcome else {
            Issue.record("Expected .enforce, got \(outcome)")
            return
        }
        #expect(requirement.teamIdentifier == Self.team)
        #expect(!requirement.isRelaxedForDevelopment)
        #expect(requirement.text.contains(Self.team))
        #expect(outcome.permitsAnyConnection)
    }

    @Test("A Debug-built requirement advertises that it is relaxed")
    func debugRequirementAdvertisesItsRelaxation() {
        let outcome = ClientAuthorisationBuilder.build(
            inspection: .teamIdentifier(Self.team),
            variant: .debug,
            negativeControl: .system
        )
        guard case .enforce(let requirement) = outcome else {
            Issue.record("Expected .enforce, got \(outcome)")
            return
        }
        #expect(requirement.isRelaxedForDevelopment)
    }

    /// Row 1: an ad-hoc or unsigned helper names nobody, so it obeys nobody.
    @Test("A helper with no Team ID refuses every connection")
    func noTeamIdentifierRefusesAll() {
        let outcome = ClientAuthorisationBuilder.build(
            inspection: .noTeamIdentifier,
            variant: .release,
            negativeControl: .system
        )
        #expect(outcome == .refuseAll(.helperHasNoTeamIdentifier))
        #expect(!outcome.permitsAnyConnection)
    }

    @Test("A helper whose own signature cannot be read refuses every connection")
    func selfInspectionFailureRefusesAll() {
        let outcome = ClientAuthorisationBuilder.build(
            inspection: .inspectionFailed(errSecCSUnsigned),
            variant: .release,
            negativeControl: .system
        )
        #expect(outcome == .refuseAll(.selfInspectionFailed(errSecCSUnsigned)))
    }

    @Test(
        "A Team ID that cannot be safely quoted refuses every connection",
        arguments: [("", TeamIdentifierRejection.empty), ("AB\"CD", .unacceptableCharacters)]
    )
    func unusableTeamIdentifierRefusesAll(team: String, rejection: TeamIdentifierRejection) {
        let outcome = ClientAuthorisationBuilder.build(
            inspection: .teamIdentifier(team),
            variant: .release,
            negativeControl: .system
        )
        #expect(outcome == .refuseAll(.teamIdentifierNotWellFormed(rejection)))
    }

    /// Row 2: the text must never be handed onward uncompiled. Driven through the sealing
    /// seam because the production path cannot produce uncompilable text — which is the
    /// point, but leaves the refusal branch unexecuted unless it is reachable this way.
    @Test("Text that does not compile refuses every connection")
    func uncompilableRequirementRefusesAll() {
        let outcome = ClientAuthorisationBuilder.seal(
            text: "anchor apple generic and certificate leaf[[[",
            teamIdentifier: Self.team,
            variant: .release,
            negativeControl: .system
        )
        guard case .refuseAll(.requirementDidNotCompile) = outcome else {
            Issue.record("Expected .requirementDidNotCompile, got \(outcome)")
            return
        }
    }

    /// Row 4: a requirement that admits `/bin/ls` is broken however well it compiles, and a
    /// broken requirement is refuse-all, not enforce.
    @Test("A requirement that admits a foreign Apple binary refuses every connection")
    func negativeControlFiringRefusesAll() {
        let outcome = ClientAuthorisationBuilder.seal(
            text: "anchor apple",
            teamIdentifier: Self.team,
            variant: .release,
            negativeControl: .system
        )
        #expect(outcome == .refuseAll(.negativeControlAdmittedForeignCode))
    }

    /// Defence in depth: Team ID validation and the negative control share no code path, so
    /// a requirement widened by a crafted Team ID is caught even when validation is the
    /// thing that failed. This is the text a `"` in a Team ID would have produced.
    @Test("A requirement widened by an injected Team ID is caught independently")
    func injectionWidenedRequirementIsCaught() {
        let widened = """
            anchor apple generic \
            and certificate leaf[subject.OU] = "ABCDE12345" or anchor apple
            """
        let outcome = ClientAuthorisationBuilder.seal(
            text: widened,
            teamIdentifier: Self.team,
            variant: .release,
            negativeControl: .system
        )
        #expect(outcome == .refuseAll(.negativeControlAdmittedForeignCode))
    }

    @Test("A negative control that cannot run refuses every connection")
    func unrunnableNegativeControlRefusesAll() {
        let outcome = ClientAuthorisationBuilder.build(
            inspection: .teamIdentifier(Self.team),
            variant: .release,
            negativeControl: RequirementNegativeControl(probePath: "/var/empty/aeolus-no-probe")
        )
        guard case .refuseAll(.negativeControlUnavailable) = outcome else {
            Issue.record("Expected .negativeControlUnavailable, got \(outcome)")
            return
        }
    }

    /// The other way the control comes back inconclusive: a probe that exists and is
    /// readable but carries no signature. Asserted through the builder as well as at the
    /// control, because the property that matters is not "evaluate returns a third case" —
    /// it is that the third case ends the startup path in refuse-all rather than being
    /// waved through as a rejection.
    @Test("A probe that cannot be evaluated refuses every connection")
    func inconclusiveNegativeControlRefusesAll() throws {
        let fixture = try UnsignedBinaryFixture.make()
        defer { fixture.remove() }

        let outcome = ClientAuthorisationBuilder.build(
            inspection: .teamIdentifier(Self.team),
            variant: .release,
            negativeControl: RequirementNegativeControl(probePath: fixture.path)
        )
        #expect(outcome == .refuseAll(.negativeControlUnavailable(errSecCSUnsigned)))
        #expect(!outcome.permitsAnyConnection)
    }

    @Test(
        "Every refusal describes itself for the fault log",
        arguments: ClientAuthorisationFixtures.refusals
    )
    func everyRefusalHasADescription(refusal: ClientAuthorisationRefusal) {
        #expect(!refusal.description.isEmpty)
        #expect(!refusal.description.contains("ClientAuthorisationRefusal"))
    }
}

/// The one suite that touches the real world: this process's own signature, and the
/// entitlement clause evaluated against binaries that really do and really do not carry it.
@Suite("Client authorisation — the real host")
struct ClientAuthorisationHostTests {

    /// Reading our own signature must *succeed*, whatever it turns out to say.
    ///
    /// The one deterministic thing about this host: a Mach-O the kernel agreed to execute is
    /// at minimum linker-signed, on CI and on the maintainer's machine alike, so
    /// `SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopySigningInformation` can
    /// always complete. *Whether* the signature carries a Team ID is host-dependent and is
    /// deliberately not asserted here — `productionEntryPointMatchesTheHost` handles that by
    /// agreeing with whatever the host is. Whether it can be **read** is not host-dependent,
    /// and until #87 nothing said so: the whole suite stayed green with the static-code step
    /// forced to fail, because every assertion about `inspect()` was written to tolerate any
    /// answer it gave.
    ///
    /// The refusal that failure produces is fail-closed, so this is not a safety hole — it is
    /// a helper that would refuse every client for a reason nobody could distinguish from a
    /// genuine one, with no test between that state and a release.
    @Test("Reading this process's own code signature succeeds on any host that can run tests")
    func selfInspectionSucceedsOnTheHost() {
        let inspection = HelperSigningIdentity.inspect()
        if case .inspectionFailed(let status) = inspection {
            Issue.record(
                """
                Reading our own signature failed with OSStatus \(status). Any binary this \
                runner can execute is at least linker-signed, so this is a defect in \
                HelperSigningIdentity.inspect(), not a property of the host.
                """
            )
        }
    }

    /// `swift test` binaries are ad-hoc signed and carry no Team ID, on CI and on the
    /// maintainer's machine alike — so the production entry point refuses here, which is
    /// row 1 of the fail-closed table exercised by the test runner itself.
    ///
    /// Written as an exhaustive switch rather than a flat equality so it stays honest if
    /// ever run from a properly signed host: it then asserts the *other* branch instead of
    /// being silently skipped.
    @Test("The production entry point agrees with whatever this host actually is")
    func productionEntryPointMatchesTheHost() {
        let inspection = HelperSigningIdentity.inspect()
        let outcome = ClientAuthorisation.resolveForRunningProcess()

        switch inspection {
        case .noTeamIdentifier:
            #expect(outcome == .refuseAll(.helperHasNoTeamIdentifier))
        case .inspectionFailed(let status):
            #expect(outcome == .refuseAll(.selfInspectionFailed(status)))
        case .teamIdentifier(let team):
            guard case .enforce(let requirement) = outcome else {
                Issue.record("A host with team \(team) should enforce, got \(outcome)")
                return
            }
            #expect(requirement.teamIdentifier == team)
        }
    }

    /// The clause that keeps a debuggable client out of a Release helper, evaluated against
    /// two binaries that differ in exactly that entitlement and nothing else.
    ///
    /// Compiling is not discriminating — that is the whole argument for the negative
    /// control, and it applies to this clause too.
    ///
    /// This is as close as a machine with no signing identity can get to the acceptance
    /// criterion "Release rejects a `get-task-allow` client". The remainder — that the
    /// clause is in the Release text and absent from the Debug text — is asserted in
    /// `ClientRequirementTextTests`. Those two together are what CI can establish; the whole
    /// requirement against a real signed client is E2.5's hardware checklist.
    @Test("The get-task-allow clause actually discriminates")
    func debuggableEntitlementClauseDiscriminates() throws {
        let fixtures = try AdHocSignedFixtures.make()
        defer { fixtures.remove() }

        let key = ClientRequirementText.debuggableEntitlement
        let excludesDebuggable = try ClientAuthorisationFixtures.compile("!entitlement[\"\(key)\"]")

        // Vacuity guard: if the fixture did not actually pick up the entitlement, the two
        // expectations below would pass while proving nothing.
        let requiresDebuggable = try ClientAuthorisationFixtures.compile("entitlement[\"\(key)\"]")
        #expect(ClientAuthorisationFixtures.satisfies(requiresDebuggable, fixtures.debuggable))

        #expect(!ClientAuthorisationFixtures.satisfies(excludesDebuggable, fixtures.debuggable))
        #expect(ClientAuthorisationFixtures.satisfies(excludesDebuggable, fixtures.plain))
    }
}
