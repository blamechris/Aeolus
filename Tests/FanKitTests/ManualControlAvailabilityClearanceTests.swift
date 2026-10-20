import Foundation
import Testing

@testable import FanKit

/// `ManualControlAvailability.clearance` and `FanState.isClearedToAutomatic`: whether the helper
/// reports a fan cleared back to automatic control (#153).
///
/// The classification half of `fanctl`'s `SafeStateTests`, asked of the `FanKit` API directly,
/// now that the switch lives here and the app shares it. `SafeStateTests` still asks the same
/// questions through `SafeState.verdict(for:)`, which is what `fanctl auto` reads; this suite is
/// what holds the definition for a client that does not go through `fanctl`.
///
/// ## What the exhaustive switch holds, and what it does not
///
/// `clearance` switches over `Reason` with no `default:` arm. **Deleting an arm is a compile
/// error**: with `.writePathNotBuilt` removed from the silent arm, `swift build` failed with
/// `switch must be exhaustive`. That is what makes a reason added to the vocabulary a decision
/// rather than a quiet "silent".
///
/// **Adding a `default:` arm is not, on its own.** With `default: return .silent` appended after
/// the three arms, `FanKit` built with one warning, `default will never be executed`, and nothing
/// in the build fails on a warning. With the silent arm itself replaced by `default: return
/// .silent`, it built with no warning at all. No assertion can see either, because no reason
/// reaches a `default:` today: it only decides a reason that does not exist yet.
///
/// **`Tag` is what catches it.** It is a second exhaustive switch over `Reason`, in this suite,
/// with the ruling written beside it by hand, so a reason added to the vocabulary is a compile
/// error *here* even when `clearance` has a `default:` that would class it silently. With the
/// silent arm replaced by `default:` and a fifteenth `Reason` added (and given arms in
/// `wireValue`, `userFacingSummary` and `recoveryAdvice`), `FanKit` built with no warning, and
/// `swift build --target FanKitTests` failed with `switch must be exhaustive` in `Tag.init(_:)`
/// and nowhere else. Once a tag is added for the new reason, `expected` must rule it, and
/// `theWitnessAgreesWithTheRuling` compares that ruling with what `clearance` says.
///
/// What it does not catch, and need not: a `default:` that returns the right class for every
/// reason that exists. That is harmless until the vocabulary grows, and growing it is the edit
/// `Tag` stops.
@Suite("Whether the helper reports a fan cleared")
struct ManualControlAvailabilityClearanceTests {

    typealias Reason = ManualControlAvailability.Reason

    /// One tag per `Reason`, with the ruling written out by hand: the witness the header
    /// describes.
    ///
    /// Three exhaustive switches and **no `default:`**, each for its own reason. `init(_:)` is the
    /// one over `Reason`, so a reason the vocabulary grows does not compile here until a tag is
    /// added for it. `reason` maps the tag back, so `Tag(tag.reason) == tag` holds the two
    /// directions to each other. `expected` is the ruling, and a tag cannot be added without one.
    ///
    /// - `durable`: waiting will not change it, whatever the mode reads.
    /// - `pending`: the helper has not established the fan's mode, or a restore is outstanding,
    ///   whatever the mode reads. `supervisorBlind` is here and not above: a blind fan's state is
    ///   unknown, not manual.
    /// - `silent`: about manual control being granted, not about the fan, so the mode decides.
    ///
    /// Written by hand rather than derived from the code under test, so that moving a reason
    /// between classes in `ManualControlAvailability.clearance` is a disagreement with this
    /// ruling and not a self-consistent edit.
    enum Tag: CaseIterable {
        case writePathNotBuilt, boundsImplausible, reclaimedBySystem, leaseHeldByAnotherClient
        case selfRenewalNotBuilt, releaseInProgress, handbackUnconfirmed
        case restoreToAutomaticUnconfirmed, restoreToAutomaticFailed, systemSleeping
        case noThermalTelemetry, supervisorBlind, foreignManualControl, unknown

        init(_ reason: Reason) {
            switch reason {
            case .writePathNotBuilt: self = .writePathNotBuilt
            case .boundsImplausible: self = .boundsImplausible
            case .reclaimedBySystem: self = .reclaimedBySystem
            case .leaseHeldByAnotherClient: self = .leaseHeldByAnotherClient
            case .selfRenewalNotBuilt: self = .selfRenewalNotBuilt
            case .releaseInProgress: self = .releaseInProgress
            case .handbackUnconfirmed: self = .handbackUnconfirmed
            case .restoreToAutomaticUnconfirmed: self = .restoreToAutomaticUnconfirmed
            case .restoreToAutomaticFailed: self = .restoreToAutomaticFailed
            case .systemSleeping: self = .systemSleeping
            case .noThermalTelemetry: self = .noThermalTelemetry
            case .supervisorBlind: self = .supervisorBlind
            case .foreignManualControl: self = .foreignManualControl
            case .unknown: self = .unknown
            }
        }

        var reason: Reason {
            switch self {
            case .writePathNotBuilt: return .writePathNotBuilt
            case .boundsImplausible: return .boundsImplausible
            case .reclaimedBySystem: return .reclaimedBySystem
            case .leaseHeldByAnotherClient: return .leaseHeldByAnotherClient
            case .selfRenewalNotBuilt: return .selfRenewalNotBuilt
            case .releaseInProgress: return .releaseInProgress
            case .handbackUnconfirmed: return .handbackUnconfirmed
            case .restoreToAutomaticUnconfirmed: return .restoreToAutomaticUnconfirmed
            case .restoreToAutomaticFailed: return .restoreToAutomaticFailed
            case .systemSleeping: return .systemSleeping
            case .noThermalTelemetry: return .noThermalTelemetry
            case .supervisorBlind: return .supervisorBlind
            case .foreignManualControl: return .foreignManualControl
            case .unknown: return .unknown("fromTheFuture")
            }
        }

        var expected: ManualControlAvailability.Clearance {
            switch self {
            case .foreignManualControl, .restoreToAutomaticFailed:
                return .durable
            case .releaseInProgress, .handbackUnconfirmed, .restoreToAutomaticUnconfirmed,
                .supervisorBlind, .systemSleeping, .unknown:
                return .pending
            case .writePathNotBuilt, .boundsImplausible, .leaseHeldByAnotherClient,
                .selfRenewalNotBuilt, .noThermalTelemetry, .reclaimedBySystem:
                return .silent
            }
        }
    }

    /// The reasons in each class, from `Tag`'s ruling. `everyReasonIsClassifiedOnce` holds the
    /// three to the vocabulary.
    static let durable = reasons(ruled: .durable)
    static let pending = reasons(ruled: .pending)
    static let silent = reasons(ruled: .silent)

    static func reasons(ruled clearance: ManualControlAvailability.Clearance) -> [Reason] {
        Tag.allCases.filter { $0.expected == clearance }.map(\.reason)
    }

    /// The modes a fan can read.
    static let modes: [FanControlMode] = [.automatic, .manualFixed, .manualCurve]

    /// The modes that are not automatic.
    static let manualModes: [FanControlMode] = [.manualFixed, .manualCurve]

    /// A fan reading `mode` beside `availability`, and nothing else that this judgement could
    /// be tempted to read: bounds that read, a target only when the mode is not automatic.
    static func fan(
        reading mode: FanControlMode, beside availability: ManualControlAvailability
    ) -> FanState {
        FanState(
            index: 0, actualRPM: .measured(1351), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: mode == .automatic ? nil : 3000, mode: mode,
            isReclaimedBySystem: false, manualControlAvailability: availability)
    }

    @Test("The three classes cover all fourteen reasons, each exactly once")
    func everyReasonIsClassifiedOnce() {
        let all = Self.durable + Self.pending + Self.silent
        #expect(all.count == 14)
        #expect(Set(all).count == 14)
        // `Reason.init(wireValue:)` is total, so a reason the vocabulary grows is not in this
        // table until someone puts it here; the exhaustive switches in
        // `ManualControlAvailability.clearance` and in `Tag.init(_:)` are what stop the code
        // compiling until it has been decided.
        let known: Set<String> = [
            "writePathNotBuilt", "boundsImplausible", "reclaimedBySystem",
            "leaseHeldByAnotherClient", "selfRenewalNotBuilt", "releaseInProgress",
            "handbackUnconfirmed", "restoreToAutomaticUnconfirmed", "restoreToAutomaticFailed",
            "systemSleeping", "noThermalTelemetry", "supervisorBlind", "foreignManualControl",
            "fromTheFuture",
        ]
        #expect(Set(all.map(\.wireValue)) == known)
    }

    /// **Mutation (N6b):** change `Tag.expected` for `.supervisorBlind` to `.silent`. Run: red
    /// here, naming the tag, and in the class tests that read the same ruling.
    @Test("The witness agrees with the ruling, and maps every reason both ways")
    func theWitnessAgreesWithTheRuling() {
        for tag in Tag.allCases {
            #expect(
                ManualControlAvailability.unavailable(tag.reason).clearance == tag.expected,
                "\(tag)")
            #expect(Tag(tag.reason) == tag, "\(tag)")
        }
    }

    // MARK: - The classification

    /// **Mutation:** move `.foreignManualControl` into the pending arm of
    /// `ManualControlAvailability.clearance`. Run: red here, naming the reason.
    @Test("A durable reason is durable", arguments: durable)
    func durableReasons(_ reason: Reason) {
        #expect(ManualControlAvailability.unavailable(reason).clearance == .durable)
    }

    @Test("A pending reason is pending", arguments: pending)
    func pendingReasons(_ reason: Reason) {
        #expect(ManualControlAvailability.unavailable(reason).clearance == .pending)
    }

    @Test("A silent reason is silent", arguments: silent)
    func silentReasons(_ reason: Reason) {
        #expect(ManualControlAvailability.unavailable(reason).clearance == .silent)
    }

    /// `available` says manual control could be taken. That is not a statement about the mode,
    /// so it lets the mode speak, as a silent reason does.
    @Test("An available fan's availability is silent")
    func availableIsSilent() {
        #expect(ManualControlAvailability.available.clearance == .silent)
    }

    // MARK: - What a fan's availability makes of its mode

    /// A durable or a pending reason is the helper saying it has not cleared the fan, and a
    /// mode of `automatic` does not contradict it: the helper reports an unreadable `F<n>Md` as
    /// `automatic` (#178), and on Intel the register does not exist.
    ///
    /// **Mutation:** drop the `clearance == .silent` test from `FanState.isClearedToAutomatic`,
    /// leaving `mode == .automatic`. Run: red on every `automatic` row.
    @Test(
        "A durable or pending reason is never cleared, whatever mode the fan reads",
        arguments: durable + pending, modes)
    func aReasonTheHelperHasNotClearedIsNeverCleared(_ reason: Reason, mode: FanControlMode) {
        #expect(!Self.fan(reading: mode, beside: .unavailable(reason)).isClearedToAutomatic)
    }

    /// A silent reason lets the mode decide: automatic is cleared, anything else is not.
    ///
    /// **Mutation:** drop the `mode == .automatic` test from `FanState.isClearedToAutomatic`.
    /// Run: red on every manual row.
    @Test("A silent reason lets the mode decide", arguments: silent)
    func aSilentReasonLetsTheModeDecide(_ reason: Reason) {
        #expect(Self.fan(reading: .automatic, beside: .unavailable(reason)).isClearedToAutomatic)
        for mode in Self.manualModes {
            #expect(
                !Self.fan(reading: mode, beside: .unavailable(reason)).isClearedToAutomatic,
                "\(reason.wireValue) / \(mode)")
        }
    }

    @Test("A fan with no reason beside it lets the mode decide")
    func anAvailableFanLetsTheModeDecide() {
        #expect(Self.fan(reading: .automatic, beside: .available).isClearedToAutomatic)
        for mode in Self.manualModes {
            #expect(!Self.fan(reading: mode, beside: .available).isClearedToAutomatic, "\(mode)")
        }
    }

    /// **Today's real helper:** every fan reports `writePathNotBuilt`, and none of them is held.
    /// A client asking whether such a fan is back under automatic control must be able to say
    /// the helper reports that it is.
    @Test("writePathNotBuilt beside a mode of automatic is cleared")
    func theShippingHelpersFanIsCleared() {
        let fan = Self.fan(reading: .automatic, beside: .unavailable(.writePathNotBuilt))
        #expect(fan.isClearedToAutomatic)
    }

    /// #178, by name: a fan whose register did not read is reported `automatic`, and the reason
    /// beside it is the only field that says the helper has not cleared it.
    @Test("supervisorBlind and foreignManualControl beside a mode of automatic are not cleared")
    func theUnreadModeIsNotTakenAtItsWord() {
        let blind = Self.fan(reading: .automatic, beside: .unavailable(.supervisorBlind))
        #expect(!blind.isClearedToAutomatic)
        let foreign = Self.fan(reading: .automatic, beside: .unavailable(.foreignManualControl))
        #expect(!foreign.isClearedToAutomatic)
    }
}
