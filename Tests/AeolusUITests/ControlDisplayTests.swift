import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

@Suite("HelperAuthoredText — the one sanitiser for text the helper sent")
struct HelperAuthoredTextTests {

    /// Every scalar in Unicode Cc, Cf, Zl and Zp, found by walking the whole code space — the
    /// class, not a hand-picked few of its members.
    static let removedScalars: [Unicode.Scalar] = (0...0x10FFFF).compactMap { value in
        guard let scalar = Unicode.Scalar(value) else { return nil }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return scalar
        default: return nil
        }
    }

    /// **Mutation (O24):** spare U+2066–2069, U+0085, U+001B and U+FEFF from the filter.
    /// **Mutation (M12):** replace the filter's closure with `{ _ in true }`. Run, each: red,
    /// naming every scalar that survived.
    @Test("No scalar in Cc, Cf, Zl or Zp survives")
    func noRemovedScalarSurvives() {
        #expect(Self.removedScalars.count > 200)
        #expect(Self.removedScalars.contains("\u{2028}"))
        #expect(Self.removedScalars.contains("\u{2029}"))
        var survivors: [String] = []
        for scalar in Self.removedScalars {
            let text = "a" + String(Character(scalar)) + "b"
            if HelperAuthoredText.sanitised(text) != "ab" {
                survivors.append(String(format: "U+%04X", scalar.value))
            }
        }
        #expect(survivors.isEmpty, "survived: \(survivors)")
    }

    @Test("A right-to-left override is removed")
    func aBidiOverrideIsRemoved() {
        let cleaned = HelperAuthoredText.sanitised("fanctl\u{202E}lortnoc")

        #expect(cleaned == "fanctllortnoc")
        #expect(!cleaned.unicodeScalars.contains("\u{202E}"))
    }

    @Test("A newline, a line separator or a paragraph separator cannot forge a second line")
    func noLineBreakSurvives() {
        #expect(HelperAuthoredText.sanitised("fanctl\nforged") == "fanctlforged")
        #expect(HelperAuthoredText.sanitised("fanctl\u{2028}forged") == "fanctlforged")
        #expect(HelperAuthoredText.sanitised("fanctl\u{2029}forged") == "fanctlforged")
    }

    @Test("Nothing printable says so, rather than showing nothing")
    func nothingPrintableSaysSo() {
        #expect(HelperAuthoredText.sanitised("\u{202E}\n \u{200B}") == "(unprintable)")
    }

    /// **Mutation (O9):** `>` becomes `>=` at the character cap. Run: red at the 200-character
    /// expectation.
    @Test("Exactly 200 characters pass unchanged; 201 are cut to 200 with the ellipsis inside")
    func theCharacterCapIsExact() {
        let exact = String(repeating: "a", count: 200)
        #expect(HelperAuthoredText.sanitised(exact) == exact)

        let over = HelperAuthoredText.sanitised(String(repeating: "a", count: 201))
        #expect(over.count == HelperAuthoredText.maxLength)
        #expect(over == String(repeating: "a", count: 199) + "…")
    }

    @Test("The cap bounds bytes as well as characters")
    func theByteCapHolds() {
        // 300 graphemes of 201 scalars each: under the character cap's reading a short string,
        // and about 120 KB.
        let dense = String(repeating: "a" + String(repeating: "\u{0301}", count: 200), count: 300)
        let cleaned = HelperAuthoredText.sanitised(dense)

        #expect(cleaned.utf8.count <= HelperAuthoredText.maxUTF8Bytes)
        #expect(cleaned.hasSuffix("…"))
        #expect(HelperAuthoredText.maxUTF8Bytes == FaultDetailBounds.maxUTF8Bytes)
    }

    @Test("A single grapheme too dense to fit at all reads as unprintable, not as a bare ellipsis")
    func aGraphemeTooDenseToFitIsUnprintable() {
        let one = "a" + String(repeating: "\u{0301}", count: 1_000)
        #expect(HelperAuthoredText.sanitised(one) == "(unprintable)")
    }

    @Test("Ordinary text passes unchanged")
    func ordinaryTextPasses() {
        #expect(HelperAuthoredText.sanitised("fanctl 0.3.0") == "fanctl 0.3.0")
    }

    @Test("A key is shown verbatim only if nothing in it would be removed and it fits the caps")
    func verbatimKeys() {
        #expect(HelperAuthoredText.isDisplayableVerbatim("TC0P"))
        #expect(HelperAuthoredText.isDisplayableVerbatim("TA0 "))
        #expect(!HelperAuthoredText.isDisplayableVerbatim(""))
        #expect(!HelperAuthoredText.isDisplayableVerbatim("T\u{202E}0P"))
        #expect(!HelperAuthoredText.isDisplayableVerbatim("T\n0P"))
        #expect(!HelperAuthoredText.isDisplayableVerbatim("T\u{2028}0P"))
        #expect(!HelperAuthoredText.isDisplayableVerbatim(String(repeating: "a", count: 201)))
    }
}

@Suite("ThermalEmergencyDisplay — on, off and unknown, each drawn its own way")
struct ThermalEmergencyDisplayTests {

    static let monitor = ControlSource.notTracked(.noHelperInThisBuild)

    /// **Mutation (M7b):** in `ThermalEmergencyDisplay.banner(for:source:)`, return `nil` for
    /// `.unknown` — unknown drawn as off. Run: red at the distinctness expectations.
    @Test("The three states render three different ways")
    func theThreeStatesRenderDistinctly() {
        let active = ThermalEmergencyDisplay.banner(for: .active, source: Self.monitor)
        let inactive = ThermalEmergencyDisplay.banner(for: .inactive, source: Self.monitor)
        let unknown = ThermalEmergencyDisplay.banner(for: .unknown, source: Self.monitor)

        #expect(active?.severity == .emergency)
        #expect(inactive == nil)
        #expect(unknown?.severity == .unknown)
        #expect(active != unknown)
        #expect(unknown != inactive)
        #expect(active != inactive)
    }

    /// **Mutation (U1):** in `unknown(because:)`, return the reason-free sentence for every
    /// case. Run: red at both expectations.
    @Test("Unknown says why: a build with no helper, or what the helper is doing")
    func unknownSaysWhy() throws {
        let monitor = try #require(
            ThermalEmergencyDisplay.banner(for: .unknown, source: Self.monitor))
        #expect(
            monitor.text
                == "Thermal emergency: unknown — this build ships no privileged helper, so it "
                + "cannot see one.")

        let wedged = try #require(
            ThermalEmergencyDisplay.banner(
                for: .unknown, source: .notTracked(.helperConnection(.unresponsive))))
        #expect(wedged.text == "Thermal emergency: unknown. The helper stopped answering.")
    }

    @Test("Only the emergency names an emergency in force")
    func onlyTheEmergencyNamesOne() throws {
        let active = try #require(
            ThermalEmergencyDisplay.banner(for: .active, source: Self.monitor))
        let unknown = try #require(
            ThermalEmergencyDisplay.banner(for: .unknown, source: Self.monitor))

        #expect(active.text.hasPrefix("Thermal emergency reported by the helper"))
        #expect(unknown.text.contains("unknown"))
        #expect(!unknown.text.contains("reported by the helper"))
        // Neither infers a cause from a lease: § 3's flag can clear before it is read (#476).
        #expect(!active.text.lowercased().contains("lease"))
        #expect(!unknown.text.lowercased().contains("lease"))
    }
}

@Suite("ControlSourceDisplay — whose report the fan rows are")
struct ControlSourceDisplayTests {

    @Test("A listed lease's holder goes through the sanitiser")
    func theHolderIsSanitised() throws {
        let lease = Lease(
            holderDescription: "fanctl\u{202E}evil\nforged\u{2028}twice", expiresAt: Date())
        let text = ControlSourceDisplay.text(for: .helperSnapshot(activeLease: lease))
        let detail = try #require(text.detail)

        #expect(detail == "Manual-control lease held by “fanctlevilforgedtwice”.")
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

    @Test("A damaged bundle's reason is HelperStatusDisplay's title, which both defects share")
    func theDamagedReasonReusesTheHelperStatusWording() {
        let missingExecutable = HelperStatusDisplay.text(
            for: .brokenInstall(.helperExecutableMissing)
        ).title
        let missingPlist = HelperStatusDisplay.text(for: .brokenInstall(.daemonPlistMissing)).title
        #expect(missingExecutable == missingPlist)
        #expect(
            ControlSourceDisplay.explanation(.helperInstallIncomplete)
                == "This copy of Aeolus is damaged, so it does not talk to its helper.")
    }

    /// Each connection state's sentence, written out here by hand, so two of them swapping
    /// places in `ControlSourceDisplay` is a disagreement and not a pass. Every state comes
    /// from `HealthTag`, which is exhaustive over the client's enum.
    ///
    /// **Mutation (O8):** swap the `.unresponsive` and `.interrupted` sentences. Run: red for
    /// both.
    @Test("Each connection state says its own sentence", arguments: HealthTag.all)
    func eachConnectionStateSaysItsOwnSentence(_ health: HelperConnectionHealth) {
        let expected: String
        switch HealthTag(health) {
        case .idle: expected = "Aeolus has not connected to its helper yet."
        case .handshaken:
            expected = "Aeolus is connected to its helper and has no current snapshot from it."
        case .unresponsive: expected = "The helper stopped answering."
        case .interrupted: expected = "The helper process went away."
        case .invalidated:
            expected =
                "Aeolus cannot reach its helper: it may not be installed or approved yet, or it "
                + "refused this copy of Aeolus."
        case .refused: expected = "Aeolus and its helper would not agree to talk."
        case .versionMismatched:
            expected = "This copy of Aeolus and its helper speak different protocol versions."
        }
        #expect(ControlSourceDisplay.explanation(.helperConnection(health)) == expected)
    }

    @Test("A self-contradicting snapshot says the app refused it, not that a request failed")
    func aContradictionIsARefusal() {
        let why = ControlNotTracked.snapshotContradicted(detail: "it lists fan 0 twice")
        #expect(
            ControlSourceDisplay.explanation(why)
                == "The helper's last snapshot contradicted itself (it lists fan 0 twice), "
                + "so it is not shown.")
    }

    /// One tag per `ControlNotTracked` case, exhaustive and with no `default:`, so a reason
    /// added to the vocabulary does not compile here until it is listed — and so is rendered.
    enum ReasonTag: CaseIterable {
        case nothingReadYet, noHelperInThisBuild, helperInstallIncomplete, helperConnection
        case awaitingSnapshot, snapshotRequestFailed, snapshotContradicted, snapshotStale

        init(_ why: ControlNotTracked) {
            switch why {
            case .nothingReadYet: self = .nothingReadYet
            case .noHelperInThisBuild: self = .noHelperInThisBuild
            case .helperInstallIncomplete: self = .helperInstallIncomplete
            case .helperConnection: self = .helperConnection
            case .awaitingSnapshot: self = .awaitingSnapshot
            case .snapshotRequestFailed: self = .snapshotRequestFailed
            case .snapshotContradicted: self = .snapshotContradicted
            case .snapshotStale: self = .snapshotStale
            }
        }

        /// Every reason this tag stands for — one per connection state for `helperConnection`.
        var reasons: [ControlNotTracked] {
            switch self {
            case .nothingReadYet: return [.nothingReadYet]
            case .noHelperInThisBuild: return [.noHelperInThisBuild]
            case .helperInstallIncomplete: return [.helperInstallIncomplete]
            case .helperConnection: return HealthTag.all.map { .helperConnection($0) }
            case .awaitingSnapshot: return [.awaitingSnapshot]
            case .snapshotRequestFailed: return [.snapshotRequestFailed(detail: "x")]
            case .snapshotContradicted: return [.snapshotContradicted(detail: "x")]
            case .snapshotStale: return [.snapshotStale]
            }
        }
    }

    static let everyReason = ReasonTag.allCases.flatMap(\.reasons)

    @Test("Every reason nothing is tracked has its own sentence, and none says automatic")
    func everyReasonHasASentence() {
        let sentences = Self.everyReason.map(ControlSourceDisplay.explanation)
        for (why, sentence) in zip(Self.everyReason, sentences) {
            #expect(ReasonTag(why).reasons.contains(why))
            #expect(!sentence.isEmpty, "\(why)")
            #expect(!sentence.lowercased().contains("automatic"), "\(why)")
        }
        #expect(Set(sentences).count == sentences.count, "two reasons share a sentence")
    }
}
