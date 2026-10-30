import Foundation
import Testing

/// `LeaseAuthority.HandbackRegisters` and `LeaseAuthority.SleepSealPairing`, held to the rules
/// that make moving the lease core's state into them safe, asserted rather than described.
///
/// [#128](https://github.com/blamechris/Aeolus/issues/128)'s lease-core pass moved the handback
/// ledger's registers and § 4's seal out of the actor into two value types it holds `private`, so
/// its body had room for #269. The trade is the one `ReclamationWatchdog.Registry` made, and it
/// rests on properties the compiler holds only in part:
///
/// - **Each type's stores stay `private`, and are exactly the listed ones.** An instance outside
///   the actor governs nothing, and a new store is a decision this suite records.
/// - **Nothing in either type can suspend.** The compiler refuses a *mutating* `async` call on an
///   actor's stored struct and not a non-mutating one, which would answer from a copy taken before
///   its own suspension.
/// - **Nothing in either type takes a closure.** One handed in that reaches the actor's property
///   while it is being mutated compiles and traps at run time ("Simultaneous accesses"), and a
///   trap is the root daemon dying.
/// - **The actor never uses either as a whole value.** `let before = sleep`, an `await`, and a
///   write back loses every transition that ran during the suspension.
/// - **Every internal property is a computed, get-only view, and no accessor in either file
///   writes.** An internal stored `var isSealed` is a second seal the actor could clear outside
///   `wake(generation:)`, and a `mutating get` is a read that writes.
/// - **Nothing reaches either type around the file set**, by a `typealias` or a dotted extension.
///
/// `LeaseAuthorityAccessTests` holds the actor's half — its file set read off the tree, the two
/// properties `private`, its internal surface exact. The parse is `MemberAccessScan` and
/// `SeamScanner`'s, as for § 5's registry, `accessorBlock(of:in:)` included; nothing here is a
/// second scanner.
///
/// ## As spelled, and what that does not reach
///
/// The stores and the views are compared **as spelled**
/// ([#607](https://github.com/blamechris/Aeolus/issues/607)), as `HelperClientAccessTests` has
/// since [#604](https://github.com/blamechris/Aeolus/issues/604): an entry is the modifier run,
/// the introducer and the key. So `public` on a view, or `fileprivate` or an attribute on a
/// store, is a different string and red, where a bare key matched all of them.
///
/// A member is read at four spaces once the type's own indent is dropped, so **a member in the
/// formatter's two-line spelling** — a modifier alone on a line, the declaration under it at
/// twelve in the source, eight once the indent is dropped — is in no population here, whether
/// new or already there ([#605](https://github.com/blamechris/Aeolus/issues/605)). A store or a
/// view written so goes missing from its list and is red; a new member is seen by nothing here.
/// An `extension`'s own modifier is on no member's line: `HelperActorHeaderAccessTests` reads it
/// ([#610](https://github.com/blamechris/Aeolus/issues/610)). `package extension LeaseAuthority {` alone does not compile against an
/// internal actor, so a widening starts at the actor's own declaration, and that suite pins both.
@Suite("The lease core's registers and sleep seal are values the actor reaches only by member")
struct LeaseAuthorityRegistersAccessTests {

    /// One value type, where it is declared, what holds it, and what it may contain.
    private struct ValueType {
        let name: String
        let file: String
        /// The actor's `private` property holding the one instance that governs anything.
        let property: String
        /// Its stored properties, every one `private`, **as spelled** (#607): `private var
        /// releasing`. A new one is lease-core state, and adding it is a decision recorded here.
        let stores: Set<String>
        /// Its internal properties: computed, get-only views of the stores, as spelled: `var
        /// isSealed`.
        let queries: Set<String>

        /// The names behind `queries`, for the check that reads each one's accessor block.
        var queryNames: [String] {
            queries.map(MemberAccessScan.name(ofPropertySpelling:)).sorted()
        }
    }

    private static let valueTypes = [
        ValueType(
            name: "HandbackRegisters", file: "LeaseAuthorityHandbackRegisters.swift",
            property: "registers",
            stores: [
                "private var releasing", "private var restoreAbandoned",
                "private var handbackAcceptedUnconfirmed", "private var handbackUnconfirmed",
            ],
            queries: [
                "var abandonedHandbacks", "var unconfirmedHandbacks", "var fansMidHandback",
                "var handbacksOwedAReadBack",
            ]),
        ValueType(
            name: "SleepSealPairing", file: "LeaseAuthoritySleepSealPairing.swift",
            property: "sleep",
            stores: [
                "private var sleepSeal", "private var latestWakeGeneration",
                "private var sealGeneration",
            ],
            queries: ["var isSealed"]),
    ]

    /// The file that declares the actor, and so the only one that can name either property.
    private static let actorFile = "LeaseAuthority.swift"
    private static let helperTarget = "AeolusHelper"

    /// Every type a method of either value type may take. Values, so nothing handed in can run
    /// code against the actor's property while a transition is mutating it — a function type, a
    /// generic parameter and a `typealias` for either are all absent.
    private static let parameterTypes: Set<String> = ["Int", "UInt64", "[Int]", "Set<Int>"]

    /// The actor and the types declared in its value-type files, which no file may reach by an
    /// alias, and whose nested ones no file may extend by a dotted path.
    private static let leaseCoreTypes: Set<String> = [
        "LeaseAuthority", "HandbackRegisters", "SleepSealPairing", "SealOutcome",
    ]

    /// An accessor that can write, or a read accessor that can mutate: `set`, `_modify`, an
    /// observer, `unsafeMutableAddress`, `_read` — whose coroutine can be declared `mutating` —
    /// and a `mutating get`, whose body may assign any store. § 5's view check reads the other
    /// five; these two are added here, where a `mutating get` writing `latestWakeGeneration`
    /// passed the whole helper suite in #388's review.
    private static let writingAccessor =
        #"\b(set|_modify|_read|willSet|didSet|unsafeMutableAddress)\b|\bmutating\s+get\b"#

    /// **Mutations:** declare `HandbackRegisters`' `var releasing` without `private`; add
    /// `private var extra = 0` to `SleepSealPairing`. Run: red on each.
    @Test("Each value type's stores are private and exactly the listed ones; the rest are views")
    func theStoresArePrivateAndExactlyTheListedOnes() throws {
        for type in Self.valueTypes {
            let properties = MemberAccessScan.members(
                inSource: try Self.membersSource(of: type), keyword: .property)
            let stores = Set(properties.filter(\.isPrivate).map(\.spelling))
            let queries = Set(properties.filter { !$0.isPrivate }.map(\.spelling))

            #expect(
                stores == type.stores,
                """
                \(type.name)'s private properties changed, as spelled: \
                \(MemberAccessScan.difference(stores, type.stores)). A new store is lease-core \
                state; record it here with the issue that needs it.
                """)
            #expect(
                queries == type.queries,
                """
                \(type.name)'s internal properties changed, as spelled: \
                \(MemberAccessScan.difference(queries, type.queries)). An internal store is \
                writable state.
                """)
        }
    }

    /// Each whole file, comments stripped, so `SealOutcome` is no exception.
    ///
    /// **Mutation:** add `func later() async -> Self { self }` to `HandbackRegisters`. Run: red.
    @Test("Nothing in either value type's file is async or awaits")
    func nothingInEitherValueTypeCanSuspend() throws {
        let suspending = try NSRegularExpression(pattern: #"\b(async|await)\b"#)
        for type in Self.valueTypes {
            let code = try MemberAccessScan.strippedSource(of: type.file)
            let found = suspending.matches(in: code, range: NSRange(code.startIndex..., in: code))
            #expect(
                found.isEmpty,
                """
                \(type.file) names `async` or `await` \(found.count) time(s). The compiler \
                refuses a mutating async call on an actor's stored struct and not a non-mutating \
                one, which answers from a copy taken before its own suspension.
                """)
        }
    }

    /// Every method's parameters are drawn from `parameterTypes`, and neither file declares a
    /// `subscript`, which `func` scanning would not see.
    ///
    /// **Mutation:** add `mutating func amend(_ change: (inout Self) -> Void) { change(&self) }`
    /// to `SleepSealPairing`. Run: red.
    @Test("Nothing in either value type takes a closure")
    func nothingInEitherValueTypeTakesAClosure() throws {
        for type in Self.valueTypes {
            let code = try MemberAccessScan.strippedSource(of: type.file)
            let unexpected = try SeamScanner.functions(inSource: code, file: type.file)
                .flatMap { function in
                    function.parameterTypes.filter { !Self.parameterTypes.contains($0) }
                        .map { "\(function.name): \($0)" }
                }
            #expect(
                unexpected.isEmpty,
                """
                a \(type.name) method takes \(unexpected), outside \
                \(Self.parameterTypes.sorted()). A closure that reaches the actor's \
                `\(type.property)` while a transition is mutating it traps the helper at run time.
                """)
            #expect(
                !code.contains("subscript"),
                "\(type.file) declares a subscript, which this suite's `func` scan cannot see")
        }
    }

    /// Every use of `registers` and of `sleep` in the actor is a member access, and each
    /// declaration is the one exception. Whitespace before the `.` is skipped, because the
    /// formatter writes chains that way, and `.self` is refused, because it is the whole value
    /// spelled as a member.
    ///
    /// Every comment is stripped first, a trailing one included, through `strippingAllComments`:
    /// `sleep` is an English word, and `// the sleep seal` after a statement is prose, not a use.
    /// A member of another value spelled the same way — `clock.sleep(until:)` — still reads as
    /// one, and fails loudly rather than quietly; none is written in the actor, and telling it
    /// from `self.sleep` or `\.sleep` needs a receiver this scan does not parse.
    ///
    /// **Mutations:** add `let before = sleep` (and `_ = before`) to `sealForSleep(generation:)`;
    /// add `registers = HandbackRegisters()` to `releaseEveryLease()`. Run: red on each.
    /// **Probe:** `let note = 1  // the sleep seal` above `sealForSleep`'s `switch`. Run: green.
    @Test("The actor reaches each value type only through its members")
    func theActorReachesEachOnlyThroughItsMembers() throws {
        let code = SeamScanner.strippingAllComments(
            try MemberAccessScan.strippedSource(of: Self.actorFile))
        for type in Self.valueTypes {
            let uses = try NSRegularExpression(pattern: #"\b\#(type.property)\b"#)
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
                wholeValueUses == ["private var \(type.property) = \(type.name)()"],
                """
                `\(type.property)` is used as a whole value outside its declaration: \
                \(wholeValueUses). A copy taken before an `await` and written back after it \
                loses every transition that ran during the suspension.
                """)
        }
    }

    /// No accessor in either file can write: a view with a `set` or a `_modify` is a route to
    /// the store it views, a stored property with an observer is not a view, and a `mutating
    /// get` is a read that writes. Read over the whole file, so an accessor on a private store
    /// is seen as well as one on a view.
    ///
    /// **Mutations:** give `SleepSealPairing.isSealed` a `set { sleepSeal = newValue }` beside a
    /// `get`; make it `mutating get { latestWakeGeneration = latestWakeGeneration &+ 0; return
    /// sleepSeal }`. Run: red on each.
    @Test("No accessor in either value type's file writes")
    func noAccessorInEitherValueTypeWrites() throws {
        let writers = try NSRegularExpression(pattern: Self.writingAccessor)
        for type in Self.valueTypes {
            let code = try MemberAccessScan.strippedSource(of: type.file)
            let found = writers.matches(in: code, range: NSRange(code.startIndex..., in: code))
                .compactMap { Range($0.range, in: code).map { String(code[$0]) } }
            #expect(found.isEmpty, "\(type.file) declares \(found) in an accessor")
        }
    }

    /// Every internal property of either type is computed: a `var` with a type annotation and an
    /// accessor block straight after it, with no `=` before the block and no writing accessor in
    /// it. `theStoresArePrivateAndExactlyTheListedOnes` checks the names, and a name is all an
    /// internal store needs to pass it.
    ///
    /// The precedent is § 5's `ReclamationWatchdogAccessTests.everyInternalPropertyIsAGetOnlyView`,
    /// on the same `MemberAccessScan.accessorBlock(of:in:)`.
    ///
    /// **Mutations:** declare `SleepSealPairing.isSealed` as an internal stored `var isSealed =
    /// false`, set beside `sleepSeal` in `seal(generation:)` and `wake(generation:)`; give it a
    /// `mutating get` that writes `latestWakeGeneration`. Run: red on each.
    @Test("Every internal property of either value type is a computed, get-only view")
    func everyInternalPropertyIsAGetOnlyView() throws {
        let writers = try NSRegularExpression(pattern: Self.writingAccessor)
        for type in Self.valueTypes {
            let code = try Self.membersSource(of: type)
            for name in type.queryNames {
                let block = try #require(
                    try MemberAccessScan.accessorBlock(of: name, in: code),
                    """
                    `\(name)` in \(type.name) has no accessor block straight after its type, so \
                    it has storage: the actor could write `\(type.property).\(name)` past every \
                    named transition, and these must be views.
                    """)
                let found =
                    writers
                    .matches(in: block, range: NSRange(block.startIndex..., in: block))
                    .compactMap { Range($0.range, in: block).map { String(block[$0]) } }
                #expect(
                    found.isEmpty,
                    """
                    `\(name)` in \(type.name) declares \(found) in its accessor block. A view \
                    that can write is a route to the store it views.
                    """)
            }
        }
    }

    /// No file in the helper names the lease core's types through a `typealias`, or extends a
    /// nested one by a dotted path from a file `LeaseAuthorityAccessTests` already lists. The
    /// file set keys on `extension LeaseAuthority`, so `typealias R =
    /// LeaseAuthority.HandbackRegisters` and `extension R { … }` add members where neither suite
    /// looks — a non-mutating `async` one among them.
    ///
    /// **Mutations:** add `Sources/AeolusHelper/Lease/RegistersAlias.swift` declaring
    /// `typealias Registers = LeaseAuthority.HandbackRegisters` and `extension Registers { func
    /// later() async -> Set<Int> { fansMidHandback } }`; add `extension
    /// LeaseAuthority.SleepSealPairing { func later() async -> Bool { isSealed } }` to
    /// `LeaseAuthorityRefusals.swift`. Run: red on each.
    @Test("No file reaches the lease core's types through a typealias or a dotted extension")
    func nothingReachesTheValueTypesAroundTheFileSet() throws {
        let aliases = try SeamScanner.typeAliases(in: Self.helperTarget)
            .filter { !Self.leaseCoreTypes.isDisjoint(with: $0.names) }
            .map { "\($0.file): typealias \($0.name)" }

        let extending = try NSRegularExpression(pattern: #"\bextension\s+([^{]+?)\s*\{"#)
        let nested = Self.leaseCoreTypes.subtracting(["LeaseAuthority"])
        var dotted: [String] = []
        for url in try SeamScanner.swiftFiles(under: Self.helperTarget) {
            let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
            for match in extending.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                if !nested.isDisjoint(with: SeamScanner.identifiers(in: String(code[range]))) {
                    dotted.append("\(url.lastPathComponent): extension \(code[range])")
                }
            }
        }

        #expect(
            aliases.isEmpty && dotted.isEmpty,
            """
            the lease core's types are reached around the file set: \(aliases + dotted). Name \
            them in full inside `extension LeaseAuthority` in a file the access suites list.
            """)
    }

    /// `MemberAccessScan` keys a declaration on its first name, so a tuple pattern or a comma
    /// list adds a store every exact list here would miss. Asserted absent rather than parsed.
    ///
    /// **Mutation:** `private var sealGeneration: UInt64 = 0, extra: UInt64 = 0` in
    /// `SleepSealPairing`. Run: red.
    @Test("Every declaration the exact lists read binds exactly one name")
    func everyDeclarationBindsOneName() throws {
        var found: [String] = []
        for type in Self.valueTypes {
            found += MemberAccessScan.multipleBindings(inSource: try Self.membersSource(of: type))
                .map { "\(type.name): \($0)" }
        }
        found += MemberAccessScan.multipleBindings(
            inSource: try MemberAccessScan.strippedSource(of: Self.actorFile)
        ).map { "\(Self.actorFile): \($0)" }

        #expect(found.isEmpty, "these declarations bind more than one name: \(found)")
    }

    // MARK: - Parsing

    /// A value type's members are at eight spaces of indent, nested in `extension
    /// LeaseAuthority`, and `MemberAccessScan` reads four. Dropping one level brings them to four
    /// and the extension's own declarations to none, which `LeaseAuthorityAccessTests` scans.
    private static func membersSource(of type: ValueType) throws -> String {
        try MemberAccessScan.outdentedSource(of: type.file)
    }
}
