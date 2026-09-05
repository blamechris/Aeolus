import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The capability gate: `acquireLease` refuses a build with no write path, first, and
/// without spending a hardware read to do it.
///
/// ## What this replaces
///
/// `ReadOnlyFanAuthority.acquireLease` threw a hard-coded `Self.noWritePath`. It was true and
/// it was unfalsifiable: nothing sourced the refusal from the thing that would have to
/// perform the write, so the day a write path arrived the refusal would have stayed correct
/// in the type and wrong about the machine — the same defect that type's own field comments
/// record three times over (the latch, the ledger, the fan mode). #103's decision A1 makes it
/// a gate on the seam instead.
///
/// ## Why the read count is asserted and not only the fault
///
/// A check that is merely *present* can be moved. `LeaseAuthority.acquireLease` reaches
/// `refuseIfBlind` — a real 34-key `.supervisor` read on the production conformer — three
/// statements later, and an edit that put the capability check below it would leave every
/// assertion about the *fault* green while the daemon spent an SMC round trip per rejected
/// grant and answered `noThermalTelemetry` on a machine whose sensors are fine. The number of
/// reads is the only thing that can tell those two apart.
@Suite("The write-capability gate on a lease")
struct LeaseWriteCapabilityTests {

    /// The production plane over a provider that counts what it was asked for.
    ///
    /// `supervisorPlane(over:)` builds the real `SMCFanControlPlane` through a real
    /// `SMCReadScheduler`, so the capability answered here is the shipped one and the reads
    /// counted are the ones that would really reach the SMC.
    private static func productionPlane(
        over provider: FakeSensorProvider
    ) -> SMCFanControlPlane {
        supervisorPlane(over: provider)
    }

    /// **Mutation:** make `SMCFanControlPlane.writeCapability` return `.built`. Run: red —
    /// the grant is no longer refused for the build, and the refusal it does produce comes
    /// from a hardware read this test asserts never happens.
    @Test("A lease against the production plane is refused for the build, before any read")
    func aBuildWithNoWritePathRefusesBeforeItReads() async throws {
        let provider = FakeSensorProvider(keyedResults: fanKeyResults(fanCount: 1))
        let plane = Self.productionPlane(over: provider)
        let enumeration = ScriptedFanEnumeration()
        let authority = LeaseFixture.authority(
            enumeration: enumeration,
            writeCapability: plane,
            telemetry: CuratedCriticalTemperatures(plane: plane, set: .mac16x5))

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }

        #expect(
            await provider.subsetRequests.isEmpty,
            """
            the grant reached the SMC before refusing. The capability check has moved below \
            a read, so a client is told about the sensors when the answer is about the build.
            """)
        #expect(await provider.readAllCount == 0, "the grant walked every key before refusing")
        #expect(
            await enumeration.callCount == 0,
            "the grant enumerated the machine's fans before refusing")
    }

    /// The gate reads the seam rather than the build it happens to be compiled into.
    ///
    /// Without this, "refuses `.writePathNotBuilt`" is satisfied by a method that refuses
    /// unconditionally — which is exactly what it replaced, and which no assertion about the
    /// refusal alone can distinguish from a working gate.
    ///
    /// **Mutation:** make `ScriptedControlPlane.writeCapability` return `.notBuilt`. Run: red.
    @Test("A plane that answers .built is not refused for the build")
    func aBuildWithAWritePathIsNotRefusedForTheBuild() async throws {
        let authority = LeaseFixture.authority(writeCapability: LeaseFixture.writePathBuilt())

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0], holder: "capable build"), from: ConnectionID())

        #expect(lease.holderDescription == "capable build")
        #expect(await authority.leaseCount == 1)
    }

    /// The build-level refusal outranks the request-level one.
    ///
    /// Both are true of a self-renewing request sent to this build, and only one of them is
    /// worth telling a client: `.selfRenewalNotBuilt` invites "ask for a plain lease
    /// instead", which is wrong advice on an executable that can grant neither.
    ///
    /// **Mutation:** move `try refuseIfWritePathNotBuilt(connection)` below the self-renewal
    /// guard in `LeaseAuthority.acquireLease`. Run: red.
    @Test("A self-renewing request is told about the build, not about self-renewal")
    func theBuildLevelRefusalComesFirst() async throws {
        let provider = FakeSensorProvider(keyedResults: fanKeyResults(fanCount: 1))
        let plane = Self.productionPlane(over: provider)
        let authority = LeaseFixture.authority(
            writeCapability: plane,
            telemetry: CuratedCriticalTemperatures(plane: plane, set: .mac16x5))

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0], isSelfRenewing: true), from: ConnectionID())
        }
    }

    /// The production conformer's own answer, asserted where a reader looks for it.
    ///
    /// One line, and it is the line the whole gate rests on: every other assertion in this
    /// file would still pass if `SMCFanControlPlane` had quietly acquired a write path,
    /// because they would then be describing a different executable.
    @Test("The production control plane reports that it has no write path")
    func theProductionPlaneHasNoWritePath() {
        let plane = supervisorPlane(over: FakeSensorProvider())

        #expect(plane.writeCapability == .notBuilt)
    }
}
