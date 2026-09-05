import FanKit
import SMCCore

@testable import AeolusHelper

/// The scripted firmware, plus a note of what each safety registry held **at the instant the
/// keystone write was issued**.
///
/// `HelperFanRestorer` deregisters § 5 before the write and § 3 after it, and those are
/// different sides on purpose — see that type for the argument. The consequence of getting
/// either one wrong is a state, not a return value: § 5 reading a fan that has *just* gone
/// automatic as `.modeReclaimed` revokes every lease on the machine and blames the operating
/// system for a handback Aeolus asked for. Asserting the order therefore needs an observer
/// inside the write, because before and after it the two registries look identical.
///
/// The alternative was to assert the end state, which is what the abandoned-fan test does —
/// and it cannot see the ordering at all: § 5 is emptied whether it is told first or last.
/// A test that cannot distinguish the two orders is a test the mutation survives.
///
/// It wraps rather than replaces `ScriptedControlPlane`, so the firmware under the observer
/// is the shipped mock: stages, `WriteBehaviour`, the unscripted-input refusal, all of it.
actor RegistryObservingPlane: FanControlPlane {

    /// What the two registries held when one restore was issued.
    struct Observation: Sendable, Hashable {
        let scope: FanRestoreScope
        /// `ReclamationWatchdog.fansUnderManualControl` at the write.
        let reclamation: Set<Int>
        /// `ThermalEmergency.fansUnderManualControl` at the write.
        let thermal: Set<Int>
    }

    private let wrapped: ScriptedControlPlane
    private var reclamationWatchdog: ReclamationWatchdog<RegistryObservingPlane>?
    private var thermalEmergency: ThermalEmergency<RegistryObservingPlane>?

    private(set) var observations: [Observation] = []

    init(_ wrapped: ScriptedControlPlane) {
        self.wrapped = wrapped
    }

    /// Points the observer at the registries the composition built.
    ///
    /// After construction, because the graph is circular in the same way `HelperFanRestorer`
    /// documents: the registries need the lease core, which needs the restorer, which needs
    /// this plane.
    func observe(
        reclamationWatchdog: ReclamationWatchdog<RegistryObservingPlane>,
        thermalEmergency: ThermalEmergency<RegistryObservingPlane>
    ) {
        self.reclamationWatchdog = reclamationWatchdog
        self.thermalEmergency = thermalEmergency
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    // MARK: - The observed verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        let reclamation = await reclamationWatchdog?.fansUnderManualControl ?? []
        let thermal = await thermalEmergency?.fansUnderManualControl ?? []
        observations.append(
            Observation(scope: scope, reclamation: reclamation, thermal: thermal))
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
