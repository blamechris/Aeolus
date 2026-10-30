import Foundation
import Testing

/// `ReclamationWatchdog.Registry`'s own shape, asserted rather than described: its four stores
/// are `private` and exactly four, nothing in its file can suspend, and nothing in it takes a
/// closure.
///
/// Split from `ReclamationWatchdogAccessTests`, which says why each rule exists and holds the
/// actor's half — the file set, the actor's private state and exact internal surface, the
/// member-only use of `registry`, the get-only views, and the routes around the scan — so that
/// neither suite crosses SwiftLint's type-body warning. That suite reads `registryFile`,
/// `registryQueryNames` and `registryMembersSource()` from here.
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
/// eight — is in no population here, whether new or already there
/// ([#605](https://github.com/blamechris/Aeolus/issues/605)). A store or a view written so goes
/// missing from its list and is red; a new member is seen by nothing here. An `extension`'s own
/// modifier is on no member's line, so `package extension ReclamationWatchdog {` is read by
/// nothing here, and `HeldFan`'s members, at eight spaces, are in no population.
@Suite("§ 5's registry keeps its stores private, cannot suspend, and takes no closure")
struct ReclamationRegistryAccessTests {

    /// The file that declares `Registry`.
    static let registryFile = "ReclamationRegistry.swift"

    /// `Registry`'s stored properties, every one `private`, **as spelled** (#607). A new one is
    /// § 5 state, which is what this type is for — and adding it is a decision this list records:
    /// `givenUp` is #366's, the lease the terminal action last gave each fan up for.
    private static let registryStores: Set<String> = [
        "private var held", "private var finalising", "private var givenUp",
        "private var registrations",
    ]

    /// `Registry`'s internal properties: computed, get-only views of `held`, as spelled.
    private static let registryQueries: Set<String> = [
        "var isEmpty", "var fans", "var fansInOrder",
    ]

    /// The names behind `registryQueries`, for the check that reads each one's accessor block.
    static var registryQueryNames: [String] {
        registryQueries.map(MemberAccessScan.name(ofPropertySpelling:)).sorted()
    }

    /// Every type a `Registry` method may take. Value types, so nothing handed in can run code
    /// against the registry while a transition is mutating it — a function type, a generic
    /// parameter and a `typealias` for either are all absent from this set.
    private static let registryParameterTypes: Set<String> = [
        "Int", "UUID", "Bool", "UInt64", "CommandedTarget", "FanControlState",
    ]

    /// **Mutations:** declare `var held` without `private`; add `private var extra = 0`. Run: red
    /// on each.
    @Test("The registry's four stores are private, and its internal properties are its views")
    func theRegistrysStoresArePrivateAndExactlyFour() throws {
        let code = try Self.registryMembersSource()
        let properties = MemberAccessScan.members(inSource: code, keyword: .property)
        let stores = Set(properties.filter(\.isPrivate).map(\.spelling))
        let queries = Set(properties.filter { !$0.isPrivate }.map(\.spelling))

        #expect(
            stores == Self.registryStores,
            """
            Registry's private properties changed, as spelled: \
            \(MemberAccessScan.difference(stores, Self.registryStores)). A new store is § 5 \
            state; record it in `registryStores` with the issue that needs it.
            """
        )
        #expect(
            queries == Self.registryQueries,
            """
            Registry's internal properties changed, as spelled: \
            \(MemberAccessScan.difference(queries, Self.registryQueries)).
            """
        )
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
    /// extension's own members to none, which `ReclamationWatchdogAccessTests` already scans.
    static func registryMembersSource() throws -> String {
        try MemberAccessScan.strippedSource(of: registryFile)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
            .joined(separator: "\n")
    }
}
