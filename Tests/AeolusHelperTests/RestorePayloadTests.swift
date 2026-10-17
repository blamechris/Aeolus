import SMCCore
import Testing

@testable import AeolusHelper

/// What a restore writes (B1's P0, #9): zeros of each restore key's declared size, as the
/// preparation step recorded it, or one zero byte when it recorded none (ADR 0014 D5, D7 and its
/// B1 amendment). Never through `encode`, and no read at restore time: the sizes are the
/// ledger's, from bring-up.
@Suite("A restore's payload", .timeLimit(.minutes(1)))
struct RestorePayloadTests {

    // MARK: - The payload

    /// Zeros, as many as recorded: one, two and four bytes. A key with no recorded size, a fan the
    /// preparation step did not find, or a size no SMC payload carries, is written one zero byte.
    ///
    /// **Mutations, in `PlaneWriteLedger.restorePayload(for:)`:** the wrong size, `count: 1`; a
    /// non-zero byte, `repeating: 1`, and `return [1]` when unknown; no byte when unknown, `return
    /// []`; and the range check dropped. Run: red on the rows each changes.
    @Test(
        "A restore writes zeros of the recorded size, and one zero byte when it is unknown",
        arguments: [
            (RestorePlan.Write.mode(fan: 0), [UInt8](repeating: 0, count: 1)),
            (.mode(fan: 1), [0, 0]),
            (.forceKey, [0, 0, 0, 0]),
            (.mode(fan: 2), [0]),
            (.mode(fan: 3), [0]),
            (.mode(fan: 4), [0]),
            (.mode(fan: 10), [0]),
        ])
    func aRestoreWritesZerosOfTheRecordedSize(write: RestorePlan.Write, payload: [UInt8]) {
        let ledger = PlaneWriteLedger(
            enumerated: [0, 1, 2, 3, 4], forceKey: .present,
            declaredSizes: [
                smcKey("F0Md"): 1, smcKey("F1Md"): 2, smcKey("Ftst"): 4,
                smcKey("F3Md"): 0, smcKey("F4Md"): 33,
            ])

        #expect(ledger.restorePayload(for: write) == payload)
    }

    /// What the preparation step records is what a restore then writes, and a later record
    /// replaces it whole: a size it no longer names is one byte again.
    ///
    /// **Mutation:** in `PlaneWriteLedger.recordPreparation(enumerated:forceKey:declaredSizes:)`,
    /// drop `$0.declaredSizes = declaredSizes`. Run: red on both records.
    @Test("The preparation step's record decides the payload")
    func thePreparationRecordDecidesThePayload() {
        let ledger = PlaneWriteLedger()
        #expect(ledger.restorePayload(for: .forceKey) == [0])

        ledger.recordPreparation(
            enumerated: [0], forceKey: .present,
            declaredSizes: [smcKey("F0Md"): 2, smcKey("Ftst"): 3])
        #expect(ledger.restorePayload(for: .mode(fan: 0)) == [0, 0])
        #expect(ledger.restorePayload(for: .forceKey) == [0, 0, 0])

        ledger.recordPreparation(
            enumerated: [0], forceKey: .unknown, declaredSizes: [smcKey("F0Md"): 2])
        #expect(ledger.restorePayload(for: .forceKey) == [0])
    }

    // MARK: - The scripted preparation step

    /// The scripted step records and reports what its firmware declares: one byte for each
    /// enumerated `F<n>Md`, and for `Ftst` only when it is present. A failed enumeration records
    /// no fan's size.
    ///
    /// **Mutation:** in `ScriptedControlPlane.declaredSizes(enumerated:forceKey:)`, record `Ftst`
    /// whatever its presence. Run: red on the unknown and absent rows.
    @Test(
        "The scripted preparation step records each restore key's declared size",
        arguments: [
            (ForceKeyPresence.present, true, ["F0Md", "F1Md", "Ftst"]),
            (.unknown, true, ["F0Md", "F1Md"]),
            (.absent, true, ["F0Md", "F1Md"]),
            (.present, false, ["Ftst"]),
        ])
    func theScriptedStepRecordsTheSizes(
        forceKey: ForceKeyPresence, enumerates: Bool, recorded: [String]
    ) async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal, 1: .nominal], forceKey: forceKey, prepared: false)
        let enumeration =
            enumerates
            ? ScriptedFanEnumeration()
            : ScriptedFanEnumeration(failure: FakeProviderError(description: "FNum"))

        let report = try #require(await plane.prepareWritePath(enumerating: enumeration))

        let expected = Dictionary(uniqueKeysWithValues: recorded.map { (smcKey($0), 1) })
        #expect(report.declaredSizes == expected)
    }

    /// The composition's line states the sizes, which D8's start-0 check reads with the rest.
    ///
    /// **Mutation:** in `SafetyLog.writePathPrepared(_:)`, drop the sizes' clause. Run: red.
    @Test("The preparation report's line states the declared sizes")
    func thePreparationLineStatesTheSizes() throws {
        let recorded = RecordedLog()

        SafetyLog(recording: { recorded.append($0, $1) }).writePathPrepared(
            WritePathPreparation(
                enumeratedFans: [0, 1], forceKey: .reads(0), machineWideRestore: nil,
                declaredSizes: [smcKey("Ftst"): 1, smcKey("F1Md"): 1, smcKey("F0Md"): 1]))

        let line = try #require(recorded.lines.first)
        #expect(line.contains("declared sizes in bytes [F0Md 1, F1Md 1, Ftst 1]"), "\(line)")
    }
}
