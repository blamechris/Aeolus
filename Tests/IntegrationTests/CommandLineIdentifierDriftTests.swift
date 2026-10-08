import Foundation
import Testing

@testable import AeolusXPC

/// The helper admits `fanctl` by code-signing identifier, and the identifier lives in two
/// places that nothing links at compile time: `AeolusClientIdentifier.commandLine`, which the
/// helper's client requirement is built from, and the `fanctl` target in `project.yml`, which
/// is the only thing in the tree that produces a binary carrying it.
///
/// A drift between them is silent in the worst way, and the same way the helper's identifier
/// drift is (`HelperIdentifierDriftTests`): the app still builds, `fanctl` still runs and
/// still reads the SMC, and the one command that matters when a fan is wrong —
/// `fanctl reset --all` — is refused by the helper. From the client's side that refusal is
/// indistinguishable from "no helper installed" (docs/RECOVERY.md), so the user reads it as
/// "Aeolus is not running" and reaches for step 5.
///
/// These tests hold the source side. They cannot establish what the *built* binary is
/// signed with — `codesign` has to see that, and CI's "Assert the embedded fanctl carries the
/// identifier the helper pins" step does. They also cannot establish that an installed helper
/// admits a Developer ID `fanctl` and refuses an ad-hoc one; that is E2.5's manual check on
/// the signed Full build, on `Mac16,5`.
@Suite("Command-line client — the identifier matches the build definition")
struct CommandLineIdentifierDriftTests {

    @Test("The pinned identifier is fanctl's PRODUCT_BUNDLE_IDENTIFIER")
    func productBundleIdentifierMatches() throws {
        let target = try ProjectTarget.load("fanctl")
        let declared = try target.value(of: "PRODUCT_BUNDLE_IDENTIFIER")
        #expect(declared == AeolusClientIdentifier.commandLine)
    }

    /// Compared against the requirement the helper actually builds, not only against the
    /// constant it is built from. The constant is the obvious thing to hold equal, and a
    /// requirement builder that stopped using it — a second literal, a renamed case — would
    /// leave the constant and `project.yml` agreeing about an identifier the helper no longer
    /// names.
    @Test(
        "The helper's client requirement names the identifier project.yml gives fanctl",
        arguments: ClientAuthorisationFixtures.variants
    )
    func requirementNamesTheDeclaredIdentifier(variant: ClientRequirementVariant) throws {
        let declared = try ProjectTarget.load("fanctl").value(of: "PRODUCT_BUNDLE_IDENTIFIER")
        let text = try ClientAuthorisationFixtures.text(variant: variant)
        #expect(text.contains("identifier \"\(declared)\""))
    }

    /// The identifier is declared once. The embedded Info.plist takes its `CFBundleIdentifier`
    /// from the build setting by reference rather than restating it, so there is no second
    /// literal that could win over the first when `codesign` picks an identifier. A literal
    /// here that equals the setting would pass a weaker test and still be a second copy; the
    /// reference is what rules the second copy out.
    @Test("The embedded Info.plist takes its identifier from the build setting")
    func infoPlistReferencesTheBuildSetting() throws {
        let target = try ProjectTarget.load("fanctl")
        let declared = try target.value(of: "CFBundleIdentifier")
        #expect(declared == "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }

    /// Without the embedded plist, `codesign` names a bare Mach-O after its file — `fanctl`,
    /// which the helper refuses. This is the setting that makes the identifier above reach
    /// the signature at all.
    @Test("The Info.plist is embedded in the binary, where codesign reads it")
    func infoPlistIsEmbeddedInTheBinary() throws {
        let target = try ProjectTarget.load("fanctl")
        let declared = try target.value(of: "CREATE_INFOPLIST_SECTION_IN_BINARY")
        #expect(declared == "YES")
    }
}
