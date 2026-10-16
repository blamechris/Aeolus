import Foundation
import Testing

/// The access levels [#128](https://github.com/blamechris/Aeolus/issues/128)'s third pass left
/// on § 5, asserted rather than described.
///
/// ## Why this suite exists
///
/// #128 moved `held`, `finalising` and `registrations` out of `ReclamationWatchdog` into
/// `ReclamationWatchdog.Registry`, a value type in `ReclamationRegistry.swift`, so the actor's
/// body had room for the A6 fixes. The trade that made that safe is a set of properties the
/// compiler holds only in part, and a paragraph is not enforcement:
///
/// - **The actor's state stays `private`.** One stored `registry`, never widened; and every
///   collaborator beside it.
/// - **The actor's internal surface is exactly what it was.** The five seam members and the two
///   static classifiers, and nothing a sibling file could call to reach `registry`.
/// - **The registry's own stores stay `private`, and are exactly three.** An instance outside the
///   actor governs nothing, and a fourth store is a decision — #366's episode mark and #368's
///   token will each update `ReclamationRegistryAccessTests.registryStores` on purpose.
/// - **Nothing in the registry can suspend.** The compiler refuses a *mutating* `async` call on
///   an actor's stored struct, and does not refuse a non-mutating one, which would answer from a
///   copy taken before its own suspension. So no `async` and no `await`, anywhere in the file.
/// - **Nothing in the registry takes a closure.** One handed in that reaches the actor's
///   `registry` while it is being mutated compiles and traps at run time ("Simultaneous
///   accesses … modification requires exclusive access"), and a trap is the root daemon dying.
/// - **The actor never uses `registry` as a whole value.** `let before = registry`, an `await`,
///   and a write back loses every transition that ran during the suspension.
/// - **Every internal property is a get-only view.** Its accessor block is read whole, so a
///   `set`, a `_modify` or an observer is seen wherever it is written.
///
/// ## The routes around the scan, closed after #128's review
///
/// Three evasions left the first version of this suite green, each a compiling spelling:
///
/// - a `typealias` naming the actor, and `extension W.Registry { … }` in a new file — the file
///   set keys on a literal `extension ReclamationWatchdog`, so nothing here read it;
/// - a tuple pattern or a comma list — `MemberAccessScan` keys a declaration on its first name;
/// - a setter or `_modify` on a view — the old check read only the declaration's line.
///
/// `nothingReachesTheRegistryAroundTheFileSet`, `everyDeclarationBindsOneName` and
/// `everyInternalPropertyIsAGetOnlyView` close them. Two shapes are left open on purpose: a
/// `Registry` method returning a copy of one of its private stores, and a `snapshot() -> Self`.
/// Each hands out a value and changes nothing, and writing one back needs either a whole-value
/// assignment to `registry`, which `registryIsOnlyReachedThroughItsMembers` refuses, or a
/// `Registry`-typed parameter, which `ReclamationRegistryAccessTests`' type allowlist refuses.
///
/// ## Both directions, for the reason `LeaseAuthorityAccessTests` gives
///
/// A listed member that loses its `private` fails, as does one no longer declared or declared
/// twice; the exhaustive halves fail on a widening nobody listed; and the file set is read off
/// the tree, so a fifth file declaring `extension ReclamationWatchdog` fails here. The
/// registry's own half — its stores, `async`, closures — is `ReclamationRegistryAccessTests`.
/// `HeldFan`'s methods are written inside its struct body, reached only through `Registry`.
@Suite("§ 5's registry stays private to the watchdog and is reached only through its members")
struct ReclamationWatchdogAccessTests {

    private static let watchdogType = "ReclamationWatchdog"
    private static let helperTarget = "AeolusHelper"

    /// The file that declares the actor, and so the only one that can name `registry`.
    private static let watchdogFile = "ReclamationWatchdog.swift"

    /// Every file `ReclamationWatchdog`'s members are written in, **sorted**, and checked against
    /// the tree by `theScannedFilesAreEveryFileTheActorIsIn` rather than trusted.
    private static let watchdogFiles = [
        "ReclamationHeldFan.swift",
        "ReclamationRegistry.swift",
        "ReclamationSignals.swift",
        "ReclamationWatchdog.swift",
    ]

    /// Every member of the actor whose privacy is load-bearing, spelled as declared.
    ///
    /// The nine stored members first: the read seam, the ungoverned writer, the engagement
    /// driver, the lease role, § 3's latch, the ledger, the log, the registry and the sweep
    /// flag. Then every method that acts on a held fan — each one awaits, re-fetches and acts in
    /// an order the re-fetch rule depends on, and an internal one is callable from every file
    /// in `AeolusHelper` with `registry` in scope — and the two hand-back steps #128 lifted out.
    private static let mustStayPrivate = [
        "let sensing: any FanStateSensing",
        "let writer: SafetyActorWriter<Plane>",
        "let engagement: EngagementDriver<Plane>",
        "let leases: any HeldLeaseRole",
        "let latch: ThermalEmergencyLatch",
        "let ledger: ReclamationLedger",
        "let log: SafetyLog",
        "var registry = Registry()",
        "var isSweeping = false",
        "func examine(fanAt index: Int) async {",
        "func diverged(",
        "func reassert(",
        "func commandWriteFailed(",
        "func cycleCouldNotSee(",
        "func restoreAndForget(fanAt index: Int, heldUnder lease: UUID) async {",
        "func finaliseRelease(",
        "func currentRuling() async -> SafetyRuling {",
        "func isHeld(_ index: Int, under lease: UUID) -> Bool {",
        "func handBack(fanAt index: Int) async {",
        "func clearReclamationMark(fanAt index: Int) async {",
    ]

    /// The one internal property of the actor: the registry's fan set, for tests and
    /// diagnostics. A copy of the keys, and nothing reached through it can change who is held.
    private static let acknowledgedInternalProperties: Set<String> = [
        "fansUnderManualControl"
    ]

    /// The actor's seam, unchanged by #128: the three notices the lease core and the engagement
    /// path send, the supervisor's cycle, and the diagnostic read — plus the two static, pure
    /// classifiers in `ReclamationSignals.swift`, which reach no state because there is none
    /// there to reach.
    private static let acknowledgedInternalMethods: Set<String> = [
        "manualControlEngaged(_: CommandableFan, under: UUID)",
        "commandedTarget(_: CommandedTarget, under: UUID)",
        "manualControlReleased(fanAt: Int)",
        "lastCommanded(ofFan: Int)",
        "cycle()",
        "primaryDivergence(of: FanControlState, against: CommandedTarget?)",
        "actualShortfall(of: FanControlState, against: CommandedTarget?)",
    ]

    /// The actor and every type nested in it, which no other file may reach by an alias or a
    /// dotted extension.
    private static let sectionFiveTypes: Set<String> = [
        "ReclamationWatchdog", "Registry", "HeldFan", "Judgement", "Registration",
    ]

    // MARK: - The actor

    /// **Mutation:** add `Sources/AeolusHelper/Safety/ReclamationExtra.swift` declaring
    /// `extension ReclamationWatchdog { func x() {} }`. Run: red.
    @Test("Every file the watchdog is written in is one this suite scans")
    func theScannedFilesAreEveryFileTheActorIsIn() throws {
        let sites = try MemberAccessScan.filesDeclaring(
            Self.watchdogType, inTarget: Self.helperTarget)

        #expect(
            sites.members == Self.watchdogFiles.sorted(),
            """
            the files \(Self.watchdogType) is written in changed: the tree declares it in \
            \(sites.members), this suite scans \(Self.watchdogFiles.sorted()). A file this \
            suite does not scan can widen any member of § 5 while every assertion here stays \
            green. Add it to `watchdogFiles` and say what it is allowed to widen.
            """
        )
        #expect(
            sites.declarations == [Self.watchdogFile],
            """
            \(Self.watchdogType)'s own declaration is in \(sites.declarations), and \
            `watchdogFile` names \(Self.watchdogFile). That name is what \
            `theActorsStateStaysPrivate` and `registryIsOnlyReachedThroughItsMembers` open.
            """
        )
    }

    /// **Mutation:** declare `var registry = Registry()` without `private`. Run: red.
    @Test("The watchdog's stored state, and every method that acts on a held fan, is private")
    func theActorsStateStaysPrivate() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.watchdogFile)

        for member in Self.mustStayPrivate {
            let declaration = try MemberAccessScan.declaration(
                of: member, in: code, from: Self.watchdogFile)
            #expect(
                declaration.hasPrefix("private "),
                """
                `\(declaration)` is no longer private. An internal member of § 5 is reachable \
                from every file in AeolusHelper, and inside one `registry` is in scope.
                """
            )
        }
    }

    /// **Mutation:** add `var heldCount: Int { registry.fans.count }` to the actor. Run: red.
    @Test("Only the acknowledged properties of the watchdog are internal")
    func onlyTheAcknowledgedPropertiesAreInternal() throws {
        let internalProperties = Set(
            try MemberAccessScan.members(in: Self.watchdogFiles, keyword: .property)
                .filter { !$0.isPrivate }.map(\.key))

        #expect(
            internalProperties == Self.acknowledgedInternalProperties,
            """
            the internal properties of ReclamationWatchdog changed: found \
            \(internalProperties.sorted()), acknowledged \
            \(Self.acknowledgedInternalProperties.sorted()). Say why here.
            """
        )
    }

    /// **Mutation:** declare `finaliseRelease(fanAt:heldUnder:because:)` without `private`.
    /// Run: red.
    @Test("Only the acknowledged methods of the watchdog are internal")
    func onlyTheAcknowledgedMethodsAreInternal() throws {
        let internalMethods = Set(
            try MemberAccessScan.members(in: Self.watchdogFiles, keyword: .method)
                .filter { !$0.isPrivate }.map(\.key))

        #expect(
            internalMethods == Self.acknowledgedInternalMethods,
            """
            the internal methods of ReclamationWatchdog changed: found \
            \(internalMethods.sorted()), acknowledged \
            \(Self.acknowledgedInternalMethods.sorted()). A method of this actor that is not \
            private is callable from every file in AeolusHelper with `registry` in scope — say \
            why here.
            """
        )
    }

    /// Every use of `registry` in the actor is a member access, and the declaration is the one
    /// exception.
    ///
    /// Whitespace before the `.` is skipped, because `registry\n    .isEmpty` is a member access
    /// and swift-format writes chains that way; and `registry.self` is refused, because it is
    /// the whole value spelled as a member.
    ///
    /// **Mutations:** add `let before = registry` to `examine(fanAt:)`; add
    /// `registry = Registry()` to `cycle()`. Run: red on each.
    @Test("The watchdog reaches its registry only through the registry's members")
    func registryIsOnlyReachedThroughItsMembers() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.watchdogFile)
        let uses = try NSRegularExpression(pattern: #"\bregistry\b"#)
        var wholeValueUses: [String] = []

        for match in uses.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let found = Range(match.range, in: code) else { continue }
            let after = code[found.upperBound...].drop { $0 == " " || $0 == "\n" }
            let member = after.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if after.first == ".", member != "self" { continue }

            let lineStart = code[..<found.lowerBound].lastIndex(of: "\n") ?? code.startIndex
            let lineEnd = code[found.upperBound...].firstIndex(of: "\n") ?? code.endIndex
            wholeValueUses.append(
                code[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines))
        }

        #expect(
            wholeValueUses == ["private var registry = Registry()"],
            """
            `registry` is used as a whole value outside its declaration: \(wholeValueUses). A \
            copy taken before an `await` and written back after it loses every transition that \
            ran during the suspension; reach the registry through a named member instead.
            """
        )
    }

    /// Every internal property of the actor and of `Registry` is computed, and nothing in its
    /// accessor block writes. The block is read whole, brace-matched from the declaration, so a
    /// `get { … } set { … }` pair or a `_modify` split across lines is seen; a declaration with
    /// an `=` before its block, or with no block at all, has storage.
    ///
    /// **Mutations:** declare `var fans: Set<Int> = []` as a stored property; give `Registry.fans`
    /// a `set`; give `Registry.isEmpty` a `_modify`; give the actor's `fansUnderManualControl` a
    /// `set`. Run: red on each.
    @Test("Every internal property of the watchdog and the registry is a computed, get-only view")
    func everyInternalPropertyIsAGetOnlyView() throws {
        let watchdog = try MemberAccessScan.strippedSource(of: Self.watchdogFile)
        let registry = try ReclamationRegistryAccessTests.registryMembersSource()
        let views =
            Self.acknowledgedInternalProperties.sorted().map { (Self.watchdogFile, $0) }
            + ReclamationRegistryAccessTests.registryQueries.sorted().map { ("Registry", $0) }
        let writers = try NSRegularExpression(
            pattern: #"\b(set|_modify|willSet|didSet|unsafeMutableAddress)\b"#)

        for (owner, name) in views {
            let code = owner == Self.watchdogFile ? watchdog : registry
            let block = try #require(
                try Self.accessorBlock(of: name, in: code),
                """
                `\(name)` in \(owner) has no accessor block straight after its type, so it has \
                storage: an internal store is writable state, and these must be views.
                """)
            let found =
                writers
                .matches(in: block, range: NSRange(block.startIndex..., in: block))
                .compactMap { Range($0.range, in: block).map { String(block[$0]) } }
            #expect(
                found.isEmpty,
                """
                `\(name)` in \(owner) declares \(found) in its accessor block. A view that can \
                be written is a route to the state it views.
                """
            )
        }
    }

    /// No file in the helper names § 5's nested types through a `typealias`, or extends one by a
    /// dotted path. Either is a way past `theScannedFilesAreEveryFileTheActorIsIn`, which keys
    /// on a literal `extension ReclamationWatchdog`: `typealias W =
    /// ReclamationWatchdog<SMCFanControlPlane>` and then `extension W.Registry { … }` in a new
    /// file add members to the registry where none of this suite looks. A non-mutating `async`
    /// one compiles: the stale-copy route `ReclamationRegistryAccessTests` closes in its own file.
    ///
    /// **Mutation:** add `Sources/AeolusHelper/Safety/ReclamationAlias.swift` declaring
    /// `typealias W = ReclamationWatchdog<SMCFanControlPlane>` and `extension W.Registry { func
    /// later() async -> Int { 0 } }`. Run: red.
    @Test("No file reaches § 5's types through a typealias or a dotted extension")
    func nothingReachesTheRegistryAroundTheFileSet() throws {
        let aliases = try SeamScanner.typeAliases(in: Self.helperTarget)
            .filter { !Self.sectionFiveTypes.isDisjoint(with: $0.names) }
            .map { "\($0.file): typealias \($0.name)" }

        let extending = try NSRegularExpression(pattern: #"\bextension\s+([^{]+?)\s*\{"#)
        let nested = Self.sectionFiveTypes.subtracting([Self.watchdogType])
        var dotted: [String] = []
        for url in try SeamScanner.swiftFiles(under: Self.helperTarget) {
            let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
            for match in extending.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                let extended = SeamScanner.identifiers(in: String(code[range]))
                if !nested.isDisjoint(with: extended) {
                    dotted.append("\(url.lastPathComponent): extension \(code[range])")
                }
            }
        }

        #expect(
            aliases.isEmpty && dotted.isEmpty,
            """
            § 5's types are reached around the file set: \(aliases + dotted). Name them in \
            full in a file `watchdogFiles` lists, or add the file there and say why.
            """
        )
    }

    /// `MemberAccessScan` keys a declaration on its first name, so a tuple pattern or a comma
    /// list adds a member every exact list here would miss (#128's review). Asserted absent
    /// rather than parsed, so the spelling fails loudly.
    ///
    /// **Mutations:** `private var (hiddenA, hiddenB) = (0, 0)` in `Registry`; `private var
    /// finalising: [Int: UUID] = [:], hiddenStore: [Int: UUID] = [:]` in `Registry`; `var (leakA,
    /// leakB) = (0, 0)` on the actor. Run: red on each.
    @Test("Every declaration the exact lists read binds exactly one name")
    func everyDeclarationBindsOneName() throws {
        var found: [String] = []
        for file in Self.watchdogFiles {
            found += MemberAccessScan.multipleBindings(
                inSource: try MemberAccessScan.strippedSource(of: file)
            ).map { "\(file): \($0)" }
        }
        let registry = try ReclamationRegistryAccessTests.registryMembersSource()
        found += MemberAccessScan.multipleBindings(inSource: registry).map { "Registry: \($0)" }

        #expect(
            found.isEmpty,
            """
            these declarations bind more than one name: \(found). The access scan reads only the \
            first, so the rest are members nothing here acknowledges. Write one per line.
            """
        )
    }

    // MARK: - Parsing

    /// The accessor block of the member-indent `var name:` in `code`, braces included — or `nil`
    /// when the declaration reaches a `=` or a newline before any `{`, which is a stored one.
    ///
    /// String literals are stepped over, so a `}` written inside one cannot close the block
    /// early and leave a `set` after it unread.
    private static func accessorBlock(of name: String, in code: String) throws -> String? {
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^    (?:[^\s]+ )*var \#(name)\s*:"#)
        guard
            let match = declaration.firstMatch(
                in: code, range: NSRange(code.startIndex..., in: code)),
            let found = Range(match.range, in: code),
            let open = code[found.upperBound...].firstIndex(where: { "{=\n".contains($0) }),
            code[open] == "{"
        else { return nil }

        var depth = 0
        var index = open
        var skipped = ""
        while index < code.endIndex {
            if code[index] == "\"" {
                let delimiter = code[index...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
                index = SeamScanner.copyDelimited(
                    code, from: index, delimiter: delimiter, into: &skipped)
                continue
            }
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }
}
