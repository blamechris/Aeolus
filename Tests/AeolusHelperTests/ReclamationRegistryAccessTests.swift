import Foundation
import Testing

/// `ReclamationWatchdog.Registry`'s own shape, asserted rather than described: its three stores
/// are `private` and exactly three, nothing in its file can suspend, and nothing in it takes a
/// closure.
///
/// Split from `ReclamationWatchdogAccessTests`, which says why each rule exists and holds the
/// actor's half — the file set, the actor's private state and exact internal surface, the
/// member-only use of `registry`, the get-only views, and the routes around the scan — so that
/// neither suite crosses SwiftLint's type-body warning. That suite reads `registryFile`,
/// `registryQueries` and `registryMembersSource()` from here.
@Suite("§ 5's registry keeps its stores private, cannot suspend, and takes no closure")
struct ReclamationRegistryAccessTests {

    /// The file that declares `Registry`.
    static let registryFile = "ReclamationRegistry.swift"

    /// `Registry`'s stored properties, every one `private`. A new one is § 5 state, which is
    /// what this type is for — and adding it is a decision this list records.
    private static let registryStores: Set<String> = ["held", "finalising", "registrations"]

    /// `Registry`'s internal properties: computed, get-only views of `held`.
    static let registryQueries: Set<String> = ["isEmpty", "fans", "fansInOrder"]

    /// Every type a `Registry` method may take. Value types, so nothing handed in can run code
    /// against the registry while a transition is mutating it — a function type, a generic
    /// parameter and a `typealias` for either are all absent from this set.
    private static let registryParameterTypes: Set<String> = [
        "Int", "UUID", "Bool", "UInt64", "CommandedTarget", "FanControlState",
    ]

    /// **Mutations:** declare `var held` without `private`; add `private var extra = 0`. Run: red
    /// on each.
    @Test("The registry's three stores are private, and its internal properties are its views")
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
