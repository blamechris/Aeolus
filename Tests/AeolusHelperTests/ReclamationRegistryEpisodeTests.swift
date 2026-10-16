import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// #366's half of `ReclamationRegistryTests`: the episode `HeldFan.judge(_:)` opens and closes, the
/// answer a registration gives about the ledger's mark, and the lease the terminal action gave a
/// fan up for, as values. Kept out of `ReclamationRegistryTests.swift`, which would otherwise
/// cross SwiftLint's `file_length` and `type_body_length` warnings, as an extension of the same
/// suite. `ReclamationEpisodeMarkTests` drives the same rules through the actor.
///
/// Every assertion names the mutation it kills, and each was run.
extension ReclamationRegistryTests {

    // MARK: - Registration

    /// #366: a registration under the record's own lease while its episode is in flight is
    /// accepted, keeps the record and its episode, and may not clear the mark. One under a newer
    /// lease over the same record may: one live lease covers a fan, so a newer engagement holds it.
    ///
    /// **Mutation (a):** make `register` answer `mayClearTheMark: true` always. Run: red.
    /// **Mutation (b):** drop the lease half of `midEpisode`, leaving `existing?.episodeInFlight
    /// == true`. Run: red on the newer lease's answer.
    @Test("A same-lease registration mid-episode may not clear the mark, and a newer lease's may")
    func aSameLeaseRegistrationMidEpisodeMayNotClearTheMark() throws {
        var registry = holding(under: lease)
        registry.command(target, ofFan: 0)
        let judged = registry.judge(unreadable, ofFan: 0)

        let reapply = registry.register(
            lease, fanAt: 0, live: true, since: registry.generation(ofFan: 0))
        let kept = try #require(registry.record(ofFan: 0))
        #expect(judged == .diverged(.targetUnreadable(reason: "F0Tg: no answer")))
        #expect(reapply == .accepted(replacedEndedLease: false, mayClearTheMark: false))
        #expect(kept.episodeInFlight, "a same-lease registration closed the episode")
        #expect(kept.commanded == target)

        let newer = registry.register(
            other, fanAt: 0, live: true, since: registry.generation(ofFan: 0))
        let fresh = try #require(registry.record(ofFan: 0))
        #expect(newer == .accepted(replacedEndedLease: true, mayClearTheMark: true))
        #expect(fresh.episodeInFlight == false, "a newer lease inherited the ended lease's episode")
    }

    // MARK: - The terminal action

    /// #366: the lease the terminal action gave a fan up for stays refused once the call has
    /// returned and `finalising` is clear, whatever notice was sent or lost; another lease is
    /// accepted, and may clear the mark.
    ///
    /// **Mutation (a):** clear `givenUp[index]` in `endFinalising(fanAt:)`. Run: red.
    /// **Mutation (b):** put `finalising[index] != lease` back in place of `givenUp[index] !=
    /// lease` in `register`'s guard. Run: red.
    @Test("The lease the terminal action gave a fan up for stays refused after it returns")
    func aGivenUpLeaseStaysRefusedAfterTheTerminalAction() {
        var registry = holding(under: lease)
        let entered = registry.beginFinalising(fanAt: 0, for: lease)
        let siblings = registry.dropLease(lease, sparing: 0)
        registry.endFinalising(fanAt: 0)
        let generation = registry.generation(ofFan: 0)

        let sameLease = registry.register(lease, fanAt: 0, live: true, since: generation)
        #expect(entered)
        #expect(siblings.isEmpty)
        #expect(sameLease == .refused, "the lease given up was accepted once the call returned")
        #expect(registry.fans.isEmpty)
        #expect(registry.generation(ofFan: 0) == generation, "a refusal moved the generation")

        let another = registry.register(other, fanAt: 0, live: true, since: generation)
        #expect(another == .accepted(replacedEndedLease: false, mayClearTheMark: true))
        #expect(registry.isHeld(0, under: other))
    }

    // MARK: - One readable cycle

    /// #366: the episode opens on every `.diverged` — a commanded fan's first, and an uncommanded
    /// fan's once its grace runs out — and never on `.graced`. Derived per cycle, so it holds at
    /// every value of `blindCyclesBeforeDivergence`.
    ///
    /// **Mutation (a):** delete `episodeInFlight = true` from `HeldFan.judge(_:)`. Run: red.
    /// **Mutation (b):** set it at the top of the primary branch, so `.graced` opens it too.
    /// Run: red. **Mutation (c):** set it only when `commanded` is not `nil`. Run: red on the
    /// grace-exhausted cycle.
    @Test("Every divergence outside the grace opens the episode, and the grace does not")
    func everyDivergenceOutsideTheGraceOpensTheEpisode() {
        var commanded = Watchdog.HeldFan(lease: lease)
        commanded.command(target)
        let diverged = commanded.judge(unreadable)
        #expect(diverged == .diverged(.targetUnreadable(reason: "F0Tg: no answer")))
        #expect(commanded.episodeInFlight, "a commanded fan's divergence opened no episode")

        var uncommanded = Watchdog.HeldFan(lease: lease)
        for cycle in 1...ReclamationLimits.blindCyclesBeforeDivergence {
            let judged = uncommanded.judge(unreadable)
            let graced = cycle < ReclamationLimits.blindCyclesBeforeDivergence
            #expect(
                uncommanded.episodeInFlight == !graced,
                "cycle \(cycle), \(judged): the episode opens exactly when the grace runs out")
        }
    }

    /// #366: the next cycle whose primary converges closes the episode, whatever the secondary
    /// says — the cycle the actor clears the mark on.
    ///
    /// **Mutation (a):** delete `episodeInFlight = false` from `HeldFan.judge(_:)`. Run: red on
    /// both. **Mutation (b):** move it to the converged tail, after the shortfall's return. Run:
    /// red on `.short`.
    @Test("A cycle whose primary converges closes the episode, short or converged")
    func aConvergedPrimaryClosesTheEpisode() {
        for reading in [short, converged] {
            var fan = Watchdog.HeldFan(lease: lease)
            fan.command(target)
            _ = fan.judge(unreadable)
            let opened = fan.episodeInFlight

            let judged = fan.judge(reading)
            #expect(opened, "the divergence opened no episode to close")
            #expect(fan.episodeInFlight == false, "\(judged) left the episode open")
        }
    }
}
