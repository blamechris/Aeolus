import Foundation
import Testing

// The keyed exemptions to `aPermitTravelsBesideNothingThatNamesAFan`, in a file of their own so the
// suite's body stays inside `type_body_length` now that the production plane's step and floor hold
// carry their permit (ADR 0014's P1′ amendment).
extension WriteVerbAllowlistTests {

    /// Companions allowed beside a permit for **one named key**, and for no other verb.
    ///
    /// `ReclamationWatchdog.manualControlEngaged(_:under:)` carries the `UUID` of the lease the
    /// fan was engaged under (#357). A registration writes nothing, and its lease is judged
    /// against the permit's own fan at registration and at every examination, so a mismatched
    /// pair ends as a refused registration or `.leaseLapsed`, never as a write. Keyed rather
    /// than added to `clampedCompanions`, so no write verb can take a `UUID` beside its permit:
    /// this suite stays red for one that does, and so does `everyEngageVerbTakesAPermit` unless
    /// the parameter has a default containing parentheses, such as `= UUID()`, whose
    /// declaration its scan misses ([#362](https://github.com/blamechris/Aeolus/issues/362)).
    ///
    /// A key is a file and a signature, not a declaring type, so a second declaration with the
    /// same signature in the same file — an extension on a writer, say — would share the
    /// exemption. `aPermitTravelsBesideNothingThatNamesAFan` therefore requires exactly one
    /// declaration per keyed key (#361's panel).
    ///
    /// The second entry is the same registration as a requirement of
    /// `ReclamationRegistrationRole`, the role level 6 tells § 5 through (ADR 0014's A6 PR-2
    /// amendment). The watchdog's method is its one witness, so it carries nothing the first
    /// entry does not.
    ///
    /// The third is D3's engaged-turn target rule (ADR 0014's P1′ amendment, decision 4):
    /// `EngagementRules.engagedTarget(reading:of:)` judges the `F<n>Tg` the turn read, a
    /// `FanRPMReadback`, against the permit's own floor. A readback is an RPM or the reason there
    /// is none, so it names no fan and no bounds, and the rule writes nothing: what it returns is
    /// the permit's own target at its floor, minted by `target(for:)`, or no write at all.
    ///
    /// The fourth and fifth are the production plane's step body and its floor hold, which take the
    /// step's permit into its write turn so that rule judges the permit's own floor, as the
    /// scripted plane's does. Beside it they take the plane's `PlaneWriteLedger`, its
    /// `PlaneWriteLog` and the turn's `isolated` channel: one per plane, none naming a fan or
    /// bounds, and the fan they act on is the permit's index (`SMCWriteTurns.step`).
    static let keyedCompanions: [String: Set<String>] = [
        "ReclamationWatchdog.swift: manualControlEngaged(_: CommandableFan, under: UUID)": ["UUID"],
        "ReclamationRegistrationRole.swift: manualControlEngaged(_: CommandableFan, under: UUID)": [
            "UUID"
        ],
        "EngagementRules.swift: engagedTarget(reading: FanRPMReadback, of: CommandableFan)": [
            "FanRPMReadback"
        ],
        "SMCWriteTurns.swift: step(_: CommandableFan, ledger: PlaneWriteLedger, "
            + "log: PlaneWriteLog, on: isolated any SMCWriteChannel)": [
                "PlaneWriteLedger", "PlaneWriteLog", "isolated any SMCWriteChannel",
            ],
        "SMCWriteTurns.swift: holdFloor(of: CommandableFan, log: PlaneWriteLog, "
            + "on: isolated any SMCWriteChannel)": [
                "PlaneWriteLog", "isolated any SMCWriteChannel",
            ],
    ]
}
