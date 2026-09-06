import Foundation
import Security
import Testing

@testable import AeolusXPC

/// The other direction of [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md): the
/// requirement a **client** pins on its connection so that the peer answering the mach
/// service is the helper we shipped and not a per-user impostor squatting the name.
///
/// Mirrors `ClientRequirementTextTests` deliberately, exact-match discipline included.
/// #87's review established why that discipline is the load-bearing one: the negative
/// control only sees a requirement that collapsed into an Apple-wide one, and a
/// `contains` assertion cannot see a clause that was *added*. Only a whole-string
/// comparison sees both.
///
/// The literals below are checked against an external authority rather than only against
/// themselves: ADR 0005's "client-side mirror, clause by clause" section carries the clause
/// list for both variants, and `HelperMirrorSpecificationTests` asserts the
/// builder against it. #220's review is why — an exact-match test whose expectation was
/// transcribed from the implementation defends against drift and cannot defend against a
/// requirement that was wrong on day one.
///
/// What no test here can establish is that the text admits the real installed helper.
/// That needs a Developer ID signature and an installed daemon, and is E2.5's manual
/// `Mac16,5` checklist item.
@Suite("Helper pinning — requirement text")
struct HelperRequirementTextTests {

    private static let team = ClientAuthorisationFixtures.team

    @Test("The Release helper requirement is exactly the text ADR 0005's mirror section specifies")
    func releaseTextIsTheSpecifiedText() throws {
        let expected = """
            anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] \
            and certificate leaf[subject.OU] = "ABCDE12345" \
            and identifier "com.blamechris.Aeolus.Helper" \
            and !entitlement["com.apple.security.get-task-allow"]
            """
        let built = try HelperRequirementText.build(
            teamIdentifier: Self.team, variant: .release
        ).get()
        #expect(built == expected)
    }

    @Test("The Debug helper requirement adds a second chain and drops only the debuggable clause")
    func debugTextIsTheSpecifiedText() throws {
        let expected = """
            anchor apple generic \
            and ((certificate 1[field.1.2.840.113635.100.6.2.6] \
            and certificate leaf[field.1.2.840.113635.100.6.1.13]) \
            or (certificate 1[field.1.2.840.113635.100.6.2.1] \
            and certificate leaf[field.1.2.840.113635.100.6.1.12])) \
            and certificate leaf[subject.OU] = "ABCDE12345" \
            and identifier "com.blamechris.Aeolus.Helper"
            """
        let built = try HelperRequirementText.build(
            teamIdentifier: Self.team, variant: .debug
        ).get()
        #expect(built == expected)
    }

    @Test(
        "Both variants compile as code requirements",
        arguments: ClientAuthorisationFixtures.variants
    )
    func everyVariantCompiles(variant: ClientRequirementVariant) throws {
        let text = try HelperRequirementText.build(
            teamIdentifier: Self.team, variant: variant
        ).get()
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test(
        "The helper requirement names the helper and neither client",
        arguments: ClientAuthorisationFixtures.variants
    )
    func onlyTheHelperIsNamed(variant: ClientRequirementVariant) throws {
        let text = try HelperRequirementText.build(
            teamIdentifier: Self.team, variant: variant
        ).get()
        #expect(text.contains("identifier \"com.blamechris.Aeolus.Helper\""))
        // The two requirements are mirrors, not copies. A helper requirement that also
        // admitted the app or the CLI would let one client pin another client — the
        // pinning would compile, connect to an impostor of the right team, and say
        // nothing.
        #expect(!text.contains(AeolusClientIdentifier.commandLine))
        #expect(!text.contains("identifier \"\(AeolusClientIdentifier.app)\""))
    }

    @Test("Release excludes debuggable helpers and every Development certificate OID")
    func releasePinsTheDeveloperIDChainOnly() throws {
        let release = try HelperRequirementText.build(
            teamIdentifier: Self.team, variant: .release
        ).get()
        let debug = try HelperRequirementText.build(
            teamIdentifier: Self.team, variant: .debug
        ).get()
        let clause = "!entitlement[\"\(ClientRequirementText.debuggableEntitlement)\"]"
        #expect(release.contains(clause))
        #expect(!debug.contains(ClientRequirementText.debuggableEntitlement))
        // A debuggable helper is one whose task port a debugger can claim, which is a root
        // process that can be puppeted. Apple Development OIDs in a Release requirement
        // would mean a shipped client trusts a locally-built daemon.
        #expect(!release.contains("1.2.840.113635.100.6.1.12"))
        #expect(!release.contains("1.2.840.113635.100.6.2.1]"))
        #expect(release.contains("1.2.840.113635.100.6.2.6"))
        #expect(release.contains("1.2.840.113635.100.6.1.13"))
    }

    @Test(
        "A different Team ID produces a different requirement",
        arguments: ClientAuthorisationFixtures.variants
    )
    func teamIdentifierIsLoadBearing(variant: ClientRequirementVariant) throws {
        let ours = try HelperRequirementText.build(
            teamIdentifier: "ABCDE12345", variant: variant
        ).get()
        let theirs = try HelperRequirementText.build(
            teamIdentifier: "ZZZZZ99999", variant: variant
        ).get()
        #expect(ours != theirs)
        #expect(!ours.contains("ZZZZZ99999"))
    }

    /// The Team ID reaching the string unvalidated is the one input that can rewrite what
    /// the requirement *means*, so the builder validates before it interpolates and there
    /// is no overload that skips it.
    @Test(
        "A Team ID that could escape its quotes is refused before any text is built",
        arguments: ["AB\"CD", "AB\\CD", "ABCDE12345\" or anchor apple", "AB CD", "AB]CD", ""]
    )
    func malformedTeamRefused(candidate: String) {
        for variant in ClientAuthorisationFixtures.variants {
            let built = HelperRequirementText.build(
                teamIdentifier: candidate, variant: variant
            )
            #expect(built.isFailure)
            let sealed = HelperRequirementPinning.seal(
                teamIdentifier: candidate,
                variant: variant,
                negativeControl: .system
            )
            switch sealed {
            case .success:
                Issue.record("a malformed Team ID produced a sealed requirement")
            case .failure(let refusal):
                #expect(refusal.isTeamIdentifierNotWellFormed)
            }
        }
    }
}

/// The identifier clause is a copy of a value that lives in the build definition. Nothing
/// links the two at compile time, and a drift between them is silent in the worst way: the
/// helper still installs, the client still connects, and the pin refuses the very daemon it
/// was written to trust.
@Suite("Helper pinning — the identifier matches the build definition")
struct HelperIdentifierDriftTests {

    private static var projectDefinition: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/IntegrationTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repository root
            let yaml = root.appendingPathComponent("project.yml")
            return try String(contentsOf: yaml, encoding: .utf8)
        }
    }

    /// The lines of the `AeolusHelper:` target, from its own key to the next one at the
    /// same indentation. Scoped rather than searched whole, because the app target also
    /// declares a `PRODUCT_BUNDLE_IDENTIFIER` and matching that one would assert nothing.
    private static func helperTargetLines(in yaml: String) -> [Substring] {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0 == "  AeolusHelper:" }) else { return [] }
        let rest = lines[lines.index(after: start)...]
        let end =
            rest.firstIndex { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                return line.prefix(3).filter { $0 == " " }.count < 3
            } ?? lines.endIndex
        return Array(lines[start..<end])
    }

    private static func value(of key: String, in lines: [Substring]) throws -> String {
        let line = try #require(
            lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") },
            "project.yml's AeolusHelper target declares no \(key)"
        )
        let value = line.drop { $0 != ":" }.dropFirst()
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    @Test("The pinned identifier is the helper's PRODUCT_BUNDLE_IDENTIFIER")
    func productBundleIdentifierMatches() throws {
        let lines = Self.helperTargetLines(in: try Self.projectDefinition)
        #expect(!lines.isEmpty, "project.yml declares no AeolusHelper target")
        let declared = try Self.value(of: "PRODUCT_BUNDLE_IDENTIFIER", in: lines)
        #expect(declared == HelperRequirementText.helperIdentifier)
    }

    /// The tool target has nowhere to put an Info.plist except inside its own binary, and
    /// that embedded plist is what fixes the code-signing identifier a client can pin. If
    /// it and the build setting disagreed, which one wins is a question nobody should have
    /// to answer at a refused connection.
    @Test("The pinned identifier is the helper's embedded CFBundleIdentifier")
    func bundleIdentifierMatches() throws {
        let lines = Self.helperTargetLines(in: try Self.projectDefinition)
        let declared = try Self.value(of: "CFBundleIdentifier", in: lines)
        #expect(declared == HelperRequirementText.helperIdentifier)
    }
}

/// Sealing: nothing may reach `setCodeSigningRequirement` that has not compiled here
/// first. ADR 0005's verification log measured what a malformed requirement does — an
/// uncatchable `NSInvalidArgumentException` on a libxpc event thread — and on the client
/// side that is a crash of the app, in the user's face, on every connect.
@Suite("Helper pinning — sealing and the running process")
struct HelperRequirementPinningTests {

    private static let team = ClientAuthorisationFixtures.team

    @Test(
        "A well-formed team seals in both variants",
        arguments: ClientAuthorisationFixtures.variants
    )
    func wellFormedTeamSeals(variant: ClientRequirementVariant) throws {
        let sealed = try HelperRequirementPinning.seal(
            teamIdentifier: Self.team, variant: variant, negativeControl: .system
        ).get()
        #expect(sealed.teamIdentifier == Self.team)
        #expect(sealed.isRelaxedForDevelopment == variant.isRelaxedForDevelopment)
        #expect(
            sealed.text
                == (try HelperRequirementText.build(
                    teamIdentifier: Self.team, variant: variant
                ).get())
        )
    }

    @Test("Text that does not compile is never sealed")
    func uncompilableTextIsRefused() {
        let outcome = HelperRequirementPinning.seal(
            text: "anchor apple generic and (((",
            teamIdentifier: Self.team,
            variant: .release,
            negativeControl: .system
        )
        switch outcome {
        case .success: Issue.record("uncompilable text was sealed")
        case .failure(let refusal): #expect(refusal.isRequirementDidNotCompile)
        }
    }

    /// `anchor apple` compiles and admits every binary Apple ships. A client pinning it
    /// would trust any Apple-signed process that got to the mach name first, which is
    /// exactly the impostor this requirement exists to exclude — and it is a *semantic*
    /// break, so only the probe sees it.
    @Test("A requirement that admits Apple platform code is refused")
    func negativeControlFires() {
        let outcome = HelperRequirementPinning.seal(
            text: "anchor apple",
            teamIdentifier: Self.team,
            variant: .release,
            negativeControl: .system
        )
        #expect(outcome == .failure(.negativeControlAdmittedForeignCode))
    }

    @Test("A negative control that cannot run refuses rather than passing")
    func inconclusiveNegativeControlRefuses() {
        let outcome = HelperRequirementPinning.seal(
            teamIdentifier: Self.team,
            variant: .release,
            negativeControl: RequirementNegativeControl(probePath: "/nonexistent/probe")
        )
        switch outcome {
        case .success: Issue.record("an unrunnable negative control was treated as a pass")
        case .failure(let refusal): #expect(refusal.isNegativeControlUnavailable)
        }
    }

    /// The consequence ADR 0005 already accepts: a client that cannot verify itself cannot
    /// pin the helper, so it refuses to connect. A `swift build` `fanctl` can never command
    /// an installed helper, and the refusal names why rather than failing at the connection.
    ///
    /// Written as an exhaustive switch on the host's own signature rather than a flat
    /// equality, for the reason `ClientAuthorisationTests.productionEntryPointMatchesTheHost`
    /// gives: under `swift test` the host is ad-hoc signed here and on CI alike, but if this
    /// suite is ever run from a signed test host it must assert the *other* branch rather
    /// than go red for the mechanism working. No arm fabricates a Team ID — each one reads
    /// the answer the host actually gives.
    @Test("The production entry point agrees with this host's own signature")
    func productionEntryPointMatchesTheHost() {
        let inspection = HelperSigningIdentity.inspect()
        let outcome = HelperRequirementPinning.resolveForRunningProcess()

        switch inspection {
        case .noTeamIdentifier:
            guard case .failure(let refusal) = outcome else {
                Issue.record("a host with no Team ID should refuse, got \(outcome)")
                return
            }
            #expect(refusal == .runningProcessHasNoTeamIdentifier)
            #expect(refusal.description.contains("Team ID"))
        case .inspectionFailed(let status):
            #expect(outcome == .failure(.selfInspectionFailed(status)))
        case .teamIdentifier(let team):
            guard case .success(let requirement) = outcome else {
                Issue.record("a host with team \(team) should pin, got \(outcome)")
                return
            }
            #expect(requirement.teamIdentifier == team)
        }
    }
}

extension Result {
    fileprivate var isFailure: Bool {
        switch self {
        case .success: return false
        case .failure: return true
        }
    }
}

extension HelperPinningRefusal {
    fileprivate var isTeamIdentifierNotWellFormed: Bool {
        if case .teamIdentifierNotWellFormed = self { return true }
        return false
    }

    fileprivate var isRequirementDidNotCompile: Bool {
        if case .requirementDidNotCompile = self { return true }
        return false
    }

    fileprivate var isNegativeControlUnavailable: Bool {
        if case .negativeControlUnavailable = self { return true }
        return false
    }
}
