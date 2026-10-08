import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `CriticalSensorSet.allCurated` is every curated set (ADR 0012, "Outstanding reads, and why
/// D_cycle is 15 s").
///
/// The watchdog's cycle bound is sized from a set's key count, and `WatchdogLimitsTests` checks
/// that bound against each set in `allCurated`. That is only as good as the list: a set that is
/// declared, or reachable from `resolve(for:)`, and is not in it is a set no bound is ever
/// checked against, and a family with 85 keys against a turn of 64 would move D_cycle under the
/// watchdog with every test green. So the list is checked against the source two ways, neither
/// of which depends on how the set is spelled:
///
/// - **by what is declared**: every `static let`/`var` of type `CriticalSensorSet`, or built
///   with `CriticalSensorSet(`, `Self(`, `.init(` or their `.init` forms, is listed, by exact
///   name;
/// - **by what is reachable**: every string literal in `resolve(for:)` is a model identifier,
///   and what it resolves to is a listed set or the empty one.
@Suite("Every curated critical set is listed")
struct CriticalSensorSetCompletenessTests {

    private func setSource() throws -> String {
        let url = SeamScanner.sourcesRoot.appendingPathComponent(
            "AeolusHelper/Safety/CriticalSensorSet.swift")
        return WatchdogConfigurationTripwireTests.normalised(
            SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8)))
    }

    /// The sets that are declared in `code` (normalised), other than the empty one for
    /// unidentified hardware: a `static` of type `CriticalSensorSet`, whatever it is built
    /// with, or a `static` built by any of the initialiser spellings, whatever its type.
    static func declaredSetNames(in code: String) throws -> Set<String> {
        let annotated = #"static (?:let|var) (\w+) ?: ?CriticalSensorSet\b"#
        let constructed =
            #"static (?:let|var) (\w+) ?(?::[\w.<>\[\]?! ]*)?= ?"#
            + #"(?:(?:CriticalSensorSet|Self)\.init|CriticalSensorSet|Self|\.init)\("#
        var names: Set<String> = []
        for pattern in [annotated, constructed] {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            for match in expression.matches(in: code, range: range) {
                if let name = Range(match.range(at: 1), in: code) {
                    names.insert(String(code[name]))
                }
            }
        }
        return names.subtracting(["unidentifiedHardware", "allCurated"])
    }

    /// The names listed in `allCurated`, each reduced to its last component (`.mac16x5`,
    /// `CriticalSensorSet.mac16x5` and `Self.mac16x5` are `mac16x5`).
    static func listedSetNames(in code: String) throws -> Set<String> {
        let list = try NSRegularExpression(
            pattern: #"static let allCurated ?: ?\[CriticalSensorSet\] ?= ?\[([^\]]*)\]"#)
        guard
            let match = list.firstMatch(
                in: code, range: NSRange(code.startIndex..<code.endIndex, in: code)),
            let inner = Range(match.range(at: 1), in: code)
        else { return [] }
        return Set(
            code[inner].split(separator: ",").compactMap { element in
                let name = element.split(separator: ".").last.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                return name?.isEmpty == false ? name : nil
            })
    }

    /// **Mutation:** declare `static let mac16x6: CriticalSensorSet = .init(…)` and leave it
    /// out of `allCurated`. Run: red.
    /// **Mutation:** declare `static let mac17x1 = CriticalSensorSet(…)` and leave it out. Run:
    /// red.
    @Test("Every curated set is in the list the bound is checked against")
    func everyCuratedSetIsListed() throws {
        let code = try setSource()
        let declared = try Self.declaredSetNames(in: code)
        let listed = try Self.listedSetNames(in: code)
        #expect(declared.contains("mac16x5"), "the scan no longer finds the Mac16,5 set")
        #expect(!listed.isEmpty, "`allCurated` is empty or is no longer a literal list")
        #expect(
            declared == listed,
            """
            allCurated lists \(listed.sorted()) and the source declares \(declared.sorted()). \
            D_cycle is sized from a set's key count, so a set the list leaves out is a set the \
            bound is never checked against.
            """)
    }

    /// Every machine the resolver names gets a set that is listed, or the empty one. This is the
    /// half that does not care how a set is declared: an inline `CriticalSensorSet(…)` in a
    /// `return`, a set built in another file, a `Self(…)` all end in a value, and the value is
    /// either in `allCurated` or it is not.
    ///
    /// **Mutation:** `case "Mac16,6": return .mac16x6` for a set left out of `allCurated`.
    /// Run: red.
    /// **Mutation:** an inline `return CriticalSensorSet(keys: …)` for a new model. Run: red.
    @Test("Every set the resolver can return is listed")
    func everyResolvedSetIsListed() throws {
        let body = try #require(
            WatchdogBoundsTripwireTests.body(
                ofTypeDeclaredBy:
                    "static func resolve(for identity: HardwareIdentity) -> CriticalSensorSet",
                in: try setSource()),
            "resolve(for:) is no longer declared with this signature")
        let literals = try Self.stringLiterals(in: body)
        #expect(literals.contains("Mac16,5"), "the scan no longer finds the Mac16,5 literal")
        for model in literals {
            let resolved = CriticalSensorSet.resolve(
                for: HardwareIdentity(modelIdentifier: model, chipFamily: nil))
            #expect(
                resolved == .unidentifiedHardware
                    || CriticalSensorSet.allCurated.contains(resolved),
                "\(model) resolves to a set (\(resolved.provenance)) that allCurated does not list")
        }
    }

    static func stringLiterals(in code: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #""([^"\\]*)""#)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return expression.matches(in: code, range: range).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// The scans, over fixtures.
    ///
    /// **Mutation:** make `declaredSetNames(in:)` return an empty set. Run: red.
    /// **Mutation:** drop `.init` from the constructed pattern. Run: red.
    /// **Mutation:** match the listing by substring. Run: red — `mac16` is not `mac16x5`.
    @Test("The completeness scans read a declaration the way Swift does")
    func theScansSeeWhatTheyShould() throws {
        let normalised = WatchdogConfigurationTripwireTests.normalised
        let declared = try Self.declaredSetNames(
            in: normalised(
                """
                static let a = CriticalSensorSet(
                static let b: CriticalSensorSet = CriticalSensorSet (
                static let c: CriticalSensorSet = .init(
                static let d = Self(
                static let e = Self.init(
                static let f = CriticalSensorSet.init(
                static var g: CriticalSensorSet { make() }
                static let h = `CriticalSensorSet`(
                static let unidentifiedHardware = CriticalSensorSet(
                static let allCurated: [CriticalSensorSet] = [a]
                static let notASet = 3
                static func resolve(for x: Int) -> CriticalSensorSet {
                """))
        #expect(declared == ["a", "b", "c", "d", "e", "f", "g", "h"])

        let listed = try Self.listedSetNames(
            in: normalised(
                """
                static let allCurated: [CriticalSensorSet] = [
                    mac16x5, .mac16x6, CriticalSensorSet.mac17x1, Self.mac18x1,
                ]
                """))
        #expect(listed == ["mac16x5", "mac16x6", "mac17x1", "mac18x1"])
        // Exact names: a set called `mac16` is not listed by a list that has `mac16x5`.
        let mac16 = try Self.listedSetNames(
            in: normalised("static let allCurated: [CriticalSensorSet] = [mac16x5]"))
        #expect(mac16 != ["mac16"])
        #expect(Set(["mac16", "mac16x5"]).subtracting(mac16) == ["mac16"])

        #expect(
            try Self.stringLiterals(in: #"case "Mac16,5": return .a; case "X","Y": r"#) == [
                "Mac16,5", "X", "Y",
            ])
    }
}
