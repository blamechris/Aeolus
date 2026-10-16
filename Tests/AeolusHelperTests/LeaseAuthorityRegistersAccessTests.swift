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
/// - **Every internal property is a view, and no accessor in either file writes.**
/// - **Nothing reaches either type around the file set**, by a `typealias` or a dotted extension.
///
/// `LeaseAuthorityAccessTests` holds the actor's half — its file set read off the tree, the two
/// properties `private`, its internal surface exact. The parse is `MemberAccessScan` and
/// `SeamScanner`'s, as for § 5's registry; nothing here is a second scanner.
@Suite("The lease core's registers and sleep seal are values the actor reaches only by member")
struct LeaseAuthorityRegistersAccessTests {

    /// One value type, where it is declared, what holds it, and what it may contain.
    private struct ValueType {
        let name: String
        let file: String
        /// The actor's `private` property holding the one instance that governs anything.
        let property: String
        /// Its stored properties, every one `private`. A new one is lease-core state, and adding
        /// it is a decision recorded here.
        let stores: Set<String>
        /// Its internal properties: computed, get-only views of the stores.
        let queries: Set<String>
    }

    private static let valueTypes = [
        ValueType(
            name: "HandbackRegisters", file: "LeaseAuthorityHandbackRegisters.swift",
            property: "registers",
            stores: [
                "releasing", "restoreAbandoned", "handbackAcceptedUnconfirmed",
                "handbackUnconfirmed",
            ],
            queries: [
                "abandonedHandbacks", "unconfirmedHandbacks", "fansMidHandback",
                "handbacksOwedAReadBack",
            ]),
        ValueType(
            name: "SleepSealPairing", file: "LeaseAuthoritySleepSealPairing.swift",
            property: "sleep",
            stores: ["sleepSeal", "latestWakeGeneration", "sealGeneration"],
            queries: ["isSealed"]),
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

    /// **Mutations:** declare `HandbackRegisters`' `var releasing` without `private`; add
    /// `private var extra = 0` to `SleepSealPairing`. Run: red on each.
    @Test("Each value type's stores are private and exactly the listed ones; the rest are views")
    func theStoresArePrivateAndExactlyTheListedOnes() throws {
        for type in Self.valueTypes {
            let properties = MemberAccessScan.members(
                inSource: try Self.membersSource(of: type), keyword: .property)
            let stores = Set(properties.filter(\.isPrivate).map(\.key))
            let queries = Set(properties.filter { !$0.isPrivate }.map(\.key))

            #expect(
                stores == type.stores,
                """
                \(type.name)'s private properties changed: found \(stores.sorted()), \
                acknowledged \(type.stores.sorted()). A new store is lease-core state; record it \
                here with the issue that needs it.
                """)
            #expect(
                queries == type.queries,
                """
                \(type.name)'s internal properties changed: found \(queries.sorted()), \
                acknowledged \(type.queries.sorted()). An internal store is writable state.
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

    /// No accessor in either file can write: a view with a `set` or a `_modify` is a route to
    /// the store it views, and a stored property with an observer is not a view.
    ///
    /// **Mutation:** give `SleepSealPairing.isSealed` a `set { sleepSeal = newValue }` beside a
    /// `get`. Run: red.
    @Test("No accessor in either value type's file writes")
    func noAccessorInEitherValueTypeWrites() throws {
        let writers = try NSRegularExpression(
            pattern: #"\b(set|_modify|willSet|didSet|unsafeMutableAddress)\b"#)
        for type in Self.valueTypes {
            let code = try MemberAccessScan.strippedSource(of: type.file)
            let found = writers.matches(in: code, range: NSRange(code.startIndex..., in: code))
                .compactMap { Range($0.range, in: code).map { String(code[$0]) } }
            #expect(found.isEmpty, "\(type.file) declares \(found) in an accessor")
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
        try MemberAccessScan.strippedSource(of: type.file)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
    }
}
