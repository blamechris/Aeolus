import Foundation
import Testing

@testable import AeolusHelper

/// Where the fans' examination gate may be named, built and entered, and that the composition's one
/// instance is the one § 5 waits on (ADR 0014's A6 amendment).
///
/// Swift's access control cannot keep another file of the module from naming a type, so this is a
/// census, `RoleCensus`'s (#402), not a list of forbidden shapes. Anything that reaches the gate —
/// a stored property, a parameter, an extension, a conformance that would let a protocol carry
/// its verbs, an alias, a cast — has to write `FanExaminationGate`, and anything that enters it has
/// to write its entry's name. Each statement found is matched against the listed ones and uses one
/// up, so a second construction is unlisted as surely as a new file is. Level 6's file, where
/// `LeaseApplier` holds the gate and enters it for each step, is on both lists since A6's second
/// step (ADR 0014's A6 PR-2 amendment); the composition does not hand it the gate until the next.
///
/// What a restore path naming the gate would do is `ExaminationGateRestoreTests`': it would wait on
/// a holder, and a hand-back held up by a holder is a hand-back that does not happen.
@Suite(
    "The examination gate is named, built and entered only where it is listed",
    .timeLimit(.minutes(1)))
struct ExaminationGateRouteTests {

    private static let gatePath = "AeolusHelper/Safety/FanExaminationGate.swift"
    private static let watchdogPath = "AeolusHelper/Safety/ReclamationWatchdog.swift"
    private static let compositionPath = "AeolusHelper/HelperComposition.swift"
    private static let levelSixPath = "AeolusHelper/Control/LeaseApplier.swift"

    /// Every statement under `Sources/` that may write the gate's type: its declaration and the
    /// extension in its own file; § 5's stored property and init parameter; level 6's stored
    /// property and init parameter; and the composition's stored property and its one construction.
    static let typeListings = [
        RoleCensus.Listing(path: gatePath, statement: "class FanExaminationGate: Sendable"),
        RoleCensus.Listing(path: gatePath, statement: "extension FanExaminationGate"),
        RoleCensus.Listing(path: watchdogPath, statement: "let gate: FanExaminationGate"),
        RoleCensus.Listing(path: watchdogPath, statement: "gate: FanExaminationGate"),
        RoleCensus.Listing(path: levelSixPath, statement: "let gate: FanExaminationGate"),
        RoleCensus.Listing(path: levelSixPath, statement: "gate: FanExaminationGate"),
        RoleCensus.Listing(
            path: compositionPath, statement: "let examinationGate: FanExaminationGate"),
        RoleCensus.Listing(
            path: compositionPath, statement: "let examinationGate = FanExaminationGate"),
    ]

    /// § 5's entry: declared in the gate's file, called once, from `cycle()`.
    static let examinationEntryListings = [
        RoleCensus.Listing(path: gatePath, statement: "func enterForExamination"),
        RoleCensus.Listing(
            path: watchdogPath, statement: "let pass = await gate.enterForExamination"),
    ]

    /// Level 6's entry: declared, and called once, from `LeaseApplier.step`.
    static let stepEntryListings = [
        RoleCensus.Listing(path: gatePath, statement: "func enterForStep"),
        RoleCensus.Listing(path: levelSixPath, statement: "let pass = await gate.enterForStep"),
    ]

    private static func expectOnlyListed(
        _ name: String, _ listed: [RoleCensus.Listing], what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let verdict = RoleCensus.reconcile(
            try RoleCensus.occurrences(roles: [name]), with: listed)
        #expect(
            verdict.unlisted.isEmpty,
            """
            `\(name)` is written where it is not listed:\(Self.lines(verdict.unlisted))
            \(what)
            """, sourceLocation: sourceLocation)
        #expect(
            verdict.missing.isEmpty,
            """
            Listed and not found:\(Self.lines(verdict.missing))
            Either the gate is no longer reached there, or the statement is spelled another way; \
            the list is this test's to be told about.
            """, sourceLocation: sourceLocation)
    }

    /// **Mutation (a):** give `EngagementDriver` a stored
    /// `private let gate: FanExaminationGate? = nil`. Run: red, at
    /// `Sources/AeolusHelper/Safety/EngagementDriver.swift`. **(b):** hand § 5 a second gate in
    /// `HelperComposition.init` — `gate: FanExaminationGate(clock: clock, log: safetyLog)`. Run:
    /// red on the second construction, and in `theComposedWatchdogWaitsOnTheComposedGate`.
    /// **(c):** `typealias ExaminationGate = FanExaminationGate` in `SafetyWriters.swift`. Run:
    /// red.
    @Test("The gate's type is named only in its own file, § 5's, level 6's and the composition's")
    func theGateIsNamedOnlyWhereListed() throws {
        try Self.expectOnlyListed(
            "FanExaminationGate", Self.typeListings,
            what: """
                The engagement driver, the writers, the plane, the lease core, § 3 and every \
                restore path must never reach the gate: § 5's re-engage runs through the driver \
                while § 5 holds it, and a restore that waited on a holder would not happen.
                """)
    }

    /// **Mutation:** add `func probe(_ gate: FanExaminationGate) async {
    /// gate.leave(await gate.enterForExamination(fanAt: 0)) }` to `ThermalEmergency`. Run: red at
    /// `ThermalEmergency.swift`, here and in `theGateIsNamedOnlyWhereListed`. **Mutation:** in
    /// `LeaseApplier.undo`, enter the fan's gate around the hand-back (`guard let pass = await
    /// gate.enterForStep(fanAt: index)`). Run: red here, on the second `enterForStep`.
    @Test("Only § 5's cycle enters the gate as an examination, and only level 6's step as a step")
    func onlySectionFiveEntersTheGate() throws {
        try Self.expectOnlyListed(
            "enterForExamination", Self.examinationEntryListings,
            what: "Only § 5's cycle examines; a second examiner is a second § 5.")
        try Self.expectOnlyListed(
            "enterForStep", Self.stepEntryListings,
            what: """
                Level 6's step is the only party that steps: its undo, like every restore, never \
                takes the gate.
                """)
    }

    /// The composition's one gate is the one § 5 waits on: a step pass held on
    /// `HelperComposition.examinationGate` makes the composed § 5 wait, and leaving it lets the
    /// sweep finish.
    ///
    /// **Mutation:** hand § 5 a second gate in `HelperComposition.init`, as above. Run: red on the
    /// wait.
    @Test("The composed § 5 waits on the composition's gate")
    func theComposedWatchdogWaitsOnTheComposedGate() async throws {
        let helper = HelperRestorerTests.composed()
        await helper.bindSafetyRegistries()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        try await HelperRestorerTests.engage(fan: 0, in: helper, under: lease.id)
        let held = try #require(await helper.examinationGate.enterForStep(fanAt: 0))

        let sweep = observing { await helper.reclamationWatchdog.cycle() }
        #expect(
            await yieldUntil("the composed § 5 to wait on the composed gate") {
                helper.examinationGate.waiting(onFan: 0) == 1
            })
        helper.examinationGate.leave(held)
        try await finished("the composed sweep", sweep)
        #expect(helper.examinationGate.isIdle)
    }

    /// **Nothing is observable on a shipped build.** Over a plane that answers `.notBuilt`, no
    /// lease is granted, so § 5 registers nothing and its cycle returns before it reaches the
    /// gate: the snapshot, a grant attempt, § 3's cycle and § 5's leave the gate never entered.
    ///
    /// **Mutation:** in `cycle()`, enter fan 0's gate before the empty-registry check —
    /// `gate.leave(await gate.enterForExamination(fanAt: 0))` above `guard !registry.isEmpty`.
    /// Run: red on the entrant count.
    @Test("On a build that cannot write, the gate is never entered")
    func onANotBuiltPlaneTheGateIsNeverEntered() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = HelperComposition(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        #expect(helper.plane.writeCapability == .notBuilt, "this test is vacuous on a .built plane")
        await helper.bindSafetyRegistries()

        _ = try await helper.authority.snapshot()
        await #expect(throws: (any Error).self, "a lease was granted on .notBuilt") {
            try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        await helper.thermalEmergency.cycle()
        await helper.reclamationWatchdog.cycle()

        #expect(await helper.reclamationWatchdog.fansUnderManualControl.isEmpty)
        #expect(helper.examinationGate.entrants == 0, "the gate was entered on a shipped build")
        #expect(helper.examinationGate.isIdle)
    }

    private static func lines(_ items: [some CustomStringConvertible]) -> String {
        items.map { "\n  \($0)" }.joined()
    }
}
