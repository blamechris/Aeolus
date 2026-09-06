// `ManualControlAvailability` and its `Reason`, lifted out of `Fan.swift` by
// [#128](https://github.com/blamechris/Aeolus/issues/128) — a mechanical move, with the type
// and its `Codable` conformance unchanged.
//
// It is the vocabulary that keeps growing: every refusal `docs/SAFETY.md` adds lands in
// `Reason`, and `Fan.swift` had no headroom left for the next one. #128 records the state
// this was filed from — `Fan.swift` sat at exactly 400 lines before #124's additive case, so
// the case had nowhere to go — and the fix for that is a file of its own rather than another
// line in a file that was already full.
//
// `Fan`, `FanControlMode`, `FanReading` and `FanState` stay in `Fan.swift`, along with the
// `measuredFinite(` construction tripwire `FanKitTests.onlyConstructedInFanSwift` pins to
// that file: nothing this file holds constructs one.

/// Whether manual control of a fan can be taken at all right now, and if not, why.
///
/// This is not "is the fan under manual control" — that is `FanControlMode`. It is the
/// prior question: *could* a client acquire control of this fan if it asked? A client
/// that cannot tell the difference between "nothing is holding this fan" and "nothing
/// **can** hold this fan" ends up offering a slider that silently does nothing, which is
/// rule 6 ("never claim control you do not have") failing one step earlier than usual.
///
/// The reasons are named in fan-and-system terms rather than in terms of which binary is
/// installed. `FanKit` is a pure model target; "the helper build shipped without a write
/// path" is a fact about an executable, and modelling it here would make this type
/// describe the deployment rather than the machine.
///
/// New reasons may be added **within** a protocol version, precisely because an
/// unrecognised wire value decodes to `.unknown(_)` rather than failing: see
/// `AeolusXPCVersion`'s bump policy.
public enum ManualControlAvailability: Sendable, Hashable {
    /// The helper can take this fan under a lease.
    case available
    /// It cannot, for the stated reason.
    case unavailable(Reason)

    /// Why manual control of a fan is not available.
    public enum Reason: Sendable, Hashable {
        /// This build has no SMC write path at all. E2's state for every fan: the
        /// boundary exists, the thing behind it is inert, and saying so is the honest
        /// answer rather than a lease that would control nothing.
        case writePathNotBuilt
        /// The fan's firmware bounds (`F0Mn`/`F0Mx`) did not survive a plausibility
        /// check, so there is no envelope to clamp into. Distinct from "no helper" and
        /// from "no such fan": the fan is right there and is refused anyway.
        case boundsImplausible
        /// The system has taken this fan back and is not currently yielding it.
        case reclaimedBySystem
        /// Another client holds the manual-control lease.
        ///
        /// A lease is bound to the connection that acquired it, and the wire reports one
        /// `SystemSnapshot.activeLease` for the whole machine, so control is held by at
        /// most one client at a time. This is what the others are told — the honest
        /// answer to "why can't I take this fan", distinct from "nothing here can be
        /// controlled at all".
        case leaseHeldByAnotherClient
        /// A self-renewing lease was asked for and this build does not implement one.
        ///
        /// Self-renewal's entire safety story is helper restart plus startup
        /// reconciliation, which is not hardware-verified yet, so the helper refuses
        /// rather than granting a lease whose backstop has never been watched to work.
        /// See [ADR 0007](../../docs/ADR/0007-safety-composition.md).
        case selfRenewalNotBuilt
        /// The fan is mid-handback: a previous lease has ended and the restore-to-automatic
        /// write for this fan has not completed yet.
        ///
        /// Transient, and the shortest-lived reason here — `systemSleeping` is the other
        /// transient one, and it lasts until the machine wakes. Granting during the window would
        /// hand a client a lease over a fan that is about to be returned to the system
        /// underneath it — the client writes a target, the in-flight restore lands, and the
        /// client holds a live lease over a fan nothing is honouring. Refusing for a few
        /// milliseconds is the honest answer; a client may simply retry.
        case releaseInProgress
        /// The handback failed: the helper spent its attempts trying to return this fan to
        /// automatic control and the firmware never took the write.
        ///
        /// The durable counterpart to `releaseInProgress`, and the distinction is the
        /// point — that one means *retrying*, this one means *gave up*. A client that
        /// cannot tell them apart retries forever against a fan whose handback is over.
        ///
        /// Manual control is refused because the helper no longer knows what mode the fan
        /// is in: it asked for automatic, was refused, and stopped asking. Granting a lease
        /// over it would be `CLAUDE.md` rule 6 — claiming control of a fan nothing has
        /// confirmed is listening.
        ///
        /// The fan may still be pinned at a speed Aeolus is no longer tracking, and nothing
        /// is watching it: every path that reaches this state clears `docs/SAFETY.md` § 5's
        /// registry — `ReclamationWatchdog.finaliseRelease(fanAt:because:)` empties it before
        /// it revokes, and `manualControlReleased(fanAt:)` drops the entry — so § 5 has no
        /// entry left to cycle over. That gap is
        /// [#181](https://github.com/blamechris/Aeolus/issues/181)'s, which owns
        /// re-registration. Until it lands, the refusal is for the life of the helper
        /// process and `docs/RECOVERY.md` is the user's route out.
        ///
        /// **Two producers, and the second is not a lease teardown.** Startup reconciliation
        /// hands back every fan it finds in manual at bring-up
        /// ([ADR 0011](../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md)),
        /// and a fan the firmware refuses there is in exactly the state the paragraphs above
        /// describe — asked for automatic, refused, no longer asked — reached before a
        /// client ever connected rather than after one disconnected. It is watched by
        /// nothing for the same reason, § 3 included, which is
        /// [#201](https://github.com/blamechris/Aeolus/issues/201)'s.
        case restoreToAutomaticFailed
        /// The machine is going to sleep, and the helper has already handed every fan back.
        ///
        /// `docs/SAFETY.md` § 4 drops every lease and returns every fan to automatic control
        /// in the window `kIOMessageSystemWillSleep` opens, and refuses new leases for the
        /// duration. Without the refusal, a request that was already in flight when the sleep
        /// arrived could resume after the teardown, find an empty table, and engage manual
        /// control on a machine that is about to stop running the helper — a fan pinned
        /// across a sleep by the one path § 4 does not otherwise close.
        ///
        /// Transient, and the advice is to retry after the machine wakes rather than
        /// immediately: nothing the client does shortens it, and the helper clears it on
        /// `kIOMessageSystemHasPoweredOn`.
        case systemSleeping
        /// The helper cannot currently see any critical temperature, so the mechanism
        /// that would protect a leased fan is blind.
        ///
        /// `docs/SAFETY.md` § 3 is a **precondition** of § 1, not a peer of it. A lease
        /// granted while the helper cannot read a temperature pins fans with nothing
        /// watching them: the thermal override cannot fire, the reclamation watchdog
        /// cannot tell divergence from silence, and the only surviving backstop is the
        /// TTL. [ADR 0007](../../docs/ADR/0007-safety-composition.md) records that gap as
        /// its second hole, and refusing the lease is the half of the answer that runs
        /// before any fan is taken off automatic control.
        ///
        /// Not transient in the way `releaseInProgress` is. A client may retry, but
        /// retrying is not the advice — blindness lasts until the SMC answers again, and
        /// nothing the client does affects that.
        case noThermalTelemetry
        /// The helper cannot read *this fan's* control state, so the mechanism that would
        /// notice it being taken back is blind on it.
        ///
        /// `.noThermalTelemetry`'s argument one cardinality down: that one is the machine's
        /// temperature going unreadable, this one is a single fan's state going unreadable
        /// for `ReclamationLimits.blindCyclesBeforeDivergence` consecutive cycles, after
        /// which § 5 reconnects, restores the fan and revokes the lease. ADR 0007's hole 2,
        /// with [#68](https://github.com/blamechris/Aeolus/issues/68) — a stale
        /// `io_connect_t` after wake — as the motivating case.
        ///
        /// **Emphatically not `.reclaimedBySystem`.** That reason says the operating system
        /// took the fan, which is a diagnosis; this one says nobody has been able to look.
        /// Reporting the two as one sent a user to investigate macOS's thermal behaviour
        /// when what had happened was Aeolus's own SMC connection dying, and it claimed a
        /// loss of control that nothing had established — `CLAUDE.md` rule 6 in the
        /// direction that is easy to miss.
        ///
        /// **Two producers, and the second is not a cycle at all.** Startup reconciliation
        /// runs on a bounded budget — see
        /// [ADR 0011](../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md) —
        /// and a fan it never reached before the budget ran out is a fan nobody has looked
        /// at — the sentence above, arrived at by a different route. The helper serves
        /// clients anyway, because refusing to answer a snapshot helps nobody, and refuses
        /// a lease over that fan for the life of the process: reconciliation is one-shot
        /// and never runs again, so nothing will revise the answer.
        case supervisorBlind
        /// Something outside Aeolus is holding this fan in manual mode.
        ///
        /// The helper reads `F<n>Md` once at startup and returns anything it finds in
        /// manual to Apple's thermal management — see
        /// [ADR 0011](../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md).
        /// After that one pass, a fan observed in manual that Aeolus did not engage was put
        /// there by something else: another fan-control tool, or firmware that re-asserted
        /// it. **It is not a reclamation**, and reporting it as one would blame the
        /// operating system for a third party's write.
        ///
        /// Manual control is refused rather than taken, and the fan is **not** restored a
        /// second time. A restore loop against a live writer *is* the fight — each side
        /// undoing the other's mode write, several times a second, over a machine's cooling
        /// — and the honest answer is to decline and say who has it. `F<n>Md` cannot name
        /// the holder, so this reason cannot either; a client rendering it should say the
        /// fan is under another program's control and leave the user to quit it.
        ///
        /// Durable, and not in the way `.releaseInProgress` is transient: nothing in Aeolus
        /// will change it, because nothing in Aeolus put the fan there. It clears when the
        /// other writer hands the fan back.
        case foreignManualControl
        /// A reason this build does not recognise, carried verbatim so a newer helper
        /// can explain itself to an older client without a protocol bump. Render it
        /// generically; never treat it as equivalent to `available`.
        case unknown(String)

        /// The string this reason travels as.
        public var wireValue: String {
            switch self {
            case .writePathNotBuilt: return "writePathNotBuilt"
            case .boundsImplausible: return "boundsImplausible"
            case .reclaimedBySystem: return "reclaimedBySystem"
            case .leaseHeldByAnotherClient: return "leaseHeldByAnotherClient"
            case .selfRenewalNotBuilt: return "selfRenewalNotBuilt"
            case .releaseInProgress: return "releaseInProgress"
            case .restoreToAutomaticFailed: return "restoreToAutomaticFailed"
            case .systemSleeping: return "systemSleeping"
            case .noThermalTelemetry: return "noThermalTelemetry"
            case .supervisorBlind: return "supervisorBlind"
            case .foreignManualControl: return "foreignManualControl"
            case .unknown(let raw): return raw
            }
        }

        /// Forward-tolerant by construction: this initialiser cannot fail, because a
        /// value from a newer peer is information, not an error. Round-tripping a known
        /// value always yields the known case, never `.unknown`.
        public init(wireValue: String) {
            switch wireValue {
            case Reason.writePathNotBuilt.wireValue: self = .writePathNotBuilt
            case Reason.boundsImplausible.wireValue: self = .boundsImplausible
            case Reason.reclaimedBySystem.wireValue: self = .reclaimedBySystem
            case Reason.leaseHeldByAnotherClient.wireValue: self = .leaseHeldByAnotherClient
            case Reason.selfRenewalNotBuilt.wireValue: self = .selfRenewalNotBuilt
            case Reason.releaseInProgress.wireValue: self = .releaseInProgress
            case Reason.restoreToAutomaticFailed.wireValue: self = .restoreToAutomaticFailed
            case Reason.systemSleeping.wireValue: self = .systemSleeping
            case Reason.noThermalTelemetry.wireValue: self = .noThermalTelemetry
            case Reason.supervisorBlind.wireValue: self = .supervisorBlind
            case Reason.foreignManualControl.wireValue: self = .foreignManualControl
            default: self = .unknown(wireValue)
            }
        }
    }
}

extension ManualControlAvailability: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State {
        static let available = "available"
        static let unavailable = "unavailable"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(State.available, forKey: .state)
        case .unavailable(let reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason.wireValue, forKey: .reason)
        }
    }

    /// Decoding fails **closed**. An unrecognised state — a third state some future
    /// version grows — becomes `.unavailable(.unknown(_))`, never `.available`: the
    /// direction of that guess is the whole point, because guessing "available" hands a
    /// client permission it was never granted.
    ///
    /// A structurally broken payload (`unavailable` with no reason) still throws. Within
    /// a version the required fields of a known state cannot move — that is a bump — so
    /// their absence is corruption rather than a newer peer, and a snapshot that decodes
    /// to a wrong answer is worse than one that does not decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        switch state {
        case State.available:
            self = .available
        case State.unavailable:
            let raw = try container.decode(String.self, forKey: .reason)
            self = .unavailable(Reason(wireValue: raw))
        default:
            self = .unavailable(.unknown(state))
        }
    }
}
