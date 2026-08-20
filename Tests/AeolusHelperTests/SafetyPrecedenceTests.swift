import FanKit
import Testing

@testable import AeolusHelper

/// The precedence engine: two classes, six ordered actors, and the property that keeps them
/// from becoming each other.
///
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md) exists because `docs/SAFETY.md`
/// specifies eight mechanisms as though they were independent. Its conflict 4 — § 8's ramp
/// cap throttling § 3's emergency — is what conflating the two classes produces, so the
/// separation is asserted here as a property of the types rather than described in a doc
/// comment.
@Suite("The safety precedence engine")
struct SafetyPrecedenceTests {

    // MARK: - The order

    @Test("The six actor levels are exactly ADR 0007's, in its numbering")
    func theLevelsAreTheADRs() {
        #expect(SafetyActorLevel.allCases.count == 6)
        #expect(SafetyActorLevel.panicRestore.rawValue == 1)
        #expect(SafetyActorLevel.thermalEmergency.rawValue == 2)
        #expect(SafetyActorLevel.reclamationWatchdog.rawValue == 3)
        #expect(SafetyActorLevel.sleepWake.rawValue == 4)
        #expect(SafetyActorLevel.leaseExpiry.rawValue == 5)
        #expect(SafetyActorLevel.controlLoop.rawValue == 6)
    }

    /// The trap this type's documentation warns about, pinned. `Comparable` runs opposite to
    /// the raw values, because a call site wants `challenger > incumbent` to read
    /// "pre-empts".
    @Test("Precedence runs opposite to the ADR numbering: greater outranks")
    func precedenceRunsOppositeToTheADRNumbering() {
        #expect(SafetyActorLevel.panicRestore > SafetyActorLevel.controlLoop)
        #expect(SafetyActorLevel.panicRestore.rawValue < SafetyActorLevel.controlLoop.rawValue)
        #expect(SafetyActorLevel.panicRestore.outranks(.controlLoop))
        #expect(SafetyActorLevel.controlLoop.outranks(.panicRestore) == false)
    }

    /// #125 asks for this at **every adjacent pair**, not merely at the extremes. A single
    /// top-versus-bottom assertion would pass on an ordering that was wrong in the middle.
    @Test("Every adjacent pair pre-empts downward and not upward")
    func everyAdjacentPairPreempts() {
        let ordered = SafetyActorLevel.allCases.sorted { $0.rawValue < $1.rawValue }
        #expect(ordered.count == 6)

        for (higher, lower) in zip(ordered, ordered.dropFirst()) {
            #expect(higher.outranks(lower), "\(higher) should pre-empt \(lower)")
            #expect(lower.outranks(higher) == false, "\(lower) must not pre-empt \(higher)")

            #expect(SafetyArbiter.ruling(for: higher, incumbent: lower) == .commands)
            #expect(
                SafetyArbiter.ruling(for: lower, incumbent: higher) == .preempted(by: higher))
        }
    }

    @Test("Nothing holding the fans means the challenger commands")
    func anEmptyFieldGrants() {
        for level in SafetyActorLevel.allCases {
            #expect(SafetyArbiter.ruling(for: level, incumbent: nil) == .commands)
        }
    }

    /// A supervisor polling on a cycle re-asserts at its own level constantly. Refusing that
    /// would make every safety actor a one-shot.
    @Test("An actor at the same level continues rather than being refused")
    func anEqualLevelContinues() {
        for level in SafetyActorLevel.allCases {
            #expect(SafetyArbiter.ruling(for: level, incumbent: level) == .commands)
        }
    }

    @Test("A ruling that is not .commands does not permit a write")
    func onlyCommandsPermitsAWrite() {
        #expect(SafetyRuling.commands.permitsWrite)
        #expect(SafetyRuling.preempted(by: .panicRestore).permitsWrite == false)
    }

    // MARK: - The two classes are two classes

    /// **Being ordered is what it means to be schedulable.** An actor level is `Comparable`;
    /// a constraint is not, and must never become one, because a constraint that could be
    /// outranked is an actor and an actor that binds writes is exactly ADR 0007's conflict 4.
    ///
    /// Checked through the runtime conformance rather than asserted in prose, so the
    /// smallest step toward scheduling a constraint — adding `: Comparable` to
    /// `SafetyConstraint` — turns this red.
    @Test("Constraints cannot be scheduled: they are not ordered and an actor level is")
    func constraintsCannotBeScheduled() {
        let constraintIsOrdered = (SafetyConstraint.self as Any.Type) is any Comparable.Type
        let levelIsOrdered = (SafetyActorLevel.self as Any.Type) is any Comparable.Type

        #expect(constraintIsOrdered == false)
        #expect(levelIsOrdered)
    }

    /// The other direction: an actor level binds nothing. What binds a write is the permit,
    /// and `WriteAuthorisationTests` already proves the only mint for one is
    /// `FanEnvelope.commandable`. This pins the two constraints to that single piece of
    /// evidence so a second answer cannot appear beside it.
    @Test("Both constraints are discharged by the same permit, and only by it")
    func constraintsAreDischargedByThePermit() {
        #expect(SafetyConstraint.allCases.count == 2)
        // `ObjectIdentifier` rather than `==` on the metatypes: it is an exact identity
        // comparison, and it is the spelling `#expect` can typecheck without the optional
        // promotion that `Any.Type ==` drags in.
        let permit = ObjectIdentifier(AuthorisedFanTarget.self)
        for constraint in SafetyConstraint.allCases {
            #expect(ObjectIdentifier(constraint.evidence) == permit)
        }
    }

    // MARK: - § 8's exclusion, as a type

    /// The mapping is derived, not hand-kept. Adding a seventh safety actor to
    /// `SafetyActorLevel` without adding it here turns this red, rather than silently
    /// leaving a new safety mechanism unable to use the ungoverned writer — or, worse,
    /// leaving somebody to "fix" that by giving it the governed one.
    @Test("Every level but the control loop is ungoverned")
    func everyLevelButTheControlLoopIsUngoverned() {
        let ungoverned = Set(SafetyActorLevel.Ungoverned.allCases.map(\.level))
        let expected = Set(SafetyActorLevel.allCases).subtracting([.controlLoop])

        #expect(ungoverned == expected)
        #expect(ungoverned.count == 5)
        #expect(ungoverned.contains(.controlLoop) == false)
        // Injective: five distinct cases must not collapse onto four levels.
        #expect(SafetyActorLevel.Ungoverned.allCases.count == ungoverned.count)
    }
}
