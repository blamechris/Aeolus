import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `ThreadBlockingRestorePlane` gives up at its ceiling and says so, instead of wedging the
/// process ([#554](https://github.com/blamechris/Aeolus/issues/554)).
///
/// The double parks a cooperative-pool thread on a `DispatchSemaphore`, on purpose: that is what a
/// restore stuck in a synchronous IOKit call does. A semaphore wait cannot be cancelled, so a
/// suite's `.timeLimit` cannot free the thread, and on a pool too narrow to run the release the
/// whole process stopped at 0% CPU (a pool of one, 12 minutes, in #545's measurement). The double
/// now waits at most its ceiling, records an issue and goes on. The real ceiling is 90 s, above
/// the 60 s time limit of the suite that uses it (`threadBlockingCeiling` says why); this test
/// gives it one second, the least a ceiling counted in whole seconds can be, and a restore nobody
/// releases, so it costs a second.
///
/// **What it holds.** The restore comes back, with an issue recorded for it, and the next restore
/// does not wait out a ceiling of its own. The first is inside `withKnownIssue`, so the issue is
/// the expectation and not a failure; the second is outside it, so an issue there fails the test.
/// A restore that never comes back is not joined: `finishedBeforeCeiling` ends the wait at
/// `outwaitCeiling` and says what never finished, and the expectation after it fails. So a double
/// that lost its ceiling fails here after ten seconds, and does not wedge the run. The `defer`
/// frees the thread it left parked.
///
/// **Mutation:** in `blockThisThreadUntilReleased`, replace the `signalled(held, within: ceiling)`
/// guard and the `release()` and `Issue.record` after it with `held.wait()`. Run: red on
/// "the blocked restore never came back", after the outwait's ten seconds.
/// **Mutation:** in `blockThisThreadUntilReleased`, delete the `release()` after the guard. Run:
/// red on the issue the second restore records at its own ceiling, outside the known issue.
/// **Mutation (MG):** in `blockThisThreadUntilReleased`, delete the `Issue.record(…)` at the
/// ceiling, and keep the `release()`. Run: red on "Known issue was not recorded": the restore
/// comes back, and the block opened without saying so.
@Suite("A thread-blocking double gives up at its ceiling", .timeLimit(.minutes(1)))
struct ThreadBlockingCeilingTests {

    /// Short enough that a test of a ceiling costs a second, which is the least a ceiling counted
    /// in whole seconds can be.
    private static let ceiling = 1

    @Test("ThreadBlockingRestorePlane's block opens at its ceiling, and stops blocking")
    func threadBlockingRestorePlaneGivesUp() async throws {
        let plane = ThreadBlockingRestorePlane(SystemPowerTests.machine(), ceiling: Self.ceiling)
        defer { plane.release() }

        var returned = false
        await withKnownIssue("a blocked restore records an issue at its ceiling") {
            let held = observing { try await plane.restoreToAutomatic(.everyFan) }
            returned = try await finishedBeforeCeiling("the blocked restore", held) != nil
        }
        #expect(returned, "the blocked restore never came back")

        let next = observing { try await plane.restoreToAutomatic(.everyFan) }
        let nextReturned =
            try await finishedBeforeCeiling("a restore after the ceiling", next) != nil
        #expect(nextReturned, "the plane went on blocking after its ceiling")
        #expect(plane.restoreScopes == [.everyFan, .everyFan])
    }
}
