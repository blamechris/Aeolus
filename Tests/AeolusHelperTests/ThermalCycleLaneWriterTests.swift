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
/// **The census asserts positively, on the priority each stored plane's turns are admitted at**
/// (`PlaneAdmission.priority`), not on which admission it names: every stored plane is at
/// `.supervisor` but an explicit list of § 3's lane sites, and each of those is at the lane. A
/// case that maps to the lane under another name therefore fails here as well as at the value-set
/// pin (`ThermalCycleLaneValueSetTests`), which is what stops it compiling at all.
///
/// **It is taken at rest and after a § 3 episode** (#440), because the one lane site that moves is
/// lent: § 3 holds its handback and the lease core borrows it for a call. A holder that kept what
/// it was lent would show only after the lending, so the census is taken after one too.
///
/// **What it cannot see.** A plane captured by a closure or a `Task` rather than stored is not a
/// child any reflection walk reaches, and neither is a view built at a call site and dropped.
/// Today `ConnectionHealth`'s recovery plane is the only plane held that way: it is captured by the
/// pump's task, and a recycle is a supervisor turn whatever view asks for it
/// (`FanControlPlane.admitted(at:)`), so no call could tell. A view built at a call site needs an
/// admission that maps to the lane, and the value-set pin leaves only `.thermalCycle`, whose
/// namings `ThermalCycleLaneTripwireTests` counts per file. Those counts say where the lane is
/// named, not who uses it: a lane view returned by a property in a file that may name the lane, and
/// used elsewhere, keeps every count. `ThermalCycleHandbackShapeTripwireTests` closes the
/// accidental forms of that for the two files that may name it, and counts the names of the
/// handback's type, per file, since building one is a mint; `SupervisorWriterAdmissionTests` holds
/// the consequence, by behaviour. This census covers reachable stored planes, and nothing else.
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

    /// § 3's four lane sites, by the path the census names each by: its telemetry's view, its
    /// writer's, its read-back's, and the handback it holds and lends for its revocation (#440).
    ///
    /// Adding a site here is an ADR 0012 amendment and a safety review (#332): a fifth lane site
    /// lands with a few visible edits and nothing else red, so this list is the review signal. The
    /// handback's site is under `ThermalEmergency`, and nowhere else: a lane bound kept by the
    /// lease core, or by the restorer, is a stored plane this census names under that holder.
    static let laneSites: Set<String> = [
        "ThermalEmergency.telemetry.plane",
        "ThermalEmergency.writer.plane",
        "ThermalEmergency.handbackReadBack.sensing",
        "ThermalEmergency.handback.bounded.attempting.writer.plane",
    ]

    /// The census's verdict on `found`: every lane site is stored, at the lane, and every other
    /// stored plane is at `.supervisor`. Judged by the priority each admission maps to, for every
    /// site, with the lane sites listed rather than filtered for.
    private static func expectOnlySectionThreesSitesInTheLane(
        _ found: [String: Set<PlaneAdmission>], _ when: String
    ) {
        #expect(found.count > 10, "\(when): the census found \(found.count) planes: \(found)")
        #expect(
            laneSites.isSubset(of: Set(found.keys)),
            """
            \(when): § 3's lane sites \(laneSites.subtracting(found.keys).sorted()) are not \
            stored
            """)
        for (site, admissions) in found.sorted(by: { $0.key < $1.key }) {
            let priorities = Set(admissions.map(\.priority))
            let expected: Set<SMCReadPriority> =
                laneSites.contains(site) ? [.thermalCycle] : [.supervisor]
            #expect(
                priorities == expected,
                "\(when): \(site) is admitted at \(priorities), not \(expected)")
        }
    }

    /// The composed graph, bound as bring-up binds it: every plane it stores is admitted at
    /// `.supervisor` but § 3's four lane sites, which are admitted in the lane.
    ///
    /// **Mutation:** in `HelperComposition.init`, build § 5's `reclamationWriter` over
    /// `plane.admitted(at: .thermalCycle)`. Run: red, naming § 5's writer and its driver's.
    /// **Mutation:** the same for § 4's writer, `SafetyActorWriter(plane: …, level: .sleepWake)`.
    /// Run: red, naming the power responder's.
    /// **Mutation:** the same for the signal teardown's `restore:` writer. Run: red.
    /// **Mutation:** the same for § 6's `panic:` writer. Run: red, naming reconciliation's.
    /// **Mutation:** add `PlaneAdmission.reassert`, mapped with `.thermalCycle` to the lane, give
    /// it to § 5's writer, and update the value-set pin to match. Run: red here, naming § 5's
    /// writer, though no lane word was added and no admission is `.thermalCycle`.
    @Test("Every plane the composed graph stores is at supervisor but § 3's")
    func everyStoredPlaneIsAtSupervisorButSectionThrees() async throws {
        let firmware = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let helper = Self.helper(over: firmware)
        await helper.bindSafetyRegistries()

        Self.expectOnlySectionThreesSitesInTheLane(Self.planes(reachableFrom: helper), "at rest")
    }

    /// K5. The same census after a whole § 3 episode: a lease engaged through level 6, a firing
    /// that bridges the fan and revokes the lease through § 3's handback, a latched cycle, the
    /// machine cooling and the latch releasing, and the read-back of § 3's own restore. The four
    /// lane sites are still the only ones: lending the handback left it where it was, and nothing
    /// the episode ran kept a lane plane anywhere else.
    ///
    /// **Mutation (K5):** make `revokeEveryLease`'s and `restore(_:because:through:)`'s generic
    /// parameters copyable and their parameters plain, add `private var lent: (any FanRestoring)?`
    /// to `LeaseAuthority`, set it in `revokeEveryLease`, and restore lapsed leases through it
    /// when it is set. Run: green at rest, red here — naming `LeaseAuthority.lent.some.bounded…`.
    /// With the borrowing signatures it does not compile: the parameter cannot be stored.
    @Test("After a § 3 episode, every stored plane is still at supervisor but § 3's")
    func afterAnEpisodeEveryStoredPlaneIsStillAtSupervisorButSectionThrees() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures), .at(96),
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
            ])
        let helper = Self.helper(over: firmware)
        await helper.bindSafetyRegistries()
        let holder = ConnectionID()
        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)
        try await helper.authority.apply(
            [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400))], leaseID: lease.id, from: holder)

        await firmware.advance()
        await helper.thermalEmergency.cycle()
        #expect(await helper.latch.isActive, "the cycle did not fire")
        #expect(await helper.leases.leaseCount == 0, "the firing did not revoke the lease")
        await helper.thermalEmergency.cycle()
        await firmware.advance()
        await helper.thermalEmergency.cycle()
        #expect(await !helper.latch.isActive, "the latch never released")
        await helper.thermalEmergency.cycle()
        #expect(
            await helper.thermalEmergency.fansRestoredUnconfirmed.isEmpty,
            "§ 3 never read back its own restore")

        Self.expectOnlySectionThreesSitesInTheLane(
            Self.planes(reachableFrom: helper), "after an episode")
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
