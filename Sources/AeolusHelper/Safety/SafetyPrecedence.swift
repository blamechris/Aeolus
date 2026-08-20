// The engine that makes `docs/SAFETY.md`'s eight rules **compose** rather than merely
// coexist.
//
// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) was written because that
// document specifies eight mechanisms as if they were independent, and they are not:
// several act on the same fan at the same instant, and it never says which one wins. The
// ADR's answer is two classes, and **conflating them is what produced its conflict 4** —
// § 8's ramp cap throttling § 3's emergency, a comfort mechanism rate-limiting a safety
// mechanism while a CPU sits above its ceiling.
//
// So the two classes are two types in this file, and they have deliberately nothing in
// common:
//
// - `SafetyActorLevel` **commands** fans. It is ordered, it is scheduled, and a higher
//   level pre-empts a lower one. It cannot bind a write — nothing on it produces an
//   `AuthorisedFanTarget`, and a level is not evidence of anything.
// - `SafetyConstraint` **binds** every write, with no exceptions, ever. It is not
//   ordered, not scheduled, and never competes: it applies to the write whoever issued
//   it, at whatever level. There is no arrangement of levels under which a constraint
//   yields.
//
// A single enum with eight cases would let either of those become the other by accident.
// That is the shape ADR 0007 diagnosed, and it is why `SafetyArbiter` below takes a level
// and cannot be handed a constraint.

// MARK: - Class one: what commands

/// The actors, highest first, exactly as
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) orders them.
///
/// ## Reading the ordering
///
/// The raw values are the ADR's own numbering — 1 is the highest authority — because every
/// reader of this type will have that document open beside it, and a private numbering
/// would make the two disagree at a glance.
///
/// **`Comparable` runs the other way: greater means outranks.** `a > b` reads "a
/// pre-empts b", which is the only direction the call sites want, and it is the opposite
/// of the raw-value order. That inversion is a trap, so it is stated here, spelled once in
/// `<`, and pinned by `SafetyPrecedenceTests.precedenceRunsOppositeToTheADRNumbering`.
/// Prefer `outranks(_:)` in code: it cannot be misread.
///
/// ## Why it is `Comparable` at all
///
/// Being ordered *is* what it means to be schedulable, and it is the property that
/// distinguishes this class from `SafetyConstraint` — which is deliberately not
/// `Comparable`, because there is no such thing as a constraint that outranks another. A
/// test asserts that asymmetry through the runtime conformance rather than in prose, so
/// making a constraint schedulable turns it red.
enum SafetyActorLevel: Int, Sendable, Hashable, CaseIterable, Comparable {

    /// § 6 and § 7: signal teardown and the panic verb. Nothing pre-empts these, and their
    /// terminal action is the bounds-free restore verb that needs no trusted data at all.
    case panicRestore = 1

    /// § 3: the thermal emergency override. `ThermalEmergency`.
    case thermalEmergency = 2

    /// § 5: the reclamation watchdog. [#126](https://github.com/blamechris/Aeolus/issues/126).
    case reclamationWatchdog = 3

    /// § 4: sleep and wake. [#103](https://github.com/blamechris/Aeolus/issues/103).
    case sleepWake = 4

    /// § 1: the lease's TTL backstop. `LeaseExpirySupervisor`.
    case leaseExpiry = 5

    /// The control loop running a user's curve or fixed target under a live lease.
    ///
    /// **The only level § 8 shapes**, and the only one that writes through
    /// `GovernedFanWriter`. Every level above it writes through `SafetyActorWriter`, which
    /// holds no `RampGovernor` and has no property one could be assigned to.
    case controlLoop = 6

    /// Whether this level pre-empts `other`.
    ///
    /// The spelling to use in code. `>` says the same thing and reads backwards against the
    /// ADR's numbering; this one cannot.
    func outranks(_ other: SafetyActorLevel) -> Bool { self > other }

    /// Greater means **outranks**, so the comparison is the reverse of the raw values.
    static func < (lhs: SafetyActorLevel, rhs: SafetyActorLevel) -> Bool {
        lhs.rawValue > rhs.rawValue
    }
}

extension SafetyActorLevel {

    /// The five levels whose writes bypass § 8 entirely.
    ///
    /// ## Why this is a second type and not a `!= .controlLoop` check
    ///
    /// #125 asks for the exclusion to hold *by construction*, "so that it survives a future
    /// edit by someone who has not read this issue". A runtime guard does not survive that:
    /// it is one `if` somebody can delete while tidying, and deleting it turns nothing red
    /// until an emergency is 22 seconds late on real hardware.
    ///
    /// `SafetyActorWriter` stores one of these instead, so the control loop cannot be given
    /// the ungoverned writer — not "must not be", *cannot be*, with the compiler doing the
    /// refusing. The mapping is not hand-synchronised either:
    /// `SafetyPrecedenceTests.everyLevelButTheControlLoopIsUngoverned` asserts this covers
    /// exactly `SafetyActorLevel.allCases` minus `.controlLoop`, so adding a seventh actor
    /// level and forgetting this type turns the suite red rather than silently governing a
    /// new safety mechanism.
    enum Ungoverned: Sendable, Hashable, CaseIterable {
        case panicRestore
        case thermalEmergency
        case reclamationWatchdog
        case sleepWake
        case leaseExpiry

        /// This level in the full precedence order.
        var level: SafetyActorLevel {
            switch self {
            case .panicRestore: return .panicRestore
            case .thermalEmergency: return .thermalEmergency
            case .reclamationWatchdog: return .reclamationWatchdog
            case .sleepWake: return .sleepWake
            case .leaseExpiry: return .leaseExpiry
            }
        }
    }
}

// MARK: - Class two: what binds

/// What binds **every** write, at every level, with no exceptions and no precedence.
///
/// ## It is a name, not an implementation, and that is the design
///
/// Both constraints already exist and shipped in
/// [#101](https://github.com/blamechris/Aeolus/issues/101) and
/// [#37](https://github.com/blamechris/Aeolus/issues/37). #125 says this engine *consumes*
/// them and **must not restate them**, so nothing here clamps anything: a second clamp is a
/// second place for the project's most consequential arithmetic to drift, and
/// `FanControlEnvelope` is emphatic that there is one clamp in the project and not two.
///
/// What this type does instead is make the class visible, so that a reader of the
/// precedence engine can see there *is* a second class and can find where it is enforced.
/// `evidence` names the type that proves a constraint was applied, and that type is the
/// enforcement: an `AuthorisedFanTarget` can only be minted by
/// `FanEnvelope.commandable` → `CommandableFan.target(for:)`, which runs the plausibility
/// gate and clamps into `[max(F<n>Mn, minimumManualRPM), F<n>Mx]`. Holding one *is* both
/// constraints, discharged. See `FanWriteAuthorisation.swift`.
///
/// ## Not `Comparable`, deliberately
///
/// There is no ordering on this type and none may be added. A constraint that could be
/// outranked is an actor, and an actor that binds writes is the conflation ADR 0007 was
/// written to end. `SafetyPrecedenceTests.constraintsCannotBeScheduled` checks the
/// conformance at runtime, so adding `: Comparable` here — the smallest possible step
/// toward scheduling one — turns the suite red.
enum SafetyConstraint: Sendable, Hashable, CaseIterable {

    /// `docs/SAFETY.md` § 2 and `CLAUDE.md` rule 4: clamp to `[F<n>Mn, F<n>Mx]` as read at
    /// runtime. A configuration may narrow the range and may never widen it.
    case firmwareBounds

    /// `CLAUDE.md` rule 3: never 0 RPM, on any path, from any input, under any
    /// configuration. `FanSafetyLimits.minimumManualRPM` is what makes it hold on firmware
    /// that legitimately declares a minimum of zero.
    case zeroSpeedFloor

    /// The type whose existence proves this constraint was applied to a write.
    ///
    /// One answer for both cases, and that is a fact about the design rather than a
    /// shortcut: `CommandableFan.target(for:)` discharges both in a single step, because
    /// the floor is part of the same clamp as the bounds. Two names for one permit would
    /// suggest a write could satisfy one constraint and not the other.
    var evidence: Any.Type { AuthorisedFanTarget.self }
}

// MARK: - The arbiter

/// Who commands the fans, as a pure function.
///
/// It holds no state, reads nothing, and writes nothing — it takes the level asking and
/// the level already holding, and answers. That shape is the point: the mechanism deciding
/// precedence must be exhaustively testable without hardware, and every interesting
/// question about it is a question about two enum values.
///
/// **It cannot be handed a `SafetyConstraint`.** There is no overload that takes one, and
/// none may be added: a constraint does not compete for the fans, so asking whether it wins
/// is not a question. That absence is class separation made mechanical rather than
/// promised.
enum SafetyArbiter {

    /// Whether `challenger` may take the fans.
    ///
    /// - Parameters:
    ///   - challenger: The level asking to write.
    ///   - incumbent: The level currently commanding the fans, or `nil` when nothing is.
    /// - Returns: `.commands` when the challenger writes, `.preempted` when it does not.
    ///
    /// An equal level **commands**, rather than being refused. Two distinct actors never
    /// share a level in ADR 0007's order, so equality only ever means the same actor
    /// continuing — a thermal emergency re-firing while it is already latched, a watchdog
    /// re-asserting. Refusing that would make every safety actor a one-shot, which is the
    /// opposite of what a supervisor polling on a cycle needs.
    static func ruling(
        for challenger: SafetyActorLevel, incumbent: SafetyActorLevel?
    ) -> SafetyRuling {
        guard let incumbent else { return .commands }
        return challenger.outranks(incumbent) || challenger == incumbent
            ? .commands
            : .preempted(by: incumbent)
    }
}

/// What the arbiter decided.
///
/// It carries no constraints, and that omission is load-bearing: a ruling that could
/// mention them would be a ruling that could relax one. Constraints bind whichever way this
/// goes — see `SafetyConstraint`.
enum SafetyRuling: Sendable, Hashable {

    /// The challenger commands the fans. Its write is still bound by every
    /// `SafetyConstraint`, which it discharges by holding an `AuthorisedFanTarget`.
    case commands

    /// Something with more authority holds them.
    case preempted(by: SafetyActorLevel)

    /// Whether this ruling permits a write. Named rather than pattern-matched at every call
    /// site so that adding a third case cannot silently read as "commands" anywhere.
    var permitsWrite: Bool {
        switch self {
        case .commands: return true
        case .preempted: return false
        }
    }
}
