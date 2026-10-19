import Foundation
import Testing

/// The rule-zero scans on a comment inside an interpolation (#460), read through
/// `RuleZeroScan.code(of:)` as every one of them reads the tree.
///
/// `SeamScannerInterpolationCommentTests` holds the lexer's side. What is held here is what
/// `NotBuiltRequireTripwireTests` then does with the text. Its first-use check reads the first
/// mention of a composition's binding after the construction, and a comment in an interpolation
/// that spelled the require was that mention:
///
/// ```swift
/// let helper = HelperComposition<SMCFanControlPlane>.production(log: HelperLog())
/// let s = """
///     \(f(1
///     // ;try #require(!helper.plane.holdsWriteChannel)
///     ))
///     """
/// await helper.run()
/// ```
///
/// The comment is not code, and `helper.run()` is the first use. Nobody writes this by accident,
/// and the graph `production` builds has no write channel, so this closes a hole in what the scans
/// read and not a route to the SMC. ADR 0014's compiler seam is the control; these scans catch
/// accidents. The fixtures are lexical text, never compiled or run.
@Suite("The rule-zero scans do not read a comment inside an interpolation as code")
struct RuleZeroScanInterpolationCommentTests {

    private static let build =
        "let helper = HelperComposition<SMCFanControlPlane>.production(log: L())"
    private static let require = "try #require(!helper.plane.holdsWriteChannel, \"held\")"

    /// A literal holding the comment, and the shape of the comment: the require as its text.
    private static let comments: [(name: String, literal: String)] = [
        (
            "a comment line",
            #"""
            let s = """
                \(f(1
                // ;try #require(!helper.plane.holdsWriteChannel)
                ))
                """
            """#
        ),
        (
            "a trailing comment",
            #"""
            let s = """
                \(f(1 // ;try #require(!helper.plane.holdsWriteChannel)
                ))
                """
            """#
        ),
        (
            "a block comment",
            #"""
            let s = """
                \(f(1 /* ;try #require(!helper.plane.holdsWriteChannel) */))
                """
            """#
        ),
        (
            "a raw literal",
            ##"""
            let s = #"""
                \#(f(1
                // ;try #require(!helper.plane.holdsWriteChannel)
                ))
                """#
            """##
        ),
    ]

    private static func judged(_ body: String) throws -> [RuleZeroScan.Construction] {
        try RuleZeroScan.constructions(
            in: RuleZeroScan.code(of: "func fixture() async throws {\n\(body)\n}"))
    }

    /// The require that is only a comment is no require: the first use is the call after the
    /// literal, and the rule judges it.
    ///
    /// **Mutation:** put `copyDelimited`'s copy of an interpolation back to the text as it
    /// stands. Run: red here, at every shape. Put in a `Tests/` file that reaches a connection,
    /// the same shape is red at `NotBuiltRequireTripwireTests`.
    @Test("A require that is only a comment in an interpolation is not the first use")
    func aCommentedRequireIsNotTheFirstUse() throws {
        for (name, literal) in Self.comments {
            let found = try Self.judged("\(Self.build)\n\(literal)\nawait helper.run()")
            #expect(found.count == 1, "\(name): \(found)")
            #expect(found.first?.binding == "helper", "\(name): \(found)")
            #expect(
                found.first?.violation?.contains("first later use") == true,
                "\(name): \(found)")
        }
    }

    /// The control: the same shapes with the real require first. The rule holds, so the test
    /// above is red for the comment in the interpolation, and not because these shapes fail the
    /// rule whatever they hold.
    @Test("A real require before such a literal still satisfies the rule")
    func aRealRequireStillSatisfiesTheRule() throws {
        for (name, literal) in Self.comments {
            let found = try Self.judged(
                "\(Self.build)\n\(Self.require)\n\(literal)\nawait helper.run()")
            #expect(found.count == 1, "\(name): \(found)")
            #expect(found.first?.violation == nil, "\(name): \(found)")
        }
    }

    /// The factory named only in a comment inside an interpolation is prose, not reach. The first
    /// source holds `))` in the comment before the factory: counted, they ended the interpolation
    /// at the comment, and what followed was read as code once the comment was gone.
    ///
    /// **Mutation:** take the comment skip out of `interpolationEnd`. Run: red here, at that
    /// source.
    @Test("The factory named in a comment inside an interpolation is not in reach")
    func theFactoryInACommentIsNotInReach() throws {
        let sources = [
            #"""
            let s = """
                \(f(1, // )) HelperComposition.production(log: L())
                ))
                """
            """#,
            #"""
            let s = """
                \(f(1
                // HelperComposition.production(log: L())
                ))
                """
            """#,
            #"""
            let s = """
                \(f(1 // HelperComposition.production(log: L())
                ))
                """
            """#,
            #"""
            let s = """
                \(f(1 /* HelperComposition.production(log: L()) */))
                """
            """#,
        ]
        for source in sources {
            #expect(try !RuleZeroScan.reaches(RuleZeroScan.code(of: source)), "\(source)")
        }
    }
}
