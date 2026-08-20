import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The read-only authority against the real SMC.
///
/// Gated on `HardwareIdentity.current()` matching this project's sole verified machine and
/// not merely on `SMCConnection.isHardwareAvailable()`, which is true of every Mac
/// including a fanless Air. The assertions below are facts about `Mac16,5` — that it has
/// fans at all, that it exposes sensor keys — so on any other machine they would fail
/// honestly rather than because something is broken. CI has no SMC and skips the lot.
/// `.serialized` because these tests contend for one piece of hardware. Run in parallel,
/// three concurrent `readAll()` enumerations against the same SMC turned a 5.9 s cold
/// discovery into 24.9 s and a 0.35 s warm snapshot into 0.89 s — measured, not guessed.
/// A timing assertion whose number depends on what else the suite happens to be doing is
/// not a measurement.
@Suite(
    "The helper's read path, real hardware",
    .serialized,
    .enabled(
        if: SMCConnection.isHardwareAvailable()
            && HardwareIdentity.current().modelIdentifier == "Mac16,5")
)
struct HelperHardwareTests {

    private static let log = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Hardware")

    @Test("A snapshot from real hardware reports real fans, controllable by nothing")
    func snapshotFromRealHardware() async throws {
        let authority = ReadOnlyFanAuthority(
            provider: SMCSensorProvider(), log: Self.log,
            thermalEmergency: ThermalEmergencyLatch())

        let snapshot = try await authority.snapshot()

        #expect(!snapshot.fans.isEmpty)
        #expect(!snapshot.sensors.isEmpty)
        #expect(snapshot.activeLease == nil)
        #expect(snapshot.isThermalEmergencyActive == false)
        for fan in snapshot.fans {
            #expect(fan.mode == .automatic)
            #expect(fan.targetRPM == nil)
            #expect(fan.manualControlAvailability == .unavailable(.writePathNotBuilt))
        }
        // Deliberately no assertion comparing `actualRPM` against `minimumRPM`: `F0Ac` was
        // measured at 1343.07 against a declared `F0Mn` of 1350 on this machine, so a
        // reading below the declared minimum is a legitimate observation and a test
        // encoding the opposite would be wrong about real hardware.

        // The rule, checked against the hardware that would otherwise tempt someone to
        // decorate: the root daemon attaches no labels, ever.
        for sensor in snapshot.sensors {
            #expect(sensor.label == nil)
            #expect(sensor.labelConfidence == nil)
        }
    }

    /// ADR 0006 makes the helper the machine's only continuous SMC reader whenever the
    /// app is running, which puts `snapshot` on a 1 Hz path. The first snapshot pays for
    /// discovery; every one after it must be a subset read.
    ///
    /// ## What this measured, which is not what the ADR assumed
    ///
    /// On `Mac16,5` / macOS 26.5.2, serialised: this machine exposes **2929** readable
    /// sensor keys. The first snapshot costs 2.2 s against a warm SMC key cache and 5.9 s
    /// against a cold one; a warm snapshot costs **~0.5 s**. Discovery is off the hot path
    /// as designed — a 4x to 11x difference — but **half a second is not "cheap at 1 Hz"**:
    /// it is half the interval spent in a root daemon reading firmware, plus a 2929-sample
    /// payload crossing the boundary every second. ADR 0006's "snapshot cost at 1 Hz is
    /// accepted" was written without a measurement to hand, and this is the measurement.
    /// The remedy that ADR already names is an additive subset-request capability within
    /// v1, never a second continuous reader. Recorded here rather than fixed here: #72
    /// builds the helper side, and the app-side client that would ask for a subset is not
    /// in it.
    ///
    /// The payload is measured here too, because the byte count arguably decides whether the
    /// subset-request capability is required more clearly than the half-second does:
    /// **~138 KB** of JSON for 2929 samples, so roughly 138 KB/s crossing the boundary at
    /// 1 Hz. Six runs on this machine have landed between 137,750 and 138,402 bytes, the last
    /// digits moving with how many significant figures the readings themselves print to.
    /// Treat that as provenance, not a bound: a narrower range was quoted here until a run
    /// fell below it. Printed rather than asserted, for the same reason the sensor count is:
    /// a figure that drifts with the machine is a measurement, not a budget.
    ///
    /// ## What the two-second threshold actually buys, stated honestly
    ///
    /// It is a **coarse regression tripwire, and it does not kill the mutation it was
    /// written for.** Measured on this machine, a warm snapshot costs **roughly half a
    /// second** — six runs have ranged from 0.48 s to 0.60 s — so two seconds is only about
    /// **3x to 4x** it, not the order of magnitude an earlier version of this comment
    /// claimed.
    ///
    /// The mutation it names — `readAll()` back on every snapshot, reproduced by making
    /// `readSensors()` ignore its cached key set — **survives**. Three runs put `warmest` at
    /// 1.216 s to 1.221 s, well inside the threshold, and `warmest < cold` holds too because
    /// the mutant's first snapshot still pays discovery on top of the re-read. The **2.46 s**
    /// figure once quoted here as the mutant's cost is the mutant's *first* snapshot, which
    /// includes discovery; the assertion is on `warmest`, so that number was never the one
    /// the threshold is compared against.
    /// [#97](https://github.com/blamechris/Aeolus/issues/97) tracks making this assertion
    /// structural — counting `readAll()` calls — rather than timed.
    ///
    /// The threshold is still **not** to be loosened, since raising it toward the cold cost
    /// gives up what little it does catch; it just must not be read as proof that discovery
    /// cannot return to the hot path. If this ever goes flaky, the finding is that the
    /// snapshot got slower, which is the thing worth knowing.
    @Test("Discovery stays off the snapshot path")
    func warmSnapshotIsCheap() async throws {
        let authority = ReadOnlyFanAuthority(
            provider: SMCSensorProvider(), log: Self.log,
            thermalEmergency: ThermalEmergencyLatch())

        let coldStart = ContinuousClock.now
        let first = try await authority.snapshot()
        let cold = ContinuousClock.now - coldStart

        var warmest = Duration.zero
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let snapshot = try await authority.snapshot()
            warmest = max(warmest, ContinuousClock.now - started)
            #expect(!snapshot.fans.isEmpty)
        }

        let encoded = try AeolusXPCCoding.encoder().encode(first)

        print(
            """
            snapshot cost on \(HardwareIdentity.current().modelIdentifier ?? "unknown"): \
            \(first.sensors.count) sensors; first (with discovery) \(cold); \
            warmest of three subsequent \(warmest); \
            encoded payload \(encoded.count) bytes, which is the per-tick wire cost at 1 Hz
            """
        )
        #expect(warmest < .seconds(2))
        #expect(warmest < cold, "discovery is supposed to be the expensive one")
    }

    /// End to end over a real XPC connection, on real hardware: app to boundary to root
    /// authority to SMC and back, with no write path anywhere in it.
    @Test("A real snapshot crosses a real connection and decodes")
    func snapshotCrossesTheBoundary() async throws {
        let authority = ReadOnlyFanAuthority(
            provider: SMCSensorProvider(), log: Self.log,
            thermalEmergency: ThermalEmergencyLatch())
        let harness = AnonymousListenerHarness(authority: authority)

        _ = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }
        let result = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }

        let data = try #require(result.payload)
        let snapshot = try AeolusXPCCoding.decoder().decode(SystemSnapshot.self, from: data)
        #expect(!snapshot.fans.isEmpty)
        #expect(snapshot.protocolVersion == AeolusXPCVersion.current)
    }
}
