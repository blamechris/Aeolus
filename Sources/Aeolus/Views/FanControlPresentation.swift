import AeolusLeaseControl
import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

/// What the UI may claim about manual control of one fan: whether a control is shown, whether it
/// is enabled and why not, what it shows as selected, whether it must offer to give the fans back,
/// and the line beneath it (#154, #155).
///
/// **Nothing renders this yet.** It is the logic and its tests. The control that draws it is
/// #153's PR 6, and the contract that control must honour is at the end of this comment.
///
/// Pure, like `FanRowModel`: no I/O, no clock and no actor. It is a function of what the window
/// already has, gathered by `Inputs`, and of one fan's row.
///
/// ## The affordance: the first rule that applies
///
/// 1. **Hidden** when this build ships no helper (`ControlNotTracked.noHelperInThisBuild`). The
///    reason is `ControlSourceDisplay`'s sentence and `HelperStatusDisplay`'s account, so the
///    pane, the footer and this say it in one set of words.
/// 2. **Disabled, not tracked** when no licensed snapshot speaks for this fan: the machine's
///    `ControlSource` is `.notTracked`, or the fan's own `FanControlSource` is, or no snapshot is
///    on screen, or the inputs come from different snapshots (see "One snapshot at a time").
///    The reason is `ControlSourceDisplay.explanation(_:)` where there is one.
/// 3. **Disabled, thermal emergency** while the snapshot reports one. `LeaseAuthority` refuses
///    every new lease while § 3's latch holds (`refuseIfThermalEmergencyActive`, in
///    `acquireLease`), and that is all the reason says: no new lease. It says nothing about which
///    fans anything is driving, and nothing about the lease the app may already hold (#485's S3,
///    #484).
/// 4. **Disabled, held by another lease** when the snapshot lists a lease whose identifier is not
///    the one the driver holds. The helper grants one lease per machine: `acquireLease` refuses
///    `.leaseHeldByAnotherClient` while its table is non-empty, whoever is in it. **Compared by
///    identifier only.** A holder string is free text that any client can choose, ours included,
///    so it never decides "this is us". It is shown through `HelperAuthoredText`'s sanitiser, in
///    `ControlSourceDisplay`'s sentence.
/// 5. **Disabled, refused by the helper** when the fan's `manualControlAvailability` is
///    `.unavailable(reason)`: the refusal `FanRowModel` shows, in the reason's own summary and
///    advice. On today's helper every fan reads `.unavailable` (`.writePathNotBuilt`, or
///    `.foreignManualControl` for a fan another program holds), so every fan stops here.
/// 6. Otherwise **enabled**.
///
/// Rules 3 and 4 are machine-wide, and no fan's availability states either: the helper's ladder
/// leaves both out, so a fan nothing else refuses reads `.available` beside either
/// (`AvailabilityRestatement.swift`'s header). That is why they are rules of their own here and not
/// part of rule 5.
///
/// ## Release is not an affordance
///
/// `canRelease` is true while the driver is acquiring or holding a lease over this fan, and it is
/// read from the driver alone. A disabled control refuses taking or changing manual control; it
/// never refuses giving the fans back. The read connection can go stale while the lease keeps
/// renewing, and rule 2 then disables every fan: without `canRelease` the user's only way back to
/// automatic would be to quit.
///
/// ## The selection is a function of state
///
/// Never of the user's last intent. The inputs are the driver's state and the snapshot on screen,
/// so a click moves the segment only by moving the driver, and only as far as the driver has got:
/// `.applying` until the helper answers, and Custom once a snapshot shows the lease holding.
///
/// - **`.custom(target)`** only when the driver is `.held` with phase `.confirmed(target)`, a
///   licensed snapshot is on screen, and that snapshot's
///   `controlLoss(leaseID:covering:)` over every fan the lease covers is `nil`. That is #472's
///   judgement, used whole: a loss on any covered fan is a loss for the lease, so no fan under it
///   reads Custom. No second judgement of loss is made here.
/// - **`.applying(target)`** while the driver is `.held` with phase `.applying`. It is drawn as
///   asked for, never as achieved.
/// - **`.checking`** while the driver is `.held` and confirmed, and no licensed snapshot is on
///   screen. A wake is one case of this: the age clock counts sleep (`HelperSnapshotSource`), so a
///   snapshot from before the sleep loses its licence at wake, and `PollingViewModel`'s authority
///   watch takes it off screen at its next step. Until that step it is still the snapshot on
///   screen, as every other claim in the window is.
/// - **`.automatic`** only when the fan `isClearedToAutomatic` and the driver neither holds it, nor
///   is acquiring it, nor is releasing (which names no fans, so it covers every one).
/// - **`.unknown`** otherwise.
///
/// ## The status line
///
/// What the driver is doing about this fan, or the last thing that happened to the lease.
///
/// - **Custom says both numbers**: the speed the helper accepted and the held target the snapshot
///   on screen reports. After an adjust they differ until the next snapshot, at most the refresh
///   interval.
/// - **`lost` and `refused` are past events**, worded as what happened ("ended", "could not be
///   shown to have begun", "refused") and what the helper said then, never as a state now. A
///   lease is one per machine and `LeaseLoss` names no fans, so every fan carries the line.
/// - **The emergency is named only from a flag that is set**: the one in
///   `LeaseLoss.Cause.snapshot(_:isThermalEmergencyActive:)`. The flag clears when § 3's latch
///   releases (#476 NB3), so a lease gone with the flag clear says only that control ended. A
///   helper refusal is shown by its own wire code, `thermalEmergencyActive` included: that code is
///   the helper naming it, and it sends it only while § 3's latch is set (`LeaseAuthority`'s grant
///   and `LeaseApplier`'s apply).
/// - **Every helper-authored string goes through `HelperAuthoredText.sanitised(_:)`**: a holder, a
///   fault's detail and code, a reason's wire value, and `HelperFailure.other`.
///
/// ## One snapshot at a time
///
/// Each claim is read from the input that already renders it elsewhere in the window, so the
/// control and the rest of the screen say the same thing: the lease from `ControlSource` (the
/// pane's header), the emergency from `ThermalEmergencyState` (the banner), the availability from
/// the fan's row, and loss from the snapshot on screen. They agree only once `PollingViewModel`
/// has finished a change. It assigns them one at a time and each publisher fires in `willSet`, so a
/// sink on any one of them can pair one snapshot's rows with another's lease. Read them where every
/// change has landed.
///
/// The licence also requires the lease, the emergency and this fan's state to be the ones
/// `renderedSnapshot` carries. `render` assigns `renderedSnapshot` after the rows, the emergency
/// and the lease, so a read that pairs a newer one of those with the older snapshot, where the two
/// differ, is disabled and claims neither Custom nor Automatic.
/// The check cannot see a read that holds only the older snapshot's values for what it compares.
/// A sink on `$fans` runs before any of them has changed. A sink on `$sensors` or
/// `$thermalEmergency` passes when this fan's row did not change, and one on `$controlSource` when
/// neither the row nor the emergency did: the lease has not moved yet. Such a read shows the
/// older snapshot's claim, Custom included, and a sink keeps it until its property is next
/// assigned. Only the contract's first line prevents that.
///
/// ## The contract the control must honour (#153's PR 6)
///
/// - **Compute presentations in a SwiftUI `body`, or on `polling.$revision` as `MenuBarViewModel`
///   does**, reading `Inputs(polling:driver:)` and `polling.fans` together there, or calling
///   `everyFan(of:driver:)`, which does both. Never from a sink on any single published property
///   of `polling`.
/// - **Recompute whenever the driver's state changes as well** (`LeaseDriver.stateUpdates()`):
///   `revision` moves only with `polling`, so a control computed on it alone keeps showing Custom
///   after the driver has lost the lease, until `polling` next moves `revision`.
/// - Read only from a started view model. After `stop()`, nothing withdraws the snapshot on screen.
/// - `.hidden`: no control at all. State its reason once, where the control would be (#154).
/// - `.disabled(reason)`: show the reason's summary, its advice and its wire value where present.
///   Never a greyed control with no explanation.
/// - **Offer to give the fans back whenever `canRelease` is true, whatever `affordance` says.**
///   Auto is `selectAutomatic()`, a release, and a disabled control does not withhold it.
/// - **Draw `selection` and nothing else as selected.** A click calls the driver (`take` for a
///   deliberate choice, `selectAutomatic()` for Auto, `adjust` while held) and selects nothing
///   itself. Draw `.applying` and `.checking` as pending, never as the segment achieved.
/// - Show `status` beneath the control, and draw `lost` and `refused` as what happened.
/// - **A control that speaks for several fans claims no more than each of them does.** It is
///   enabled only if every fan's affordance is enabled. A segment is selected only if every fan's
///   selection is that segment: Auto when every fan is `.automatic`; a percentage when each fan is
///   `.custom` at its own target for that percentage. It offers a release if any fan's
///   `canRelease` is true.
struct FanControlPresentation: Equatable {

    let affordance: Affordance
    let selection: Selection
    /// Whether the control must offer to give the fans back: the driver is acquiring or holding a
    /// lease over this fan. Read from the driver alone, never from `affordance`.
    let canRelease: Bool
    /// `nil` when there is nothing to say beneath the control.
    let status: StatusLine?

    enum Affordance: Equatable {
        /// No control is drawn, for this reason.
        case hidden(Reason)
        /// A control is drawn, and refuses taking or changing manual control, for this reason.
        /// It does not refuse a release: see `canRelease`.
        case disabled(Reason)
        case enabled
    }

    /// Why a control is hidden or disabled, in words that already exist elsewhere where they do.
    struct Reason: Equatable {
        let summary: String
        let advice: String?
        /// The helper's own word for the refusal, shown beside the prose as a raw key is shown
        /// beside a label. Cleaned, because an `unknown` reason's wire value is the helper's text.
        /// `nil` when the helper did not state the reason.
        let wireValue: String?
    }

    enum Selection: Equatable {
        /// The helper reports the fan cleared to automatic, and the driver is neither holding,
        /// acquiring nor releasing it.
        case automatic
        /// The helper accepted this target, and the snapshot on screen shows the lease holding
        /// every fan it covers.
        case custom(FanTargetRPM)
        /// This target has been sent and the helper has not answered.
        case applying(FanTargetRPM)
        /// The lease is held, and no licensed snapshot on screen can show it still holds the fans.
        case checking
        /// Nothing on screen says which choice is in effect.
        case unknown
    }

    /// One line beneath the control.
    struct StatusLine: Equatable {
        let text: String
        let detail: String?
    }

    /// Everything the presentation is a function of, for the whole machine. One fan's row is the
    /// other half.
    struct Inputs: Equatable {
        let controlSource: ControlSource
        let thermalEmergency: ThermalEmergencyState
        /// The snapshot whose claims are on screen: `PollingViewModel.renderedSnapshot`.
        let renderedSnapshot: SystemSnapshot?
        let driver: LeaseDriverState
    }

    init(reading: FanPollingReading, given inputs: Inputs) {
        let licence = Licence(reading: reading, inputs: inputs)
        let affordance = Self.affordance(reading, licence, inputs)
        let canRelease = Self.canRelease(reading.index, inputs.driver)
        if case .hidden = affordance {
            self.init(
                affordance: affordance, selection: .unknown, canRelease: canRelease, status: nil)
            return
        }
        let claim = Self.claim(about: reading.index, licence, inputs.driver)
        self.init(
            affordance: affordance, selection: claim.selection, canRelease: canRelease,
            status: claim.status)
    }

    private init(
        affordance: Affordance, selection: Selection, canRelease: Bool, status: StatusLine?
    ) {
        self.affordance = affordance
        self.selection = selection
        self.canRelease = canRelease
        self.status = status
    }

    /// Whether the driver is acquiring or holding a lease over fan `index`. Exhaustive, with no
    /// `default:`, so a driver state added later has to be decided here.
    private static func canRelease(_ index: Int, _ driver: LeaseDriverState) -> Bool {
        switch driver {
        case .acquiring(let fans):
            return fans.contains(index)
        case .held(let held):
            return held.fans.contains(index)
        case .idle, .releasing, .released, .lost, .refused:
            return false
        }
    }
}

extension FanControlPresentation.Inputs {

    /// What `polling` has on screen now, beside the driver's state.
    @MainActor
    init(polling: PollingViewModel, driver: LeaseDriverState) {
        self.init(
            controlSource: polling.controlSource, thermalEmergency: polling.thermalEmergency,
            renderedSnapshot: polling.renderedSnapshot, driver: driver)
    }
}

extension FanControlPresentation {

    /// Every fan `polling` shows, each beside its presentation, from one read of `polling`: the
    /// rows and the inputs are read together, so a caller never pairs them itself.
    @MainActor
    static func everyFan(
        of polling: PollingViewModel, driver: LeaseDriverState
    ) -> [(reading: FanPollingReading, presentation: FanControlPresentation)] {
        let inputs = Inputs(polling: polling, driver: driver)
        return polling.fans.map { ($0, FanControlPresentation(reading: $0, given: inputs)) }
    }
}

// MARK: - The affordance

extension FanControlPresentation {

    /// Whether a licensed snapshot speaks for this fan, and if so what it says.
    private enum Licence {
        case licensed(SystemSnapshot, FanState, activeLease: Lease?)
        case notTracked(ControlNotTracked)
        /// Every source says tracked, and no snapshot is on screen.
        case nothingOnScreen
        /// Every source says tracked, and they do not all come from the snapshot on screen.
        case betweenSnapshots

        init(reading: FanPollingReading, inputs: Inputs) {
            switch (inputs.controlSource, reading.control, inputs.renderedSnapshot) {
            case (.notTracked(let why), _, _):
                self = .notTracked(why)
            case (_, .notTracked(let why), _):
                self = .notTracked(why)
            case (.helperSnapshot, .reported, .none):
                self = .nothingOnScreen
            case (.helperSnapshot(let lease), .reported(let state, _), .some(let snapshot)):
                let whole = Self.isOneSnapshot(
                    snapshot, lease: lease, state: state, emergency: inputs.thermalEmergency)
                self = whole ? .licensed(snapshot, state, activeLease: lease) : .betweenSnapshots
            }
        }

        /// Whether every input the presentation reads from a snapshot is the one `snapshot`
        /// carries: the generation check. `PollingViewModel.render` assigns `renderedSnapshot`
        /// after the rows, the lease and the emergency, so a read that pairs a newer one of those
        /// with the older snapshot fails here when the two differ. A read wholly of the older
        /// snapshot passes; see the type's documentation on reads taken part-way through.
        private static func isOneSnapshot(
            _ snapshot: SystemSnapshot, lease: Lease?, state: FanState,
            emergency: ThermalEmergencyState
        ) -> Bool {
            guard lease == snapshot.activeLease else { return false }
            guard snapshot.fans.first(where: { $0.index == state.index }) == state else {
                return false
            }
            guard emergency == (snapshot.isThermalEmergencyActive ? .active : .inactive) else {
                return false
            }
            return true
        }
    }

    private static func affordance(
        _ reading: FanPollingReading, _ licence: Licence, _ inputs: Inputs
    ) -> Affordance {
        switch licence {
        case .notTracked(.noHelperInThisBuild):
            return .hidden(.noHelperInThisBuild)
        case .notTracked(let why):
            return .disabled(.notTracked(why))
        case .nothingOnScreen:
            return .disabled(.nothingOnScreen)
        case .betweenSnapshots:
            return .disabled(.betweenSnapshots)
        case .licensed(_, _, let activeLease):
            if inputs.thermalEmergency == .active {
                return .disabled(.thermalEmergencyActive)
            }
            if let activeLease, !isHeldByThisDriver(activeLease, inputs.driver) {
                return .disabled(.heldElsewhere(activeLease))
            }
            if let refusal = FanRowModel(reading: reading).refusal {
                return .disabled(Reason(refusal))
            }
            return .enabled
        }
    }

    /// Whether `lease` is the one the driver holds, **by identifier**. Never by holder.
    private static func isHeldByThisDriver(_ lease: Lease, _ driver: LeaseDriverState) -> Bool {
        guard case .held(let held) = driver else { return false }
        return held.lease.id == lease.id
    }
}

extension FanControlPresentation.Reason {

    /// `ControlSourceDisplay`'s sentence, and `HelperStatusDisplay`'s account beneath it.
    static let noHelperInThisBuild = Self(
        summary: ControlSourceDisplay.explanation(.noHelperInThisBuild),
        advice: HelperStatusDisplay.text(for: .unavailableInThisBuild).detail,
        wireValue: nil)

    static func notTracked(_ why: ControlNotTracked) -> Self {
        Self(summary: ControlSourceDisplay.explanation(why), advice: nil, wireValue: nil)
    }

    static let nothingOnScreen = Self(
        summary: "No helper snapshot is on screen.", advice: nil, wireValue: nil)

    /// What the generation check refused: the inputs do not all come from the snapshot on screen.
    static let betweenSnapshots = Self(
        summary:
            "The window's inputs come from different helper snapshots, as they do part-way "
            + "through an update, so nothing is claimed from them.",
        advice: nil,
        wireValue: nil)

    /// No new lease while the emergency lasts, and nothing more: see the type's rule 3. The
    /// wording #485's S3 gives the banner, which today still says "grants no manual control".
    static let thermalEmergencyActive = Self(
        summary:
            "Thermal emergency reported by the helper — it grants no new manual-control lease "
            + "while this lasts.",
        advice: nil,
        wireValue: nil)

    /// `ControlSourceDisplay`'s sentence for a listed lease, which sanitises the holder, so the
    /// header and the control name it in the same words. The advice is the one
    /// `ManualControlAvailability.Reason.leaseHeldByAnotherClient` gives, and its summary is not
    /// used: it says "another Aeolus client", and a listed lease can be the app's own lost one.
    static func heldElsewhere(_ lease: Lease) -> Self {
        let listed = ControlSourceDisplay.text(for: .helperSnapshot(activeLease: lease))
        return Self(
            summary: listed.detail ?? listed.headline,
            advice: ManualControlAvailability.Reason.leaseHeldByAnotherClient.recoveryAdvice,
            wireValue: nil)
    }

    /// The refusal the fan's row shows, unchanged.
    init(_ refusal: FanRowModel.Refusal) {
        self.init(summary: refusal.summary, advice: refusal.advice, wireValue: refusal.wireValue)
    }
}

// MARK: - The selection and the status line

extension FanControlPresentation {

    private typealias Claim = (selection: Selection, status: StatusLine?)

    private static func claim(
        about index: Int, _ licence: Licence, _ driver: LeaseDriverState
    ) -> Claim {
        switch driver {
        case .held(let held) where held.fans.contains(index):
            return heldClaim(about: index, held, licence)
        case .acquiring(let fans) where fans.contains(index):
            return (.unknown, StatusLine(text: "Asking the helper for control.", detail: nil))
        case .releasing:
            let line = StatusLine(
                text: "Releasing the lease. The helper has not answered yet.", detail: nil)
            return (.unknown, line)
        case .lost(let loss):
            return (automaticOrUnknown(licence), LeaseEventText.lost(loss))
        case .refused(let fault):
            return (automaticOrUnknown(licence), LeaseEventText.refused(fault))
        case .idle, .acquiring, .held, .released:
            return (automaticOrUnknown(licence), nil)
        }
    }

    /// For a fan the driver holds nothing over.
    private static func automaticOrUnknown(_ licence: Licence) -> Selection {
        guard case .licensed(_, let state, _) = licence, state.isClearedToAutomatic else {
            return .unknown
        }
        return .automatic
    }

    private static func heldClaim(
        about index: Int, _ held: HeldLease, _ licence: Licence
    ) -> Claim {
        let noSpeed = StatusLine(
            text: "Not confirmed: no speed for this fan has been accepted.", detail: nil)
        switch held.phase {
        case .applying(let target, _):
            guard let speed = target.speeds[index] else { return (.unknown, noSpeed) }
            return (
                .applying(speed),
                StatusLine(
                    text: "Asked the helper for \(rpm(speed.rpm)). Not confirmed yet.", detail: nil)
            )
        case .confirmed(let target):
            guard case .licensed(let snapshot, let state, _) = licence else {
                return (.checking, unchecked(licence))
            }
            guard let speed = target.speeds[index] else { return (.unknown, noSpeed) }
            guard snapshot.controlLoss(leaseID: held.lease.id, covering: held.fans) == nil else {
                let line = StatusLine(
                    text:
                        "Not confirmed: the helper's snapshot does not show this lease holding "
                        + "its fans.",
                    detail: nil)
                return (.unknown, line)
            }
            let reported = state.targetRPM.map { rpm($0) } ?? "no held target"
            let line = StatusLine(
                text: "Accepted \(rpm(speed.rpm)); the helper's last snapshot reports \(reported).",
                detail: nil)
            return (.custom(speed), line)
        }
    }

    /// Why a confirmed lease cannot be checked against what is on screen.
    private static func unchecked(_ licence: Licence) -> StatusLine {
        guard case .betweenSnapshots = licence else {
            return StatusLine(
                text: "Not confirmed: no current helper snapshot is on screen.", detail: nil)
        }
        return StatusLine(
            text: "Not confirmed: the window's inputs come from different helper snapshots.",
            detail: nil)
    }

    private static func rpm(_ value: Double) -> String {
        ReadingFormatting.number(value) + " RPM"
    }
}

// MARK: - Past events

/// The status line for a lease that ended or was refused: what happened, in the past tense, with
/// every helper-authored string cleaned.
private enum LeaseEventText {

    typealias StatusLine = FanControlPresentation.StatusLine

    static func lost(_ loss: LeaseLoss) -> StatusLine {
        let text: String
        if case .acquireUnanswered = loss.cause {
            text = "Control could not be shown to have begun."
        } else if loss.afterWake {
            // `LeaseLoss.afterWake`: the helper releases every lease before a sleep, so a
            // renderer may say control ended across it. It is an order of events, not a cause.
            text = "Control ended across sleep."
        } else {
            text = "Control ended."
        }
        return StatusLine(text: text, detail: cause(loss.cause))
    }

    static func refused(_ fault: AeolusXPCFault) -> StatusLine {
        StatusLine(text: "The helper refused the request for control.", detail: Self.fault(fault))
    }

    private static func cause(_ cause: LeaseLoss.Cause) -> String {
        switch cause {
        case .acquireUnanswered(let failure):
            return "The request for control " + Self.failure(failure)
        case .renewal(let failure):
            return "A renewal " + Self.failure(failure)
        case .apply(let failure):
            return "A speed change " + Self.failure(failure)
        case .snapshot(let loss, let isThermalEmergencyActive):
            // The emergency is named from this flag and from nothing else: not from the loss
            // being `.leaseNotListed(listed: nil)`, which § 3's revocation produces and so does
            // any other way the helper drops a lease (#476 NB3).
            guard isThermalEmergencyActive else { return snapshot(loss) }
            return snapshot(loss) + " That snapshot reported a thermal emergency."
        case .connection(let health):
            return connection(health)
        case .heartbeatFailed:
            return "The lease could no longer be renewed on schedule."
        }
    }

    /// What the control connection did, in the past tense, with the state's own name beside it.
    /// Not `ControlSourceDisplay`'s sentences: those describe the connection now, and a
    /// replacement connection reports `.idle`, which that text calls "not connected yet".
    private static func connection(_ health: HelperConnectionHealth) -> String {
        switch health {
        case .idle:
            return "The connection to the helper reported no handshake (idle)."
        case .handshaken:
            return "The connection to the helper reported a handshake (handshaken)."
        case .unresponsive:
            return "The helper stopped answering (unresponsive)."
        case .interrupted:
            return "The helper process went away (interrupted)."
        case .invalidated:
            return "The connection to the helper ended (invalidated)."
        case .refused:
            return "Aeolus and the helper would not agree to talk (refused)."
        case .versionMismatched:
            return "This copy of Aeolus and the helper did not share a protocol version "
                + "(versionMismatched)."
        }
    }

    /// What a snapshot showed, from `ControlLoss`. Never names the emergency: the cause's flag
    /// does that.
    private static func snapshot(_ loss: ControlLoss) -> String {
        switch loss {
        case .leaseNotListed(listed: .none):
            return "The helper's snapshot no longer listed this lease."
        case .leaseNotListed(listed: .some(let other)):
            return "The helper's snapshot listed another lease instead, held by “"
                + HelperAuthoredText.sanitised(other.holderDescription) + "”."
        case .thermalEmergency:
            return "The helper's snapshot still listed this lease, but no longer showed it in "
                + "control."
        case .fanNotReported(let fan):
            return "The helper's snapshot did not report fan \(fan)."
        case .reclaimedBySystem(let fan):
            return "The helper reported fan \(fan) reclaimed by the system."
        case .fanNotHeld(let fan):
            return "The helper's snapshot did not show fan \(fan) held."
        }
    }

    private static func failure(_ failure: HelperFailure) -> String {
        switch failure {
        case .refused(let fault):
            return "was refused: " + Self.fault(fault)
        case .failed(let error):
            // As `HelperSnapshotSource` renders a failed request: the description, cleaned.
            let description = error.errorDescription ?? String(describing: error)
            return "went unanswered. " + HelperAuthoredText.sanitised(description)
        case .other(let text):
            return "failed: " + HelperAuthoredText.sanitised(text)
        }
    }

    /// A fault by its wire code, with any free text it carries cleaned.
    ///
    /// Not `errorDescription`: that text says `.leaseExpired` means "the fans have returned to
    /// automatic control", which is a snapshot's to show. A refused reason's summary describes the
    /// reason as it stands, so it is introduced as what the helper's answer meant at the time.
    /// **Exhaustive, with no `default:`**, so a fault added to the vocabulary is a compile error
    /// here until it is rendered.
    private static func fault(_ fault: AeolusXPCFault) -> String {
        switch fault {
        case .manualControlUnavailable(let reason):
            return fault.wireCode + " (" + HelperAuthoredText.sanitised(reason.wireValue)
                + "). At the time, that meant: " + reason.userFacingSummary
        case .malformedPayload(let detail), .helperFailed(let detail):
            return fault.wireCode + ": " + HelperAuthoredText.sanitised(detail)
        case .invalidParameter(let name, let detail):
            return fault.wireCode + " " + HelperAuthoredText.sanitised(name) + ": "
                + HelperAuthoredText.sanitised(detail)
        case .boundsImplausible(let fanIndex, let detail):
            return fault.wireCode + ", fan \(fanIndex): " + HelperAuthoredText.sanitised(detail)
        case .unknown(let code, let detail):
            let suffix = detail.map { ": " + HelperAuthoredText.sanitised($0) } ?? ""
            return HelperAuthoredText.sanitised(code) + suffix
        case .handshakeRequired, .versionMismatch, .leaseExpired, .leaseUnknown,
            .leaseNotHeldByThisConnection, .thermalEmergencyActive, .reclaimedBySystem:
            return fault.wireCode
        }
    }
}
