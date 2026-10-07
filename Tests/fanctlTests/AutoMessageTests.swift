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
        interruption: String? = nil
    ) -> AutoCommand.Observation {
        AutoCommandTests.observation(
            snapshot, restoreRequested: restoreRequested, restoreFailure: restoreFailure,
            endedLease: endedLease, interruption: interruption)
    }

    private static func pinned(
        _ reason: ManualControlAvailability.Reason, index: Int = 1
    ) -> SystemSnapshot {
        AutoCommandTests.pinned(reason, index: index)
    }

    // MARK: - Text: the reasons

    /// 9 carries the fan, the reason's own words and its advice, and the raw wire value a user
    /// can find in `docs/RECOVERY.md`.
    @Test("Exit 9 names the fan, the reason, its advice and the wire value")
    func nineCarriesTheReason() throws {
        let message = try #require(
            Self.observation(Self.pinned(.foreignManualControl)).failure?.message)
        let reason = ManualControlAvailability.Reason.foreignManualControl
        #expect(message.contains("Fan 1"))
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
        #expect(message.contains("Fan 1 also still reads manual"))
    }

    @Test("Exit 5 names the holder and says the request is not repeated")
    func fiveNamesTheHolder() throws {
        let message = try #require(Self.observation(Fixtures.leasedManual).failure?.message)
        #expect(message.contains("\"Aeolus.app 0.3.0\""))
        #expect(message.contains("sent the request once"))
        #expect(!message.contains("launchctl bootout"))
    }

    @Test("Exit 8 says what is still manual, that nothing is repeated, and the way out")
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

    @Test("Exit 8 after the helper stopped answering says so, and that the snapshot may predate it")
    func eightAfterInterruption() throws {
        let message = try #require(
            Self.observation(Fixtures.leasedManual, interruption: "The helper went away.")
                .failure?.message)
        #expect(message.contains("stopped answering"))
        #expect(message.contains("The helper went away."))
        #expect(message.contains("may predate"))
        #expect(!message.contains("within 10 seconds"))
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

    @Test("The document has exactly the six keys, every one present")
    func documentKeys() throws {
        let document = try Self.document(
            Self.observation(Fixtures.automatic, restoreRequested: false))
        #expect(
            Set(document.keys)
                == ["schema", "restoreRequested", "endedLease", "lease", "fans", "failure"])
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
