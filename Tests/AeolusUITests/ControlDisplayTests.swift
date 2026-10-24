import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

@Suite("HelperAuthoredText — the one sanitiser for text the helper sent")
struct HelperAuthoredTextTests {

    /// **Mutation:** in `HelperAuthoredText.sanitised(_:)`, replace the `controlCharacters`
    /// filter's closure with `{ _ in true }`. Run: red at both, and in `aNewlineIsRemoved`.
    @Test("A right-to-left override is removed")
    func aBidiOverrideIsRemoved() {
        let cleaned = HelperAuthoredText.sanitised("fanctl\u{202E}lortnoc")

        #expect(cleaned == "fanctllortnoc")
        #expect(!cleaned.unicodeScalars.contains("\u{202E}"))
    }

    @Test("A newline cannot forge a second line")
    func aNewlineIsRemoved() {
        let cleaned = HelperAuthoredText.sanitised("fanctl\nThermal emergency: not active.")

        #expect(cleaned == "fanctlThermal emergency: not active.")
        #expect(!cleaned.contains("\n"))
    }

    @Test("Nothing printable says so, rather than showing nothing")
    func nothingPrintableSaysSo() {
        #expect(HelperAuthoredText.sanitised("\u{202E}\n \u{200B}") == "(unprintable)")
    }

    @Test("Ordinary text passes unchanged, and long text is capped with an ellipsis")
    func ordinaryTextPassesAndLongTextIsCapped() {
        #expect(HelperAuthoredText.sanitised("fanctl 0.3.0") == "fanctl 0.3.0")

        let capped = HelperAuthoredText.sanitised(String(repeating: "a", count: 500))
        #expect(capped.count == HelperAuthoredText.maxLength)
        #expect(capped.hasSuffix("…"))
    }
}

@Suite("ThermalEmergencyDisplay — on, off and unknown, each drawn its own way")
struct ThermalEmergencyDisplayTests {

    /// **Mutation:** in `ThermalEmergencyDisplay.banner(for:)`, return `nil` for `.unknown` —
    /// unknown drawn as off. Run: red at the distinctness expectations.
    @Test("The three states render three different ways")
    func theThreeStatesRenderDistinctly() {
        let active = ThermalEmergencyDisplay.banner(for: .active)
        let inactive = ThermalEmergencyDisplay.banner(for: .inactive)
        let unknown = ThermalEmergencyDisplay.banner(for: .unknown)

        #expect(active?.severity == .emergency)
        #expect(inactive == nil)
        #expect(unknown?.severity == .unknown)
        #expect(active != unknown)
        #expect(unknown != inactive)
        #expect(active != inactive)
    }

    @Test("Only the emergency names an emergency in force")
    func onlyTheEmergencyNamesOne() throws {
        let active = try #require(ThermalEmergencyDisplay.banner(for: .active))
        let unknown = try #require(ThermalEmergencyDisplay.banner(for: .unknown))

        #expect(active.text.hasPrefix("Thermal emergency reported by the helper"))
        #expect(unknown.text.contains("unknown"))
        #expect(!unknown.text.contains("reported by the helper —"))
        // Neither infers a cause from a lease: § 3's flag can clear before it is read (#476).
        #expect(!active.text.lowercased().contains("lease"))
        #expect(!unknown.text.lowercased().contains("lease"))
    }
}

@Suite("ControlSourceDisplay — whose report the fan rows are")
struct ControlSourceDisplayTests {

    @Test("A listed lease's holder goes through the sanitiser")
    func theHolderIsSanitised() throws {
        let lease = Lease(holderDescription: "fanctl\u{202E}evil\nforged", expiresAt: Date())
        let text = ControlSourceDisplay.text(for: .helperSnapshot(activeLease: lease))
        let detail = try #require(text.detail)

        #expect(detail == "Manual-control lease held by “fanctlevilforged”.")
        #expect(!detail.unicodeScalars.contains("\u{202E}"))
        #expect(!detail.contains("\n"))
    }

    /// No lease listed says nothing about the lease and nothing about a safe state: that
    /// banner is #157's, and needs every fan cleared as well.
    @Test("A snapshot with no lease claims no safe state")
    func noLeaseClaimsNoSafeState() {
        let text = ControlSourceDisplay.text(for: .helperSnapshot(activeLease: nil))

        #expect(text.detail == nil)
        #expect(!text.headline.lowercased().contains("automatic"))
        #expect(!text.headline.lowercased().contains("safe"))
    }

    @Test("The Monitor build's reason is HelperStatusDisplay's own title")
    func theMonitorReasonReusesTheHelperStatusWording() {
        let text = ControlSourceDisplay.text(for: .notTracked(.noHelperInThisBuild))

        #expect(text.headline == "Mode not tracked.")
        #expect(text.detail == HelperStatusDisplay.text(for: .unavailableInThisBuild).title + ".")
    }

    @Test(
        "Every reason nothing is tracked has a sentence",
        arguments: [
            ControlNotTracked.nothingReadYet, .noHelperInThisBuild, .helperInstallIncomplete,
            .helperConnection(.idle), .helperConnection(.handshaken),
            .helperConnection(.unresponsive), .helperConnection(.interrupted),
            .helperConnection(.invalidated), .helperConnection(.refused),
            .helperConnection(.versionMismatched), .awaitingSnapshot,
            .snapshotRequestFailed(detail: "x"), .snapshotStale,
        ])
    func everyReasonHasASentence(_ why: ControlNotTracked) {
        let sentence = ControlSourceDisplay.explanation(why)

        #expect(!sentence.isEmpty)
        #expect(!sentence.lowercased().contains("automatic"))
    }
}
