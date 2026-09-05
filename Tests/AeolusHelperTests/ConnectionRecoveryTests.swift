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

    /// Whether a request produced no reading at all — the shape a stale handle answers in,
    /// asserted rather than a throw. See `FakeSMC`.
    private static func everyKeyFailed(_ outcomes: [SensorReadOutcome]) -> Bool {
        !outcomes.isEmpty
            && outcomes.allSatisfy {
                if case .failure = $0.result { return true }
                return false
            }
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
    ///
    /// The first read **returns**, and that is the ruling-D21 correction rather than a
    /// weakening of the assertion: a stale handle answers per key, so what the caller receives
    /// is a full-length array of failures, not a throw. See `FakeSMC`.
    @Test("A read that fails against a stale handle succeeds after the reconnect")
    func aReconnectRestoresReadsThroughAStaleHandle() async throws {
        let smc = FakeSMC(handleIsStale: true)
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))

        let blind = try await scheduler.read(keys: ["TC0P"], at: .snapshot)
        #expect(Self.everyKeyFailed(blind), "a stale handle answered something")

        try await plane.reconnect()

        let served = try await scheduler.read(keys: ["TC0P"], at: .snapshot)
        #expect(served.map(\.key) == ["TC0P"])
        #expect(!Self.everyKeyFailed(served), "the reconnect did not restore reading")
    }

    /// **#68 end to end, on the contract production actually has.**
    ///
    /// The one test the adversarial review asked for by name, and the reason ruling D21
    /// exists: a provider that fails every key **without throwing** must still reach a
    /// reconnect. Nothing else in the repository covers the whole chain — `ConnectionHealth`'s
    /// suite drives the observer directly and `SchedulerObservingTests` drives the emission —
    /// and it was precisely in the joint between them that the defect lived. Every mechanism
    /// was present, tested, and wired; the event that drives it was unreachable on the one
    /// machine state it was written for.
    ///
    /// So this wires the production graph over one `FakeSMC` — provider, scheduler,
    /// `ConnectionHealth` as its observer, and the plane as the recovery seam — and asserts
    /// the fans-out end: the handle really was recycled, and reads really do work afterwards.
    ///
    /// **Mutation:** in `SMCReadScheduler.read(keys:at:)`, replace the
    /// `wholeReadEvent(for:at:)` report with `.wholeReadSucceeded` whenever the provider did
    /// not throw — the behaviour at the PR's first head. Run: red, on the close count,
    /// because no failure is ever counted.
    /// **Mutation (false-positive guard):** make `wholeReadEvent(for:at:)` count
    /// `.unknownKey` failures too. Run: red on `absentKeysAreNeitherAFailureNorASuccess` in
    /// `SchedulerObservingTests`, which is the other side of the rule.
    @Test("A handle that fails every key without throwing still reaches a reconnect")
    func theStaleHandleCaseReachesAReconnect() async throws {
        let smc = FakeSMC(handleIsStale: true)
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc), observer: health)
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))
        await health.start(recovering: plane)

        // Exactly the threshold, so this cannot pass by driving comfortably more than the
        // policy asks for — `ConnectionHealthTests` makes the same argument about literals.
        for _ in 0..<3 {
            _ = try await scheduler.read(keys: ["TC0P"], at: .snapshot)
        }
        await yieldUntil("the three whole-read failures to be handled") {
            await health.observedOutcomes == 3
        }

        #expect(
            await smc.closeCount == 1,
            """
            three whole reads that produced no value fired no reconnect. A stale io_connect_t \
            fails per key and throws nothing, so a scheduler that decides blindness from a \
            throw never reports one — which is #68 surviving every mechanism built to close it.
            """)
        let served = try await scheduler.read(keys: ["TC0P"], at: .snapshot)
        #expect(!Self.everyKeyFailed(served), "the rebuilt handle still answers nothing")
        await health.stop()
    }

    /// Whether every outcome is `.unknownKey` — the answer a key outside `knownKeys` gets.
    private static func everyKeyAbsent(_ outcomes: [SensorReadOutcome]) -> Bool {
        !outcomes.isEmpty
            && outcomes.allSatisfy {
                if case .failure(.unknownKey) = $0.result { return true }
                return false
            }
    }

    /// **Ruling D25's machine: a fanless Mac with a stale handle.**
    ///
    /// `SMCFanEnumeration.enumerate` reads `FNum` as a request of its own on every snapshot,
    /// and on a Mac with no fans the key is outside `knownKeys`, so `SMCConnection` answers
    /// it `.keyNotFound` at zero round trips whatever state the handle is in. When the handle
    /// goes stale, the scheduler therefore sees the fan-count read alternate with genuine
    /// failures: absent-only, failed, absent-only, failed. At `eb91026` an absent-only
    /// request was reported `.wholeReadSucceeded` and **reset the run**, so
    /// `consecutiveFailures` peaked at one for ever and the reconnect never fired — #68 on a
    /// fanless Air, surviving every mechanism built to close it. The re-review measured it:
    /// twenty whole reads, ten genuine failures, zero attempts.
    ///
    /// The production graph over one `FakeSMC`, as `theStaleHandleCaseReachesAReconnect`,
    /// driven **exactly** to the threshold — three genuine failures interleaved with three
    /// absent-only reads — with the attempt count checked one read short, so that a rule
    /// which *counted* absent-only reads (reaching three on the third read, two of which
    /// touched no hardware) is red here as well as on
    /// `aRunOfAbsentOnlyReadsReconnectsNothing`.
    ///
    /// **Mutation A:** in `SMCReadScheduler.wholeReadEvent(for:at:)`, return
    /// `.wholeReadSucceeded` where it returns `.wholeReadAbsentOnly` — `eb91026`'s rule.
    /// Run: red — the run never reaches three.
    /// **Mutation B:** in `ConnectionHealth.handle(_:recovering:)`, treat
    /// `.wholeReadAbsentOnly` as `.wholeReadSucceeded`. Run: red on the same line.
    /// **Mutation C:** treat it as `.wholeReadFailed` instead. Run: red on the one-short
    /// check.
    @Test("A fanless Mac's absent fan-count read does not reset the run a stale handle builds")
    func theFanlessMacCaseReachesAReconnect() async throws {
        let smc = FakeSMC(handleIsStale: true, absentKeys: ["FNum"])
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc), observer: health)
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))
        await health.start(recovering: plane)

        // Absent-only, failed, absent-only, failed, absent-only — two genuine failures on
        // either path, and nothing may have fired yet.
        for _ in 0..<2 {
            let fanCount = try await scheduler.read(keys: ["FNum"], at: .snapshot)
            #expect(Self.everyKeyAbsent(fanCount), "the fanless Mac answered a fan count")
            let blind = try await scheduler.read(keys: ["TC0P"], at: .supervisor)
            #expect(Self.everyKeyFailed(blind), "a stale handle answered something")
        }
        _ = try await scheduler.read(keys: ["FNum"], at: .snapshot)
        await yieldUntil("the first five outcomes to be handled") {
            await health.observedOutcomes == 5
        }
        #expect(
            await health.reconnectAttempts == 0,
            """
            a reconnect fired after two genuine failures. The absent-only reads between them \
            touched no hardware and were counted as the handle failing — D21's false-positive \
            guard, which on a healthy fanless Mac is a rebuild every third snapshot.
            """)

        // The third genuine failure, and the whole run is three.
        _ = try await scheduler.read(keys: ["TC0P"], at: .supervisor)
        await yieldUntil("the sixth outcome to be handled") {
            await health.observedOutcomes == 6
        }

        #expect(
            await health.reconnectAttempts == 1,
            """
            three genuine whole-read failures, interleaved with a fanless Mac's absent-only \
            fan-count reads, fired no reconnect. The absent-only reads touched no hardware \
            and reset the run anyway, so it peaked at one for ever — #68 on a fanless Air, \
            surviving every mechanism built to close it.
            """)
        #expect(await smc.closeCount == 1, "the reconnect did not recycle the handle")

        let served = try await scheduler.read(keys: ["TC0P"], at: .supervisor)
        #expect(!Self.everyKeyFailed(served), "the rebuilt handle still answers nothing")
        // And the Mac still has no fans, because that was never about the handle.
        let fanCount = try await scheduler.read(keys: ["FNum"], at: .snapshot)
        #expect(Self.everyKeyAbsent(fanCount), "the rebuild invented a fan-count key")
        await health.stop()
    }

    /// A run made only of absent-only reads reconnects nothing, however long it is.
    ///
    /// The other half of D25 — D21's false-positive guard, asserted through the production
    /// graph rather than at the emission. A fanless Mac whose handle is *fine* produces one
    /// of these on every snapshot; counting them would recycle a working connection every
    /// third snapshot, on the machines least able to afford it. Six rather than three, so
    /// that a rule which counted them cannot pass by firing late.
    ///
    /// **Mutation:** in `ConnectionHealth.handle(_:recovering:)`, treat `.wholeReadAbsentOnly`
    /// as `.wholeReadFailed`. Run: red — one attempt, one close.
    /// (`SchedulerObservingTests.absentKeysAreNeitherAFailureNorASuccess` kills the same
    /// mistake made on the scheduler's side of the seam.)
    @Test("A run of absent-only reads reconnects nothing")
    func aRunOfAbsentOnlyReadsReconnectsNothing() async throws {
        let smc = FakeSMC(absentKeys: ["FNum"])
        let health = ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc), observer: health)
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))
        await health.start(recovering: plane)

        for _ in 0..<6 {
            let fanCount = try await scheduler.read(keys: ["FNum"], at: .snapshot)
            #expect(Self.everyKeyAbsent(fanCount), "the fanless Mac answered a fan count")
        }
        await yieldUntil("the six absent-only outcomes to be handled") {
            await health.observedOutcomes == 6
        }

        #expect(
            await health.reconnectAttempts == 0,
            """
            six reads that touched no hardware — a fanless Mac asking for a fan count — were \
            counted as the connection failing, and a working handle was rebuilt over them.
            """)
        #expect(await smc.closeCount == 0, "a working handle was recycled")
        await health.stop()
    }

    // MARK: - Discovery

    /// **Ruling D22, first direction: a recycle requested during a walk lands after it.**
    ///
    /// `readAll()` takes no turn — holding one would be a 2.2 s, 5.9 s cold, barrier against
    /// the safety cycle, which is worse than the contention it would arbitrate — so for one
    /// release of `SMCReadScheduler` the exclusive turn did not exclude the longest occupation
    /// of the connection in the process. Closing the handle mid-walk does not merely fail the
    /// walk: `SMCSensorProvider.readAll()` skips every key that fails, and
    /// `ReadOnlyFanAuthority` caches what comes back for the life of the daemon. The visible
    /// symptom is a Mac permanently missing sensors, with nothing logged.
    ///
    /// The wait is on a disjunction for `aReconnectNeverLandsInsideAReadInFlight`'s reason:
    /// under the mutation the recycle never parks, so waiting on the parked count alone would
    /// time out and report a wait instead of the interleaving.
    ///
    /// **Mutation:** delete the `while discoveryWalksInFlight > 0` wait from
    /// `withExclusiveAccess(_:)`. Run: red — the close lands between `.walkBegan` and
    /// `.walkEnded`.
    @Test("A reconnect waits for a discovery walk that is already in flight")
    func aReconnectWaitsForADiscoveryWalkInFlight() async throws {
        let smc = FakeSMC(holdingDiscovery: true)
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))

        let walk = observing { _ = try await scheduler.readAll() }
        await yieldUntil("the discovery walk to reach the SMC") { await smc.walksBegun == 1 }

        let reconnect = observing { try await plane.reconnect() }
        await yieldUntil("the reconnect to park behind the walk, or to barge into it") {
            let parked = await scheduler.recyclesWaitingForDiscovery
            let closes = await smc.closeCount
            return parked == 1 || closes > 0
        }

        await smc.releaseTheWalk()
        _ = try await finished("the discovery walk", walk)
        _ = try await finished("the reconnect", reconnect)

        let events = await smc.events
        #expect(
            await smc.recycledInsideAWalk == false,
            """
            the connection was recycled in the middle of a discovery walk. The walk skips \
            every key that fails and the authority caches what it returns for the life of \
            the daemon, so this is a permanently short sensor set. Log: \(events)
            """)
        #expect(await smc.closeCount == 1, "the reconnect did not close exactly once")
        #expect(await smc.walksBegun == 1, "the walk did not run")
    }

    /// **Ruling D22, second direction: a walk starting inside a recycle waits for it.**
    ///
    /// The mirror of the test above, and it is not redundant with it. One wait keeps a recycle
    /// out of a walk that started first; the other keeps a walk out of a recycle that started
    /// first — and only the second is reachable at bring-up, where `ReadOnlyFanAuthority`'s
    /// first discovery and a reconnect fired by a failing boot can arrive in either order.
    ///
    /// The recycle is held **inside** its exclusive body, at the point where the handle is
    /// closed and not yet reopened, which is the only vantage point from which a walk starting
    /// during it is a fact rather than a race.
    ///
    /// **The assertion is `walkBeganInsideARecycle`, and the first version of this test used
    /// `recycledInsideAWalk` instead and stayed green under its own mutation.** A walk that
    /// barges into a recycle begins *and ends* while the handle is shut, so no close or open
    /// falls inside it — the harm is that the walk ran against nothing, not that it was
    /// interrupted, and only a scan of the recycle's span can see that. It is the whole reason
    /// the mutation below is quoted from a run rather than reasoned about.
    ///
    /// **Mutation:** delete the `while exclusiveClaims > 0` wait from
    /// `SMCReadScheduler.readAll()`. Run: red — the walk begins against a closed handle.
    @Test("A discovery walk started during a recycle waits for the recycle")
    func aDiscoveryWalkWaitsForARecycle() async throws {
        let smc = FakeSMC(holdingRecycle: true)
        let scheduler = SMCReadScheduler(provider: FakeSMCProvider(smc: smc))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: FakeSMCConnection(smc: smc))

        let reconnect = observing { try await plane.reconnect() }
        await yieldUntil("the recycle to be holding the connection closed") {
            await smc.closeCount == 1
        }

        let walk = observing { _ = try await scheduler.readAll() }
        await yieldUntil("the walk to park behind the recycle, or to start inside it") {
            let parked = await scheduler.walksWaitingForARecycle
            let walks = await smc.walksBegun
            return parked == 1 || walks > 0
        }

        await smc.releaseTheRecycle()
        _ = try await finished("the reconnect", reconnect)
        _ = try await finished("the discovery walk", walk)

        let events = await smc.events
        #expect(
            await smc.walkBeganInsideARecycle == false,
            """
            a discovery walk began while the recycle held the connection closed. It walks the \
            index table against a shut handle, skips every key that fails, and the authority \
            caches the short result for the life of the daemon. Log: \(events)
            """)
        #expect(await smc.recycledInsideAWalk == false, "the reopen landed inside the walk")
        #expect(await smc.walksBegun == 1, "the walk never ran")
        #expect(await smc.openCount == 1, "the reconnect did not reopen exactly once")
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
///
/// ## And it fails reads the way production fails them: **per key, without throwing**
///
/// This is the correction ruling D21 turned on. The first version of this fake threw from
/// `read()` when the handle was stale, and nothing in the suite disagreed — but
/// `SMCSensorProvider.read(keys:)` throws from exactly one place, `connection.open()`, and a
/// stale-but-non-zero handle returns from that `guard` having done nothing. What follows is
/// `SMCConnection.read(keys:)`, which is not a throwing function: it reports every key as a
/// per-key `.readFailed` and returns normally. A fake that threw therefore agreed with a
/// scheduler that decided blindness from a throw, and both were wrong about the one machine
/// state #68 is.
actor FakeSMC {

    /// What happened, in order. The whole point of the type.
    enum Event: Sendable, Equatable {
        case readBegan(Int)
        case readEnded(Int)
        case walkBegan
        case walkEnded
        case closed
        case opened
    }

    private(set) var events: [Event] = []
    private(set) var turnsBegun = 0
    private(set) var walksBegun = 0
    private(set) var closeCount = 0
    private(set) var openCount = 0

    /// Whether the handle answers reads. A handle can be open and stale at once — that is
    /// #68 — and only a genuine reopen clears it.
    private var isStale: Bool
    private var isOpen = true
    private let reopenFails: Bool

    /// Keys this machine's firmware does not expose — outside `knownKeys`, in
    /// `SMCConnection`'s terms.
    ///
    /// Answered `.unknownKey` **before the handle is consulted**, because that is the order
    /// `SMCConnection.readOutcome(for:)` answers in: a key outside `knownKeys` is
    /// `.keyNotFound` at zero round trips, whatever state the `io_connect_t` is in. A fanless
    /// Mac has no `FNum`, and `SMCFanEnumeration` asks for it on every snapshot — so a stale
    /// handle on such a Mac produces an absent-only request between every pair of genuine
    /// failures, which is the shape ruling D25 exists for.
    private let absentKeys: Set<String>

    private var isHeld: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var isWalkHeld: Bool
    private var walkWaiters: [CheckedContinuation<Void, Never>] = []

    private var isRecycleHeld: Bool
    private var recycleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        handleIsStale: Bool = false,
        holdingReads: Bool = false,
        holdingDiscovery: Bool = false,
        holdingRecycle: Bool = false,
        reopenFails: Bool = false,
        absentKeys: Set<String> = []
    ) {
        self.isStale = handleIsStale
        self.isHeld = holdingReads
        self.isWalkHeld = holdingDiscovery
        self.isRecycleHeld = holdingRecycle
        self.reopenFails = reopenFails
        self.absentKeys = absentKeys
    }

    /// Whether any close or open landed between a read beginning and that read ending.
    ///
    /// The assertion `aReconnectNeverLandsInsideAReadInFlight` is built on, computed here so
    /// the test reads as the property rather than as a scan.
    var recycledInsideARead: Bool {
        recycledInsideSomethingBoundedBy(
            begins: { if case .readBegan = $0 { true } else { false } },
            ends: { if case .readEnded = $0 { true } else { false } })
    }

    /// Whether any close or open landed between a discovery walk beginning and that walk
    /// ending — ruling D22's property, and the harm is sharper than a failed read: a walk
    /// that loses keys returns a **short** set, which `ReadOnlyFanAuthority` then caches for
    /// the life of the daemon with nothing logged.
    var recycledInsideAWalk: Bool {
        recycledInsideSomethingBoundedBy(
            begins: { $0 == .walkBegan }, ends: { $0 == .walkEnded })
    }

    /// Whether a discovery walk ever **began inside a recycle** — between a `close()` and the
    /// `open()` that ended it, with the handle shut.
    ///
    /// **It is not the mirror image of `recycledInsideAWalk`, and assuming it was is how the
    /// test for this direction came to pass on the mutation it names.** The two hazards leave
    /// different marks in the log. A recycle barging into a running walk puts a `.closed`
    /// *inside* a walk span, which the scan below sees. A walk barging into a running recycle
    /// puts a `.walkBegan` inside a *recycle* span — and the walk then begins and ends before
    /// the reopen, so no close or open is inside it and `recycledInsideAWalk` is `false`.
    /// Deleting the wait in `SMCReadScheduler.readAll()` left the whole suite green until this
    /// property existed.
    var walkBeganInsideARecycle: Bool {
        var isRecycling = false
        for event in events {
            switch event {
            case .closed: isRecycling = true
            case .opened: isRecycling = false
            case .walkBegan: if isRecycling { return true }
            case .walkEnded, .readBegan, .readEnded: break
            }
        }
        return false
    }

    /// The scan both `recycledInside…` properties are: a depth counter over the log, answering
    /// whether a `.closed` or an `.opened` ever fell inside a span.
    private func recycledInsideSomethingBoundedBy(
        begins: (Event) -> Bool, ends: (Event) -> Bool
    ) -> Bool {
        var inFlight = 0
        for event in events {
            if begins(event) {
                inFlight += 1
            } else if ends(event) {
                inFlight -= 1
            } else if inFlight > 0, event == .closed || event == .opened {
                return true
            }
        }
        return false
    }

    // MARK: - The connection's half

    /// `async` so a test can hold the recycle *inside* its exclusive body, which is the only
    /// vantage point from which "a walk started while the recycle held the connection" is
    /// observable rather than a race.
    func close() async {
        closeCount += 1
        events.append(.closed)
        isOpen = false
        if isRecycleHeld {
            await withCheckedContinuation { recycleWaiters.append($0) }
        }
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

    /// Lets a held recycle finish its body.
    func releaseTheRecycle() {
        isRecycleHeld = false
        let parked = recycleWaiters
        recycleWaiters.removeAll()
        for waiter in parked { waiter.resume() }
    }

    // MARK: - The provider's half

    /// One turn's worth of reading, recorded either side of whatever suspension the test
    /// asked for, and answered **per key**.
    ///
    /// The suspension is inside the actor, so a `close()` arriving during it is admitted by
    /// reentrancy — which is precisely what lets the interleaving be observed rather than
    /// merely reasoned about.
    ///
    /// A closed or stale handle fails every key it is asked to touch and throws nothing. See
    /// this type's documentation for why that, and not a throw, is what production does —
    /// and `absentKeys` for the keys it is never asked to touch.
    func read(keys: [String]) async -> [SensorReadOutcome] {
        turnsBegun += 1
        let turn = turnsBegun
        events.append(.readBegan(turn))
        if isHeld {
            await withCheckedContinuation { waiters.append($0) }
        }
        events.append(.readEnded(turn))

        let handleFailure: String?
        if !isOpen {
            handleFailure = "the connection is closed"
        } else if isStale {
            handleFailure = "the io_connect_t is stale"
        } else {
            handleFailure = nil
        }
        return keys.map { key in
            // Absent first, handle second: `SMCConnection.readOutcome(for:)`'s order, and the
            // whole reason an absent-only request says nothing about the handle.
            if absentKeys.contains(key) {
                return SensorReadOutcome(key: key, result: .failure(.unknownKey(key)))
            }
            if let handleFailure {
                return SensorReadOutcome(
                    key: key, result: .failure(.readFailed(reason: handleFailure)))
            }
            return SensorReadOutcome(key: key, result: .reading(key, 1))
        }
    }

    /// The discovery walk, recorded either side of whatever suspension the test asked for.
    ///
    /// It takes no turn — `SMCReadScheduler.readAll()` does not grant one — so the only thing
    /// keeping a recycle out of it is ruling D22's mutual exclusion, which is exactly what
    /// this lets a test observe.
    func walk() async {
        walksBegun += 1
        events.append(.walkBegan)
        if isWalkHeld {
            await withCheckedContinuation { walkWaiters.append($0) }
        }
        events.append(.walkEnded)
    }

    /// Stops holding reads and lets every parked one finish.
    func releaseEveryRead() {
        isHeld = false
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }

    /// Stops holding the discovery walk.
    func releaseTheWalk() {
        isWalkHeld = false
        let parked = walkWaiters
        walkWaiters.removeAll()
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

    func readAll() async throws -> [SensorReading] {
        await smc.walk()
        return []
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        await smc.read(keys: keys)
    }
}

/// The lifecycle half of the same `FakeSMC`, as the two verbs `reconnect()` needs.
struct FakeSMCConnection: SMCConnectionRecycling {

    let smc: FakeSMC

    func close() async { await smc.close() }

    func open() async throws { try await smc.open() }
}
