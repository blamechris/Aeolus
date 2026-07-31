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

    /// Every current caller (`ListCommand`, `SensorsCommand`, `DumpFormatter`) builds
    /// each row literally, with exactly as many cells as `headers` — so a row with
    /// *more* cells than `headers` never happens today. `render(headers:rows:)`'s own
    /// contract note ("Every row must have exactly as many cells as `headers`") admits
    /// that is a caller obligation it does not enforce by trapping, though — and
    /// `line(_:)`'s inner closure used to lack the `index < widths.count` bound its
    /// sibling width-computation loop above already had, so a violation of that
    /// contract would have indexed `widths` out of range instead of falling through to
    /// the unpadded-cell branch. A single-column header makes the gap unambiguous: cell
    /// index 1 is neither `cells.count - 1` (the always-unpadded last cell, index 2) nor
    /// within `widths`'s bound (`widths.count == 1`) — exactly the case the guard exists
    /// for, and the case that would crash if it were ever removed.
    @Test("A row with more cells than headers renders the extra cells unpadded, not a crash")
    func rowWiderThanHeadersDoesNotCrash() {
        let table = Table.render(headers: ["A"], rows: [["1", "2", "3"]])

        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0] == "A")
        // "1" is padded to headers' width (1); "2" and "3" have no width to pad to and
        // are carried through exactly as given.
        #expect(lines[1] == "1  2  3")
    }
}
