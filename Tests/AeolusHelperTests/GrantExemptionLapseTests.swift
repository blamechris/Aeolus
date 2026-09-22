import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// [#311](https://github.com/blamechris/Aeolus/issues/311): a fan the grant path exempted from
/// the foreign-control step because it was mid-handback must not be granted when its handback
/// finishes while the grant is suspended.
///
/// `refuseIfForeignManualControl` computes `fansAeolusIsAccountableFor` once and then suspends
/// — on the reconciliation actor, and on one mode read per fan it does judge. A fan in
/// `releasing` at that instant is exempted and never read. If its restore returns during the
/// suspension, `releasing` clears, so by the straight-line region the `.releaseInProgress`
/// guard no longer sees it and nothing refuses it, however it reads.
@Suite("A handback that lands mid-grant", .timeLimit(.minutes(1)))
struct GrantExemptionLapseTests {

    /// Fan 0's handback lands while a grant over fans 0 and 1 is parked on fan 1's mode read.
    /// The firmware accepted fan 0's restore and left it manual, and nothing has read it since.
    ///
    /// The grant must not go through. It is refused `.releaseInProgress`: the honest answer for
    /// a fan whose handback finished inside this request, because a retry reads it fresh and
    /// states whatever is true of it then — which the last expectation checks: fan 0 still
    /// reads manual, no § 3 is keeping it here, so the retry is told `.foreignManualControl`.
    ///
    /// **Mutation:** delete `try refuseIfExemptionLapsed(connection, exempted: exempted)` from
    /// `LeaseAuthority.acquireLease`. Run: red — "Granted a lease over fan 0".
    /// **Mutation:** in `refuseIfForeignManualControl(_:wanting:)`, return `[]` in place of
    /// `fans.intersection(held)`. Run: red, the same line.
    @Test("A fan exempted mid-handback is not granted once its handback lands mid-grant")
    func anExemptionThatLapsesMidGrantIsRefused() async throws {
        let plane = ControlStateGatePlane(
            ScriptedControlPlane(
                fans: [0: .automatic(at: 2_400), 1: .automatic(at: 2_400)],
                stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]))
        let fans = ScriptedFanEnumeration(indices: [0, 1])
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let leases = LeaseFixture.authority(
            enumeration: fans,
            restorer: RecordingFanRestorer(entered: entered, release: release),
            foreignControl: LeaseFixture.reconciliation(over: plane, enumeration: fans))

        // Client A holds fan 0, which E3's engage write puts in manual, and releases it. The
        // restore parks: fan 0 is mid-handback.
        let holder = ConnectionID()
        let lease = try await leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)
        await plane.wrapped.setMode(.manual, ofFan: 0)
        let handback = observing { try await leases.releaseLease(id: lease.id, from: holder) }
        try await entered.wait()
        #expect(await leases.fansMidHandback == [0], "fan 0's handback is not in flight")

        // Client B asks for fans 0 and 1. Fan 0 is exempted as mid-handback; fan 1 is read, and
        // that read parks.
        await plane.modeReads(.held)
        let grant = observing {
            try await leases.acquireLease(LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
        }
        #expect(
            await yieldUntil("the grant to park on fan 1's read") {
                await plane.heldModeReads == 1
            })

        // Fan 0's restore returns — accepted, and the firmware left the fan manual.
        await release.signal()
        _ = try await finished("fan 0's handback to finish", handback)
        #expect(await leases.fansMidHandback.isEmpty, "fan 0's handback never finished")
        #expect(try await plane.wrapped.readControlState(ofFan: 0).mode == .manual)

        await plane.modeReads(.answered)

        do {
            _ = try await grant.task.value
            Issue.record(
                """
                Granted a lease over fan 0, which still reads manual and which nothing has read \
                since its handback was accepted: the foreign-control step exempted it as \
                mid-handback, and the handback finished before the straight-line region.
                """)
        } catch let fault as AeolusXPCFault {
            guard case .manualControlUnavailable(let reason) = fault else {
                Issue.record("refused with \(fault), not a manual-control reason")
                return
            }
            #expect(reason == .releaseInProgress)
        }

        do {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
            Issue.record("the retry granted a lease over fan 0, which still reads manual")
        } catch let fault as AeolusXPCFault {
            #expect(fault == .manualControlUnavailable(reason: .foreignManualControl))
        }
    }
}
