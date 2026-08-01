import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The boundary over a real XPC connection: a real `NSXPCListener`, the real delegate, the
/// real exported object, and a real client proxy — all in this process, with no mach
/// service, no privilege, and no signing identity, so it runs unchanged on CI.
///
/// What these add over `HandshakeGateTests`, which drives the same actor directly: the
/// wiring. A gate that is correct in the actor and never reached because the delegate
/// forgot to set `exportedObject`, or an invalidation handler that was never attached,
/// fails here and nowhere else.
///
/// `.timeLimit` because of what mutation testing turned up: deleting the delegate's
/// `return false` on the refuse-all path made the listener accept a connection it never
/// configured, so the client's message went to nothing — no reply, no error handler, and
/// `withCheckedContinuation` waited for an answer that was never coming. The suite hung
/// instead of failing, which is the worst possible way for a safety test to react to a
/// safety mechanism being removed. A green suite must mean the tests ran.
@Suite("The boundary over a real XPC connection", .timeLimit(.minutes(1)))
struct AnonymousListenerTests {

    @Test("snapshot before hello is refused over the wire, with the fault intact")
    func snapshotRefusedBeforeHandshake() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)

        let result = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }

        #expect(result.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    @Test("hello then snapshot succeeds, and the snapshot decodes")
    func handshakeThenSnapshot() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)

        let hello = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }
        let helloData = try #require(hello.payload)
        let helloReply = try AeolusXPCCoding.decoder().decode(HelloReply.self, from: helloData)
        #expect(helloReply.helperProtocolRange == AeolusXPCVersion.supportedRange)
        #expect(helloReply.helperBuild == "test")

        let snapshot = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }
        let snapshotData = try #require(snapshot.payload)
        let decoded = try AeolusXPCCoding.decoder().decode(
            SystemSnapshot.self, from: snapshotData)

        #expect(decoded == .empty)
        #expect(await authority.calls == [.snapshot])
    }

    /// Refuse, never degrade — and carry both sides' ranges so the client can say which of
    /// the two to update rather than shrugging.
    @Test("An out-of-range client is refused over the wire with both ranges")
    func versionMismatchCrossesTheWire() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)

        let result = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload(version: 7)) ?? Data(), reply: reply)
        }

        guard case .versionMismatch(let clientVersion, let helperRange) = try #require(result.fault)
        else {
            Issue.record("expected versionMismatch, got \(String(describing: result.fault))")
            return
        }
        #expect(clientVersion == 7)
        #expect(helperRange == AeolusXPCVersion.supportedRange)

        // And the gate stayed shut.
        let snapshot = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }
        #expect(snapshot.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    @Test("restoreAllToAutomatic is reachable over the wire before hello")
    func panicPathIsReachableBeforeHandshake() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)

        let error = await harness.acknowledgementMessage { proxy, reply in
            proxy.restoreAllToAutomatic(reply: reply)
        }

        #expect(error == nil)
        #expect(await authority.calls.count == 1)
        guard case .restoreAllToAutomatic = try #require(await authority.calls.first) else {
            Issue.record("the panic path did not reach the authority")
            return
        }
    }

    @Test("Lease messages are refused rather than stubbed, once handshaken")
    func leaseMessagesRefuse() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)
        _ = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }

        let acquire = await harness.payloadMessage { proxy, reply in
            proxy.acquireLease(request: (try? leasePayload()) ?? Data(), reply: reply)
        }
        #expect(acquire.fault == .manualControlUnavailable(reason: .writePathNotBuilt))

        let renew = await harness.payloadMessage { proxy, reply in
            proxy.renewLease(id: UUID().uuidString, reply: reply)
        }
        #expect(renew.fault == .manualControlUnavailable(reason: .writePathNotBuilt))

        let release = await harness.acknowledgementMessage { proxy, reply in
            proxy.releaseLease(id: UUID().uuidString, reply: reply)
        }
        #expect(release.fault == .manualControlUnavailable(reason: .writePathNotBuilt))

        let settings = try AeolusXPCCoding.encoder().encode(
            [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_000))])
        let apply = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(settings: settings, leaseID: UUID().uuidString, reply: reply)
        }
        #expect(apply.fault == .manualControlUnavailable(reason: .writePathNotBuilt))
    }

    /// A malformed `apply` payload is refused as malformed, not as manual-control-
    /// unavailable: the boundary's validation is a property of the boundary, not of
    /// whether the thing behind it has been built yet.
    @Test("A malformed apply payload is refused as malformed")
    func malformedApplyIsRefusedAsMalformed() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)
        _ = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }

        let apply = await harness.acknowledgementMessage { proxy, reply in
            proxy.apply(
                settings: Data("[{\"fanIndex\":\"zero\"}]".utf8),
                leaseID: UUID().uuidString,
                reply: reply)
        }

        #expect(apply.fault?.wireCode == "malformedPayload")
        #expect(await authority.calls.isEmpty)
    }

    // MARK: - Teardown

    /// **The assertion the seam exists for.** ADR 0005 makes connection death one of the
    /// lease's two independent teardown paths; the invalidation handler is listener code,
    /// so if the event does not cross the seam, E5 can only implement its half by editing
    /// the listener.
    ///
    /// Asserts on the *authority being called*, not on a handler existing: a handler that
    /// is attached and never fires, or fires and does not cross, looks identical from
    /// outside.
    @Test("A client invalidating its connection reaches connectionDidInvalidate")
    func invalidationCrossesTheSeam() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)

        // One message first, so the connection is fully established before it is torn
        // down — an invalidation racing the accept would prove nothing about the handler.
        _ = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }

        harness.connection.invalidate()

        try await waitUntil("connectionDidInvalidate crossed the seam") {
            await !authority.invalidatedConnections.isEmpty
        }
        #expect(await authority.invalidatedConnections.count == 1)
    }

    /// The same event, for a connection that never handshook and delivered nothing. This
    /// is the case the log line calls indistinguishable from a code-signing refusal — and
    /// the seam must still be crossed, because a client holding a lease is not the only
    /// reason to know a connection died.
    @Test("A connection that never handshook still reaches connectionDidInvalidate")
    func invalidationCrossesTheSeamWithoutAHandshake() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)

        // Force the connection to actually be established: NSXPCConnection is lazy, and a
        // connection nothing was ever sent on may never reach the listener at all.
        _ = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }
        harness.connection.invalidate()

        try await waitUntil("connectionDidInvalidate crossed the seam") {
            await !authority.invalidatedConnections.isEmpty
        }
    }

    // MARK: - Refuse-all

    /// Every row of ADR 0005's fail-closed table lands on this behaviour: the listener
    /// comes up and refuses each connection.
    ///
    /// The client sees a *transport* failure, not an Aeolus refusal — `AeolusXPCFault`
    /// deliberately does not synthesise one, because "the helper said no" and "the helper
    /// never answered" are different things and a client must not conflate them.
    @Test("A helper refusing all connections answers nothing, and not with a fault")
    func refuseAllAnswersNothing() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(
            authority: authority,
            admission: RefuseAllAdmission(refusal: .helperHasNoTeamIdentifier))

        let result = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }

        #expect(result.isPromptTransportFailure)
        #expect(!result.timedOut, "a refused connection must fail, not hang")
        #expect(result.payload == nil)
        #expect(await authority.calls.isEmpty)
    }

    /// The panic path is exempt from the handshake gate and never from the authorisation
    /// gate. A helper refusing every connection refuses this one too.
    @Test("Refuse-all also refuses the panic path")
    func refuseAllAlsoRefusesThePanicPath() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(
            authority: authority,
            admission: RefuseAllAdmission(refusal: .negativeControlAdmittedForeignCode))

        let error = await harness.acknowledgementMessage { proxy, reply in
            proxy.restoreAllToAutomatic(reply: reply)
        }

        #expect(error.isPromptTransportFailure)
        #expect(!error.timedOut, "a refused connection must fail, not hang")
        #expect(error.fault == nil, "a refused connection is a transport failure, not a refusal")
        #expect(await authority.calls.isEmpty)
    }
}

/// Polls `condition` until it holds or the deadline passes.
///
/// Connection invalidation is delivered by libxpc on its own schedule, so the alternative
/// to polling is a fixed sleep — which is either flaky or slow, and gives no diagnostic
/// when it fails. Fails the test with the reason rather than hanging the suite.
func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(10),
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    Issue.record("timed out after \(timeout) waiting for: \(what)", sourceLocation: sourceLocation)
}
