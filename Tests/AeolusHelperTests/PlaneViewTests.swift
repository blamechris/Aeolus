import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// A plane's view at § 3's admission **is** the plane (ADR 0012's 2026-10-18 amendment): one
/// scheduler, one connection and, on a plane that can write, one ledger — in both conformers.
///
/// The in-turn properties the lane must not change — U15, D4's epoch, the exit's seal, #305's
/// check and D5's force-key gate — are each decided from the plane's own state. A view with state
/// of its own would decide them twice, so these tests hold the sharing two ways: structurally,
/// every stored property of a view is the plane's by identity, and behaviourally, what one does
/// through the view is seen through the plane and the reverse.
@Suite("A plane's view at an admission is the plane", .timeLimit(.minutes(1)))
struct PlaneViewTests {

    // MARK: - Structure, in both conformers

    /// Whether `view` holds `plane`'s state rather than a copy of it: every reference the same
    /// object, every optional the same case, every struct the same all the way down. A stored
    /// value — a number, a string, an enum with a payload — is state a copy would duplicate, and
    /// it does not share.
    static func shares(_ plane: Any, _ view: Any) -> Bool {
        let left = Mirror(reflecting: plane)
        let right = Mirror(reflecting: view)
        switch (left.displayStyle, right.displayStyle) {
        case (.class, .class):
            return ObjectIdentifier(plane as AnyObject) == ObjectIdentifier(view as AnyObject)
        case (.optional, .optional):
            switch (left.children.first, right.children.first) {
            case (nil, nil): return true
            case (let some?, let other?): return shares(some.value, other.value)
            default: return false
            }
        case (.struct, .struct), (.tuple, .tuple):
            let pairs = zip(left.children, right.children)
            return left.children.count == right.children.count
                && pairs.allSatisfy { $0.label == $1.label && shares($0.value, $1.value) }
        default:
            return false
        }
    }

    /// Every stored property of `plane` but its admission, and whether its view at the lane holds
    /// the same one. A property that is not shared is named.
    static func unshared<Plane: FanControlPlane>(by plane: Plane) -> [String] {
        let view = plane.admitted(at: .thermalCycle)
        return zip(Mirror(reflecting: plane).children, Mirror(reflecting: view).children)
            .filter { $0.0.label != "admission" && !shares($0.0.value, $0.1.value) }
            .map { $0.0.label ?? "?" }
    }

    /// The scanner itself, before it is trusted: a shared reference shares, a copied value does
    /// not, and a struct is judged by what it holds.
    ///
    /// **Mutation:** make `shares(_:_:)`'s `default` return `true`. Run: red here, at the value.
    @Test("The sharing scan tells a shared reference from a copied value")
    func theSharingScanTellsReferenceFromValue() {
        let ledger = PlaneWriteLedger()
        #expect(Self.shares(ledger, ledger))
        #expect(!Self.shares(ledger, PlaneWriteLedger()))
        #expect(!Self.shares(3, 3), "a stored number is state a copy duplicates")
        #expect(Self.shares(Optional<PlaneWriteLedger>.none, Optional<PlaneWriteLedger>.none))
        #expect(
            Self.shares(InertSMCConnection(), InertSMCConnection()), "an empty struct holds nothing"
        )
    }

    /// The production plane's view holds its one scheduler and its one connection, and nothing
    /// of its own but the admission. A stored property added to `SMCFanControlPlane` later is in
    /// this scan — but the plane scanned here is built with no write channel, so a channel B1
    /// adds is not checked by it. The sync that carries B1's channel onto `main`'s lane views scans
    /// a plane built with one, at every lane site, the handback's included (#440's sync notes).
    ///
    /// **Mutation:** add `private var turnsTaken = 0` to `SMCFanControlPlane`. Run: red — the view
    /// holds a counter of its own.
    @Test("The production plane's view holds its scheduler and connection, by identity")
    func theProductionViewIsThePlane() {
        let plane = SMCFanControlPlane(
            scheduler: SMCReadScheduler(provider: GatedSensorProvider()),
            connection: FakeSMCConnection(smc: FakeSMC()))
        #expect(Self.unshared(by: plane).isEmpty, "unshared: \(Self.unshared(by: plane))")
        #expect(Mirror(reflecting: plane).children.count >= 3, "the scan saw no stored property")
        #expect(plane.admitted(at: .thermalCycle).admission == .thermalCycle)
        #expect(plane.admission == .supervisor)
    }

    /// The scripted plane's view holds its one firmware — every fan, every stage, the ledger and
    /// the record of attempts.
    ///
    /// **Mutation:** in `ScriptedControlPlane.admitted(at:)`, build the view over
    /// `ScriptedFirmware(fans: [0: .nominal])`. Run: red here and in the two tests below.
    @Test("The scripted plane's view holds its firmware, by identity")
    func theScriptedViewIsThePlane() {
        let plane = ScriptedControlPlane(fans: [0: .nominal])
        #expect(Self.unshared(by: plane).isEmpty, "unshared: \(Self.unshared(by: plane))")
        #expect(plane.admitted(at: .thermalCycle).ledger === plane.ledger)
    }

    // MARK: - Behaviour

    /// A reading through the production plane's view queues on the plane's own scheduler, at the
    /// lane; one through the plane queues at `.supervisor`.
    ///
    /// **Mutation:** in `SMCFanControlPlane.readSubset`, read at `.supervisor` rather than
    /// `admission.priority`. Run: red — nothing queues in the lane.
    @Test("A read through the production view queues on the plane's scheduler, in the lane")
    func aReadThroughTheProductionViewTakesTheLane() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        let plane = SMCFanControlPlane(scheduler: scheduler, connection: InertSMCConnection())
        let view = plane.admitted(at: .thermalCycle)
        let keys = [smcKey("TPD0")]

        let held = observing { try await scheduler.read(keys: ["H0"], at: .snapshot) }
        await yieldUntil("the held turn to reach the provider") { await provider.turns.count == 1 }
        let throughView = observing { try await view.readCriticalTemperatures(keys) }
        let throughPlane = observing { try await plane.readCriticalTemperatures(keys) }
        let queued = await yieldUntil("both reads to queue") {
            let lane = await scheduler.queuedTurns(at: .thermalCycle)
            let supervisor = await scheduler.queuedTurns(at: .supervisor)
            return lane == 1 && supervisor == 1
        }
        #expect(queued, "the view's read did not queue in the lane of the plane's own scheduler")

        await provider.releaseEveryTurn()
        try await finished("the held read", held)
        try await finished("the view's read", throughView)
        try await finished("the plane's read", throughPlane)
    }

    /// The epoch is one: a restore requested through the view supersedes a first step whose
    /// ticket was taken through the plane, and a restore through the plane supersedes one taken
    /// through the view. Whichever fan the restore covers, as D4 says.
    ///
    /// **Mutation:** the view over a second firmware (see `theScriptedViewIsThePlane`). Run: red —
    /// both steps are admitted.
    @Test("A restore through either supersedes a step through the other")
    func aRestoreThroughEitherSupersedesAStepThroughTheOther() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal, 1: .nominal])
        let view = plane.admitted(at: .thermalCycle)
        let fan = try commandableFan(0, declaring: .nominal)

        plane.beginEngagement(fanAt: 0)
        try await view.restoreToAutomatic(.fan(1))
        await #expect(throws: FanControlPlaneError.superseded) {
            try await plane.engageManualControl(of: fan)
        }

        view.beginEngagement(fanAt: 0)
        try await plane.restoreToAutomatic(.fan(1))
        await #expect(throws: FanControlPlaneError.superseded) {
            try await view.engageManualControl(of: fan)
        }
        #expect(await plane.keyWrites.contains(.mode(fan: 0, value: 1)) == false)
    }

    /// The engaged set and the force-key flag are one: a fan engaged through the plane on the
    /// force-key path is engaged, with the key set, as the view sees it, and a restore through the
    /// view hands it back and clears the key as the plane sees it.
    ///
    /// **Mutation:** the view over a second firmware (see `theScriptedViewIsThePlane`). Run: red —
    /// the view's restore clears nothing the plane holds.
    @Test("The engaged set and the force-key flag are the same through both")
    func theEngagedSetAndTheKeyAreShared() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal], unlock: .heldUntilForced(stepsToYield: 0))
        let view = plane.admitted(at: .thermalCycle)
        let fan = try commandableFan(0, declaring: .nominal)

        #expect(try await plane.ticketedStep(of: fan) == .awaitingYield)
        #expect(try await plane.engageManualControl(of: fan) == .engaged)
        #expect(view.ledger.engagedFans == [0])
        #expect(view.ledger.isForceKeySet)
        #expect(await view.isForceKeySet)

        try await view.restoreToAutomatic(.fan(0))
        #expect(plane.ledger.engagedFans.isEmpty)
        #expect(!plane.ledger.isForceKeySet)
        #expect(await !plane.isForceKeySet, "the view's restore did not clear the plane's key")
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic)
        let admissions = await plane.admittedAttempts.map(\.admission)
        #expect(admissions == [.supervisor, .supervisor, .thermalCycle], "\(admissions)")
    }
}
