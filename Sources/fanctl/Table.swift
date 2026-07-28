import Foundation

/// A minimal fixed-width table renderer for terminal output.
///
/// Not a general-purpose dependency-worthy formatter — two commands, a handful of
/// left-aligned columns, no wide-character or ANSI-colour handling. If `fanctl` ever
/// needs more than that, reach for a real library instead of growing this one.
enum Table {
    /// Renders `headers` and `rows` as a left-aligned, space-padded table. Every row must
    /// have exactly as many cells as `headers`.
    static func render(headers: [String], rows: [[String]]) -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { index, cell in
                    index == cells.count - 1 ? cell : cell.paddedRight(to: widths[index])
                }
                .joined(separator: "  ")
        }

        return ([headers] + rows).map(line).joined(separator: "\n")
    }
}

extension String {
    fileprivate func paddedRight(to width: Int) -> String {
        let padding = max(0, width - count)
        return self + String(repeating: " ", count: padding)
    }
}
