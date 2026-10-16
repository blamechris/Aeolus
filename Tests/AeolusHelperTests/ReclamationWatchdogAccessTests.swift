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
/// - **The registry's own stores stay `private`, and are exactly three.** The new surface is two
///   types; an instance outside the actor governs nothing, and a fourth store is a decision —
///   #366's episode mark and #368's token will each update `registryStores` on purpose.
/// - **Nothing in the registry can suspend.** The compiler refuses a *mutating* `async` call on
///   an actor's stored struct, and does not refuse a non-mutating one, which would answer from a
///   copy taken before its own suspension. So no `async` and no `await`, anywhere in the file.
/// - **Nothing in the registry takes a closure.** One handed in that reaches the actor's
///   `registry` while it is being mutated compiles and traps at run time ("Simultaneous
///   accesses … modification requires exclusive access"), and a trap is the root daemon dying.
/// - **The actor never uses `registry` as a whole value.** `let before = registry`, an `await`,
///   and a write back loses every transition that ran during the suspension.
///
/// ## Both directions, for the reason `LeaseAuthorityAccessTests` gives
///
/// A listed member that loses its `private` fails, as does one that is no longer declared or is
/// declared twice (`MemberAccessScan.declaration(of:in:from:)`); and the exhaustive halves fail
/// on a widening nobody listed. The file set is read off the tree by
/// `MemberAccessScan.filesDeclaring(_:inTarget:)`, so a fifth file declaring
/// `extension ReclamationWatchdog` is a failure here rather than a file scanned by nothing.
///
/// ## Where the per-reading judgement lives, and why it is not scanned here
///
/// `HeldFan.judge(_:)` and the record's other mutating methods are declared inside the
/// `struct HeldFan` body rather than in an `extension ReclamationWatchdog.HeldFan`, which the
/// file-set regex would match. They are a record's methods, reached from the actor only through
/// `Registry`'s transitions, and `held` is private to `Registry`.
@Suite("§ 5's registry stays private to the watchdog and is reached only through its members")
struct ReclamationWatchdogAccessTests {

    private static let watchdogType = "ReclamationWatchdog"
    private static let helperTarget = "AeolusHelper"

    /// The file that declares the actor, and so the only one that can name `registry`.
    private static let watchdogFile = "ReclamationWatchdog.swift"

    /// The file that declares `Registry`.
    private static let registryFile = "ReclamationRegistry.swift"

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

    /// `Registry`'s stored properties, every one `private`. A new one is § 5 state, which is
    /// what this type is for — and adding it is a decision this list records.
    private static let registryStores: Set<String> = ["held", "finalising", "registrations"]

    /// `Registry`'s internal properties: computed, get-only views of `held`.
    private static let registryQueries: Set<String> = ["isEmpty", "fans", "fansInOrder"]

    /// Every type a `Registry` method may take. Value types, so nothing handed in can run code
    /// against the registry while a transition is mutating it — a function type, a generic
    /// parameter and a `typealias` for either are all absent from this set.
    private static let registryParameterTypes: Set<String> = [
        "Int", "UUID", "Bool", "UInt64", "CommandedTarget", "FanControlState",
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

    // MARK: - The registry

    /// **Mutations:** declare `var held` without `private`; add `private var extra = 0`;
    /// declare `var fans: Set<Int> = []` as a stored property. Run: red on each.
    @Test("The registry's three stores are private, and its only internal properties are views")
    func theRegistrysStoresArePrivateAndExactlyThree() throws {
        let code = try Self.registryMembersSource()
        let properties = MemberAccessScan.members(inSource: code, keyword: .property)
        let stores = Set(properties.filter(\.isPrivate).map(\.key))
        let queries = properties.filter { !$0.isPrivate }

        #expect(
            stores == Self.registryStores,
            """
            Registry's private properties changed: found \(stores.sorted()), acknowledged \
            \(Self.registryStores.sorted()). A new store is § 5 state; record it in \
            `registryStores` with the issue that needs it.
            """
        )
        #expect(
            Set(queries.map(\.key)) == Self.registryQueries,
            """
            Registry's internal properties changed: found \(queries.map(\.key).sorted()), \
            acknowledged \(Self.registryQueries.sorted()).
            """
        )
        for query in queries {
            let line = try MemberAccessScan.declaration(
                of: "var \(query.key):", in: code, from: Self.registryFile)
            #expect(
                line.contains("{") && !line.contains("="),
                "`\(line)` is not a computed, get-only view: an internal store is writable state")
        }
    }

    /// The whole file, comments stripped, so a member of `Registration` is not an exception.
    ///
    /// **Mutation:** add `func later() async -> Self { self }` to `Registry`. Run: red.
    @Test("Nothing in the registry's file is async or awaits")
    func theRegistryCannotSuspend() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.registryFile)
        let suspending = try NSRegularExpression(pattern: #"\b(async|await)\b"#)
        let found = suspending.matches(in: code, range: NSRange(code.startIndex..., in: code))

        #expect(
            found.isEmpty,
            """
            \(Self.registryFile) names `async` or `await` \(found.count) time(s). The compiler \
            refuses a mutating async call on an actor's stored struct and not a non-mutating \
            one, which answers from a copy taken before its own suspension.
            """
        )
    }

    /// Every method's parameters are drawn from `registryParameterTypes`, and the file declares
    /// no `subscript`, which `func` scanning would not see.
    ///
    /// **Mutations:** add `mutating func amend(_ index: Int, _ change: (inout HeldFan) -> Void)
    /// { … }` to `Registry`; add `subscript(_ change: (Int) -> Void) -> Int { 0 }`. Run: red on
    /// each.
    @Test("Nothing in the registry takes a closure")
    func theRegistryTakesNoClosure() throws {
        let code = try MemberAccessScan.strippedSource(of: Self.registryFile)
        let unexpected = try SeamScanner.functions(inSource: code, file: Self.registryFile)
            .flatMap { function in
                function.parameterTypes
                    .filter { !Self.registryParameterTypes.contains($0) }
                    .map { "\(function.name): \($0)" }
            }

        #expect(
            unexpected.isEmpty,
            """
            a Registry method takes \(unexpected), outside \
            \(Self.registryParameterTypes.sorted()). A closure that reaches the actor's \
            `registry` while a transition is mutating it traps the helper at run time.
            """
        )
        #expect(
            !code.contains("subscript"),
            "\(Self.registryFile) declares a subscript, which this suite's `func` scan cannot see")
    }

    // MARK: - Parsing

    /// `Registry`'s members are at eight spaces of indent, nested in the extension, and
    /// `MemberAccessScan` reads four. Dropping one indent level brings them to four and the
    /// extension's own members to none, which the actor's suite above already scans.
    private static func registryMembersSource() throws -> String {
        try MemberAccessScan.strippedSource(of: registryFile)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
    }
}
