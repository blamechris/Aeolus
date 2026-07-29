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

    /// One compact JSON value, with no embedded newline — the NDJSON framing
    /// `fanctl watch --json` emits, one line per refresh.
    ///
    /// Deliberately a second function rather than a `pretty: Bool` parameter on
    /// `encode(_:)` above: `encode(_:)`'s pretty-printing is not a style preference, it is
    /// there because its callers (`list`, `sensors`, `dump`) are one-shot commands whose
    /// `--json` output is meant to be pasted whole into a GitHub issue by a human. `watch`
    /// is the opposite shape — a long-running stream a script tails line by line — where
    /// pretty-printing would be actively wrong: a multi-line object per tick makes "one
    /// JSON value per line" (NDJSON's entire contract, and what makes `jq -c` or
    /// `while read -r line` work at all) impossible to tell apart from the next tick's.
    /// `dateEncodingStrategy` and the non-finite-float handling stay identical to
    /// `encode(_:)` so a `capturedAt` field, or a sanitised reading, means the same thing
    /// regardless of which `--json` path produced it.
    static func encodeLine(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
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
        // NDJSON's contract is exactly one JSON value per line. Nothing this CLI encodes
        // is expected to contain a literal newline — and in practice nothing could:
        // JSONEncoder escapes every control character inside a JSON string — but the type
        // system does not rule one out for an arbitrary String field, so this is checked
        // rather than trusted, on the theory that a violation should fail loudly instead of
        // silently corrupting line-based framing for whatever reads the next line as a new
        // object. Checked over `unicodeScalars`, not `Character`: Swift's `String.contains`
        // over `Character` compares by grapheme cluster, and "\r\n" is one grapheme
        // cluster distinct from a lone "\n" `Character` — a scalar-level check is what
        // actually catches both LF and CR regardless of how they're paired.
        guard !string.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw FanctlError.jsonEncodingFailed(
                reason: "encoded line unexpectedly contained a newline")
        }
        return string
    }
}
