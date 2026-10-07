import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import fanctl

/// Why `fanctl auto` did not end in the safe state, and the `--json` document it prints either
/// way. The invocation, the exit codes and the success text are `AutoCommandTests`.
@Suite("fanctl auto reasons and document")
struct AutoMessageTests {

    typealias Fixtures = SafeStateTests

    private static func observation(
        _ snapshot: SystemSnapshot,
        restoreRequested: Bool = true,
        restoreFailure: String? = nil,
        endedLease: Lease? = nil,
        interruption: String? = nil,
        snapshotFollowsRestore: Bool? = nil
    ) -> AutoCommand.Observation {
        AutoCommandTests.observation(
            snapshot, restoreRequested: restoreRequested, restoreFailure: restoreFailure,
            endedLease: endedLease, interruption: interruption,
            snapshotFollowsRestore: snapshotFollowsRestore)
    }

    private static func pinned(
        _ reason: ManualControlAvailability.Reason, index: Int = 1,
        reading mode: FanControlMode = .manualFixed
    ) -> SystemSnapshot {
        AutoCommandTests.pinned(reason, index: index, reading: mode)
    }

    // MARK: - Text: the reasons

    /// 9 carries the fan, the reason's own words and its advice, and the raw wire value a user
    /// can find in `docs/RECOVERY.md`.
    @Test("Exit 9 names the fan, the reason, its advice and the wire value")
    func nineCarriesTheReason() throws {
        let message = try #require(
            Self.observation(Self.pinned(.foreignManualControl)).failure?.message)
        let reason = ManualControlAvailability.Reason.foreignManualControl
        #expect(message.contains("Fan 1 (reads manual)"))
        #expect(message.contains(reason.userFacingSummary))
        #expect(message.contains(reason.recoveryAdvice))
        #expect(message.contains("(reason: foreignManualControl)"))
        #expect(message.contains("docs/RECOVERY.md"))
        #expect(message.contains("sent the request once"))
        // Stopping the helper does not release a fan another program holds.
        #expect(!message.contains("launchctl bootout"))
    }

    @Test(
        "Exit 9 for a refused restore adds the step that needs neither this command nor the helper")
    func nineForAFailedRestore() throws {
        let message = try #require(
            Self.observation(Self.pinned(.restoreToAutomaticFailed)).failure?.message)
        let reason = ManualControlAvailability.Reason.restoreToAutomaticFailed
        #expect(message.contains(reason.userFacingSummary))
        #expect(message.contains(reason.recoveryAdvice))
        #expect(message.contains("(reason: restoreToAutomaticFailed)"))
        #expect(message.contains("launchctl bootout system/"))
        // `restoreToAutomaticFailed`'s own advice is `fanctl reset --all`, which is the request
        // this run already made. The message has to say so rather than leave it circular.
        #expect(message.contains("this run already made that request"))
    }

    /// An unread mode is reported as `automatic`. The message may not say such a fan "still
    /// reads manual": it says what the helper said, both halves of it.
    ///
    /// **Mutation:** restore the heading "These fans still read manual" in
    /// `AutoCommand.cannotReturnMessage`. Run: red.
    @Test("Exit 9 for a fan that reads automatic says so, and does not call it manual")
    func nineForAnAutomaticModedFan() throws {
        let message = try #require(
            Self.observation(Self.pinned(.restoreToAutomaticFailed, reading: .automatic))
                .failure?.message)
        let reason = ManualControlAvailability.Reason.restoreToAutomaticFailed
        #expect(message.contains("Fan 1 (reads automatic)"))
        #expect(message.contains("the mode a fan reads does not clear it"))
        #expect(message.contains(reason.recoveryAdvice))
        #expect(!message.contains("still read manual"))
        #expect(!message.contains("reads manual"))
    }

    @Test("Exit 9 names every pinned fan and leaves the transient ones out of the advice")
    func nineNamesEveryPinnedFan() throws {
        let snapshot = Fixtures.snapshot([
            Fixtures.fan(0, mode: .manualFixed, availability: .unavailable(.foreignManualControl)),
            Fixtures.fan(1, mode: .manualFixed, availability: .unavailable(.releaseInProgress)),
            Fixtures.fan(
                2, mode: .manualFixed, availability: .unavailable(.restoreToAutomaticFailed)),
        ])
        let message = try #require(Self.observation(snapshot).failure?.message)
        #expect(message.contains("Fan 0"))
        #expect(message.contains("Fan 2"))
        #expect(message.contains("Fan 1 (reads manual) is also not cleared"))
    }

    @Test("Exit 5 names the holder and says the request is not repeated")
    func fiveNamesTheHolder() throws {
        let message = try #require(Self.observation(Fixtures.leasedManual).failure?.message)
        #expect(message.contains("\"Aeolus.app 0.3.0\""))
        #expect(message.contains("sent the request once"))
        #expect(!message.contains("launchctl bootout"))
    }

    @Test("Exit 8 says what is not cleared, that nothing is repeated, and the way out")
    func eightText() throws {
        let snapshot = Fixtures.snapshot([
            Fixtures.fan(0, mode: .manualFixed, availability: .unavailable(.releaseInProgress)),
            Fixtures.fan(1),
        ])
        let message = try #require(Self.observation(snapshot).failure?.message)
        #expect(message.contains("within 10 seconds"))
        #expect(message.contains("Fan 0"))
        #expect(message.contains("reason: releaseInProgress"))
        #expect(!message.contains("Fan 1"))
        #expect(message.contains("sent the request once"))
        #expect(message.contains("launchctl bootout system/"))
    }

    /// A blind fan's state is unknown, not manual: 8, never 9. The message names the reason,
    /// carries the reason's own advice, and ends in the restart that advice leads to.
    ///
    /// **Mutation:** move `.supervisorBlind` into `durable` in `SafeState.clearance(of:)`, or
    /// drop the fan from `unclearedFanLines`. Run: red.
    @Test("Exit 8 for a blind fan names the reason, its advice and the restart")
    func eightForABlindFan() throws {
        let observation = Self.observation(Self.pinned(.supervisorBlind, reading: .automatic))
        let failure = try #require(observation.failure)
        let reason = ManualControlAvailability.Reason.supervisorBlind
        #expect(failure.code == .safeStateNotConfirmed)
        #expect(failure.message.contains("Fan 1 (reads automatic) is not cleared"))
        #expect(failure.message.contains("(reason: supervisorBlind)"))
        #expect(failure.message.contains(reason.userFacingSummary))
        #expect(failure.message.contains(reason.recoveryAdvice))
        #expect(failure.message.contains("launchctl bootout system/"))
        // Every fan reads automatic, so the helper did not fail to report one as automatic: it
        // has not cleared it, and the sentence says which fan and why.
        #expect(failure.message.contains("The helper has not cleared fan 1 (supervisorBlind)"))
        #expect(!failure.message.contains("did not report every fan automatic"))
    }

    /// The sentence about the snapshot agrees with `snapshotFollowsRestore`, in both directions.
    ///
    /// **Mutation:** make the text ignore the flag (always say "may predate the restore", or
    /// always say "after"). Run: red on one of the two.
    @Test("Exit 8 after the helper stopped answering says when the snapshot shown was read")
    func eightAfterInterruption() throws {
        let before = try #require(
            Self.observation(
                Fixtures.leasedManual, interruption: "The helper went away.",
                snapshotFollowsRestore: false
            ).failure?.message)
        #expect(before.contains("stopped answering"))
        #expect(before.contains("The helper went away."))
        #expect(before.contains("The snapshot shown was read before the restore request."))
        #expect(!before.contains("after the restore request, and is the last"))
        #expect(!before.contains("within 10 seconds"))

        let after = try #require(
            Self.observation(
                Fixtures.leasedManual, interruption: "The helper went away.",
                snapshotFollowsRestore: true
            ).failure?.message)
        #expect(after.contains("The snapshot shown was read after the restore request"))
        #expect(!after.contains("predate"))
        #expect(!after.contains("before the restore request"))
    }

    @Test("A restore the helper did not confirm is part of the exit 8 message")
    func eightMentionsAnUnacknowledgedRestore() throws {
        let message = try #require(
            Self.observation(
                Fixtures.snapshot([Fixtures.fan(0, mode: .manualFixed)]), restoreFailure: "refused"
            ).failure?.message)
        #expect(message.contains("did not confirm the restore request: refused"))
    }

    @Test("A thermal emergency explains an exit 8")
    func eightExplainsAnEmergency() throws {
        let emergency = SystemSnapshot(
            fans: [Fixtures.fan(0, mode: .manualFixed)], sensors: [], activeLease: nil,
            isThermalEmergencyActive: true, capturedAt: Fixtures.captured)
        let message = try #require(Self.observation(emergency).failure?.message)
        #expect(message.contains("thermal emergency"))
        #expect(message.contains("outranks"))
    }

    // MARK: - JSON

    private static func document(_ observation: AutoCommand.Observation) throws -> [String: Any] {
        let text = try FanctlJSON.encode(AutoDocumentJSON(observation))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("The document has exactly its eight keys, every one present")
    func documentKeys() throws {
        let document = try Self.document(
            Self.observation(Fixtures.automatic, restoreRequested: false))
        #expect(
            Set(document.keys)
                == [
                    "schema", "capturedAt", "restoreRequested", "snapshotFollowsRestore",
                    "endedLease", "lease", "fans", "failure",
                ])
        #expect(document["schema"] as? Int == 1)
        #expect(document["restoreRequested"] as? Bool == false)
        #expect(document["endedLease"] is NSNull)
        #expect(document["lease"] is NSNull)
        #expect(document["failure"] is NSNull)
        let fans = try #require(document["fans"] as? [[String: Any]])
        #expect(fans.count == 2)
        #expect(fans.first?["mode"] as? String == "automatic")
    }

    @Test("An ended lease and a failure are objects, with the lease reusing status's shape")
    func documentWithEndedLeaseAndFailure() throws {
        let ended = Lease(
            holderDescription: "Aeolus.app 0.3.0",
            expiresAt: Fixtures.captured.addingTimeInterval(9))
        let other = Lease(holderDescription: "Other 1.0", expiresAt: Fixtures.captured)
        let snapshot = Fixtures.snapshot([Fixtures.fan(0, mode: .manualFixed)], lease: other)
        let document = try Self.document(Self.observation(snapshot, endedLease: ended))

        #expect(document["restoreRequested"] as? Bool == true)
        let endedBody = try #require(document["endedLease"] as? [String: Any])
        #expect(endedBody["holderDescription"] as? String == "Aeolus.app 0.3.0")
        #expect(endedBody["id"] as? String == ended.id.uuidString)
        let leaseBody = try #require(document["lease"] as? [String: Any])
        #expect(leaseBody["holderDescription"] as? String == "Other 1.0")
        let failure = try #require(document["failure"] as? [String: Any])
        #expect(failure["exitCode"] as? Int == 5)
        #expect(failure["kind"] as? String == "heldByAnotherClient")
        #expect(failure["message"] as? String == Self.observation(snapshot).failure?.message)
        #expect(
            document["fans"] is [[String: Any]], "a failure after a snapshot still carries fans")
    }

    /// `status --json` carries when the helper captured what it reports; so does this, so a
    /// script reading an exit 0 can tell how old the helper's report is.
    ///
    /// **Mutation:** drop the `capturedAt` line from `AutoDocumentJSON.encode`. Run: red.
    @Test("The document says when the helper captured the snapshot")
    func documentCarriesCapturedAt() throws {
        let document = try Self.document(Self.observation(Fixtures.automatic))
        #expect(document["capturedAt"] as? String == "2026-09-21T14:13:20Z")
    }

    /// Whether `fans` and `lease` describe the helper after the request or before it, as a
    /// boolean a script can branch on instead of prose it has to parse.
    ///
    /// **Mutation:** encode `true` for `snapshotFollowsRestore` whatever the observation says.
    /// Run: red on the two `false` cases.
    @Test("snapshotFollowsRestore is true only for a snapshot read after the request")
    func documentSaysWhetherTheSnapshotFollowsTheRestore() throws {
        let noRestore = try Self.document(
            Self.observation(Fixtures.automatic, restoreRequested: false))
        let settled = try Self.document(Self.observation(Fixtures.automatic))
        // The wait could not read a second snapshot: `fans` and `lease` are the ones from before
        // the request, and the document says so rather than leaving the prose to.
        let beforeTheRequest = try Self.document(
            Self.observation(
                Fixtures.leasedManual, interruption: "gone", snapshotFollowsRestore: false))

        #expect(noRestore["snapshotFollowsRestore"] as? Bool == false)
        #expect(settled["snapshotFollowsRestore"] as? Bool == true)
        #expect(beforeTheRequest["snapshotFollowsRestore"] as? Bool == false)
        #expect(beforeTheRequest["restoreRequested"] as? Bool == true)
        let failure = try #require(beforeTheRequest["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "safeStateNotConfirmed")
    }

    @Test("Exit 9 is its own kind in the document")
    func documentForNine() throws {
        let document = try Self.document(Self.observation(Self.pinned(.foreignManualControl)))
        let failure = try #require(document["failure"] as? [String: Any])
        #expect(failure["exitCode"] as? Int == 9)
        #expect(failure["kind"] as? String == "cannotReturnToAutomatic")
        let fans = try #require(document["fans"] as? [[String: Any]])
        let manual = try #require(fans.first { $0["index"] as? Int == 1 })
        let control = try #require(manual["manualControl"] as? [String: Any])
        #expect(control["reason"] as? String == "foreignManualControl")
    }
}
