import Testing

@testable import AeolusHelper

/// `LeaseAuthority.HandbackRegisters` and `LeaseAuthority.SleepSealPairing` as values: no actor,
/// no restorer, no clock, and nothing awaited.
///
/// [#128](https://github.com/blamechris/Aeolus/issues/128)'s lease-core pass moved every
/// synchronous decision the lease core makes over its handback registers and § 4's seal out of the
/// actor, so each can be asserted where it is stated, against a value a test constructs directly.
/// The actor suites — `UnconfirmedHandbackTests`, `AbandonedHandbackRecoveryTests`,
/// `SleepOrderingTests`, `LeaseRevocationOutwaitTests` and the rest — still drive the same rules
/// through the lease core with every interleaving they script; this suite says which half of a
/// failure is the bookkeeping and which the orchestration.
///
/// Every assertion names the mutation it kills, and each was run.
@Suite("The lease core's handback registers and sleep seal, as values")
struct LeaseAuthorityRegistersTests {

    private typealias Registers = LeaseAuthority.HandbackRegisters
    private typealias Pairing = LeaseAuthority.SleepSealPairing

    /// Registers whose restore of `fans` came back with `abandoned` given up on.
    private func restored(_ fans: Set<Int>, abandoning abandoned: Set<Int>) -> Registers {
        var registers = Registers()
        for fan in fans { registers.beginHandback(ofFan: fan) }
        _ = registers.recordRestore(of: fans, abandoned: abandoned)
        for fan in fans { _ = registers.endHandback(ofFan: fan) }
        return registers
    }

    // MARK: - releasing

    /// The count is a count: two restores of one fan, and the first back leaves it on the wire.
    ///
    /// **Mutations:** `releasing[fan] = 1` in place of `+= 1` in `beginHandback(ofFan:)`; drop
    /// `guard outstanding > 1` from `endHandback(ofFan:)`, so the first back clears the fan. Run:
    /// red on each.
    @Test("A fan stays mid-handback until its last outstanding restore is back")
    func aFanLeavesOnlyWithItsLastRestore() {
        var registers = Registers()
        registers.beginHandback(ofFan: 0)
        registers.beginHandback(ofFan: 0)

        let first = registers.endHandback(ofFan: 0)
        #expect(first == false, "the first of two restores was last")
        #expect(registers.isMidHandback(0))
        let second = registers.endHandback(ofFan: 0)
        #expect(second, "the second of two restores was not last")
        #expect(registers.isMidHandback(0) == false)
        #expect(registers.fansMidHandback.isEmpty)
    }

    /// **Mutation:** `guard let outstanding = releasing[fan] else { return true }` in
    /// `endHandback(ofFan:)`. Run: red — the actor would resume a fan's waiters for a restore it
    /// never issued.
    @Test("Counting back a fan with nothing outstanding says it was not the last, and records it")
    func countingBackAnIdleFanIsNotItsLast() {
        var registers = Registers()

        let last = registers.endHandback(ofFan: 3)
        #expect(last == false)
        #expect(registers.fansMidHandback.isEmpty)
    }

    /// **Mutation:** `!releasing.isEmpty` in place of `releasing[fan] != nil` in
    /// `isMidHandback(_:)`. Run: red.
    @Test("Mid-handback is asked of one fan, and of the requested fans in request order")
    func midHandbackIsPerFan() {
        var registers = Registers()
        registers.beginHandback(ofFan: 1)

        #expect(registers.isMidHandback(1))
        #expect(registers.isMidHandback(0) == false, "another fan's restore answered for fan 0")
        #expect(registers.midHandback(among: [2, 1, 0, 1]) == [1, 1])
    }

    // MARK: - handbackUnconfirmed

    /// D33: § 4's budget path records every fan on the wire, and the register stays inside
    /// `releasing` — a fan leaves it with its last restore.
    ///
    /// **Mutations:** delete `handbackUnconfirmed.remove(fan)` from `endHandback(ofFan:)`;
    /// `restoreAbandoned.formUnion(outstanding)` in place of `handbackUnconfirmed`'s in
    /// `recordUnconfirmedHandbacks()`. Run: red on each.
    @Test("An unconfirmed handback is recorded from the wire and leaves with its last restore")
    func anUnconfirmedHandbackLeavesWithItsLastRestore() {
        var registers = Registers()
        registers.beginHandback(ofFan: 0)
        registers.beginHandback(ofFan: 0)
        registers.beginHandback(ofFan: 1)

        let recorded = registers.recordUnconfirmedHandbacks()
        let again = registers.recordUnconfirmedHandbacks()
        #expect(recorded == [0, 1])
        #expect(again == [0, 1], "a second call changed it")
        #expect(registers.unconfirmedHandbacks == [0, 1])
        #expect(registers.abandonedHandbacks.isEmpty, "a budget expiring is not a refusal (D33)")
        #expect(registers.unconfirmed(among: [1, 2, 0]) == [1, 0])

        _ = registers.endHandback(ofFan: 0)
        _ = registers.endHandback(ofFan: 1)
        #expect(registers.unconfirmedHandbacks == [0], "fan 0 left before its last restore")
        _ = registers.endHandback(ofFan: 0)
        #expect(registers.unconfirmedHandbacks.isEmpty)
        #expect(registers.unconfirmedHandbacks.isSubset(of: registers.fansMidHandback))
    }

    // MARK: - restoreAbandoned and the read-back

    /// **Mutations:** delete `restoreAbandoned.formUnion(abandoned)` from
    /// `recordRestore(of:abandoned:)`; `fans.filter { handbackUnconfirmed.contains($0) }` in
    /// `abandoned(among:)`. Run: red on each.
    @Test("A fan the restorer gave up on is recorded abandoned, and refused by request")
    func aGivenUpFanIsAbandoned() {
        var registers = restored([0, 1], abandoning: [1])

        #expect(registers.abandonedHandbacks == [1])
        #expect(registers.abandoned(among: [0, 1, 2]) == [1])
        #expect(registers.handbacksOwedAReadBack.isEmpty, "a first refusal is owed nothing")
        #expect(registers.fansMidHandback.isEmpty)
        let elsewhere = registers.recordRestore(of: [2], abandoned: [])
        #expect(elsewhere.isEmpty, "a fan the register never held was owed a read-back")
    }

    /// #291: accepted is not automatic. A fan the register held whose next restore came back
    /// accepted stays refused and is owed a read-back; one refused again is owed none.
    ///
    /// **Mutations:** `let accepted = restoreAbandoned.intersection(fans)` in
    /// `recordRestore(of:abandoned:)`, dropping the subtraction; delete
    /// `handbackAcceptedUnconfirmed.subtract(abandoned)`; delete
    /// `handbackAcceptedUnconfirmed.formUnion(accepted)`. Run: red on each.
    @Test("An abandoned fan's accepted restore is owed a read-back, and a refusal cancels it")
    func anAcceptedRestoreIsOwedAReadBack() {
        var registers = restored([0, 1], abandoning: [0, 1])

        let accepted = registers.recordRestore(of: [0, 1], abandoned: [1])
        #expect(accepted == [0])
        #expect(registers.handbacksOwedAReadBack == [0])
        #expect(registers.abandonedHandbacks == [0, 1], "an accepted write lifted the refusal")

        let refusedAgain = registers.recordRestore(of: [0], abandoned: [0])
        #expect(refusedAgain.isEmpty)
        #expect(registers.handbacksOwedAReadBack.isEmpty, "a renewed refusal is still owed a read")
    }

    /// The read-back lifts the refusal over a fan owed one that reads automatic, and over no
    /// other: not one that reads manual, and not an abandoned fan nothing accepted.
    ///
    /// **Mutations:** `restoreAbandoned.subtract(automatic)` in place of `recovered` in
    /// `liftRefusals(readingAutomatic:)`; delete `restoreAbandoned.subtract(recovered)`; delete
    /// `handbackAcceptedUnconfirmed.subtract(recovered)`. Run: red on each.
    @Test("A read-back lifts only the refusals owed one that read automatic")
    func aReadBackLiftsOnlyOwedRefusals() {
        var registers = restored([0, 1, 2], abandoning: [0, 1, 2])
        _ = registers.recordRestore(of: [0, 1], abandoned: [])

        let recovered = registers.liftRefusals(readingAutomatic: [0, 2])
        #expect(recovered == [0])
        #expect(registers.abandonedHandbacks == [1, 2], "fan 2 was owed no read-back")
        #expect(registers.handbacksOwedAReadBack == [1], "fan 1 read manual and is still owed")
        let twice = registers.liftRefusals(readingAutomatic: [0])
        #expect(twice.isEmpty, "fan 0 lifted twice")
    }

    // MARK: - The sleep seal

    /// **Mutations:** delete `sleepSeal = true` from `seal(generation:)`; drop `sleepSeal,` from
    /// `wake(generation:)`'s guard, so a wake with no seal reports clearing one. Run: red on each.
    @Test("A sleep seals the table and its own wake clears it, once")
    func aSleepSealsAndItsWakeClears() {
        var pairing = Pairing()

        #expect(pairing.isSealed == false)
        let early = pairing.wake(generation: 1)
        let sealing = pairing.seal(generation: 2)
        let sealed = pairing.isSealed
        let own = pairing.wake(generation: 3)
        #expect(early == false, "a wake with no seal cleared one")
        #expect(sealing == .sealed)
        #expect(sealed)
        #expect(own)
        #expect(pairing.isSealed == false)
    }

    /// A seal whose wake was already heard is declined, by a strictly later wake only.
    ///
    /// **Mutations:** drop `guard generation > latestWakeGeneration` from `seal(generation:)`;
    /// move `latestWakeGeneration = max(…)` below `wake(generation:)`'s guard, so a wake with no
    /// seal records nothing; `latestWakeGeneration = generation` in place of the `max`. Run: red
    /// on each.
    @Test("A seal is declined when a later wake was already heard, however the wakes arrived")
    func aSealItsWakeAnsweredIsDeclined() {
        var pairing = Pairing()
        _ = pairing.wake(generation: 5)
        _ = pairing.wake(generation: 3)

        let answered = pairing.seal(generation: 4)
        #expect(answered == .declined, "the latest wake heard is 5")
        #expect(pairing.isSealed == false)
        let newer = pairing.seal(generation: 6)
        #expect(newer == .sealed)
    }

    /// #347: a sleep that meets the seal standing records the larger generation, so neither a
    /// wake older than the newest sleep nor a starved older sleep reopens the table.
    ///
    /// **Mutations:** move `sealGeneration = max(sealGeneration, generation)` below
    /// `guard !sleepSeal`; `sealGeneration = generation` in place of the `max`; `>=` in place of
    /// `>` in `wake(generation:)`'s guard. Run: red on each.
    @Test("A seal opens only to a wake newer than every sleep that met it")
    func aSealOpensOnlyToANewerWake() {
        var pairing = Pairing()

        let first = pairing.seal(generation: 2)
        let newest = pairing.seal(generation: 5)
        let starved = pairing.seal(generation: 3)
        let older = pairing.wake(generation: 4)
        let same = pairing.wake(generation: 5)
        let stillSealed = pairing.isSealed
        let newer = pairing.wake(generation: 6)
        #expect(first == .sealed)
        #expect(newest == .metStanding)
        #expect(starved == .metStanding, "a starved older sleep")
        #expect(older == false, "a wake older than the newest sleep cleared the seal")
        #expect(same == false, "a wake no newer than the newest sleep cleared the seal")
        #expect(stillSealed)
        #expect(newer)
    }
}
