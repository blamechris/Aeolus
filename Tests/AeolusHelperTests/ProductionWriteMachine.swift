import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The composed helper over the **production** write plane (b2's E1, and the composed lane tests):
/// `HelperComposition` built as the daemon builds it, over `SMCFanControlPlane` holding
/// `FirmwareSMC` as its channel, the scheduler reading the same fake — the real ledger, the real
/// turns, the real lane — with only IOKit faked.
///
/// Between the graph and the plane is `InterferingWritePlane`, which delegates every verb to the
/// production plane and its views and can run an effect before the nth engagement step or target
/// command reaches the plane: after the driver's ticket and entitlement, before the step's turn,
/// as `LevelSixMachine` does over the scripted plane. With no effect set it is the plane.
struct ProductionWriteMachine: Sendable {
    let firmware: FirmwareSMC
    let scheduler: SMCReadScheduler
    let plane: SMCFanControlPlane
    let writes: InterferingWritePlane
    let helper: HelperComposition<InterferingWritePlane>
    let journal: TeardownJournal
    let lines: RecordedLog
    let observer: RecordingSchedulerObserver
    let clock: TestClock
    let holder = ConnectionID()

    /// A machine whose curated critical sensors read `celsius`, bound and prepared as bring-up
    /// binds and prepares it.
    init(unlock: FirmwareSMC.Unlock = .naive, celsius: Double = 44) async {
        let journal = TeardownJournal()
        let lines = RecordedLog()
        let observer = RecordingSchedulerObserver()
        let clock = TestClock()
        let firmware = FirmwareSMC.mac16x5(unlock: unlock)
        await firmware.declareCriticalTemperatures(celsius)
        let scheduler = SMCReadScheduler(
            provider: firmware.provider,
            observer: SchedulerObservers([firmware.log, observer]))
        let plane = SMCFanControlPlane(
            scheduler: scheduler, connection: firmware.recycler, channel: firmware,
            log: SafetyLog(recording: { lines.append($0, $1) }))
        let writes = InterferingWritePlane(plane)
        self.journal = journal
        self.lines = lines
        self.observer = observer
        self.clock = clock
        self.firmware = firmware
        self.scheduler = scheduler
        self.plane = plane
        self.writes = writes
        helper = HelperComposition(
            plane: writes,
            snapshotProvider: scheduler.snapshotReader,
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { lines.append($0, $1) }),
            teardown: TeardownSeams(sources: RecordingSignalSources(), terminate: journal.terminate)
        )
        await helper.bindSafetyRegistries()
        await helper.prepareWritePath()
    }

    /// A lease over `fans`, acquired through the authority on `holder`.
    func lease(fans: [Int] = [0]) async throws -> UUID {
        try await helper.authority.acquireLease(LeaseFixture.request(fans: fans), from: holder).id
    }

    /// `apply` through the composed authority, as the session hands it a decoded message.
    func apply(rpm: Double, fans: [Int] = [0], under lease: UUID) async throws {
        try await helper.authority.apply(
            fans.map { FanSetting(fanIndex: $0, control: .fixed(rpm: rpm)) }, leaseID: lease,
            from: holder)
    }

    /// The signal teardown, as the installed handler runs it.
    func tearDown() async {
        await helper.signalTeardown.run(stoppingSupervisorsWith: { await helper.shutDown() })
    }

    /// The writes the fake took after `mark`, as `key=bytes`.
    func writes(since mark: Int) -> [String] {
        firmware.log.entries.dropFirst(mark).compactMap {
            guard case .write(let key, let bytes, _) = $0 else { return nil }
            return "\(key.rawValue)=\(bytes.map { String($0) }.joined(separator: ","))"
        }
    }

    /// The writes away from the safe state after `mark`: any `F<n>Tg`, or any non-zero byte.
    func forwardWrites(since mark: Int) -> [String] {
        firmware.log.entries.dropFirst(mark).compactMap {
            guard case .write(let key, let bytes, _) = $0,
                key.rawValue.hasSuffix("Tg") || bytes.contains(where: { $0 != 0 })
            else { return nil }
            return "\(key.rawValue)=\(bytes)"
        }
    }

    /// Each write after `mark`, with the admission of the scheduler turn it fell in.
    func admittedWrites(since mark: Int) -> [(key: String, priority: SMCReadPriority?)] {
        var priority: SMCReadPriority?
        var found: [(key: String, priority: SMCReadPriority?)] = []
        for entry in firmware.log.entries.dropFirst(mark) {
            switch entry {
            case .turnGranted(let granted): priority = granted
            case .turnEnded: priority = nil
            case .write(let key, _, _): found.append((key.rawValue, priority))
            default: break
            }
        }
        return found
    }

    /// The fault an `apply` ended with, or `nil` when it was applied.
    static func answer(_ work: () async throws -> Void) async -> AeolusXPCFault? {
        await LevelSixMachine.answer(work)
    }
}

// MARK: - The interfering plane

/// The production plane with an effect that can run before the nth engagement step or target
/// command reaches it. A struct over the production plane and one shared `Interference`, so every
/// view the composition mints is the production plane's view, interfered with by the same counts.
struct InterferingWritePlane: FanControlPlane {

    actor Interference {
        private var steps = 0
        private var commands = 0
        private var beforeStep: (ordinal: Int, effect: @Sendable () async -> Void)?
        private var beforeCommand: (ordinal: Int, effect: @Sendable () async -> Void)?
        private(set) var didFire = false

        func set(beforeStep ordinal: Int, _ effect: @escaping @Sendable () async -> Void) {
            beforeStep = (ordinal, effect)
        }

        func set(beforeCommand ordinal: Int, _ effect: @escaping @Sendable () async -> Void) {
            beforeCommand = (ordinal, effect)
        }

        func stepArrives() async {
            steps += 1
            guard let due = beforeStep, due.ordinal == steps else { return }
            beforeStep = nil
            didFire = true
            await due.effect()
        }

        func commandArrives() async {
            commands += 1
            guard let due = beforeCommand, due.ordinal == commands else { return }
            beforeCommand = nil
            didFire = true
            await due.effect()
        }
    }

    let plane: SMCFanControlPlane
    let interference: Interference

    init(_ plane: SMCFanControlPlane) {
        self.init(plane: plane, interference: Interference())
    }

    private init(plane: SMCFanControlPlane, interference: Interference) {
        self.plane = plane
        self.interference = interference
    }

    func interfere(
        beforeEngageStep ordinal: Int, with effect: @escaping @Sendable () async -> Void
    ) async {
        await interference.set(beforeStep: ordinal, effect)
    }

    func interfere(
        beforeCommandTarget ordinal: Int, with effect: @escaping @Sendable () async -> Void
    ) async {
        await interference.set(beforeCommand: ordinal, effect)
    }

    var didFire: Bool { get async { await interference.didFire } }

    func admitted(at admission: PlaneAdmission) -> InterferingWritePlane {
        InterferingWritePlane(plane: plane.admitted(at: admission), interference: interference)
    }

    var writeCapability: FanWriteCapability { plane.writeCapability }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await plane.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await plane.readEnvelope(ofFan: index)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await plane.readControlState(ofFan: index)
    }

    func reconnect() async throws { try await plane.reconnect() }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await plane.restoreToAutomatic(scope)
    }

    func beginEngagement(fanAt index: Int) { plane.beginEngagement(fanAt: index) }

    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        await interference.stepArrives()
        return try await plane.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        await interference.commandArrives()
        return try await plane.commandTarget(target)
    }

    func bridgeThenRestore(_ target: AuthorisedFanTarget) async -> BridgeOutcome {
        await plane.bridgeThenRestore(target)
    }

    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        await plane.prepareWritePath(enumerating: fans)
    }
}

// MARK: - The curated critical sensors, on the fake

extension FirmwareSMC {

    /// Declares `Mac16,5`'s curated die-cluster keys (`CriticalSensorSet.mac16x5`) as `flt`,
    /// little-endian under the modern generation (attribute bit `0x04`), each reading `celsius`.
    func declareCriticalTemperatures(_ celsius: Double) {
        for key in CriticalSensorSet.mac16x5.keys {
            declare(
                key, .present(SMCKeyInfo(key: key, type: .flt, dataSize: 4, attributes: 0x84)))
        }
        setCriticalTemperatures(celsius)
    }

    /// Every curated die-cluster key reads `celsius` from now on.
    func setCriticalTemperatures(_ celsius: Double) {
        for key in CriticalSensorSet.mac16x5.keys {
            setRegister(key, Self.flt(rpm: Float(celsius)))
        }
    }
}
