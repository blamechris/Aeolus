import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// A `LeaseDriver` over a `FakeLeaseHelper` and a `HandWoundClock`, with the driver's states
/// forwarded into the scene's `LeaseLedger`.
///
/// Every wait here is on the ledger or the clock, so none spends wall-clock time and none blocks a
/// thread. A test whose driver never does what it waits for does not finish; the suites carry a
/// one-minute time limit so that it fails instead, as the helper's suites do.
struct LeaseScene: Sendable {

    static let holder = "Aeolus.app 9.9.9"

    let clock: HandWoundClock
    let ledger: LeaseLedger
    let helper: FakeLeaseHelper
    let driver: LeaseDriver
    /// Where the clock's hands start, and the instant every offset in a test is measured from.
    let start: ContinuousClock.Instant
    private let forwarding: Task<Void, Never>

    init(releaseBound: Duration = LeaseDriver.releaseBound) async {
        let clock = HandWoundClock()
        let ledger = LeaseLedger()
        let helper = FakeLeaseHelper(clock: clock, ledger: ledger)
        let driver = LeaseDriver(
            control: helper, holderDescription: Self.holder, clock: clock,
            releaseBound: releaseBound)
        self.clock = clock
        self.ledger = ledger
        self.helper = helper
        self.driver = driver
        self.start = clock.now
        let updates = driver.stateUpdates()
        forwarding = Task {
            for await state in updates { await ledger.record(.state(state), at: clock.now) }
        }
        // The subscription is in place before the test acts, so no state is missed.
        await ledger.waitFor { $0.states.contains(.idle) }
    }

    /// `start` plus `duration`.
    func at(_ duration: Duration) -> ContinuousClock.Instant {
        start.advanced(by: duration)
    }

    /// A target of fixed speeds, each minted through a plausible envelope (1350 to 5777 RPM, the
    /// development machine's) as the app will mint one.
    static func target(_ speeds: [Int: Double]) throws -> LeaseTarget {
        guard
            case .success(let envelope) = FanControlEnvelope.validating(
                declaredMinimumRPM: 1350, declaredMaximumRPM: 5777)
        else {
            throw TargetError.envelopeRefused
        }
        return try #require(LeaseTarget(speeds: speeds.mapValues { envelope.target(for: $0) }))
    }

    enum TargetError: Error { case envelopeRefused }

    /// Takes `target` and waits until the helper has confirmed its `apply`, under a lease granted
    /// after this call: a confirmation already in the ledger, from an earlier lease with the same
    /// target, does not end the wait.
    @discardableResult
    func take(_ target: LeaseTarget) async -> HeldLease? {
        let from = await mark()
        await driver.take(target)
        await waitForState(since: from) { state in
            if case .held(let held) = state, held.phase == .confirmed(target) { return true }
            return false
        }
        if case .held(let held) = await driver.state { return held }
        return nil
    }

    /// Where the ledger ends now, for a wait that must look only at what comes after.
    func mark() async -> Int {
        await ledger.entries.count
    }

    /// Waits until the ledger shows a state satisfying `matches`, anywhere in it.
    func waitForState(_ matches: @escaping @Sendable (LeaseDriverState) -> Bool) async {
        await ledger.waitFor { $0.states.contains(where: matches) }
    }

    /// Waits until the ledger shows a state satisfying `matches`, recorded after `mark`.
    func waitForState(
        since mark: Int, _ matches: @escaping @Sendable (LeaseDriverState) -> Bool
    ) async {
        await ledger.waitFor { Array($0.dropFirst(mark)).states.contains(where: matches) }
    }

    /// The ledger now.
    var entries: [LeaseLedger.Entry] {
        get async { await ledger.entries }
    }

    /// A few round trips through the fake and the driver, for a test about something a driver
    /// must **not** do after a reply it has no reason to act on.
    ///
    /// That reply ends in the fake, then hops to the driver, and nothing a correct driver does
    /// next is visible, so there is no event to wait for. Each round trip here queues behind
    /// whatever the reply queued on the same actor, so after them the driver has handled it.
    /// That rests on an actor running the jobs queued on it in order, which is how Swift's
    /// default actors behave but not a language guarantee: a correct driver passes whatever the
    /// order, and only a mutant's red could be missed. It is a fixed number of hops, never a
    /// loop on a condition, and spends no time.
    func settle() async {
        for _ in 0..<4 {
            _ = await helper.heldLeases
            _ = await driver.state
            _ = await ledger.entries.count
        }
    }

    /// Ends the forwarding and answers anything still parked, so nothing waits on the fake.
    func finish() async {
        forwarding.cancel()
        await helper.disconnect()
    }
}

/// Waits until either wait returns, and cancels the other. Both waits a scene offers end when
/// cancelled, so this always finishes once one of them does.
func firstOf(
    _ first: @escaping @Sendable () async -> Void, _ second: @escaping @Sendable () async -> Void
) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask(operation: first)
        group.addTask(operation: second)
        await group.next()
        group.cancelAll()
    }
}

extension LeaseDriverState {

    var loss: LeaseLoss? {
        if case .lost(let loss) = self { return loss }
        return nil
    }

    var isLost: Bool { loss != nil }

    var isReleased: Bool { self == .released }
}
