import Testing

@testable import smc_sampler

/// Covers `FanEnumerationOutcome.from(_:model:)` — the mapping `SMCSamplerMain.swift`'s
/// `main()` used to perform inline, against a local variable no test could see. See that
/// type's own documentation for why it was pulled out, and the round-2 delta review of
/// #248 for the mutation that motivated it: deleting the wiring at
/// `SMCSamplerMain.swift:188-189` (`fanEnumerationFailed: fanEnumerationFailureReason !=
/// nil, fanEnumerationFailureReason: fanEnumerationFailureReason`) and replacing it with
/// `fanEnumerationFailed: false, fanEnumerationFailureReason: nil` left the full 1482-test
/// suite green. These tests exercise the pure mapping directly instead of the wiring
/// around it, so the same class of regression fails here.
@Suite("FanEnumerationOutcome")
struct FanEnumerationOutcomeTests {

    private struct ProbeError: Error, CustomStringConvertible {
        var description: String { "ProbeError.hardwareUnavailable" }
    }

    @Test("a successful enumeration reports no failure and the default(model:...,fans:N) source")
    func successReportsNoFailure() {
        let outcome = FanEnumerationOutcome.from(.success([0, 1]), model: "Mac16,5")
        #expect(outcome.fanIndices == [0, 1])
        #expect(outcome.keySource == "default(model:Mac16,5,fans:2)")
        #expect(outcome.fanEnumerationFailed == false)
        #expect(outcome.fanEnumerationFailureReason == nil)
    }

    @Test(
        "a successful enumeration with zero fans still reports fans:0 as a success, not a failure")
    func successWithNoFansIsNotAFailure() {
        let outcome = FanEnumerationOutcome.from(.success([]), model: "Mac16,5")
        #expect(outcome.fanIndices.isEmpty)
        #expect(outcome.keySource == "default(model:Mac16,5,fans:0)")
        #expect(outcome.fanEnumerationFailed == false)
        #expect(outcome.fanEnumerationFailureReason == nil)
    }

    @Test(
        "a thrown error reports the failure, an empty fan list, and the error's description as the reason"
    )
    func failureReportsFailedAndReason() {
        let outcome = FanEnumerationOutcome.from(.failure(ProbeError()), model: "Mac16,5")
        #expect(outcome.fanIndices.isEmpty)
        #expect(outcome.keySource == "default(model:Mac16,5,fans:0)")
        #expect(outcome.fanEnumerationFailed == true)
        #expect(outcome.fanEnumerationFailureReason == "ProbeError.hardwareUnavailable")
    }

    @Test(
        "a nil model resolves to the documented \"unknown\" placeholder in keySource, on both paths"
    )
    func nilModelResolvesToUnknown() {
        let success = FanEnumerationOutcome.from(.success([0]), model: nil)
        #expect(success.keySource == "default(model:unknown,fans:1)")

        let failure = FanEnumerationOutcome.from(.failure(ProbeError()), model: nil)
        #expect(failure.keySource == "default(model:unknown,fans:0)")
    }
}
