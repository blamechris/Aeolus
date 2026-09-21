import FanKit
import SMCCore

@testable import AeolusHelper

// The doubles #295's tests need to act *inside* § 3's owed read-back, in a file of their own.
//
// `ScriptedControlPlane`'s methods contain no suspension point, so "a fan was engaged again
// while the read was out" and "the keystone went out while the read was out" could only be
// arguments against it — see `mock-without-suspension-hides-concurrency` in this repository's
// history. Both doubles below suspend inside the one operation being measured.

/// § 3's read-back seam with a gate a test can close, over a real reader.
///
/// Delegates to whatever it wraps — `ThermalMachine` passes the real `StartupReconciliation`
/// over the scripted firmware — **after** the gate opens, so the answer describes the firmware
/// at the moment the read is let through rather than the moment it was asked for. That is the
/// moment a stale read is about.
///
/// Records every request before it parks, so "no read was issued" is an assertion about calls
/// made rather than calls that happened to finish.
actor GatedHandbackReadBack: HandbackReadingBack {

    private let wrapped: any HandbackReadingBack
    private var isHolding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Every set of fans § 3 asked about, in order.
    private(set) var requests: [Set<Int>] = []

    /// Reads parked on the gate right now.
    private(set) var held = 0

    init(_ wrapped: any HandbackReadingBack) {
        self.wrapped = wrapped
    }

    /// Parks every read from now until `open()`.
    func hold() {
        isHolding = true
    }

    /// Lets every parked read through, and stops gating the ones that follow.
    func open() {
        isHolding = false
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func handbackReadings(of fans: Set<Int>) async -> [Int: HandbackReading] {
        requests.append(fans)
        if isHolding {
            held += 1
            await withCheckedContinuation { waiters.append($0) }
            held -= 1
        }
        return await wrapped.handbackReadings(of: fans)
    }
}

/// Scripted firmware whose `F<n>Md` reads can be parked or made to throw, while every other
/// verb — critical temperatures included — behaves as the wrapped `ScriptedControlPlane` says.
///
/// Separate from `ScriptedControlPlane.Stage.reads` because that axis blinds **everything**:
/// a stage that fails mode reads also fails the critical-temperature read, and a blind cycle
/// never reaches the owed read-back at all. The scenarios here need § 3 sighted and one fan's
/// mode unreadable, which one axis cannot say.
///
/// Used through the **composed** helper, so the read it parks is the one
/// `StartupReconciliation.handbackReadings(of:)` issues in production.
actor ControlStateGatePlane: FanControlPlane {

    /// What a mode read does right now.
    enum ModeReads: Sendable {
        /// Straight through to the scripted firmware.
        case answered
        /// Parked until `answerModeReads()`.
        case held
        /// Throws, as a key the SMC will not answer does.
        case failing
    }

    let wrapped: ScriptedControlPlane
    private var modeReads: ModeReads = .answered
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Mode reads parked right now.
    private(set) var heldModeReads = 0

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Sets what mode reads do from now on. Leaving `.held` releases any read parked there.
    func modeReads(_ behaviour: ModeReads) {
        modeReads = behaviour
        guard behaviour != .held else { return }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Every restore the firmware was asked for, from the wrapped plane's own record.
    var restoreAttempts: [FanRestoreScope] {
        get async {
            await wrapped.attempts.compactMap {
                if case .restoreToAutomatic(let scope) = $0 { return scope }
                return nil
            }
        }
    }

    // MARK: - The gated verb

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        switch modeReads {
        case .answered:
            break
        case .held:
            heldModeReads += 1
            await withCheckedContinuation { waiters.append($0) }
            heldModeReads -= 1
        case .failing:
            throw FanControlPlaneError.readFailed(detail: "F\(index)Md did not answer")
        }
        return try await wrapped.readControlState(ofFan: index)
    }

    // MARK: - Straight delegation

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
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
