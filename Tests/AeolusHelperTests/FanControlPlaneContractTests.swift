import SMCCore
import Testing

@testable import AeolusHelper

/// The two rules the seam enforces on its own values, tested where they live rather than
/// through a conformer — so that every conformer, production and mock alike, inherits them
/// instead of restating them slightly differently.
@Suite("Control-plane value rules")
struct FanControlPlaneContractTests {

    // MARK: - Blindness is not a successful report of nothing

    /// The supervisor-blindness case, refused at construction.
    ///
    /// `SAFETY.md` covers divergence of values and does not cover the inability to obtain
    /// them; the shape that hides the difference is an array that happens to be empty,
    /// because "no sensor is above its ceiling" and "no sensor answered" are then the same
    /// value. This type has no empty representation at all.
    @Test("A critical-temperature report with no readings cannot be constructed")
    func anEmptyTemperatureReportIsRefused() {
        #expect(throws: FanControlPlaneError.criticalTelemetryUnavailable(requestedKeys: 2)) {
            try CriticalTemperatureReport(
                readings: [], unreadableKeys: [smcKey("TC0P"), smcKey("TG0P")])
        }
    }

    /// An empty *request* lands in the same place. #102's curated critical set being empty
    /// on an unrecognised machine is one of the named ways the supervisor goes blind, and
    /// it must not read as a clean cycle.
    @Test("A report built from no requested keys at all is refused too")
    func aReportFromNoKeysAtAllIsRefused() {
        #expect(throws: FanControlPlaneError.criticalTelemetryUnavailable(requestedKeys: 0)) {
            try CriticalTemperatureReport(readings: [], unreadableKeys: [])
        }
    }

    @Test("A report with one reading and one loss keeps both facts")
    func aPartialReportIsStillAReport() throws {
        let report = try CriticalTemperatureReport(
            readings: [CriticalTemperature(key: smcKey("TC0P"), celsius: 61.5)],
            unreadableKeys: [smcKey("TG0P")])

        #expect(report.readings.count == 1)
        #expect(report.readings[0].celsius == 61.5)
        #expect(report.unreadableKeys == [smcKey("TG0P")])
    }

    // MARK: - The finiteness rule

    /// `SMCValue.scalar()` applies no finiteness guard, so a byte-swapped `flt` decodes to
    /// `±.infinity` or `.nan` on an otherwise-successful read. Both survive arithmetic
    /// without looking wrong, so a non-finite ceiling comparison never fires and a
    /// non-finite bound clamps nothing.
    @Test("A non-finite value is a read failure, never a number the seam hands on")
    func nonFiniteValuesAreReadFailures() {
        for value in [Double.nan, .infinity, -.infinity] {
            let result = FanControlPlaneValue.finite(value, describing: "F0Mn")
            guard case .failure(.readFailed(let detail)) = result else {
                Issue.record("\(value) was accepted as a reading")
                continue
            }
            #expect(detail.contains("F0Mn"))
        }
    }

    @Test("A finite value passes through unchanged, including zero and negatives")
    func finiteValuesPassThrough() throws {
        for value in [0.0, -40.0, 1_343.07, 5_777.0] {
            let produced = try FanControlPlaneValue.finite(value, describing: "F0Mn").get()
            #expect(produced == value)
        }
    }
}
