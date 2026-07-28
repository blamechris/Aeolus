import Testing

@testable import fanctl

/// `FanctlError.errorDescription` is what swift-argument-parser actually prints to a
/// user's terminal (see `FanctlError.swift`'s documentation), so these pin the exact
/// requirement CLAUDE.md and issue #45 both call out: never a bare `nil`, never a raw
/// `SMCError` case name, always something a person can act on.
@Suite("FanctlError — messages are actionable, never a bare nil or a raw error dump")
struct FanctlErrorTests {

    @Test("Every case has a non-empty, human-readable description")
    func everyCaseHasADescription() {
        let cases: [FanctlError] = [
            .noSMC,
            .connectionFailed(context: "read FNum", reason: "boom"),
            .implausibleFanCount("9000000"),
            .jsonEncodingFailed(reason: "boom"),
        ]
        for error in cases {
            let description = error.errorDescription
            #expect(description != nil)
            #expect(!(description ?? "").isEmpty)
        }
    }

    @Test("noSMC names the actual problem, not an IOKit code")
    func noSMCNamesTheProblem() {
        #expect(FanctlError.noSMC.errorDescription?.contains("No SMC found") == true)
    }

    @Test("connectionFailed carries both what was attempted and why")
    func connectionFailedCarriesContextAndReason() {
        let error = FanctlError.connectionFailed(context: "read FNum", reason: "kIOReturnNotOpen")
        let description = error.errorDescription ?? ""
        #expect(description.contains("read FNum"))
        #expect(description.contains("kIOReturnNotOpen"))
    }

    @Test(
        "implausibleFanCount can describe a non-finite decode (NaN/Infinity), not just an Int"
    )
    func implausibleFanCountDescribesNonFiniteDecode() {
        // The whole reason this case carries a String rather than an Int: a decode
        // fault worth reporting here is not always representable as one.
        let nan = FanctlError.implausibleFanCount(Formatting.number(.nan))
        #expect(nan.errorDescription?.contains("NaN") == true)

        let infinity = FanctlError.implausibleFanCount(Formatting.number(.infinity))
        #expect(infinity.errorDescription?.contains("Infinity") == true)
    }
}
