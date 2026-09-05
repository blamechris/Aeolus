import AeolusXPC
import FanKit
import Foundation
import SMCCore

/// E2's `FanAuthority`: it reports the machine truthfully and refuses everything that
/// would need a write path, because there is no write path.
///
/// ## What it serves, and what it refuses
///
/// `snapshot` returns **real data** — fans through `SMCFanEnumeration`, sensors through
/// `SMCCore`'s public read API, each fan's mode through `F<n>Md` — with `activeLease: nil`
/// and every fan `manualControlAvailability: .unavailable(.writePathNotBuilt)`. That makes
/// E2 demonstrable end to end on hardware, app to XPC to root helper to SMC and back, with
/// no write existing anywhere in the tree.
///
/// The mode is **read, not assumed** — a literal `.automatic` until
/// [#148](https://github.com/blamechris/Aeolus/issues/148). Nothing in this build can take a
/// fan off automatic control, so "every fan is automatic" was true of the executable and
/// never a statement about the machine; a fan left in manual by a crashed helper, a reboot,
/// or another vendor's tool is exactly the case a user needs to be told about. See `fanMode`
/// below and `ReadOnlyFanReport.controlMode(_:)`.
///
/// `acquireLease`, `renewLease`, `releaseLease` and `apply` **refuse** with
/// `.manualControlUnavailable(.writePathNotBuilt)`. Never a stubbed success: a lease a
/// client can acquire that controls nothing is a lie about control, which is `CLAUDE.md`
/// rule 6's exact shape. A UI shown that lease would draw a slider that moves and does
/// nothing.
///
/// `restoreAllToAutomatic` **succeeds, truthfully**: in E2 every fan is already automatic,
/// because nothing here can make one anything else. That is a real answer rather than a
/// stub, and it wires and tests the panic path from the day the boundary exists rather
/// than the day the write path does.
///
/// ## Sensor labels are `nil`, permanently — a rule, not a `TODO`
///
/// Every `SensorSample` this type produces carries `label: nil` and
/// `labelConfidence: nil`, and it always will.
///
/// The catalog lives at `~/Library/Application Support/Aeolus/catalog.json` when a user
/// has overridden it — a **user-writable file**, read by a **root daemon**, which is a
/// shape this project does not want at any price. The bundled catalog is not
/// user-writable, but reading it is no better an idea: decoration is presentation, both
/// clients already own a `SensorLabelSource`, and a label the helper attached would be a
/// second opinion competing with theirs. The optional fields stay in the DTO because the
/// wire format is shared with clients that do decorate.
///
/// ## `readAll()` is discovery, never a refresh
///
/// ADR 0006 makes the helper the machine's only continuous SMC reader whenever the app is
/// running, so `snapshot` is on a 1 Hz path and `readAll()` cannot be on it. The key set
/// is discovered once and cached; every snapshot after that refreshes by subset read.
///
/// **The cache holds metadata only — keys and kinds, never values.** A cached reading is
/// a stale reading presented as current, which is the same defect as a fabricated one with
/// a longer fuse.
///
/// ### What that costs, measured
///
/// `Mac16,5` / macOS 26.5.2 exposes **2929** readable sensor keys. The first snapshot,
/// which pays for discovery, costs 2.2 s against a warm SMC key cache and 5.9 s against a
/// cold one; every snapshot after it costs **~0.5 s**. Keeping discovery off the hot path
/// is therefore doing its job — and half a second per second is still a great deal of a
/// root daemon's time, plus a 2929-sample payload of **~138 KB** crossing the boundary every
/// tick. ADR 0006's "snapshot cost at 1 Hz is accepted" was written before anyone measured
/// it; the remedy it names, and the only one it permits, is an additive subset-request
/// capability within v1 — never a second continuous reader. Not built in #72, which has no
/// app-side client to ask for a subset.
/// `Tests/AeolusHelperTests/HelperHardwareTests` re-measures it on every hardware run.
actor ReadOnlyFanAuthority: FanAuthority {

    private let provider: any SensorProvider
    private let log: HelperLog
    private let now: @Sendable () -> Date

    /// `docs/SAFETY.md` § 3's latch, read once per snapshot.
    ///
    /// **Read from the mechanism, never written as a literal.** Until #125 this field was
    /// `false` in the initialiser of `SystemSnapshot` below, with a comment saying E2 has no
    /// thermal supervisor — true at the time, and the shape that goes quietly wrong the day
    /// it stops being true. Sourcing it from the latch now means the field moves when the
    /// mechanism does, and `connectionDidInvalidate(_:)` is already wired the same way and
    /// for the same reason.
    ///
    /// In *this* build the answer is still always `false`, and honestly so: every path that
    /// would grant a lease refuses, so no fan is ever off automatic control, so
    /// `ThermalEmergency` has nothing to fire on. What changed is where the answer comes
    /// from.
    ///
    /// **Required, with no default.** A defaulted latch would compile and report a bit
    /// nothing sets — see `LeaseAuthority`'s field of the same name.
    private let thermalEmergency: ThermalEmergencyLatch

    /// `docs/SAFETY.md` § 5's ledger, read once per snapshot.
    ///
    /// **Read from the mechanism, never written as a literal** — the same rule as the latch
    /// above, and it is here because this field had exactly the defect that rule describes.
    /// `fanState(for:)` wrote `isReclaimedBySystem: false` with a comment saying E2 has no
    /// watchdog: true when it was written, and the shape that goes quietly wrong the day it
    /// stops being true. `ReclamationWatchdog` is now that day.
    ///
    /// In *this* build the answer is still always `false`, and honestly so: every path that
    /// would grant a lease refuses, so no fan is ever off automatic control, so nothing can
    /// take one back. What changed is where the answer comes from.
    ///
    /// **Required, with no default**, for the latch's reason: a defaulted ledger would
    /// compile and report a bit nothing sets.
    private let reclamation: ReclamationLedger

    /// The sensor keys this machine exposes, discovered once. `nil` until the first
    /// successful discovery; a failed discovery leaves it `nil` so the next snapshot tries
    /// again rather than caching a machine with no sensors on it.
    private var discoveredSensors: [DiscoveredSensorKey]?

    /// The discovery that is running right now, held so that a snapshot arriving during one
    /// **awaits it** instead of starting a second.
    ///
    /// The task, not just its result. `discoveredSensors` above is only assigned when a walk
    /// *completes*, so it stays `nil` for the whole 2.2 s (warm) to 5.9 s (cold) walk, and a
    /// check-then-act around it let every snapshot arriving in that window start its own —
    /// [#149](https://github.com/blamechris/Aeolus/issues/149). At daemon launch that window
    /// is exactly when both clients connect, and `snapshot()` suspends inside an actor and is
    /// therefore reentrant, so the race was the ordinary case rather than an exotic one.
    ///
    /// Three harms, of which the count is only the first: `SMCReadScheduler` exempts
    /// `readAll()` from taking a turn on the grounds that it "runs once for the life of the
    /// process". The second is silent — two walks can return **different key sets**, because
    /// `SMCSensorProvider.readAll()` skips a key whose read or decode fails without failing
    /// the walk, and the cache took whichever finished last, so a short set was kept for the
    /// life of the daemon. The third: a *failed* second walk returned `[]` to its client
    /// while the first got the full set from the same instant.
    ///
    /// Cleared when the walk ends, so the retry-after-failure rule below still holds: the
    /// next snapshot starts a fresh discovery rather than awaiting a task that already threw.
    private var discovery: Task<[DiscoveredSensorKey], Error>?

    /// `F<n>Md`, read once per fan per snapshot, so that who owns a fan is **observed rather
    /// than assumed**.
    ///
    /// **Required, with no default**, for the latch's and the ledger's reason — and this is
    /// the third instance of the same defect, which is why the rule is stated three times in
    /// this file. `mode: .automatic` was a literal: true of every fan this build can
    /// *produce*, and not a statement about the machine, which is what a client reads it as
    /// ([#148](https://github.com/blamechris/Aeolus/issues/148)).
    ///
    /// Narrow on purpose: `FanModeSensing` has one read verb and no write side, so nothing
    /// reachable from the snapshot path can command a fan. `FanStateSensing` refines it, so
    /// [#103](https://github.com/blamechris/Aeolus/issues/103) can hand the supervisor's own
    /// control plane here without changing anything above — see `FanModeSensing` for why the
    /// snapshot does not simply take one today.
    private let fanMode: any FanModeSensing

    init(
        provider: some SensorProvider,
        fanMode: some FanModeSensing,
        log: HelperLog,
        thermalEmergency: ThermalEmergencyLatch,
        reclamation: ReclamationLedger,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.fanMode = fanMode
        self.log = log
        self.thermalEmergency = thermalEmergency
        self.reclamation = reclamation
        self.now = now
    }

    // MARK: - Reporting

    func snapshot() async throws -> SystemSnapshot {
        let fans = try await SMCFanEnumeration.enumerate(provider: provider)
        let modes = await observedModes(ofFans: fans.fanIndices)
        let sensors = await readSensors()
        let isThermalEmergencyActive = await thermalEmergency.isActive
        // One read of the ledger per snapshot rather than one per fan: a snapshot carries a
        // single `capturedAt`, and two fans answered from two different views of who holds
        // them would be one instant's report built from two. The causes travel together for
        // the same reason — reading "which fans are reclaimed" and "which are blind" as two
        // hops could observe one fan in neither set or in both.
        let reclamationCauses = await reclamation.causes

        return SystemSnapshot(
            fans: fans.fans.map {
                ReadOnlyFanReport.fanState(
                    for: $0, reclamation: reclamationCauses, mode: modes[$0.index])
            },
            sensors: sensors,
            // No lease can exist: every path that would grant one refuses below.
            activeLease: nil,
            isThermalEmergencyActive: isThermalEmergencyActive,
            capturedAt: now()
        )
    }

    /// Who owns each enumerated fan, as `F<n>Md` answered this tick.
    ///
    /// Never throws, and a fan whose mode did not read is **absent from the result** rather
    /// than defaulted into it: `ReadOnlyFanReport` decides what to say about a gap, and can
    /// only decide it if it can tell a gap from an answer. One key that disappeared must not
    /// cost the client the whole snapshot, exactly as in `readSensors()`.
    ///
    /// One read per fan rather than a batched one, because `FanModeSensing` is per-fan so
    /// that E5's control plane satisfies it unchanged — one or two extra turns against the 48
    /// a full snapshot already takes.
    private func observedModes(ofFans indices: [Int]) async -> [Int: FirmwareFanMode] {
        var modes: [Int: FirmwareFanMode] = [:]
        modes.reserveCapacity(indices.count)
        for index in indices {
            do {
                modes[index] = try await fanMode.readMode(ofFan: index)
            } catch {
                log.fanModeUnreadable(fanIndex: index, reason: String(describing: error))
            }
        }
        return modes
    }

    /// The fans this authority enumerated, for the fan-index check that decides which fans
    /// a lease may cover.
    ///
    /// It lives here because the enumeration lives here: `AeolusXPCValidation` is pure and
    /// the listener has no hardware. E5 calls this before honouring a lease request; E2
    /// refuses every lease before it gets that far, which is why nothing calls it yet.
    func enumeratedFanIndices() async throws -> Set<Int> {
        try await SMCFanEnumeration.enumerate(provider: provider).enumeratedFanIndices
    }

    // MARK: - Control, all refused

    func acquireLease(
        _ request: LeaseRequest,
        from connection: ConnectionID
    ) async throws -> Lease {
        throw Self.noWritePath
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        throw Self.noWritePath
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        throw Self.noWritePath
    }

    func apply(
        _ settings: [FanSetting],
        leaseID: UUID,
        from connection: ConnectionID
    ) async throws {
        throw Self.noWritePath
    }

    /// Succeeds as a truthful no-op.
    ///
    /// Not a stub. In E2 every fan really is under Apple's thermal management, because
    /// nothing in this build can take one off it — so "every fan is now automatic" is a
    /// correct statement about the machine after this call, which is the only thing the
    /// caller was promised.
    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        log.restoredAllToAutomatic(connection: connection)
    }

    /// Nothing to release: no lease can exist in E2, so no connection can be holding one.
    ///
    /// Deliberately still wired all the way from the invalidation handler. E5 fills this
    /// in; if the event did not already arrive here, filling it in would mean editing the
    /// listener. See `FanAuthority.connectionDidInvalidate(_:)`.
    func connectionDidInvalidate(_ connection: ConnectionID) async {}

    /// The one refusal every control path here raises.
    private static let noWritePath = AeolusXPCFault.manualControlUnavailable(
        reason: .writePathNotBuilt)

    // MARK: - Sensors

    /// Reads every discovered sensor key by subset read, discovering the key set first if
    /// this is the first snapshot.
    ///
    /// Never throws. A sensor set that could not be read is a degraded snapshot, not a
    /// failed one: the fans are the part a client cannot do without, and failing a whole
    /// snapshot because one temperature key disappeared would take the fan readings with
    /// it.
    private func readSensors() async -> [SensorSample] {
        let discovered: [DiscoveredSensorKey]
        if let discoveredSensors {
            discovered = discoveredSensors
        } else {
            do {
                discovered = try await discoverSensorKeys()
            } catch {
                log.sensorDiscoveryFailed(reason: String(describing: error))
                return []
            }
        }

        guard !discovered.isEmpty else { return [] }

        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: discovered.map(\.key))
        } catch {
            log.sensorRefreshFailed(reason: String(describing: error))
            return []
        }

        var kindsByKey: [String: SensorReading.Kind] = [:]
        kindsByKey.reserveCapacity(discovered.count)
        for sensor in discovered {
            kindsByKey[sensor.key] = sensor.kind
        }

        // A key that failed this read is omitted, never carried as a zero. `SensorSample`
        // has a non-optional value, so within v1 there is no shape of it that says "this
        // key is here and did not read" — and inventing a number for a sensor is the
        // fabricated-zero defect this project has stamped out three times already.
        // Omission loses the fact that the key exists; a fabricated 0 °C would lose the
        // truth. Only one of those is recoverable.
        //
        // A read that *succeeded* and decoded to a non-finite `Double` is omitted by the
        // same rule, and that clause is the load-bearing one. `SMCValue.scalar()` applies
        // no finiteness guard, so a byte-swapped `flt` or `ioft` can decode to
        // `±.infinity` or `.nan` on an otherwise-successful read — the case
        // `SMCFanEnumeration.checked` already refuses for the three fan keys, which this
        // path meets across ~500x more keys than that one does. Carrying one here would
        // not merely be a wrong number: `AeolusXPCCoding.encoder()` is a bare
        // `JSONEncoder`, so its `nonConformingFloatEncodingStrategy` is `.throw`, and the
        // key set is discovered once and cached for the life of the process. One such key
        // would therefore fail the encode of *every* snapshot from then until exit, taking
        // the other 2928 sensors and both fans with it — and under ADR 0006 the app has
        // stopped its own polling, so the user sees nothing rather than one bad row.
        return outcomes.compactMap { outcome in
            guard case .success(let reading) = outcome.result, reading.value.isFinite
            else { return nil }
            return SensorSample(
                key: reading.key,
                label: nil,
                labelConfidence: nil,
                value: reading.value,
                unit: ReadOnlyFanReport.unit(for: kindsByKey[reading.key] ?? reading.kind)
            )
        }
    }

    /// The one `readAll()` in the helper: **at most one walk is ever in flight**, and after
    /// a successful one there are no more for the life of the process.
    ///
    /// Two claims because they are enforced in two places, and one of them used to be a habit
    /// rather than an invariant. The cache stops a *later* snapshot walking again;
    /// `discovery` stops a *concurrent* one, by handing the arrival the running task to
    /// await. A snapshot arriving during a walk therefore gets the key set of the walk that
    /// was already running rather than a second opinion about the machine — and a walk that
    /// throws is not cached, so the next snapshot tries again.
    private func discoverSensorKeys() async throws -> [DiscoveredSensorKey] {
        let walk: Task<[DiscoveredSensorKey], Error>
        if let discovery {
            walk = discovery
        } else {
            walk = Task { [self] in try await walkEveryKey() }
            discovery = walk
        }

        // Cleared however this ends, including a throw: a walk that failed must not be the
        // thing every later snapshot awaits the answer of. `==` rather than an unconditional
        // clear because the caller that merely *joined* this walk must not wipe a newer one.
        defer { if discovery == walk { discovery = nil } }

        let discovered = try await walk.value
        discoveredSensors = discovered
        return discovered
    }

    /// The walk itself, and the only call to `SensorProvider.readAll()` in the helper.
    private func walkEveryKey() async throws -> [DiscoveredSensorKey] {
        let started = ContinuousClock.now
        let readings = try await provider.readAll()

        var seen: Set<String> = []
        seen.reserveCapacity(readings.count)
        var discovered: [DiscoveredSensorKey] = []
        discovered.reserveCapacity(readings.count)
        for reading in readings where seen.insert(reading.key).inserted {
            discovered.append(DiscoveredSensorKey(key: reading.key, kind: reading.kind))
        }
        discovered.sort { $0.key < $1.key }

        log.discoveredSensors(count: discovered.count, duration: ContinuousClock.now - started)
        return discovered
    }
}

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
