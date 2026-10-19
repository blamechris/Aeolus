import Foundation
import Testing

/// `DeclarationCensus`, held to the spellings a guard built on it must read, on synthetic
/// sources. A census that silently stops seeing a declaration reports a clean file, so it is
/// tested as a guard.
@Suite("The declaration census")
struct DeclarationCensusTests {

    private static func census(_ source: String) -> DeclarationCensus.Census {
        DeclarationCensus.outermost(inSource: source)
    }

    /// The introducer and whether it is private, for each outermost declaration.
    private static func privacy(_ source: String) -> [String] {
        census(source).declarations.map { "\($0.introducer) \($0.isPrivate)" }
    }

    @Test("Only a bare private is private: not private(set), fileprivate or a wider level")
    func onlyABarePrivateIsPrivate() {
        #expect(Self.privacy("private struct A {}") == ["struct true"])
        #expect(Self.privacy("struct A {}") == ["struct false"])
        #expect(Self.privacy("fileprivate func f() {}") == ["func false"])
        #expect(Self.privacy("private(set) var x = 1") == ["var false"])
        #expect(Self.privacy("public private(set) var x = 1") == ["var false"])
        #expect(Self.privacy("internal let x = 1") == ["let false"])
        #expect(Self.privacy("nonisolated(unsafe) private var x = 0") == ["var true"])
        #expect(Self.privacy("private final class A {}") == ["class true"])
        #expect(Self.privacy("private extension Array {}") == ["extension true"])
        #expect(Self.privacy("extension Array {}") == ["extension false"])
    }

    @Test("A modifier on the line above counts, and one an earlier declaration owns does not")
    func theModifierRunIsTheDeclarationsOwn() {
        #expect(Self.privacy("private\nfunc f() {}") == ["func true"])
        #expect(Self.privacy("private let a = b\nfunc leak() {}") == ["let true", "func false"])
        #expect(Self.privacy("private let a = 1; func leak() {}") == ["let true", "func false"])
        #expect(
            Self.privacy("private struct A {} func leak() {}") == ["struct true", "func false"])
        #expect(Self.privacy("private let a = b.c\nfunc leak() {}") == ["let true", "func false"])
    }

    /// A backticked word is a name. Stripping the backticks, as `RuleZeroScan.code(of:)` does,
    /// would read `` `private` `` at the end of one line as the modifier of the next.
    ///
    /// **Mutation:** in `DeclarationCensus.outermost(inSource:)`, strip the backticks as
    /// `RuleZeroScan.code(of:)` does. Run: red here.
    @Test("A backticked name is never a modifier")
    func aBacktickedNameIsNotAModifier() {
        #expect(
            Self.privacy("private let a = `private`\nfunc leak() {}") == ["let true", "func false"])
        #expect(Self.census("private struct `A` {}").declarations.map(\.name) == ["`A`"])
    }

    @Test("Attributes are read with and without arguments, and dotted")
    func attributesAreRead() {
        let declarations = Self.census(
            """
            @Suite("a suite", .timeLimit(.minutes(1)))
            private struct A {}
            @Testing.Suite @available(*, deprecated) private struct B {}
            """
        ).declarations
        #expect(declarations.map(\.attributes) == [["Suite"], ["Testing.Suite", "available"]])
        #expect(declarations.allSatisfy { $0.isPrivate })
    }

    @Test("Every declaration keyword is an introducer, and a contextual one only before a name")
    func everyIntroducerIsFound() {
        for introducer in DeclarationCensus.introducers.sorted() {
            let source = "\(introducer) Name {}"
            #expect(Self.privacy(source) == ["\(introducer) false"], "\(source)")
        }
        #expect(Self.privacy("private let actor = 1") == ["let true"])
        #expect(Self.privacy("private let macro = 1") == ["let true"])
        #expect(Self.privacy("final class func f() {}") == ["func false"])
    }

    @Test("An import declares nothing, whatever kind it names")
    func anImportIsNotADeclaration() {
        for source in [
            "import Foundation", "@testable import SMCCore", "import struct SMCCore.SMCKey",
            "import func Darwin.sqrt", "public import SMCCore",
        ] {
            let read = Self.census(source)
            #expect(read.declarations.isEmpty, "\(source)")
            #expect(read.unreadable.isEmpty, "\(source)")
        }
    }

    @Test("Nothing inside a body, an argument list, a comment or a string is outermost")
    func onlyTheOutermostLevelIsRead() {
        #expect(Self.privacy("private let f = { func inner() {} }") == ["let true"])
        #expect(Self.privacy("private struct A { func inner() {} }") == ["struct true"])
        #expect(Self.privacy("private let x = g(func: 1, [struct])") == ["let true"])
        #expect(Self.privacy("// func leak() {}\n/* struct Leak {} */") == [])
        #expect(Self.privacy(#"private let s = "func leak() {}""#) == ["let true"])
        #expect(
            Self.privacy("private let s = \"\\(1)\"\nfunc leak() {}") == ["let true", "func false"])
    }

    @Test("A body is read as a census of its own")
    func aBodyIsACensus() throws {
        let outer = try #require(
            Self.census(
                "extension A { struct R { let k: Int\n private init() {}\n static func f() {} } }"
            ).declarations.first)
        #expect(outer.introducer == "extension" && outer.name == "A")
        let type = try #require(
            DeclarationCensus.outermost(inCode: outer.body ?? "").declarations.first)
        let members = DeclarationCensus.outermost(inCode: type.body ?? "").declarations
        #expect(members.map(\.introducer) == ["let", "init", "func"])
        #expect(members.map(\.isPrivate) == [false, true, false])
        #expect(members.map(\.modifiers) == [[], ["private"], ["static"]])
    }

    @Test("Conditional compilation is read through, and any other directive is unreadable")
    func directives() {
        let conditional = Self.census("#if DEBUG\nprivate func f() {}\n#else\nfunc g() {}\n#endif")
        #expect(conditional.unreadable.isEmpty)
        #expect(
            conditional.declarations.map { "\($0.name) \($0.isPrivate)" } == ["f true", "g false"])
        #expect(Self.census("#declareSomething(x)").unreadable == ["#declareSomething"])
    }

    @Test("A bracket that does not balance is unreadable, not skipped")
    func unbalancedBracketsAreUnreadable() {
        #expect(!Self.census("private struct A {").unreadable.isEmpty)
        #expect(!Self.census("private struct A {}\n}").unreadable.isEmpty)
        #expect(!Self.census("private let x = (1]").unreadable.isEmpty)
    }
}
