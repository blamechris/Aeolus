import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// Discovery under **concurrency**, which is a different question from discovery under
/// repetition and needs a different double to ask.
///
/// `ReadOnlyFanAuthorityTests.discoveryRunsOnce` issues snapshots one after another through
/// a provider that returns immediately, so it can only ever observe the cache being
/// consulted. The suite here drives two snapshots that overlap *inside* `readAll()`, which
/// is the only way to see [#149](https://github.com/blamechris/Aeolus/issues/149) at all.
///
/// Its own file rather than another block in that suite: those tests are about what one
/// snapshot says, and this one is about what two of them do to each other.
@Suite("ReadOnlyFanAuthority discovery, concurrently")
struct ReadOnlyFanAuthorityDiscoveryTests {

    private static let log = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Discovery")

    private func authority(provider: some SensorProvider) -> ReadOnlyFanAuthority {
        ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: Self.log,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger(),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    /// The concurrency claim, which `discoveryRunsOnce` above cannot make.
    ///
    /// That test issues three snapshots **sequentially**, so it proves the cache is
    /// consulted and says nothing about two snapshots racing the first tick — the
    /// interleaving [#149](https://github.com/blamechris/Aeolus/issues/149) is about. Two
    /// clients connect at launch (the app and `fanctl`), one `ReadOnlyFanAuthority` serves
    /// both, and `snapshot()` suspends inside an actor and is therefore reentrant, so the
    /// race is the ordinary case at daemon start rather than a contrived one.
    ///
    /// The double suspends *inside* `readAll()`, which is what makes the second caller
    /// arrive while the first walk is still running. It also answers a **shorter key set**
    /// to the second walk, because that is what real hardware does — `SMCSensorProvider`
    /// skips a key whose read or decode fails without failing the walk — and a
    /// last-writer-wins cache assignment then keeps the short set for the life of the
    /// process. Both halves are asserted: the count, and the key set a later snapshot sees.
    ///
    /// **Mutation:** restore the check-then-act — read `discoveredSensors`, and on a miss
    /// `discovered = try await discoverSensorKeys(); discoveredSensors = discovered` —
    /// instead of holding the in-flight `Task`. Run: red, on `readAllCount == 1`.
    @Test("Two snapshots racing the first tick run one discovery between them")
    func concurrentSnapshotsShareOneDiscovery() async throws {
        let full: [SensorReading] = [
            .fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius),
            .fake(key: "TC0D", value: 41.0, kind: .temperatureCelsius),
        ]
        // The second walk loses a key — a transient per-key failure inside `readAll()`,
        // which that call reports as a smaller list rather than as an error.
        let short: [SensorReading] = [.fake(key: "TC0P", value: 44.5, kind: .temperatureCelsius)]
        let provider = GatedDiscoveryProvider(
            keyedResults: fanKeyResults(
                fanCount: 1,
                extraKeys: [
                    "TC0P": .reading("TC0P", 44.5, kind: .temperatureCelsius),
                    "TC0D": .reading("TC0D", 41.0, kind: .temperatureCelsius),
                ]),
            readingsPerCall: [full, short])
        let authority = authority(provider: provider)

        let racing = try await withThrowingTaskGroup(of: SystemSnapshot.self) { group in
            group.addTask { try await authority.snapshot() }
            group.addTask { try await authority.snapshot() }

            // Both callers get past enumeration — two subset reads each — before either can
            // reach discovery, so this waits for the arrival rather than sleeping on faith.
            try await Self.waitUntil { await provider.subsetReadCount >= 4 }
            // Then give a second walk every chance to start, so that a build with the defect
            // reaches `readAllCount == 2` before anything is released. Under the fix this
            // simply expires, which is what the assertion below is measuring.
            try await Self.waitUntil { await provider.readAllCount >= 2 }
            await provider.release()

            var snapshots: [SystemSnapshot] = []
            for try await snapshot in group { snapshots.append(snapshot) }
            return snapshots
        }

        #expect(
            await provider.readAllCount == 1,
            "a second snapshot arriving during discovery started a second full walk")
        #expect(racing.count == 2)
        // Neither client is served a different machine from the other.
        #expect(Set(racing[0].sensors.map(\.key)) == Set(racing[1].sensors.map(\.key)))

        // And the key set that got cached is not the short one: a snapshot after the race
        // still reports both sensors.
        let later = try await authority.snapshot()
        #expect(later.sensors.map(\.key).sorted() == ["TC0D", "TC0P"])
    }

    /// Polls `condition` until it holds or the deadline expires. Expiry is not a failure:
    /// the caller above uses it both to wait for something that must happen and to give
    /// something that must *not* happen its chance to.
    private static func waitUntil(
        within limit: Duration = .milliseconds(500),
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
