import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// One write contract, run over **both** planes (C7; #439's W6): `ScriptedControlPlane`, which
/// every
/// ticket, seal and bridge test on `main` runs against, and the production `SMCFanControlPlane`
/// over `FirmwareSMC`. #417's tests ran against the double alone, so a production plane that
/// skipped `admitCommand()`, or called it after the write, turned nothing red. Here each scenario
/// is one test with two arms, and the two record their key writes in one vocabulary: a plane that
/// breaks the contract in production only goes red on its own arm.
///
/// The writes compared are the ones each plane **issued** — the scripted double records every key
/// write before its firmware answers, and the fake logs every write call — so a refused write is
/// in both lists, as it was in both planes.
@Suite("Both planes keep one write contract", .timeLimit(.minutes(1)))
struct WritePlaneContractTests {

    enum Arm: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case scripted, smcPlane
        var testDescription: String { rawValue }
    }

    /// A plane under the contract, and what it issued, in one vocabulary: `F0Md=1`, `Ftst=0`,
    /// `F0Tg`.
    struct Harness: Sendable {
        let plane: any FanControlPlane
        let ledger: PlaneWriteLedger
        let keyWrites: @Sendable () async -> [String]
        /// Runs `effect` once, inside the next step, after its mode write and before its force
        /// key's: the instant a restore requested from another thread lands mid-turn.
        let duringNextModeWrite: @Sendable (@escaping @Sendable () -> Void) async -> Void
    }

    static let modeZero = smcKey("F0Md")

    static func harness(
        _ arm: Arm, unlock: ScriptedControlPlane.UnlockBehaviour = .naive,
        refusingTargets: Bool = false
    ) async throws -> Harness {
        switch arm {
        case .scripted:
            let stage = ScriptedControlPlane.Stage.nominal(
                targetWrites: refusingTargets ? .refused(reason: "the firmware refused it") : nil)
            let plane = ScriptedControlPlane(
                fans: [0: .nominal, 1: .nominal], stages: [stage], unlock: unlock)
            return Harness(
                plane: plane, ledger: plane.ledger,
                keyWrites: { await plane.keyWrites.map(Self.normalised) },
                duringNextModeWrite: { effect in await plane.duringNextModeWrite(effect) })
        case .smcPlane:
            let fixture = WritePlaneFixture(unlock: unlock)
            let mark = await fixture.prepared()
            if refusingTargets {
                for key in ["F0Tg", "F1Tg"] {
                    await fixture.firmware.queueWrites(
                        to: smcKey(key), Array(repeating: .refuses(code: 0x85), count: 4))
                }
            }
            let firmware = fixture.firmware
            return Harness(
                plane: fixture.plane, ledger: try fixture.ledger,
                keyWrites: { fixture.writes(since: mark).map(Self.normalised) },
                duringNextModeWrite: { effect in
                    await firmware.onAfter(.write(Self.modeZero), run: effect)
                })
        }
    }

    private static func normalised(_ write: ScriptedControlPlane.KeyWrite) -> String {
        switch write {
        case .mode(let fan, let value): return "F\(fan)Md=\(value)"
        case .forceKey(let value): return "Ftst=\(value)"
        case .target(let fan, _): return "F\(fan)Tg"
        }
    }

    /// The fixture's `key=bytes`, with a target's bytes dropped: the two planes agree on which key
    /// was written, and the scripted one keeps no bytes for a target.
    private static func normalised(_ write: String) -> String {
        write.hasSuffix("Tg") || write.contains("Tg=") ? String(write.prefix(4)) : write
    }

    static func fan(_ index: Int) throws -> CommandableFan { try WritePlaneFixture.fan(index) }

    /// Steps `index` from its ticket until it reads back.
    static func engage(_ index: Int, on plane: any FanControlPlane) async throws {
        plane.beginEngagement(fanAt: index)
        for _ in 0..<8 {
            if try await plane.engageManualControl(of: Self.fan(index)) == .engaged { return }
        }
        Issue.record("fan \(index) did not engage")
    }

    // MARK: - C2: the ticket

    /// **Mutation (production only):** make `SMCFanControlPlane.beginEngagement(fanAt:)` do
    /// nothing. Run: red on the smcPlane arm, green on the scripted one.
    @Test(
        "A first step without a ticket writes nothing; with one it engages", arguments: Arm.allCases
    )
    func aStepNeedsItsTicket(_ arm: Arm) async throws {
        let harness = try await Self.harness(arm)

        await #expect(throws: FanControlPlaneError.superseded) {
            try await harness.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(await harness.keyWrites().isEmpty)
        try await Self.engage(0, on: harness.plane)
        #expect(await harness.keyWrites() == ["F0Md=1"], "\(arm)")
    }

    // MARK: - C3: a restore requested after the ticket supersedes the first step

    /// **Mutation (production only):** in `SMCFanControlPlane.restoreToAutomatic(_:)`, drop
    /// `ledger.restoreRequested(scope)`. Run: red on the smcPlane arm.
    @Test("A restore requested after the ticket supersedes the first step", arguments: Arm.allCases)
    func aRestoreSupersedesTheFirstStep(_ arm: Arm) async throws {
        let harness = try await Self.harness(arm)

        harness.plane.beginEngagement(fanAt: 0)
        try await harness.plane.restoreToAutomatic(.fan(1))
        await #expect(throws: FanControlPlaneError.superseded) {
            try await harness.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(await harness.keyWrites() == ["F1Md=0"], "\(arm)")
    }

    // MARK: - C4: the exit's seal

    /// **Mutation (production only):** delete `try ledger.admitCommand()` from
    /// `SMCWriteTurns.command`. Run: red on the smcPlane arm — the sealed command writes.
    @Test(
        "Once sealed, no step and no command writes, and every restore still does",
        arguments: Arm.allCases)
    func theExitSealsForwardWrites(_ arm: Arm) async throws {
        let harness = try await Self.harness(arm)

        try await harness.plane.restoreToAutomatic(.forExit)
        await #expect(throws: FanControlPlaneError.superseded) {
            try await harness.plane.commandTarget(Self.fan(0).target(for: 2_400))
        }
        harness.plane.beginEngagement(fanAt: 0)
        await #expect(throws: FanControlPlaneError.superseded) {
            try await harness.plane.engageManualControl(of: Self.fan(0))
        }
        try await harness.plane.restoreToAutomatic(.fan(0))
        #expect(
            await harness.keyWrites() == ["F0Md=0", "F1Md=0", "Ftst=0", "F0Md=0"], "\(arm)")
    }

    // MARK: - C5: a restore requested mid-step is seen before the force key

    /// **Mutation (production only):** delete the `isCurrent(fanAt:)` re-check in
    /// `SMCWriteTurns.setForceKey`. Run: red on the smcPlane arm — the key is written.
    @Test(
        "A restore requested mid-step supersedes it before the force key", arguments: Arm.allCases)
    func aMidStepRestoreSupersedesTheKey(_ arm: Arm) async throws {
        let harness = try await Self.harness(arm, unlock: .heldUntilForced(stepsToYield: 0))
        let ledger = harness.ledger
        await harness.duringNextModeWrite { ledger.restoreRequested(.fan(1)) }

        harness.plane.beginEngagement(fanAt: 0)
        await #expect(throws: FanControlPlaneError.supersededAfterWrite) {
            try await harness.plane.engageManualControl(of: Self.fan(0))
        }
        #expect(await harness.keyWrites() == ["F0Md=1"], "\(arm)")
    }

    // MARK: - C6: the restore is the ledger's plan

    /// **Mutation (production only):** in `SMCFanControlPlane.restoreToAutomatic(_:)`, issue
    /// `.fan(0)` in the turn when the scope is `.forExit`. Run: red on the smcPlane arm.
    @Test("The exit's restore writes what the machine-wide restore writes", arguments: Arm.allCases)
    func theExitIsTheMachineWideRestore(_ arm: Arm) async throws {
        var issued: [[String]] = []
        for scope in [FanRestoreScope.everyFan, .forExit] {
            let harness = try await Self.harness(arm, unlock: .heldUntilForced(stepsToYield: 0))
            try await Self.engage(1, on: harness.plane)
            let before = await harness.keyWrites().count
            try await harness.plane.restoreToAutomatic(scope)
            issued.append(Array(await harness.keyWrites().dropFirst(before)))
        }
        #expect(issued[0] == issued[1], "\(arm): \(issued)")
        #expect(issued[0] == ["F0Md=0", "F1Md=0", "Ftst=0"], "\(arm)")
    }

    // MARK: - The unlock and its reversal

    /// D3 and D5 on each plane: the held first step sets the key, the next step engages, a second
    /// fan under the key writes no key of its own, and the restores clear the key last.
    @Test("The unlock, a second fan under the key, and the reversal match", arguments: Arm.allCases)
    func theUnlockAndItsReversalMatch(_ arm: Arm) async throws {
        let harness = try await Self.harness(arm, unlock: .heldUntilForced(stepsToYield: 1))

        try await Self.engage(0, on: harness.plane)
        harness.plane.beginEngagement(fanAt: 1)
        #expect(try await harness.plane.engageManualControl(of: Self.fan(1)) == .awaitingYield)
        try await harness.plane.restoreToAutomatic(.fan(1))
        try await harness.plane.restoreToAutomatic(.fan(0))

        #expect(
            await harness.keyWrites() == [
                "F0Md=1", "Ftst=1", "F0Md=1", "F0Md=1", "F1Md=1", "F1Md=0", "F0Md=0", "Ftst=0",
            ], "\(arm)")
    }

    // MARK: - W6: the bridge job

    /// § 3's bridge on each plane: a refused maximum still restores; a sealed one writes no target
    /// and still restores; an accepted one is the target, then the fan's restore.
    ///
    /// **Mutation (production only):** in `SMCFanControlPlane.bridgeThenRestore(_:)`, run the
    /// restore half only when the command half succeeded. Run: red on the smcPlane arm.
    @Test("The bridge restores whatever its command half answered", arguments: Arm.allCases)
    func theBridgeRestoresWhateverTheCommandAnswered(_ arm: Arm) async throws {
        let refusing = try await Self.harness(arm, refusingTargets: true)
        try await Self.engage(0, on: refusing.plane)
        let refused = await refusing.plane.bridgeThenRestore(try Self.fan(0).target(for: 5_777))
        #expect(throws: (any Error).self) { try refused.maximum.get() }
        #expect(throws: Never.self) { try refused.restore.get() }
        #expect(await refusing.keyWrites() == ["F0Md=1", "F0Tg", "F0Md=0"], "\(arm)")

        let sealed = try await Self.harness(arm)
        try await sealed.plane.restoreToAutomatic(.forExit)
        let seal = await sealed.plane.bridgeThenRestore(try Self.fan(0).target(for: 5_777))
        #expect(throws: FanControlPlaneError.superseded) { try seal.maximum.get() }
        #expect(await sealed.keyWrites().suffix(1) == ["F0Md=0"], "\(arm)")

        let accepted = try await Self.harness(arm)
        try await Self.engage(0, on: accepted.plane)
        let bridged = await accepted.plane.bridgeThenRestore(try Self.fan(0).target(for: 5_777))
        #expect(try bridged.maximum.get() == CommandedTarget(fanIndex: 0, rpm: 5_777))
        #expect(await accepted.keyWrites() == ["F0Md=1", "F0Tg", "F0Md=0"], "\(arm)")
        #expect(accepted.ledger.engagedFans.isEmpty, "\(arm)")
    }
}
