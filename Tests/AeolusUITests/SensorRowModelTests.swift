import FanKit
import SMCCore
import Testing

@testable import AeolusUI

@Suite("SensorRowModel — the raw key always survives, a guess always looks like a guess")
struct SensorRowModelTests {

    @Test("An undecorated sensor renders fully, unlabelled — not a degraded state")
    func undecoratedSensorHasNoLabelOrConfidence() {
        let reading = SensorPollingReading(
            key: "Tp09", kind: .temperatureCelsius, sample: .value(key: "Tp09", 44.2))
        let row = SensorRowModel(reading: reading)

        #expect(row.key == "Tp09")
        #expect(row.label == nil)
        #expect(row.confidence == nil)
        #expect(row.categoryLabel == nil)
        #expect(row.value.text == "44.20 °C")
    }

    @Test("A decorated sensor carries the raw key alongside the label, never in place of it")
    func decoratedSensorCarriesKeyAlongsideLabel() {
        let decoration = CatalogDecoration(
            key: "Tp09", label: "CPU Package", category: .cpu, confidence: .verified)
        let reading = SensorPollingReading(
            key: "Tp09", kind: .temperatureCelsius, sample: .value(key: "Tp09", 44.2),
            decoration: decoration)
        let row = SensorRowModel(reading: reading)

        #expect(row.key == "Tp09")
        #expect(row.label == "CPU Package")
        #expect(row.categoryLabel == "cpu")
        #expect(row.confidence == .verified)
    }

    @Test(
        """
        Every confidence level round-trips through the row model unchanged — a guess must \
        render as a guess
        """,
        arguments: [
            CatalogConfidence.verified, .community, .guess, .unknown("future-level"),
        ]
    )
    func confidenceLevelsRoundTrip(_ confidence: CatalogConfidence) {
        let decoration = CatalogDecoration(
            key: "Tp01", label: "Ambient", category: .ambient, confidence: confidence)
        let reading = SensorPollingReading(
            key: "Tp01", kind: .temperatureCelsius, sample: .value(key: "Tp01", 30),
            decoration: decoration)
        let row = SensorRowModel(reading: reading)

        #expect(row.confidence == confidence)
    }

    @Test(
        "Each SensorReading.Kind maps to its display unit, with .unknown carrying no unit at all",
        arguments: [
            (SensorReading.Kind.temperatureCelsius, "°C"),
            (.rpm, "RPM"),
            (.watts, "W"),
            (.volts, "V"),
            (.amps, "A"),
            (.percent, "%"),
        ]
    )
    func kindMapsToDisplayUnit(_ pair: (SensorReading.Kind, String)) {
        let (kind, unit) = pair
        #expect(SensorRowModel.unit(for: kind) == unit)
    }

    @Test(".unknown kind carries no unit suffix")
    func unknownKindHasNoUnit() {
        #expect(SensorRowModel.unit(for: .unknown) == nil)
    }

    @Test("An unavailable sensor sample never renders as 0 or a bare dash")
    func unavailableSampleRendersHonestly() {
        let reading = SensorPollingReading(
            key: "TG0P", kind: .unknown,
            sample: .unavailable(key: "TG0P", reason: "read failed"))
        let row = SensorRowModel(reading: reading)

        #expect(!row.value.isAvailable)
        #expect(row.value.text != "0")
        #expect(row.value.text != "—")
        #expect(row.value.text.contains("unavailable"))
    }
}
