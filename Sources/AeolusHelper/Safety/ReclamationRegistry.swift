// Who § 5 is watching, under which lease, and the marks that let a registration tell whether its
// lease answer still describes the fan — with every synchronous decision made over them.
// Split from `ReclamationWatchdog.swift` by
// [#128](https://github.com/blamechris/Aeolus/issues/128)'s third pass, when that actor's body
// stood four code lines under `type_body_length`'s error and three issues each needed § 5 code.
//
// It is the first split of that file to move state rather than a type or a function, and it
// widens none. The actor holds its one instance as `private var registry`, so another file can
// construct a `Registry` and reach nothing the actor owns: an instance outside the actor governs
// nothing. What moved is the bookkeeping. Every `await`, every re-fetch after one and every act
// stays on the actor's side, in the order it had.
//
// A value type, so nothing here can suspend, and three rules keep it that way. The two access
// suites hold each, `ReclamationRegistryAccessTests` and `ReclamationWatchdogAccessTests`,
// because the compiler holds only the first half of the first:
//
// - **No `async` member.** The compiler refuses a *mutating* `async` call on an actor's stored
//   struct, but a non-mutating one compiles, and would answer from a copy taken before its own
//   suspension.
// - **No function-typed parameter.** A closure handed in here that reaches the actor's
//   `registry` while it is being mutated compiles, and traps at run time with "Simultaneous
//   accesses": in a root daemon, a trap is the helper dying. So every transition is named.
// - **No whole-value use on the actor's side.** `let before = registry`, an `await`, and a
//   write back loses every transition that ran during the suspension. The actor reaches the
//   registry only through its members.

import FanKit
import Foundation

extension ReclamationWatchdog {

    /// § 5's registry: every held fan's record, the fan the terminal action is giving up, the
    /// lease it last gave each fan up for, and how many times each fan has been released,
    /// registered or given up.
    ///
    /// Every transition is synchronous, closure-free, and named for what `ReclamationWatchdog`
    /// does with it. One on a fan that is not held does nothing, through optional chaining —
    /// which is **not** the actor's re-fetch rule, and is not offered as it. The actor
    /// re-fetches with `isHeld(_:under:)` after every `await` and stops on a record that is gone
    /// or another lease's; what a transition then does to an absent record is what
    /// `held[index]?.x = y` did before this type existed, so no answer changed by moving it.
    struct Registry: Sendable {

        /// Every fan currently off Apple's thermal management, with what this mechanism knows
        /// about it.
        ///
        /// Keyed by index so a second registration finds the entry that is already there
        /// rather than duplicating it — and `manualControlEngaged(_:under:)` then leaves an
        /// entry of the same lease alone, which is what stops a re-registration rearming a
        /// budget. Empty is the ordinary state, and a cycle over an empty registry does nothing
        /// at all — there is no fan pinned, so there is nothing that could be taken back.
        private var held: [Int: HeldFan] = [:]

        /// The fan `finaliseRelease(fanAt:heldUnder:because:)` is giving up right now, and the
        /// lease it is giving it up for. A release notification must not clear that fan's
        /// ledger entry (#346) — see `manualControlReleased(fanAt:)`. One sweep runs at a time,
        /// so it never holds more than one fan. The refusal of a registration under that lease
        /// is `givenUp`'s since #366, which outlives the call.
        private var finalising: [Int: UUID] = [:]

        /// The lease the terminal action last gave each fan up for (#366). Set at its entry beside
        /// `finalising` and, unlike it, never cleared: the same call ends that lease, and an ended
        /// lease is never live again, so a registration under it holds a stale answer whenever it
        /// began and is refused whenever it resumes.
        private var givenUp: [Int: UUID] = [:]

        /// How many times each fan has been released, registered or given up, so a
        /// registration can tell whether its lease answer still describes the fan when it
        /// resumes (#361's review). Bumped by every release notice, every accepted
        /// registration and the terminal action's entry; never reset.
        private var registrations: [Int: UInt64] = [:]

        // MARK: - Queries

        /// Whether no fan is held.
        var isEmpty: Bool { held.isEmpty }

        /// The fans held, under any lease.
        var fans: Set<Int> { Set(held.keys) }

        /// The fans held, sorted: the order `cycle()` examines them in.
        var fansInOrder: [Int] { held.keys.sorted() }

        /// The fan's record, or `nil` when it is not held.
        func record(ofFan index: Int) -> HeldFan? { held[index] }

        /// Whether `index` is held under `lease`. An absent record, or one under another lease,
        /// is `false`: presence is not identity (#357).
        func isHeld(_ index: Int, under lease: UUID) -> Bool { held[index]?.lease == lease }

        /// The fan's registration generation, read before a registration's lease hop and
        /// compared after it.
        func generation(ofFan index: Int) -> UInt64 { registrations[index, default: 0] }

        // MARK: - One examination

        /// Begins one examination of `index`: stamps its record with the fan's generation, before
        /// the control-state read, through `HeldFan.beginExamination(atGeneration:gated:)`, so a
        /// registration under the same lease during the examination is visible to its re-assert
        /// (#381). A same-lease registration keeps the record and moves the generation, so the two
        /// then differ. `gated` is `false` only for an examination past the gate's bound, whose
        /// re-assert then stands down (ADR 0014's A6 amendment). `cycle()` takes the gate before
        /// calling this, never after.
        ///
        /// - Returns: the lease the record was registered under, or `nil` when it is not held.
        mutating func beginExamination(ofFan index: Int, gated: Bool) -> UUID? {
            let generation = registrations[index, default: 0]
            held[index]?.beginExamination(atGeneration: generation, gated: gated)
            return held[index]?.lease
        }

        /// What a re-assert of `index` for `lease` commands now: the record's own target as it
        /// stands, not the one the re-assert was decided on (#381). A report alone moves no
        /// generation, so it is followed.
        ///
        /// - Returns: `nil` when the record is gone or another lease's, when the fan has been
        ///   registered again under `lease` since its examination began: that engagement is
        ///   commanding it; or when the examination runs past the gate's bound, which writes
        ///   nothing away from automatic control.
        func reassertTarget(ofFan index: Int, under lease: UUID) -> CommandedTarget? {
            guard let record = held[index], record.lease == lease, record.examinedGated,
                record.examinedAtGeneration == registrations[index, default: 0]
            else { return nil }
            return record.commanded
        }

        // MARK: - Registration, release and the terminal action

        /// Records a registration of `index` under `lease`, given what the lease core answered
        /// and the generation read before it was asked.
        ///
        /// Refused when `live` is false, when the generation moved while the lease was asked —
        /// a release, a registration or the terminal action's entry — or when the terminal
        /// action has given the fan up for this same lease, while it runs or after (`givenUp`,
        /// #366). An accepted one keeps a record of the same lease, so its counters are not
        /// rearmed, and replaces another lease's with a fresh one
        /// (`HeldFan.registering(_:over:)`); either way the generation moves.
        ///
        /// One under the record's own lease while its episode is in flight
        /// (`HeldFan.episodeInFlight`) is accepted and may not clear the ledger's mark: the
        /// episode decides it, on the next cycle whose primary converges or at the terminal
        /// action, or the record goes first (`HeldFan.episodeInFlight` lists what drops or replaces
        /// it), so a re-apply can neither erase the mark nor postpone the terminal action.
        /// One under any other lease may: one live lease covers a fan, so a newer engagement
        /// holds it.
        ///
        /// - Returns: `.refused`, having touched nothing, or `.accepted`.
        mutating func register(
            _ lease: UUID, fanAt index: Int, live: Bool, since generation: UInt64
        ) -> Registration {
            guard live, registrations[index, default: 0] == generation, givenUp[index] != lease
            else { return .refused }
            let existing = held[index]
            let replacesEndedLease = existing != nil && existing?.lease != lease
            let midEpisode = existing?.lease == lease && existing?.episodeInFlight == true
            held[index] = HeldFan.registering(lease, over: existing)
            registrations[index, default: 0] &+= 1
            return .accepted(replacedEndedLease: replacesEndedLease, mayClearTheMark: !midEpisode)
        }

        /// Forgets a fan that has gone back to automatic control on purpose, and moves its
        /// generation.
        ///
        /// - Returns: whether its ledger entry may be cleared: `false` while the terminal
        ///   action is giving the fan up, whose entry this release must not erase (#346).
        mutating func release(fanAt index: Int) -> Bool {
            held[index] = nil
            registrations[index, default: 0] &+= 1
            return finalising[index] == nil
        }

        /// Forgets a fan § 5 is handing back for `lease`.
        ///
        /// - Returns: `false`, having touched nothing, when the fan's record now belongs to
        ///   another lease (#357) — that lease's engagement holds the fan.
        mutating func forget(fanAt index: Int, ifUnder lease: UUID) -> Bool {
            if let record = held[index], record.lease != lease { return false }
            held[index] = nil
            return true
        }

        /// The terminal action's entry: marks the fan as being given up for `lease`, records
        /// `lease` in `givenUp`, and moves the generation. A registration under `lease` is then
        /// refused whenever it began or resumes (#366), and one under another lease already in
        /// flight resumes refused (#361's review, C3).
        ///
        /// - Returns: `false`, having touched nothing, when the fan's record now belongs to
        ///   another lease (#353).
        mutating func beginFinalising(fanAt index: Int, for lease: UUID) -> Bool {
            if let record = held[index], record.lease != lease { return false }
            finalising[index] = lease
            givenUp[index] = lease
            registrations[index, default: 0] &+= 1
            return true
        }

        /// The terminal action's exit, whichever way it leaves. `givenUp` stays.
        mutating func endFinalising(fanAt index: Int) {
            finalising[index] = nil
        }

        /// Drops every record of `lease`, which the terminal action is revoking whole.
        ///
        /// - Returns: the fans other than `index` that were held under `lease`, sorted.
        mutating func dropLease(_ lease: UUID, sparing index: Int) -> [Int] {
            let siblings = held.filter { $0.key != index && $0.value.lease == lease }.keys.sorted()
            held = held.filter { $0.value.lease != lease }
            return siblings
        }

        // MARK: - One record's counters

        /// Records a commanded target, and resets the secondary dwell: `HeldFan.command(_:)`.
        ///
        /// - Returns: `false` when the fan's record refused `target` (`HeldFan.record(_:)`), and
        ///   `true` otherwise, a fan not held included: there is no record to refuse it.
        mutating func command(_ target: CommandedTarget, ofFan index: Int) -> Bool {
            held[index]?.command(target) ?? true
        }

        /// Records the target a re-assert put on the wire, unless another was reported for the
        /// fan while that write was in flight (#381): the report is newer than the decision, so
        /// the next cycle judges the fan against it. `commanded` only: the dwell is left as it
        /// stands, as it always was on this path. Through `HeldFan.record(_:)`, so the record
        /// refuses a target here exactly as it refuses a report (#395).
        ///
        /// - Returns: `false` when the record refused `target`, and `true` otherwise, including
        ///   when a newer report kept it from being offered.
        mutating func recordReassertedTarget(
            _ target: CommandedTarget, decidedOn decided: CommandedTarget, ofFan index: Int
        ) -> Bool {
            guard held[index]?.commanded == decided else { return true }
            return held[index]?.record(target) ?? true
        }

        /// A cycle read the fan again after cycles that could not.
        mutating func resetReadFailures(ofFan index: Int) {
            held[index]?.consecutiveReadFailures = 0
        }

        /// Counts one more cycle that could not read the fan.
        ///
        /// - Returns: the cycles in a row that could not read it, this one included, or `nil`
        ///   when it is not held.
        mutating func recordReadFailure(ofFan index: Int) -> Int? {
            held[index]?.recordReadFailure()
        }

        /// Judges one readable cycle of the fan: `HeldFan.judge(_:)`.
        ///
        /// - Returns: the judgement, or `nil` when it is not held.
        mutating func judge(_ state: FanControlState, ofFan index: Int) -> Judgement? {
            held[index]?.judge(state)
        }

        /// Books re-assert `attempt` against the fan's budget, at the point of intent and before
        /// the envelope read that suspends.
        ///
        /// Assigned rather than incremented, as it always was: `attempt` is counted from the
        /// record `diverged(_:fanAt:heldUnder:)` re-fetched after its ledger hop.
        mutating func spendReassertAttempt(_ attempt: Int, ofFan index: Int) {
            held[index]?.reassertAttempts = attempt
        }

        /// Gives back an attempt that never reached the firmware:
        /// `HeldFan.refundReassertAttempt()`.
        mutating func refundReassertAttempt(ofFan index: Int) {
            held[index]?.refundReassertAttempt()
        }
    }

    /// What `Registry.register(_:fanAt:live:since:)` did.
    ///
    /// A sibling of `Registry` rather than nested in it, for `Judgement`'s reason: SwiftLint's
    /// `nesting` rule allows one level.
    enum Registration: Sendable, Equatable {
        /// Nothing was recorded and nothing evicted: the lease was not live or did not cover the
        /// fan, the fan was released or registered while the lease was asked, or the terminal
        /// action has given it up for this same lease.
        case refused
        /// Recorded. `replacedEndedLease` is whether the record it replaced was another lease's,
        /// which the actor logs. `mayClearTheMark` is `false` for a registration under the
        /// record's own lease while its episode is in flight, which leaves the ledger's mark to
        /// the episode (#366).
        case accepted(replacedEndedLease: Bool, mayClearTheMark: Bool)
    }
}
