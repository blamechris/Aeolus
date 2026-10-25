import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// `LeaseTarget.setting(_:to:)` and `removing(_:)`, what the driver's per-fan verbs compose with
/// (#154): pure, every other fan's speed kept, and never an empty target.
@Suite("LeaseTarget — one fan at a time")
struct LeaseTargetOneFanTests {

    static func speed(_ rpm: Double) throws -> FanTargetRPM {
        try #require(try LeaseScene.target([0: rpm]).speeds[0])
    }

    @Test("Setting a fan the target names replaces its speed and keeps the others")
    func settingAFanItNames() throws {
        let target = try LeaseScene.target([0: 3000, 1: 3200])

        let set = target.setting(1, to: try Self.speed(4000))

        #expect(set == (try LeaseScene.target([0: 3000, 1: 4000])))
        #expect(set.fans == target.fans, "the same fans: a re-apply, not a change of set")
        #expect(target == (try LeaseScene.target([0: 3000, 1: 3200])), "the original is kept")
    }

    @Test("Setting a fan the target does not name adds it")
    func settingANewFan() throws {
        let target = try LeaseScene.target([0: 3000])

        let set = target.setting(2, to: try Self.speed(4000))

        #expect(set == (try LeaseScene.target([0: 3000, 2: 4000])))
        #expect(set.fans == [0, 2])
    }

    @Test("Removing a fan keeps the others; removing the last answers nil")
    func removing() throws {
        let target = try LeaseScene.target([0: 3000, 1: 3200])

        let rest = try #require(target.removing(1))
        #expect(rest == (try LeaseScene.target([0: 3000])))
        #expect(rest.removing(0) == nil, "a lease over no fans is not a target")
        #expect(target.removing(5) == target, "a fan it does not name: unchanged")
    }

    @Test("A target over one fan, as takeFan makes from nothing")
    func oneFan() throws {
        let speed = try Self.speed(3300)

        let target = LeaseTarget(fan: 1, at: speed)

        #expect(target.fans == [1])
        #expect(target.speeds == [1: speed])
    }
}
