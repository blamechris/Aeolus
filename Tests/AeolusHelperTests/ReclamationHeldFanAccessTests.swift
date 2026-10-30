import Foundation
import Testing

/// `ReclamationWatchdog.HeldFan`'s members, held to the access they are written with, asserted
/// rather than described ([#610](https://github.com/blamechris/Aeolus/issues/610)).
///
/// ## Why this suite exists
///
/// `HeldFan` keeps what § 5 knows about one fan, and `commanded` is the step it last put on the
/// wire, which the watchdog's re-assert writes back to the firmware. `commanded` is `private(set)`
/// so that its one writer, `record(_:)`, is also the one place that holds the floor check
/// (`rpm.isFinite && rpm >= FanSafetyLimits.minimumManualRPM`): a bare `var` would let another file
/// in the module assign a target no permit could produce, past that check.
///
/// No suite read it. `HeldFan` is a struct nested in `extension ReclamationWatchdog`, so its
/// members sit at eight spaces and `MemberAccessScan` reads four. On #609, `commanded` respelled
/// as a bare `var` left all 1,642 `AeolusHelperTests` green. The file is read here with one
/// indent level removed (`MemberAccessScan.outdentedSource(of:)`, which
/// `ReclamationRegistryAccessTests` and `LeaseAuthorityRegistersAccessTests` read their own
/// nested types through), which puts `HeldFan`'s members at four.
///
/// ## What is compared
///
/// Every member of `HeldFan` is internal; `private(set)` counts as internal, because the getter
/// is. So the whole record is the population, and it is compared **as spelled**
/// ([#607](https://github.com/blamechris/Aeolus/issues/607)): `private(set) var commanded` is a
/// different string from `var commanded`, and `public`, `package` or any other modifier on an
/// acknowledged member is red like a new member. Nothing is stored privately, so there is no
/// second list of stores as there is for `Registry`.
///
/// ## What this does not reach
///
/// - **A member in the formatter's two-line spelling** (a modifier alone on a line, the
///   declaration under it at twelve spaces in the source, eight once the level is removed) is in
///   no population, whether new or already there
///   ([#605](https://github.com/blamechris/Aeolus/issues/605)). An acknowledged member written
///   so goes missing and is red; a new one is seen by nothing here.
/// - **An initialiser or a subscript** is read by no population in this repository: the scan
///   reads `let`, `var` and `func`. A second `init` that took a `commanded` would be a route to
///   the field that this suite does not see.
/// - **The bodies of the acknowledged methods** (inferred, not run). The entries say which
///   methods exist, not what they assign: `judge(_:)` edited to assign `commanded`, or a local
///   function in one, leaves every entry as it was. That `record(_:)` is the only writer is a
///   sentence in the source, and nothing here.
/// - **A key path** (inferred from #456's finding on `Request`, not run here): a `private(set)`
///   setter can be reached through a dynamic cast of a key path to `WritableKeyPath` (SR-5218),
///   from any file.
/// - **`HeldFan`'s own declaration and its sibling's.** `struct HeldFan` and `enum Judgement` are
///   read by no suite. Their access is capped by the actor, so a widened header matters only
///   after the headers `HelperActorHeaderAccessTests` pins have been widened; measured:
///   `public struct HeldFan` compiles and leaves the access suites green. `Judgement` has only
///   cases, and a member added to it is read here as `HeldFan`'s and is red as an unacknowledged
///   one.
///
/// What this does hold is every way in that needs no edit to an existing body: a bare `var`, a
/// new member of a kind the scan reads, a binding list, a second declaration of `HeldFan`, and a
/// type nested in the record or a second extension in its file (`noTypeIsNestedInHeldFan`).
@Suite("§ 5's per-fan record keeps its commanded target's setter private")
struct ReclamationHeldFanAccessTests {

    private static let heldFanType = "HeldFan"
    private static let heldFanFile = "ReclamationHeldFan.swift"
    private static let helperTarget = "AeolusHelper"

    /// Every property of `HeldFan`, **as spelled**. `commanded` is the one with a modifier: its
    /// setter is private and its getter is not, and the entry says so. The rest are counters and
    /// stamps the record moves itself, and the lease it was registered under.
    private static let acknowledgedProperties: Set<String> = [
        "let lease",
        "private(set) var commanded",
        "var consecutiveReadFailures",
        "var actualDwellCycles",
        "var reassertAttempts",
        "var episodeInFlight",
        "var examinedAtGeneration",
        "var examinedInBound",
        "var uncommandedDivergentCycles",
    ]

    /// The type declarations in the file, in source order: the extension everything sits in, the
    /// record, and `Judgement`, which is `HeldFan`'s sibling and not nested in it.
    private static let acknowledgedTypeDeclarations = [
        "extension ReclamationWatchdog", "struct HeldFan", "enum Judgement",
    ]

    /// Every method of `HeldFan`, **as spelled**. `mutating` is part of an entry, so a method that
    /// starts to mutate, or stops, is red. `record(_:)` is the one writer of `commanded`, and
    /// `command(_:)` goes through it.
    private static let acknowledgedMethods: Set<String> = [
        "mutating func refundReassertAttempt()",
        "static func registering(_: UUID, over: HeldFan?)",
        "mutating func beginExamination(atGeneration: UInt64, inBound: Bool)",
        "mutating func record(_: CommandedTarget)",
        "mutating func command(_: CommandedTarget)",
        "mutating func recordReadFailure()",
        "mutating func judge(_: FanControlState)",
    ]

    /// **Mutation:** declare `struct HeldFan {}` in a file of its own, inside another type. Run:
    /// red here, naming both files.
    @Test("HeldFan is declared in the one file this suite reads")
    func heldFanIsDeclaredWhereThisSuiteReads() throws {
        let sites = try MemberAccessScan.filesDeclaring(
            Self.heldFanType, inTarget: Self.helperTarget)

        #expect(
            sites.declarations == [Self.heldFanFile],
            """
            \(Self.heldFanType) is declared in \(sites.declarations), and this suite reads \
            \(Self.heldFanFile). A second declaration is a record whose members nothing here \
            compares; a moved one leaves this suite reading a file that no longer holds it.
            """
        )
    }

    /// **Mutations:** respell `private(set) var commanded` as `var commanded`. Respell `let lease`
    /// as `public let lease`. Add `var leak = 0`. Put `public` alone on the line above
    /// `private(set) var commanded`. Add a computed property to `Judgement`. Run: red on each, at
    /// the comparison.
    @Test("Only the acknowledged properties of HeldFan exist, as spelled")
    func onlyTheAcknowledgedPropertiesExist() throws {
        let found = try Self.nonPrivateSpellings(keyword: .property)

        #expect(
            found == Self.acknowledgedProperties,
            """
            the properties of HeldFan changed, as spelled: \
            \(MemberAccessScan.difference(found, Self.acknowledgedProperties)). `commanded` is \
            written only by `record(_:)`, which holds the floor check, and a bare `var` lets \
            any file in AeolusHelper assign past it. Say why here, and re-state the entry as it \
            is now written.
            """
        )
    }

    /// **Mutations:** respell `mutating func record(_ target: CommandedTarget)` with `public` in
    /// front. Add `mutating func force(_ target: CommandedTarget) { commanded = target }`. Run:
    /// red on each, at the comparison.
    @Test("Only the acknowledged methods of HeldFan exist, as spelled")
    func onlyTheAcknowledgedMethodsExist() throws {
        let found = try Self.nonPrivateSpellings(keyword: .method)

        #expect(
            found == Self.acknowledgedMethods,
            """
            the methods of HeldFan changed, as spelled: \
            \(MemberAccessScan.difference(found, Self.acknowledgedMethods)). A method of the \
            record can write `commanded` without `record(_:)`'s check; say why here, and \
            re-state the entry as it is now written.
            """
        )
    }

    /// `MemberAccessScan` keys a declaration on its first name, so a tuple pattern or a comma list
    /// adds a member the two exact lists above would miss. Asserted absent, as the sibling suites
    /// do, rather than parsed.
    ///
    /// **Mutation:** add `var (leakA, leakB) = (0, 0)` to `HeldFan`. Run: red here.
    @Test("Every declaration the exact lists read binds exactly one name")
    func everyDeclarationBindsOneName() throws {
        let found = MemberAccessScan.multipleBindings(
            inSource: try MemberAccessScan.outdentedSource(of: Self.heldFanFile))

        #expect(
            found.isEmpty,
            """
            these declarations bind more than one name: \(found). The access scan reads only the \
            first, so the rest are members nothing here acknowledges. Write one per line.
            """
        )
    }

    /// Nothing is nested in `HeldFan`. A type declared inside its body can write `commanded`: the
    /// setter is `private`, and a nested type is inside the scope `private` names, so `enum
    /// Backdoor { static func force(_ fan: inout HeldFan, to target: CommandedTarget) {
    /// fan.commanded = target } }` compiles, passes `swift format lint --strict`, and sits at a
    /// depth the member scan does not read. So the type declarations in the file are listed:
    /// the extension, the record and `Judgement`, in source order, as `kind Name`. The match is
    /// on the keyword and the name wherever it stands, so a nested type in any spelling is a
    /// third entry, and a second `extension` (`extension ReclamationWatchdog.HeldFan`, whose
    /// `private` reaches the setter from the same file) is a fourth.
    ///
    /// **Mutation:** add `enum Backdoor { static func force(_ fan: inout HeldFan, to target:
    /// CommandedTarget) { fan.commanded = target } }` to `HeldFan`'s body. Run: red here.
    @Test("No type is declared in the per-fan record's file beyond the three it holds")
    func noTypeIsNestedInHeldFan() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.heldFanFile)
        let declaration = try NSRegularExpression(
            pattern: #"\b(actor|class|enum|extension|protocol|struct)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let found = declaration.matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { match -> String? in
                guard let kind = Range(match.range(at: 1), in: code),
                    let name = Range(match.range(at: 2), in: code)
                else { return nil }
                return "\(code[kind]) \(code[name])"
            }

        #expect(
            found == Self.acknowledgedTypeDeclarations,
            """
            the type declarations in \(Self.heldFanFile) changed: found \(found), expected \
            \(Self.acknowledgedTypeDeclarations). A type nested in `HeldFan`, or a second \
            extension of it in this file, can write `commanded` without `record(_:)`'s check, \
            and the member scan does not read it. Say why here, and read what it adds.
            """
        )
    }

    // MARK: - Parsing

    /// The spelling of every member of the requested kind that is not `private`, read from the
    /// file with its nested level removed.
    private static func nonPrivateSpellings(
        keyword: MemberAccessScan.Keyword
    ) throws -> Set<String> {
        let code = try MemberAccessScan.outdentedSource(of: heldFanFile)
        return Set(
            MemberAccessScan.members(inSource: code, keyword: keyword)
                .filter { !$0.isPrivate }.map(\.spelling))
    }
}
