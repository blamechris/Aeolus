import Foundation
import Testing

@testable import AeolusHelper

/// `ReclamationWatchdog.HeldFan`'s commanded target held read-only, and its members held to the
/// access they are written with, asserted rather than described
/// ([#610](https://github.com/blamechris/Aeolus/issues/610),
/// [#612](https://github.com/blamechris/Aeolus/issues/612)).
///
/// ## Why this suite exists
///
/// `HeldFan` keeps what § 5 knows about one fan, and `commanded` is the step it last put on the
/// wire, which the watchdog's re-assert writes back to the firmware. Its one writer, `record(_:)`,
/// is also the one place that holds the floor check
/// (`rpm.isFinite && rpm >= FanSafetyLimits.minimumManualRPM`). A second writer anywhere would let
/// a target no permit could produce past that check.
///
/// `HeldFan` is a struct nested in `extension ReclamationWatchdog`, so its members sit at eight
/// spaces and `MemberAccessScan` reads four. The file is read here with one indent level removed
/// (`MemberAccessScan.outdentedSource(of:)`, which `ReclamationRegistryAccessTests` and
/// `LeaseAuthorityRegistersAccessTests` read their own nested types through), which puts
/// `HeldFan`'s members at four.
///
/// ## The control is structural; the scans catch accidents
///
/// Since #612 `commanded` is a get-only view of `private var storedCommanded`. The compiler refuses
/// an assignment to `commanded` anywhere ("cannot assign to property: 'commanded' is a get-only
/// property"), and one to `storedCommanded` from another file ("inaccessible due to 'private'
/// protection level"). At run time no key path to `commanded` is writable
/// (`noKeyPathToTheCommandedTargetIsWritable`). As a `private(set) var`, until #612, its key path
/// was writable (SR-5218), and shapes that assigned it compiled past #611's lexical scan. Measured
/// on #612, these no longer compile: a type nested in `HeldFan` named in backticks
/// (``enum `Backdoor` ``), one whose name starts outside ASCII (`enum Éackdoor`), a second `init`
/// and a subscript, each assigning `commanded`. `Judgement` moved inside `HeldFan` to assign it is
/// inferred, not run: the same refusal.
///
/// What is left is this file, where `private` reaches a type nested in `HeldFan` and an extension
/// of it, so either can name `storedCommanded`. `theStorageIsAssignedOnlyInRecord` counts the
/// assignments to it, and is lexical. Each of the four measured shapes, rewritten to assign
/// `storedCommanded`, compiles and is red on that count and nowhere else, measured at full scope.
///
/// ## What is compared
///
/// Every member of `HeldFan` is in the population, `private` ones included, and it is compared
/// **as spelled** ([#607](https://github.com/blamechris/Aeolus/issues/607)): `var commanded` and
/// `private var storedCommanded` are two entries, and `public`, `package` or any other modifier on
/// an acknowledged member is red like a new member. A spelling does not say whether a `var` is
/// stored: a stored `var commanded` reads as the same string as the view, and the key-path test is
/// what is red on it.
///
/// ## What is held
///
/// By the compiler, and asked at run time: no assignment to `commanded`, and no writable key path
/// to it. Lexically, catching accidents: one assignment to `storedCommanded`, in `record(_:)`; any
/// respelling of a member; a new property or method, `private` or not; a binding list; a second
/// declaration of `HeldFan`; and a type with an ASCII name, or a second `extension`, in the file.
///
/// ## What this does not reach
///
/// Each limit says how it is known: measured at full scope (the whole `AeolusHelperTests`
/// target), measured under a filter (named suites only), or inferred (not run). None of them is a
/// route to assigning `commanded`.
///
/// - **A member in the formatter's two-line spelling** (a modifier alone on a line, the
///   declaration under it at twelve spaces in the source, eight once the level is removed) is in
///   no population, whether new or already there. An acknowledged member written so goes missing
///   and is red: measured at full scope (`public` alone above `var commanded`, #612). A new one is
///   seen by nothing here: measured at full scope (`public` alone above a new `var leak = 0`,
///   #612). Closed by [#605](https://github.com/blamechris/Aeolus/issues/605).
/// - **An initialiser or a subscript** is in no population: the scan reads `let`, `var` and
///   `func`. Neither can assign `commanded`, and one that assigns `storedCommanded` is red on the
///   write-site count: measured at full scope for both (#612). No issue: past the storage, either
///   reaches only members that are internal already.
/// - **A write that does not name the storage.** `self = HeldFan(lease: lease)`, or `self` assigned
///   another record, in a mutating method replaces the whole record, storage and all, and the
///   count does not see it: inferred, not run. It can store only `nil` or a value some record's
///   `record(_:)` took. No issue: it cannot carry a target past the floor check.
/// - **`HeldFan`'s own declaration and its sibling's.** `struct HeldFan` and `enum Judgement` are
///   read by no suite. Their access is capped by the actor's, which `HelperActorHeaderAccessTests`
///   pins: `public struct HeldFan` compiles and leaves this target green, measured at full scope
///   (#612). Not a route to `commanded`. Closed by
///   [#613](https://github.com/blamechris/Aeolus/issues/613).
@Suite("§ 5's per-fan record keeps its commanded target read-only")
struct ReclamationHeldFanAccessTests {

    /// The record, at the concrete plane the other § 5 suites build it with.
    private typealias Held = ReclamationWatchdog<ScriptedControlPlane>.HeldFan

    private static let heldFanType = "HeldFan"
    private static let heldFanFile = "ReclamationHeldFan.swift"
    private static let helperTarget = "AeolusHelper"

    /// The storage behind `commanded`, by name.
    private static let commandedStorage = "storedCommanded"

    /// Every property of `HeldFan`, **as spelled**. `commanded` is a get-only view, and
    /// `storedCommanded` is the storage it reads. The rest are counters and stamps the record moves
    /// itself, and the lease it was registered under.
    private static let acknowledgedProperties: Set<String> = [
        "let lease",
        "var commanded",
        "private var storedCommanded",
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
    /// starts to mutate, or stops, is red. `record(_:)` is the one writer of `storedCommanded`, and
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

    /// A `private(set) var` hides its setter from lookup and not from a key path: at run time the
    /// key path is a `WritableKeyPath`, and a cast outside the declaring file recovers it (SR-5218,
    /// the route #456 closed on `Request`). A computed property with no setter has no writable key
    /// path to recover. The first expectation is the second's precondition: a cast to a value type
    /// the key path does not have is `nil` whatever the setter.
    ///
    /// **Mutation:** put back `private(set) var commanded: CommandedTarget?`, assigned by
    /// `record(_:)`, in place of the view and its storage. Run: red here, on the cast, which
    /// succeeds from this file.
    @Test("No key path to the commanded target is writable")
    func noKeyPathToTheCommandedTargetIsWritable() {
        let path: AnyKeyPath = \Held.commanded

        #expect(path is KeyPath<Held, CommandedTarget?>, "the key path is not the one this asks")
        #expect(
            (path as? WritableKeyPath<Held, CommandedTarget?>) == nil,
            """
            a key path to `commanded` is writable, so any file in AeolusHelper can assign a target \
            past `record(_:)`'s floor check through a cast (SR-5218). Keep `commanded` a get-only \
            view of private storage.
            """
        )
    }

    /// `storedCommanded` is assigned once in this file, in `record(_:)`, and named three times:
    /// its declaration, the view that reads it, and that assignment. `init(lease:)` assigns it
    /// nothing; its `nil` is the optional's default.
    ///
    /// **This is lexical, and catches accidents only.** The compiler holds every other file. Here,
    /// a type nested in `HeldFan` and an extension in this file can assign the storage, and this is
    /// what reads for one: an assignment is the name, then `=` and not `==`, with or without
    /// backticks, `self.` or whitespace between. The mention count is there for a write spelled
    /// another way, as an `inout` argument or through a key path. It sees names, not writes, so a
    /// new read of the storage is red too: read `commanded` instead. It does not see a write that
    /// never names the storage (in the suite's limits).
    ///
    /// **Mutations:** add `mutating func force(_ target: CommandedTarget) { storedCommanded =
    /// target }`; move `record(_:)`'s assignment into `command(_:)`, after its guard; write
    /// `self[keyPath: \.storedCommanded] = nil` in `recordReadFailure()`. Run: red on the file's
    /// assignment count and the mention count; on `record(_:)`'s count, the only one of the three;
    /// and on the mention count, the only one of the three.
    @Test("The commanded target's storage is assigned in one place, record(_:)")
    func theStorageIsAssignedOnlyInRecord() throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: Self.heldFanFile))
        let record = try #require(
            try SeamScanner.functionBody(named: "record", inSource: code),
            "`record(_:)` has no body in \(Self.heldFanFile), so this counts nothing in it")
        let assignments = try Self.storageAssignments(in: code)
        let assignmentsInRecord = try Self.storageAssignments(in: record)
        let mentions = try SeamScanner.mentions(of: Self.commandedStorage, inSource: code)

        #expect(
            assignments == 1,
            """
            \(Self.heldFanFile) assigns `\(Self.commandedStorage)` \(assignments) time(s). \
            `record(_:)`'s is the only one, because it holds the floor check; another writes a \
            target past it.
            """
        )
        #expect(
            assignmentsInRecord == 1,
            """
            `record(_:)` assigns `\(Self.commandedStorage)` \(assignmentsInRecord) time(s), not \
            once, so its floor check does not guard the one write.
            """
        )
        #expect(
            mentions == 3,
            """
            \(Self.heldFanFile) names `\(Self.commandedStorage)` \(mentions) time(s), not three: \
            its declaration, `commanded`'s read and `record(_:)`'s assignment. A write as an \
            `inout` argument or through a key path is one more; so is a read, which should read \
            `commanded`.
            """
        )
    }

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

    /// **Mutations:** respell `var commanded` as `public var commanded`. Respell `let lease` as
    /// `public let lease`. Add `var leak = 0`. Add `private var shadow = 0`. Put `public` alone on
    /// the line above `var commanded`. Add a computed property to `Judgement`. Run: red on each, at
    /// the comparison.
    @Test("Only the acknowledged properties of HeldFan exist, as spelled")
    func onlyTheAcknowledgedPropertiesExist() throws {
        let found = try Self.spellings(keyword: .property)

        #expect(
            found == Self.acknowledgedProperties,
            """
            the properties of HeldFan changed, as spelled: \
            \(MemberAccessScan.difference(found, Self.acknowledgedProperties)). `commanded` is a \
            get-only view of `storedCommanded`, which only `record(_:)` assigns because it holds \
            the floor check. Say why here, and re-state the entry as it is now written.
            """
        )
    }

    /// **Mutations:** respell `mutating func record(_ target: CommandedTarget)` with `public` in
    /// front. Add `mutating func force(_ target: CommandedTarget) { storedCommanded = target }`.
    /// Run: red on each, at the comparison.
    @Test("Only the acknowledged methods of HeldFan exist, as spelled")
    func onlyTheAcknowledgedMethodsExist() throws {
        let found = try Self.spellings(keyword: .method)

        #expect(
            found == Self.acknowledgedMethods,
            """
            the methods of HeldFan changed, as spelled: \
            \(MemberAccessScan.difference(found, Self.acknowledgedMethods)). A method of the \
            record can assign `storedCommanded` without `record(_:)`'s check; say why here, and \
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

    /// A type declared inside `HeldFan`, or a second `extension` of it in this file, is inside the
    /// scope `private` names, so it can name `storedCommanded`, and its members sit below the depth
    /// the member scan reads. So the type declarations in the file are listed: the extension, the
    /// record and `Judgement`, in source order, as `kind Name`.
    ///
    /// **What it catches:** a declaration whose name matches `[A-Za-z_][A-Za-z0-9_]*`, which is
    /// ASCII only, under any modifier or attribute, because the match is on the keyword and the
    /// name wherever it stands; and a second `extension` (`extension ReclamationWatchdog.HeldFan`,
    /// whose `private` reaches the storage from the same file).
    ///
    /// **What it does not:** a name in backticks; a name that starts with a letter outside ASCII,
    /// which is an ordinary identifier to Swift (``enum Éackdoor``); and a listed type moved inside
    /// `HeldFan`, because the list says which types exist and not where they sit (`Judgement`).
    /// None of them can assign `commanded`, which has no setter: measured for the first two
    /// (#612), inferred for the third. An assignment to the storage from any of them is
    /// `theStorageIsAssignedOnlyInRecord`'s. Measured at full scope (#612): ``enum `Backdoor` ``
    /// and `enum Éackdoor`, each assigning `storedCommanded`, leave this test green and are red on
    /// the count. Written as the formatter wraps them, `swift format lint --strict` exits 0 on
    /// either, `IdentifiersMustBeASCII` notwithstanding, and SwiftLint exits 0 with one `nesting`
    /// warning.
    ///
    /// **Mutation:** add `enum Backdoor { static func force(_ fan: inout HeldFan, to target:
    /// CommandedTarget) { fan.storedCommanded = target } }` to `HeldFan`'s body. Run: red here.
    @Test("No type with an ASCII name is declared in the per-fan record's file beyond its three")
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
            extension of it in this file, can assign `storedCommanded`, and the member scan does \
            not read it. This lists names the ASCII pattern matches: not a name in backticks or \
            one starting outside ASCII, and not where a listed type sits. Say why here, and read \
            what it adds.
            """
        )
    }

    // MARK: - Parsing

    /// The spelling of every member of the requested kind, `private` ones included, read from the
    /// file with its nested level removed.
    private static func spellings(keyword: MemberAccessScan.Keyword) throws -> Set<String> {
        let code = try MemberAccessScan.outdentedSource(of: heldFanFile)
        return Set(MemberAccessScan.members(inSource: code, keyword: keyword).map(\.spelling))
    }

    /// The assignments to `storedCommanded` in `code`: the name, not preceded by an identifier
    /// character, then an optional closing backtick, any whitespace, and `=` not followed by `=`.
    private static func storageAssignments(in code: String) throws -> Int {
        let assignment = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])"# + commandedStorage + #"`?\s*=(?!=)"#)
        return assignment.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }
}
