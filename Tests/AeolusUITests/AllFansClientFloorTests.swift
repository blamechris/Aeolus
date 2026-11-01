import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The app's all-fans 50 % preset under the helper's client floor (#670's (b), ADR 0014's
/// minimal-run amendment, item 7 (b) as re-ruled on 2026-11-01). The floor is 65 % of each fan's
/// declared range, and 50 % is below it, so the helper holds each fan at its floor and its
/// snapshot says so. The app keeps the lease, shows the preset it asked for as selected, and
/// names the target the helper holds beneath it (`CLAUDE.md` rule 6): not pending, not refused,
/// not lost.
///
/// Fan 0 declares 1,350 to 5,777 (50 % is 3,564, the floor 4,227.55) and fan 1 1,200 to 4,800
/// (3,000 and 3,540), `AllFansFixtures.bounds(_:)`.
@Suite("All fans — the 50 % preset held at the client floor (#670)")
struct AllFansClientFloorTests {

    typealias Fixtures = FanControlFixtures
    typealias Fans = AllFansFixtures
    typealias Support = SnapshotTestSupport

    /// The floor the helper holds fan `index` at: 65 % of its declared range, as ADR 0014's item
    /// 7 (b) states it. The app does not compute it; the snapshot carries it.
    static func floor(_ index: Int) -> Double {
        let (minimum, maximum) = Fans.bounds(index)
        return minimum + 0.65 * (maximum - minimum)
    }

    /// The snapshot that shows `lease` holding both fans at their floors.
    static func heldAtTheFloors(_ lease: Lease) -> SystemSnapshot {
        Support.snapshot(
            fans: [Fans.held(0, at: floor(0)), Fans.held(1, at: floor(1))], activeLease: lease)
    }

    /// The control after a confirmed 50 % `apply`, beside a snapshot that holds each fan at its
    /// floor: 50 % selected, never pending, and each fan's line names the held target, not the
    /// speed sent.
    ///
    /// **Mutation:** in `FanControlPresentation.customLine`, name `speed.rpm` in place of the
    /// snapshot's `target`. Run: red, each line naming the speed sent as the held target.
    @Test("The 50 % preset held at the floor stays selected, and names the held target")
    func theControlNamesTheHeldTarget() throws {
        let target = try Fans.target(.fifty, fans: [0, 1])
        #expect(try Fans.rpm(.fifty, fan: 0) < Self.floor(0), "50 % is not below fan 0's floor")
        let control = AllFansControlPresentationTests.control(
            Self.heldAtTheFloors(Fixtures.ours),
            driver: Fixtures.held(Fixtures.ours, fans: [0, 1], .confirmed(target)))

        #expect(control.selection == .percent(.fifty))
        #expect(control.affordance == .enabled)
        let lines = control.statusLines.map(\.value.text)
        #expect(
            lines.contains { $0.hasSuffix("reports a held target of 4227.55 RPM.") }, "\(lines)")
        #expect(lines.contains { $0.hasSuffix("reports a held target of 3540 RPM.") }, "\(lines)")
        #expect(!lines.contains { $0.contains("Not confirmed") }, "\(lines)")
        #expect(!lines.contains { $0.contains("held target of 3564 RPM") }, "\(lines)")
    }

    /// The driver, against its fake helper: a confirmed 50 % lease whose snapshot shows each fan
    /// held at its floor, above the speed sent, is still held and confirmed. A held target is the
    /// evidence of control (`SystemSnapshot.controlLoss`); one other than the speed sent is not a
    /// loss.
    @Test("A snapshot holding the 50 % preset at the floors keeps the lease")
    func theDriverKeepsTheLease() async throws {
        let scene = await LeaseScene()
        let target = try Fans.target(.fifty, fans: [0, 1])
        let held = try #require(await scene.take(target), "the 50 % preset was not confirmed")

        let ticket = await scene.driver.beginSnapshotRead()
        await scene.driver.observe(Self.heldAtTheFloors(held.lease), readWith: ticket)

        let state = await scene.driver.state
        guard case .held(let now) = state else {
            Issue.record("the lease ended over fans held at their floors: \(state)")
            return await scene.finish()
        }
        #expect(now.phase == .confirmed(target))
        await scene.finish()
    }
}
