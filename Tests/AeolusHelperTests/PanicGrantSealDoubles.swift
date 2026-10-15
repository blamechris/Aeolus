import FanKit
import SMCCore

@testable import AeolusHelper

/// Scripted firmware whose restores of one scope park until the test lets them through, one at
/// a time, over `ControlStateGatePlane`'s parkable mode reads (#350).
///
/// `CycleWedgingRestorePlane` parks every restore while it is wedging and opens them all at once.
/// The grant seal's tests need what it cannot say: `.everyFan` parked while a `.fan(n)` restore is
/// not, the other way round, and two overlapping `.everyFan` restores let go one at a time. And
/// they need a grant parked on its foreign-control read at the same time, which is the mode read
/// `ControlStateGatePlane` already parks — so this wraps it rather than repeating it.
///
/// Every park suspends on an `AsyncSignal`, never on a blocked thread. A test's `.timeLimit` does
/// not unpark it: the parked restore runs in `observing`'s unstructured task, or in the task
/// `BoundedFanRestorer` starts for a per-fan restore, and the test's cancellation reaches
/// neither. So every test lets through what it parks before it returns.
actor ScopeParkingPlane: FanControlPlane {

    /// The firmware below, with its mode-read gate.
    let reads: ControlStateGatePlane

    private var parking: FanRestoreScope?
    private var parked: [AsyncSignal] = []

    /// Every scope a restore was asked for, in order, recorded before it parks.
    private(set) var restoreScopes: [FanRestoreScope] = []

    init(_ firmware: ScriptedControlPlane) {
        reads = ControlStateGatePlane(firmware)
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Restores parked right now.
    var parkedRestores: Int { parked.count }

    /// Parks every restore of `scope` from now until it is released.
    func park(_ scope: FanRestoreScope) {
        parking = scope
    }

    /// Lets the oldest parked restore through. Later restores of the same scope still park.
    func releaseOne() async {
        guard !parked.isEmpty else { return }
        await parked.removeFirst().signal()
    }

    /// Stops parking, and lets every parked restore through.
    func releaseAll() async {
        parking = nil
        let waiting = parked
        parked = []
        for signal in waiting { await signal.signal() }
    }

    // MARK: - The parked verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        restoreScopes.append(scope)
        if scope == parking {
            let signal = AsyncSignal()
            parked.append(signal)
            try await signal.wait()
        }
        try await reads.restoreToAutomatic(scope)
    }

    // MARK: - Straight delegation

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await reads.readControlState(ofFan: index)
    }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await reads.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await reads.readEnvelope(ofFan: index)
    }

    func reconnect() async throws {
        try await reads.reconnect()
    }

    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        try await reads.engageManualControl(of: fan)
    }

    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        await reads.prepareWritePath(enumerating: fans)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await reads.commandTarget(target)
    }
}
