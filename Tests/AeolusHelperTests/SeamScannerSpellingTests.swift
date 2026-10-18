import Foundation
import Testing

/// What the shared stripper and the spawn census read, held to the spellings #441's review found
/// (#442, S1 and S3). Beside `SeamScannerParsingTests`, which is at its length ceiling.
@Suite("The seam scanner's spawn census and block-comment separator")
struct SeamScannerSpellingTests {

    /// The spellings #441 added to the job scan's pattern, now the census's too (#442's review,
    /// S1). `Task(operation: { … })` has no `{` straight after its argument list, so the pattern
    /// this counted with read none of them.
    ///
    /// **Mutation:** put `\bTask(\.detached)?\s*(<[^<>]*>)?\s*(\([^()]*\))?\s*\{` back in
    /// `unstructuredTaskSpawns`. Run: red here, at the first source.
    @Test("An initialiser call with its closure inside the parentheses is a spawn site")
    func closuresInsideTheArgumentListAreCounted() throws {
        let sources = [
            "Task(operation: { await a() })",
            "Task.detached(priority: .background, operation: { await a() })",
            "Task.init(priority: .low, operation: { await a(b()) })",
            "Task<Void, Never>(operation: { await a() })",
            "Task(operation: work)", "Task.immediate { await a() }",
        ]
        for source in sources {
            #expect(try SeamScanner.unstructuredTaskSpawns(inSource: source) == 1, "\(source)")
        }
    }

    /// Comments and strings are removed before the count, trailing comments too: the old pattern
    /// needed a `{`, which prose rarely has, and the new one needs only `Task(`.
    @Test("The word Task in a trailing comment or a string is not a spawn site")
    func proseIsNotASpawnSite() throws {
        let source = """
            let value = 1  // spawns a Task (see the supervisor)
            let text = "Task (detached) { }"
            /* Task(operation: { }) */
            """

        #expect(try SeamScanner.unstructuredTaskSpawns(inSource: source) == 0)
    }

    /// **S3.** Swift reads `public/* */import` as two words, and so must every pattern built on
    /// this stripper: joined, `publicimport` is a word no pattern for an import finds.
    ///
    /// **Mutation:** in `strippingBlockComments`, drop the space. Run: red here.
    @Test("A stripped block comment leaves one space, however many lines it spans")
    func aBlockCommentLeavesASpace() throws {
        #expect(
            SeamScanner.strippingComments("public/* */import SMCCore") == "public import SMCCore")
        #expect(SeamScanner.strippingComments("a/* x */b/* y */c") == "a b c")
        #expect(SeamScanner.strippingComments("a/* x\ny */b") == "a \nb")
        #expect(SeamScanner.strippingComments("a/* outer /* inner */ */b") == "a b")
        #expect(SeamScanner.strippingAllComments("public/**/import") == "public import")
    }
}
