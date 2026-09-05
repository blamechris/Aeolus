import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

// The `FanRestoreAttempting` doubles `HandbackBoundTests` drives.
//
// Split out of that file so each stays under the 400-line limit, and because these are the
// pieces a later test of the same seam is most likely to reach for. The suite itself is in
// `HandbackBoundTests.swift`; the reasoning behind the ceiling below is `AttemptCeiling`'s.

/// The scripted firmware as the bounded restorer's attempt seam.
///
/// One line, and deliberately in the test target: `FanControlPlane` is the provider and
/// `FanRestoreAttempting` is the role, but *which* scope a production adapter uses — and
/// whether it clears the Apple Silicon force key on the way — is
/// [#102](https://github.com/blamechris/Aeolus/issues/102)'s decision, not this one's.
/// Bridging it here gets the shipped scripted firmware onto the bound's path without
/// pre-empting that.
extension ScriptedControlPlane: FanRestoreAttempting {
    func restoreOnce(fanAt index: Int) async throws {
        try await restoreToAutomatic(.fan(index))
    }
}

/// How many attempts on one fan a double in this file will absorb before it gives in.
///
/// **The bound under test must never be enforced by the double** — that would be the test
/// asserting itself. But it must not be enforced by a *time limit* either. A restorer that
/// lost its bound spins on an actor hop, never observes the time limit's cancellation, and
/// the run has to be killed: the failure is recorded at 60 s and the process hangs. A
/// regression that can only be seen by killing the runner is a test that cannot fail
/// cleanly, which is [#139](https://github.com/blamechris/Aeolus/issues/139)'s class of
/// defect.
///
/// So the ceiling stops refusing rather than refusing harder. Past it the double reports
/// success, the loop terminates whatever the restorer does, and `breachedCeiling` turns the
/// exhaustion into a plain red `#expect` in milliseconds.
///
/// Ten: comfortably above `RestoreLimits.attemptBudget`, so a budget that grew to four still
/// fails on the budget assertion rather than here, and far below anything a human waits for.
enum AttemptCeiling {
    static let perFan = 10
}

/// An attempt seam that refuses for a named set of fans and succeeds for the rest.
///
/// The scripted plane's `WriteBehaviour` is a property of the stage, so it cannot express
/// "this fan's mode write is discarded and that one's is not" — which is the one thing a
/// *per-fan* bound has to be tested against. Everything else in this file drives the real
/// mock.
///
/// It gives in at `AttemptCeiling.perFan`; see there for why.
actor PartiallyRefusingRestore: FanRestoreAttempting {

    private let refusing: Set<Int>
    private(set) var attempts: [Int] = []
    private(set) var breachedCeiling = false

    init(refusing: Set<Int>) {
        self.refusing = refusing
    }

    func restoreOnce(fanAt index: Int) async throws {
        attempts.append(index)
        guard refusing.contains(index) else { return }
        guard attemptCount(forFan: index) < AttemptCeiling.perFan else {
            breachedCeiling = true
            return
        }
        throw AeolusXPCFault.helperFailed(detail: "the firmware discarded the mode write")
    }

    func attemptCount(forFan index: Int) -> Int {
        attempts.filter { $0 == index }.count
    }
}

/// Any attempt seam, with `AttemptCeiling.perFan` as a hard stop on one fan's refusals.
///
/// It exists so the tests that drive the shipped `ScriptedControlPlane` — a firmware that
/// refuses *every* write, with no per-fan ceiling of its own — fail as a red assertion
/// rather than as a hang when the bound regresses.
actor CeilingedRefusal<Wrapped: FanRestoreAttempting>: FanRestoreAttempting {

    private let wrapped: Wrapped
    private(set) var attempts: [Int] = []
    private(set) var breachedCeiling = false

    init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }

    func restoreOnce(fanAt index: Int) async throws {
        attempts.append(index)
        do {
            try await wrapped.restoreOnce(fanAt: index)
        } catch {
            guard attemptCount(forFan: index) < AttemptCeiling.perFan else {
                breachedCeiling = true
                return
            }
            throw error
        }
    }

    func attemptCount(forFan index: Int) -> Int {
        attempts.filter { $0 == index }.count
    }
}

/// An attempt seam that refuses a fan's first `refusals` attempts and then takes the write.
///
/// The firmware that comes good on a retry — which is the case the whole retry loop exists
/// for, and the one no other double in this file can express: `PartiallyRefusingRestore`
/// either always refuses a fan or never does.
actor RefusesThenSucceeds: FanRestoreAttempting {

    private let refusals: Int
    private(set) var attempts: [Int] = []

    init(refusals: Int) {
        self.refusals = refusals
    }

    func restoreOnce(fanAt index: Int) async throws {
        attempts.append(index)
        guard attemptCount(forFan: index) > refusals else {
            throw AeolusXPCFault.helperFailed(detail: "the firmware discarded the mode write")
        }
    }

    func attemptCount(forFan index: Int) -> Int {
        attempts.filter { $0 == index }.count
    }
}

/// An attempt seam that fails **only** because the task it runs on was cancelled.
///
/// The firmware is fine here: `landed` counts the writes that reached it. A restorer that
/// treats a `CancellationError` as a firmware refusal spends the whole budget without ever
/// getting one there.
actor CancellationSensitiveRestore: FanRestoreAttempting {

    private(set) var attempts = 0
    private(set) var landed = 0

    func restoreOnce(fanAt index: Int) async throws {
        attempts += 1
        try Task.checkCancellation()
        landed += 1
    }
}
