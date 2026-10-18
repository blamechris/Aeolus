import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Every plane the composed graph stores is at `.supervisor`, except § 3's (ADR 0012's 2026-10-18
/// amendment) — writers included.
///
/// `ThermalCycleLaneRoutingTests` drives each mechanism's **reads** and reads off the admission
/// each call came through. A writer is only seen there when its mechanism writes, and several
/// write only in a scenario of their own: § 5's writer when it re-asserts, § 6's `panic:` writer
/// when a pass ends machine-wide, the teardown's when the process ends. So the writes are held two
/// ways here: **structurally**, every `ScriptedControlPlane` reachable through the graph's stored
/// properties, found wherever it is stored and named by the path it was reached by; and
/// **behaviourally**, § 4's sleep and the signal teardown driven, each restoring at `.supervisor`.
///
/// `ConnectionHealth`'s recovery plane is the one plane neither can see: it is captured by the
/// pump's task, not stored, and a recycle is a supervisor turn whatever view asks for it
/// (`FanControlPlane.admitted(at:)`), so no call could tell. The count of lane namings in
/// `HelperComposition.swift` (`ThermalCycleLaneTripwireTests`) is what holds it.
@Suite("Every stored plane is at supervisor but § 3's", .timeLimit(.minutes(1)))
struct ThermalCycleLaneWriterTests {

    // MARK: - The census

    /// Every `ScriptedControlPlane` reachable from `root` through stored properties, with the
    /// admissions it is stored at.
    ///
    /// Each is named from the **nearest object that stores it** — the type, generic arguments
    /// dropped, then the labels down to the plane (`ThermalEmergency.writer.plane`) — so a name
    /// does not depend on which route the walk took to that object, and a type stored twice is
    /// one name with each admission it is stored at. Each object is entered once, so a cycle in
    /// the graph ends.
    static func planes(reachableFrom root: Any) -> [String: Set<PlaneAdmission>] {
        var seen: Set<ObjectIdentifier> = []
        var found: [String: Set<PlaneAdmission>] = [:]
        walk(root, path: "", seen: &seen, found: &found)
        return found
    }

    private static func walk(
        _ value: Any, path: String, seen: inout Set<ObjectIdentifier>,
        found: inout [String: Set<PlaneAdmission>]
    ) {
        if let plane = value as? ScriptedControlPlane {
            found[path, default: []].insert(plane.admission)
            return
        }
        let mirror = Mirror(reflecting: value)
        var path = path
        if mirror.displayStyle == .class {
            guard seen.insert(ObjectIdentifier(value as AnyObject)).inserted else { return }
            let name = String(describing: type(of: value))
            path = String(name.prefix { $0 != "<" })
        }
        var level: Mirror? = mirror
        while let current = level {
            for (index, child) in current.children.enumerated() {
                walk(
                    child.value, path: path + "." + (child.label ?? "\(index)"), seen: &seen,
                    found: &found)
            }
            level = current.superclassMirror
        }
    }

    /// The walk itself, before it is trusted: it finds a plane inside a struct, an optional, an
    /// array and an actor, names it by its path, and enters a shared object once.
    ///
    /// **Mutation:** make `walk` return without descending into a class. Run: red here, at the
    /// plane inside the actor.
    @Test("The census finds a plane wherever it is stored")
    func theCensusFindsAPlaneWhereverItIsStored() {
        struct Holder {
            let writer: SafetyActorWriter<ScriptedControlPlane>
            let spare: ScriptedControlPlane?
            let many: [ScriptedControlPlane]
        }
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let holder = Holder(
            writer: SafetyActorWriter(plane: plane.admitted(at: .thermalCycle), level: .sleepWake),
            spare: plane, many: [plane])
        let shared = PlaneHoldingActor(plane: plane)

        let found = Self.planes(reachableFrom: [Any](arrayLiteral: holder, shared, shared))
        #expect(
            found == [
                ".0.writer.plane": [.thermalCycle], ".0.spare": [.supervisor],
                ".0.many.0": [.supervisor], "PlaneHoldingActor.plane": [.supervisor],
            ], "\(found)")
    }

    /// The composed graph, bound as bring-up binds it: every plane it stores is at `.supervisor`
    /// but § 3's three views — its telemetry's, its writer's and its read-back's — and the
    /// restorer's lane view for § 3's revocation.
    ///
    /// **Mutation:** in `HelperComposition.init`, build § 5's `reclamationWriter` over
    /// `plane.admitted(at: .thermalCycle)`. Run: red, naming § 5's writer and its driver's.
    /// **Mutation:** the same for § 4's writer, `SafetyActorWriter(plane: …, level: .sleepWake)`.
    /// Run: red, naming the power responder's.
    /// **Mutation:** the same for the signal teardown's `restore:` writer. Run: red.
    /// **Mutation:** the same for § 6's `panic:` writer. Run: red, naming reconciliation's.
    @Test("Every plane the composed graph stores is at supervisor but § 3's")
    func everyStoredPlaneIsAtSupervisorButSectionThrees() async throws {
        let firmware = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let helper = Self.helper(over: firmware)
        await helper.bindSafetyRegistries()

        let found = Self.planes(reachableFrom: helper)
        let lane = Set(found.filter { $0.value.contains(.thermalCycle) }.keys)
        #expect(found.count > 10, "the census found \(found.count) planes: \(found)")
        #expect(
            lane == [
                "HelperFanRestorer.thermalCycleBounded.attempting.writer.plane",
                "ThermalEmergency.telemetry.plane",
                "ThermalEmergency.writer.plane",
                "ThermalEmergency.handbackReadBack.sensing",
            ],
            "the planes stored in the lane are \(lane.sorted()), of \(found)")
        let mixed = found.filter { $0.value.count > 1 }
        #expect(mixed.isEmpty, "a place stores planes at both admissions: \(mixed)")
    }

    // MARK: - The mechanisms that write only in their own scenario

    /// § 4's sleep and the signal teardown, each restoring the fan a lease holds, through the
    /// composed graph: both at `.supervisor`.
    ///
    /// **Mutation:** build § 4's writer over `plane.admitted(at: .thermalCycle)`. Run: red at the
    /// sleep.
    /// **Mutation:** build the teardown's `restore:` writer over the lane view. Run: red at the
    /// exit.
    @Test("§ 4's sleep and the signal teardown restore at supervisor")
    func sleepAndTeardownRestoreAtSupervisor() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = Self.helper(over: firmware)
        await helper.bindSafetyRegistries()
        let holder = ConnectionID()

        _ = try await helper.authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)
        let sleep = await Self.calls(on: firmware) {
            await helper.powerResponder.respond(
                to: SystemPowerNotification(event: .willSleep, generation: 1) {})
        }
        #expect(sleep.contains { $0.attempt == .restoreToAutomatic(.fan(0)) }, "\(sleep)")
        #expect(Set(sleep.map(\.admission)) == [.supervisor], "§ 4: \(sleep)")

        let exit = await Self.calls(on: firmware) {
            await helper.signalTeardown.run(stoppingSupervisorsWith: { await helper.shutDown() })
        }
        #expect(
            exit.contains {
                if case .restoreToAutomatic = $0.attempt { return true }
                return false
            }, "the teardown restored nothing: \(exit)")
        #expect(Set(exit.map(\.admission)) == [.supervisor], "the teardown: \(exit)")
    }

    // MARK: - Fixtures

    /// The composed graph over `firmware`. Its teardown ends nothing: the shipping termination
    /// would end this test process, successfully, with the run unfinished.
    private static func helper(
        over firmware: ScriptedControlPlane
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: firmware,
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(
                sources: RecordingSignalSources(), terminate: TeardownJournal().terminate))
    }

    private static func calls(
        on firmware: ScriptedControlPlane, during work: () async -> Void
    ) async -> [ScriptedControlPlane.AdmittedAttempt] {
        let before = await firmware.admittedAttempts.count
        await work()
        return Array(await firmware.admittedAttempts.dropFirst(before))
    }
}

/// An actor holding a plane, for the census's own test: the graph's mechanisms are actors.
private actor PlaneHoldingActor {
    let plane: ScriptedControlPlane

    init(plane: ScriptedControlPlane) {
        self.plane = plane
    }
}
