import Testing

@testable import AeolusHelper

/// The production plane's write channel, at every one of § 3's lane sites (ADR 0012's #440
/// amendment, the obligation it leaves to the sync that carries the lane onto `e4/bring-up`).
///
/// `theProductionViewIsThePlane` scans a plane built with no channel, where `nil` shares with
/// `nil`: a view rebuilt through `init` would drop the channel at every lane site with that scan
/// still green, and once the plane can write, § 3 would be the one mechanism that could not. So
/// this composes the graph over a plane built with `FirmwareSMC`, the one channel a test may give a
/// plane, and holds each lane site, as the composition stores it, to that channel and to the plane.
extension PlaneViewTests {

    /// The stored property `label` of `plane`, by reflection: the channel and the scheduler are
    /// `private`, and the connection is an existential.
    static func storedProperty(_ label: String, of plane: SMCFanControlPlane) -> Any? {
        Mirror(reflecting: plane).children.first { $0.label == label }?.value
    }

    /// § 3's four lane sites, by the census's names (`ThermalCycleLaneWriterTests.laneSites`): its
    /// telemetry's view, its writer's, its read-back's, and its handback's bound writer. Each is at
    /// the lane, holds the plane's channel, scheduler and connection by identity, and shares every
    /// other stored property with the plane. Every other plane the graph stores holds them too.
    ///
    /// **Mutation:** make `SMCFanControlPlane.admitted(at:)` start its view from
    /// `SMCFanControlPlane(scheduler: scheduler, connection: connection)`, with no channel. Run:
    /// red here, at each lane site, and green in `theProductionViewIsThePlane`.
    @Test("Every lane site of a graph over a plane holding a channel holds that channel")
    func everyLaneSiteHoldsThePlanesChannel() throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider)
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: firmware.recycler, channel: firmware)
        try #require(plane.holdsWriteChannel, "the plane was not given its channel")
        let helper = HelperComposition(
            plane: plane,
            snapshotProvider: firmware.provider,
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(
                sources: RecordingSignalSources(), terminate: TeardownJournal().terminate))

        let found = ThermalCycleLaneWriterTests.stored(
            SMCFanControlPlane.self, reachableFrom: helper)
        let sites = ThermalCycleLaneWriterTests.laneSites
        #expect(found.count > 10, "the walk found \(found.count) planes: \(found.keys.sorted())")
        #expect(
            sites.isSubset(of: Set(found.keys)),
            "§ 3's lane sites \(sites.subtracting(found.keys).sorted()) are not stored")

        for (site, views) in found.sorted(by: { $0.key < $1.key }) {
            for view in views {
                if sites.contains(site) {
                    #expect(view.admission == .thermalCycle, "\(site) is at \(view.admission)")
                }
                #expect(view.holdsWriteChannel, "\(site) holds no write channel")
                let channel = Self.storedProperty("writeChannel", of: view) as? any SMCWriteChannel
                #expect(channel === firmware, "\(site) holds a channel that is not the plane's")
                #expect(
                    Self.storedProperty("scheduler", of: view) as? SMCReadScheduler === scheduler,
                    "\(site) holds a scheduler that is not the plane's")
                let recycler = Self.storedProperty("connection", of: view) as? FirmwareSMC.Recycler
                #expect(
                    recycler?.firmware === firmware,
                    "\(site) holds a connection that is not the plane's")
                let unshared = Self.unshared(view, with: plane)
                #expect(unshared.isEmpty, "\(site) does not share \(unshared) with the plane")
            }
        }
    }
}
