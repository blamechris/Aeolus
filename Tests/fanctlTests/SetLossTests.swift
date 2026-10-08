import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import fanctl

/// What a snapshot can say about a hold: when the lease is no longer proof of control.
///
/// Pure, over hand-built snapshots. The same judgement run end to end against the simulated
/// helper, with the exit code and the release around it, is `FanctlSetLossTests`.
@Suite("fanctl set's judgement of a snapshot")
struct SetLossTests {

    typealias Fixtures = SafeStateTests

    private static let leaseID = UUID()

    private static func lease(_ id: UUID = leaseID) -> Lease {
        Lease(id: id, holderDescription: "fanctl", expiresAt: Date())
    }

    private static func snapshot(
        fans: [FanState], lease: Lease?, emergency: Bool = false
    ) -> SystemSnapshot {
        SystemSnapshot(
            fans: fans, sensors: [], activeLease: lease, isThermalEmergencyActive: emergency,
            capturedAt: Fixtures.captured)
    }

    private static func reclaimed(_ index: Int) -> FanState {
        FanState(
            index: index, actualRPM: .measured(1350), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: nil, mode: .automatic,
            isReclaimedBySystem: true, manualControlAvailability: .unavailable(.reclaimedBySystem))
    }

    @Test("A snapshot that lists the lease, with the fans in hand, is no loss")
    func noLoss() {
        let snapshot = Self.snapshot(fans: [Fixtures.fan(0), Fixtures.fan(1)], lease: Self.lease())
        #expect(SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0, 1]) == nil)
    }

    /// A covered fan that is missing from the snapshot cannot be called held. Not in the
    /// contract's list; the safe direction when the helper stops reporting a fan.
    ///
    /// **Mutation:** in `SetCommand.loss`, `continue` past a covered fan the snapshot lacks.
    /// Run: red.
    @Test("A covered fan the snapshot no longer reports is a loss")
    func aCoveredFanIsMissing() {
        let snapshot = Self.snapshot(fans: [Fixtures.fan(0)], lease: Self.lease())
        #expect(
            SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0, 1])
                == .fanNotReported(1))
        #expect(SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0]) == nil)
    }

    /// Fans the lease does not cover are not its business: another fan reclaimed is not our loss.
    ///
    /// **Mutation:** in `SetCommand.loss`, loop over every fan in the snapshot rather than the
    /// covered ones. Run: red.
    @Test("A fan the hold does not cover being reclaimed is not a loss")
    func anUncoveredFanIsReclaimed() {
        let snapshot = Self.snapshot(
            fans: [Fixtures.fan(0), Self.reclaimed(1)], lease: Self.lease())
        #expect(SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0]) == nil)
        #expect(
            SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0, 1])
                == .reclaimed(fan: 1))
    }

    @Test("A lease with another ID is not ours, whoever holds it")
    func anotherID() {
        let snapshot = Self.snapshot(fans: [Fixtures.fan(0)], lease: Self.lease(UUID()))
        guard
            case .leaseNotListed(let listed) = SetCommand.loss(
                in: snapshot, leaseID: Self.leaseID, covering: [0])
        else {
            Issue.record("another client's lease was taken for ours")
            return
        }
        #expect(listed?.holder == "fanctl")
    }

    @Test("Order: the lease, then the emergency, then the fans")
    func order() {
        let both = Self.snapshot(fans: [Self.reclaimed(0)], lease: Self.lease(), emergency: true)
        #expect(
            SetCommand.loss(in: both, leaseID: Self.leaseID, covering: [0]) == .thermalEmergency)
        let none = Self.snapshot(fans: [Self.reclaimed(0)], lease: nil, emergency: true)
        #expect(
            SetCommand.loss(in: none, leaseID: Self.leaseID, covering: [0])
                == .leaseNotListed(listed: nil))
    }

    /// The mode is the helper's report of a register it may not have been able to read, so it
    /// is not read here: a fan that reads automatic or manual beside a lease the helper lists
    /// is not a loss.
    ///
    /// **Mutation:** report a loss for `fan.mode == .automatic` in `SetCommand.loss`. Run: red.
    @Test("The mode alone is never a loss")
    func modeAlone() {
        for mode in [FanControlMode.automatic, .manualFixed, .manualCurve] {
            let snapshot = Self.snapshot(fans: [Fixtures.fan(0, mode: mode)], lease: Self.lease())
            #expect(
                SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0]) == nil,
                "\(mode)")
        }
    }
}
