import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The one question about this type that is not "what does E2 refuse".
///
/// Its own suite because the suite above is at SwiftLint's `type_body_length` limit, and
/// because this is about a field's *provenance* rather than about the read-only contract.
@Suite("ReadOnlyFanAuthority and the thermal-emergency latch")
struct ReadOnlyFanAuthorityLatchTests {

    /// `isThermalEmergencyActive` is read from § 3's latch, not written as a literal.
    ///
    /// Until #125 the field was `false` in the initialiser with a comment explaining that
    /// E2 has no thermal supervisor — a claim that was true and that nothing would have
    /// noticed becoming false. Engage the latch and the snapshot says so; replace the read
    /// with `false` again and this goes red.
    ///
    /// The build still cannot reach this state on real hardware, because every path that
    /// would grant a lease refuses. What is asserted is the *sourcing*.
    @Test("A latched thermal emergency is reported on the snapshot")
    func theSnapshotReportsTheLatch() async throws {
        let latch = ThermalEmergencyLatch()
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99))

        let snapshot = try await authority(
            provider: fanProvider(fanCount: 1), thermalEmergency: latch
        ).snapshot()

        #expect(snapshot.isThermalEmergencyActive)
    }

    private func authority(
        provider: FakeSensorProvider, thermalEmergency: ThermalEmergencyLatch
    ) -> ReadOnlyFanAuthority {
        ReadOnlyFanAuthority(
            provider: provider,
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Authority"),
            thermalEmergency: thermalEmergency,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }
}
