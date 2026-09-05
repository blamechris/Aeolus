import SMCCore
import Testing

@testable import AeolusHelper

/// `SMCFanControlPlane.reconnect()`: what it must never land in the middle of, and what it
/// must actually fix.
///
/// ## Why a fake SMC and not a mock connection
///
/// The two properties here are both about a *connection and a provider being the same
/// thing*. "The recycle did not land inside a read" is only meaningful if the reads and the
/// close/open are ordered against each other; "a stale handle reads again afterwards" is only
/// meaningful if closing and reopening is what changed the reads. A mock connection that
/// counted calls could express neither — it would assert that `reconnect()` called two
/// methods, which is a restatement of the body rather than a test of it.
///
/// So `FakeSMC` is one actor holding both: an ordered event log, an open/closed handle, and a
/// staleness bit. `FakeSMCProvider` and `FakeSMCConnection` are two views of it, wired
/// exactly as `HelperComposition.production(log:)` wires the real pair.
///
/// `.timeLimit` for `SMCReadSchedulerTests`' reason: a scheduler that stops granting turns
/// makes a task join hang, and a green suite must mean the tests ran.
@Suite("SMC connection recovery", .timeLimit(.minutes(1)))
struct ConnectionRecoveryTests {

    private static func keys(_ count: Int) -> [String] {
        (0..<count).map { "S\($0)" }
    }

    // MARK: - Serialisation

    /// **The exclusive turn, asserted at the one instant it matters.**
    ///
    /// `SMCSensorProvider.read(keys:)` opens idempotently and then issues its round trips
    /// against whatever handle it found. A `close()` landing between those two steps
    /// invalidates the handle *mid-request*, so the read fails with a firmware error nothing
    /// on this machine caused — a fault produced by the recovery, indistinguishable from the
    /// one being recovered from. #103's decision A6 is why `reconnect()` takes an exclusive
    /// scheduler turn, and this is that decision as an assertion.
    ///
    /// ## The script
    ///
    /// A three-turn read is put on the connection and held inside the provider on turn 1. The
    /// reconnect is then started, and the test waits for **either** of two facts before
    /// releasing anything: the reconnect queued at `.supervisor`, or the connection was
    /// already closed. Waiting on the disjunction is what makes the mutation red rather than
    /// hung — under it the reconnect never queues, so a wait on the queue alone would time
    /// out and report a wait instead of the interleaving.
    ///
    /// Three turns rather than one, because a single-turn read cannot distinguish "the
    /// recycle waited for the read" from "the recycle waited for the whole request". The
    /// scheduler's contract is the former: `withExclusiveAccess` may be admitted in the gap
    /// between two turns of a multi-turn read, and must not be admitted inside one. Both
    /// halves are asserted below — no interleaving, and all three turns still ran.
    ///
    /// **Mutation:** in `SMCFanControlPlane.reconnect()`, drop the
    /// `scheduler.withExclusiveAccess { … }` wrapper and call `close()` / `open()` directly.
    /// Run: red here on the interleaving assertion.
    @Test("A reconnect never lands inside a read that is in flight")
    func aReconnectNeverLandsInsideAReadInFlight() async throws {
        let smc = FakeSMC(holdingReads: true)
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))

        let read = observing {
            try await scheduler.read(
                keys: Self.keys(SMCReadScheduler.maxKeysPerTurn * 3), at: .snapshot)
        }
        await yieldUntil("the first turn to reach the SMC") { await smc.turnsBegun == 1 }

        let reconnect = observing { try await plane.reconnect() }
        await yieldUntil("the reconnect to queue for a turn, or to barge in without one") {
            let queued = await scheduler.queuedTurns(at: .supervisor)
            let closes = await smc.closeCount
            return queued == 1 || closes > 0
        }

        await smc.releaseEveryRead()
        _ = try await finished("the three-turn read", read)
        _ = try await finished("the reconnect", reconnect)

        let events = await smc.events
        #expect(
            await smc.recycledInsideARead == false,
            """
            the connection was closed or reopened while a read was in flight — the recycle \
            invalidated a handle mid-request, which is the fault it exists to recover from, \
            produced by the recovery. Log: \(events)
            """)
        #expect(await smc.turnsBegun == 3, "the read did not finish all three of its turns")
        #expect(await smc.closeCount == 1, "the reconnect did not close exactly once")
    }

    // MARK: - Recovery

    /// A stale handle answers nothing until it is recycled, and then it answers.
    ///
    /// [#68](https://github.com/blamechris/Aeolus/issues/68)'s shape exactly: the connection
    /// is open, the machine is fine, and every read fails. `FakeSMC` models
    /// `SMCConnection.open()`'s **idempotence**, which is what makes both halves of the
    /// recycle load-bearing — an `open()` against a handle that is already open returns
    /// having done nothing, so it is the `close()` that makes the reopen a reopen.
    ///
    /// **Mutation A:** delete `try await connection.open()` from
    /// `SMCFanControlPlane.reconnect()`. Run: red — the follow-up read fails against a
    /// closed connection.
    /// **Mutation B:** delete `await connection.close()` instead. Run: red — the `open()` is
    /// a no-op against a handle that is already open, so the stale one survives and the
    /// follow-up read still fails.
    @Test("A read that fails against a stale handle succeeds after the reconnect")
    func aReconnectRestoresReadsThroughAStaleHandle() async throws {
        let smc = FakeSMC(handleIsStale: true)
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))

        await #expect(throws: (any Error).self) {
            try await scheduler.read(keys: ["TC0P"], at: .snapshot)
        }

        try await plane.reconnect()

        let served = try await scheduler.read(keys: ["TC0P"], at: .snapshot)
        #expect(served.map(\.key) == ["TC0P"])
    }

    /// A reopen that fails is reported as a read failure naming the reconnect, not as a
    /// silent return.
    ///
    /// The case it replaces — `.reconnectNotBuilt` — meant *"no attempt was possible"*, and
    /// is gone. What is left is the one an operator sees now: the attempt was made and the
    /// machine did not come back. `ReclamationWatchdog` treats it exactly as it treats a
    /// reconnect that returned cleanly, which is the property `SAFETY.md` § 5 rests on.
    @Test("A reopen that fails throws, carrying the reason")
    func aFailedReopenIsReported() async throws {
        let smc = FakeSMC(reopenFails: true)
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await plane.reconnect()
        }

        guard case .readFailed(let detail)? = error else {
            Issue.record("a failed reopen produced \(describe(error))")
            return
        }
        #expect(detail.contains("reconnect"))
    }

    /// The turn is given back when the reopen throws, and that is not a free assertion.
    ///
    /// `withExclusiveAccess` releases its turn in a `defer`, exactly as `read(keys:at:)`
    /// does, and for the same reason: a turn taken and not given back wedges the helper's
    /// only SMC reader for the life of the process, silently, because waiting at the gate is
    /// deliberately not cancellable. The reopen throwing is the one path where the release
    /// runs on the error branch.
    ///
    /// **Mutation:** in `SMCReadScheduler.withExclusiveAccess(_:)`, replace
    /// `defer { endTurn(at: .supervisor) }` with a call after `body()`. Run: red here — the
    /// follow-up read never returns.
    @Test("A reconnect whose reopen throws still gives the connection back")
    func aFailedReconnectReleasesItsTurn() async throws {
        let smc = FakeSMC(reopenFails: true)
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))

        await #expect(throws: (any Error).self) { try await plane.reconnect() }

        // Asserted by taking a turn, not by inspecting a flag: a flag says what the scheduler
        // believes and a served read says what a caller gets. Started observably, because
        // under the mutation the read never returns at all and a bare `await` would hang the
        // suite for the whole time limit instead of failing in milliseconds.
        //
        // `try?`, and the assertion is on the SMC rather than on the outcome: a reopen that
        // threw leaves the handle closed — which is what `SMCConnection.open()` does on
        // failure — so this read is *expected* to fail. What is being asserted is that it
        // reached the SMC at all, which it can only do from a turn it was granted.
        let follow = observing { try? await scheduler.read(keys: ["TPD1"], at: .supervisor) }
        _ = try await finished("the read issued after a failed reconnect", follow)
        #expect(
            await smc.turnsBegun == 1,
            "the read never reached the SMC, so the failed reconnect kept its turn")
    }
}

// MARK: - The fake SMC

/// One SMC: an ordered event log, a handle that can be open or closed, and a staleness bit.
///
/// The single state behind `FakeSMCProvider` and `FakeSMCConnection`, so that closing the
/// connection really is the thing that stops the reads — which is what makes
/// `ConnectionRecoveryTests`' assertions about the *machine* rather than about a mock's call
/// counts.
///
/// ## It models `SMCConnection`'s idempotent `open()` on purpose
///
/// `SMCConnection.open()` is `guard connection == 0 else { return }`, and
/// `SMCSensorProvider.read(keys:)` calls it before every subset read — which is why a stale
/// handle is not healed by opening it again, and why the `close()` in
/// `SMCFanControlPlane.reconnect()` is load-bearing rather than tidy. A fake whose `open()`
/// healed unconditionally would agree with an implementation that had dropped the `close()`.
actor FakeSMC {

    /// What happened, in order. The whole point of the type.
    enum Event: Sendable, Equatable {
        case readBegan(Int)
        case readEnded(Int)
        case closed
        case opened
    }

    private(set) var events: [Event] = []
    private(set) var turnsBegun = 0
    private(set) var closeCount = 0
    private(set) var openCount = 0

    /// Whether the handle answers reads. A handle can be open and stale at once — that is
    /// #68 — and only a genuine reopen clears it.
    private var isStale: Bool
    private var isOpen = true
    private let reopenFails: Bool

    private var isHeld: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(handleIsStale: Bool = false, holdingReads: Bool = false, reopenFails: Bool = false) {
        self.isStale = handleIsStale
        self.isHeld = holdingReads
        self.reopenFails = reopenFails
    }

    /// Whether any close or open landed between a read beginning and that read ending.
    ///
    /// The assertion `aReconnectNeverLandsInsideAReadInFlight` is built on, computed here so
    /// the test reads as the property rather than as a scan.
    var recycledInsideARead: Bool {
        var inFlight = 0
        for event in events {
            switch event {
            case .readBegan: inFlight += 1
            case .readEnded: inFlight -= 1
            case .closed, .opened: if inFlight > 0 { return true }
            }
        }
        return false
    }

    // MARK: - The connection's half

    func close() {
        closeCount += 1
        events.append(.closed)
        isOpen = false
    }

    func open() throws {
        openCount += 1
        events.append(.opened)
        if reopenFails {
            throw FakeProviderError(description: "IOServiceOpen refused")
        }
        // Idempotent, exactly like `SMCConnection.open()`: an open handle is left alone, and
        // therefore a stale one stays stale. See this type's documentation.
        guard !isOpen else { return }
        isOpen = true
        isStale = false
    }

    // MARK: - The provider's half

    /// One turn's worth of reading, recorded either side of whatever suspension the test
    /// asked for.
    ///
    /// The suspension is inside the actor, so a `close()` arriving during it is admitted by
    /// reentrancy — which is precisely what lets the interleaving be observed rather than
    /// merely reasoned about.
    func read() async throws {
        turnsBegun += 1
        let turn = turnsBegun
        events.append(.readBegan(turn))
        if isHeld {
            await withCheckedContinuation { waiters.append($0) }
        }
        events.append(.readEnded(turn))

        guard isOpen else {
            throw FakeProviderError(description: "the connection is closed")
        }
        guard !isStale else {
            throw FakeProviderError(description: "the io_connect_t is stale")
        }
    }

    /// Stops holding reads and lets every parked one finish.
    func releaseEveryRead() {
        isHeld = false
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }
}

/// The reading half of a `FakeSMC`, as a `SensorProvider`.
struct FakeSMCProvider: SensorProvider {

    let smc: FakeSMC

    var identifier: String { "fake-smc" }

    var isAvailable: Bool {
        get async { true }
    }

    func readAll() async throws -> [SensorReading] { [] }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        try await smc.read()
        return keys.map { SensorReadOutcome(key: $0, result: .reading($0, 1)) }
    }
}

/// The lifecycle half of the same `FakeSMC`, as the two verbs `reconnect()` needs.
struct FakeSMCConnection: SMCConnectionRecycling {

    let smc: FakeSMC

    func close() async { await smc.close() }

    func open() async throws { try await smc.open() }
}
