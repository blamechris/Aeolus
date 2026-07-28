import Foundation

/// Shared JSON encoding for every `--json` output this CLI produces.
///
/// `.github/ISSUE_TEMPLATE/hardware-report.yml` and `sensor-catalog.yml` both ask
/// contributors to paste this output directly into a GitHub issue, so it is
/// pretty-printed with sorted keys — never minified — and a human skims it before any
/// parser sees it.
enum FanctlJSON {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw FanctlError.jsonEncodingFailed(reason: String(describing: error))
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw FanctlError.jsonEncodingFailed(reason: "encoded data was not valid UTF-8")
        }
        return string
    }
}
