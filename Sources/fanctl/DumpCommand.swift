import ArgumentParser
import Foundation
import SMCCore

/// `fanctl dump` — a full SMC key enumeration for hardware reports.
///
/// This is a research and diagnostic tool for contributors, distinct from `list`/
/// `sensors`/`watch` (end-user monitoring): it exists to turn every hardware report into
/// the observation [ADR 0004](../../docs/ADR/0004-float-byte-order.md) is waiting on. That
/// ADR decided `flt`/`ioft` resolve byte order per key via attribute bit `0x04`, a rule
/// that is unfalsifiable on this project's own machine (every readable `flt`/`ioft` key on
/// `Mac16,5` happens to be bit-set) and names its own discriminator: an M1/M2 report of
/// `VP3b`'s declared type, attribute byte, and raw bytes. `fanctl dump --key VP3b` is how
/// a contributor produces that one row directly, without the full multi-hundred-kilobyte
/// dump a hardware report's issue body cannot hold.
extension Fanctl {
    struct Dump: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Dump every SMC key's type, attributes, and raw bytes.",
            discussion: """
                Enumerates every key via the SMC's own index table — never a hard-coded \
                list — and lists every key that fails to read alongside its failure \
                rather than omitting it. docs/SMC-RESEARCH.md records three distinct \
                read-failure modes on Mac16,5, and a dropped row would make one \
                machine's dump incomparable with another's.

                This is how to collect the report docs/ADR/0004-float-byte-order.md is \
                waiting on: run with --key VP3b and paste its declared type, attribute \
                byte, and raw bytes. The unfiltered dump is hundreds of kilobytes as \
                --json, well over what a GitHub issue body accepts, so --key is the \
                pasteable form; --json without --key is for local inspection or piping \
                to another tool, not for pasting into a report.
                """
        )

        @Flag(name: .long, help: "Emit JSON instead of a table.")
        var json = false

        @Option(
            name: .long,
            help: "Only show this one key (exactly four characters, e.g. VP3b).")
        var key: String?

        func run() async throws {
            if let key, let message = keyFilterFormatError(key) {
                throw ValidationError(message)
            }

            let connection = SMCConnection()

            do {
                try await connection.open()
            } catch {
                throw DumpRuntimeError(
                    message: "Could not open a connection to the SMC: "
                        + describeDumpError(error))
            }

            let declaredCount: Int
            do {
                declaredCount = try await connection.keyCount()
            } catch {
                throw DumpRuntimeError(
                    message: "Could not read #KEY, this machine's declared key count: "
                        + describeDumpError(error))
            }

            let generation = await connection.interfaceGeneration
            var entries = await Self.walk(
                connection: connection, declaredCount: declaredCount, generation: generation)

            // Independent of the walk above: re-probes index `declaredCount` itself,
            // which the walk never visits, so a #KEY that under-declares the real table
            // is caught rather than silently producing a clean-looking dump that is
            // missing keys past the bound. See SMCConnection.verifyKeyCountCrossCheck()
            // and KeyCountCrossCheck.keyExistsPastDeclaredCount.
            let crossCheck = try? await connection.verifyKeyCountCrossCheck()

            if let key {
                entries = filterEntries(entries, byKey: key)
                guard !entries.isEmpty else {
                    throw DumpRuntimeError(
                        message: keyFilterNotFoundMessage(
                            key: key, declaredCount: declaredCount))
                }
            }

            let rendered =
                json
                ? try DumpFormatter.renderJSON(
                    entries: entries, generation: generation, declaredKeyCount: declaredCount,
                    crossCheck: crossCheck)
                : DumpFormatter.renderTable(
                    entries: entries, generation: generation, declaredKeyCount: declaredCount,
                    crossCheck: crossCheck)
            print(rendered)
        }

        /// Walks every index `0..<declaredCount`, building one `DumpEntry` per key
        /// regardless of whether any stage of that key's lookup failed. A failure at any
        /// one key — the index walk itself, `READ_KEYINFO`, or the read — is recorded and
        /// enumeration continues; see `SMCConnection.read(_:)` for the three failure modes
        /// this survives.
        private static func walk(
            connection: SMCConnection, declaredCount: Int, generation: SMCInterfaceGeneration?
        ) async -> [DumpEntry] {
            var entries: [DumpEntry] = []
            entries.reserveCapacity(declaredCount)

            for index in 0..<declaredCount {
                let key: SMCKey
                do {
                    key = try await connection.key(at: index)
                } catch {
                    entries.append(
                        .forIndexFailure(index: index, description: describeDumpError(error)))
                    continue
                }

                let info: SMCKeyInfo
                do {
                    info = try await connection.keyInfo(for: key)
                } catch {
                    entries.append(
                        .forKeyInfoFailure(
                            index: index, key: key, description: describeDumpError(error)))
                    continue
                }

                do {
                    let value = try await connection.read(key)
                    entries.append(
                        .forSuccessfulRead(
                            index: index, key: key, info: info, value: value,
                            generation: generation))
                } catch {
                    entries.append(
                        .forFailedRead(
                            index: index, key: key, info: info,
                            description: describeDumpError(error), generation: generation))
                }
            }

            return entries
        }
    }
}

// MARK: - Errors

/// A runtime failure talking to the SMC — deliberately not `ValidationError`.
/// `ValidationError` prints a usage/help block and exits with `ExitCode.validationFailure`
/// (64), which is correct for a malformed argument and wrong here: opening the SMC
/// connection or reading `#KEY` can fail for reasons that have nothing to do with how the
/// command was invoked, and a usage block below the message wrongly implies the user
/// typed something wrong. Conforming to `LocalizedError` (rather than a plain `Error`)
/// makes `errorDescription` the only text ArgumentParser prints — a clean message, exit
/// code 1, no usage block — which also makes a runtime failure trivially distinguishable
/// from a usage mistake for automation consuming `--json`.
struct DumpRuntimeError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Validates `--key`'s format before any hardware I/O: exactly four ASCII characters,
/// matching `SMCKey`'s own constructor. Returns a ready-to-throw message, or `nil` if the
/// format is fine. Pure, so it is directly unit-testable without a connection — unlike
/// the runtime failures above, a malformed `--key` genuinely is a usage mistake, so the
/// caller throws this as a `ValidationError`, not a `DumpRuntimeError`.
func keyFilterFormatError(_ key: String) -> String? {
    guard SMCKey(key) == nil else { return nil }
    return "--key must be exactly four ASCII characters (e.g. VP3b); got '\(key)' "
        + "(\(key.count) characters)."
}

/// The message for a well-formed `--key` that this machine's key table simply does not
/// contain — a fact about the hardware, not a usage mistake, so the caller throws this as
/// a `DumpRuntimeError`.
func keyFilterNotFoundMessage(key: String, declaredCount: Int) -> String {
    "No key '\(key)' found among the \(declaredCount) keys this machine's index table "
        + "exposes."
}

/// Filters `entries` down to the row(s) matching `key`, or returns them unfiltered if
/// `key` is `nil`. Pure and testable without hardware; turning "matched nothing" into a
/// clear runtime error stays with the caller, which also knows `declaredCount` for the
/// message.
func filterEntries(_ entries: [DumpEntry], byKey key: String?) -> [DumpEntry] {
    guard let key else { return entries }
    return entries.filter { $0.key == key }
}

// MARK: - Row model

/// One row of `fanctl dump`'s output: a single SMC key's declared metadata, raw bytes,
/// and resolved byte order — or, if any stage failed, which stage and why.
///
/// Every field but `index`/`key`/`error` is optional because the read path can be
/// truncated at different stages, matching the three failure modes
/// `docs/SMC-RESEARCH.md` records: `READ_KEYINFO` failing outright leaves nothing else
/// known about the key; a key that declares itself unreadable, or one that claims
/// readable and errors anyway, still has full metadata but no bytes. This is the join of
/// all three shapes rather than a separate case per shape, so rendering never needs to
/// branch on *why* a row is partial — only on which fields are present.
struct DumpEntry: Sendable, Equatable, Codable {
    /// Position in the SMC's own key-table walk, `0..<#KEY`. Not a stable identifier
    /// across machines or even across boots of the same machine — carried only so a
    /// dump can be compared position-by-position against another run if that is ever
    /// useful.
    let index: Int
    /// The four-character SMC key, e.g. `VP3b`. Always present: this is what the index
    /// walk itself returned, before any metadata lookup is attempted. `"????"` only if
    /// the index walk itself failed, which `docs/SMC-RESEARCH.md` has never observed.
    let key: String
    /// The declared type exactly as the SMC spells it (`SMCKeyType.fourCharString`,
    /// trailing space included where the firmware pads to four characters), or `nil` if
    /// `READ_KEYINFO` itself failed for this key.
    let type: String?
    let dataSize: Int?
    /// The raw attribute byte, decimal. Bit `0x80` is "readable"; bit `0x04` is the
    /// per-key byte-order discriminator ADR 0004 asks this command to make visible.
    let attributes: UInt8?
    /// The byte order `resolveByteOrder(generation:attributes:type:)` resolves for this
    /// key — `"little-endian"` or `"big-endian"` — independent of whether the value
    /// itself could be read: this is computed straight from `attributes`/`type`, the
    /// same inputs a successful read would have used. `nil` when `type` is one
    /// `SMCValue.scalar()` never consults a byte order for at all (see
    /// `typeConsultsByteOrder(_:)`), when `attributes`/`type` are themselves unavailable
    /// (`READ_KEYINFO` failed), or when the SMC interface generation could not be
    /// determined for this connection — the same fail-safe `SMCValue.scalar()` applies,
    /// never a guessed or inapplicable order.
    let byteOrder: String?
    /// The raw payload as lowercase hex (e.g. `"8020e73f"`), present only on a
    /// successful read. Empty string for a zero-length `dataSize`, `nil` on any failure.
    let bytes: String?
    /// A human-readable description of whatever went wrong, or `nil` on a full success.
    let error: String?
}

extension DumpEntry {
    /// The index walk itself (`READ_INDEX`) failed for this position. Not observed on
    /// `Mac16,5` — `docs/SMC-RESEARCH.md`'s three failure modes are all downstream of a
    /// successfully resolved key — but the walk must survive it regardless, since the
    /// index table is firmware data this project does not control.
    static func forIndexFailure(index: Int, description: String) -> DumpEntry {
        DumpEntry(
            index: index, key: "????", type: nil, dataSize: nil, attributes: nil,
            byteOrder: nil, bytes: nil, error: "key-table lookup failed: \(description)")
    }

    /// Failure mode 1 of 3: `READ_KEYINFO` fails outright. Observed on 3 keys on
    /// `Mac16,5` (`BDFU`, `CH0J`, `CHLS`) — nothing else about the key is knowable.
    static func forKeyInfoFailure(index: Int, key: SMCKey, description: String) -> DumpEntry {
        DumpEntry(
            index: index, key: key.rawValue, type: nil, dataSize: nil, attributes: nil,
            byteOrder: nil, bytes: nil, error: "READ_KEYINFO failed: \(description)")
    }

    /// A key whose metadata and value were both read successfully.
    static func forSuccessfulRead(
        index: Int, key: SMCKey, info: SMCKeyInfo, value: SMCValue,
        generation: SMCInterfaceGeneration?
    ) -> DumpEntry {
        DumpEntry(
            index: index, key: key.rawValue, type: info.type.fourCharString,
            dataSize: info.dataSize, attributes: info.attributes,
            byteOrder: resolvedByteOrderDescription(info: info, generation: generation),
            bytes: hexString(value.bytes), error: nil)
    }

    /// Failure modes 2 and 3 of 3: metadata was read successfully, but the value was
    /// not — either because the key declares itself unreadable (attribute bit `0x80`
    /// clear, 52 keys on `Mac16,5`) or because it claims readable and `READ_BYTES`
    /// errors anyway (a further 52 keys). `SMCConnection.read(_:)` distinguishes these
    /// as `SMCError.notReadable` versus `SMCError.firmware`; `description` already
    /// carries that distinction through `describeDumpError(_:)`.
    static func forFailedRead(
        index: Int, key: SMCKey, info: SMCKeyInfo, description: String,
        generation: SMCInterfaceGeneration?
    ) -> DumpEntry {
        DumpEntry(
            index: index, key: key.rawValue, type: info.type.fourCharString,
            dataSize: info.dataSize, attributes: info.attributes,
            byteOrder: resolvedByteOrderDescription(info: info, generation: generation),
            bytes: nil, error: description)
    }
}

/// Whether `SMCValue.scalar()` actually consults a resolved byte order when decoding
/// this type — see that function's switch. `flt`/`ioft` and the six plain integers do;
/// every other type either has a byte order fixed by definition
/// (`fpe2`/`fp78`/`sp78`, always big-endian, never firmware-declared) or none at all
/// (`ui8`/`si8`/`flag`, a single byte; `{fds`/`{jst`/`ch8*`/`hex_`/unknown, non-numeric
/// and never decoded as a scalar at all). `resolveByteOrder(generation:attributes:type:)`
/// is total and will still compute *something* for those — that is correct arithmetic
/// but false as evidence in a document meant to be read as one, since nothing in the
/// actual decode path ever looks at the answer. `resolvedByteOrderDescription(info:
/// generation:)` reports `nil` for them instead of a number nobody consumes.
///
/// Internal rather than `private` so it is directly unit-testable.
func typeConsultsByteOrder(_ type: SMCKeyType) -> Bool {
    switch type {
    case .flt, .ioft, .ui16, .si16, .ui32, .si32, .ui64, .si64:
        return true
    case .fpe2, .fp78, .sp78, .ui8, .si8, .flag, .fds, .jst, .ch8, .hex, .unknown:
        return false
    }
}

/// The byte order `resolveByteOrder(generation:attributes:type:)` resolves for `info`,
/// described as `"little-endian"`/`"big-endian"`, or `nil` when either the type never
/// consults a resolved order at all (see `typeConsultsByteOrder(_:)`) or the SMC
/// interface generation could not be determined for this connection — matching
/// `SMCValue.scalar()`'s own fail-safe rather than guessing an order nothing confirmed.
///
/// Internal rather than `private` so it is directly unit-testable without an open
/// hardware connection: every input is a plain value, not I/O.
func resolvedByteOrderDescription(
    info: SMCKeyInfo, generation: SMCInterfaceGeneration?
) -> String? {
    guard typeConsultsByteOrder(info.type) else { return nil }
    guard let generation else { return nil }
    let order = resolveByteOrder(
        generation: generation, attributes: info.attributes, type: info.type)
    switch order {
    case .littleEndian: return "little-endian"
    case .bigEndian: return "big-endian"
    }
}

/// Lowercase hex for a raw byte payload, e.g. `[0x80, 0x20, 0xE7, 0x3F]` → `"8020e73f"`.
/// Empty input yields `""`, not a placeholder string — callers that want a human-facing
/// placeholder for an empty payload apply that at render time (see `DumpFormatter`).
func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// A clear, human-readable description of a failure from the SMC read path — never the
/// default `String(describing:)` dump of an enum case, and never a bare `nil`. Every
/// case in `SMCError` is named explicitly, so a contributor reading a hardware report
/// understands what happened without the source open next to it.
func describeDumpError(_ error: Error) -> String {
    guard let smcError = error as? SMCError else {
        return String(describing: error)
    }
    switch smcError {
    case .connectionFailed(let kernReturn):
        return "connection to AppleSMC failed (kernel result \(kernReturn))"
    case .keyNotFound(let key):
        return "\(key) does not exist on this machine"
    case .firmware(let code):
        let hex = String(format: "%02x", code)
        return "firmware rejected the request (SMC result 0x\(hex))"
    case .sizeMismatch(let key, let declared, let reportedBytes):
        return "\(key) declares \(declared.fourCharString) but returned \(reportedBytes) bytes"
    case .invalidFlagValue(let key, let byte):
        let hex = String(format: "%02x", byte)
        return "\(key) is declared flag but returned 0x\(hex), not 0x00 or 0x01"
    case .encodingFailed(let key, let type):
        return "\(key) (\(type.fourCharString)) value could not be encoded"
    case .encodingNotImplemented(let type):
        return "no encoder implemented yet for \(type.fourCharString)"
    case .notPermitted:
        return "not permitted (this connection has no write access)"
    case .notReadable(let key):
        return "\(key) declares itself unreadable (attribute bit 0x80 clear)"
    case .valueTooLargeForSingleRead(let key, let dataSize):
        return "\(key) declares \(dataSize) bytes, larger than the 32-byte read payload"
    case .malformedKeyCode(let code):
        return "index table returned a malformed key code (\(code))"
    case .invalidIndex(let index):
        return "invalid key-table index \(index)"
    case .truncatedReply(let expected, let received):
        return "truncated SMC reply: expected \(expected) bytes, received \(received)"
    case .integerByteOrderUndetectable(let key):
        return "\(key) byte order undetectable (SMC interface generation unknown)"
    case .implausibleKeyCount(let declared):
        return "#KEY decoded to an implausible value (\(declared))"
    }
}

// MARK: - Rendering

/// Renders `DumpEntry` rows as a table or as JSON. Both are pure functions over already-
/// collected data — no I/O, no hardware — so both are directly unit-testable.
enum DumpFormatter {
    /// A `Codable` mirror of `SMCCore`'s `KeyCountCrossCheck`, which isn't `Codable` and
    /// doesn't need to be outside this one render path.
    struct CrossCheckSummary: Codable, Equatable {
        let matches: Bool
        let declaredCount: Int
        let walkedCount: Int
        let keyExistsPastDeclaredCount: Bool

        init(_ crossCheck: KeyCountCrossCheck) {
            matches = crossCheck.matches
            declaredCount = crossCheck.declaredCount
            walkedCount = crossCheck.walkedCount
            keyExistsPastDeclaredCount = crossCheck.keyExistsPastDeclaredCount
        }
    }

    /// The JSON envelope: entries alongside the context needed to interpret them
    /// (interface generation, declared key count, the cross-check) rather than a bare
    /// array.
    private struct Report: Codable {
        let generation: String
        let declaredKeyCount: Int
        let crossCheck: CrossCheckSummary?
        let entries: [DumpEntry]
    }

    static func renderJSON(
        entries: [DumpEntry], generation: SMCInterfaceGeneration?, declaredKeyCount: Int,
        crossCheck: KeyCountCrossCheck?
    ) throws -> String {
        let report = Report(
            generation: generationDescription(generation), declaredKeyCount: declaredKeyCount,
            crossCheck: crossCheck.map(CrossCheckSummary.init), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    static func renderTable(
        entries: [DumpEntry], generation: SMCInterfaceGeneration?, declaredKeyCount: Int,
        crossCheck: KeyCountCrossCheck?
    ) -> String {
        var lines: [String] = []
        lines.append(
            "SMC interface: \(generationDescription(generation))"
                + "  |  #KEY: \(declaredKeyCount)  |  shown: \(entries.count)")
        lines.append(crossCheckLine(for: crossCheck))
        lines.append("")

        let header = ["INDEX", "KEY", "TYPE", "SIZE", "ATTRS", "ORDER", "BYTES", "ERROR"]
        var rows: [[String]] = [header]
        for entry in entries {
            rows.append(tableRow(for: entry))
        }

        let widths = columnWidths(rows)
        for row in rows {
            lines.append(formatRow(row, widths: widths))
        }

        lines.append("")
        lines.append(summary(for: entries))
        return lines.joined(separator: "\n")
    }

    /// The real cross-check, independent of `entries` entirely: `entries` always has
    /// exactly one row per index in `0..<declaredCount` by construction (or fewer, once
    /// `--key` filters them), so counting them can never disagree with `declaredCount` —
    /// that comparison is a tautology, not a check. What actually tests whether `#KEY`
    /// under-declares the real table is probing index `declaredCount` itself, which the
    /// walk never visits — see `KeyCountCrossCheck.keyExistsPastDeclaredCount` and
    /// `SMCConnection.verifyKeyCountCrossCheck()`, the source of `crossCheck` here.
    private static func crossCheckLine(for crossCheck: KeyCountCrossCheck?) -> String {
        guard let crossCheck else {
            return "Cross-check: unavailable (could not re-verify #KEY against the key table)"
        }
        guard crossCheck.matches else {
            return "Cross-check: MISMATCH — walked \(crossCheck.walkedCount) of "
                + "\(crossCheck.declaredCount) declared; a key exists past the declared "
                + "bound: \(crossCheck.keyExistsPastDeclaredCount). #KEY may be "
                + "under-declaring this machine's real key table."
        }
        return "Cross-check: MATCH — walked \(crossCheck.walkedCount) of "
            + "\(crossCheck.declaredCount) declared; nothing exists past the bound."
    }

    private static func tableRow(for entry: DumpEntry) -> [String] {
        [
            String(entry.index),
            entry.key,
            entry.type?.trimmingCharacters(in: .whitespaces) ?? "-",
            entry.dataSize.map(String.init) ?? "-",
            entry.attributes.map(String.init) ?? "-",
            entry.byteOrder ?? "-",
            entry.bytes.map { $0.isEmpty ? "(empty)" : $0 } ?? "-",
            entry.error ?? "",
        ]
    }

    private static func columnWidths(_ rows: [[String]]) -> [Int] {
        guard let columnCount = rows.first?.count else { return [] }
        return (0..<columnCount).map { column in
            rows.map { $0[column].count }.max() ?? 0
        }
    }

    private static func formatRow(_ row: [String], widths: [Int]) -> String {
        row.enumerated().map { columnIndex, value in
            // The last column (ERROR) is never padded: padding a variable-length,
            // often-empty trailing column would only add invisible whitespace.
            guard columnIndex < row.count - 1 else { return value }
            let width = max(widths[columnIndex], value.count)
            return value.padding(toLength: width, withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }

    private static func summary(for entries: [DumpEntry]) -> String {
        let successCount = entries.filter { $0.error == nil }.count
        let failureCount = entries.count - successCount
        return "\(entries.count) keys enumerated: \(successCount) read successfully, "
            + "\(failureCount) failed."
    }
}

/// `"modern"` / `"legacy"` / `"undetermined"` — shared by both render paths so the JSON
/// and table outputs agree on the same three spellings.
private func generationDescription(_ generation: SMCInterfaceGeneration?) -> String {
    switch generation {
    case .modern: return "modern"
    case .legacy: return "legacy"
    case nil: return "undetermined"
    }
}
