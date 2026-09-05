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

            // **A precondition that must hold**, so its result is asserted. Each caller
            // issues three subset reads before it can reach discovery — `FNum`, the batch of
            // fan keys, and this fan's `F0Md`, the last of which #148 added — so six is
            // "both callers have arrived", where the four this once waited for was reachable
            // with one caller done and the other one read in. Waiting rather than sleeping on
            // faith.
            #expect(await Self.waitUntil { await provider.subsetReadCount >= 6 })
            // **A grace period that must expire**, so its result is deliberately discarded.
            // It gives a second walk every chance to start: a build with the defect reaches
            // `readAllCount == 2` here, before anything is released, and the fixed build burns
            // the full limit instead. Naming the two apart is the point — a silently swallowed
            // expiry cannot tell "the second walk never started" from "the poll never ran".
            _ = await Self.waitUntil { await provider.readAllCount >= 2 }
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

    /// Polls `condition` until it holds, and answers **whether it ever did**.
    ///
    /// Expiry is not a failure here — the caller above uses this both to wait for something
    /// that must happen and to give something that must *not* happen its chance to — but it
    /// must not be invisible either. Returning `Bool` is what lets the caller say which of
    /// the two each wait is: one `#expect`s the answer, the other discards it, and neither
    /// can be mistaken for the other by a later reader.
    ///
    /// Sleeps with `Task.sleep(for:)` and swallows its cancellation error rather than
    /// throwing: a cancelled poll has not observed the condition, which is exactly what
    /// `false` says, and a `throws` here would give the caller a third outcome to interpret.
    private static func waitUntil(
        within limit: Duration = .milliseconds(500),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }
}
