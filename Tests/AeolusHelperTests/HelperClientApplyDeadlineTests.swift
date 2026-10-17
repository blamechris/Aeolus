import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// `apply`'s own deadline: as long as the helper may lawfully take for the fans it names
/// ([#325](https://github.com/blamechris/Aeolus/issues/325), ADR 0014's #410 amendment).
///
/// ## Nothing here waits for a deadline
///
/// `apply`'s shipping deadline is 57 s for one fan and 109 s for two, and the client tests that
/// wait for a bound in real time are the ones a stalled runner fails
/// ([#341](https://github.com/blamechris/Aeolus/issues/341),
/// [#407](https://github.com/blamechris/Aeolus/issues/407)). So every client here measures its
/// deadlines on a `ManualClock` that only the test moves. A deadline runs out when the test moves
/// the hands past it and at no other time, whatever the runner is doing. The XPC round trips are
/// the only thing still on the wall clock: the suite waits for each hop with a generous bound and
/// asserts nothing about how long one took.
///
/// The deadlines are injected, and differ from the shipping ones: 7 s for a gated verb and 70 s per
/// fan. A client that read `HelperClientDeadlines`' constants instead of its own would then wait,
/// and report, a figure these tests do not expect. Both are looser than the shipping figures, so
/// `HelperClientDeadlineLiteralTests` needs no licence for them. On a clock that never moves by
/// itself, their size costs nothing.
@Suite("apply's own client deadline", .timeLimit(.minutes(1)))
struct HelperClientApplyDeadlineTests {

    static let deadlines = HelperClientDeadlines(
        gatedVerb: .seconds(7),
        panicVerb: HelperClientDeadlines.panicVerb,
        handshakeVerb: HelperClientDeadlines.handshakeVerb,
        applyPerFan: .seconds(70))

    static let lease = Lease(
        id: UUID(),
        holderDescription: "test client",
        expiresAt: Date(timeIntervalSince1970: 1_000_030),
        timeToLive: 30)

    static func fan(_ index: Int, rpm: Double = 2_000) -> FanSetting {
        FanSetting(fanIndex: index, control: .fixed(rpm: rpm))
    }

    /// One client on a frozen clock, with an `apply` the helper has accepted and not answered.
    ///
    /// Built in an order that leaves exactly one deadline running: a `snapshot` first, so the
    /// connection exists and its handshake is over, and only then the `apply`. Each earlier
    /// message's deadline ended when it was answered, and `ManualClock` honours that
    /// cancellation, so the one sleep parked on the clock when this returns is the `apply`'s own.
    /// The wait for it is a hop, not a deadline.
    ///
    /// The harness is a stored property and every test reads `sessions` off it last, which keeps
    /// it alive past the client's last call (#239) and states that one connection carried the
    /// whole test.
    struct ParkedApply {
        let release: AsyncSignal
        let authority: LeaseGrantingAuthority
        let harness: ClientListenerHarness
        let clock: ManualClock
        let client: HelperClient
        let health: OrderRecord<HelperConnectionHealth>
        let watcher: Task<Void, Never>
        let generation: UInt64
        let apply: Task<Void, Error>

        static func sending(_ settings: [FanSetting]) async throws -> ParkedApply {
            let release = AsyncSignal()
            let authority = LeaseGrantingAuthority(lease: lease, applyGate: release)
            let harness = ClientListenerHarness(authority: authority)
            let clock = ManualClock()
            let client = HelperClient(
                transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
                clientDescription: "test client", deadlines: deadlines, clock: clock)

            let health = OrderRecord<HelperConnectionHealth>()
            let watcher = Task {
                for await state in client.healthUpdates() { health.append(state) }
            }

            _ = try await client.snapshot()
            let generation = await client.currentGeneration

            let apply = Task { try await client.apply(settings, leaseID: lease.id) }
            try await waitUntil(
                "the apply is parked in the helper and its deadline is running",
                timeout: .seconds(30)
            ) {
                await authority.hasBeenAskedToApply && clock.sleepers == 1
            }

            return ParkedApply(
                release: release, authority: authority, harness: harness, clock: clock,
                client: client, health: health, watcher: watcher, generation: generation,
                apply: apply)
        }

        /// The `apply` was answered and nothing about the connection moved: it is the one the
        /// test started with, it is still handshaken, it never read `.unresponsive`, and the
        /// helper never saw it go — which is what would have ended the lease.
        func expectAnsweredOnTheSameConnection(
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            try await apply.value

            let generation = await client.currentGeneration
            #expect(
                generation == self.generation,
                """
                the connection moved from generation \(self.generation) to \(generation): the \
                client gave up on an `apply` the helper was still inside its contract on, and a \
                connection given up is a lease ended (#325).
                """,
                sourceLocation: sourceLocation)
            #expect(await client.health == .handshaken, sourceLocation: sourceLocation)
            #expect(
                !health.entries.contains(.unresponsive),
                "the health signal read \(health.entries) on the way",
                sourceLocation: sourceLocation)
            #expect(
                await authority.invalidatedConnections.isEmpty,
                "the helper saw the connection go, which releases its lease",
                sourceLocation: sourceLocation)
            #expect(harness.sessions.count == 1, sourceLocation: sourceLocation)
        }
    }

    /// **D2. An `apply` the helper answers after `gatedVerb` has passed is answered.**
    ///
    /// The defect #325 names: every gated verb waited `gatedVerb`, so an `apply` that engaged a
    /// fan, which may lawfully take a gate wait, a yield and several scheduler turns, was cut off
    /// at 5 s with nothing wrong. Cut off, it discarded the connection, the helper ended the lease,
    /// and the client reported an unresponsive helper.
    ///
    /// The clock is moved past `gatedVerb`, and to half the per-fan figure beyond it, so short of
    /// one fan's deadline by any reading. The `apply`'s deadline must still be running, and the
    /// helper's answer must then arrive on the same connection.
    ///
    /// **Mutation:** in `HelperClient.apply`, drop `within:`, so `apply` waits `gatedVerb` like
    /// every other verb. Run: red on the sleeper count, the deadline having run out at the move,
    /// and on `apply.value`, thrown `helperNeverAnswered(after: 7.0 seconds)`.
    @Test("An apply answered after gatedVerb is answered")
    func anApplyAnsweredAfterGatedVerbIsAnswered() async throws {
        let parked = try await ParkedApply.sending([Self.fan(0)])
        defer { parked.watcher.cancel() }
        let answeredAt = Self.deadlines.gatedVerb + Self.deadlines.applyPerFan / 2

        parked.clock.advance(by: answeredAt)
        #expect(
            parked.clock.sleepers == 1,
            """
            the apply's deadline ran out by \(answeredAt), past `gatedVerb` and short of one \
            fan's \(Self.deadlines.gatedVerb + Self.deadlines.applyPerFan).
            """)
        await parked.release.signal()

        try await parked.expectAnsweredOnTheSameConnection()
    }

    /// **D3. An `apply` that names two fans waits two fans' worth.**
    ///
    /// The clock is moved to one and a half times the per-fan figure: past one fan's deadline
    /// (`gatedVerb` plus one `applyPerFan`) and short of two fans'. A first `apply` of two fans is
    /// the case #325 was filed for, and the one a flat deadline cuts off however long it is set.
    ///
    /// **Mutation:** in `HelperClientDeadlines.applyDeadline(naming:)`, multiply by 1 instead of by
    /// the fan count. Run: red on the sleeper count and on `apply.value`, thrown
    /// `helperNeverAnswered(after: 77.0 seconds)`.
    @Test("An apply of two fans gets two fans' deadline")
    func anApplyOfTwoFansGetsTwoFansDeadline() async throws {
        let parked = try await ParkedApply.sending([Self.fan(0), Self.fan(1)])
        defer { parked.watcher.cancel() }

        let answeredAt = Self.deadlines.applyPerFan * 3 / 2

        parked.clock.advance(by: answeredAt)
        #expect(
            parked.clock.sleepers == 1,
            """
            a two-fan apply's deadline ran out by \(answeredAt), short of two fans' \
            \(Self.deadlines.gatedVerb + Self.deadlines.applyPerFan * 2).
            """)
        await parked.release.signal()

        try await parked.expectAnsweredOnTheSameConnection()
    }

    /// **D4. An `apply` past its deadline says that control ended, and it has.**
    ///
    /// Past its deadline the helper is outside its contract, so the connection is still
    /// discarded: everything sequenced behind the `apply` would otherwise wait for it too. The
    /// discard is what ends the lease, because the helper releases a connection's leases when it
    /// goes, so the error has to say so. Before #325 it said only that nothing could be said about
    /// whether the request took effect, which leaves a caller believing it still holds fans it
    /// has just given back (rule 6).
    ///
    /// The clock is moved to exactly one fan's deadline, which ends it. The client must report the
    /// deadline it waited, read `.unresponsive`, and say that giving up the connection ended any
    /// manual control it held; and the helper must see the connection go.
    ///
    /// **Mutation:** put `helperNeverAnswered`'s description back to its text before #325. Run:
    /// red on the description alone. **Mutation:** in `HelperClient.translate(_:on:)`, delete the
    /// `discardConnection(generation, as: .unresponsive)` in the `.helperNeverAnswered` arm. Run:
    /// red on the health, on the generation, and on the helper's sighting of the connection.
    @Test("An apply past its deadline says control ended")
    func anApplyPastItsDeadlineSaysControlEnded() async throws {
        let parked = try await ParkedApply.sending([Self.fan(0)])
        defer { parked.watcher.cancel() }
        let deadline = Self.deadlines.gatedVerb + Self.deadlines.applyPerFan

        parked.clock.advance(by: deadline)
        let error = await #expect(throws: HelperClientError.self) {
            try await parked.apply.value
        }
        #expect(error == .helperNeverAnswered(after: deadline))

        let description = error?.errorDescription ?? ""
        #expect(
            description.contains("ends any manual control it held"),
            "a cut-off apply said only: \(description)")
        #expect(await parked.client.health == .unresponsive)
        #expect(await parked.client.currentGeneration != parked.generation)
        try await waitUntil(
            "the helper saw the connection go, which ends its lease", timeout: .seconds(30)
        ) {
            await parked.authority.invalidatedConnections.count == 1
        }

        await parked.release.signal()
        #expect(parked.harness.sessions.count == 1)
    }

    /// **Two settings for one fan are one fan's deadline.**
    ///
    /// Level 6 refuses settings that name a fan twice, so the request engages one fan at most and
    /// the helper's lawful bound is one fan's. The deadline counts distinct fans for that reason,
    /// and the figure the client reports is the one it waited: moving the clock far past every
    /// candidate runs it out whichever it is, and the error names it.
    ///
    /// The client still sends both settings. Refusing the duplicate is level 6's job, and this
    /// client neither repairs a request nor validates one on the helper's behalf.
    ///
    /// **Mutation:** in `HelperClientDeadlines.applyDeadline(naming:)`, count `settings.count`
    /// instead of the distinct fan indices. Run: red on the thrown error, which names
    /// `helperNeverAnswered(after: 147.0 seconds)` where one fan's 77 s was expected.
    @Test("Settings that name one fan twice get one fan's deadline")
    func settingsThatNameOneFanTwiceGetOneFansDeadline() async throws {
        let settings = [Self.fan(0, rpm: 2_000), Self.fan(0, rpm: 2_400)]
        let parked = try await ParkedApply.sending(settings)
        defer { parked.watcher.cancel() }
        let oneFan = Self.deadlines.gatedVerb + Self.deadlines.applyPerFan

        parked.clock.advance(by: oneFan * 10)
        await #expect(throws: HelperClientError.helperNeverAnswered(after: oneFan)) {
            try await parked.apply.value
        }
        #expect(await parked.authority.applied == settings)

        await parked.release.signal()
        #expect(parked.harness.sessions.count == 1)
    }
}
