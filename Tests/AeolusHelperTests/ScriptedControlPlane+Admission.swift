import FanKit
import SMCCore

@testable import AeolusHelper

/// The scripted `FanControlPlane`: a view of one `ScriptedFirmware` at an admission.
///
/// ## Why the plane is a view and the firmware an actor
///
/// [ADR 0012](../../docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md)'s
/// 2026-10-18 amendment gives § 3's cycle its own admission, reached through a view of the one
/// plane (`FanControlPlane.admitted(at:)`). A view that is the plane needs the plane's state to
/// live somewhere both share, so the state is the firmware's — the actor in
/// `ScriptedControlPlane.swift`, which holds every fan, every stage, the `PlaneWriteLedger` and
/// the record of every call — and this value holds the firmware and an admission and nothing
/// else. `SMCFanControlPlane` has the same shape over its scheduler and connection.
///
/// Every verb forwards to the firmware with this view's admission, so `admittedAttempts` says
/// which admission each call came through, and every scripting verb forwards unchanged, so a
/// test scripts the machine through whichever view it holds. `PlaneViewTests` holds the sharing:
/// a restore through the view supersedes a step through the plane, and the reverse.
struct ScriptedControlPlane: FanControlPlane {

    typealias Stage = ScriptedFirmware.Stage
    typealias ReadBehaviour = ScriptedFirmware.ReadBehaviour
    typealias ReconnectBehaviour = ScriptedFirmware.ReconnectBehaviour
    typealias WriteBehaviour = ScriptedFirmware.WriteBehaviour
    typealias UnlockBehaviour = ScriptedFirmware.UnlockBehaviour
    typealias KeyWrite = ScriptedFirmware.KeyWrite
    typealias FanCondition = ScriptedFirmware.FanCondition
    typealias Attempt = ScriptedFirmware.Attempt
    typealias AdmittedAttempt = ScriptedFirmware.AdmittedAttempt
    typealias Bound = ScriptedFirmware.Bound
    typealias BoundRead = ScriptedFirmware.BoundRead
    typealias UnansweredWrite = ScriptedFirmware.UnansweredWrite

    /// The machine every view of it shares.
    let firmware: ScriptedFirmware

    /// What every turn through this view is admitted at.
    let admission: PlaneAdmission

    /// A new machine, and the plane over it at `.supervisor`. See `ScriptedFirmware.init` for
    /// the parameters.
    init(
        fans: [Int: FanCondition], stages: [Stage] = [.nominal()],
        forceKey: ForceKeyPresence = .present, unlock: UnlockBehaviour = .naive,
        prepared: Bool = true
    ) {
        self.init(
            firmware: ScriptedFirmware(
                fans: fans, stages: stages, forceKey: forceKey, unlock: unlock,
                prepared: prepared),
            admission: .supervisor)
    }

    private init(firmware: ScriptedFirmware, admission: PlaneAdmission) {
        self.firmware = firmware
        self.admission = admission
    }

    /// The same firmware at `admission`.
    func admitted(at admission: PlaneAdmission) -> ScriptedControlPlane {
        ScriptedControlPlane(firmware: firmware, admission: admission)
    }

    /// `.built`, always: this firmware really does take writes, and `WriteBehaviour` is how
    /// a scenario says one was refused.
    ///
    /// Synchronous, so the answer costs no actor hop and no read — see
    /// `FanWriteCapabilityReporting`, which is the whole reason a mechanism can ask it before
    /// touching hardware. It is deliberately **not** scriptable per stage: the capability is
    /// a property of the build behind the seam, not of the machine at a moment, and a mock
    /// that could toggle it would let a test drive a state no executable can be in.
    var writeCapability: FanWriteCapability { .built }

    // MARK: - The seam, at this view's admission

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await firmware.readCriticalTemperatures(keys, at: admission)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await firmware.readEnvelope(ofFan: index, at: admission)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await firmware.readControlState(ofFan: index, at: admission)
    }

    /// At `.supervisor` whatever this view's admission: see `FanControlPlane.admitted(at:)`.
    func reconnect() async throws {
        try await firmware.reconnect()
    }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await firmware.restoreToAutomatic(scope, at: admission)
    }

    func beginEngagement(fanAt index: Int) {
        firmware.beginEngagement(fanAt: index)
    }

    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        try await firmware.engageManualControl(of: fan, at: admission)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await firmware.commandTarget(target, at: admission)
    }

    /// § 3's bridge as B1's plane will run it: the `.fan` restore **requested first**,
    /// synchronously, before the job waits for its turn (D4), then the job's turn as one firmware
    /// step (`ScriptedFirmware.bridgeTurn(_:at:)`). Between the two is the wait a scenario can act
    /// inside (`duringNextBridgeWait(_:)`).
    func bridgeThenRestore(_ target: AuthorisedFanTarget) async -> BridgeOutcome {
        ledger.restoreRequested(.fan(target.fanIndex))
        if let wait = await firmware.takeBridgeWait() { await wait() }
        return await firmware.bridgeTurn(target, at: admission)
    }

    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        await firmware.prepareWritePath(enumerating: fans)
    }

    // MARK: - What the firmware recorded, through any view

    var attempts: [Attempt] { get async { await firmware.attempts } }
    var admittedAttempts: [AdmittedAttempt] { get async { await firmware.admittedAttempts } }
    var keyWrites: [KeyWrite] { get async { await firmware.keyWrites } }
    var preparations: Int { get async { await firmware.preparations } }
    var isForceKeySet: Bool { get async { await firmware.isForceKeySet } }
    var ledger: PlaneWriteLedger { firmware.ledger }
    var forceKeyDeclaration: ForceKeyPresence { firmware.forceKeyDeclaration }

    // MARK: - Scripting, through any view

    func advance() async { await firmware.advance() }

    func setMode(_ mode: FirmwareFanMode, ofFan index: Int) async {
        await firmware.setMode(mode, ofFan: index)
    }

    func duringNextModeWrite(_ effect: @escaping @Sendable () -> Void) async {
        await firmware.duringNextModeWrite(effect)
    }

    func setForceKey(_ isSet: Bool) async { await firmware.setForceKey(isSet) }

    func setRawMode(_ raw: UInt8?, ofFan index: Int) async {
        await firmware.setRawMode(raw, ofFan: index)
    }

    func failNextReadBack(ofFan index: Int) async { await firmware.failNextReadBack(ofFan: index) }

    func firmwareMode(ofFan index: Int) async throws -> FirmwareFanMode {
        try await firmware.firmwareMode(ofFan: index)
    }

    func firmwareBound(_ bound: Bound, ofFan index: Int) async throws -> Double {
        try await firmware.firmwareBound(bound, ofFan: index)
    }

    func ticketedStep(of fan: CommandableFan) async throws -> EngagementStep {
        try await firmware.ticketedStep(of: fan)
    }

    func duringNextBridgeWait(_ effect: @escaping @Sendable () async -> Void) async {
        await firmware.duringNextBridgeWait(effect)
    }

    static func readback(_ value: Double, describing what: String) -> FanRPMReadback {
        ScriptedFirmware.readback(value, describing: what)
    }

    static func declaredSizes(enumerated: Set<Int>?, forceKey: ForceKeyPresence) -> [SMCKey: Int] {
        ScriptedFirmware.declaredSizes(enumerated: enumerated, forceKey: forceKey)
    }
}

/// A test plane with no scheduler and no admission of its own: every view of it is itself.
///
/// The doubles that conform wrap a `ScriptedControlPlane` or stand in for one to script an
/// interleaving, and none of them is asked which admission a call came through. A composed graph
/// over one runs § 3's cycle through the same instance as everything else, so its admission is
/// whatever the wrapped plane is built at, `.supervisor`. A test about the lane composes over
/// `ScriptedControlPlane` directly.
protocol AdmissionBlindPlane: FanControlPlane {}

extension AdmissionBlindPlane {
    func admitted(at admission: PlaneAdmission) -> Self { self }

    /// § 3's bridge through this double's own two verbs, in order, the second whatever the first
    /// answered — so a double that scripts an interleaving in `commandTarget(_:)` or
    /// `restoreToAutomatic(_:)` still sees § 3's halves there. Two calls, not one job: a double
    /// that is about the job's order implements the verb itself.
    func bridgeThenRestore(_ target: AuthorisedFanTarget) async -> BridgeOutcome {
        let maximum: Result<CommandedTarget, any Error>
        do {
            maximum = .success(try await commandTarget(target))
        } catch {
            maximum = .failure(error)
        }
        let restore: Result<Void, any Error>
        do {
            restore = .success(try await restoreToAutomatic(.fan(target.fanIndex)))
        } catch {
            restore = .failure(error)
        }
        return BridgeOutcome(maximum: maximum, restore: restore)
    }
}

/// The write permit for one of a scripted machine's own fans.
///
/// **Derived from the mock's `FanCondition`, never from figures restated in a test.** An
/// earlier draft declared `FanControlEnvelope.nominal = validated(1_350, 5_777)` beside
/// `FanCondition.nominal`'s own `1_350`/`5_777`, which put the development machine's
/// envelope in two hand-maintained places with nothing enforcing that they agree — the
/// precise hazard `FanSafetyLimits` documents itself as avoiding. Changing the mock fan's
/// declared minimum now changes the permit clamped against it, because there is one number.
///
/// It also lives in a free function rather than in an `extension FanControlEnvelope`. A
/// test-target extension on a `FanKit` type silently shadows a same-named member added
/// later on the `FanKit` side — no ambiguity error and no warning — so every helper test
/// would go on using the stale figures while the library's own moved.
///
/// Building a `FanEnvelope` by hand is the honest shape and is the *only* route: both permit
/// types have `fileprivate` initialisers, and `@testable` does not widen `fileprivate`. A
/// test that wants to command a fan has to fake a firmware reading, and it looks like it.
///
/// - Throws: `FanBoundsImplausibility` when the condition's declared bounds fail #37's gate
///   — which is exactly what a test asserting "this fan cannot be commanded" wants to catch.
func commandableFan(
    _ index: Int, declaring condition: ScriptedControlPlane.FanCondition
) throws -> CommandableFan {
    try FanEnvelope(
        index: index,
        minimumRPM: condition.minimumRPM,
        maximumRPM: condition.maximumRPM
    ).commandable.get()
}

/// A four-character SMC key written out in a test, where a typo can only be a typo.
///
/// Traps rather than returning an optional, for the same reason `SMCKey.known(_:)` does:
/// the failure it can have is an authoring mistake in this repository, caught by the suite
/// rather than by a user, and threading an optional through every fixture would obscure
/// what each test is actually asserting.
func smcKey(_ raw: String) -> SMCKey {
    guard let key = SMCKey(raw) else {
        preconditionFailure("'\(raw)' is not a valid four-character SMC key")
    }
    return key
}

extension ScriptedFirmware.Attempt {

    /// Whether this attempt writes to a fan: a command, a restore, an engagement or a bridge.
    ///
    /// The one classification the suites share (`ThermalEmergencyFixture`'s ordering assertions
    /// and `SupervisorWriterAdmissionTests`' `bringUp()` drives), as an exhaustive switch, so a new
    /// kind of attempt must be classed here before the test target compiles and is never left out
    /// of a check by default.
    ///
    /// A reconnect is not a write to a fan: it closes and reopens the connection under a
    /// `.supervisor` turn whatever view asks for it (`FanControlPlane.admitted(at:)`), so it can
    /// never be in the lane and is harmless to leave unchecked. It is classed with the reads, for
    /// the reason `readControlState` is: an assertion about what a mechanism *wrote* must not
    /// shift because it also tried to see again.
    var isWrite: Bool {
        switch self {
        case .commandTarget, .restoreToAutomatic, .engageManualControl, .bridgeThenRestore:
            true
        case .readCriticalTemperatures, .readEnvelope, .readControlState, .reconnect:
            false
        }
    }
}
