import AeolusXPC
import FanKit
import Foundation
import SMCCore

/// How one enumerated fan and one sensor kind are stated on the wire.
///
/// **Pure functions in their own type, rather than an extension on the actor.** The rules
/// here — what may be clamped, what may be claimed, what a firmware bit is allowed to be
/// read as — are the part of the snapshot path worth reading on its own, and they need none
/// of the authority's state to apply. Splitting them out is what keeps
/// `ReadOnlyFanAuthority.swift` inside the 400-line limit without making the actor's
/// `private` state module-visible, which is the trade `SnapshotSensorReads` refused for the
/// same reason and [#128](https://github.com/blamechris/Aeolus/issues/128) records.
enum ReadOnlyFanReport {

    /// One enumerated fan as the wire reports it.
    ///
    /// Nothing here is clamped, floored, or nudged: `F0Ac` was measured at 1343.07 against
    /// a declared `F0Mn` of 1350 on this project's development machine, so a reading below
    /// the declared minimum is a legitimate observation. Clamping governs targets on the
    /// write path, never observations — see `SMCFanEnumeration`.
    static func fanState(
        for fan: SMCFanEnumeration.Fan, reclamation: [Int: ReclamationLedger.Cause]
    ) -> FanState {
        let cause = reclamation[fan.index]
        return FanState(
            index: fan.index,
            // `{fds`, the firmware fan-descriptor struct, is absent on this project's
            // development machine and is not read anywhere in the tree. No name is
            // honest; an invented one is not.
            firmwareName: nil,
            actualRPM: reading(for: fan.actual),
            minimumRPM: reading(for: fan.minimum),
            maximumRPM: reading(for: fan.maximum),
            // "No target is set" rather than "the target could not be read": this helper
            // is asking for nothing, and that is an answer.
            targetRPM: nil,
            mode: .automatic,
            // From § 5's ledger, never a literal — see `reclamation`. Always `false` in
            // this build because no fan is ever off automatic control here, but the field
            // now moves when the mechanism does.
            //
            // **`.systemReclaimed` and nothing else.** The ledger's other cause is a helper
            // that went blind on the fan, which is not a statement about the operating
            // system at all, and this field's contract — rendered verbatim as "Reclaimed by
            // system" — cannot carry it. #140.
            isReclaimedBySystem: cause == .systemReclaimed,
            manualControlAvailability: availability(whenLedgerSays: cause)
        )
    }

    /// What a fan's disposition means for whether it could be leased.
    ///
    /// `.writePathNotBuilt` is the build-level answer, and it stays the answer for every
    /// fan whose bounds this executable could not judge either: E5's bounds gate —
    /// `FanKit.FanControlEnvelope.validating(declaredMinimumRPM:declaredMaximumRPM:)`,
    /// whose failures map to `.boundsImplausible` — is deliberately not consulted here,
    /// because a build-level fact outranks a per-fan one. No fan in this build can be
    /// controlled, so reporting `.boundsImplausible` on one would imply that better bounds
    /// would grant control, which is false of every fan this executable serves. The gate
    /// plugs in here in the epic that also brings the write path it guards.
    ///
    /// **Blindness is the exception, and it is not one of those per-fan facts.** It is § 5
    /// saying it gave a fan up because it could not see it — a claim about the supervisor,
    /// not about what stands between a client and a lease, so it cannot imply that anything
    /// would grant control. It is also the only honest thing the snapshot can say about
    /// such a fan, `isReclaimedBySystem` having said it wrongly as a system reclamation. In
    /// this build it is unreachable for the ledger's own reason — nothing is ever held, so
    /// nothing can go blind — and what changed is where the answer comes from.
    private static func availability(
        whenLedgerSays cause: ReclamationLedger.Cause?
    ) -> ManualControlAvailability {
        switch cause {
        case .supervisorBlind: return .unavailable(.supervisorBlind)
        case .systemReclaimed, nil: return .unavailable(.writePathNotBuilt)
        }
    }

    private static func reading(for outcome: SensorReadOutcome) -> FanReading {
        switch outcome.result {
        case .success(let value):
            return .measured(value.value)
        case .failure(.unknownKey(let key)):
            return .unavailable(reason: "\(key) is not present on this machine")
        case .failure(.readFailed(let reason)), .failure(.notDecodable(let reason)):
            return .unavailable(reason: reason)
        }
    }

    /// Maps `SMCCore`'s physical kind onto the wire's unit vocabulary.
    ///
    /// `SMCSensorProvider` classifies conservatively — only the fan-key naming convention
    /// is treated as known, everything else is `.unknown` — and that conservatism is
    /// carried across the boundary rather than improved on here. A helper guessing
    /// "starts with T, therefore Celsius" would be inventing the decoration this type has
    /// just finished declining to attach.
    static func unit(for kind: SensorReading.Kind) -> SensorSample.Unit {
        switch kind {
        case .temperatureCelsius: return .celsius
        case .rpm: return .rpm
        case .watts: return .watts
        case .volts: return .volts
        case .amps: return .amps
        case .percent: return .percent
        case .unknown: return .unknown
        }
    }
}
