import Testing

@testable import fanctl

@Suite("Table rendering")
struct TableTests {

    @Test("Columns are padded to the widest cell, header included")
    func columnsPadToWidestCell() {
        let table = Table.render(
            headers: ["KEY", "VALUE"],
            rows: [["F0Ac", "1712"], ["Tp09", "42.5"]])

        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        // "KEY" (3) padded to "F0Ac"/"Tp09"'s width (4), then two spaces before "VALUE".
        #expect(lines[0] == "KEY   VALUE")
        #expect(lines[1] == "F0Ac  1712")
        #expect(lines[2] == "Tp09  42.5")
    }

    @Test("A single row with no other rows still renders both the header and the row")
    func singleRowRendersHeaderAndRow() {
        let table = Table.render(headers: ["A"], rows: [["1"]])
        #expect(table == "A\n1")
    }

    @Test("Rendering with no rows still renders the header line")
    func noRowsStillRendersHeader() {
        let table = Table.render(headers: ["A", "B"], rows: [])
        #expect(table == "A  B")
    }
}
