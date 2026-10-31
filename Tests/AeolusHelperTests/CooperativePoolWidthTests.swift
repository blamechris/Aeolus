import Foundation
import Testing
import os

/// A run that says it is on a cooperative pool of one really is (#593).
///
/// `.github/workflows/ci.yml` runs the whole suite with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
/// so that a test which holds a pool thread on a release only the pool can deliver wedges the
/// run instead of passing on the second and third thread a hosted runner has. That step is green
/// whenever nothing wedges, and nothing wedges on a pool of three either. If a toolchain stopped
/// honouring the variable, the step would stay green and hold nothing.
///
/// This is the step's positive control. It is off unless the step also sets
/// `AEOLUS_EXPECT_POOL_OF_ONE=1`, which says "this run claims a pool of one". The variable is a
/// separate one, not `LIBDISPATCH_COOPERATIVE_POOL_STRICT` itself, so that a run which unsets
/// libdispatch's variable and keeps this one can be made to fail, which is the mutation below.
///
/// The suite is skipped, not failed, when this variable is missing, and a skip exits 0. So the
/// CI step also requires this test's `passed` line in its output, by the display name on the
/// `@Test` below; renaming that name means renaming it in `ci.yml`'s check too.
///
/// The test starts several tasks that each hold their thread for a fixed time and counts how
/// many are inside that time at once. A pool of one cannot make that more than 1. A pool of two
/// or more makes it more than 1 as soon as two of the tasks are scheduled together, which six
/// tasks that hold their thread for 100 ms do in practice; it is a probe, not a proof of width,
/// so the test can pass on a wider pool only by never overlapping two tasks.
///
/// The sleeps hold the test's pool threads for 100 ms each and give them back on their own: a
/// `Thread.sleep` is a timeout, not a wait on anything the pool delivers, so it cannot exhaust a
/// pool (docs/TESTING.md, second table).
///
/// **Mutation (variable not honoured):** run with `AEOLUS_EXPECT_POOL_OF_ONE=1` and without
/// `LIBDISPATCH_COOPERATIVE_POOL_STRICT`. Red on `widest == 1`, with `widest` above 1.
@Suite(
    "A run that claims a cooperative pool of one has one",
    .enabled(
        if: ProcessInfo.processInfo.environment["AEOLUS_EXPECT_POOL_OF_ONE"] == "1",
        "set by the pool-of-one CI step and by the command in docs/TESTING.md"
    )
)
struct CooperativePoolWidthTests {

    /// Synchronous, because `Thread.sleep` is refused in an `async` context.
    private static func holdAThread(
        for seconds: TimeInterval,
        counting occupancy: OSAllocatedUnfairLock<(inside: Int, widest: Int)>
    ) {
        occupancy.withLock {
            $0.inside += 1
            $0.widest = max($0.widest, $0.inside)
        }
        Thread.sleep(forTimeInterval: seconds)
        occupancy.withLock { $0.inside -= 1 }
    }

    @Test("No two tasks hold a pool thread at once")
    func noTwoTasksHoldAThreadAtOnce() async {
        let taskCount = 6
        let holdSeconds = 0.1
        let occupancy = OSAllocatedUnfairLock(initialState: (inside: 0, widest: 0))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask { Self.holdAThread(for: holdSeconds, counting: occupancy) }
            }
            await group.waitForAll()
        }

        let widest = occupancy.withLock { $0.widest }
        #expect(
            widest == 1,
            """
            \(widest) of \(taskCount) tasks held a pool thread at the same moment, so this \
            run is not on a cooperative pool of one. LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 \
            did not take effect on this toolchain, and the pool-of-one CI step checks nothing.
            """
        )
    }
}
