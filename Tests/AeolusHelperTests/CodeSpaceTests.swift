import Testing
import os

/// `CodeSpace.forEachRun` gives the pool back between runs (#570).
///
/// Nothing else can see it do so: every sweep passes whether or not it yields, and a pool wide
/// enough to run a sibling beside it makes the yield unnecessary. These tests take the width out
/// of the question. A sweep and a sibling both prefer one `OneLaneTaskExecutor`, a serial queue,
/// so the sibling can run only when the sweep's job ends, and a sweep that never yields has one
/// job. The body, called between runs, asks whether the sibling has run.
///
/// **Two tests, two claims.** `aSiblingRunsBetweenRuns` holds that the sweep yields *at all*. It
/// stays green when the yield is cut to one, after the first run, so it cannot hold "between
/// runs" (#574). `aTickerGetsATurnBetweenRuns` holds that: a sibling that re-yields after every
/// tick is let in once per run, so its ticks are counted against the runs.
///
/// **This holds the `AeolusHelperTests` copy of `CodeSpace` only.** The other three copies, in
/// `AeolusUITests`, `IntegrationTests` and `fanctlTests`, are held to the same yield by being
/// byte-identical to this one, by convention, and nothing tests that.
///
/// **Mutation:** in `CodeSpace.forEachRun`, delete `await Task.yield()`. Run: red on
/// `ranBetweenRuns` and on `tickCount >= runCount / 2` (0 ticks across 272 runs), with
/// `CodeSpace`'s own `visited == scalarCount` still green.
/// **Mutation (one yield):** replace it with `if start == runLength { await Task.yield() }`.
/// Run: red on `tickCount >= runCount / 2` alone (1 tick across 272 runs); `ranBetweenRuns`
/// stays green, which is why the second test exists.
/// **Mutation (periodic yield):** replace it with `if (start / runLength) % 16 == 0 { await
/// Task.yield() }`. Run: red on `tickCount >= runCount / 2` alone (17 ticks across 272 runs);
/// `ranBetweenRuns` stays green.
@Suite("CodeSpace gives the pool back between runs")
struct CodeSpaceTests {

    @Test("A job queued behind a sweep runs before the sweep is over")
    func aSiblingRunsBetweenRuns() async {
        guard #available(macOS 15.0, *) else {
            Issue.record("Task executor preference needs macOS 15; this test watches nothing here")
            return
        }
        let lane = OneLaneTaskExecutor()
        // Locks rather than actors: the sweep's body is synchronous and cannot `await` one.
        let siblingRan = OSAllocatedUnfairLock(initialState: false)
        let ranBetweenRuns = OSAllocatedUnfairLock(initialState: false)
        await withTaskExecutorPreference(lane) {
            let sibling = Task(executorPreference: lane) { siblingRan.withLock { $0 = true } }
            await CodeSpace.forEachRun { _ in
                if siblingRan.withLock({ $0 }) { ranBetweenRuns.withLock { $0 = true } }
            }
            await sibling.value
        }
        #expect(
            ranBetweenRuns.withLock { $0 }, "the sibling did not run until the sweep was over")
    }

    @Test("A ticker queued behind a sweep gets a turn between the runs, not just one")
    func aTickerGetsATurnBetweenRuns() async {
        guard #available(macOS 15.0, *) else {
            Issue.record("Task executor preference needs macOS 15; this test watches nothing here")
            return
        }
        let lane = OneLaneTaskExecutor()
        let done = OSAllocatedUnfairLock(initialState: false)
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        let runs = OSAllocatedUnfairLock(initialState: 0)
        await withTaskExecutorPreference(lane) {
            // Queued behind the sweep on the one lane, and back behind it after every tick, so
            // it ticks once for each time the sweep lets go of the lane and not otherwise.
            let ticker = Task(executorPreference: lane) {
                while !done.withLock({ $0 }) {
                    ticks.withLock { $0 += 1 }
                    await Task.yield()
                }
            }
            await CodeSpace.forEachRun { _ in runs.withLock { $0 += 1 } }
            done.withLock { $0 = true }
            await ticker.value
        }
        let tickCount = ticks.withLock { $0 }
        let runCount = runs.withLock { $0 }
        // A sweep that yields between every run is let past by the ticker about once per run. One
        // yield, or one in sixteen, leaves it well under half; none leaves it at most one tick.
        #expect(runCount > 1, "the sweep handed out \(runCount) runs: nothing to yield between")
        #expect(
            tickCount >= runCount / 2,
            "the ticker ticked \(tickCount) times across \(runCount) runs: the sweep held the lane")
    }
}
