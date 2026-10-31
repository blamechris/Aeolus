import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import fanctl

/// What `fanctl set` decides from the helper's first snapshot, before it acquires anything: which
/// fans, at what speed, or why not.
///
/// Every refusal here is **exit 2** and **nothing is acquired**: the request is well formed
/// (`SetArgumentsTests`) and does not fit this machine. The gate is
/// `FanState.controlEnvelope == .success`, for a percentage *and* for an rpm: "min and max read
/// as measured values" misses a declared maximum of 1e14, whose 75 % is 7.5e13 RPM and which the
/// helper would grant a lease over anyway ([#270](https://github.com/blamechris/Aeolus/issues/270)).
@Suite("fanctl set's plan")
struct SetPlanTests {

    static func fan(
        _ index: Int, minimum: FanReading = .measured(1350), maximum: FanReading = .measured(5777)
    ) -> FanState {
        FanState(
            index: index, actualRPM: .measured(1351), minimumRPM: minimum, maximumRPM: maximum,
            targetRPM: nil, mode: .automatic, isReclaimedBySystem: false,
            manualControlAvailability: .available)
    }

    static func snapshot(_ fans: [FanState]) -> SystemSnapshot {
        SystemSnapshot(
            fans: fans, sensors: [], activeLease: nil, isThermalEmergencyActive: false,
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    static let macSixteenFive = snapshot([fan(0), fan(1)])

    private static func plan(
        _ selection: SetArguments.FanSelection, _ speed: SetArguments.Speed,
        _ snapshot: SystemSnapshot = macSixteenFive
    ) -> Result<[SetFanPlan], HelperCommandFailure> {
        SetPlan.make(selection: selection, speed: speed, snapshot: snapshot)
    }

    private static func refusal(
        _ result: Result<[SetFanPlan], HelperCommandFailure>
    ) -> HelperCommandFailure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }

    // MARK: - What fits

    @Test("75 percent of Mac16,5's range is 4670 RPM, for one fan or for every fan")
    func percentage() throws {
        let one = try Self.plan(.index(1), .percent(75)).get()
        #expect(one.map(\.index) == [1])
        #expect(one.map(\.commandedRPM) == [4670])
        #expect(one.map(\.requested) == [.percent(75)])

        let all = try Self.plan(.all, .percent(75)).get()
        #expect(all.map(\.index) == [0, 1])
        #expect(all.map(\.commandedRPM) == [4670, 4670])
    }

    @Test("An rpm inside the range, at either end of it, is commanded as asked")
    func rpmInsideTheRange() throws {
        for rpm in [1350, 3000, 5777] {
            let plans = try Self.plan(.index(0), .rpm(rpm)).get()
            #expect(plans.map(\.commandedRPM) == [Double(rpm)], "\(rpm)rpm")
        }
    }

    /// `all` resolves each fan against **its own** envelope. 75 % of 2000 to 6000 is 5000, and
    /// 1500 RPM is inside fan 0's range and below fan 1's.
    ///
    /// **Mutation:** in `SetPlan.make`, build every fan's plan from the first fan's envelope.
    /// Run: red on the 5000 here.
    @Test("all maps every fan through its own envelope")
    func eachFanOwnEnvelope() throws {
        let uneven = Self.snapshot([
            Self.fan(0), Self.fan(1, minimum: .measured(2000), maximum: .measured(6000)),
        ])
        let percent = try Self.plan(.all, .percent(75), uneven).get()
        #expect(percent.map(\.commandedRPM) == [4670, 5000])

        let rpm = try Self.plan(.all, .rpm(3000), uneven).get()
        #expect(rpm.map(\.commandedRPM) == [3000, 3000])

        let below = Self.refusal(Self.plan(.all, .rpm(1500), uneven))
        #expect(below?.code == .requestDoesNotFit)
        #expect(below?.message.contains("Fan 1") == true)
        #expect(below?.message.contains("2000") == true)
    }

    /// A firmware minimum of zero is legal; the range starts at the floor, so 0 % is not a stop.
    @Test("A declared minimum of zero never makes zero RPM reachable")
    func zeroMinimum() throws {
        let zero = Self.snapshot([Self.fan(0, minimum: .measured(0), maximum: .measured(3000))])
        #expect(try Self.plan(.index(0), .percent(0), zero).get().map(\.commandedRPM) == [100])
        let refused = Self.refusal(Self.plan(.index(0), .rpm(0), zero))
        #expect(refused?.code == .requestDoesNotFit)
    }

    // MARK: - What does not fit: 2

    /// Refused, never clamped on the client: a request outside the range is a request this
    /// machine cannot honour, and "close enough" would be a speed nobody asked for. The helper
    /// still clamps (`CLAUDE.md` rule 7); that is its control, not this command's courtesy.
    ///
    /// **Mutation:** replace the range check in `SetPlan.make` with a call to `target(for:)`
    /// alone. Run: red on every row.
    @Test("An rpm outside the fan's range exits 2 and names the range")
    func rpmOutsideTheRange() {
        for rpm in [0, 1, 1349, 5778, 20_000] {
            let failure = Self.refusal(Self.plan(.index(0), .rpm(rpm)))
            #expect(failure?.code == .requestDoesNotFit, "\(rpm)rpm")
            #expect(failure?.message.contains("1350") == true, "\(rpm)rpm")
            #expect(failure?.message.contains("5777") == true, "\(rpm)rpm")
            #expect(failure?.message.contains("Nothing was acquired") == true, "\(rpm)rpm")
        }
    }

    @Test("0rpm is refused as outside the range, never raised to the floor")
    func zeroRPM() {
        let failure = Self.refusal(Self.plan(.index(0), .rpm(0)))
        #expect(failure?.code == .requestDoesNotFit)
        #expect(failure?.message.contains("0rpm") == true)
    }

    @Test("A fan the helper does not report exits 2 and lists the fans it does")
    func noSuchFan() {
        let failure = Self.refusal(Self.plan(.index(7), .percent(50)))
        #expect(failure?.code == .requestDoesNotFit)
        #expect(failure?.message.contains("Fan 7") == true)
        #expect(failure?.message.contains("0, 1") == true)
    }

    @Test("A machine the helper reports no fans for exits 2, for one fan and for all")
    func noFans() {
        let empty = Self.snapshot([])
        #expect(Self.refusal(Self.plan(.all, .percent(50), empty))?.code == .requestDoesNotFit)
        #expect(Self.refusal(Self.plan(.index(0), .percent(50), empty))?.code == .requestDoesNotFit)
    }

    // MARK: - The gate

    /// A declared maximum of 1e14 makes 75 % about 7.5e13 RPM, and the helper would grant the
    /// lease regardless. The gate is the envelope, and it refuses, whichever unit was asked in.
    ///
    /// **Mutation:** in `SetPlan.make`, test only that both bounds are measured (`.value != nil`)
    /// instead of `controlEnvelope`. Run: red on every row.
    @Test(
        "Bounds the envelope refuses exit 2 for a percentage and for an rpm",
        arguments: [
            (
                FanReading.measured(1350), FanReading.measured(1e14),
                FanBoundsImplausibility.maximumAboveCeiling
            ),
            (.measured(1350), .measured(20_001), .maximumAboveCeiling),
            (.measured(-1), .measured(5777), .negativeMinimum),
            (.measured(5777), .measured(1350), .notAscending),
            (.measured(1350), .measured(1350), .notAscending),
            (.measured(0), .measured(50), .maximumBelowFloor),
            (.unavailable(reason: "no key"), .measured(5777), .notMeasured),
            (.measured(1350), .unavailable(reason: "read failed"), .notMeasured),
        ])
    func implausibleBounds(
        minimum: FanReading, maximum: FanReading, why: FanBoundsImplausibility
    ) {
        let snapshot = Self.snapshot([Self.fan(0, minimum: minimum, maximum: maximum)])
        for speed in [SetArguments.Speed.percent(75), .rpm(3000), .percent(0), .rpm(1350)] {
            let failure = Self.refusal(Self.plan(.index(0), speed, snapshot))
            #expect(failure?.code == .requestDoesNotFit, "\(speed) over \(why)")
            #expect(failure?.message.contains(why.description) == true, "\(speed) over \(why)")
            #expect(failure?.message.contains("Nothing was acquired") == true)
        }
    }

    /// One fan the machine cannot be asked for is the whole command refused: a half-applied
    /// `all` would leave one fan at the speed and one still on Apple's curve while the output
    /// said "holding".
    ///
    /// **Mutation:** in `SetPlan.make`, skip a fan whose envelope fails instead of refusing the
    /// plan. Run: red — the plan succeeds with one fan.
    @Test("all is all or nothing: one unusable fan refuses every fan")
    func allOrNothing() {
        let mixed = Self.snapshot([
            Self.fan(0), Self.fan(1, minimum: .measured(1350), maximum: .measured(1e14)),
        ])
        let failure = Self.refusal(Self.plan(.all, .percent(75), mixed))
        #expect(failure?.code == .requestDoesNotFit)
        #expect(failure?.message.contains("Fan 1") == true)
        #expect(
            failure?.message.contains(FanBoundsImplausibility.maximumAboveCeiling.description)
                == true)
        #expect(failure?.message.contains("Fan 0") != true, "fan 0 was fine")

        // The same fan, asked for by itself, is refused too; the other fan alone is fine.
        #expect(Self.refusal(Self.plan(.index(1), .percent(75), mixed))?.code == .requestDoesNotFit)
        #expect(Self.refusal(Self.plan(.index(0), .percent(75), mixed)) == nil)
    }

    @Test("Every refused fan is named, so one run shows all of them")
    func everyRefusedFanIsNamed() {
        let bad = Self.snapshot([
            Self.fan(0, maximum: .measured(1e14)), Self.fan(1, minimum: .unavailable(reason: "x")),
        ])
        let failure = Self.refusal(Self.plan(.all, .percent(50), bad))
        #expect(failure?.message.contains("Fan 0") == true)
        #expect(failure?.message.contains("Fan 1") == true)
    }
}
