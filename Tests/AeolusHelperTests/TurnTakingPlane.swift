import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// A scripted plane whose every call holds a real `SMCReadScheduler` turn, at its view's
/// admission, for as long as the call runs — so the scheduler sees § 3's calls as production's
/// would, one request per call, and reports two that overlap
/// (`SchedulerEvent.thermalCycleLaneOverlapped`).
///
/// `ScriptedControlPlane` has no scheduler: its views record which admission a call came through
/// and nothing waits. That cannot tell calls made one at a time from calls made together, and that
/// is the premise ADR 0012's 2026-10-18 amendment rests both lane bounds on. This double puts the
/// scheduler back under the scripted firmware: each call is registered with `TurnHolder`'s
/// provider under a token, read through the scheduler at the view's priority, and run by the
/// provider inside the turn that read is granted, so the turn is held across the whole call and
/// two calls in flight together are two requests outstanding together.
///
/// A recycle is a supervisor turn whatever the view (`FanControlPlane.admitted(at:)`), and § 3's
/// bridge requests its restore before it waits for the turn, as production's does.
///
/// `beforeSupervisorRead` is the one interference it offers: an effect run before the next
/// critical read at `.supervisor` asks for its turn — the grant's cold-cache sightedness read, in
/// a composed graph — and outside any turn, so what it runs can take turns of its own. Shared by
/// every view, and empty unless a test arms it.
struct TurnTakingPlane: FanControlPlane {

    let scripted: ScriptedControlPlane
    let turns: TurnHolder
    var beforeSupervisorRead = OneShotEffect()

    func admitted(at admission: PlaneAdmission) -> TurnTakingPlane {
        TurnTakingPlane(
            scripted: scripted.admitted(at: admission), turns: turns,
            beforeSupervisorRead: beforeSupervisorRead)
    }

    var writeCapability: FanWriteCapability { scripted.writeCapability }

    private var priority: SMCReadPriority { scripted.admission.priority }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        if priority == .supervisor { await beforeSupervisorRead.fire() }
        let scripted = scripted
        return try await turns.holding(at: priority) {
            try await scripted.readCriticalTemperatures(keys)
        }
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        let scripted = scripted
        return try await turns.holding(at: priority) {
            try await scripted.readEnvelope(ofFan: index)
        }
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        let scripted = scripted
        return try await turns.holding(at: priority) {
            try await scripted.readControlState(ofFan: index)
        }
    }

    func reconnect() async throws {
        let scripted = scripted
        try await turns.holding(at: .supervisor) { try await scripted.reconnect() }
    }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        let scripted = scripted
        try await turns.holding(at: priority) { try await scripted.restoreToAutomatic(scope) }
    }

    func beginEngagement(fanAt index: Int) {
        scripted.beginEngagement(fanAt: index)
    }

    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        let scripted = scripted
        return try await turns.holding(at: priority) {
            try await scripted.engageManualControl(of: fan)
        }
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        let scripted = scripted
        return try await turns.holding(at: priority) { try await scripted.commandTarget(target) }
    }

    func bridgeThenRestore(_ target: AuthorisedFanTarget) async -> BridgeOutcome {
        scripted.ledger.restoreRequested(.fan(target.fanIndex))
        let firmware = scripted.firmware
        let admission = scripted.admission
        do {
            return try await turns.holding(at: priority) {
                await firmware.bridgeTurn(target, at: admission)
            }
        } catch {
            Issue.record("the scheduler refused § 3's bridge a turn: \(error)")
            return BridgeOutcome(maximum: .failure(error), restore: .failure(error))
        }
    }

    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        await scripted.prepareWritePath(enumerating: fans)
    }
}

/// The scheduler a `TurnTakingPlane` holds its turns at, and the provider that runs each call
/// inside one.
final class TurnHolder: Sendable {

    let scheduler: SMCReadScheduler
    private let provider = CallRunningProvider()

    init(observer: some SchedulerObserving) {
        scheduler = SMCReadScheduler(provider: provider, observer: observer)
    }

    /// Runs `call` inside a turn at `priority`, and answers what it answered.
    func holding<T: Sendable>(
        at priority: SMCReadPriority, _ call: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let answer = Answer<T>()
        let token = provider.register {
            do {
                answer.set(.success(try await call()))
            } catch {
                answer.set(.failure(error))
            }
        }
        _ = try await scheduler.read(keys: [token], at: priority)
        return try answer.take()
    }

    /// One call's answer, set inside the turn and taken after it.
    private final class Answer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, any Error>?

        func set(_ result: Result<T, any Error>) {
            lock.withLock { self.result = result }
        }

        func take() throws -> T {
            let result = lock.withLock { self.result }
            guard let result else { throw TurnHolderError.callNeverRan }
            return try result.get()
        }
    }
}

enum TurnHolderError: Error {
    case callNeverRan
}

/// An effect run at most once: armed by a test, fired by the double that holds it.
actor OneShotEffect {
    private var effect: (@Sendable () async -> Void)?

    /// Whether the armed effect has run.
    private(set) var didFire = false

    func arm(_ effect: @escaping @Sendable () async -> Void) {
        self.effect = effect
    }

    /// Runs the armed effect, if there is one, and disarms it first: whatever the effect does
    /// cannot fire it again.
    func fire() async {
        guard let effect else { return }
        self.effect = nil
        didFire = true
        await effect()
    }
}

/// A provider whose read of a token runs the call registered under it, so the scheduler's turn is
/// held for as long as the call runs — and then for `holdYields` yields more.
///
/// The yields are what make two calls in flight together reliably **overlap**. A call to the
/// scripted firmware is a few actor hops, and two concurrent callers that reach § 3's actor one
/// after the other can each finish their turn before the other asks for one, so a task group
/// would pass unseen. Held across the yields, the first turn is still outstanding when the
/// second caller reaches the scheduler, which is the moment production's overlap is about: a
/// real turn is round trips long. Suspending, never blocking the pool.
final class CallRunningProvider: SensorProvider, @unchecked Sendable {

    /// How many yields a turn is held for after its call returns.
    static let holdYields = 64

    let identifier = "call-running"

    private let lock = NSLock()
    private var calls: [String: @Sendable () async -> Void] = [:]

    var isAvailable: Bool {
        get async { true }
    }

    func readAll() async throws -> [SensorReading] { [] }

    func register(_ call: @escaping @Sendable () async -> Void) -> String {
        let token = UUID().uuidString
        lock.withLock { calls[token] = call }
        return token
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        for key in keys {
            let call = lock.withLock { calls.removeValue(forKey: key) }
            await call?()
            for _ in 0..<Self.holdYields { await Task.yield() }
        }
        return keys.map { SensorReadOutcome(key: $0, result: .reading($0, 0, kind: .unknown)) }
    }
}
