import AeolusXPC
import FanKit
import Foundation

/// One fan `fanctl set` will ask the helper to hold, and the speed it will ask for.
struct SetFanPlan: Equatable, Sendable {
    let index: Int
    /// What was typed, kept so the output can say "75%" beside the RPM it became.
    let requested: SetArguments.Speed
    /// The envelope the speed was judged against: this fan's own, from the helper's snapshot.
    let envelope: FanControlEnvelope
    /// The speed that will be sent. Always from `envelope`, so it is inside the firmware's range
    /// and above the floor that keeps it off zero.
    let target: FanTargetRPM

    var commandedRPM: Double { target.rpm }
}

/// What `fanctl set` decides from the helper's first snapshot, before it acquires anything.
///
/// ## The gate
///
/// **`FanState.controlEnvelope == .success`, for a percentage and for an rpm alike.** Checking
/// that both bounds merely read as measured values misses an implausible pair: a declared
/// maximum of 1e14 makes 75 % about 7.5e13 RPM, and the helper would grant the lease over such a
/// fan anyway ([#270](https://github.com/blamechris/Aeolus/issues/270)). A fan whose envelope is
/// refused gets no speed from this command in either unit; the message is
/// `FanBoundsImplausibility`'s own description.
///
/// ## Refused, never clamped
///
/// An rpm outside `[lowestCommandableRPM, highestCommandableRPM]` — `0rpm` included — is exit 2.
/// `FanControlEnvelope.target(for:)` would clamp it, and that clamp is the *helper's* control
/// (`CLAUDE.md` rule 7): a client that quietly turned 6000 into 5777 would be reporting a speed
/// nobody asked for. A percentage cannot be outside the range; it is a position in it.
///
/// ## All or nothing
///
/// `all` judges every fan against its own envelope, and one fan that cannot be asked for refuses
/// the command: nothing is acquired. A half-applied `all` would leave one fan at the speed and
/// one on Apple's curve while the output said it was holding.
enum SetPlan {

    static func make(
        selection: SetArguments.FanSelection, speed: SetArguments.Speed,
        snapshot: SystemSnapshot
    ) -> Result<[SetFanPlan], HelperCommandFailure> {
        let fans: [FanState]
        switch selection {
        case .all:
            fans = snapshot.fans.sorted { $0.index < $1.index }
            guard !fans.isEmpty else {
                return .failure(refusal("The helper reports no fans on this machine."))
            }
        case .index(let index):
            fans = snapshot.fans.filter { $0.index == index }
            guard !fans.isEmpty else {
                let known = snapshot.fans.map(\.index).sorted().map(String.init)
                let reported =
                    known.isEmpty
                    ? "The helper reports no fans."
                    : "The helper reports fan \(known.joined(separator: ", "))."
                return .failure(refusal("Fan \(index) does not exist on this machine. \(reported)"))
            }
        }

        var plans: [SetFanPlan] = []
        var reasons: [String] = []
        for fan in fans {
            switch plan(for: fan, speed: speed) {
            case .success(let plan): plans.append(plan)
            case .failure(let reason): reasons.append(reason.text)
            }
        }
        guard reasons.isEmpty else {
            return .failure(refusal(reasons.joined(separator: "\n")))
        }
        return .success(plans)
    }

    /// Exit 2, with the reasons and the one fact that matters after them: no lease was taken.
    private static func refusal(_ reasons: String) -> HelperCommandFailure {
        HelperCommandFailure(
            .requestDoesNotFit,
            "\(reasons)\nNothing was acquired and nothing was sent to a fan.")
    }

    private static func plan(
        for fan: FanState, speed: SetArguments.Speed
    ) -> Result<SetFanPlan, PlanReason> {
        let envelope: FanControlEnvelope
        switch fan.controlEnvelope {
        case .failure(let why):
            return .failure(
                PlanReason(
                    "Fan \(fan.index): no speed can be set, because its firmware speed range is "
                        + "unusable: \(why.description)."))
        case .success(let valid):
            envelope = valid
        }

        let target: FanTargetRPM
        switch speed {
        case .percent(let percent):
            target = envelope.target(forPercent: Double(percent))
        case .rpm(let rpm):
            let requested = Double(rpm)
            guard
                requested >= envelope.lowestCommandableRPM,
                requested <= envelope.highestCommandableRPM
            else {
                return .failure(
                    PlanReason(
                        "Fan \(fan.index): \(rpm)rpm is outside the speeds this fan can be set to, "
                            + "\(Formatting.number(envelope.lowestCommandableRPM)) to "
                            + "\(Formatting.number(envelope.highestCommandableRPM)) RPM "
                            + "(the firmware's range, above the floor that keeps a fan off zero)."))
            }
            target = envelope.target(for: requested)
        }
        return .success(
            SetFanPlan(index: fan.index, requested: speed, envelope: envelope, target: target))
    }

    /// A reason one fan was refused, as a sentence.
    private struct PlanReason: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }
}
