import Foundation
import Testing

@testable import FanKit

/// `ManualControlAvailability.Reason`'s user-facing rendering — #310. Until this file
/// existed, nothing asserted that every reason actually says something, let alone that it
/// says something distinct from its neighbours or that an unrecognised reason never reads
/// as permission.
///
/// **The mechanism, and the mutation that proves it holds.** `userFacingSummary` and
/// `recoveryAdvice` are each an exhaustive `switch` over `Reason` with no `default:` arm, so
/// a `Reason` case added to `ManualControlAvailability.swift` without a matching arm here is
/// a compile error in this file, not a test that silently keeps passing. That was verified
/// directly rather than assumed: with the `.writePathNotBuilt` arm of `userFacingSummary`
/// deleted (`Sources/FanKit/ManualControlAvailability+Recovery.swift`, a five-line cut, the
/// file otherwise untouched), `swift build` failed —
/// `error: switch must be exhaustive; add missing case: '.writePathNotBuilt'` — before this
/// suite, or any suite, ever ran. The file was restored from a backup copy taken before the
/// cut (`cp`, never `git checkout`, per this project's own note on why not), and `swift build`
/// was run again clean to confirm the restore. What follows tests the arms that exist, which
/// the mutation above cannot: content, distinctness, and the direction `.unknown` must fail
/// in.
@Suite("Manual control availability recovery rendering")
struct ManualControlAvailabilityRecoveryTests {

    typealias Reason = ManualControlAvailability.Reason

    /// Every case this build recognises, plus one `.unknown` — the same set
    /// `ManualControlAvailabilityTests.knownWireValuesResolveToKnownCases` exercises, so a
    /// case added there and missed here is visible by comparing the two lists rather than by
    /// this suite silently under-covering.
    static let everyReason: [Reason] = [
        .writePathNotBuilt,
        .boundsImplausible,
        .reclaimedBySystem,
        .leaseHeldByAnotherClient,
        .selfRenewalNotBuilt,
        .releaseInProgress,
        .handbackUnconfirmed,
        .restoreToAutomaticUnconfirmed,
        .restoreToAutomaticFailed,
        .systemSleeping,
        .noThermalTelemetry,
        .supervisorBlind,
        .foreignManualControl,
        .unknown("somethingFromAFutureHelper"),
    ]

    @Test("Every reason renders a non-empty summary", arguments: everyReason)
    func summaryIsNonEmpty(_ reason: Reason) {
        #expect(!reason.userFacingSummary.isEmpty)
    }

    @Test("Every reason renders non-empty advice", arguments: everyReason)
    func adviceIsNonEmpty(_ reason: Reason) {
        #expect(!reason.recoveryAdvice.isEmpty)
    }

    @Test("Every reason's combined description carries both halves", arguments: everyReason)
    func combinedDescriptionCarriesBothHalves(_ reason: Reason) {
        let combined = reason.recoveryDescription
        #expect(combined.contains(reason.userFacingSummary))
        #expect(combined.contains(reason.recoveryAdvice))
    }

    /// Distinct, not merely non-empty: a client cannot tell two reasons apart if their
    /// sentences are the same string, which is exactly the failure #310 found in
    /// `AeolusXPCFault.errorDescription` printing the raw wire value and nothing else — every
    /// reason rendered as "the raw code", differing only in the one substring the old code
    /// already carried.
    @Test("Every known reason's summary is distinct from every other")
    func summariesAreDistinct() {
        let knownReasons = Self.everyReason.filter {
            if case .unknown = $0 { return false }
            return true
        }
        let summaries = knownReasons.map(\.userFacingSummary)
        #expect(Set(summaries).count == summaries.count)
    }

    @Test("Every known reason's advice is distinct from every other")
    func adviceIsDistinct() {
        let knownReasons = Self.everyReason.filter {
            if case .unknown = $0 { return false }
            return true
        }
        let advice = knownReasons.map(\.recoveryAdvice)
        #expect(Set(advice).count == advice.count)
    }

    /// The direction that matters most: `.unknown` must never be mistaken for permission.
    /// `ManualControlAvailability.available` is a different case entirely and nothing under
    /// test here can reach it, but the sentence itself must not *read* as though it could —
    /// a client that renders text without checking which case produced it is exactly the
    /// failure mode `CLAUDE.md` rule 6 exists for.
    @Test(
        "unknown never reads as available",
        arguments: [
            "somethingFromAFutureHelper", "firmwareLocked", "", "available",
        ]
    )
    func unknownNeverReadsAsAvailable(_ raw: String) {
        let reason = Reason.unknown(raw)
        let combined = reason.recoveryDescription
        #expect(!combined.contains("is available"))
        #expect(combined.contains("not available") || combined.contains("not recognise"))
    }

    /// Faithful to `.restoreToAutomaticUnconfirmed`'s own doc comment: the write was issued
    /// and has not been confirmed, which is not the same claim as "the write was accepted and
    /// not confirmed". A sentence that dropped the distinction would tell a user their fan is
    /// probably back on automatic when the firmware may never have taken the write at all.
    @Test("restoreToAutomaticUnconfirmed does not claim the write was accepted")
    func restoreToAutomaticUnconfirmedDoesNotClaimAcceptance() {
        let summary = Reason.restoreToAutomaticUnconfirmed.userFacingSummary
        #expect(summary.contains("may or may not"))
        #expect(!summary.contains("was accepted"))
    }

    /// `.writePathNotBuilt` is today's answer for every fan on every build this project
    /// ships, so its sentence has to be true of the build a normal user actually has — not a
    /// hypothetical future one with a write path.
    @Test("writePathNotBuilt's advice matches what is actually true of this build")
    func writePathNotBuiltIsHonestAboutToday() {
        let advice = Reason.writePathNotBuilt.recoveryAdvice
        #expect(advice.contains("no user action"))
        #expect(!advice.contains("retry"))
    }
}
