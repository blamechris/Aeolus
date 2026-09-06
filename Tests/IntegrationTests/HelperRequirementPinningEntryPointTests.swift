import Foundation
import Security
import Testing

@testable import AeolusXPC

/// The three things #220's review found asserted by nothing: the specification the mirror
/// requirement is built against, the production entry point's own choices, and the refusal
/// rows a client renders when it will not connect.
///
/// Separate from `HelperRequirementTextTests` because that file is at its size and these are
/// a different kind of test: those check a pure builder against literals, these check the
/// impure entry point and the document it answers to.
enum HelperPinningFixtures {

    /// A Team ID shaped like Apple's, belonging to nobody. The same value the sibling
    /// suites use, read from their fixture rather than restated, so a change there cannot
    /// leave two different fake teams in the tree.
    static let team = ClientAuthorisationFixtures.team

    /// Every `HelperPinningRefusal` case, with each `TeamIdentifierRejection` spelled out.
    ///
    /// Mirrors `ClientAuthorisationFixtures.refusals`, and exists for the same reason: a
    /// refusal a client cannot render is a refusal the user sees as "Aeolus does nothing".
    /// Kept here rather than added to `ClientAuthorisationFixtures`, which another in-flight
    /// change owns.
    static let refusals: [HelperPinningRefusal] = [
        .runningProcessHasNoTeamIdentifier,
        .selfInspectionFailed(errSecCSUnsigned),
        .teamIdentifierNotWellFormed(.empty),
        .teamIdentifierNotWellFormed(.unacceptableCharacters),
        .teamIdentifierNotWellFormed(.tooLong),
        .requirementDidNotCompile(errSecCSReqInvalid),
        .negativeControlUnavailable(errSecCSStaticCodeNotFound),
        .negativeControlAdmittedForeignCode,
    ]
}

/// The requirement text checked against the document that specifies it, rather than against
/// a literal transcribed from the implementation in the same commit.
///
/// #220's review made the case precisely: an exact-match test written from the code defends
/// against later drift and could never have caught a requirement that was wrong on day one —
/// had the `!entitlement` clause been missing from the builder, the expected literal would
/// have been written without it too and every test would have been green. ADR 0005 now
/// carries the clause list (its "client-side mirror, clause by clause" section, #158/D26),
/// and this suite is what makes citing it more than a claim.
///
/// The join is the one thing this suite contributes: the ADR lists the clauses one per line,
/// in the order the builder emits them, and these tests join them with the separator the
/// builder uses. That separator is asserted by the exact-match tests next door.
@Suite("Helper pinning — the requirement matches ADR 0005's specification")
struct HelperMirrorSpecificationTests {

    /// The placeholder the ADR uses where the client's own Team ID goes.
    static let placeholder = "TEAMID"

    static let releaseMarker = "<!-- helper-requirement:release -->"
    static let debugMarker = "<!-- helper-requirement:debug -->"

    private static var adr: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/IntegrationTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repository root
            let document =
                root
                .appendingPathComponent("docs/ADR/0005-xpc-authorisation.md")
            return try String(contentsOf: document, encoding: .utf8)
        }
    }

    /// Why a scan of the ADR produced no requirement.
    ///
    /// Every one of these is thrown rather than shrugged off with an empty result, because
    /// the failure this suite is most likely to suffer is the specification being moved or
    /// reformatted — and an empty clause list would make the comparisons below pass against
    /// an empty requirement, which is exactly the vacuous shape the suite exists to rule
    /// out. The five tests at the end of this suite are the ones that prove that: they run
    /// the scan against documents damaged in each of these four ways — `blockMalformed`
    /// gets two, since "no fence at all" and "a neighbour's fence read as this marker's"
    /// are distinct failures that a single guard must catch both of.
    enum SpecificationScanFailure: Error, Equatable {
        /// ADR 0005 carries no such marker: the specification is gone or was renamed.
        case markerAbsent(String)
        /// The marker is there but no fenced block follows it, or it is never closed.
        case blockMalformed(String)
        /// The block exists and lists nothing.
        case blockListsNoClauses(String)
        /// The block names no Team ID placeholder, so it pins no team.
        case blockPinsNoTeam(String)
    }

    /// The clauses of one variant, read out of the fenced block that follows its marker and
    /// joined with the separator the builder uses.
    static func specifiedText(marker: String, in document: String) throws -> String {
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        guard
            let markerIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == marker
            })
        else {
            throw SpecificationScanFailure.markerAbsent(marker)
        }
        let afterMarker = lines[lines.index(after: markerIndex)...]
        // Bounded to the few lines immediately after the marker, not the rest of the
        // document: an unbounded search finds a *neighbour's* fence when the marker's own
        // block is deleted, and reads that neighbour's content as if it were this variant's
        // — the downstream-guard-masks-upstream shape #220's delta review named. The ADR's
        // own layout is marker, one blank line, opening fence; four lines of slack is
        // generous without reaching into the next variant's block.
        let searchWindow = afterMarker.prefix(4)
        guard let openIndex = searchWindow.firstIndex(where: { $0.hasPrefix("```") }) else {
            throw SpecificationScanFailure.blockMalformed(marker)
        }
        let body = lines[lines.index(after: openIndex)...]
        guard let closeIndex = body.firstIndex(where: { $0.hasPrefix("```") }) else {
            throw SpecificationScanFailure.blockMalformed(marker)
        }
        let clauses =
            body[..<closeIndex]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else {
            throw SpecificationScanFailure.blockListsNoClauses(marker)
        }
        let joined = clauses.joined(separator: " and ")
        guard joined.contains(placeholder) else {
            throw SpecificationScanFailure.blockPinsNoTeam(marker)
        }
        return joined.replacingOccurrences(of: placeholder, with: HelperPinningFixtures.team)
    }

    @Test("The Release requirement is the one ADR 0005 lists, clause for clause and in order")
    func releaseMatchesTheSpecification() throws {
        let specified = try Self.specifiedText(
            marker: Self.releaseMarker, in: try Self.adr
        )
        let built = try HelperRequirementText.build(
            teamIdentifier: HelperPinningFixtures.team, variant: .release
        ).get()
        #expect(built == specified)
    }

    @Test("The Debug requirement is the one ADR 0005 lists, clause for clause and in order")
    func debugMatchesTheSpecification() throws {
        let specified = try Self.specifiedText(
            marker: Self.debugMarker, in: try Self.adr
        )
        let built = try HelperRequirementText.build(
            teamIdentifier: HelperPinningFixtures.team, variant: .debug
        ).get()
        #expect(built == specified)
    }

    /// The tripwire's own condition, which is a guard and therefore needs its own mutation.
    ///
    /// A scanner that silently found nothing would report the two tests above as passing
    /// while asserting nothing whatever, and no mutation of the *builder* could reveal that:
    /// an empty specification equals an empty requirement only when both sides are empty,
    /// and the comparison never runs. So the damaged documents are supplied here directly.
    @Test("A specification with no marker fails the scan rather than passing it vacuously")
    func aMissingMarkerIsAFailure() {
        #expect(throws: SpecificationScanFailure.markerAbsent(Self.releaseMarker)) {
            try Self.specifiedText(
                marker: Self.releaseMarker,
                in: "# An ADR that says nothing about the mirror\n"
            )
        }
    }

    /// The one failure mode `SpecificationScanFailure` names that had no test until #220's
    /// delta review: a marker with no fenced block after it at all, rather than one that is
    /// merely empty.
    @Test("A marker with no fenced block anywhere after it fails the scan")
    func aMissingFencedBlockIsAFailure() {
        #expect(throws: SpecificationScanFailure.blockMalformed(Self.releaseMarker)) {
            try Self.specifiedText(
                marker: Self.releaseMarker,
                in: "\(Self.releaseMarker)\n\nno fence follows this marker at all.\n"
            )
        }
    }

    /// The scenario the delta review's evidence actually described: a marker whose own
    /// fenced block was deleted, with a *different* variant's block sitting later in the
    /// same document. An unbounded forward search for the opening fence treats that later
    /// block as if it belonged to this marker and reads its content as the specification —
    /// the downstream-guard-masks-upstream shape, because `blockListsNoClauses` and
    /// `blockPinsNoTeam` both still have something non-vacuous to fire on or pass, and
    /// nothing ever reports that the fence belongs to a different marker entirely.
    ///
    /// **Mutation:** replace `searchWindow` with `afterMarker` (drop the `.prefix(4)`
    /// bound) in `specifiedText`. Run: red — `\(Self.debugMarker)`'s block below is found
    /// and read as this marker's, and the call returns successfully instead of throwing.
    @Test("A deleted block does not silently borrow a later marker's fence")
    func aDeletedBlockDoesNotBorrowALaterMarkersFence() {
        let document = [
            Self.releaseMarker,
            "",
            "the block that used to follow this marker is gone; only prose remains",
            "here, spanning several lines, so nothing found from here on is this",
            "variant's own fenced block, only a neighbour's borrowed by mistake",
            "",
            Self.debugMarker,
            "",
            "```text",
            "certificate leaf[subject.OU] = \"\(Self.placeholder)\"",
            "```",
        ].joined(separator: "\n")

        #expect(throws: SpecificationScanFailure.blockMalformed(Self.releaseMarker)) {
            try Self.specifiedText(marker: Self.releaseMarker, in: document)
        }
    }

    @Test("A marker followed by an empty block fails the scan")
    func anEmptyBlockIsAFailure() {
        #expect(throws: SpecificationScanFailure.blockListsNoClauses(Self.releaseMarker)) {
            try Self.specifiedText(
                marker: Self.releaseMarker,
                in: "\(Self.releaseMarker)\n\n```text\n\n```\n"
            )
        }
    }

    @Test("A block that names no team placeholder fails the scan")
    func aBlockWithNoTeamIsAFailure() {
        #expect(throws: SpecificationScanFailure.blockPinsNoTeam(Self.releaseMarker)) {
            try Self.specifiedText(
                marker: Self.releaseMarker,
                in: "\(Self.releaseMarker)\n\n```text\nanchor apple generic\n```\n"
            )
        }
    }
}

/// The production entry point's own choices — the variant it selects and the negative
/// control it uses — and the refusal rows that reach a user.
///
/// These need the injection seam `HelperRequirementPinning.resolveForRunningProcess(
/// inspection:)`, added in #220's review round. Without it the entry point's success path is
/// unreachable from every test: under `swift test` the host is always ad-hoc signed, so
/// control leaves at the `.noTeamIdentifier` row and the lines below it never execute. The
/// review measured that by mutating `variant: .forRunningProcess` to `.debug` and watching
/// the whole suite stay green, in Debug and in Release.
@Suite("Helper pinning — the production entry point")
struct HelperPinningEntryPointTests {

    private static let team = HelperPinningFixtures.team

    /// The injected inspection is the *only* thing this fabricates. Everything after it —
    /// the variant, the requirement text, the compile, the negative control — is the
    /// production path, which is the point: the assertion is about what the entry point
    /// chooses, not about what a test can arrange.
    @Test("The entry point pins the variant this build ships, and no other")
    func theProductionEntryPointSelectsTheBuildVariant() throws {
        let sealed = try HelperRequirementPinning.resolveForRunningProcess(
            inspection: .teamIdentifier(Self.team)
        ).get()

        #expect(sealed.teamIdentifier == Self.team)
        #expect(sealed.text.contains("certificate leaf[subject.OU] = \"\(Self.team)\""))
        #expect(
            sealed.isRelaxedForDevelopment
                == ClientRequirementVariant.forRunningProcess.isRelaxedForDevelopment
        )
        #expect(
            sealed.text
                == (try HelperRequirementText.build(
                    teamIdentifier: Self.team, variant: .forRunningProcess
                ).get())
        )

        // Both arms are asserted, and only the build decides which one runs — the same
        // shape `ClientRequirementTextTests` uses for the property itself. A Debug-only
        // run cannot see a Release client pinning the relaxed requirement, which is what
        // CI's `swift test -c release -Xswiftc -enable-testing` step is for.
        #if DEBUG
        #expect(sealed.isRelaxedForDevelopment)
        #else
        #expect(!sealed.isRelaxedForDevelopment)
        #expect(
            sealed.text.contains("!entitlement[\"\(ClientRequirementText.debuggableEntitlement)\"]")
        )
        // The Apple Development leaf OID. A Release client admitting it would be pinning a
        // locally built, debuggable root daemon.
        #expect(!sealed.text.contains("1.2.840.113635.100.6.1.12"))
        #endif
    }

    /// Row 1 of the fail-closed table, driven by argument rather than by the host, so it is
    /// asserted on a signed machine too.
    @Test("A process with no Team ID refuses to pin")
    func noTeamIdentifierRefusesToPin() {
        let outcome = HelperRequirementPinning.resolveForRunningProcess(
            inspection: .noTeamIdentifier
        )
        #expect(outcome == .failure(.runningProcessHasNoTeamIdentifier))
    }

    /// "We failed to look" is not "there is nothing to see", and the two must not collapse
    /// into one message. Telling a user their build carries no Team ID when the truth is
    /// that Security refused to describe the process at all is `CLAUDE.md` rule 6 — a
    /// refusal reporting a state it never confirmed — in the one string they will read when
    /// the app will not talk to the daemon.
    @Test("An unreadable signature refuses as an inspection failure, not as a missing team")
    func inspectionFailureIsNotReportedAsAMissingTeam() {
        let outcome = HelperRequirementPinning.resolveForRunningProcess(
            inspection: .inspectionFailed(errSecCSUnsigned)
        )
        #expect(outcome == .failure(.selfInspectionFailed(errSecCSUnsigned)))
        #expect(outcome != .failure(.runningProcessHasNoTeamIdentifier))

        let refusal = HelperPinningRefusal.selfInspectionFailed(errSecCSUnsigned)
        #expect(refusal.description.contains("\(errSecCSUnsigned)"))
        #expect(!refusal.description.contains("no Team ID"))
    }

    /// A refusal a client cannot render is a refusal the user experiences as nothing
    /// happening. `.description` is public for that reason, and every row is checked
    /// because the rows that are hardest to reach are the ones most likely to be wrong.
    @Test(
        "Every refusal describes itself for the log and for the user",
        arguments: HelperPinningFixtures.refusals
    )
    func everyRefusalHasADescription(refusal: HelperPinningRefusal) {
        #expect(!refusal.description.isEmpty)
        #expect(!refusal.description.contains("HelperPinningRefusal"))
    }

    /// The fixture list above is hand-written, so nothing stops a seventh case from being
    /// added and never described. This is the cheapest guard that notices: the six cases are
    /// spelled out here, and a new one makes this switch fail to compile.
    @Test("The fixture list covers every refusal case")
    func fixturesCoverEveryCase() {
        for refusal in HelperPinningFixtures.refusals {
            switch refusal {
            case .runningProcessHasNoTeamIdentifier,
                .selfInspectionFailed,
                .teamIdentifierNotWellFormed,
                .requirementDidNotCompile,
                .negativeControlUnavailable,
                .negativeControlAdmittedForeignCode:
                continue
            }
        }
        #expect(Set(HelperPinningFixtures.refusals).count == HelperPinningFixtures.refusals.count)
        #expect(
            Set(HelperPinningFixtures.refusals.map(\.description)).count
                == HelperPinningFixtures.refusals.count,
            "two refusals describe themselves identically, so a log line cannot tell them apart"
        )
    }
}
