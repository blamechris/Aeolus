import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// [#381](https://github.com/blamechris/Aeolus/issues/381)'s registry half, as values: the
/// examination's stamp, the re-assert's re-fetch of its target, and the record that keeps a report
/// newer than the re-assert's decision. The actor's half, each interleaving landed in a real
/// suspension, is `ReclamationReassertViewTests`.
///
/// Every assertion names the mutation it kills, and each was run.
@Suite("§ 5's re-assert target, as a value")
struct ReclamationReassertTargetValueTests {

    private typealias Registry = ReclamationWatchdog<ScriptedControlPlane>.Registry

    private let lease = UUID()
    private let other = UUID()
    private let decided = CommandedTarget(fanIndex: 0, rpm: 2_400)
    private let reported = CommandedTarget(fanIndex: 0, rpm: 2_000)

    /// Fan 0 registered under `lease`, with `decided` commanded on it.
    private func holding(under lease: UUID) -> Registry {
        var registry = Registry()
        _ = registry.register(lease, fanAt: 0, live: true, since: registry.generation(ofFan: 0))
        _ = registry.command(decided, ofFan: 0)
        return registry
    }

    /// A report moves no generation, so the re-fetch follows it; a registration under the same
    /// lease keeps the record and moves the generation, so the re-fetch withholds the target until
    /// the next examination stamps the record again.
    ///
    /// **Mutation (a):** delete the stamp in `HeldFan.beginExamination(atGeneration:gated:)`.
    /// **(b):** drop the generation comparison from `Registry.reassertTarget(ofFan:under:)`.
    /// **(c):** make `Registry.register` restamp the record it keeps with the generation it moves
    /// to. **(d):** drop `record.lease == lease` from `reassertTarget(ofFan:under:)`. **(e):**
    /// delete the call to `HeldFan.beginExamination(atGeneration:gated:)` from
    /// `Registry.beginExamination(ofFan:gated:)`. Run: red on each.
    @Test("The re-assert target follows reports, and is withheld after a same-lease registration")
    func theTargetFollowsReportsAndIsWithheldAfterARegistration() {
        var registry = holding(under: lease)
        let examined = registry.beginExamination(ofFan: 0, gated: true)
        #expect(examined == lease)
        #expect(registry.reassertTarget(ofFan: 0, under: lease) == decided)
        #expect(registry.reassertTarget(ofFan: 0, under: other) == nil, "presence for identity")

        _ = registry.command(reported, ofFan: 0)
        #expect(registry.reassertTarget(ofFan: 0, under: lease) == reported, "a report withheld")

        let generation = registry.generation(ofFan: 0)
        _ = registry.register(lease, fanAt: 0, live: true, since: generation)
        #expect(
            registry.reassertTarget(ofFan: 0, under: lease) == nil,
            "a same-lease registration since the examination began did not withhold the target")

        _ = registry.beginExamination(ofFan: 0, gated: true)
        #expect(registry.reassertTarget(ofFan: 0, under: lease) == reported, "a new examination")
    }

    /// An examination past the gate's bound is stamped ungated, and its re-assert is given no
    /// target: it writes nothing away from automatic control (ADR 0014's A6 amendment). The next
    /// examination under the gate is given one again, and the stamp survives a report.
    ///
    /// **Mutation (a):** drop `record.examinedGated` from `Registry.reassertTarget(ofFan:under:)`.
    /// **(b):** delete `examinedGated = gated` from
    /// `HeldFan.beginExamination(atGeneration:gated:)`. Run: (a) red on the ungated examination;
    /// (b) red on the gated one after it.
    @Test("An examination past the gate's bound is given no target to re-assert")
    func anUngatedExaminationIsGivenNoTarget() {
        var registry = holding(under: lease)
        #expect(registry.beginExamination(ofFan: 0, gated: false) == lease)
        #expect(
            registry.reassertTarget(ofFan: 0, under: lease) == nil,
            "an examination without the gate was given a target to write")
        _ = registry.command(reported, ofFan: 0)
        #expect(registry.reassertTarget(ofFan: 0, under: lease) == nil, "a report ungated it")

        _ = registry.beginExamination(ofFan: 0, gated: true)
        #expect(registry.reassertTarget(ofFan: 0, under: lease) == reported)
    }

    /// What the write returned is recorded over the target it was decided on, which it need not
    /// equal: the writer clamps. A report that arrived during the write is newer, and is kept.
    ///
    /// **Mutation (a):** make `recordReassertedTarget(_:decidedOn:ofFan:)` record unconditionally.
    /// **(b):** make it return `true` having recorded nothing. Run: red on each.
    @Test("A re-asserted target is recorded only over the target it was decided on")
    func aReassertedTargetIsRecordedOnlyOverItsDecision() throws {
        var registry = holding(under: lease)
        let written = CommandedTarget(fanIndex: 0, rpm: 2_350)

        _ = registry.recordReassertedTarget(written, decidedOn: decided, ofFan: 0)
        #expect(try #require(registry.record(ofFan: 0)).commanded == written)

        _ = registry.command(reported, ofFan: 0)
        _ = registry.recordReassertedTarget(written, decidedOn: decided, ofFan: 0)
        #expect(
            try #require(registry.record(ofFan: 0)).commanded == reported,
            "the re-assert's write replaced a report newer than its decision")
    }
}
