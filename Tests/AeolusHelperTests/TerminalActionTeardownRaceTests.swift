import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's terminal action keeps its reclamation mark when a lease-core teardown takes the lease
/// between the hand-back and the revocation
/// ([#368](https://github.com/blamechris/Aeolus/issues/368)).
///
/// `finaliseRelease(fanAt:heldUnder:because:)` holds the fan in `finalising` until its
/// revocation returns, and a release notice that arrives while it does skips its clear (#346). A
/// TTL sweep or a connection death that removes the lease first makes the revocation `.gone`;
/// that teardown's notice is then still inside `HelperFanRestorer`, and until #368 it could
/// arrive after `finalising` had closed and erase the mark: 4–6 times in 1,200 runs, 5–9 in 2,000
/// and 15 in 1,200 under load, about 2.5–12.5 per 1,000, and never in 1,200 run alone.
///
/// **Hand-built, from real types, because the composition root has no seam before the notice**,
/// and adding one there would be a production seam that exists for a test. The graph is
/// `ReclamationMachine`'s shape with the lease side made real: a real `LeaseAuthority` whose
/// restorer is `ParkingFanRestorer` over a real `HelperFanRestorer`, bound to this graph's own
/// § 3 and § 5, and § 5 asking the lease core through `ParkableHeldLeases`. The revocation's
/// effect launches the teardown and waits for it to be held inside the parking restorer — after
/// the lease left the table and its fans entered `releasing`, before the notice — so the removal
/// lands exactly between § 5's hand-back returning and its revocation reaching the lease core.
/// `FinaliseReleaseLedgerTests` keeps covering the composed wiring.
@Suite(
    "A teardown between § 5's hand-back and its revocation keeps the mark", .timeLimit(.minutes(1)))
struct TerminalActionTeardownRaceTests {

    /// What `SafetyLog.reclamationResolved(fan:)` says, and nothing else does.
    private static let resolved = "is no longer reported as taken from Aeolus"

    /// The lease-core teardown that takes the lease first.
    enum Teardown: CaseIterable, Sendable, CustomTestStringConvertible {
        case ttlSweep
        case connectionDeath

        var testDescription: String {
            switch self {
            case .ttlSweep: "the TTL sweep"
            case .connectionDeath: "the holder's connection dying"
            }
        }
    }

    /// Which fans the lease covers, and the one § 5 holds and gives up.
    ///
    /// The pair registers fan 1 and not fan 0, so the teardown hands back a fan § 5 never held
    /// beside the one it is giving up, and a revocation outwaiting the wrong fan — `index &+ 1` —
    /// finds nothing to wait for.
    enum Layout: CaseIterable, Sendable, CustomTestStringConvertible {
        case oneFan
        case secondOfTwo

        var leasedFans: [Int] { self == .oneFan ? [0] : [0, 1] }
        var givenUp: Int { self == .oneFan ? 0 : 1 }
        var testDescription: String { self == .oneFan ? "one fan" : "fan 1 of two" }
    }

    /// The terminal action outwaits the teardown's handback, so the teardown's notice lands
    /// while `finalising` holds the fan and the mark survives the call.
    ///
    /// The evidence that the notice ran at all is on the plane: the given-up fan restored twice —
    /// the hand-back, then the teardown's restore through `HelperFanRestorer`, which sends § 5
    /// its notice before that write — with exactly one restore through the lease core's restorer.
    ///
    /// **Mutation (M1):** delete `await outwaitHandback(of: fan)` from
    /// `LeaseAuthority.revokeLease(id:forFan:because:)`, which is `main`'s behaviour. Run: red on
    /// `.waiting`, the mark and the "resolved" line, in all four cases.
    /// **Mutation (M6):** pass `forFan: index &+ 1` at § 5's call site in
    /// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)`. Run: red on the same three.
    @Test(
        "A teardown taking the lease after the hand-back does not erase the terminal action's mark",
        arguments: Teardown.allCases, Layout.allCases)
    func aTeardownAfterTheHandBackKeepsTheMark(teardown: Teardown, layout: Layout) async throws {
        let graph = await TeardownRaceGraph.built(fans: layout.leasedFans)
        let fan = layout.givenUp
        let lease = try await graph.leases.acquireLease(
            LeaseFixture.request(fans: layout.leasedFans), from: graph.holder)
        try await graph.watchdog.manualControlEngaged(
            try commandableFan(fan, declaring: .held(at: 2_400)), under: lease.id)
        let landed = TeardownLanding()
        await graph.hops.beforeNextRevocation(graph.landing(teardown, recordingIn: landed))

        let cycles = observing { [graph] in
            for _ in 1...ReclamationLimits.blindCyclesBeforeDivergence {
                await graph.watchdog.cycle()
            }
        }

        let progress = await revocationProgress(of: cycles, outwaiting: fan, in: graph.leases)
        #expect(
            progress == .waiting,
            """
            § 5's revocation answered while \(teardown.testDescription) was still handing fan \
            \(fan) back, so its release notice can land after the terminal action has returned
            """)
        await graph.parking.release.signal()
        try await finishedBeforeCeiling("§ 5's cycles", cycles)
        let ending = try #require(await landed.ending, "the revocation's effect never ran")
        try await finishedBeforeCeiling("the teardown", ending)

        #expect(
            await landed.midHandback?.contains(fan) == true,
            "the teardown was not inside its handback of fan \(fan) when the revocation ran")
        #expect(graph.safetyLog.lines(containing: "no speed to re-assert").count == 1)
        #expect(graph.safetyLog.lines(containing: "had already ended").count == 1)
        #expect(await graph.leases.leaseCount == 0)
        #expect(await graph.parking.forwarded == 1, "the lease core restored other than once")
        #expect(
            await graph.plane.attempts.filter { $0 == .restoreToAutomatic(.fan(fan)) }.count == 2,
            "the hand-back, then the teardown's restore through the restorer, and nothing else")
        #expect(
            await graph.ledger.isReclaimed(fanAt: fan),
            """
            \(teardown.testDescription), landing between the hand-back and the revocation, \
            erased the reclamation § 5 gave fan \(fan) up for
            """)
        #expect(
            graph.safetyLog.lines(containing: "Fan \(fan) \(Self.resolved)").isEmpty,
            "the reclamation was logged resolved by the teardown racing the terminal action")
    }
}

/// The graph `TerminalActionTeardownRaceTests` builds, wired as `ReclamationMachine` wires its
/// own, with `HelperFanRestorer` on the lease side behind `ParkingFanRestorer`.
struct TeardownRaceGraph: Sendable {
    let plane: ScriptedControlPlane
    let clock: TestClock
    let parking: ParkingFanRestorer
    let leases: LeaseAuthority
    let hops: ParkableHeldLeases
    let watchdog: ReclamationWatchdog<ScriptedControlPlane>
    let ledger: ReclamationLedger
    let safetyLog: RecordedLog
    let holder = ConnectionID()

    /// Every fan in `fans` reads automatic, so a fan § 5 holds with nothing commanded reads as
    /// reclaimed, is graced, and reaches the terminal action on the
    /// `blindCyclesBeforeDivergence`th cycle with no speed to re-assert.
    static func built(fans: [Int]) async -> Self {
        let plane = ScriptedControlPlane(
            fans: Dictionary(uniqueKeysWithValues: fans.map { ($0, .automatic(at: 2_400)) }),
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let clock = TestClock()
        let latch = ThermalEmergencyLatch()
        let ledger = ReclamationLedger()
        let safetyLog = RecordedLog()
        let log = SafetyLog(recording: { [safetyLog] in safetyLog.append($0, $1) })
        let restorer = HelperFanRestorer(
            writer: SafetyActorWriter(plane: plane, level: .leaseExpiry), log: LeaseFixture.log)
        let parking = ParkingFanRestorer(over: restorer)
        let leases = LeaseFixture.authority(
            restorer: parking, thermalEmergency: latch, clock: clock)
        let hops = ParkableHeldLeases(leases)
        let telemetry = CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
        let emergency = ThermalEmergency(
            telemetry: telemetry,
            sightings: CriticalTemperatureCache(source: telemetry, clock: clock),
            writer: SafetyActorWriter(plane: plane, level: .thermalEmergency),
            leases: leases,
            latch: latch,
            handbackReadBack: LeaseFixture.reconciliation(over: plane),
            log: log)
        let writer = SafetyActorWriter(plane: plane, level: .reclamationWatchdog)
        let watchdog = ReclamationWatchdog(
            sensing: plane,
            writer: writer,
            engagement: EngagementDriver(
                writer: writer, leases: leases, latch: latch, emergency: emergency,
                clock: clock, level: .reclamationWatchdog, log: log),
            leases: hops,
            latch: latch,
            ledger: ledger,
            gate: FanExaminationGate(clock: clock, log: log),
            log: log)
        await restorer.bind(thermalEmergency: emergency, reclamationWatchdog: watchdog)
        await leases.bind(emergencyRestores: emergency)
        return Self(
            plane: plane, clock: clock, parking: parking, leases: leases, hops: hops,
            watchdog: watchdog, ledger: ledger, safetyLog: safetyLog)
    }

    /// The revocation's effect: arm the parking restorer, lapse the lease for the TTL sweep, launch
    /// the teardown detached, and return once it is held inside its handback — with the lease out
    /// of the table, its fans in `releasing` and its notice to § 5 not yet sent.
    fileprivate func landing(
        _ teardown: TerminalActionTeardownRaceTests.Teardown,
        recordingIn landed: TeardownLanding
    ) -> @Sendable () async -> Void {
        { [self] in
            await parking.armNext()
            if teardown == .ttlSweep {
                clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
            }
            let flag = CompletionFlag()
            let ending = Task<Void, any Error>.detached {
                await self.end(by: teardown)
                await flag.mark()
            }
            await landed.record(ObservableWork(task: ending, isFinished: flag))
            try? await parking.entered.wait()
            await landed.record(midHandback: await leases.fansMidHandback)
        }
    }

    /// Ends the holder's lease the way `teardown` does. The TTL's clock is moved first.
    private func end(by teardown: TerminalActionTeardownRaceTests.Teardown) async {
        switch teardown {
        case .ttlSweep: await leases.expireLapsedLeases()
        case .connectionDeath: await leases.connectionDidInvalidate(holder)
        }
    }
}

/// What the revocation's effect launched and saw, for the test to await and assert after.
private actor TeardownLanding {
    private(set) var ending: ObservableWork<Void>?
    private(set) var midHandback: Set<Int>?

    func record(_ ending: ObservableWork<Void>) { self.ending = ending }
    func record(midHandback fans: Set<Int>) { midHandback = fans }
}
