import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A parking double gives up at its ceiling and says so, instead of turning a red into a hang
/// ([#451](https://github.com/blamechris/Aeolus/issues/451)).
///
/// `ScopeParkingPlane` and the three wedging doubles park a restore on an `AsyncSignal` in an
/// unstructured task, where a suite's `.timeLimit` cannot reach it. A mutation that adds a restore
/// the test did not park or release (#448's U3: a restore through the kept handback from the
/// power observer's closure) therefore hung `SleepGrantSealTests`, `SleepCycleSurvivalTests` and
/// `UnconfirmedHandbackTests` until CI's own timeout killed the job. Each double now waits at most
/// its ceiling, records an issue, and goes on; these tests give each one a ceiling of tens of
/// milliseconds and a restore nobody releases.
///
/// **What each test holds.** The restore comes back, with an issue recorded for it, and the next
/// restore does not wait out a ceiling of its own. The first is inside `withKnownIssue`, so the
/// issue is the expectation rather than a failure; the second is outside it, so an issue there
/// fails the test. A restore that never comes back is not joined: `finishedBeforeCeiling` ends the
/// wait at `outwaitCeiling` and records that, and the expectation after it fails. So a double that
/// lost its ceiling fails here after ten seconds of waiting, naming itself, and does not hang the
/// suite. Time the whole test process spends stopped is not waiting
/// ([#547](https://github.com/blamechris/Aeolus/issues/547)): a stall of more than ten seconds
/// used to fail five of these, whose doubles had done nothing wrong.
@Suite("A parking double gives up at its ceiling", .timeLimit(.minutes(1)))
struct ParkingCeilingTests {

    /// Short enough that a test of a ceiling costs nothing, and long enough that a restore the
    /// test lets through itself is never mistaken for one that was not.
    private static let ceiling = Duration.milliseconds(40)

    /// Runs `restore`, which its plane holds and nobody releases, and reports whether it came
    /// back. An error it throws on the way back is not the question, only that it did.
    private static func returnsAtItsCeiling(
        _ description: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ restore: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        var returned = false
        await withKnownIssue("a held restore records an issue at its ceiling") {
            let held = observing {
                do { try await restore() } catch {}
            }
            returned =
                try await finishedBeforeCeiling(
                    description, held, sourceLocation: sourceLocation) != nil
        }
        return returned
    }

    /// Runs `restore` outside `withKnownIssue`, so an issue it records fails the test.
    private static func returnsAtOnce(
        _ description: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ restore: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        let next = observing {
            do { try await restore() } catch {}
        }
        return try await finishedBeforeCeiling(
            description, next, sourceLocation: sourceLocation) != nil
    }

    // MARK: - The signal

    @Test("A wait that is signalled in time reports it, and records nothing")
    func aSignalledWaitReportsIt() async throws {
        let signal = AsyncSignal()
        let waiting = observing { try await signal.wait(atMost: .seconds(30)) }
        await signal.signal()
        let released = try await finishedBeforeCeiling("the signalled wait", waiting)
        #expect(released == true, "the wait gave up on a signal that was sent")
    }

    @Test("A wait nobody signals gives up at its ceiling and leaves the signal open")
    func anUnsignalledWaitGivesUp() async throws {
        let signal = AsyncSignal()
        let waiting = observing { try await signal.wait(atMost: Self.ceiling) }
        let released = try await finishedBeforeCeiling("the unsignalled wait", waiting)
        #expect(released == false, "the wait was not told it gave up")

        // Open: a second wait with a ceiling no test would sit through returns at once, and
        // says it was signalled, because the expiry signalled on its behalf.
        let later = observing { try await signal.wait(atMost: .seconds(30)) }
        #expect(try await finishedBeforeCeiling("the wait after the ceiling", later) == true)
    }

    @Test("A wait that gives up does not cancel the others on its signal")
    func aGivenUpWaitDoesNotCancelTheOthers() async throws {
        let signal = AsyncSignal()
        // Parked well inside the timed wait's ceiling, which is the longer of the two for it.
        let plain = observing { try await signal.wait() }
        let released = try await signal.wait(atMost: .milliseconds(150))
        #expect(released == false)
        // `wait()`'s cancellation handler resumes every waiter with `CancellationError`, so a
        // wait that cancelled itself on expiry would have this one throw instead of return.
        _ = try await finishedBeforeCeiling("the plain wait, let go by the expiry", plain)
    }

    // MARK: - The doubles

    @Test("ScopeParkingPlane lets every parked restore through, and stops parking")
    func scopeParkingPlaneGivesUp() async throws {
        let plane = ScopeParkingPlane(SystemPowerTests.machine(fanCount: 2), ceiling: Self.ceiling)
        await plane.park(.everyFan)

        let returned = try await Self.returnsAtItsCeiling("the held machine-wide restore") {
            // Two restores of the parked scope: the first to give up lets the other through.
            async let first: Void = plane.restoreToAutomatic(.everyFan)
            async let second: Void = plane.restoreToAutomatic(.everyFan)
            try await first
            try await second
        }
        #expect(returned, "the parked restores were never let through")
        #expect(await plane.parkedRestores == 0, "a restore is still parked after the ceiling")

        let next = try await Self.returnsAtOnce("a restore after the ceiling") {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(next, "the plane went on parking after the ceiling")
    }

    @Test("WedgedRestorePlane's wedge opens at its ceiling")
    func wedgedRestorePlaneGivesUp() async throws {
        let plane = WedgedRestorePlane(SystemPowerTests.machine(), ceiling: Self.ceiling)

        let returned = try await Self.returnsAtItsCeiling("the wedged restore") {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(returned, "the wedged restore never came back")

        let next = try await Self.returnsAtOnce("a restore after the ceiling") {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(next, "the wedge held a second restore after its ceiling")
    }

    @Test("WedgedThenRefusingRestorePlane's wedge opens at its ceiling, into the refusal")
    func wedgedThenRefusingRestorePlaneGivesUp() async throws {
        let plane = WedgedThenRefusingRestorePlane(
            SystemPowerTests.machine(), ceiling: Self.ceiling)

        let returned = try await Self.returnsAtItsCeiling("the wedged restore") {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(returned, "the wedged restore never came back")
        #expect(await plane.restoreScopes == [.everyFan])
    }

    @Test("CycleWedgingRestorePlane's wedge opens at its ceiling, and stops wedging")
    func cycleWedgingRestorePlaneGivesUp() async throws {
        let plane = CycleWedgingRestorePlane(SystemPowerTests.machine(), ceiling: Self.ceiling)
        await plane.wedgeTheNextRestore()

        let returned = try await Self.returnsAtItsCeiling("the wedged restore") {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(returned, "the wedged restore never came back")

        let next = try await Self.returnsAtOnce("a restore after the ceiling") {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(next, "the plane went on wedging after the ceiling")
    }
}
