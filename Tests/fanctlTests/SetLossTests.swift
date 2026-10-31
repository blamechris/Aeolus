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

    /// A fan the helper says it holds: manual, with the held target `FanState.targetRPM` states
    /// only while the same snapshot shows the fan held under the live lease.
    private static func held(_ index: Int, target: Double? = 4_670) -> FanState {
        FanState(
            index: index, actualRPM: .measured(1351), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: target, mode: .manualFixed,
            isReclaimedBySystem: false, manualControlAvailability: .available)
    }

    private static func reclaimed(_ index: Int) -> FanState {
        FanState(
            index: index, actualRPM: .measured(1350), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: nil, mode: .automatic,
            isReclaimedBySystem: true, manualControlAvailability: .unavailable(.reclaimedBySystem))
    }

    @Test("A snapshot that lists the lease, with every covered fan held, is no loss")
    func noLoss() {
        let snapshot = Self.snapshot(fans: [Self.held(0), Self.held(1)], lease: Self.lease())
        #expect(SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0, 1]) == nil)
    }

    /// A covered fan that is missing from the snapshot cannot be called held. Not in the
    /// contract's list; the safe direction when the helper stops reporting a fan.
    ///
    /// **Mutation:** in `SetCommand.loss`, `continue` past a covered fan the snapshot lacks.
    /// Run: red.
    @Test("A covered fan the snapshot no longer reports is a loss")
    func aCoveredFanIsMissing() {
        let snapshot = Self.snapshot(fans: [Self.held(0)], lease: Self.lease())
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
            fans: [Self.held(0), Self.reclaimed(1)], lease: Self.lease())
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

    /// Another client's holder is hostile input to a terminal. It is sanitised where the loss is
    /// built, as `status` and `auto` sanitise it where they print it; the message sanitises it
    /// again where it prints it (`SetMessagesTests.holderIsSanitisedWhenPrinted`).
    ///
    /// **Mutation (the review's U1):** store `$0.holderDescription` unsanitised in
    /// `SetCommand.loss`. Run: red.
    @Test("Another client's holder has its control and formatting characters removed")
    func holderIsSanitised() {
        let hostile = Lease(
            id: UUID(), holderDescription: "Evil\u{1B}[2J\u{202E}Corp", expiresAt: Fixtures.captured
        )
        let snapshot = Self.snapshot(fans: [Fixtures.fan(0)], lease: hostile)

        guard
            case .leaseNotListed(let listed) = SetCommand.loss(
                in: snapshot, leaseID: Self.leaseID, covering: [0])
        else {
            Issue.record("another client's lease was taken for ours")
            return
        }

        let holder = listed?.holder ?? ""
        #expect(holder.contains("Evil"), "the readable part of the name survives")
        #expect(!holder.unicodeScalars.contains("\u{1B}"))
        #expect(!holder.unicodeScalars.contains("\u{202E}"))
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
    /// is not read here: whatever it says, a fan that carries the helper's held target beside a
    /// lease the helper lists is held, and the mode is not what decides.
    ///
    /// **Mutation:** report a loss for `fan.mode == .automatic` in `SetCommand.loss`. Run: red.
    @Test("The mode alone is never a loss")
    func modeAlone() {
        for mode in [FanControlMode.automatic, .manualFixed, .manualCurve] {
            let fan = FanState(
                index: 0, actualRPM: .measured(1351), minimumRPM: .measured(1350),
                maximumRPM: .measured(5777), targetRPM: 4_670, mode: mode,
                isReclaimedBySystem: false, manualControlAvailability: .available)
            let snapshot = Self.snapshot(fans: [fan], lease: Self.lease())
            #expect(
                SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0]) == nil,
                "\(mode)")
        }
    }

    // MARK: - The held target

    /// **A lease the helper lists beside a fan it states no target for is not a hold.** The
    /// firmware can take a fan back before the reclamation watchdog has marked it; the snapshot
    /// then lists the lease, reads the fan automatic and states no held target
    /// (`HeldTargetReport`, #426). That used to be `started`, and then `holding` every ten
    /// seconds.
    ///
    /// Every mode is tried: the target, not the mode, is what is missing.
    ///
    /// **Mutation:** delete the `fan.targetRPM` guard in `SetCommand.loss`. Run: red on every row.
    @Test("A covered fan with no held target is a loss, whatever mode it reads")
    func noHeldTarget() {
        for mode in [FanControlMode.automatic, .manualFixed, .manualCurve] {
            let fan = FanState(
                index: 0, actualRPM: .measured(1351), minimumRPM: .measured(1350),
                maximumRPM: .measured(5777), targetRPM: nil, mode: mode,
                isReclaimedBySystem: false, manualControlAvailability: .available)
            let snapshot = Self.snapshot(fans: [fan], lease: Self.lease())
            #expect(
                SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0])
                    == .fanNotHeld(0),
                "\(mode)")
        }
    }

    /// Nothing is ever held at 0 RPM, and a negative speed is not a speed: neither is evidence
    /// that anything is held.
    ///
    /// **Mutation:** relax `held > 0` to `held >= 0` in `SetCommand.loss`. Run: red on the zero
    /// row.
    @Test("A held target that is not a positive speed is no target")
    func aTargetThatIsNotASpeed() {
        for target in [0.0, -1.0] {
            let snapshot = Self.snapshot(
                fans: [Self.held(0, target: target)], lease: Self.lease())
            #expect(
                SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0])
                    == .fanNotHeld(0),
                "\(target)")
        }
    }

    /// `all` holds several fans under one lease: one of them without a target is a loss, and the
    /// fan that is named is the one.
    @Test("Every covered fan must carry a target, and the one without is named")
    func eachCoveredFanIsChecked() {
        let snapshot = Self.snapshot(
            fans: [Self.held(0), Self.held(1, target: nil)], lease: Self.lease())
        #expect(
            SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0, 1])
                == .fanNotHeld(1))
        #expect(
            SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0]) == nil,
            "a fan the lease does not cover is not its business")
    }

    /// A reclaimed fan states no target either, but reclamation is the more specific thing to
    /// say about it; and the lease and the emergency still come first.
    @Test("A reclaimed fan is reported as reclaimed, not as lacking a target")
    func reclaimedBeforeNotHeld() {
        let snapshot = Self.snapshot(fans: [Self.reclaimed(0)], lease: Self.lease())
        #expect(
            SetCommand.loss(in: snapshot, leaseID: Self.leaseID, covering: [0])
                == .reclaimed(fan: 0))
    }
}
