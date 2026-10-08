import FanKit
import SMCCore
import os

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

/// The ordered log of everything the teardown did.
///
/// A lock-guarded array and not an actor, for one reason: the process ending is **synchronous**
/// now (ADR 0012 — the watchdog ends it from its own queue, where there is no pool thread to
/// spend), so the recorder the terminate seam is given must be callable without `await`, and
/// it must still sit in the same order as the restores. `record(_:)` stays `async` so that
/// every existing `await journal.record(...)` keeps meaning what it meant; `recordNow(_:)` is
/// the same append without the suspension point.
final class TeardownJournal: Sendable {

    private let recorded = OSAllocatedUnfairLock(initialState: [TeardownEvent]())

    func record(_ event: TeardownEvent) async {
        recordNow(event)
    }

    func recordNow(_ event: TeardownEvent) {
        recorded.withLock { $0.append(event) }
    }

    /// The terminate seam for a test: records the exit, in order, and returns.
    var terminate: @Sendable (TeardownOutcome) -> Void {
        { [self] outcome in recordNow(.exited(outcome)) }
    }

    var events: [TeardownEvent] {
        get async { recorded.withLock { $0 } }
    }

    /// Every exit recorded, read without suspending.
    var exitsNow: [TeardownOutcome] {
        recorded.withLock { events in
            events.compactMap {
                if case .exited(let outcome) = $0 { return outcome }
                return nil
            }
        }
    }

    /// Just the scopes, for the assertions that are only about which restores happened.
    var restoreScopes: [FanRestoreScope] {
        get async {
            recorded.withLock { events in
                events.compactMap {
                    if case .restored(let scope, _) = $0 { return scope }
                    return nil
                }
            }
        }
    }

    /// Waits for an exit to be recorded: for a test that drives the teardown through a fired
    /// signal, whose handler runs it on a task of its own. A failsafe on readiness, not a
    /// bound on speed.
    func waitForExit() async -> Bool {
        await pollUntil { !exitsNow.isEmpty }
    }
}

/// `ScriptedControlPlane` with every restore written into a journal, together with the
/// control gate's state at that instant.
///
/// It wraps rather than replaces, exactly as `RegistryObservingPlane` does, so the firmware
/// under the observer is the shipped mock — stages, `WriteBehaviour`, the unscripted-input
/// refusal, all of it.
actor JournallingPlane: FanControlPlane {

    /// What this plane's *restore* verb does, which is the one axis `ScriptedControlPlane`
    /// cannot express.
    ///
    /// `WriteBehaviour.refused` models a firmware that says no; nothing models a **build**
    /// with no write path at all, and after ruling D15 those are different outcomes with
    /// different exit codes. `SMCFanControlPlane` is the thing being stood in for here, so
    /// `.refusedAsNotBuilt` throws exactly what it throws, from the same place: before any
    /// of the firmware underneath is touched, and therefore without a journal entry, because
    /// no restore reached the firmware to record.
    enum RestoreBehaviour: Sendable, Hashable {
        case reachTheFirmware
        case refusedAsNotBuilt
    }

    private let wrapped: ScriptedControlPlane
    private let journal: TeardownJournal
    private let restores: RestoreBehaviour
    private var gate: ControlMessageGate?

    init(
        journal: TeardownJournal,
        restores: RestoreBehaviour = .reachTheFirmware,
        wrapping wrapped: ScriptedControlPlane
    ) {
        self.journal = journal
        self.restores = restores
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

    /// Reported from the same field the restore verb reads, so a `.refusedAsNotBuilt` plane
    /// cannot be handed a lease it could never honour. `restores` is a `let` of a `Sendable`
    /// type, which is what makes it readable from outside the actor without an `await`.
    nonisolated var writeCapability: FanWriteCapability {
        restores == .refusedAsNotBuilt ? .notBuilt : .built
    }

    // MARK: - The observed verb

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        if restores == .refusedAsNotBuilt {
            throw FanControlPlaneError.controlPathNotBuilt
        }
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
