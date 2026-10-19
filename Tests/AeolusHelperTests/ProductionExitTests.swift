import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// E1 (b2): the orderly exit with level 6's `apply` in flight, composed over the **production**
/// plane — `SignalTeardownInFlightApplyTests`' two flight scenarios, which ran against the scripted
/// double alone, run here through `SMCFanControlPlane`'s own ticket, admission and seal, over
/// `FirmwareSMC`. Nothing forward is written after the exit's keystone, and the process ends
/// `.restored` with every fan automatic and the key clear.
@Suite("The exit with an apply in flight, over the production plane", .timeLimit(.minutes(1)))
struct ProductionExitTests {

    /// An `apply` whose engagement has its ticket and entitlement when the teardown runs: the
    /// release ends the lease, the keystones request `.everyFan` then `.forExit`, and the step is
    /// refused at its admission; its retry's entitlement refuses on the ended lease. Nothing is
    /// written forward, and the exit is `.restored`.
    ///
    /// **Mutation:** in `SMCWriteTurns.step`, take a refused admission as `.first`
    /// (`(try? ledger.admitStep(fanAt: index)) ?? .first`). Run: red here, at the forward writes.
    @Test(
        "An apply in flight at the exit writes nothing forward over the production plane",
        arguments: [FirmwareSMC.Unlock.naive, .heldUntilForced(stepsToYield: 2)])
    func anApplyInFlightAtTheExitWritesNothing(_ unlock: FirmwareSMC.Unlock) async throws {
        let machine = await ProductionWriteMachine(unlock: unlock)
        let lease = try await machine.lease()
        await machine.writes.interfere(beforeEngageStep: 1) { await machine.tearDown() }
        let mark = machine.firmware.log.entries.count

        let answer = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        #expect(await machine.writes.didFire, "the teardown never ran inside the engagement")
        #expect(machine.journal.exitsNow == [.restored], "\(machine.journal.exitsNow)")
        #expect(
            machine.forwardWrites(since: mark).isEmpty,
            "a forward write reached the firmware: \(machine.forwardWrites(since: mark))")
        #expect(await machine.firmware.register(smcKey("F0Md")) == [0])
        #expect(await machine.firmware.register(SMCKey.forceTest) == [0])
        #expect(answer == .leaseUnknown, "\(String(describing: answer))")
    }

    /// The seal's command half over the production plane: fan 0 engaged and commanded, then a
    /// re-apply's command parked before its turn while the teardown runs. The command reaches the
    /// plane after the exit and writes no target: `.forExit` sealed it, and `admitCommand()` is its
    /// turn's first statement.
    ///
    /// **Mutation:** delete `try ledger.admitCommand()` from `SMCWriteTurns.command`. Run: red
    /// here,
    /// at the target write.
    @Test("A command in flight at the exit writes no target over the production plane")
    func aCommandInFlightAtTheExitWritesNoTarget() async throws {
        let machine = await ProductionWriteMachine()
        let lease = try await machine.lease()
        try await machine.apply(rpm: 2_400, under: lease)
        #expect(machine.forwardWrites(since: 0).contains { $0.hasPrefix("F0Tg") })
        await machine.writes.interfere(beforeCommandTarget: 2) { await machine.tearDown() }
        let mark = machine.firmware.log.entries.count

        let answer = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 3_000, under: lease)
        }

        #expect(await machine.writes.didFire, "the teardown never ran inside the command")
        #expect(machine.journal.exitsNow == [.restored], "\(machine.journal.exitsNow)")
        #expect(
            machine.forwardWrites(since: mark).isEmpty,
            "a target was written after the exit's keystone: \(machine.forwardWrites(since: mark))")
        #expect(await machine.firmware.register(smcKey("F0Md")) == [0])
        #expect(answer == .leaseUnknown, "\(String(describing: answer))")
    }
}
