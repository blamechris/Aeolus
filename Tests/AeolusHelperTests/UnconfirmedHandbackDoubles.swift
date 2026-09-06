import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

// The firmware double decision D33's ordering needs, in a file of its own.
//
// `SystemPowerTestDoubles.swift` is where it belongs by subject and is already at the line
// limit that split it out of `SystemPowerTests.swift` in the first place, so it goes here
// rather than pushing that file past 400 lines. Same reason, one level down.

/// The firmware that parks the first restore and then refuses every attempt.
///
/// `WedgedRestorePlane`'s wedge followed by `ScriptedControlPlane`'s refusal, which neither
/// double can express alone: the first is a machine that comes good once released, and the
/// second refuses from the very first attempt so the budget never has anything outstanding to
/// give up on.
///
/// It is the case decision D33's ordering exists for. § 4's budget expires while the restore
/// is parked, so the fan is recorded as an *unconfirmed* handback; the restore then comes back
/// having spent `RestoreLimits.attemptBudget` on a firmware that never took the write, and
/// `LeaseAuthority.restore(_:because:)`'s existing union converts it to the durable
/// `.restoreToAutomaticFailed`. Without a double that does both in that order, "converts to
/// the durable set through the path that already exists" is a sentence with no test behind it.
///
/// **Only the first attempt parks**, so `BoundedFanRestorer` spends its remaining two without
/// any inter-attempt wait — `RestoreLimits` has none by design — and the test does not have to
/// release the wedge three times.
actor WedgedThenRefusingRestorePlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private let held = AsyncSignal()
    private var hasParked = false

    /// Every scope the restore was asked for, recorded before it parks or throws.
    private(set) var restoreScopes: [FanRestoreScope] = []

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Lets the parked restore off its wedge — into the refusal, not into success.
    func release() async {
        await held.signal()
    }

    // MARK: - The wedged-then-refusing verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        restoreScopes.append(scope)
        if !hasParked {
            hasParked = true
            try await held.wait()
        }
        throw AeolusXPCFault.helperFailed(detail: "the firmware discarded the mode write")
    }

    // MARK: - Straight delegation

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await wrapped.readControlState(ofFan: index)
    }

    func reconnect() async throws {
        try await wrapped.reconnect()
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}
