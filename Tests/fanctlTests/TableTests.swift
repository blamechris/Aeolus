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

    /// `render(headers:rows:)`'s contract says every row must have exactly as many cells
    /// as `headers` — but does not enforce it by trapping (see that function's own
    /// documentation). Its `line(_:)` closure carries the same `index < widths.count`
    /// bound the width-computation loop above it has, specifically so a row that
    /// violates the contract falls through to an unpadded cell (see the assertion below)
    /// instead of indexing `widths` out of range. Nothing before this test actually
    /// exercised that branch — a caller could have dropped the guard and every other
    /// test here would still pass.
    @Test("A row with more cells than headers renders without crashing")
    func rowWiderThanHeadersDoesNotCrash() {
        let table = Table.render(headers: ["A", "B"], rows: [["1", "2", "3", "4"]])
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0] == "A  B")
        // Every cell padded up to (and including) the header count is still joined with
        // the usual two-space separator; index 2 is the first past `widths.count` (2)
        // that is not also the row's last cell, so it is exactly what would have
        // trapped without the bound — see the doc comment above.
        #expect(lines[1] == "1  2  3  4")
    }
}
