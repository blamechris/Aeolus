import Foundation
import Testing

/// The rule-zero scans on a `//`-led line of a multi-line literal (#457), read through
/// `RuleZeroScan.code(of:)` as every one of them reads the tree.
///
/// `SeamScannerCommentLineTests` holds the lexer's side of this. What is held here is what the
/// scans then do with the text: the factory in an interpolation on such a line is in reach, and a
/// construction the rule must judge, where it had been removed with the line. The fixtures are
/// lexical text, never compiled or run.
@Suite("The rule-zero scans see an interpolation on a //-led line of a literal")
struct RuleZeroScanCommentLineTests {

    private static func code(_ source: String) -> String { RuleZeroScan.code(of: source) }

    /// The shape #457 names, as a function's result and as a binding.
    private static let hidden: [String] = [
        #"""
        func zzDescribe() -> String {
            """
            //\(HelperComposition<SMCFanControlPlane>.production(log: HelperLog()))
            """
        }
        """#,
        #"""
        let s = """
            //\(HelperComposition.production(log: log))
            """
        """#,
        ##"""
        let s = #"""
            //\#(HelperComposition.production(log: log))
            """#
        """##,
    ]

    /// **Mutation:** put the whole-line filter back in `strippingComments` (split on newlines,
    /// drop each line whose trimmed text begins `//`, join). Run: red here, at every source.
    @Test("The factory on a //-led line of a literal is in reach")
    func theFactoryOnACommentLedLineIsInReach() throws {
        for source in Self.hidden {
            let code = Self.code(source)
            #expect(try RuleZeroScan.reaches(code), "\(source): \(code)")
            #expect(
                try RuleZeroScan.count(RuleZeroScan.productionMember, in: code) == 1,
                "\(source): \(code)")
        }
    }

    /// The rule judges it as it judges any other construction: one that is no `let`'s whole
    /// initialiser, or is one and is not required first, is a violation. A construction on such a
    /// line was invisible to `NotBuiltRequireTripwireTests`.
    ///
    /// **Mutation:** as above. Run: red here.
    @Test("The factory on a //-led line of a literal is a construction the rule judges")
    func theFactoryOnACommentLedLineIsJudged() throws {
        for source in Self.hidden {
            let judged = try RuleZeroScan.constructions(
                in: Self.code("func fixture() async throws {\n\(source)\n}"))
            #expect(judged.count == 1, "\(source): \(judged)")
            #expect(judged.first?.built == .composition, "\(source): \(judged)")
            #expect(judged.first?.violation != nil, "\(source): \(judged)")
        }
    }

    @Test("A comment, and the prose of a //-led line of a literal, are not in reach")
    func proseIsNotInReach() throws {
        let sources = [
            "// let helper = HelperComposition.production(log: log)",
            "    /// HelperComposition.production(log: log)",
            "/* a */ // HelperComposition.production(log: log)",
            "let s = \"\"\"\n    // HelperComposition.production(log: log) in prose\n    \"\"\"",
            "let s = #\"\"\"\n    //HelperComposition.production(log: log)\n    \"\"\"#",
            "let s = \"// HelperComposition.production(log: log)\"",
            "let s = \"\"\"\n    // SMCConnection()\n    \"\"\"",
        ]
        for source in sources {
            #expect(try !RuleZeroScan.reaches(Self.code(source)), "\(source)")
            let judged = try RuleZeroScan.constructions(
                in: Self.code("func fixture() async throws {\n\(source)\n}"))
            #expect(judged.isEmpty, "\(source): \(judged)")
        }
    }

    /// A real comment line next to the literal is dropped, and only it: the literal's line stays.
    @Test("A comment line beside such a literal is dropped, and the literal's line is kept")
    func aCommentLineBesideTheLiteralIsDropped() throws {
        let source = #"""
            // HelperComposition.production(log: Before())
            let s = """
                //\(HelperComposition.production(log: Inside()))
                """
            // HelperComposition.production(log: After())
            """#
        let code = Self.code(source)
        #expect(code.contains("Inside()"), "\(code)")
        #expect(!code.contains("Before"), "\(code)")
        #expect(!code.contains("After"), "\(code)")
        #expect(try RuleZeroScan.count(RuleZeroScan.productionMember, in: code) == 1, "\(code)")
    }
}
