import FanKit
import SMCCore

@testable import AeolusHelper

/// One thing the orderly teardown did, in the order it did it.
///
/// The point of a single ordered log is that the teardown's contract is an **order**, not a
/// set of effects. Asserting the end state cannot distinguish "released, then restored" from
/// "restored, then released": both leave an empty lease table and every fan automatic, which
/// is why `HelperRestorerTests` needed a `RegistryObservingPlane` for the same reason one
/// layer down.
enum TeardownEvent: Sendable, Hashable {

    /// A restore reached the firmware, and whether the control gate was already closed when
    /// it did.
    ///
    /// The gate's state travels **with the restore** rather than being asserted separately,
    /// because "the gate closed first" is an ordering claim and a `#expect(gate.isClosed)`
    /// after the fact is true whichever order the two ran in.
    case restored(FanRestoreScope, gateClosed: Bool)

    /// `HelperComposition.shutDown()` ran.
    case supervisorsStopped

    /// The process would have ended, with this code.
    case exited(TeardownOutcome)
}

/// The ordered log of everything the teardown did, plus a latch for the end of it.
actor TeardownJournal {

    private(set) var events: [TeardownEvent] = []

    /// Fires when `.exited` is recorded, so a test driving the teardown through a fired
    /// signal has something deterministic to await instead of polling.
    let finished = AsyncSignal()

    func record(_ event: TeardownEvent) async {
        events.append(event)
        if case .exited = event { await finished.signal() }
    }

    /// Just the scopes, for the assertions that are only about which restores happened.
    var restoreScopes: [FanRestoreScope] {
        events.compactMap {
            if case .restored(let scope, _) = $0 { return scope }
            return nil
        }
    }
}

/// `ScriptedControlPlane` with every restore written into a journal, together with the
/// control gate's state at that instant.
///
/// It wraps rather than replaces, exactly as `RegistryObservingPlane` does, so the firmware
/// under the observer is the shipped mock — stages, `WriteBehaviour`, the unscripted-input
/// refusal, all of it.
actor JournallingPlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private let journal: TeardownJournal
    private var gate: ControlMessageGate?

    init(journal: TeardownJournal, wrapping wrapped: ScriptedControlPlane) {
        self.journal = journal
        self.wrapped = wrapped
    }

    /// Points the observer at the gate the composition built.
    ///
    /// After construction, because the graph is circular in the way `HelperFanRestorer`
    /// documents: the gate belongs to the authority, which needs the lease core, which needs
    /// the restorer, which needs this plane.
    func observe(gate: ControlMessageGate) {
        self.gate = gate
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    // MARK: - The observed verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        let closed = await gate?.isClosed ?? false
        await journal.record(.restored(scope, gateClosed: closed))
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

/// A `SignalSourcing` that installs nothing in the test process and hands the handler back.
///
/// **Nothing under `Tests/` may construct `DispatchSignalSources`**, and that is not
/// fastidiousness: it calls `signal(_, SIG_IGN)`, which is process-wide and permanent, so a
/// single test that used the real one would leave `swift test` unable to be interrupted and
/// would then `exit(0)` the runner on the next `SIGTERM` — reporting success for a run that
/// never finished.
actor RecordingSignalSources: SignalSourcing {

    private(set) var served: [Int32] = []
    private var handler: (@Sendable () -> Void)?

    func serve(_ signals: [Int32], with handler: @escaping @Sendable () -> Void) async {
        served += signals
        self.handler = handler
    }

    var isServing: Bool { handler != nil }

    /// Delivers a signal the way `DispatchSourceSignal` would: by calling the handler on an
    /// ordinary thread, in normal execution context.
    func fire() {
        handler?()
    }
}
