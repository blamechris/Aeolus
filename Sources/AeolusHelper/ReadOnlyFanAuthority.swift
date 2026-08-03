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
/// `SMCCore`'s public read API — with `activeLease: nil`, every fan `.automatic`, and
/// every fan `manualControlAvailability: .unavailable(.writePathNotBuilt)`. That makes E2
/// demonstrable end to end on hardware, app to XPC to root helper to SMC and back, with no
/// write existing anywhere in the tree.
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
/// tick.
/// ADR 0006's "snapshot cost at 1 Hz is accepted" was written before anyone measured it;
/// the remedy it names, and the only one it permits, is an additive subset-request
/// capability within v1 — never a second continuous reader. Not built in #72, which has no
/// app-side client to ask for a subset.
/// `Tests/AeolusHelperTests/HelperHardwareTests` re-measures it on every hardware run.
actor ReadOnlyFanAuthority: FanAuthority {

    private let provider: any SensorProvider
    private let log: HelperLog
    private let now: @Sendable () -> Date

    /// The sensor keys this machine exposes, discovered once. `nil` until the first
    /// successful discovery; a failed discovery leaves it `nil` so the next snapshot tries
    /// again rather than caching a machine with no sensors on it.
    private var discoveredSensors: [DiscoveredSensorKey]?

    init(
        provider: some SensorProvider,
        log: HelperLog,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.log = log
        self.now = now
    }

    // MARK: - Reporting

    func snapshot() async throws -> SystemSnapshot {
        let fans = try await SMCFanEnumeration.enumerate(provider: provider)
        let sensors = await readSensors()

        return SystemSnapshot(
            fans: fans.fans.map(Self.fanState(for:)),
            sensors: sensors,
            // No lease can exist: every path that would grant one refuses below.
            activeLease: nil,
            // E2 has no thermal supervisor, so nothing is engaged. This is a statement
            // about the helper, and it is true of this helper.
            isThermalEmergencyActive: false,
            capturedAt: now()
        )
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
                discoveredSensors = discovered
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
                unit: Self.unit(for: kindsByKey[reading.key] ?? reading.kind)
            )
        }
    }

    /// The one `readAll()` in the helper. Called at most once per process, on the first
    /// snapshot.
    private func discoverSensorKeys() async throws -> [DiscoveredSensorKey] {
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

    // MARK: - Mapping

    /// One enumerated fan as the wire reports it.
    ///
    /// Nothing here is clamped, floored, or nudged: `F0Ac` was measured at 1343.07 against
    /// a declared `F0Mn` of 1350 on this project's development machine, so a reading below
    /// the declared minimum is a legitimate observation. Clamping governs targets on the
    /// write path, never observations — see `SMCFanEnumeration`.
    private static func fanState(for fan: SMCFanEnumeration.Fan) -> FanState {
        FanState(
            index: fan.index,
            // `{fds`, the firmware fan-descriptor struct, is absent on this project's
            // development machine and is not read anywhere in the tree. No name is
            // honest; an invented one is not.
            firmwareName: nil,
            actualRPM: reading(for: fan.actual),
            minimumRPM: reading(for: fan.minimum),
            maximumRPM: reading(for: fan.maximum),
            // "No target is set" rather than "the target could not be read": this helper
            // is asking for nothing, and that is an answer.
            targetRPM: nil,
            mode: .automatic,
            isReclaimedBySystem: false,
            manualControlAvailability: .unavailable(.writePathNotBuilt)
        )
    }

    private static func reading(for outcome: SensorReadOutcome) -> FanReading {
        switch outcome.result {
        case .success(let value):
            return .measured(value.value)
        case .failure(.unknownKey(let key)):
            return .unavailable(reason: "\(key) is not present on this machine")
        case .failure(.readFailed(let reason)), .failure(.notDecodable(let reason)):
            return .unavailable(reason: reason)
        }
    }

    /// Maps `SMCCore`'s physical kind onto the wire's unit vocabulary.
    ///
    /// `SMCSensorProvider` classifies conservatively — only the fan-key naming convention
    /// is treated as known, everything else is `.unknown` — and that conservatism is
    /// carried across the boundary rather than improved on here. A helper guessing
    /// "starts with T, therefore Celsius" would be inventing the decoration this type has
    /// just finished declining to attach.
    private static func unit(for kind: SensorReading.Kind) -> SensorSample.Unit {
        switch kind {
        case .temperatureCelsius: return .celsius
        case .rpm: return .rpm
        case .watts: return .watts
        case .volts: return .volts
        case .amps: return .amps
        case .percent: return .percent
        case .unknown: return .unknown
        }
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
