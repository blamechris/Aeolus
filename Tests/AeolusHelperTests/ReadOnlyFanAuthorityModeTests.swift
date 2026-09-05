import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What the snapshot says about **who owns a fan**, and where that answer comes from.
///
/// Until [#148](https://github.com/blamechris/Aeolus/issues/148) it came from nowhere:
/// `mode: .automatic` was a literal in the `FanState` initialiser, so a fan left in manual by
/// a crashed previous helper — or by another vendor's fan tool, which is the reachable case
/// in a build with no write path at all — was reported to the user as being under Apple's
/// thermal management. `CLAUDE.md` rule 6 is "never claim control you do not have", and its
/// converse is what this suite exists for: never report a state nothing observed.
///
/// The tests drive the **real** `SnapshotFanModeReads` over a stubbed provider, rather than a
/// double standing in for it, so the key naming, the finiteness guard and the flag decode are
/// all exercised on the way through. A double here would assert that a mode the test itself
/// invented survives being copied into a DTO.
@Suite("The fan mode a snapshot reports")
struct ReadOnlyFanAuthorityModeTests {

    private static let log = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Mode")

    /// One authority and the provider it reads through, so a test can assert on both what
    /// was reported and what was asked for.
    private struct Fixture {
        let authority: ReadOnlyFanAuthority
        let provider: FakeSensorProvider
    }

    /// One fan, its three enumeration keys readable, and whatever `F0Md` the case needs.
    private func fixture(modeKey: Result<SensorReading, SensorReadFailure>?) -> Fixture {
        var extraKeys: [String: Result<SensorReading, SensorReadFailure>] = [:]
        if let modeKey { extraKeys["F0Md"] = modeKey }
        return fixture(fanCount: 1, modeKeys: extraKeys)
    }

    /// `fanCount` fans, each with its three enumeration keys readable, and whatever `F<n>Md`
    /// keys the case supplies.
    ///
    /// Parameterised on the fan count so a case can give **two** fans different modes. Every
    /// single-fan case above is blind to which fan a mode was read for — see
    /// `eachFanReportsItsOwnMode`.
    private func fixture(
        fanCount: Int,
        modeKeys: [String: Result<SensorReading, SensorReadFailure>]
    ) -> Fixture {
        let provider = fanProvider(fanCount: fanCount, extraKeys: modeKeys)
        let authority = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: Self.log,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger(),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        return Fixture(authority: authority, provider: provider)
    }

    /// The assertion that cannot be satisfied by a literal: the key is asked for, and the
    /// answer is what is reported.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.controlMode(_:)`, return `.automatic` for every
    /// case. Run: red here, on `.manualFixed`.
    @Test("A fan the firmware says is in manual is never reported as automatic")
    func manualFanIsReportedAsManual() async throws {
        let machine = fixture(modeKey: .reading("F0Md", 1))

        let snapshot = try await machine.authority.snapshot()
        let fan = try #require(snapshot.fans.first)

        #expect(fan.mode == .manualFixed)
        // No lease exists in this build, so the honest report is a fan off automatic control
        // that Aeolus is not the one holding — which is what startup reconciliation (#103)
        // is for. The two fields together say that; either alone would not.
        #expect(snapshot.activeLease == nil)
        #expect(fan.manualControlAvailability == .unavailable(.writePathNotBuilt))
        // And the mode really was read, rather than inferred from the build.
        #expect(await machine.provider.subsetRequests.contains(["F0Md"]))
    }

    /// `F<n>Md` is a flag key and is **not rounded** before it is judged: anything that is
    /// not zero is manual. A decode artefact of `0.4` read as automatic would leave a pinned
    /// fan looking managed, which is the asymmetry `FirmwareFanMode(declaredByFirmware:)`
    /// records.
    @Test("A mode that decodes to a fraction is manual, not rounded down to automatic")
    func fractionalModeIsManual() async throws {
        let machine = fixture(modeKey: .reading("F0Md", 0.4))

        let fan = try #require(try await machine.authority.snapshot().fans.first)

        #expect(fan.mode == .manualFixed)
    }

    /// **Mutation:** in `ReadOnlyFanReport.controlMode(_:)`, return `.manualFixed` for
    /// `.automatic`. Run: red here.
    @Test("A fan the firmware says is on automatic is reported automatic, from the read")
    func automaticFanIsReportedFromTheRead() async throws {
        let machine = fixture(modeKey: .reading("F0Md", 0))

        let fan = try #require(try await machine.authority.snapshot().fans.first)

        #expect(fan.mode == .automatic)
        #expect(await machine.provider.subsetRequests.contains(["F0Md"]))
    }

    /// The gap this change does **not** close, asserted so it is visible rather than
    /// discovered.
    ///
    /// `F<n>Md` is absent on Intel Macs, which express the same fact as bit *n* of the `FS! `
    /// bitmask, so "the mode could not be read" is the *normal* state of an entire family
    /// rather than an exotic failure. v1's `FanControlMode` has no `unknown` case and gaining
    /// one is a wire change — an older client decodes the whole snapshot or none of it — so
    /// the report falls back to `.automatic` and says so in the log. Reporting `.manualFixed`
    /// instead would tell every user of every Intel Mac that every fan is being held by
    /// something, which is a false claim at a far larger scale than the one being fixed here.
    ///
    /// [#178](https://github.com/blamechris/Aeolus/issues/178) holds the honest answer,
    /// which needs the wire to be able to say "not known".
    @Test("A mode that cannot be read falls back to automatic, and the fan is still reported")
    func unreadableModeFallsBackToAutomatic() async throws {
        let machine = fixture(modeKey: nil)

        let snapshot = try await machine.authority.snapshot()
        let fan = try #require(snapshot.fans.first)

        #expect(fan.mode == .automatic)
        // The fan is not dropped and its readings survive: an unreadable mode is a gap in one
        // claim, not a reason to lose two working RPM readings.
        #expect(fan.actualRPM == .measured(1_800))
    }

    /// A non-finite decode must not become `manual` on the strength of `NaN != 0`.
    ///
    /// `SMCValue.scalar()` applies no finiteness guard, so a byte-swapped `flt` decodes to
    /// `NaN` on an otherwise-successful read — and every comparison with `NaN` is false, so a
    /// bare `value == 0` test answers "manual" for it. That is a fan reported as held by
    /// nobody's decision.
    ///
    /// **Mutation:** delete the `FanControlPlaneValue.finite` switch in
    /// `SnapshotFanModeReads.readMode(ofFan:)` and return
    /// `FirmwareFanMode(declaredByFirmware: reading.value)` directly. Run: red here.
    @Test("A non-finite mode is a read failure, never a fan reported as held")
    func nonFiniteModeIsNotManual() async throws {
        let machine = fixture(modeKey: .reading("F0Md", .nan))

        let fan = try #require(try await machine.authority.snapshot().fans.first)

        #expect(fan.mode != .manualFixed)
    }

    /// The per-fan association, which no single-fan case can make.
    ///
    /// #148's claim is not "a mode is read" but "**this** fan's mode is reported on this
    /// fan", and every other case in this suite builds a one-fan machine, where
    /// `modes[$0.index]` and `modes[anything]` are the same expression. On a two-fan Mac with
    /// another vendor's tool holding fan 1, an index-binding regression reports fan 0 as held
    /// and fan 1 as automatic — pointing #164's startup reconciliation at the wrong fan and
    /// telling the user the wrong thing about both.
    ///
    /// The two fans are given **asymmetric** modes so the assertion distinguishes fan from
    /// fan in either direction: a mutant that reports fan 0's mode everywhere fails on
    /// `fans[1]`, and one that reports fan 1's fails on `fans[0]`.
    ///
    /// **Mutation:** in `ReadOnlyFanAuthority.snapshot()`, replace `mode: modes[$0.index]`
    /// with `mode: modes[0]`. Run: red here, on `fans[1].mode == .manualFixed`.
    @Test("Each fan is reported with its own F<n>Md, not with some other fan's")
    func eachFanReportsItsOwnMode() async throws {
        let machine = fixture(
            fanCount: 2,
            modeKeys: [
                "F0Md": .reading("F0Md", 0),
                "F1Md": .reading("F1Md", 1),
            ])

        let snapshot = try await machine.authority.snapshot()

        #expect(snapshot.fans.count == 2)
        let byIndex = Dictionary(uniqueKeysWithValues: snapshot.fans.map { ($0.index, $0) })
        #expect(byIndex[0]?.mode == .automatic)
        #expect(byIndex[1]?.mode == .manualFixed)
        // Both keys really were asked for, so neither answer came from a default.
        #expect(await machine.provider.subsetRequests.contains(["F0Md"]))
        #expect(await machine.provider.subsetRequests.contains(["F1Md"]))
    }

    /// The log line is a diagnostic, not a heartbeat.
    ///
    /// `F<n>Md` does not exist on Intel Macs, which express the same fact as bit *n* of the
    /// `FS! ` bitmask, so "the mode could not be read" is the **normal** state of a whole
    /// architecture rather than a fault. `snapshot()` is on a 1 Hz path, so an unthrottled
    /// error-level line here is on the order of 86,400 entries per fan per day, permanently —
    /// which drowns the very signal the line was written to preserve, on the one architecture
    /// this project cannot test. The first occurrence per fan carries the whole diagnostic;
    /// the repeats carry nothing new.
    ///
    /// The wording does not change with the level, so this asserts the **levels** — the level
    /// is the distinction, and it is the half a log assertion usually forgets to make.
    ///
    /// **Mutation:** in `ObservedFanModes.modes(ofFans:)`, pass
    /// `alreadyReported: false` unconditionally. Run: red here, on both fans.
    @Test("An unreadable mode is an error once per fan, and a debug line every time after")
    func unreadableModeIsReportedOncePerFanAtErrorLevel() async throws {
        let recorder = RecordedHelperFanLines()
        // Two fans and no `F<n>Md` for either: every mode read fails, on every snapshot.
        let provider = fanProvider(fanCount: 2)
        let authority = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: HelperLog(
                subsystem: "dev.aeolus.AeolusHelperTests",
                category: "Mode",
                recordingFanLines: { recorder.append($0, $1) }),
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger(),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )

        for _ in 0..<3 { _ = try await authority.snapshot() }

        // Per fan, not per process: a second fan going unreadable is news about that fan.
        #expect(recorder.levels(containing: "Fan 0's mode key") == [.error, .debug, .debug])
        #expect(recorder.levels(containing: "Fan 1's mode key") == [.error, .debug, .debug])
    }

    /// The other half of #148's title, and the one that stays a literal — deliberately.
    ///
    /// `FanState.targetRPM` is documented as *"the speed the helper is currently asking
    /// for"*, and this build asks for nothing: `SMCConnection.write(_:to:)` is `package` and
    /// throws, and no write selector exists anywhere in `Sources`. So `nil` here is a
    /// build-level fact of the same kind as `activeLease: nil`, not an unconfirmed
    /// observation. Sourcing it from `F<n>Tg` would report the firmware's own target — set by
    /// Apple's thermal manager on an automatic fan — as something Aeolus is asking for, which
    /// changes what a v1 field *means* and is a protocol bump by
    /// `AeolusXPCVersion`'s own policy.
    @Test("The target stays nil while the helper asks for nothing, even on a manual fan")
    func targetIsNilBecauseNothingIsAsked() async throws {
        let machine = fixture(modeKey: .reading("F0Md", 1))

        let fan = try #require(try await machine.authority.snapshot().fans.first)

        #expect(fan.mode == .manualFixed)
        #expect(fan.targetRPM == nil)
    }
}

/// A `HelperLog` fan-line sink a test can read back, **with the level**.
///
/// `NSLock` rather than an actor so an assertion can read it without an `await`, matching
/// `RecordedLog` in `CriticalSensorSetTests.swift`, which does the same job for `SafetyLog`.
///
/// The level is the whole point. `HelperLog.fanModeUnreadable` reports a condition that is
/// normal for an entire architecture family, so whether the tenth occurrence is an error or a
/// debug line is the difference between a diagnostic and a denial of service against whoever
/// reads the log — and before this sink existed that choice was a claim no test could observe.
final class RecordedHelperFanLines: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(level: HelperLog.FanLineLevel, line: String)] = []

    func append(_ level: HelperLog.FanLineLevel, _ line: String) {
        lock.withLock { recorded.append((level, line)) }
    }

    /// The levels of the lines containing `needle`, in order.
    ///
    /// Substring matching on a phrase only the intended line can produce: asserting a whole
    /// prose line is a test that fails on a comma, and matching text a *different* line could
    /// also satisfy is a test that passes for the wrong reason.
    func levels(containing needle: String) -> [HelperLog.FanLineLevel] {
        lock.withLock { recorded.filter { $0.line.contains(needle) }.map(\.level) }
    }
}
