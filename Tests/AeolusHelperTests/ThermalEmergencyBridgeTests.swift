import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// § 3's bridge as one plane job (ADR 0012's 2026-10-18 amendment): maximum, then the `.fan`
/// restore, both attempted and both reported, with the restore requested before the job's turn.
///
/// `ThermalEmergencyTests` holds what § 3 writes through it; this suite holds the job's own order
/// on the scripted plane, which models B1's job, and that only § 3's writer declares the verb.
@Suite("§ 3's bridge is one job: maximum, then restore", .timeLimit(.minutes(1)))
struct ThermalEmergencyBridgeTests {

    /// What a step taken inside the bridge's wait answered.
    private actor StepOutcome {
        private(set) var step: EngagementStep?
        private(set) var error: (any Error)?

        func record(_ work: @Sendable () async throws -> EngagementStep) async {
            do {
                step = try await work()
            } catch {
                self.error = error
            }
        }
    }

    private static func maximum(of fan: CommandableFan) -> AuthorisedFanTarget {
        fan.target(for: fan.envelope.highestCommandableRPM)
    }

    /// The restore is requested **before** the job waits for its turn (D4): an engagement whose
    /// ticket is older than the bridge, stepping while the bridge is queued, is superseded at its
    /// admission and writes nothing — whichever fan it is.
    ///
    /// **Mutation:** in `ScriptedControlPlane.bridgeThenRestore(_:)`, move
    /// `ledger.restoreRequested(_:)` after the wait, into the turn. Run: red — the step is admitted
    /// and writes fan 1's mode.
    @Test("A step queued behind the bridge is superseded by its restore")
    func theRestoreIsRequestedBeforeTheTurn() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal, 1: .nominal])
        let bridged = try commandableFan(0, declaring: .nominal)
        let other = try commandableFan(1, declaring: .nominal)

        plane.beginEngagement(fanAt: 1)
        let step = StepOutcome()
        await plane.duringNextBridgeWait {
            await step.record { try await plane.engageManualControl(of: other) }
        }
        let outcome = await plane.bridgeThenRestore(Self.maximum(of: bridged))

        #expect(await step.error as? FanControlPlaneError == .superseded, "the step was admitted")
        #expect(await step.step == nil)
        #expect(await !plane.keyWrites.contains(.mode(fan: 1, value: 1)))
        #expect(throws: Never.self) { try outcome.maximum.get() }
        #expect(throws: Never.self) { try outcome.restore.get() }
        #expect(
            await plane.keyWrites == [.target(fan: 0, rpm: 5_777), .mode(fan: 0, value: 0)],
            "the job's two writes, in order")
    }

    /// After the exit's seal the command half is refused at its admission and the restore half is
    /// still issued: the job never writes a target after the final keystone, and never skips the
    /// restore.
    ///
    /// **Mutation:** in `BridgeOutcome.attempting(maximum:thenRestore:)`, return without attempting
    /// the restore when the command failed. Run: red — no mode write.
    @Test("A sealed plane refuses the bridge's command and still restores")
    func aSealedPlaneRefusesTheCommandAndStillRestores() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal])
        let fan = try commandableFan(0, declaring: .nominal)
        try await plane.restoreToAutomatic(.forExit)
        let before = await plane.keyWrites.count

        let outcome = await plane.bridgeThenRestore(Self.maximum(of: fan))

        #expect(throws: FanControlPlaneError.superseded) { try outcome.maximum.get() }
        #expect(throws: Never.self) { try outcome.restore.get() }
        let written = Array(await plane.keyWrites.dropFirst(before))
        #expect(written == [.mode(fan: 0, value: 0)], "after the seal the job wrote \(written)")
    }

    /// § 3's bridge is the **one** verb that restores inside a permit: the stated exception to the
    /// keystone's permit-free restore (`docs/SAFETY.md`; `WriteAuthorisationTests`'
    /// `theRestoreVerbTakesNoAuthorisation`, whose `restore\w*` scan does not reach it).
    /// `bridgeThenRestore(_:)` and its writer's `bridgeToMaximumThenRestore(of:)` take a permit
    /// because their command half writes the fan's maximum, and run a `.fan(n)` restore in the same
    /// job, attempted whatever the command answered and reading nothing of the permit but the fan's
    /// index. The keystone verbs are untouched, and § 3's revocation restores every fan through
    /// them afterwards. Pinned to exactly its three declarations, so a second verb that restores
    /// inside a permit is a decision and not a drift.
    ///
    /// **Mutation:** declare `func commandThenRestore(_ target: AuthorisedFanTarget) async` on
    /// `SafetyActorWriter`. Run: red.
    @Test("§ 3's bridge is the one verb that restores inside a permit")
    func theBridgeIsTheOneRestoreInsideAPermit() throws {
        let bridges = try SeamScanner.writeVerbs(named: #"\w+ThenRestore"#)
        #expect(
            bridges.map(\.file).sorted()
                == ["FanControlPlane.swift", "SMCFanControlPlane.swift", "SafetyWriters.swift"],
            """
            a verb that restores inside a permit is declared at \(bridges.map(\.file).sorted()). \
            § 3's bridge is the one stated exception to the keystone's permit-free restore.
            """)
        let permits = ["AuthorisedFanTarget", "CommandableFan"]
        for bridge in bridges {
            #expect(
                permits.contains(where: bridge.text.contains),
                "\(bridge.file): `\(bridge.text)` restores without its command's permit")
        }
    }

    /// Only the safety-actor writer declares the bridge: `GovernedFanWriter`, level 6's governed
    /// writer, declares neither it nor a restore — in its body or in an extension anywhere in the
    /// helper — so § 8's ramp governor cannot be pointed at § 3's write (`SafetyWriters.swift`'s
    /// header). Read at the source, beside a positive control.
    ///
    /// **Mutation:** add `func bridgeToMaximumThenRestore(of fan: CommandableFan) async ->
    /// BridgeOutcome { await plane.bridgeThenRestore(fan.target(for: 0)) }` to `GovernedFanWriter`.
    /// Run: red.
    /// **Mutation:** add the same in an `extension GovernedFanWriter` in `LeaseApplier.swift`.
    /// Run: red.
    @Test("GovernedFanWriter declares no bridge, and SafetyActorWriter does")
    func onlyTheSafetyActorWriterDeclaresTheBridge() throws {
        let url = SeamScanner.sourcesRoot.appendingPathComponent(
            "AeolusHelper/Safety/SafetyWriters.swift")
        let code = SeamScanner.strippingAllComments(try String(contentsOf: url, encoding: .utf8))
        var governed = [
            try #require(
                WatchdogBoundsTripwireTests.body(
                    ofTypeDeclaredBy: "actor GovernedFanWriter", in: code))
        ]
        let safetyActor = try #require(
            WatchdogBoundsTripwireTests.body(
                ofTypeDeclaredBy: "struct SafetyActorWriter", in: code))

        let opening = try NSRegularExpression(pattern: #"\bextension\s+GovernedFanWriter\b"#)
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let source = SeamScanner.strippingAllComments(
                try String(contentsOf: file, encoding: .utf8))
            let range = NSRange(source.startIndex..., in: source)
            for match in opening.matches(in: source, range: range) {
                guard let start = Range(match.range, in: source) else { continue }
                let rest = String(source[start.lowerBound...])
                let body = WatchdogBoundsTripwireTests.body(
                    ofTypeDeclaredBy: "GovernedFanWriter", in: rest)
                governed.append(contentsOf: body.map { [$0] } ?? [])
            }
        }

        for verb in ["bridgeToMaximumThenRestore", "bridgeThenRestore", "restoreToAutomatic"] {
            for body in governed {
                #expect(try SeamScanner.mentions(of: verb, inSource: body) == 0, "\(verb)")
                #expect(!body.contains("func \(verb)"), "GovernedFanWriter declares \(verb)")
            }
        }
        #expect(
            safetyActor.contains("func bridgeToMaximumThenRestore"),
            "the scan no longer finds the safety-actor writer's bridge")
    }
}
