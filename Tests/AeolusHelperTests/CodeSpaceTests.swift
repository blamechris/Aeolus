import Testing
import os

/// `CodeSpace.forEachRun` gives the pool back between runs (#570).
///
/// Nothing else can see it do so: every sweep passes whether or not it yields, and a pool wide
/// enough to run a sibling beside it makes the yield unnecessary. This test takes the width out
/// of the question. A sweep and a sibling both prefer one `OneLaneTaskExecutor`, a serial queue,
/// so the sibling can run only when the sweep's job ends, and a sweep that never yields has one
/// job. The body, called between runs, asks whether the sibling has run.
///
/// **This holds the `AeolusHelperTests` copy of `CodeSpace` only.** The other three copies, in
/// `AeolusUITests`, `IntegrationTests` and `fanctlTests`, are held to the same yield by being
/// byte-identical to this one, by convention, and nothing tests that.
///
/// **Mutation:** in `CodeSpace.forEachRun`, delete `await Task.yield()`. Run: red on
/// `ranBetweenRuns`, with `CodeSpace`'s own `visited == scalarCount` still green.
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
}
