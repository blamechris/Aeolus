import FanKit
import Testing

@testable import AeolusUI

@Suite("FanRowModel — control state renders honestly: not tracked, cleared, refused, reclaimed")
struct FanRowModelTests {

    typealias Reason = ManualControlAvailability.Reason
    typealias Support = SnapshotTestSupport

    private static func reading(_ control: FanControlSource) -> FanPollingReading {
        FanPollingReading(
            index: 0,
            displayName: "Fan 0",
            actual: .value(key: "F0Ac", 1712),
            minimum: .value(key: "F0Mn", 1200),
            maximum: .value(key: "F0Mx", 5312),
            control: control)
    }

    private static func row(
        mode: FanControlMode = .automatic,
        availability: ManualControlAvailability = .unavailable(.writePathNotBuilt),
        reclaimed: Bool = false
    ) -> FanRowModel {
        FanRowModel(
            reading: reading(
                .reported(
                    Support.fan(
                        mode: mode, availability: availability, reclaimed: reclaimed,
                        target: mode == .automatic || reclaimed ? nil : 3000))))
    }

    @Test("The raw keys for actual/minimum/maximum are always carried into the row")
    func rawKeysAreCarriedThrough() {
        let row = FanRowModel(reading: Self.reading(.notTracked(.noHelperInThisBuild)))

        #expect(row.actual.key == "F0Ac")
        #expect(row.minimum.key == "F0Mn")
        #expect(row.maximum.key == "F0Mx")
    }

    @Test("A fan nothing reports on says Mode not tracked, refuses nothing and is not reclaimed")
    func anUntrackedFanSaysSo() {
        let row = FanRowModel(reading: Self.reading(.notTracked(.snapshotStale)))

        #expect(row.controlStateLabel == "Mode not tracked")
        #expect(row.refusal == nil)
        #expect(!row.isReclaimedBySystem)
    }

    @Test("A fan the helper reports cleared to automatic says Automatic")
    func aClearedFanSaysAutomatic() {
        #expect(
            Self.row(mode: .automatic, availability: .available).controlStateLabel == "Automatic")
        #expect(Self.row(mode: .automatic).controlStateLabel == "Automatic")
    }

    /// The reasons a fan reading automatic is not cleared: every one `clearance` does not call
    /// silent. Derived from `Tag`, which is exhaustive over `Reason`.
    static let notClearing = Tag.allCases.map(\.reason).filter {
        ManualControlAvailability.unavailable($0).clearance != .silent
    }

    /// **Mutation:** in `FanRowModel.controlStateLabel(for:)`, replace
    /// `state.isClearedToAutomatic` with `state.mode == .automatic`. Run: red for every
    /// argument — the pending reasons the brief names, and the durable ones beside them.
    @Test(
        "Automatic comes only from isClearedToAutomatic, never from the mode alone",
        arguments: notClearing)
    func automaticNeedsClearance(_ reason: Reason) {
        let row = Self.row(mode: .automatic, availability: .unavailable(reason))

        #expect(row.controlStateLabel == "Not confirmed as automatic")
        #expect(row.controlStateLabel != "Automatic")
    }

    @Test(
        "A manual fan the helper reports is labelled with its mode",
        arguments: [
            (FanControlMode.manualFixed, "Manual — fixed speed"),
            (FanControlMode.manualCurve, "Manual — curve"),
        ])
    func aManualFanShowsItsMode(_ pair: (FanControlMode, String)) {
        #expect(Self.row(mode: pair.0).controlStateLabel == pair.1)
    }

    @Test(
        "A reclaimed fan says so, whatever its mode reads",
        arguments: [FanControlMode.automatic, .manualFixed, .manualCurve])
    func aReclaimedFanSaysSo(_ mode: FanControlMode) {
        let row = Self.row(mode: mode, availability: .available, reclaimed: true)

        #expect(row.isReclaimedBySystem)
        #expect(row.controlStateLabel == "Reclaimed by system")
    }

    // MARK: - Every reason renders its own text

    /// One tag per `Reason`, with **no `default:`** in either switch, so a reason added to the
    /// vocabulary does not compile here until it has a tag — and every tag is rendered below.
    /// The same witness `FanKitTests`' `ManualControlAvailabilityClearanceTests` keeps, which
    /// this target cannot import.
    enum Tag: CaseIterable {
        case writePathNotBuilt, boundsImplausible, reclaimedBySystem, leaseHeldByAnotherClient
        case selfRenewalNotBuilt, releaseInProgress, handbackUnconfirmed
        case restoreToAutomaticUnconfirmed, restoreToAutomaticFailed, systemSleeping
        case noThermalTelemetry, supervisorBlind, foreignManualControl, unknown

        init(_ reason: Reason) {
            switch reason {
            case .writePathNotBuilt: self = .writePathNotBuilt
            case .boundsImplausible: self = .boundsImplausible
            case .reclaimedBySystem: self = .reclaimedBySystem
            case .leaseHeldByAnotherClient: self = .leaseHeldByAnotherClient
            case .selfRenewalNotBuilt: self = .selfRenewalNotBuilt
            case .releaseInProgress: self = .releaseInProgress
            case .handbackUnconfirmed: self = .handbackUnconfirmed
            case .restoreToAutomaticUnconfirmed: self = .restoreToAutomaticUnconfirmed
            case .restoreToAutomaticFailed: self = .restoreToAutomaticFailed
            case .systemSleeping: self = .systemSleeping
            case .noThermalTelemetry: self = .noThermalTelemetry
            case .supervisorBlind: self = .supervisorBlind
            case .foreignManualControl: self = .foreignManualControl
            case .unknown: self = .unknown
            }
        }

        var reason: Reason {
            switch self {
            case .writePathNotBuilt: return .writePathNotBuilt
            case .boundsImplausible: return .boundsImplausible
            case .reclaimedBySystem: return .reclaimedBySystem
            case .leaseHeldByAnotherClient: return .leaseHeldByAnotherClient
            case .selfRenewalNotBuilt: return .selfRenewalNotBuilt
            case .releaseInProgress: return .releaseInProgress
            case .handbackUnconfirmed: return .handbackUnconfirmed
            case .restoreToAutomaticUnconfirmed: return .restoreToAutomaticUnconfirmed
            case .restoreToAutomaticFailed: return .restoreToAutomaticFailed
            case .systemSleeping: return .systemSleeping
            case .noThermalTelemetry: return .noThermalTelemetry
            case .supervisorBlind: return .supervisorBlind
            case .foreignManualControl: return .foreignManualControl
            case .unknown: return .unknown("fromTheFuture")
            }
        }
    }

    @Test("The tags map every reason both ways")
    func theTagsMapEveryReasonBothWays() {
        for tag in Tag.allCases {
            #expect(Tag(tag.reason) == tag, "\(tag)")
        }
    }

    /// **Mutation:** in `FanRowModel.refusal(for:)`, return `Refusal(summary: "Manual control
    /// is unavailable.", …)` — one sentence for every reason. Run: red for every argument.
    @Test("A refused fan shows its reason's own summary and advice", arguments: Tag.allCases)
    func everyReasonRendersItsText(_ tag: Tag) throws {
        let reason = tag.reason
        let row = Self.row(mode: .automatic, availability: .unavailable(reason))
        let refusal = try #require(row.refusal, "\(tag) rendered no refusal")

        #expect(refusal.summary == reason.userFacingSummary)
        #expect(refusal.advice == reason.recoveryAdvice)
        #expect(refusal.wireValue == reason.wireValue)
        #expect(!refusal.summary.isEmpty)
    }

    @Test("A fan the helper offers refuses nothing")
    func anAvailableFanRefusesNothing() {
        #expect(Self.row(availability: .available).refusal == nil)
    }

    @Test("An unknown reason's wire value is the helper's text, and is cleaned")
    func anUnknownReasonIsCleaned() throws {
        let row = Self.row(availability: .unavailable(.unknown("future\u{202E}Reason\nforged")))
        let refusal = try #require(row.refusal)

        #expect(refusal.wireValue == "futureReasonforged")
    }

    // MARK: - Observations

    @Test("A reading below the declared minimum still renders as an available actual value")
    func belowMinimumActualStillRendersAsAvailable() {
        let fan = FanPollingReading(
            index: 0,
            displayName: "Fan 0",
            actual: .value(key: "F0Ac", 1343.07),
            minimum: .value(key: "F0Mn", 1350),
            maximum: .value(key: "F0Mx", 5312),
            control: .notTracked(.noHelperInThisBuild))
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
            maximum: .value(key: "F2Mx", 5312),
            control: .notTracked(.noHelperInThisBuild))
        let row = FanRowModel(reading: fan)

        #expect(!row.actual.isAvailable)
        #expect(row.actual.text != "0")
        #expect(row.actual.text != "0 RPM")
        #expect(row.actual.text != "—")
        #expect(row.actual.text.contains("unavailable"))
    }
}
