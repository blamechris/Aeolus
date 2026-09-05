import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// The production control plane: reads that are real, and writes that refuse.
///
/// Entirely hardware-free — every test here drives `FakeSensorProvider`, which is also what
/// makes the two structural claims checkable: that no operation reaches `readAll()`, and
/// that the restore verb reaches the provider at all.
@Suite("SMCFanControlPlane")
struct SMCFanControlPlaneTests {

    private static let cpuKey = smcKey("TC0P")
    private static let gpuKey = smcKey("TG0P")

    private static func plane(_ keyedResults: KeyedResults) -> SMCFanControlPlane {
        supervisorPlane(over: FakeSensorProvider(keyedResults: keyedResults))
    }

    // MARK: - The keystone

    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s keystone, asserted against
    /// the thing that could break it: **restore-to-automatic must not read.**
    ///
    /// The failure this catches is a plausible and tempting implementation — check the
    /// current mode, skip the write if the fan is already automatic. That version is
    /// missing in the one case the verb exists for, because the cycle where every read has
    /// failed is exactly the cycle where a fan is pinned and nothing else can help. The
    /// provider recording no request at all is what proves the property.
    @Test("Restoring to automatic reaches the SMC for nothing at all before refusing")
    func restoringToAutomaticIssuesNoRead() async throws {
        for scope in [FanRestoreScope.everyFan, .fan(0)] {
            let provider = FakeSensorProvider(keyedResults: [:])
            let plane = supervisorPlane(over: provider)

            await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
                try await plane.restoreToAutomatic(scope)
            }

            let subsetRequests = await provider.subsetRequests
            let readAllCount = await provider.readAllCount
            #expect(subsetRequests.isEmpty, "restore issued a subset read for \(scope)")
            #expect(readAllCount == 0, "restore issued a full enumeration for \(scope)")
        }
    }

    // MARK: - The write side is modelled and unbuilt

    /// `CLAUDE.md` rule 1 as a test. E5 gates E3 and E4, so the seam models the write side
    /// and implements none of it; a stubbed success here would be a lease that controls
    /// nothing wearing a different name.
    @Test("Every write verb refuses, because this build has no write path")
    func everyWriteVerbRefuses() async throws {
        let plane = Self.plane([:])

        await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
            try await plane.engageManualControl(of: commandableFan(0, declaring: .nominal))
        }
        await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
            _ = try await plane.commandTarget(
                commandableFan(0, declaring: .nominal).target(for: 2_400))
        }
        await #expect(throws: FanControlPlaneError.controlPathNotBuilt) {
            try await plane.restoreToAutomatic(.fan(0))
        }
    }

    // MARK: - Reads are subset reads

    /// ADR 0006 puts the helper's 1 Hz snapshot on the same single SMC connection, and a
    /// warm snapshot costs ~0.5 s against 2929 keys on this project's development machine.
    /// A supervisor read that reached `readAll()` would queue the safety cycle behind that.
    @Test("Every read asks for named keys only and never reaches readAll()")
    func readsAreSubsetReadsOnly() async throws {
        let provider = FakeSensorProvider(keyedResults: [
            "TC0P": .reading("TC0P", 61.5, kind: .temperatureCelsius),
            "F0Mn": .reading("F0Mn", 1_350),
            "F0Mx": .reading("F0Mx", 5_777),
            "F0Md": .reading("F0Md", 1),
            "F0Tg": .reading("F0Tg", 2_400),
            "F0Ac": .reading("F0Ac", 2_380),
        ])
        let plane = supervisorPlane(over: provider)

        _ = try await plane.readCriticalTemperatures([Self.cpuKey])
        _ = try await plane.readEnvelope(ofFan: 0)
        _ = try await plane.readControlState(ofFan: 0)

        let readAllCount = await provider.readAllCount
        let subsetRequests = await provider.subsetRequests
        #expect(readAllCount == 0)
        // Three requests, not four: `F0Ac` rides in the control-state read rather than
        // taking a second `.supervisor` turn of its own. #126 added it here for exactly that
        // reason, and this assertion is what would notice somebody splitting it back out —
        // see `FanStateSensing.readControlState(ofFan:)` and #134.
        #expect(subsetRequests == [["TC0P"], ["F0Mn", "F0Mx"], ["F0Md", "F0Tg", "F0Ac"]])
    }

    // MARK: - Control state

    @Test("Control state carries the mode and the target read-back together")
    func controlStateCarriesModeAndTarget() async throws {
        let state = try await Self.plane([
            "F0Md": .reading("F0Md", 1),
            "F0Tg": .reading("F0Tg", 2_400),
        ]).readControlState(ofFan: 0)

        #expect(state.index == 0)
        #expect(state.mode == .manual)
        #expect(state.target == .rpm(2_400))
    }

    @Test("A mode of zero is automatic")
    func aModeOfZeroIsAutomatic() async throws {
        let state = try await Self.plane([
            "F0Md": .reading("F0Md", 0),
            "F0Tg": .reading("F0Tg", 1_800),
        ]).readControlState(ofFan: 0)

        #expect(state.mode == .automatic)
    }

    /// The failure asymmetry, stated as a test: a mode value that is not exactly zero reads
    /// as **manual**, and must not be rounded toward automatic first.
    ///
    /// Reading a manual fan as automatic leaves it pinned with startup reconciliation
    /// satisfied there is nothing to do — the exact failure `docs/SAFETY.md` opens with.
    /// Reading an automatic fan as manual costs one redundant restore write to a fan that
    /// is already automatic. Only one of those directions is expensive.
    @Test("A mode that is not exactly zero reads as manual rather than rounding to automatic")
    func aModeThatIsNotExactlyZeroReadsAsManual() async throws {
        let state = try await Self.plane([
            "F0Md": .reading("F0Md", 0.4),
            "F0Tg": .reading("F0Tg", 1_800),
        ]).readControlState(ofFan: 0)

        #expect(state.mode == .manual)
    }

    @Test("A non-finite mode is a read failure, not a mode")
    func aNonFiniteModeIsAReadFailure() async throws {
        let plane = Self.plane([
            "F0Md": .reading("F0Md", .nan),
            "F0Tg": .reading("F0Tg", 1_800),
        ])

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await plane.readControlState(ofFan: 0)
        }

        #expect(error?.isReadFailure == true, "a NaN mode produced \(describe(error))")
    }

    /// A target that did not read is carried as unreadable, and the mode still arrives.
    ///
    /// Both halves matter. Reconciliation only needs the mode, so failing the whole read
    /// over a missing target would blind it for no reason; and the watchdog needs to be
    /// able to tell "no divergence" from "I could not look", which `.unreadable` is the
    /// only shape that says.
    @Test("An unreadable target is carried as unreadable while the mode still arrives")
    func anUnreadableTargetIsCarriedNotDiscarded() async throws {
        let state = try await Self.plane(["F0Md": .reading("F0Md", 1)])
            .readControlState(ofFan: 0)

        #expect(state.mode == .manual)
        guard case .unreadable(let reason) = state.target else {
            Issue.record("an absent F0Tg produced \(state.target)")
            return
        }
        #expect(reason.contains("F0Tg"))
    }

    @Test("A mode that did not read fails the whole control-state read")
    func anUnreadableModeFailsTheRead() async throws {
        let plane = Self.plane(["F0Tg": .reading("F0Tg", 1_800)])

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await plane.readControlState(ofFan: 0)
        }

        #expect(error?.isReadFailure == true, "an absent F0Md produced \(describe(error))")
    }

    /// A per-key provider failure's detail text comes from `SensorReadFailure`'s one
    /// shared `readableDescription` — not a second, independently-maintained copy of the
    /// same switch living in this file. `HelperTestDoubles.swift` defaults any key absent
    /// from `keyedResults` to `.unknownKey(key)`, which is what "F0Md" missing here
    /// produces; if this seam ever grew its own diverging rendering again, the detail text
    /// would drift from `readableDescription`'s and this assertion would catch it.
    @Test("A per-key read failure's detail reuses SensorReadFailure's shared description")
    func perKeyReadFailureReusesSharedDescription() async throws {
        let plane = Self.plane(["F0Tg": .reading("F0Tg", 1_800)])

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await plane.readControlState(ofFan: 0)
        }

        guard case .readFailed(let detail)? = error else {
            Issue.record("an absent F0Md produced \(describe(error))")
            return
        }
        #expect(detail.contains(SensorReadFailure.unknownKey("F0Md").readableDescription))
    }

    // MARK: - Addressability

    /// `F10Md` is five characters and is not a well-formed SMC key, so a tenth fan has no
    /// addressable mode or target. Refused by name rather than answered with a default —
    /// see `SMCFanEnumeration.actualKey(forFan:)`, which records the same behaviour for the
    /// read-only keys.
    @Test("A fan index with no well-formed keys is refused rather than answered")
    func anUnaddressableFanIsRefused() async throws {
        let plane = Self.plane([:])

        await #expect(throws: FanControlPlaneError.fanNotAddressable(index: 10)) {
            try await plane.readControlState(ofFan: 10)
        }
        await #expect(throws: FanControlPlaneError.fanNotAddressable(index: 10)) {
            try await plane.readEnvelope(ofFan: 10)
        }
    }

    // MARK: - Envelope

    /// Reported exactly as declared: this seam does not correct, round or omit a
    /// declaration it dislikes, because plausibility is `FanControlEnvelope.validating`'s
    /// judgement and it cannot judge what it is not shown. Note that a declared minimum of
    /// zero is then *accepted* — the floor is what keeps zero uncommandable — while
    /// inverted bounds are refused.
    @Test("An implausible envelope is reported as declared, not corrected or refused here")
    func anImplausibleEnvelopeIsReportedAsDeclared() async throws {
        let envelope = try await Self.plane([
            "F0Mn": .reading("F0Mn", 5_777),
            "F0Mx": .reading("F0Mx", 1_350),
        ]).readEnvelope(ofFan: 0)

        #expect(envelope.minimumRPM == 5_777)
        #expect(envelope.maximumRPM == 1_350)
    }

    @Test("A non-finite declared bound is a read failure rather than an envelope")
    func aNonFiniteBoundIsAReadFailure() async throws {
        let plane = Self.plane([
            "F0Mn": .reading("F0Mn", .infinity),
            "F0Mx": .reading("F0Mx", 5_777),
        ])

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await plane.readEnvelope(ofFan: 0)
        }

        #expect(error?.isReadFailure == true, "an infinite F0Mn produced \(describe(error))")
    }

    // MARK: - Critical temperatures

    @Test("Critical temperatures come back keyed, with partial loss visible")
    func criticalTemperaturesCarryPartialLoss() async throws {
        let report = try await Self.plane([
            "TC0P": .reading("TC0P", 61.5, kind: .temperatureCelsius)
        ]).readCriticalTemperatures([Self.cpuKey, Self.gpuKey])

        #expect(report.readings == [CriticalTemperature(key: Self.cpuKey, celsius: 61.5)])
        #expect(report.unreadableKeys == [Self.gpuKey])
    }

    /// Supervisor blindness: not one critical key answered.
    ///
    /// The shape this refuses is a successful read of nothing, which is indistinguishable
    /// from "every sensor is below its ceiling" — so the thermal override stops firing and
    /// the suite stays green.
    @Test("A cycle where no critical key answers is blindness, not a clean cycle")
    func noCriticalKeyAnsweringIsBlindness() async throws {
        let plane = Self.plane([:])
        let blind = FanControlPlaneError.criticalTelemetryUnavailable(requestedKeys: 2)

        await #expect(throws: blind) {
            try await plane.readCriticalTemperatures([Self.cpuKey, Self.gpuKey])
        }
    }

    /// A temperature that decoded to a non-finite value is a key that did not answer, not a
    /// reading of `NaN` °C — and a set of nothing but those is blindness.
    @Test("A non-finite temperature counts as a key that did not answer")
    func aNonFiniteTemperatureIsNotAReading() async throws {
        let plane = Self.plane([
            "TC0P": .reading("TC0P", .nan, kind: .temperatureCelsius)
        ])
        let blind = FanControlPlaneError.criticalTelemetryUnavailable(requestedKeys: 1)

        await #expect(throws: blind) {
            try await plane.readCriticalTemperatures([Self.cpuKey])
        }
    }

    /// The whole request failing — a dead connection rather than a missing key — is named
    /// for the operation that asked, so a log line says which read went dark.
    @Test("A whole-request read failure is reported as a read failure naming the operation")
    func aWholeRequestFailureNamesTheOperation() async throws {
        let provider = FakeSensorProvider(keysError: FakeProviderError(description: "no SMC"))
        let plane = supervisorPlane(over: provider)

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await plane.readCriticalTemperatures([Self.cpuKey])
        }

        guard case .readFailed(let detail)? = error else {
            Issue.record("a dead connection produced \(describe(error))")
            return
        }
        #expect(detail.contains("critical temperatures"))
        #expect(detail.contains("no SMC"))
    }
}

/// The canned-outcome dictionary `FakeSensorProvider` takes, named so the fixture helper
/// above fits on one line.
typealias KeyedResults = [String: Result<SensorReading, SensorReadFailure>]

extension FanControlPlaneError {
    /// Whether this is a read failure, for assertions that care about the case and not
    /// about the diagnostic text inside it.
    var isReadFailure: Bool {
        if case .readFailed = self { return true }
        return false
    }
}

/// Renders an optional error for a failure message, without an assertion having to unwrap
/// it first just to say what it saw.
func describe(_ error: FanControlPlaneError?) -> String {
    error.map { String(describing: $0) } ?? "no error at all"
}
