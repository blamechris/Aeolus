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
        // nonConformingFloatEncodingStrategy is deliberately left at its default
        // (.throw), not overridden to .convertToString: the contract for a non-finite
        // reading is decided upstream instead, by ListCommand.sanitized(key:value:) and
        // SensorsCommand.sanitize(_:), which turn NaN/±Inf into `null` plus an error
        // string *before* any Double reaches this function — see FanctlError
        // .jsonEncodingFailed's documentation. .convertToString would also make
        // "value" sometimes a string and sometimes a number, which breaks the type
        // stability this format otherwise guarantees. Leaving .throw here means a
        // violation of that upstream contract fails loudly (as jsonEncodingFailed)
        // instead of silently producing a malformed document.

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
