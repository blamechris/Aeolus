import Foundation
import Security
import Testing

@testable import AeolusXPC

/// The pure half of the client authorisation module (E2.2): requirement text and the
/// Team ID validation that guards it.
///
/// What a green run here does and does not mean is documented in
/// `ClientAuthorisationTests.swift`. Read it before adding a test that looks like it
/// covers the production requirement — it does not, and cannot.
@Suite("Client authorisation — requirement text")
struct ClientRequirementTextTests {

    private static let team = ClientAuthorisationFixtures.team

    @Test("The Release requirement is exactly the text ADR 0005 specifies")
    func releaseTextIsTheSpecifiedText() throws {
        let expected = """
            anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] \
            and certificate leaf[subject.OU] = "ABCDE12345" \
            and (identifier "com.blamechris.Aeolus" or identifier "com.blamechris.fanctl") \
            and !entitlement["com.apple.security.get-task-allow"]
            """
        let built = try #require(
            ClientRequirementText.build(teamIdentifier: Self.team, variant: .release)
        )
        #expect(built == expected)
    }

    @Test("The Debug requirement adds a second chain and drops only the debuggable clause")
    func debugTextIsTheSpecifiedText() throws {
        let expected = """
            anchor apple generic \
            and ((certificate 1[field.1.2.840.113635.100.6.2.6] \
            and certificate leaf[field.1.2.840.113635.100.6.1.13]) \
            or (certificate 1[field.1.2.840.113635.100.6.2.1] \
            and certificate leaf[field.1.2.840.113635.100.6.1.12])) \
            and certificate leaf[subject.OU] = "ABCDE12345" \
            and (identifier "com.blamechris.Aeolus" or identifier "com.blamechris.fanctl")
            """
        let built = try #require(
            ClientRequirementText.build(teamIdentifier: Self.team, variant: .debug)
        )
        #expect(built == expected)
    }

    @Test("Release excludes get-task-allow clients; Debug tolerates them")
    func onlyReleaseExcludesDebuggableClients() throws {
        let release = try #require(
            ClientRequirementText.build(teamIdentifier: Self.team, variant: .release)
        )
        let debug = try #require(
            ClientRequirementText.build(teamIdentifier: Self.team, variant: .debug)
        )
        let clause = "!entitlement[\"\(ClientRequirementText.debuggableEntitlement)\"]"
        #expect(release.contains(clause))
        #expect(!debug.contains(ClientRequirementText.debuggableEntitlement))
    }

    @Test("The Release requirement contains no Apple Development certificate OID")
    func releaseAdmitsNoDevelopmentChain() throws {
        let release = try #require(
            ClientRequirementText.build(teamIdentifier: Self.team, variant: .release)
        )
        // Apple Development leaf and the WWDR intermediate that signs it. Their presence
        // in a Release requirement would mean a shipped helper accepts locally-built
        // clients — the exact failure the Debug/Release split exists to prevent.
        #expect(!release.contains("1.2.840.113635.100.6.1.12"))
        #expect(!release.contains("1.2.840.113635.100.6.2.1]"))
        // The Developer ID chain is still pinned.
        #expect(release.contains("1.2.840.113635.100.6.2.6"))
        #expect(release.contains("1.2.840.113635.100.6.1.13"))
    }

    @Test(
        "Both variants pin the Team ID and both client identifiers",
        arguments: ClientAuthorisationFixtures.variants
    )
    func everyVariantPinsTeamAndIdentifiers(variant: ClientRequirementVariant) throws {
        let text = try #require(
            ClientRequirementText.build(teamIdentifier: Self.team, variant: variant)
        )
        #expect(text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        #expect(text.contains("identifier \"com.blamechris.Aeolus\""))
        #expect(text.contains("identifier \"com.blamechris.fanctl\""))
        #expect(text.hasPrefix("anchor apple generic"))
    }

    @Test(
        "A different Team ID produces a different requirement",
        arguments: ClientAuthorisationFixtures.variants
    )
    func teamIdentifierIsLoadBearing(variant: ClientRequirementVariant) throws {
        let ours = try #require(
            ClientRequirementText.build(teamIdentifier: "ABCDE12345", variant: variant)
        )
        let theirs = try #require(
            ClientRequirementText.build(teamIdentifier: "ZZZZZ99999", variant: variant)
        )
        #expect(ours != theirs)
        #expect(!ours.contains("ZZZZZ99999"))
    }

    @Test(
        "Both variants compile as code requirements",
        arguments: ClientAuthorisationFixtures.variants
    )
    func everyVariantCompiles(variant: ClientRequirementVariant) throws {
        let text = try #require(
            ClientRequirementText.build(teamIdentifier: Self.team, variant: variant)
        )
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test("The running process never selects the relaxed variant in a Release build")
    func variantIsAPropertyOfTheBuild() {
        // Mirrors the compile-time selection deliberately: `swift test` only ever builds
        // Debug, so the Release arm is not reachable here. What this pins down is that the
        // selection has no runtime input at all — no argument, no environment, no config.
        #if DEBUG
        #expect(ClientRequirementVariant.forRunningProcess == .debug)
        #expect(ClientRequirementVariant.forRunningProcess.isRelaxedForDevelopment)
        #else
        #expect(ClientRequirementVariant.forRunningProcess == .release)
        #expect(!ClientRequirementVariant.forRunningProcess.isRelaxedForDevelopment)
        #endif
    }
}

/// Team ID validation: the only place a value from outside the builder reaches the
/// requirement string.
@Suite("Client authorisation — Team ID validation")
struct TeamIdentifierValidationTests {

    @Test("A well-formed Team ID is accepted")
    func wellFormedTeamAccepted() {
        let result = ClientRequirementText.validate(teamIdentifier: "ABCDE12345")
        #expect(result == .success("ABCDE12345"))
    }

    @Test("An empty Team ID is refused")
    func emptyTeamRefused() {
        #expect(ClientRequirementText.validate(teamIdentifier: "") == .failure(.empty))
    }

    @Test("An over-long Team ID is refused")
    func overLongTeamRefused() {
        let length = ClientRequirementText.maximumTeamIdentifierLength + 1
        let long = String(repeating: "A", count: length)
        #expect(ClientRequirementText.validate(teamIdentifier: long) == .failure(.tooLong))
    }

    /// Each of these would change what the requirement *means* if it reached the string.
    @Test(
        "A Team ID that could escape its quotes is refused",
        arguments: [
            "AB\"CD",
            "AB\\CD",
            "ABCDE12345\" or anchor apple",
            "AB CD",
            "AB]CD",
            "AB.CD",
            "AB\nCD",
        ]
    )
    func injectionShapedTeamRefused(candidate: String) {
        #expect(
            ClientRequirementText.validate(teamIdentifier: candidate)
                == .failure(.unacceptableCharacters)
        )
        // The assertion that matters: no text is produced at all, in either variant. If
        // validation were ever dropped, these would build a requirement that parses into
        // something other than what the module documents.
        for variant in ClientAuthorisationFixtures.variants {
            let built = ClientRequirementText.build(teamIdentifier: candidate, variant: variant)
            #expect(built == nil)
        }
    }
}
