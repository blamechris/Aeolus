import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// While the lease is being taken, held or given back, the process cannot be ended without warning;
/// while it is held, App Nap is kept away. Every call is balanced, because `ProcessInfo` counts.
///
/// Driven through `AppComposition`, whose root builds the assertions over the driver's own state
/// stream. Each step waits, boundedly, for the call it must cause, then checks every counter.
@Suite("Lease process assertions — termination and App Nap", .timeLimit(.minutes(1)))
@MainActor
struct LeaseProcessAssertionsTests {

    typealias Call = FakeProcessLifetime.Call

    static let reason = LeaseProcessAssertions.reason
    static let disabled: [Call] = [.disableSudden, .disableAutomatic(reason)]
    static let enabled: [Call] = [.enableAutomatic(reason), .enableSudden]
    static let began: Call = .beginActivity(
        ProcessInfo.ActivityOptions.userInitiatedAllowingIdleSystemSleep.rawValue, reason)

    /// Every state, and whether it blocks termination: exhaustive, so a state added to the driver
    /// has to be listed here.
    ///
    /// **Mutation (P1, "not disabled while acquiring"):** in
    /// `LeaseProcessAssertions.blocksTermination`, move `.acquiring` to the `false` arm. Red here
    /// at `.acquiring`, and at the first requirement of `takeHoldRelease` and of the refusal test.
    @Test("Termination is blocked while acquiring, held or releasing, and only then")
    func whichStatesBlockTermination() throws {
        let lease = Lease(
            holderDescription: "Aeolus.app", expiresAt: Date(timeIntervalSince1970: 0),
            timeToLive: 30, isSelfRenewing: false)
        let target = try LeaseScene.target([0: 3000])
        let states: [(LeaseDriverState, Bool)] = [
            (.idle, false),
            (.acquiring(fans: [0]), true),
            (.held(HeldLease(lease: lease, fans: [0], phase: .confirmed(target))), true),
            (.releasing, true),
            (.released, false),
            (.lost(LeaseLoss(lease: lease, cause: .heartbeatFailed, afterWake: false)), false),
            (.refused(.manualControlUnavailable(reason: .leaseHeldByAnotherClient)), false),
        ]
        for (state, blocks) in states {
            #expect(LeaseProcessAssertions.blocksTermination(state) == blocks, "\(state)")
        }
    }

    /// Every transition from one kind of state to another, the same kind included, fed straight to
    /// the assertions: after each state the counters are exactly what that state needs, never
    /// deeper than one, and back to nothing at the end.
    ///
    /// P1, P2 and P3 are each red here too, for every pair that crosses the edge they break.
    @Test(
        "Every transition leaves the counters balanced",
        arguments: StateKind.allCases, StateKind.allCases)
    func everyTransitionIsBalanced(_ from: StateKind, _ to: StateKind) async throws {
        let process = FakeProcessLifetime()
        let (states, feed) = AsyncStream.makeStream(of: LeaseDriverState.self)
        let assertions = LeaseProcessAssertions(process: process, states: states)

        let sequence = [try from.state, try to.state, LeaseDriverState.idle]
        for state in sequence {
            feed.yield(state)
            let blocks = LeaseProcessAssertions.blocksTermination(state)
            let depth = blocks ? 1 : 0
            let activities = state.isHeld ? 1 : 0
            try #require(
                await becomes {
                    process.suddenDisabled == depth && process.automaticDisabled == depth
                        && process.openActivities == activities
                }, "\(from) → \(to), at \(state): \(process.calls)")
        }
        feed.finish()

        #expect(process.deepest.sudden <= 1)
        #expect(process.deepest.automatic <= 1)
        #expect(process.deepest.activities <= 1)
        withExtendedLifetime(assertions) {}
    }

    /// Acquiring disables both; held begins the activity; releasing ends it and keeps termination
    /// blocked; released enables both. Each exactly once.
    ///
    /// **Mutation (P2, "sudden termination left disabled after release"):** in
    /// `LeaseProcessAssertions.apply`, delete `process.enableSuddenTermination()`. Red at the last
    /// requirement here, and at the last requirement of the loss and refusal tests.
    @Test("Taking, holding and releasing the lease, each edge balanced")
    func takeHoldRelease() async throws {
        let scene = await CompositionScene(releaseBound: .seconds(1_000))
        let process = scene.process
        await scene.lease.helper.script(.acquire, .parked)
        await scene.lease.driver.take(try LeaseScene.target([0: 3000]))

        try #require(await becomes { process.calls == Self.disabled }, "\(process.calls)")
        #expect(process.suddenDisabled == 1)
        #expect(process.automaticDisabled == 1)
        #expect(process.openActivities == 0, "nothing is held yet")

        await scene.lease.helper.answerParked(.acquire)
        try #require(await becomes { process.calls == Self.disabled + [Self.began] })
        #expect(process.suddenDisabled == 1)
        #expect(process.openActivities == 1)

        await scene.lease.helper.script(.release, .parked)
        let releasing = scene.lease.call { await scene.lease.driver.releaseFans() }
        try #require(await becomes { process.calls == Self.disabled + [Self.began, .endActivity] })
        #expect(await scene.lease.driver.state == .releasing)
        #expect(process.suddenDisabled == 1, "still blocked until the release answers")
        #expect(process.automaticDisabled == 1)
        #expect(process.openActivities == 0)

        await scene.lease.helper.answerParked(.release)
        await scene.lease.waitForReturn(of: releasing)
        try #require(
            await becomes {
                process.calls == Self.disabled + [Self.began, .endActivity] + Self.enabled
            }, "\(process.calls)")
        #expect(process.suddenDisabled == 0)
        #expect(process.automaticDisabled == 0)
        #expect(process.openActivities == 0)
        await scene.finish()
    }

    /// A lease that ends as lost gives everything back: the activity and both counters.
    ///
    /// **Mutation (P3, "the activity is held after loss"):** in `LeaseProcessAssertions.apply`,
    /// end the activity only for `.releasing`, not whenever the state leaves `held`. Red at the
    /// requirement.
    @Test("A lost lease ends the activity and unblocks termination")
    func aLossGivesEverythingBack() async throws {
        let scene = await CompositionScene()
        let process = scene.process
        _ = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        try #require(await becomes { process.calls == Self.disabled + [Self.began] })

        await scene.lease.clock.untilParked { !$0.isEmpty }
        await scene.lease.helper.script(.renew, .refuse(.leaseUnknown))
        scene.lease.clock.advance(to: scene.lease.at(.seconds(10)))
        await scene.lease.waitForState { $0.isLost }

        try #require(
            await becomes {
                process.calls == Self.disabled + [Self.began, .endActivity] + Self.enabled
            }, "\(process.calls)")
        #expect(process.openActivities == 0)
        #expect(process.suddenDisabled == 0)
        #expect(process.automaticDisabled == 0)
        await scene.finish()
    }

    /// A refused acquisition blocked termination while it was in flight, and unblocks it after.
    /// Nothing was held, so no activity began.
    @Test("A refused acquisition unblocks termination and never begins an activity")
    func aRefusalGivesTerminationBack() async throws {
        let scene = await CompositionScene()
        let process = scene.process
        await scene.lease.helper.script(.acquire, .parked)
        await scene.lease.driver.take(try LeaseScene.target([0: 3000]))
        try #require(await becomes { process.calls == Self.disabled }, "\(process.calls)")

        await scene.lease.helper.answerParked(
            .acquire,
            throwing: AeolusXPCFault.manualControlUnavailable(reason: .leaseHeldByAnotherClient))
        await scene.lease.waitForState { if case .refused = $0 { true } else { false } }

        try #require(
            await becomes { process.calls == Self.disabled + Self.enabled }, "\(process.calls)")
        #expect(process.suddenDisabled == 0)
        #expect(process.openActivities == 0)
        await scene.finish()
    }
}

/// One driver state of each kind, for the transition table.
enum StateKind: CaseIterable, Sendable {
    case idle, acquiring, held, releasing, released, lost, refused

    var state: LeaseDriverState {
        get throws {
            let lease = Lease(
                holderDescription: "Aeolus.app", expiresAt: Date(timeIntervalSince1970: 0),
                timeToLive: 30, isSelfRenewing: false)
            switch self {
            case .idle: return .idle
            case .acquiring: return .acquiring(fans: [0])
            case .held:
                let target = try LeaseScene.target([0: 3000])
                return .held(HeldLease(lease: lease, fans: [0], phase: .confirmed(target)))
            case .releasing: return .releasing
            case .released: return .released
            case .lost:
                return .lost(LeaseLoss(lease: lease, cause: .heartbeatFailed, afterWake: false))
            case .refused:
                return .refused(.manualControlUnavailable(reason: .leaseHeldByAnotherClient))
            }
        }
    }
}
