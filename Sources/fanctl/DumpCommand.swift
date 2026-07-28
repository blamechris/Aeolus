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
/// `VP3b`'s declared type, attribute byte, and raw bytes. `fanctl dump --json` is how a
/// contributor produces that in one command instead of building a throwaway tool.
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
                waiting on: run with --json and look at the VP3b row for its declared \
                type, attribute byte, and raw bytes.
                """
        )

        @Flag(name: .long, help: "Emit JSON instead of a table.")
        var json = false

        func run() async throws {
            let connection = SMCConnection()

            do {
                try await connection.open()
            } catch {
                throw ValidationError(
                    "Could not open a connection to the SMC: \(describeDumpError(error))")
            }

            let declaredCount: Int
            do {
                declaredCount = try await connection.keyCount()
            } catch {
                throw ValidationError(
                    "Could not read #KEY, this machine's declared key count: "
                        + describeDumpError(error))
            }

            let generation = await connection.interfaceGeneration
            let entries = await Self.walk(
                connection: connection, declaredCount: declaredCount, generation: generation)

            let rendered =
                json
                ? try DumpFormatter.renderJSON(
                    entries: entries, generation: generation, declaredKeyCount: declaredCount)
                : DumpFormatter.renderTable(
                    entries: entries, generation: generation, declaredKeyCount: declaredCount)
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
    /// same inputs a successful read would have used. `nil` when `attributes`/`type` are
    /// themselves unavailable (`READ_KEYINFO` failed) or the SMC interface generation
    /// could not be determined for this connection — the same fail-safe
    /// `SMCValue.scalar()` applies, never a guessed order.
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

/// The byte order `resolveByteOrder(generation:attributes:type:)` resolves for `info`,
/// described as `"little-endian"`/`"big-endian"`, or `nil` if the SMC interface
/// generation could not be determined for this connection — matching
/// `SMCValue.scalar()`'s own fail-safe rather than guessing an order nothing confirmed.
///
/// Internal rather than `private` so it is directly unit-testable without an open
/// hardware connection: every input is a plain value, not I/O.
func resolvedByteOrderDescription(
    info: SMCKeyInfo, generation: SMCInterfaceGeneration?
) -> String? {
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
    /// The JSON envelope: entries alongside the context needed to interpret them
    /// (interface generation, declared key count) rather than a bare array.
    private struct Report: Codable {
        let generation: String
        let declaredKeyCount: Int
        let entries: [DumpEntry]
    }

    static func renderJSON(
        entries: [DumpEntry], generation: SMCInterfaceGeneration?, declaredKeyCount: Int
    ) throws -> String {
        let report = Report(
            generation: generationDescription(generation), declaredKeyCount: declaredKeyCount,
            entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    static func renderTable(
        entries: [DumpEntry], generation: SMCInterfaceGeneration?, declaredKeyCount: Int
    ) -> String {
        var lines: [String] = []
        lines.append(
            "SMC interface: \(generationDescription(generation))"
                + "  |  #KEY: \(declaredKeyCount)  |  rows: \(entries.count)")
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
