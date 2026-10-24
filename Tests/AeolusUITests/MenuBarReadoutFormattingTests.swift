import FanKit
import SMCCore
import Testing

@testable import AeolusUI

@Suite("MenuBarReadoutFormatting — what the strip and the dropdown both render")
struct MenuBarReadoutFormattingTests {

    private static func resolved(
        key: String = "Tp09",
        source: MenuBarReadout.Source = .sensor,
        label: String? = nil,
        kind: SensorReading.Kind = .temperatureCelsius,
        value: Double = 42,
        fanControl: FanControlSource? = nil
    ) -> ResolvedMenuBarReadout {
        ResolvedMenuBarReadout(
            key: key, source: source, label: label, kind: kind,
            reading: .value(key: key, value), fanControl: fanControl)
    }

    /// A fan the helper reports, cleared to automatic unless told otherwise.
    private static func reported(
        mode: FanControlMode = .automatic,
        availability: ManualControlAvailability = .unavailable(.writePathNotBuilt),
        reclaimed: Bool = false
    ) -> FanControlSource {
        .reported(
            SnapshotTestSupport.fan(
                mode: mode, availability: availability, reclaimed: reclaimed,
                target: mode == .automatic || reclaimed ? nil : 3000),
            thermalEmergency: false)
    }

    // MARK: - value(for:temperatureUnit:)

    @Test("A plain reading formats with its unit, no identifier")
    func valueFormatsWithUnit() {
        let readout = Self.resolved(key: "F0Ac", kind: .rpm, value: 1712)
        #expect(
            MenuBarReadoutFormatting.value(for: readout, temperatureUnit: .celsius)
                == "1712 RPM")
    }

    @Test("An unavailable reading renders its reason, never a bare 0")
    func valueRendersUnavailableHonestly() {
        let readout = ResolvedMenuBarReadout(
            key: "F0Ac", source: .fan, label: nil, kind: .rpm,
            reading: .unavailable(key: "F0Ac", reason: "no fan reports this key right now"),
            fanControl: nil)
        #expect(
            MenuBarReadoutFormatting.value(for: readout, temperatureUnit: .celsius)
                == "unavailable (no fan reports this key right now)")
    }

    // MARK: - controlStateSuffix(for:)

    @Test("A sensor-sourced readout has no control state to report")
    func sensorHasNoControlStateSuffix() {
        let readout = Self.resolved(source: .sensor, fanControl: nil)
        #expect(MenuBarReadoutFormatting.controlStateSuffix(for: readout) == nil)
    }

    @Test("A fan-sourced readout's control state matches FanRowModel's own wording")
    func fanControlStateSuffixMatchesFanRowModel() {
        let readout = Self.resolved(source: .fan, fanControl: Self.reported())
        #expect(MenuBarReadoutFormatting.controlStateSuffix(for: readout) == "Automatic")
        #expect(
            MenuBarReadoutFormatting.controlStateSuffix(for: readout)
                == FanRowModel.controlStateLabel(for: Self.reported()))
    }

    @Test("A reclaimed fan's control state says it was reclaimed")
    func reclaimedFanControlStateSuffix() {
        let readout = Self.resolved(
            source: .fan, fanControl: Self.reported(mode: .manualFixed, reclaimed: true))
        #expect(MenuBarReadoutFormatting.controlStateSuffix(for: readout) == "Reclaimed by system")
    }

    @Test("A fan nothing reports on says Mode not tracked in the dropdown")
    func untrackedFanControlStateSuffix() {
        let readout = Self.resolved(source: .fan, fanControl: .notTracked(.noHelperInThisBuild))
        #expect(MenuBarReadoutFormatting.controlStateSuffix(for: readout) == "Mode not tracked")
    }

    // MARK: - identifiedText(for:temperatureUnit:) — the #249 fix

    @Test("A labelled readout's identifier is its label, not its raw key")
    func identifiedTextPrefersLabel() {
        let readout = Self.resolved(key: "Tp09", label: "CPU Proximity", kind: .temperatureCelsius)
        #expect(
            MenuBarReadoutFormatting.identifiedText(for: readout, temperatureUnit: .celsius)
                == "CPU Proximity 42 °C")
    }

    @Test("An unlabelled readout's identifier falls back to its raw key")
    func identifiedTextFallsBackToKey() {
        let readout = Self.resolved(key: "Tp09", label: nil, kind: .temperatureCelsius)
        #expect(
            MenuBarReadoutFormatting.identifiedText(for: readout, temperatureUnit: .celsius)
                == "Tp09 42 °C")
    }

    @Test(
        "A catalog-labelled, .unknown-kind readout (the F0Md shape) never renders as a bare number"
    )
    func identifiedTextNeverBareForAModeShapedReadout() {
        // #249: even though MenuBarReadoutSelection no longer defaults to F0Md, a user
        // can still pick it deliberately via the preferences picker ("nameable, not
        // defaultable"). Wherever it is rendered, it must carry its label — never render
        // as the same bare "0" a stopped-fan RPM reading would show.
        let readout = Self.resolved(key: "F0Md", label: "Fan 0 Mode", kind: .unknown, value: 0)
        let text = MenuBarReadoutFormatting.identifiedText(for: readout, temperatureUnit: .celsius)
        #expect(text == "Fan 0 Mode 0")
        #expect(text != "0")
    }

    @Test(
        "A fan cleared to automatic, or not tracked, carries no suffix in the strip",
        arguments: [
            FanControlSource.reported(
                SnapshotTestSupport.fan(mode: .automatic), thermalEmergency: false),
            .notTracked(.noHelperInThisBuild),
        ])
    func identifiedTextSuppressesTheQuietControlStates(_ control: FanControlSource) {
        // "(Automatic)" and "(Mode not tracked)" are dead weight on the strip's limited
        // width — the second is on every fan of a Monitor build. The dropdown still shows
        // both: this suppression is local to identifiedText/stripText.
        let readout = Self.resolved(
            key: "F0Ac", source: .fan, label: "Fan 0", kind: .rpm, value: 1712,
            fanControl: control)
        #expect(
            MenuBarReadoutFormatting.identifiedText(for: readout, temperatureUnit: .celsius)
                == "Fan 0 1712 RPM")
    }

    @Test("A fan reading automatic that the helper has not cleared keeps its suffix")
    func identifiedTextAppendsAnUnclearedAutomatic() {
        let readout = Self.resolved(
            key: "F0Ac", source: .fan, label: "Fan 0", kind: .rpm, value: 1712,
            fanControl: Self.reported(availability: .unavailable(.restoreToAutomaticUnconfirmed)))
        #expect(
            MenuBarReadoutFormatting.identifiedText(for: readout, temperatureUnit: .celsius)
                == "Fan 0 1712 RPM (Not confirmed as automatic)")
    }

    @Test("A manually-controlled fan's identified text still appends its control state")
    func identifiedTextAppendsANoteworthyControlState() {
        let readout = Self.resolved(
            key: "F0Ac", source: .fan, label: "Fan 0", kind: .rpm, value: 1712,
            fanControl: Self.reported(mode: .manualFixed))
        #expect(
            MenuBarReadoutFormatting.identifiedText(for: readout, temperatureUnit: .celsius)
                == "Fan 0 1712 RPM (Manual — fixed speed)")
    }

    @Test(
        "A fan reclaimed while reporting mode .automatic still appends its control state — rule 6"
    )
    func identifiedTextAppendsControlStateWhenReclaimedEvenIfModeReadsAutomatic() {
        // The safety net for isNoteworthyControlState's OR: a reclaimed fan can read
        // automatic and be cleared, and `isReclaimedBySystem` alone must be enough to keep this
        // fan's line off the "nothing to see here" list the automatic-suppression exists
        // to shorten — CLAUDE.md rule 6 forbids ever looking like this app still has
        // control when the system has taken it back.
        let readout = Self.resolved(
            key: "F0Ac", source: .fan, label: "Fan 0", kind: .rpm, value: 1712,
            fanControl: Self.reported(mode: .automatic, availability: .available, reclaimed: true))
        #expect(
            MenuBarReadoutFormatting.identifiedText(for: readout, temperatureUnit: .celsius)
                == "Fan 0 1712 RPM (Reclaimed by system)")
    }

    // MARK: - stripText(for:temperatureUnit:) — the reported #249 scenario

    @Test("The exact #249 scenario: two live fans plus a mode flag and a setpoint")
    func stripTextNeverConflatesModeOrSetpointWithALiveReading() {
        let fan0 = Self.resolved(
            key: "F0Ac", source: .fan, label: "Fan 0", kind: .rpm, value: 1340.73,
            fanControl: Self.reported())
        let fan1 = Self.resolved(
            key: "F1Ac", source: .fan, label: "Fan 1", kind: .rpm, value: 1470.74,
            fanControl: .notTracked(.noHelperInThisBuild))
        let mode = Self.resolved(key: "F0Md", label: "Fan 0 Mode", kind: .unknown, value: 0)
        let target = Self.resolved(
            key: "F0Tg", label: "Fan 0 Target Speed", kind: .rpm, value: 1350)

        let text = MenuBarReadoutFormatting.stripText(
            for: [fan0, fan1, mode, target], temperatureUnit: .celsius)

        // One fan is cleared to automatic and the other is not tracked, so neither carries a
        // suffix here — see identifiedTextSuppressesTheQuietControlStates.
        #expect(
            text
                == "Fan 0 1340.73 RPM  Fan 1 1470.74 RPM  "
                + "Fan 0 Mode 0  Fan 0 Target Speed 1350 RPM")
        // The literal regression: no entry is a bare, unlabelled "0" indistinguishable
        // from a live reading.
        #expect(!text.contains("  0  "))
    }

    @Test("Empty input produces an empty string, leaving the empty-state message to the view")
    func emptyInputProducesEmptyString() {
        #expect(
            MenuBarReadoutFormatting.stripText(for: [], temperatureUnit: .celsius) == "")
    }
}
