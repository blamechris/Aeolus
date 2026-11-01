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

    /// A lease over both fans is released and its handback parks, both fans manual. A grant over
    /// both exempts both from the foreign-control step as mid-handback and parks inside it, on the
    /// reconciliation actor; the handback then lands, and the grant resumes. Nothing has read
    /// either fan since its restore was accepted, and the firmware left both manual.
    ///
    /// The grant must not go through. It is refused `.releaseInProgress`: the honest answer for
    /// fans whose handback finished inside this request, because a retry reads them fresh and
    /// states whatever is true of them then — which the last expectation checks: both still read
    /// manual, no § 3 is keeping them here, so the retry is told `.foreignManualControl`.
    ///
    /// Every fan, as a lease must cover since #670 (reviewer T's probe for PR #676): the exemption
    /// is still taken, so the guard is still the only thing between the lapse and a grant.
    ///
    /// **Mutation:** delete `try refuseIfExemptionLapsed(connection, exempted: exempted)` from
    /// `LeaseAuthority.acquireLease`. Run: red — "Granted a lease over two fans".
    /// **Mutation:** in `refuseIfForeignManualControl(_:wanting:)`, return `[]` in place of
    /// `fans.intersection(held)`. Run: red, the same line.
    @Test("Fans exempted mid-handback are not granted once their handback lands mid-grant")
    func anExemptionThatLapsesMidGrantIsRefused() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400), 1: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let fans = ScriptedFanEnumeration(indices: [0, 1])
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let foreign = ParkingForeignControl(
            over: LeaseFixture.reconciliation(over: plane, enumeration: fans))
        let leases = LeaseFixture.authority(
            enumeration: fans,
            restorer: RecordingFanRestorer(entered: entered, release: release),
            foreignControl: foreign)

        // Client A holds both fans, which E3's engage writes put in manual, and releases them.
        // The restore parks: both fans are mid-handback.
        let holder = ConnectionID()
        let lease = try await leases.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: holder)
        await plane.setMode(.manual, ofFan: 0)
        await plane.setMode(.manual, ofFan: 1)
        let handback = observing { try await leases.releaseLease(id: lease.id, from: holder) }
        try await entered.wait()
        #expect(await leases.fansMidHandback == [0, 1], "the handback is not in flight")

        // Client B asks for both. Both are exempted as mid-handback, and the foreign-control
        // step parks.
        await foreign.arm()
        let grant = observing {
            try await leases.acquireLease(LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
        }
        #expect(
            await yieldUntil("the grant to park in the foreign-control step") {
                await foreign.parked == 1
            })

        // The restore returns — accepted, and the firmware left both fans manual.
        await release.signal()
        _ = try await finished("the handback to finish", handback)
        #expect(await leases.fansMidHandback.isEmpty, "the handback never finished")
        #expect(try await plane.readControlState(ofFan: 0).mode == .manual)
        await foreign.open()

        do {
            _ = try await finished("the parked grant", grant)
            Issue.record(
                """
                Granted a lease over two fans that still read manual and that nothing has read \
                since their handback was accepted: the foreign-control step exempted them as \
                mid-handback, and the handback finished before the straight-line region.
                """)
        } catch let fault as AeolusXPCFault {
            #expect(fault == .manualControlUnavailable(reason: .releaseInProgress))
        }
        #expect(await leases.leaseCount == 0)

        do {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
            Issue.record("the retry granted a lease over fans that still read manual")
        } catch let fault as AeolusXPCFault {
            #expect(fault == .manualControlUnavailable(reason: .foreignManualControl))
        }
    }

    /// Fan 0's handback lands while a grant over fans 0 and 1 is parked on fan 1's **bounds**
    /// read ([#270](https://github.com/blamechris/Aeolus/issues/270)) — the suspension point
    /// after the foreign-control read, and the last above the marker. Fan 0 is exempted from both
    /// reads as mid-handback, so nothing reads it during the grant, and the firmware left it
    /// manual.
    ///
    /// The bounds gate adds no exemption of its own to keep honest: it reads what the foreign
    /// read did not exempt, and `refuseIfExemptionLapsed(_:exempted:)` is what answers for a
    /// handback that lands during either.
    ///
    /// **Mutation:** delete `try refuseIfExemptionLapsed(connection, exempted: exempted)` from
    /// `LeaseAuthority.acquireLease`. Run: red — "Granted a lease over fan 0".
    @Test(
        "A fan exempted mid-handback is not granted once its handback lands mid-bounds-read",
        .disabled(
            """
            Unreachable while a lease must cover every fan (#670): a handback covers every fan, \
            so the grant exempts every fan from the bounds read and has no read to park on. The \
            lapse is pinned over every fan by the test above. Re-enable when run 1d lifts the \
            rule.
            """))
    func anExemptionThatLapsesDuringTheBoundsReadIsRefused() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400), 1: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let fans = ScriptedFanEnumeration(indices: [0, 1])
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let envelopes = ParkableEnvelopeReading(over: firmware)
        let leases = LeaseFixture.authority(
            enumeration: fans,
            restorer: RecordingFanRestorer(entered: entered, release: release),
            foreignControl: LeaseFixture.reconciliation(over: firmware, enumeration: fans),
            envelopes: envelopes)

        let holder = ConnectionID()
        let lease = try await leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)
        await firmware.setMode(.manual, ofFan: 0)
        let handback = observing { try await leases.releaseLease(id: lease.id, from: holder) }
        try await entered.wait()
        #expect(await leases.fansMidHandback == [0], "fan 0's handback is not in flight")

        // Client B asks for fans 0 and 1. Fan 0 is exempted from both reads; fan 1's mode reads
        // automatic, and its bounds read parks.
        await envelopes.park()
        let grant = observing {
            try await leases.acquireLease(LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
        }
        #expect(
            await yieldUntil("the grant to park on fan 1's bounds read") {
                await envelopes.parked == 1
            })
        #expect(
            await envelopes.requests == [0, 1],
            "the grant read fan 0's bounds although fan 0 was mid-handback, or never read fan 1's")

        await release.signal()
        _ = try await finished("fan 0's handback to finish", handback)
        #expect(await leases.fansMidHandback.isEmpty, "fan 0's handback never finished")
        await envelopes.release()

        do {
            _ = try await grant.task.value
            Issue.record(
                """
                Granted a lease over fan 0, which still reads manual and which nothing has read \
                since its handback was accepted: both reads exempted it as mid-handback, and the \
                handback finished during the bounds read.
                """)
        } catch let fault as AeolusXPCFault {
            #expect(fault == .manualControlUnavailable(reason: .releaseInProgress))
        }
    }
}

/// Forwards to `inner`, parking the next `refusalForGrant` once armed until opened: the grant's
/// suspension inside the foreign-control step, after it took its exemptions.
private actor ParkingForeignControl: ForeignManualControlSensing {
    private let inner: any ForeignManualControlSensing
    private var armed = false
    private(set) var parked = 0
    private let gate = AsyncSignal()

    init(over inner: any ForeignManualControlSensing) { self.inner = inner }

    func arm() { armed = true }

    func open() async { await gate.signal() }

    func refusalForGrant(
        overFans fans: Set<Int>, heldByAeolus held: Set<Int>,
        awaitingConfirmation awaiting: Set<Int>
    ) async -> ManualControlAvailability.Reason? {
        if armed {
            armed = false
            parked += 1
            try? await gate.wait()
        }
        return await inner.refusalForGrant(
            overFans: fans, heldByAeolus: held, awaitingConfirmation: awaiting)
    }

    func fansReadingAutomatic(among fans: Set<Int>) async -> Set<Int> {
        await inner.fansReadingAutomatic(among: fans)
    }
}
