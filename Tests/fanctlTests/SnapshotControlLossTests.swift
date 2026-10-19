import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

/// `SystemSnapshot.controlLoss(leaseID:covering:)`: when a snapshot says a lease is no longer
/// proof of control (#153).
///
/// Pure, over hand-built snapshots. The judgement is `AeolusXPCClient`'s, so the app and
/// `fanctl` share it; it is tested here because this is the pure target that links the client
/// and needs no helper to do it. The cases are those #324 wrote for `SetCommand.loss`, in
/// `SetLossTests`, asked of the shared function.
///
/// Not ported: #324's `holderIsSanitised`. Removing a hostile holder's control characters is
/// `fanctl`'s rendering, and stays with the caller that renders it; this function hands the
/// listed lease back verbatim, and `listedLeaseIsReturnedVerbatim` holds it to that.
@Suite("Whether a snapshot says control was lost")
struct SnapshotControlLossTests {

    private static let captured = Date(timeIntervalSince1970: 1_790_000_000)

    private static let leaseID = UUID()

    /// The modes a fan can read.
    static let modes: [FanControlMode] = [.automatic, .manualFixed, .manualCurve]

    private static func lease(_ id: UUID = leaseID, holder: String = "fanctl") -> Lease {
        Lease(id: id, holderDescription: holder, expiresAt: captured.addingTimeInterval(30))
    }

    private static func snapshot(
        fans: [FanState], lease: Lease?, emergency: Bool = false
    ) -> SystemSnapshot {
        SystemSnapshot(
            fans: fans, sensors: [], activeLease: lease, isThermalEmergencyActive: emergency,
            capturedAt: captured)
    }

    /// A fan the helper says it holds: manual, with the held target `FanState.targetRPM` states
    /// only while the same snapshot shows the fan held under the live lease.
    private static func held(
        _ index: Int, target: Double? = 4_670, mode: FanControlMode = .manualFixed
    ) -> FanState {
        FanState(
            index: index, actualRPM: .measured(1351), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: target, mode: mode,
            isReclaimedBySystem: false, manualControlAvailability: .available)
    }

    private static func reclaimed(_ index: Int) -> FanState {
        FanState(
            index: index, actualRPM: .measured(1350), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: nil, mode: .automatic,
            isReclaimedBySystem: true, manualControlAvailability: .unavailable(.reclaimedBySystem))
    }

    private static func loss(
        in snapshot: SystemSnapshot, covering fans: [Int]
    ) -> ControlLoss? {
        snapshot.controlLoss(leaseID: leaseID, covering: fans)
    }

    @Test("A snapshot that lists the lease, with every covered fan held, is no loss")
    func noLoss() {
        let snapshot = Self.snapshot(fans: [Self.held(0), Self.held(1)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0, 1]) == nil)
    }

    // MARK: - The lease

    @Test("A snapshot that lists no lease is a loss")
    func noLeaseListed() {
        let snapshot = Self.snapshot(fans: [Self.held(0)], lease: nil)
        #expect(Self.loss(in: snapshot, covering: [0]) == .leaseNotListed(listed: nil))
    }

    /// Another client holds the lease. The snapshot lists *a* lease, and every covered fan
    /// carries a held target, so the only thing that says this is not the caller's control is
    /// the identifier.
    ///
    /// **Mutation (M3):** in `controlLoss`, `guard activeLease != nil` instead of matching the
    /// identifier. Run: red here.
    @Test("A lease with another ID is not ours, whoever holds it")
    func anotherID() {
        let theirs = Self.lease(UUID(), holder: "fanctl")
        let snapshot = Self.snapshot(fans: [Self.held(0)], lease: theirs)
        #expect(Self.loss(in: snapshot, covering: [0]) == .leaseNotListed(listed: theirs))
    }

    /// The listed lease comes back as the helper sent it, holder text included. Sanitising it
    /// is the renderer's job (`fanctl`'s `DisplayText.sanitised`), because what is safe to show
    /// depends on where it is shown.
    @Test("Another client's lease is returned verbatim, for the caller to render")
    func listedLeaseIsReturnedVerbatim() {
        let hostile = Self.lease(UUID(), holder: "Evil\u{1B}[2J\u{202E}Corp")
        let snapshot = Self.snapshot(fans: [Self.held(0)], lease: hostile)
        guard case .leaseNotListed(let listed) = Self.loss(in: snapshot, covering: [0]) else {
            Issue.record("another client's lease was taken for ours")
            return
        }
        #expect(listed == hostile)
        #expect(listed?.holderDescription == "Evil\u{1B}[2J\u{202E}Corp")
    }

    // MARK: - The order

    /// The lease, then the emergency, then the fans. Each pair of adjacent rules is held by a
    /// snapshot on which both apply.
    ///
    /// **Mutation (M5):** swap the first two rules in `controlLoss`, so the emergency is judged
    /// before the lease. Run: red on the `none` row.
    @Test("Order: the lease, then the emergency, then the fans")
    func order() {
        let both = Self.snapshot(fans: [Self.reclaimed(0)], lease: Self.lease(), emergency: true)
        #expect(Self.loss(in: both, covering: [0]) == .thermalEmergency)
        let none = Self.snapshot(fans: [Self.reclaimed(0)], lease: nil, emergency: true)
        #expect(Self.loss(in: none, covering: [0]) == .leaseNotListed(listed: nil))
    }

    /// A reclaimed fan states no target either, but reclamation is the more specific thing to
    /// say about it; and the lease and the emergency still come first.
    @Test("A reclaimed fan is reported as reclaimed, not as lacking a target")
    func reclaimedBeforeNotHeld() {
        let snapshot = Self.snapshot(fans: [Self.reclaimed(0)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0]) == .reclaimedBySystem(fan: 0))
    }

    // MARK: - The covered fans

    /// A covered fan that is missing from the snapshot cannot be called held: the safe
    /// direction when the helper stops reporting a fan.
    @Test("A covered fan the snapshot no longer reports is a loss")
    func aCoveredFanIsMissing() {
        let snapshot = Self.snapshot(fans: [Self.held(0)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0, 1]) == .fanNotReported(fan: 1))
        #expect(Self.loss(in: snapshot, covering: [0]) == nil)
    }

    /// Fans the lease does not cover are not its business: another fan reclaimed is not this
    /// lease's loss.
    @Test("A fan the lease does not cover being reclaimed is not a loss")
    func anUncoveredFanIsReclaimed() {
        let snapshot = Self.snapshot(fans: [Self.held(0), Self.reclaimed(1)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0]) == nil)
        #expect(Self.loss(in: snapshot, covering: [0, 1]) == .reclaimedBySystem(fan: 1))
    }

    /// The mode is the helper's report of a register it may not have been able to read, so it
    /// is not read here: whatever it says, a fan that carries the helper's held target beside a
    /// lease the helper lists is held.
    @Test("The mode alone is never a loss", arguments: modes)
    func modeAlone(_ mode: FanControlMode) {
        let snapshot = Self.snapshot(fans: [Self.held(0, mode: mode)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0]) == nil)
    }

    // MARK: - The held target

    /// **A lease the helper lists beside a fan it states no target for is not a hold.** The
    /// firmware can take a fan back before the reclamation watchdog has marked it; the snapshot
    /// then lists the lease and states no held target (#426). Every mode is tried: the target,
    /// not the mode, is what is missing, and a fan that reads manual with no target is the case
    /// a mode-based judgement gets wrong.
    ///
    /// **Mutation (M2):** in `controlLoss`, judge held from the mode, `guard fan.mode !=
    /// .automatic`, instead of from `targetRPM`. Run: red on the `manualFixed` and
    /// `manualCurve` rows.
    @Test("A covered fan with no held target is a loss, whatever mode it reads", arguments: modes)
    func noHeldTarget(_ mode: FanControlMode) {
        let snapshot = Self.snapshot(
            fans: [Self.held(0, target: nil, mode: mode)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0]) == .fanNotHeld(fan: 0))
    }

    /// Nothing is ever held at 0 RPM, and a negative speed is not a speed: neither is evidence
    /// that anything is held.
    ///
    /// **Mutation (M4):** drop `, held > 0` from the target check in `controlLoss`. Run: red on
    /// both rows.
    @Test("A held target that is not a positive speed is no target", arguments: [0.0, -1.0])
    func aTargetThatIsNotASpeed(_ target: Double) {
        let snapshot = Self.snapshot(fans: [Self.held(0, target: target)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0]) == .fanNotHeld(fan: 0))
    }

    /// A lease that covers several fans: one of them without a target is a loss, and the fan
    /// that is named is the one.
    @Test("Every covered fan must carry a target, and the one without is named")
    func eachCoveredFanIsChecked() {
        let snapshot = Self.snapshot(
            fans: [Self.held(0), Self.held(1, target: nil)], lease: Self.lease())
        #expect(Self.loss(in: snapshot, covering: [0, 1]) == .fanNotHeld(fan: 1))
        #expect(
            Self.loss(in: snapshot, covering: [0]) == nil,
            "a fan the lease does not cover is not its business")
    }
}
