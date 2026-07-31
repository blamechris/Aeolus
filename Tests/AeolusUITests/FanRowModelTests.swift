import FanKit
import Testing

@testable import AeolusUI

@Suite("FanRowModel — control state renders honestly, especially when reclaimed")
struct FanRowModelTests {

    private static func reading(
        mode: FanControlMode = .automatic,
        isReclaimedBySystem: Bool = false
    ) -> FanPollingReading {
        FanPollingReading(
            index: 0,
            displayName: "Fan 0",
            actual: .value(key: "F0Ac", 1712),
            minimum: .value(key: "F0Mn", 1200),
            maximum: .value(key: "F0Mx", 5312),
            mode: mode,
            isReclaimedBySystem: isReclaimedBySystem)
    }

    @Test("The raw keys for actual/minimum/maximum are always carried into the row")
    func rawKeysAreCarriedThrough() {
        let row = FanRowModel(reading: Self.reading())

        #expect(row.actual.key == "F0Ac")
        #expect(row.minimum.key == "F0Mn")
        #expect(row.maximum.key == "F0Mx")
    }

    @Test(
        "An automatic, non-reclaimed fan is labelled plainly as Automatic",
        arguments: [
            (FanControlMode.automatic, "Automatic"),
            (FanControlMode.manualFixed, "Manual — fixed speed"),
            (FanControlMode.manualCurve, "Manual — curve"),
        ]
    )
    func nonReclaimedFanShowsItsMode(_ pair: (FanControlMode, String)) {
        let (mode, expectedLabel) = pair
        let row = FanRowModel(reading: Self.reading(mode: mode, isReclaimedBySystem: false))

        #expect(row.controlStateLabel == expectedLabel)
        #expect(!row.isReclaimedBySystem)
    }

    @Test(
        """
        A reclaimed fan never renders its requested mode as though it were still in effect \
        — the reclamation is named in the label itself
        """
    )
    func reclaimedFanNamesTheReclamationHonestly() {
        let row = FanRowModel(
            reading: Self.reading(mode: .manualFixed, isReclaimedBySystem: true))

        #expect(row.isReclaimedBySystem)
        #expect(row.controlStateLabel.contains("Reclaimed by system"))
        #expect(row.controlStateLabel.contains("Manual — fixed speed"))
        // Never just "Manual — fixed speed" on its own: that alone would claim a control
        // state nothing is currently honouring. CLAUDE.md rule 6.
        #expect(row.controlStateLabel != "Manual — fixed speed")
    }

    @Test("A reading below the declared minimum still renders as an available actual value")
    func belowMinimumActualStillRendersAsAvailable() {
        let fan = FanPollingReading(
            index: 0,
            displayName: "Fan 0",
            actual: .value(key: "F0Ac", 1343.07),
            minimum: .value(key: "F0Mn", 1350),
            maximum: .value(key: "F0Mx", 5312))
        let row = FanRowModel(reading: fan)

        #expect(row.actual.isAvailable)
        #expect(row.actual.text == "1343.07 RPM")
    }

    @Test("An unavailable actual reading never renders as 0 or a bare dash")
    func unavailableActualRendersHonestly() {
        let fan = FanPollingReading(
            index: 2,
            displayName: "Fan 2",
            actual: .unavailable(key: "F2Ac", reason: "F2Ac is not present on this machine"),
            minimum: .value(key: "F2Mn", 1200),
            maximum: .value(key: "F2Mx", 5312))
        let row = FanRowModel(reading: fan)

        #expect(!row.actual.isAvailable)
        #expect(row.actual.text != "0")
        #expect(row.actual.text != "0 RPM")
        #expect(row.actual.text != "—")
        #expect(row.actual.text.contains("unavailable"))
    }
}
