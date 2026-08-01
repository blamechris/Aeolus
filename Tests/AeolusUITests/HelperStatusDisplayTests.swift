import Foundation
import Testing

@testable import AeolusUI

@Suite("HelperStatusDisplay — say what is true, including when the truth is 'not in this build'")
struct HelperStatusDisplayTests {

    /// Every state the display has to answer for. Kept in one place so the invariant
    /// tests below cover the whole space rather than whichever cases were remembered.
    private static let allStates: [HelperInstallationState] = [
        .unavailableInThisBuild,
        .notRegistered,
        .awaitingApproval,
        .enabled,
        .brokenInstall(.helperExecutableMissing),
        .brokenInstall(.daemonPlistMissing),
        .brokenInstall(.systemCannotFindService),
        .unrecognisedStatus(rawValue: 47),
    ]

    @Test("Every state produces a non-empty title and detail", arguments: Self.allStates)
    func everyStateSaysSomething(state: HelperInstallationState) {
        let text = HelperStatusDisplay.text(for: state)
        #expect(!text.title.isEmpty)
        #expect(!text.detail.isEmpty)
    }

    @Test("No state ever describes the helper as merely 'not running'", arguments: Self.allStates)
    func noStateImpliesAStoppedHelper(state: HelperInstallationState) {
        let text = HelperStatusDisplay.text(for: state)
        let combined = (text.title + " " + text.detail).lowercased()
        #expect(
            !combined.contains("not running"),
            "'Not running' implies a helper that exists and could be started")
    }

    @Test("A Monitor build says it has no helper, and offers nothing to click")
    func monitorBuildIsHonestAndActionless() {
        let text = HelperStatusDisplay.text(for: .unavailableInThisBuild)
        #expect(text.title.lowercased().contains("no privileged helper"))
        #expect(text.detail.contains("cannot change fan speeds"))
        #expect(text.action == nil, "There is nothing in this build to install")
        #expect(text.severity == .normal, "An intentional absence is not a fault")
    }

    @Test("Not registered is the one state that offers to install")
    func notRegisteredOffersRegistration() {
        let text = HelperStatusDisplay.text(for: .notRegistered)
        #expect(text.action == .register)
        #expect(text.severity == .actionNeeded)
    }

    @Test("Awaiting approval names System Settings and says no password prompt is coming")
    func awaitingApprovalExplainsTheStall() {
        let text = HelperStatusDisplay.text(for: .awaitingApproval)
        #expect(text.detail.contains("System Settings"))
        #expect(text.detail.contains("Login Items"))
        #expect(
            text.detail.contains("no password prompt"),
            "A user waiting for a prompt that will never appear is the failure to prevent")
        #expect(text.action == .openLoginItemsSettings)
        #expect(text.severity == .actionNeeded)
    }

    @Test("Enabled describes installation, and never claims fan control")
    func enabledClaimsInstallationOnly() {
        let text = HelperStatusDisplay.text(for: .enabled)
        #expect(text.title.contains("installed and enabled"))
        let combined = (text.title + " " + text.detail).lowercased()
        #expect(!combined.contains("fan control is available"))
        #expect(!combined.contains("you can now"))
        #expect(text.action == .unregister)
        #expect(text.severity == .normal)
    }

    @Test(
        "A broken install says so plainly and never offers a retry",
        arguments: [
            HelperInstallDefect.helperExecutableMissing,
            .daemonPlistMissing,
            .systemCannotFindService,
        ])
    func brokenInstallsAreNotRetried(defect: HelperInstallDefect) {
        let text = HelperStatusDisplay.text(for: .brokenInstall(defect))
        #expect(text.severity == .warning)
        #expect(
            text.action == nil,
            "Nothing here is fixed by asking SMAppService the same question again")
        #expect(text.detail.lowercased().contains("reinstall"))
    }

    @Test("An unrecognised status is reported as unknown, with the raw code")
    func unrecognisedStatusIsReportedAsUnknown() {
        let text = HelperStatusDisplay.text(for: .unrecognisedStatus(rawValue: 47))
        #expect(text.title.lowercased().contains("cannot tell"))
        #expect(text.detail.contains("47"))
        #expect(text.action == nil)
        #expect(text.severity == .warning)
    }
}
