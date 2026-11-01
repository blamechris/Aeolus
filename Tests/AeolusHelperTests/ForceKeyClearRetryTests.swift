import Testing

@testable import AeolusHelper

/// #678 through the lease core's restorer: `BoundedFanRestorer`, retrying the keystone's `.fan(n)`
/// restore as `KeystoneRestoreAttempt` issues it. A `Ftst = 0` the firmware refuses is still owed,
/// so the retry writes it again, and the fan is handed back only once the key clear is accepted.
/// A clear refused on every attempt is not a clean hand-back: the fan is abandoned, which puts it
/// in the durable register (`HelperFanRestorer`, ADR 0007's `restoreToAutomaticFailed`).
@Suite("A refused key clear is not a clean hand-back (#678)", .timeLimit(.minutes(1)))
struct ForceKeyClearRetryTests {

    /// Fan 0 engaged under the force key, then `stages` from the second on.
    private static func engaged(
        then stages: [ScriptedControlPlane.Stage]
    ) async throws -> ScriptedControlPlane {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal], stages: [.nominal()] + stages,
            unlock: .heldUntilForced(stepsToYield: 1))
        try await WritePlaneContractTests.engage(0, on: plane)
        #expect(await plane.isForceKeySet, "the engagement wrote no key")
        await plane.advance()
        return plane
    }

    /// The first attempt's `F0Md = 0` lands and its `Ftst = 0` is refused; the firmware then takes
    /// writes again, and the retry writes both.
    ///
    /// **Mutation:** in `PlaneWriteLedger.issueRestore(fanAt:)`, drop the flag when the clear is
    /// issued (`if clearsKey { state.forceKeySet = false }`). Run: red, the retry writing no
    /// `Ftst = 0` and the key left set.
    @Test("A key clear refused once and accepted on the retry hands the fan back, key clear")
    func aClearRefusedOnceIsWrittenAgain() async throws {
        let plane = try await Self.engaged(
            then: [.nominal(forceKeyWrites: .refused(reason: "Ftst refused")), .nominal()])
        let attempting = AdvancingAfterTheFirstAttempt(plane)
        let restorer = BoundedFanRestorer(attempting: attempting, log: LeaseFixture.log)
        let before = await plane.keyWrites.count

        let abandoned = await restorer.restoreToAutomatic(fans: [0], because: .leaseReleased)

        #expect(abandoned.isEmpty)
        #expect(await attempting.attempts == 2)
        #expect(
            Array(await plane.keyWrites.dropFirst(before)) == [
                .mode(fan: 0, value: 0), .forceKey(0), .mode(fan: 0, value: 0), .forceKey(0),
            ])
        #expect(await plane.isForceKeySet == false, "the key was left set")
        #expect(plane.ledger.isForceKeySet == false)
    }

    /// Every attempt's `Ftst = 0` is refused: every attempt throws, the budget is spent, and the
    /// fan is abandoned rather than reported handed back with its mode alone.
    ///
    /// **Mutation:** the one above. Run: red, the second attempt writes `F0Md = 0` alone, succeeds,
    /// and nothing is abandoned.
    @Test("A key clear refused on every attempt abandons the fan")
    func aClearRefusedEveryTimeAbandonsTheFan() async throws {
        let plane = try await Self.engaged(
            then: [.nominal(forceKeyWrites: .refused(reason: "Ftst refused"))])
        let restorer = BoundedFanRestorer(
            attempting: KeystoneOnPlane(plane), log: LeaseFixture.log)
        let before = await plane.keyWrites.count

        let abandoned = await restorer.restoreToAutomatic(fans: [0], because: .leaseReleased)

        #expect(abandoned == [0], "a fan under a key that would not clear was handed back")
        #expect(
            await plane.keyWrites.dropFirst(before).filter { $0 == .forceKey(0) }.count
                == RestoreLimits.attemptBudget)
        #expect(await plane.isForceKeySet)
        #expect(plane.ledger.isForceKeySet, "the clear still owed was dropped")
    }
}

/// The keystone's attempt, `.fan(index)` on the plane, as `KeystoneRestoreAttempt` issues it.
private struct KeystoneOnPlane: FanRestoreAttempting {
    let plane: ScriptedControlPlane
    init(_ plane: ScriptedControlPlane) { self.plane = plane }
    func restoreOnce(fanAt index: Int) async throws {
        try await plane.restoreToAutomatic(.fan(index))
    }
}

/// `KeystoneOnPlane`, moving the firmware to its next stage after the first attempt threw.
private actor AdvancingAfterTheFirstAttempt: FanRestoreAttempting {
    private let plane: ScriptedControlPlane
    private(set) var attempts = 0

    init(_ plane: ScriptedControlPlane) { self.plane = plane }

    func restoreOnce(fanAt index: Int) async throws {
        attempts += 1
        do {
            try await plane.restoreToAutomatic(.fan(index))
        } catch {
            if attempts == 1 { await plane.advance() }
            throw error
        }
    }
}
