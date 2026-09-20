import SMCCore

/// The snapshot path's view of the scheduler, and the only way to obtain one.
///
/// **In its own file so the `fileprivate` initialiser and its single caller sit together.**
/// That is what makes the guarantee structural rather than conventional: nothing outside this
/// file can construct a `SnapshotSensorReads` — `SMCReadScheduler`'s own body now cannot
/// either. Keeping the type beside the actor would have forced the initialiser wider than
/// `fileprivate` to split anything out, trading a real property for a line count, which is
/// the trade `ThermalEmergency.swift` refused and recorded in
/// [#128](https://github.com/blamechris/Aeolus/issues/128).
extension SMCReadScheduler {

    /// The snapshot path's `SensorProvider`, and the **only** one this type vends.
    ///
    /// There is deliberately no matching `supervisorReader`. A `SensorProvider` carries no
    /// priority in its signature, so a prioritised view of one is a value whose behaviour
    /// cannot be read off its type — and the one place that would be dangerous is the
    /// safety path. `SMCFanControlPlane` therefore takes this scheduler directly and names
    /// `.supervisor` itself, at the point the read is issued, so a supervisor read wired at
    /// snapshot priority is not a mistake anyone can make.
    ///
    /// `nonisolated` because it reads nothing: it hands back a reference to this actor
    /// wearing a different protocol, which is what lets the composition root wire it
    /// without an `await` in a synchronous `main`.
    nonisolated var snapshotReader: SnapshotSensorReads {
        SnapshotSensorReads(scheduler: self)
    }
}

/// The snapshot path's view of the scheduler, as a plain `SensorProvider`.
///
/// A view rather than a change to `ReadOnlyFanAuthority`'s shape: the snapshot path asks for
/// keys and gets outcomes, exactly as it did when it held `SMCSensorProvider` directly, and
/// scheduling is a property of where it was obtained rather than of what it does.
///
/// Its initialiser is `fileprivate`, so the only way to hold one is
/// `SMCReadScheduler.snapshotReader` — a reader detached from a scheduler is not a value
/// this module can construct.
struct SnapshotSensorReads: SensorProvider {

    private let scheduler: SMCReadScheduler

    fileprivate init(scheduler: SMCReadScheduler) {
        self.scheduler = scheduler
    }

    var identifier: String { scheduler.identifier }

    var isAvailable: Bool {
        get async { await scheduler.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        try await scheduler.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        try await scheduler.read(keys: keys, at: .snapshot)
    }
}

// `DiscoveredSensorKey` moved here from `ReadOnlyFanAuthority.swift` by
// [#194](https://github.com/blamechris/Aeolus/issues/194), which put that file over the
// 400-line threshold. It is the cheapest thing in it to move and the only *type* in it
// besides the actor, and this file is already the snapshot read path's other half — see the
// header above for why that half is separate. Nothing widens: it was `internal` there too.

/// A sensor key the helper found once, and the kind it was classified as at discovery.
///
/// Metadata, never a value. The kind is fixed at discovery for the same reason
/// `AeolusUI`'s `DiscoveredSensor` fixes it: it is a property of the key's name, not of
/// the reading, so re-deriving it every tick would be work that cannot produce a different
/// answer.
struct DiscoveredSensorKey: Sendable, Hashable {
    let key: String
    let kind: SensorReading.Kind
}
