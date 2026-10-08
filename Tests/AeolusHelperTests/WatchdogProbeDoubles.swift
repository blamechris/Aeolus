import FanKit
import Foundation
import SMCCore
import Testing
import os

@testable import AeolusHelper

// Probes for `HelperWatchdogCompositionTests.theWatchdogIsArmedBeforeReconciliationReads`:
// doubles that tell one shared object about every read bring-up makes, so the test can ask
// whether the watchdog was armed at the first of them.

/// Records, at the first read anything makes, whether the watchdog's tick source has been
/// started. A probe shared by the plane and the provider because the question is "was the
/// watchdog armed before the first read of either".
final class ArmProbe: Sendable {

    private struct State: Sendable {
        var reads = 0
        var firstReadFoundArmed: Bool?
    }

    private let ticks: ManualWatchdogTicks
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(ticks: ManualWatchdogTicks) {
        self.ticks = ticks
    }

    func noteRead() {
        let armed = ticks.isRunning
        state.withLock {
            $0.reads += 1
            if $0.firstReadFoundArmed == nil { $0.firstReadFoundArmed = armed }
        }
    }

    var readCount: Int { state.withLock { $0.reads } }
    var firstReadFoundTheWatchdogArmed: Bool? { state.withLock { $0.firstReadFoundArmed } }
}

/// `ScriptedControlPlane` that tells an `ArmProbe` about every read.
actor ArmProbingPlane: FanControlPlane {

    private let probe: ArmProbe
    private let wrapped: ScriptedControlPlane

    init(probe: ArmProbe, wrapping wrapped: ScriptedControlPlane) {
        self.probe = probe
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        probe.noteRead()
        return try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        probe.noteRead()
        return try await wrapped.readEnvelope(ofFan: index)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        probe.noteRead()
        return try await wrapped.readControlState(ofFan: index)
    }

    func reconnect() async throws {
        try await wrapped.reconnect()
    }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await wrapped.restoreToAutomatic(scope)
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}

/// A `SensorProvider` that tells an `ArmProbe` about every read, and otherwise is the fake it
/// wraps.
struct ArmProbingProvider: SensorProvider {

    let probe: ArmProbe
    let wrapped: FakeSensorProvider

    init(probe: ArmProbe, wrapping wrapped: FakeSensorProvider) {
        self.probe = probe
        self.wrapped = wrapped
    }

    var identifier: String { wrapped.identifier }

    var isAvailable: Bool {
        get async { await wrapped.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        probe.noteRead()
        return try await wrapped.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        probe.noteRead()
        return try await wrapped.read(keys: keys)
    }
}
