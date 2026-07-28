import Foundation
import Testing

@testable import SMCCore
@testable import fanctl

// swiftlint:disable force_unwrapping

/// `hexString(_:)` and `resolvedByteOrderDescription(info:generation:)` are the two pure
/// building blocks `DumpEntry` composes into a row. Neither needs hardware — both are
/// arithmetic over already-known values, exactly like `resolveByteOrder` itself.
@Suite("fanctl dump — hex formatting and byte-order description")
struct DumpFormattingHelperTests {

    @Test("hexString renders lowercase, no separators")
    func hexStringRendersLowercase() {
        #expect(hexString([0x80, 0x20, 0xE7, 0x3F]) == "8020e73f")
        #expect(hexString([0x00, 0x0D, 0x39]) == "000d39")
    }

    @Test("hexString on an empty payload is an empty string, not a placeholder")
    func hexStringOnEmptyPayload() {
        #expect(hexString([]).isEmpty)
    }

    @Test("resolvedByteOrderDescription is nil when the generation is undetermined")
    func nilGenerationYieldsNilDescription() {
        let info = SMCKeyInfo(key: SMCKey("VP3b")!, type: .flt, dataSize: 4, attributes: 133)
        #expect(resolvedByteOrderDescription(info: info, generation: nil) == nil)
    }

    @Test("resolvedByteOrderDescription matches resolveByteOrder, described as words")
    func descriptionMatchesResolver() {
        let bitSet = SMCKeyInfo(key: SMCKey("F0Ac")!, type: .flt, dataSize: 4, attributes: 0x84)
        #expect(
            resolvedByteOrderDescription(info: bitSet, generation: .modern) == "little-endian")

        let bitClear = SMCKeyInfo(key: SMCKey("pcHS")!, type: .ioft, dataSize: 8, attributes: 0xF0)
        #expect(
            resolvedByteOrderDescription(info: bitClear, generation: .modern) == "big-endian")

        let legacyFlt = SMCKeyInfo(key: SMCKey("F0Ac")!, type: .flt, dataSize: 4, attributes: 0x00)
        #expect(
            resolvedByteOrderDescription(info: legacyFlt, generation: .legacy) == "little-endian")
    }

    /// `VP3b` on `Mac16,5`: `flt`, attrs 133 (bit `0x04` set) — see
    /// `docs/SMC-RESEARCH.md` and `docs/ADR/0004-float-byte-order.md`. Pinned here as the
    /// exact case this command exists to make reproducible on other machines.
    @Test("VP3b on Mac16,5 resolves little-endian")
    func vp3bOnMac165ResolvesLittleEndian() {
        let info = SMCKeyInfo(key: SMCKey("VP3b")!, type: .flt, dataSize: 4, attributes: 133)
        #expect(resolvedByteOrderDescription(info: info, generation: .modern) == "little-endian")
    }
}

/// `describeDumpError(_:)` must never hand back the default `String(describing:)` dump of
/// an `SMCError` case, and must never be a bare stack trace — every case gets a
/// human-readable, specific message. Pure and synchronous.
@Suite("fanctl dump — error descriptions")
struct DumpErrorDescriptionTests {

    @Test("notReadable names the key and the attribute bit, not just the enum case")
    func notReadableIsSpecific() {
        let key = SMCKey("AC-E")!
        let description = describeDumpError(SMCError.notReadable(key))
        #expect(description.contains("AC-E"))
        #expect(description.contains("0x80"))
    }

    @Test("firmware includes the SMC result code as hex")
    func firmwareIncludesResultCode() {
        let description = describeDumpError(SMCError.firmware(code: 0x82))
        #expect(description.contains("0x82"))
    }

    @Test("valueTooLargeForSingleRead names the key and the declared size")
    func oversizedIsSpecific() {
        let key = SMCKey("ATP0")!
        let description = describeDumpError(
            SMCError.valueTooLargeForSingleRead(key: key, dataSize: 96))
        #expect(description.contains("ATP0"))
        #expect(description.contains("96"))
    }

    /// Every case in the switch inside `describeDumpError(_:)` is exhaustive over
    /// `SMCError` at compile time — if a case were missing, this file would not build.
    /// What this test adds is the runtime guarantee the compiler cannot: every case
    /// actually produces a non-empty, readable string rather than an empty fallthrough.
    @Test("Every SMCError case produces a non-empty description")
    func everyCaseIsHandled() {
        let key = SMCKey("F0Ac")!
        let cases: [SMCError] = [
            .connectionFailed(kernReturn: -1),
            .keyNotFound(key),
            .firmware(code: 0x00),
            .sizeMismatch(key: key, declared: .flt, reportedBytes: 2),
            .invalidFlagValue(key: key, byte: 0x02),
            .encodingFailed(key: key, type: .flt),
            .encodingNotImplemented(type: .flt),
            .notPermitted,
            .notReadable(key),
            .valueTooLargeForSingleRead(key: key, dataSize: 96),
            .malformedKeyCode(0),
            .invalidIndex(-1),
            .truncatedReply(expected: 80, received: 40),
            .integerByteOrderUndetectable(key: key),
            .implausibleKeyCount(declared: 957_153_280),
        ]
        for error in cases {
            #expect(!describeDumpError(error).isEmpty)
        }
    }

    @Test("A non-SMCError still produces a description rather than crashing")
    func nonSMCErrorFallsBackGracefully() {
        struct OtherError: Error {}
        #expect(!describeDumpError(OtherError()).isEmpty)
    }
}

/// `DumpEntry`'s builder functions are the join point between the three read-failure
/// modes `docs/SMC-RESEARCH.md` records and one uniform row shape. None of this needs a
/// connection — every input is a plain, already-known value.
@Suite("fanctl dump — DumpEntry construction")
struct DumpEntryConstructionTests {

    @Test("A key-table lookup failure carries no metadata, only the failure")
    func indexFailureCarriesNoMetadata() {
        let entry = DumpEntry.forIndexFailure(index: 7, description: "boom")
        #expect(entry.index == 7)
        #expect(entry.type == nil)
        #expect(entry.dataSize == nil)
        #expect(entry.attributes == nil)
        #expect(entry.byteOrder == nil)
        #expect(entry.bytes == nil)
        #expect(entry.error?.contains("boom") == true)
    }

    /// Failure mode 1 of 3: `READ_KEYINFO` fails outright (`BDFU`, `CH0J`, `CHLS` on
    /// `Mac16,5`) — nothing else about the key is knowable.
    @Test("A READ_KEYINFO failure carries the key but no type, size, or attributes")
    func keyInfoFailureCarriesOnlyTheKey() {
        let key = SMCKey("BDFU")!
        let entry = DumpEntry.forKeyInfoFailure(index: 3, key: key, description: "no reply")
        #expect(entry.key == "BDFU")
        #expect(entry.type == nil)
        #expect(entry.attributes == nil)
        #expect(entry.byteOrder == nil)
        #expect(entry.error == "READ_KEYINFO failed: no reply")
    }

    /// Failure mode 2 of 3: the key declares itself unreadable (52 keys on `Mac16,5`,
    /// e.g. `AC-E`: `flag`, attrs 80 — bit `0x80` clear). Metadata, including the
    /// resolved byte order, is still known even though the value never was.
    @Test("A declared-unreadable key keeps its metadata and resolved byte order")
    func unreadableKeyKeepsMetadata() {
        let key = SMCKey("AC-E")!
        let info = SMCKeyInfo(key: key, type: .flag, dataSize: 1, attributes: 80)
        let entry = DumpEntry.forFailedRead(
            index: 3, key: key, info: info,
            description: describeDumpError(SMCError.notReadable(key)), generation: .modern)

        #expect(entry.type == "flag")
        #expect(entry.dataSize == 1)
        #expect(entry.attributes == 80)
        #expect(entry.byteOrder != nil)
        #expect(entry.bytes == nil)
        #expect(entry.error?.contains("unreadable") == true)
    }

    /// Failure mode 3 of 3: the key claims readable and `READ_BYTES` errors anyway (a
    /// further 52 keys on `Mac16,5`, e.g. `aP70`: `ui32`, attrs 148 — bit `0x80` set,
    /// firmware result `0xc7`). Distinguishable from failure mode 2 by the error text,
    /// not by which fields are present — both keep full metadata.
    @Test("A readable-but-erroring key keeps its metadata too")
    func readableButErroringKeyKeepsMetadata() {
        let key = SMCKey("aP70")!
        let info = SMCKeyInfo(key: key, type: .ui32, dataSize: 4, attributes: 148)
        let entry = DumpEntry.forFailedRead(
            index: 1714, key: key, info: info,
            description: describeDumpError(SMCError.firmware(code: 0xC7)), generation: .modern)

        #expect(entry.attributes == 148)
        #expect(entry.bytes == nil)
        #expect(entry.error?.contains("0xc7") == true)
    }

    /// `VP3b` (`flt`, attrs 133, raw `8020e73f`) — pinned to the exact values
    /// `docs/SMC-RESEARCH.md` and `docs/ADR/0004-float-byte-order.md` record for
    /// `Mac16,5`, so this row is directly what a maintainer sees on `--json` output.
    @Test("A successful VP3b read produces the exact row observed on Mac16,5")
    func vp3bSuccessfulReadRow() {
        let key = SMCKey("VP3b")!
        let info = SMCKeyInfo(key: key, type: .flt, dataSize: 4, attributes: 133)
        let value = SMCValue(
            key: key, type: .flt, bytes: [0x80, 0x20, 0xE7, 0x3F], byteOrder: .littleEndian)
        let entry = DumpEntry.forSuccessfulRead(
            index: 42, key: key, info: info, value: value, generation: .modern)

        #expect(entry.key == "VP3b")
        #expect(entry.type == "flt ")
        #expect(entry.dataSize == 4)
        #expect(entry.attributes == 133)
        #expect(entry.byteOrder == "little-endian")
        #expect(entry.bytes == "8020e73f")
        #expect(entry.error == nil)
    }

    @Test("A zero-length successful read reports empty bytes, not nil")
    func zeroLengthReadReportsEmptyBytes() {
        let key = SMCKey("F0Md")!
        let info = SMCKeyInfo(key: key, type: .ui8, dataSize: 0, attributes: 0x80)
        let value = SMCValue(key: key, type: .ui8, bytes: [], byteOrder: nil)
        let entry = DumpEntry.forSuccessfulRead(
            index: 1, key: key, info: info, value: value, generation: .modern)

        #expect(entry.bytes?.isEmpty == true)
        #expect(entry.error == nil)
    }
}

/// `DumpFormatter` renders already-collected `DumpEntry` rows. Both output modes are pure
/// functions over that array — no hardware, no I/O — and both must surface the attribute
/// byte and raw bytes, per ADR 0004's whole reason for this command existing.
@Suite("fanctl dump — rendering")
struct DumpFormatterTests {

    private static let vp3bEntry = DumpEntry(
        index: 42, key: "VP3b", type: "flt ", dataSize: 4, attributes: 133,
        byteOrder: "little-endian", bytes: "8020e73f", error: nil)

    private static let unreadableEntry = DumpEntry(
        index: 3, key: "AC-E", type: "flag", dataSize: 1, attributes: 80,
        byteOrder: "big-endian", bytes: nil,
        error: "AC-E declares itself unreadable (attribute bit 0x80 clear)")

    private static let keyInfoFailureEntry = DumpEntry(
        index: 201, key: "BDFU", type: nil, dataSize: nil, attributes: nil, byteOrder: nil,
        bytes: nil,
        error: "READ_KEYINFO failed: connection to AppleSMC failed (kernel result -536870207)")

    @Test("Table output includes the attribute byte and raw bytes for a successful row")
    func tableIncludesAttributesAndBytes() {
        let table = DumpFormatter.renderTable(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 1)
        #expect(table.contains("VP3b"))
        #expect(table.contains("133"))
        #expect(table.contains("8020e73f"))
        #expect(table.contains("little-endian"))
    }

    @Test("Table output lists a failed row rather than omitting it")
    func tableIncludesFailures() {
        let table = DumpFormatter.renderTable(
            entries: [Self.unreadableEntry, Self.keyInfoFailureEntry], generation: .modern,
            declaredKeyCount: 2)
        #expect(table.contains("AC-E"))
        #expect(table.contains("unreadable"))
        #expect(table.contains("BDFU"))
        #expect(table.contains("READ_KEYINFO failed"))
    }

    @Test("Table output's summary line accounts for every row")
    func tableSummaryAccountsForEveryRow() {
        let table = DumpFormatter.renderTable(
            entries: [Self.vp3bEntry, Self.unreadableEntry, Self.keyInfoFailureEntry],
            generation: .modern, declaredKeyCount: 3)
        #expect(table.contains("3 keys enumerated"))
        #expect(table.contains("1 read successfully"))
        #expect(table.contains("2 failed"))
    }

    @Test("JSON output round-trips the VP3b row with every required field present")
    func jsonRoundTripsVP3b() throws {
        let json = try DumpFormatter.renderJSON(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 1)
        let data = Data(json.utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["generation"] as? String == "modern")
        #expect(object["declaredKeyCount"] as? Int == 1)

        let entries = try #require(object["entries"] as? [[String: Any]])
        let row = try #require(entries.first)
        #expect(row["key"] as? String == "VP3b")
        #expect(row["type"] as? String == "flt ")
        #expect(row["dataSize"] as? Int == 4)
        #expect(row["attributes"] as? Int == 133)
        #expect(row["byteOrder"] as? String == "little-endian")
        #expect(row["bytes"] as? String == "8020e73f")
        #expect(row["error"] == nil || row["error"] is NSNull)
    }

    @Test("JSON output for a failed row omits bytes and reports the failure")
    func jsonReportsFailuresRatherThanOmittingThem() throws {
        let json = try DumpFormatter.renderJSON(
            entries: [Self.unreadableEntry], generation: .modern, declaredKeyCount: 1)
        let data = Data(json.utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        let row = try #require(entries.first)

        #expect(row["key"] as? String == "AC-E")
        #expect(row["bytes"] == nil || row["bytes"] is NSNull)
        let error = try #require(row["error"] as? String)
        #expect(error.contains("unreadable"))
    }

    @Test("Generation description is 'undetermined' rather than a crash when unresolved")
    func undeterminedGenerationDoesNotCrash() {
        let table = DumpFormatter.renderTable(entries: [], generation: nil, declaredKeyCount: 0)
        #expect(table.contains("undetermined"))
    }
}

// swiftlint:enable force_unwrapping
