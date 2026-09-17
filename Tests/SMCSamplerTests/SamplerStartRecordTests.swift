import Testing

@testable import smc_sampler

/// Covers `SamplerStartRecord.startRecord(outcome:...)` — the mapping from a
/// `FanEnumerationOutcome?` onto the `start` line's `keySource`/`fanEnumerationFailed`/
/// `fanEnumerationFailureReason` fields that `SMCSamplerMain.swift`'s `main()` used to
/// perform inline, against local variables no test could see.
///
/// This is the passthrough round-3 delta review of #248 found still untested even after
/// `FanEnumerationOutcomeTests` closed the mapping *into* `FanEnumerationOutcome`:
/// `main()` still copied that type's fields onto locals and from there into
/// `SamplerStartRecord`'s initializer. Two mutations at that second site both left the
/// full suite green before this file existed:
///
/// Mutation A (the cited one, now at `SamplerStartRecord.startRecord`'s `return`):
/// `fanEnumerationFailed: fanEnumerationFailed, fanEnumerationFailureReason:
/// fanEnumerationFailureReason` → `fanEnumerationFailed: false, fanEnumerationFailureReason:
/// nil`. `outcomeFailureIsCarriedThrough` below fails the instant that mutation lands: it
/// asserts a *true*/non-nil outcome maps to a *true*/non-nil record.
///
/// Mutation A2 (the zero-warning variant, one assignment earlier): `let
/// fanEnumerationFailed = outcome?.fanEnumerationFailed ?? false` → `let
/// fanEnumerationFailed = false`. Also caught by `outcomeFailureIsCarriedThrough`, for the
/// same reason.
@Suite("SamplerStartRecord.startRecord(outcome:)")
struct SamplerStartRecordTests {

    private struct ProbeError: Error, CustomStringConvertible {
        var description: String { "ProbeError.hardwareUnavailable" }
    }

    private static func record(
        outcome: FanEnumerationOutcome?, keys: [String] = ["TPD0"]
    ) -> SamplerStartRecord {
        SamplerStartRecord.startRecord(
            outcome: outcome,
            hostname: "test-host",
            hwModel: "Mac16,5",
            osVersion: "macOS 26.6.2",
            uid: 501,
            pid: 4242,
            intervalSeconds: 1.0,
            keys: keys)
    }

    @Test("a nil outcome (custom --keys) reports keySource \"custom\" and no failure")
    func nilOutcomeReportsCustomSourceAndNoFailure() {
        let record = Self.record(outcome: nil, keys: ["F0Ac", "F1Ac"])

        #expect(record.keys == ["F0Ac", "F1Ac"])
        #expect(record.keySource == "custom")
        #expect(record.fanEnumerationFailed == false)
        #expect(record.fanEnumerationFailureReason == nil)
    }

    @Test("a successful enumeration outcome is carried through unchanged")
    func successfulOutcomeIsCarriedThrough() {
        let outcome = FanEnumerationOutcome.from(.success([0, 1]), model: "Mac16,5")
        let record = Self.record(outcome: outcome)

        #expect(record.keySource == "default(model:Mac16,5,fans:2)")
        #expect(record.fanEnumerationFailed == false)
        #expect(record.fanEnumerationFailureReason == nil)
    }

    /// The mutation this exists to catch — see this suite's own documentation. A failed
    /// outcome must reach the record as a failed record: `fanEnumerationFailed == true`
    /// and a non-nil reason, both read straight off `outcome`, not hardcoded at either the
    /// local-variable assignment or the record's own construction.
    @Test("a failed enumeration outcome's failure flag and reason are both carried through")
    func outcomeFailureIsCarriedThrough() {
        let outcome = FanEnumerationOutcome.from(.failure(ProbeError()), model: "Mac16,5")
        let record = Self.record(outcome: outcome)

        #expect(record.keySource == "default(model:Mac16,5,fans:0)")
        #expect(record.fanEnumerationFailed == true)
        #expect(record.fanEnumerationFailureReason == "ProbeError.hardwareUnavailable")
    }
}
