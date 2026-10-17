import Testing

@testable import AeolusHelper

// The ledger's engagement ticket and its exit seal (ADR 0014's #410 ticket-and-seal amendment): an
// extension of `PlaneWriteLedgerTests`, so the rows stay in that suite, in a file of their own so
// the suite's first file stays the sets and the first-step rule it was.
extension PlaneWriteLedgerTests {

    /// A ledger with two enumerated fans and a present force key: what every row below starts from.
    private static func prepared() -> PlaneWriteLedger {
        PlaneWriteLedger(enumerated: [0, 1], forceKey: .present)
    }

    /// The step's admission as a value, `nil` when it was refused: so a refusal is red at the row's
    /// own `#expect`, rather than thrown out of the test at its declaration.
    private static func admitted(
        _ ledger: PlaneWriteLedger, fanAt index: Int
    ) -> PlaneWriteLedger.Admission? {
        do {
            return try ledger.admitStep(fanAt: index)
        } catch {
            return nil
        }
    }

    /// What the preparation step can have recorded: a fan set and a present key, no fan set and an
    /// unknown key, and a key recorded absent.
    private static let planCases: [(Set<Int>?, ForceKeyPresence)] = [
        ([0, 1], .present), (nil, .unknown), ([0], .absent),
    ]

    // MARK: - The ticket (item 1a)

    /// A ticket taken under the current epoch admits the engagement's first step, and the steps
    /// after it continue under the record the admission made.
    ///
    /// The positive row, which the refusals below need beside them: a ledger that refused every
    /// first step would pass all of them. **Mutation:** make `admitStep(fanAt:)` throw
    /// `.superseded` for every step with no in-progress record. Run: red, at the `.first`.
    @Test("A ticket under the current epoch admits the first step")
    func aCurrentTicketAdmitsTheFirstStep() throws {
        let ledger = Self.prepared()
        ledger.beginEngagement(fanAt: 0)

        #expect(Self.admitted(ledger, fanAt: 0) == .first)
        #expect(Self.admitted(ledger, fanAt: 0) == .continuing)
        #expect(ledger.isCurrent(fanAt: 0))
    }

    /// Any restore requested between the ticket and the admission supersedes the first step, and
    /// the refusal records nothing: a second step with no fresh ticket is refused as well, rather
    /// than admitted as a continuation of a record the refusal left.
    ///
    /// **Mutation:** in `admitStep(fanAt:)`, admit `.first` whenever a ticket is present, whatever
    /// epoch it holds ("compare against nothing"). Run: red, at the first `#expect(throws:)`, for
    /// each scope.
    @Test(
        "A restore between the ticket and the admission supersedes the first step",
        arguments: [FanRestoreScope.fan(0), .fan(1), .everyFan])
    func aRestoreAfterTheTicketSupersedesTheFirstStep(_ scope: FanRestoreScope) throws {
        let ledger = Self.prepared()
        ledger.beginEngagement(fanAt: 0)
        ledger.restoreRequested(scope)

        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitStep(fanAt: 0) }
        #expect(ledger.isCurrent(fanAt: 0) == false, "the refused step recorded an engagement")
        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitStep(fanAt: 0) }
    }

    /// A first step with no ticket is refused, having recorded nothing: an engagement that never
    /// asked the plane for its epoch cannot prove its entitlement came after every restore.
    ///
    /// **Mutation:** in `admitStep(fanAt:)`, admit a step with no ticket by recording the epoch at
    /// admission — the rule before the #410 ticket-and-seal amendment. Run: red, at the first
    /// `#expect(throws:)`.
    @Test("A first step with no ticket is refused")
    func aStepWithNoTicketIsRefused() throws {
        let ledger = Self.prepared()

        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitStep(fanAt: 0) }
        #expect(ledger.isCurrent(fanAt: 0) == false, "the refused step recorded an engagement")
    }

    /// A ticket clears the stale record an earlier engagement of the same fan left behind — its
    /// undo is a restore — so a fresh engagement is admitted at its first step, with no retry.
    ///
    /// **Mutation:** in `beginEngagement(fanAt:)`, skip the clear of `inProgress[index]`. Run:
    /// red, at the second `.first`: the fresh step meets the stale record and is superseded.
    @Test("A ticket clears the record an earlier engagement left")
    func aTicketClearsAStaleRecord() throws {
        let ledger = Self.prepared()
        ledger.beginEngagement(fanAt: 0)
        #expect(try ledger.admitStep(fanAt: 0) == .first)
        ledger.restoreRequested(.fan(0))

        ledger.beginEngagement(fanAt: 0)

        #expect(Self.admitted(ledger, fanAt: 0) == .first, "the stale record superseded it")
    }

    /// A restore requested **before** the ticket was taken does not supersede the engagement: the
    /// ticket is the epoch at the moment the engagement began, not an older one.
    ///
    /// **Mutation:** in `beginEngagement(fanAt:)`, set the ticket to `0` rather than the epoch.
    /// Run: red, at the `.first`.
    @Test("A restore before the ticket does not supersede the engagement")
    func aRestoreBeforeTheTicketDoesNotSupersede() throws {
        let ledger = Self.prepared()
        ledger.restoreRequested(.everyFan)
        ledger.beginEngagement(fanAt: 0)

        #expect(Self.admitted(ledger, fanAt: 0) == .first)
    }

    /// A ticket is consumed by the first step it admits: a later first step of the same fan, with
    /// no ticket of its own and no restore requested since, is refused. So a ticket cannot be
    /// reused by an engagement that never asked the plane for its epoch.
    ///
    /// **Mutation:** in `admitStep(fanAt:)`, read the ticket (`state.tickets[index]`) instead of
    /// removing it. Run: red, at the `#expect(throws:)`: the old ticket is still current.
    @Test("A ticket admits one first step and no more")
    func aTicketIsSingleUse() throws {
        let ledger = Self.prepared()
        ledger.beginEngagement(fanAt: 0)
        #expect(Self.admitted(ledger, fanAt: 0) == .first)
        ledger.recordEngaged(fanAt: 0)

        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitStep(fanAt: 0) }
    }

    /// Every restore moves the epoch, the exit's included: the seal adds to supersession rather
    /// than replacing it, because D3 step 3's in-turn re-check (`isCurrent(fanAt:)`) and the
    /// force-key rule read the epoch alone (ADR 0014's #410 ticket-and-seal amendment).
    ///
    /// **Mutation:** in `restoreRequested(_:)`, skip the epoch bump for `.forExit`. Run: red, at
    /// the `isCurrent` assertion, for the `.forExit` row only.
    @Test(
        "Every restore moves the epoch", arguments: [FanRestoreScope.fan(0), .everyFan, .forExit])
    func everyRestoreMovesTheEpoch(_ scope: FanRestoreScope) throws {
        let ledger = Self.prepared()
        ledger.beginEngagement(fanAt: 0)
        #expect(Self.admitted(ledger, fanAt: 0) == .first)

        ledger.restoreRequested(scope)

        #expect(ledger.isCurrent(fanAt: 0) == false, "the restore left the engagement current")
    }

    // MARK: - The exit seal (item 1)

    /// **The row that keeps the seal's step half honest.** After `.forExit`, an engagement that
    /// takes its ticket — under the current epoch, so the ticket alone would admit it — is still
    /// refused at its first step, and records nothing.
    ///
    /// **Mutation:** delete the seal check at the top of `admitStep(fanAt:)`. Run: red, at the
    /// `#expect(throws:)`: the ticket is current and the step is admitted `.first`.
    @Test("After the exit's restore is requested, a ticketed first step is refused")
    func aSealedLedgerRefusesATicketedStep() throws {
        let ledger = Self.prepared()
        ledger.restoreRequested(.forExit)
        ledger.beginEngagement(fanAt: 0)

        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitStep(fanAt: 0) }
        #expect(ledger.isCurrent(fanAt: 0) == false, "the sealed step recorded an engagement")
    }

    /// After `.forExit`, a target command is refused at its admission.
    ///
    /// **Mutation:** make `admitCommand()` check nothing. Run: red, at the `#expect(throws:)`.
    @Test("After the exit's restore is requested, a command is refused")
    func aSealedLedgerRefusesACommand() throws {
        let ledger = Self.prepared()
        try ledger.admitCommand()

        ledger.restoreRequested(.forExit)

        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitCommand() }
    }

    /// The seal outlives every later restore, and never refuses one: a `.fan(n)` and an `.everyFan`
    /// after it still plan their whole writes, and a step and a command are still refused after
    /// them.
    ///
    /// **Mutation:** clear the seal in `restoreRequested(_:)` for any scope but `.forExit`. Run:
    /// red, at the step's and the command's `#expect(throws:)`.
    @Test("Nothing unseals, and a restore after the seal still plans every write")
    func theSealOutlivesEveryLaterRestore() throws {
        let ledger = Self.prepared()
        ledger.beginEngagement(fanAt: 0)
        #expect(try ledger.admitStep(fanAt: 0) == .first)
        ledger.recordForceKeyAccepted()
        ledger.recordEngaged(fanAt: 0)
        ledger.restoreRequested(.forExit)

        ledger.restoreRequested(.fan(0))
        #expect(ledger.plan(for: .fan(0)).writes == [.mode(fan: 0), .forceKey])
        ledger.restoreRequested(.everyFan)
        #expect(ledger.plan(for: .everyFan).writes == [.mode(fan: 0), .mode(fan: 1), .forceKey])

        ledger.beginEngagement(fanAt: 1)
        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitStep(fanAt: 1) }
        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitCommand() }
    }

    /// `.fan(n)` and `.everyFan` move the epoch and seal nothing: a fresh engagement after either
    /// is admitted, and a command is too.
    ///
    /// **Mutation:** in `restoreRequested(_:)`, seal on `.everyFan` as well. Run: red, for the
    /// `.everyFan` argument, at the `.first` and at `admitCommand()`.
    @Test(
        "A per-fan or machine-wide restore seals nothing",
        arguments: [FanRestoreScope.fan(0), .everyFan])
    func anOrdinaryRestoreSealsNothing(_ scope: FanRestoreScope) throws {
        let ledger = Self.prepared()
        ledger.restoreRequested(scope)
        ledger.beginEngagement(fanAt: 0)

        #expect(Self.admitted(ledger, fanAt: 0) == .first)
        #expect(throws: Never.self) { try ledger.admitCommand() }
    }

    /// The exit's plan is the machine-wide restore's, whatever the ledger knows: every enumerated
    /// and touched fan, then the force key unless it is recorded absent, and the same report of an
    /// unknown fan set.
    ///
    /// **Mutation:** in `plan(for:)`, drop the force key from `.forExit`'s plan. Run: red, for the
    /// present and the unknown key.
    @Test("The exit's plan is the machine-wide restore's", arguments: planCases)
    func theExitsPlanIsTheMachineWideRestores(
        _ enumerated: Set<Int>?, _ forceKey: ForceKeyPresence
    ) throws {
        let ledgers = [FanRestoreScope.forExit, .everyFan].map { (scope: FanRestoreScope) in
            let ledger = PlaneWriteLedger(enumerated: enumerated, forceKey: forceKey)
            ledger.recordModeWriteIssued(fanAt: 2)
            ledger.restoreRequested(scope)
            return ledger.plan(for: scope)
        }

        #expect(ledgers[0] == ledgers[1], "the exit's plan differs from the machine-wide one")
        #expect(ledgers[0].writes.contains(.mode(fan: 2)), "the touched fan was not written")
    }
}
