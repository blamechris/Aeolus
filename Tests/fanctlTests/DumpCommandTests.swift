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

        // pcHS on Mac16,5: ioft, attrs 0xF0 — bit 0x80 set (it declares itself readable),
        // bit 0x04 clear. It never yields bytes (firmware rejects READ_BYTES with 0x82),
        // but ioft is still a type whose byte order is firmware-declared, so the resolved
        // order is knowable regardless — see docs/SMC-RESEARCH.md.
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

    /// `SMCValue.scalar()` only ever consults a resolved byte order for `flt`/`ioft` and
    /// the six plain integers — see that function's switch. Every other type either has a
    /// byte order fixed by the type itself (`fpe2`/`fp78`/`sp78`) or none at all (a single
    /// byte, or non-numeric). `typeConsultsByteOrder(_:)` is the one place that
    /// distinction lives; a wrong answer here means a dump row claims to resolve an order
    /// nothing in the decoder ever looks at.
    @Test("typeConsultsByteOrder is true only for flt/ioft and the six plain integers")
    func typeConsultsByteOrderMatchesTheDecoder() {
        let consulted: [SMCKeyType] = [
            .flt, .ioft, .ui16, .si16, .ui32, .si32, .ui64, .si64,
        ]
        for type in consulted {
            #expect(typeConsultsByteOrder(type), "\(type.fourCharString) should consult")
        }

        let notConsulted: [SMCKeyType] = [
            .fpe2, .fp78, .sp78, .ui8, .si8, .flag, .fds, .jst, .ch8, .hex, .unknown(0),
        ]
        for type in notConsulted {
            #expect(!typeConsultsByteOrder(type), "\(type.fourCharString) should not consult")
        }
    }

    /// `AC-M` on `Mac16,5`: `hex_`, attrs 212 (bit `0x04` set), raw `0101`. `hex_` is
    /// documented "surfaced raw; never interpreted" — `resolveByteOrder` still computes
    /// an answer for it (the function is total over every type), but
    /// `resolvedByteOrderDescription` must not report it: nothing in `SMCValue.scalar()`
    /// ever consults it for this type, so showing "little-endian" here would be
    /// arithmetically correct and evidentially false.
    @Test("A non-numeric type (hex_) never reports a resolved byte order")
    func nonNumericTypeReportsNoByteOrder() {
        let info = SMCKeyInfo(key: SMCKey("AC-M")!, type: .hex, dataSize: 2, attributes: 212)
        #expect(resolvedByteOrderDescription(info: info, generation: .modern) == nil)
    }

    /// `fpe2`/`fp78`/`sp78` are big-endian *by definition of the type* — never
    /// firmware-declared, never attribute-bit-resolved — so a dump row must not present
    /// them as having a "resolved" order at all, even though `resolveByteOrder` itself
    /// still answers `.bigEndian` for them if asked directly.
    @Test("Fixed-by-type formats (fpe2/fp78/sp78) never report a resolved byte order")
    func fixedByTypeReportsNoByteOrder() {
        let fpe2 = SMCKeyInfo(key: SMCKey("F0Ac")!, type: .fpe2, dataSize: 2, attributes: 0x84)
        let sp78 = SMCKeyInfo(key: SMCKey("TC0P")!, type: .sp78, dataSize: 2, attributes: 0x84)
        #expect(resolvedByteOrderDescription(info: fpe2, generation: .modern) == nil)
        #expect(resolvedByteOrderDescription(info: sp78, generation: .modern) == nil)
    }

    /// Single-byte types have no byte order to resolve at all, regardless of the
    /// attribute bit or the generation.
    @Test("Single-byte types (ui8/flag) never report a resolved byte order")
    func singleByteTypeReportsNoByteOrder() {
        let ui8 = SMCKeyInfo(key: SMCKey("FNum")!, type: .ui8, dataSize: 1, attributes: 0x84)
        let flag = SMCKeyInfo(key: SMCKey("AC-E")!, type: .flag, dataSize: 1, attributes: 0x80)
        #expect(resolvedByteOrderDescription(info: ui8, generation: .modern) == nil)
        #expect(resolvedByteOrderDescription(info: flag, generation: .modern) == nil)
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

/// `--key`'s own pure format helper, plus `FanctlError.keyNotFound` — the fix for using
/// `ValidationError` (usage block, exit 64) for a runtime SMC failure that has nothing to
/// do with how the command was invoked, and for making the "paste one row" workflow ADR
/// 0004 asks for actually followable. `dump` used to raise its own ad hoc
/// `DumpRuntimeError` for exactly this; it now shares `FanctlError` with `list`/`sensors`/
/// `watch` — see `FanctlErrorTests.swift` for that type's own coverage, including
/// `.keyNotFound`.
@Suite("fanctl dump — --key filtering")
struct DumpKeyFilterTests {

    @Test("keyFilterFormatError accepts exactly four ASCII characters")
    func formatErrorAcceptsFourCharacters() {
        #expect(keyFilterFormatError("VP3b") == nil)
        #expect(keyFilterFormatError("#KEY") == nil)
    }

    @Test("keyFilterFormatError rejects the wrong length, naming what was given")
    func formatErrorRejectsWrongLength() {
        let tooShort = keyFilterFormatError("VP3")
        let tooLong = keyFilterFormatError("VP3bb")
        #expect(tooShort?.contains("VP3") == true)
        #expect(tooShort?.contains("four") == true)
        #expect(tooLong?.contains("VP3bb") == true)
    }

    @Test("--key of the wrong length is rejected before any hardware I/O, like --interval")
    func malformedKeyRejectedAtParseTime() {
        #expect(throws: (any Error).self) {
            try Fanctl.Dump.parse(["--key", "VP3"])
        }
    }

    @Test("A well-formed --key is accepted at parse time")
    func wellFormedKeyAcceptedAtParseTime() throws {
        _ = try Fanctl.Dump.parse(["--key", "VP3b"])
    }

    @Test("filterEntries with a nil key returns every entry unfiltered")
    func filterEntriesNilKeyReturnsEverything() {
        let entries = [
            DumpEntry.forIndexFailure(index: 0, description: "a"),
            DumpEntry.forIndexFailure(index: 1, description: "b"),
        ]
        #expect(filterEntries(entries, byKey: nil) == entries)
    }

    @Test("filterEntries with a key returns only matching rows")
    func filterEntriesMatchesByKey() {
        let vp3b = DumpEntry(
            index: 1675, key: "VP3b", type: "flt ", dataSize: 4, attributes: 133,
            byteOrder: "little-endian", bytes: "80f8e63f", error: nil)
        let other = DumpEntry(
            index: 0, key: "#KEY", type: "ui32", dataSize: 4, attributes: 128,
            byteOrder: "big-endian", bytes: "00000d39", error: nil)

        #expect(filterEntries([vp3b, other], byKey: "VP3b") == [vp3b])
    }

    @Test("filterEntries with a key that matches nothing returns an empty array")
    func filterEntriesNoMatchIsEmpty() {
        let entry = DumpEntry(
            index: 0, key: "#KEY", type: "ui32", dataSize: 4, attributes: 128,
            byteOrder: "big-endian", bytes: "00000d39", error: nil)
        #expect(filterEntries([entry], byKey: "ZZZZ").isEmpty)
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
    /// e.g. `AC-E`: `flag`, attrs 80 — bit `0x80` clear). Metadata is still known even
    /// though the value never was — but `flag` is a single byte with no byte order to
    /// resolve, so `byteOrder` stays `nil` here just as it would on a successful read.
    @Test("A declared-unreadable key keeps its metadata; flag has no byte order to show")
    func unreadableKeyKeepsMetadata() {
        let key = SMCKey("AC-E")!
        let info = SMCKeyInfo(key: key, type: .flag, dataSize: 1, attributes: 80)
        let entry = DumpEntry.forFailedRead(
            index: 3, key: key, info: info,
            description: describeDumpError(SMCError.notReadable(key)), generation: .modern)

        #expect(entry.type == "flag")
        #expect(entry.dataSize == 1)
        #expect(entry.attributes == 80)
        #expect(entry.byteOrder == nil)
        #expect(entry.bytes == nil)
        #expect(entry.error?.contains("unreadable") == true)
    }

    /// Failure mode 3 of 3: the key claims readable and `READ_BYTES` errors anyway (a
    /// further 52 keys on `Mac16,5`, e.g. `aP70`: `ui32`, attrs 148 — bit `0x80` set,
    /// firmware result `0xc7`). `ui32` does consult a resolved byte order, so this row
    /// keeps one even though the read itself failed — distinguishable from failure mode 2
    /// by the error text, not by which fields are present.
    @Test("A readable-but-erroring key keeps its metadata and byte order too")
    func readableButErroringKeyKeepsMetadata() {
        let key = SMCKey("aP70")!
        let info = SMCKeyInfo(key: key, type: .ui32, dataSize: 4, attributes: 148)
        let entry = DumpEntry.forFailedRead(
            index: 1714, key: key, info: info,
            description: describeDumpError(SMCError.firmware(code: 0xC7)), generation: .modern)

        #expect(entry.attributes == 148)
        #expect(entry.byteOrder == "little-endian")
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

    /// `AC-M` on `Mac16,5`: `hex_`, attrs 212, raw `0101`. A successful read of a
    /// non-numeric type must still show the bytes — that is the whole point of `hex_`
    /// being "surfaced raw" — but must not claim a resolved byte order nothing in the
    /// decoder consults. This is the exact row the review that requested this fix cited.
    @Test("A successful hex_ read shows bytes but no byte order")
    func hexTypeSuccessfulReadHasNoByteOrder() {
        let key = SMCKey("AC-M")!
        let info = SMCKeyInfo(key: key, type: .hex, dataSize: 2, attributes: 212)
        let value = SMCValue(key: key, type: .hex, bytes: [0x01, 0x01], byteOrder: nil)
        let entry = DumpEntry.forSuccessfulRead(
            index: 7, key: key, info: info, value: value, generation: .modern)

        #expect(entry.type == "hex_")
        #expect(entry.bytes == "0101")
        #expect(entry.byteOrder == nil)
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
        byteOrder: nil, bytes: nil,
        error: "AC-E declares itself unreadable (attribute bit 0x80 clear)")

    private static let keyInfoFailureEntry = DumpEntry(
        index: 201, key: "BDFU", type: nil, dataSize: nil, attributes: nil, byteOrder: nil,
        bytes: nil,
        error: "READ_KEYINFO failed: connection to AppleSMC failed (kernel result -536870207)")

    private static let matchingCrossCheck = KeyCountCrossCheck(
        declaredCount: 3385, walkedCount: 3385, keyExistsPastDeclaredCount: false)

    private static let mismatchedCrossCheck = KeyCountCrossCheck(
        declaredCount: 3385, walkedCount: 3385, keyExistsPastDeclaredCount: true)

    @Test("Table output includes the attribute byte and raw bytes for a successful row")
    func tableIncludesAttributesAndBytes() {
        let table = DumpFormatter.renderTable(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 1,
            crossCheck: Self.matchingCrossCheck)
        #expect(table.contains("VP3b"))
        #expect(table.contains("133"))
        #expect(table.contains("8020e73f"))
        #expect(table.contains("little-endian"))
    }

    @Test("Table output lists a failed row rather than omitting it")
    func tableIncludesFailures() {
        let table = DumpFormatter.renderTable(
            entries: [Self.unreadableEntry, Self.keyInfoFailureEntry], generation: .modern,
            declaredKeyCount: 2, crossCheck: Self.matchingCrossCheck)
        #expect(table.contains("AC-E"))
        #expect(table.contains("unreadable"))
        #expect(table.contains("BDFU"))
        #expect(table.contains("READ_KEYINFO failed"))
    }

    @Test("Table output's summary line accounts for every row")
    func tableSummaryAccountsForEveryRow() {
        let table = DumpFormatter.renderTable(
            entries: [Self.vp3bEntry, Self.unreadableEntry, Self.keyInfoFailureEntry],
            generation: .modern, declaredKeyCount: 3, crossCheck: Self.matchingCrossCheck)
        #expect(table.contains("3 keys enumerated"))
        #expect(table.contains("1 read successfully"))
        #expect(table.contains("2 failed"))
    }

    /// The fix for the tautology the review flagged: `#KEY: N | rows: N` can never
    /// disagree by construction, since the walk always emits exactly one row per index.
    /// The real cross-check is a separate, independently-sourced line.
    @Test("Table output reports a matching cross-check distinctly from the row count")
    func tableReportsMatchingCrossCheck() {
        let table = DumpFormatter.renderTable(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 3385,
            crossCheck: Self.matchingCrossCheck)
        #expect(table.contains("Cross-check: MATCH"))
        #expect(table.contains("3385"))
    }

    @Test("Table output reports a mismatched cross-check, not a silent clean bill of health")
    func tableReportsMismatchedCrossCheck() {
        let table = DumpFormatter.renderTable(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 3385,
            crossCheck: Self.mismatchedCrossCheck)
        #expect(table.contains("Cross-check: MISMATCH"))
        #expect(table.contains("under-declaring"))
    }

    @Test("Table output reports an unavailable cross-check rather than pretending one ran")
    func tableReportsUnavailableCrossCheck() {
        let table = DumpFormatter.renderTable(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 1, crossCheck: nil)
        #expect(table.contains("Cross-check: unavailable"))
    }

    @Test("JSON output round-trips the VP3b row with every required field present")
    func jsonRoundTripsVP3b() throws {
        let json = try DumpFormatter.renderJSON(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 1,
            crossCheck: Self.matchingCrossCheck)
        let data = Data(json.utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["generation"] as? String == "modern")
        #expect(object["declaredKeyCount"] as? Int == 1)

        let crossCheck = try #require(object["crossCheck"] as? [String: Any])
        #expect(crossCheck["matches"] as? Bool == true)
        #expect(crossCheck["declaredCount"] as? Int == 3385)

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

    /// `Report` and `DumpEntry` both rely on `Codable`'s synthesised conformance rather
    /// than a hand-written `encode(to:)` (unlike `ListCommand.KeyedValueJSON`/
    /// `SensorsCommand.SensorJSON` — see their own documentation for why those two write
    /// it by hand). The synthesised conformance calls `encodeIfPresent` for every
    /// `Optional` property, which *omits* the key entirely rather than encoding `null` —
    /// the opposite convention from those two per-entry types, and worth pinning
    /// precisely rather than accepting either shape, which is what this test used to do.
    @Test("JSON output omits the crossCheck key entirely, not as null, when unavailable")
    func jsonOmitsCrossCheckWhenUnavailable() throws {
        let json = try DumpFormatter.renderJSON(
            entries: [Self.vp3bEntry], generation: .modern, declaredKeyCount: 1, crossCheck: nil)
        #expect(!json.contains("crossCheck"))
    }

    @Test("JSON output for a failed row omits bytes/byteOrder entirely and reports the failure")
    func jsonReportsFailuresRatherThanOmittingThem() throws {
        let json = try DumpFormatter.renderJSON(
            entries: [Self.unreadableEntry], generation: .modern, declaredKeyCount: 1,
            crossCheck: Self.matchingCrossCheck)
        let data = Data(json.utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        let row = try #require(entries.first)

        #expect(row["key"] as? String == "AC-E")
        // Omitted entirely, not present as null — see this suite's doc comment above.
        #expect(row["bytes"] == nil)
        #expect(row["byteOrder"] == nil)
        let error = try #require(row["error"] as? String)
        #expect(error.contains("unreadable"))
    }

    @Test("Generation description is 'undetermined' rather than a crash when unresolved")
    func undeterminedGenerationDoesNotCrash() {
        let table = DumpFormatter.renderTable(
            entries: [], generation: nil, declaredKeyCount: 0, crossCheck: nil)
        #expect(table.contains("undetermined"))
    }
}

// swiftlint:enable force_unwrapping
