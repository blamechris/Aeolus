import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The composed helper, over a plane that can hold level 6 inside an engagement step: the same
/// wiring `HelperRestorerTests.composed` builds, with `InterferingFanStateSensing` between the
/// graph and the scripted firmware, so a test can act after the driver's entitlement and before
/// the step's turn (`interfere(beforeEngageStep:with:)`).
///
/// Its process end goes into `journal` and its safety lines into `lines`, so a scenario reads the
/// teardown's exit and level 6's lines in order. Its clock is a `TestClock` unless a scenario
/// passes one: nothing here sleeps unless the unlock polls, so no wait rests on the wall clock.
struct LevelSixMachine: Sendable {
    let helper: HelperComposition<InterferingFanStateSensing>
    let firmware: ScriptedControlPlane
    let writes: InterferingFanStateSensing
    let journal: TeardownJournal
    let lines: RecordedLog
    /// The connection the machine's lease is bound to.
    let holder = ConnectionID()

    /// `moment` is where `writes.interfere(with:)`'s effect runs; nothing runs there unless a
    /// scenario sets one.
    init(
        unlock: ScriptedControlPlane.UnlockBehaviour = .naive,
        during moment: InterferingFanStateSensing.Moment = .restoreWrite,
        clock: some MonotonicClock = TestClock()
    ) async {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)], unlock: unlock)
        let writes = InterferingFanStateSensing(firmware, during: moment)
        let journal = TeardownJournal()
        let lines = RecordedLog()
        helper = HelperComposition(
            plane: writes,
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { level, line in lines.append(level, line) }),
            teardown: TeardownSeams(sources: RecordingSignalSources(), terminate: journal.terminate)
        )
        self.firmware = firmware
        self.writes = writes
        self.journal = journal
        self.lines = lines
        await helper.bindSafetyRegistries()
    }

    /// A lease over fan 0, acquired through the authority on `holder`.
    func lease() async throws -> UUID {
        try await helper.authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder).id
    }

    /// `apply` through the composed authority, as the session hands it a decoded message.
    func apply(rpm: Double, under lease: UUID) async throws {
        try await helper.authority.apply(
            [FanSetting(fanIndex: 0, control: .fixed(rpm: rpm))], leaseID: lease, from: holder)
    }

    /// Every engagement step and target command the firmware has been asked for after `count` of
    /// its attempts: the writes away from automatic control.
    func forwardWrites(after count: Int) async -> [ScriptedControlPlane.Attempt] {
        await firmware.attempts.dropFirst(count).filter { attempt in
            switch attempt {
            case .engageManualControl, .commandTarget: return true
            default: return false
            }
        }
    }

    /// Latches § 3 on the composition's one latch, as a cycle that read a critical die would.
    func latchTheThermalEmergency() async {
        await helper.latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99), answering: [smcKey("Tp01")])
    }

    /// The fault an `apply` ended with, or `nil` when it was applied.
    static func answer(_ work: () async throws -> Void) async -> AeolusXPCFault? {
        do {
            try await work()
            return nil
        } catch {
            return (error as? AeolusXPCFault) ?? .helperFailed(detail: "\(error)")
        }
    }
}
