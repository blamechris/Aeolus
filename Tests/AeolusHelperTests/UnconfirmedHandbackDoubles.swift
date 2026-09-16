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

/// The firmware whose restore parks only while a test says it should, once per sleep cycle.
///
/// `WedgedRestorePlane` cannot stand in for this, and the difference is `AsyncSignal`: its
/// `held` is a single latch, so the first `release()` opens it for the life of the double.
/// That is the right shape for one sleep and useless for several — cycle 2's restore would
/// sail through the wedge cycle 1 opened, the budget would never have anything outstanding to
/// give up on, and the register this exists to watch would simply not be written. A test built
/// on it would report three healthy sleeps and call them three wedged ones.
///
/// So the wedge is armed per cycle, and the signal is replaced each time it is armed. What
/// that buys is the one thing a multi-cycle test of `docs/SAFETY.md` § 4 needs: the *same*
/// hazard, three times, through one helper — the budget expiring with a restore outstanding on
/// cycle 3 exactly as on cycle 1.
///
/// Wraps `ScriptedControlPlane` for the reason every other double here does: the firmware
/// underneath is the shipped mock and only the one verb behaves differently.
actor CycleWedgingRestorePlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private var isWedging = false
    private var held = AsyncSignal()

    /// Every scope the restore was asked for, in order, recorded before it parks.
    private(set) var restoreScopes: [FanRestoreScope] = []

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    /// Parks every restore issued from now until the matching `release()`.
    ///
    /// The signal is replaced rather than reset, because `AsyncSignal` has no reset and should
    /// not grow one: a latch that can be un-fired is a latch a test can un-fire by accident.
    /// A fresh one per cycle makes "this cycle's wedge" a distinct object.
    func wedgeTheNextRestore() {
        isWedging = true
        held = AsyncSignal()
    }

    /// Lets this cycle's parked restore through and stops wedging, so the keystone that
    /// follows it is not parked too.
    ///
    /// That asymmetry is deliberate rather than a convenience: the lease's own fan is what
    /// wedges, the keystone is not reached until the wedge lets go — the honest shape of a
    /// stale `io_connect_t` under a live lease, and the one
    /// `aWedgedHandbackDropsTheLeaseFirstAndLeavesTheFanUnconfirmed` already pins for a single
    /// sleep — so parking both would need two releases per cycle for no property gained.
    func release() async {
        isWedging = false
        await held.signal()
    }

    // MARK: - The per-cycle wedged verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        restoreScopes.append(scope)
        if isWedging {
            let thisCyclesWedge = held
            try await thisCyclesWedge.wait()
        }
        try await wrapped.restoreToAutomatic(scope)
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
