import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `revokeLease(id:forFan:because:)` answers `.gone` only once the fan it names has left
/// `releasing` ([#368](https://github.com/blamechris/Aeolus/issues/368)).
///
/// A teardown that takes the lease out of the table first is still handing the fan back, and
/// its release notice to § 5 is sent from inside that handback. § 5 keeps its reclamation mark
/// only until the revocation returns, so a `.gone` answered at once lets that notice arrive
/// after the mark's window has closed. These hold the teardown's restore open on
/// `ParkingFanRestorer`, before it reaches the restorer it wraps, and ask what the revocation
/// does meanwhile. The composed race is `TerminalActionTeardownRaceTests`.
///
/// Every wait a mutant could make permanent is bounded by `outwaitCeiling`, so a waiter nothing
/// resumes is a red expectation naming what never finished rather than a wedged run.
@Suite(
    "A revocation that finds its lease ended outwaits that ending's handback",
    .timeLimit(.minutes(1)))
struct LeaseRevocationOutwaitTests {

    /// The TTL sweep ends L and is held inside its handback of fan 0; a revocation of L, for fan
    /// 0, then finds the table empty. It must not answer until the sweep's restore has returned,
    /// and it must restore nothing of its own.
    ///
    /// **Mutations**, each in `LeaseAuthority.swift`: **M1** delete
    /// `await outwaitHandback(of: fan)` from `revokeLease(id:forFan:because:)`, which is `main`'s
    /// behaviour — red on `.waiting`. **M2** delete
    /// `handbackWaiters.removeValue(forKey: fan)?.forEach { $0.resume() }` from
    /// `restore(_:because:)`'s `defer` — red on the revocation's ceiling and on
    /// `fansARevocationAwaits`. **M3** move that resumption to the end of `restore`'s body,
    /// after `guard !accepted.isEmpty else { return }` — red the same way as M2, because the
    /// ordinary handback returns before it.
    @Test("A revocation that finds its lease ended returns only once that ending's handback has")
    func aGoneRevocationReturnsOnlyOnceTheEndingsHandbackHas() async throws {
        let clock = TestClock()
        let recorder = RecordingFanRestorer()
        let parking = ParkingFanRestorer(over: recorder)
        let authority = LeaseFixture.authority(restorer: parking, clock: clock)
        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        clock.advance(by: .seconds(Lease.defaultTimeToLive))
        await parking.armNext()
        let sweep = observing { await authority.expireLapsedLeases() }
        try await parking.entered.wait()

        let revocation = observing {
            await authority.revokeLease(id: lease.id, forFan: 0, because: .systemReclaimed)
        }

        #expect(
            await revocationProgress(of: revocation, outwaiting: 0, in: authority) == .waiting,
            """
            the revocation answered while the sweep that ended its lease was still handing fan 0 \
            back, so the sweep's release notice can reach § 5 after the terminal action returns
            """)
        await parking.release.signal()
        #expect(try await finishedBeforeCeiling("the revocation", revocation) == .gone)
        try await finishedBeforeCeiling("the sweep", sweep)
        #expect(
            await recorder.restores == [.init(fans: [0], cause: .leaseExpired)],
            "the sweep's handback should be the only restore: the revocation ended nothing")
        #expect(await authority.fansARevocationAwaits.isEmpty, "a waiter outlived its handback")
        #expect(await authority.fansMidHandback.isEmpty)
    }

    /// A lease released completely before it is revoked leaves nothing to outwait: the revocation
    /// answers `.gone` without parking. `revokeLeaseRevokesOnlyTheNamedLiveLeaseWhole` asks the
    /// same of an ID the table never held.
    ///
    /// **Mutation (M4):** drop `guard releasing[fan] != nil else { return }` from
    /// `outwaitHandback(of:)`. Run: red on `.finished`, and on the revocation's ceiling.
    @Test("A revocation with no handback under way returns at once")
    func aGoneRevocationWithNoHandbackUnderWayReturnsAtOnce() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        let connection = ConnectionID()
        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        try await authority.releaseLease(id: lease.id, from: connection)
        #expect(await authority.fansMidHandback.isEmpty, "the release's handback had not returned")

        let revocation = observing {
            await authority.revokeLease(id: lease.id, forFan: 0, because: .systemReclaimed)
        }

        #expect(
            await revocationProgress(of: revocation, outwaiting: 0, in: authority) == .finished,
            "a revocation parked on fan 0 with no handback of fan 0 under way")
        #expect(try await finishedBeforeCeiling("the revocation", revocation) == .gone)
        #expect(await restorer.restores.count == 1, "the revocation of an ended lease restored")
    }

    /// A lease over fan 1 expires and is held inside its handback; a revocation that names fan 0
    /// does not wait for it. Waiting on every handback would let a client granting and releasing
    /// another fan keep § 5 parked while the fan it is giving up goes unwatched.
    ///
    /// **Mutation (M5):** replace `releasing[fan] != nil` with `!releasing.isEmpty` in
    /// `outwaitHandback(of:)`. Run: red on `.finished`, and on the revocation's ceiling — fan 1's
    /// drain resumes only fan 1's waiters.
    @Test("A revocation outwaits only the handback of the fan it names")
    func aGoneRevocationOutwaitsOnlyItsOwnFan() async throws {
        let clock = TestClock()
        let parking = ParkingFanRestorer(over: RecordingFanRestorer())
        let authority = LeaseFixture.authority(restorer: parking, clock: clock)
        _ = try await authority.acquireLease(LeaseFixture.request(fans: [1]), from: ConnectionID())
        clock.advance(by: .seconds(Lease.defaultTimeToLive))
        await parking.armNext()
        let sweep = observing { await authority.expireLapsedLeases() }
        try await parking.entered.wait()
        #expect(await authority.fansMidHandback == [1], "fan 1's handback is not under way")

        let revocation = observing {
            await authority.revokeLease(id: UUID(), forFan: 0, because: .systemReclaimed)
        }

        #expect(
            await revocationProgress(of: revocation, outwaiting: 0, in: authority) == .finished,
            "a revocation about fan 0 waited on fan 1's handback")
        #expect(try await finishedBeforeCeiling("the revocation", revocation) == .gone)
        await parking.release.signal()
        try await finishedBeforeCeiling("the sweep", sweep)
    }
}
