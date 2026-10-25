import AeolusLeaseControl
import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

/// What the UI may claim about manual control of one fan: whether a control is shown, whether it
/// is enabled and why not, what it shows as selected, whether it must offer to give the fans back,
/// and the line beneath it (#154, #155).
///
/// **Rendered by the main window's one control for all fans** (`AllFansControlPresentation`, drawn
/// at the head of `FanListView`, #153's PR 6b). The contract that control honours is at the end of
/// this comment. Per-fan control is PR 8.
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
/// 3. **Disabled, thermal emergency** while the snapshot reports one. `LeaseAuthority` refuses a
///    grant that finds § 3's latch holding (`refuseIfThermalEmergencyActive`, in
///    `acquireLease`), and that is all the reason says: no new lease. A grant already past that
///    check when the emergency engages proceeds, and each § 3 cycle that keeps the latch revokes
///    it (`ThermalEmergencyDisplay`'s documentation; `docs/records/handback-ledger.md`, "Why § 3
///    revokes every lease"). It says nothing about which fans anything is driving, and nothing
///    about the lease the app may already hold (#485's S3, #484).
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
/// - **`.automatic`** only when all four of ADR 0015 D1's conditions hold
///   (`automaticClaim(_:_:)`, the one function that decides it):
///   1. **The driver holds nothing and is not acquiring or releasing:** it is `.idle`,
///      `.released`, `.lost` or `.refused`. Never while it holds the fan, acquires it or
///      releases, nor for a fan beside a lease it holds or is acquiring over other fans.
///   2. **The snapshot on screen was read after the driver last stopped acting:** its read's ticket
///      (`PollingViewModel.renderedReadTicket`) is admitted by the evidence the driver published
///      with its state (`LeaseDriverReport.AutomaticEvidence`). Automatic's evidence is an
///      absence, no lease and the fan cleared, and that looks the same in a snapshot read before
///      the grant and in one read after the release, so only the read's timing tells them apart.
///      Not even an answered release proves it: the helper's `releaseLease` removes the lease and
///      then awaits a restore that does not throw, so its reply means "accepted", not "done" (ADR
///      0015's context). `.idle` sets no floor; a read with no ticket passes no floor; and while an
///      `apply` sent before the driver stopped is unanswered, no read is evidence (#498's S2).
///   3. **That snapshot lists no lease**, and 4. **reports the fan `isClearedToAutomatic`**: one
///      predicate, `SystemSnapshot.showsAutomatic(_:)`, the one `fanctl auto`'s safe state asks
///      (ADR 0015 D4). A fan under a live lease whose `apply` has not landed reads available and
///      automatic, because the helper cannot state `.leaseHeldByAnotherClient` per fan; that holds
///      for the app's own lease and for another client's, and for a lease the helper still holds
///      after a release it did not confirm.
///
///   It needs a licensed snapshot: none on screen, or one between snapshots, claims nothing. A new
///   process starts `.idle`, so it claims Automatic from clearance and the listed lease alone; the
///   no-lease condition is what refuses it while the helper still lists an earlier process's lease.
/// - **`.unknown`** otherwise.
///
/// ## The status line
///
/// What the driver is doing about this fan, or the last thing that happened to the lease.
///
/// - **Custom says both numbers**: the speed the helper accepted and the held target the snapshot
///   on screen reports, named as a held target so that it never reads as a measured speed beside
///   the row's actual RPM. After an adjust they differ until the next snapshot, at most the
///   refresh interval.
/// - **`lost` and `refused` are past events**, worded as what happened ("ended", "could not be
///   shown to have begun", "refused") and what the helper said then, never as a state now. A
///   lease is one per machine and `LeaseLoss` names no fans, so every fan carries the line. A
///   refused reason is said in the past tense (`pastTenseSummary`), with the wire code after it as
///   a detail, never ahead of it.
/// - **`released` says what the app is doing**: it renews no lease. That is true on every path into
///   it, including one where the helper still lists the lease after a release it did not confirm,
///   so it never says the app holds none. It says nothing about the fans, which each row reports
///   from the helper and the selection claims, and never "automatic".
/// - **A second line, `awaitingApply`, says why Auto is not shown selected while an `apply` is
///   unanswered** (#505). It is given only beside `released`, `lost` and `refused`, the states in
///   which the driver has stopped acting, and only while their evidence is `.noRead`: the driver
///   stopped with an `apply` it sent unanswered, and no read is evidence until the last such
///   `apply` has answered (`LeaseDriverReport.AutomaticEvidence.noRead`). It says what Aeolus is
///   waiting for and what the control does meanwhile. Not what the fans are doing, not
///   "automatic", not when the wait ends, and not "the last" speed change: the one unanswered can
///   be an earlier lease's, and there can be several. See `StatusLine.awaitingApply`.
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
/// ## The contract the control must honour (#153's PR 6b)
///
/// - **Compute presentations in a SwiftUI `body`, or on `polling.$revision` as `MenuBarViewModel`
///   does, through `onScreen(in:driver:)`**, which reads the rows and the inputs together. Never
///   from a sink on any single published property of `polling`. `onScreen` is the only entry
///   production code takes. `init(reading:given:)` and `Inputs(polling:driver:)` stay `internal`
///   for this file and for the suite, which pins each rule one fan at a time, and nothing else in
///   the app pairs a row with inputs by hand. That is documented here, not enforced by an access
///   level.
/// - **Recompute whenever the driver's report changes as well** (`LeaseDriver.reportUpdates()`,
///   through `LeaseStateModel`): `revision` moves only with `polling`, so a control computed on it
///   alone keeps showing Custom after the driver has lost the lease, until `polling` next moves
///   `revision`. Pass the report whole, never a state beside a floor read at another time.
/// - Read only from a started view model. After `stop()`, nothing withdraws the snapshot on screen.
/// - `.hidden`: no control at all. State its reason once, where the control would be (#154).
/// - `.disabled(reason)`: show the reason's summary, its advice and its wire value where present.
///   Never a greyed control with no explanation.
/// - **Offer to give the fans back whenever `canRelease` is true, whatever `affordance` says.**
///   Auto is `selectAutomatic()`, a release, and a disabled control does not withhold it.
/// - **Draw `selection` and nothing else as selected.** A click calls the driver (`take` for a
///   deliberate choice, `selectAutomatic()` for Auto, `adjust` while held) and selects nothing
///   itself. Draw `.applying` and `.checking` as pending, never as the segment achieved:
///   `.applying` at the segment its target names; `.checking` with no segment, because no licensed
///   snapshot is on screen whose bounds could name the percentage a held target is, and the row's
///   displayed bounds are not what the helper clamps to (#497's review, S2).
/// - Show `status` beneath the control, then `awaitingApply`, and draw `lost` and `refused` as
///   what happened.
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
    /// Why Auto is not shown selected: `StatusLine.awaitingApply` while the driver has stopped
    /// acting with an `apply` it sent unanswered (evidence `.noRead`), and `nil` otherwise. Said
    /// after `status`, never in place of it.
    let awaitingApply: StatusLine?

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
        /// The driver holds nothing and is not acquiring or releasing, and the licensed snapshot on
        /// screen was read after it last stopped acting, lists no lease and reports the fan
        /// cleared to automatic (ADR 0015 D1).
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
        /// The lease driver's ticket for the read that brought it:
        /// `PollingViewModel.renderedReadTicket`.
        let renderedReadTicket: LeaseDriver.SnapshotTicket?
        let driver: LeaseDriverState
        /// Which reads may show a fan automatic, as the driver published it with `driver`: one
        /// `LeaseDriverReport`, never two values read apart.
        let automaticEvidence: LeaseDriverReport.AutomaticEvidence
    }

    init(reading: FanPollingReading, given inputs: Inputs) {
        let licence = Licence(reading: reading, inputs: inputs)
        let affordance = Self.affordance(reading, licence, inputs)
        let canRelease = Self.canRelease(reading.index, inputs.driver)
        if case .hidden = affordance {
            self.init(
                affordance: affordance, selection: .unknown, canRelease: canRelease, status: nil,
                awaitingApply: nil)
            return
        }
        let claim = Self.claim(about: reading.index, licence, inputs)
        self.init(
            affordance: affordance, selection: claim.selection, canRelease: canRelease,
            status: claim.status, awaitingApply: claim.awaitingApply)
    }

    private init(
        affordance: Affordance, selection: Selection, canRelease: Bool, status: StatusLine?,
        awaitingApply: StatusLine?
    ) {
        self.affordance = affordance
        self.selection = selection
        self.canRelease = canRelease
        self.status = status
        self.awaitingApply = awaitingApply
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

    /// What `polling` has on screen now, beside the driver's report.
    @MainActor
    init(polling: PollingViewModel, driver report: LeaseDriverReport) {
        self.init(
            controlSource: polling.controlSource, thermalEmergency: polling.thermalEmergency,
            renderedSnapshot: polling.renderedSnapshot,
            renderedReadTicket: polling.renderedReadTicket, driver: report.state,
            automaticEvidence: report.automaticEvidence)
    }
}

extension FanControlPresentation {

    /// Every fan `polling` shows, each beside its presentation, from one read of `polling`: the
    /// rows and the inputs are read together, so a caller never pairs them itself.
    ///
    /// **Named `onScreen`, not `everyFan` as #488 had it.** `.everyFan` is the machine-wide
    /// restore scope's token, and `PanicPathScopeTripwireTests` counts every file under
    /// `Sources/` whose code names it as a call site of that restore. A caller writing
    /// `FanControlPresentation.everyFan(of:)` would be counted as one.
    @MainActor
    static func onScreen(
        in polling: PollingViewModel, driver: LeaseDriverReport
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
    /// banner's own sentence (`ThermalEmergencyDisplay.emergency`), so the control and the banner
    /// above it cannot describe one emergency two ways.
    static let thermalEmergencyActive = Self(
        summary: ThermalEmergencyDisplay.emergency.text,
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

    private typealias Claim = (
        selection: Selection, status: StatusLine?, awaitingApply: StatusLine?
    )

    private static func claim(
        about index: Int, _ licence: Licence, _ inputs: Inputs
    ) -> Claim {
        switch inputs.driver {
        case .held(let held) where held.fans.contains(index):
            let claim = heldClaim(about: index, held, licence)
            return (claim.selection, claim.status, nil)
        case .acquiring(let fans) where fans.contains(index):
            return (.unknown, StatusLine(text: "Asking the helper for control.", detail: nil), nil)
        case .releasing:
            let line = StatusLine(
                text: "Releasing the lease. The helper has not answered yet.", detail: nil)
            return (.unknown, line, nil)
        case .acquiring, .held:
            // A lease over other fans: never Automatic beside it.
            return (.unknown, nil, nil)
        // ADR 0015 D1's first condition: the driver holds nothing and is not acquiring or
        // releasing. The other three are `automaticClaim`'s. `idle` has never acted, so it has
        // sent no `apply` to wait for.
        case .idle:
            return (automaticClaim(licence, inputs), nil, nil)
        case .released:
            return stopped(LeaseEventText.released, licence, inputs)
        case .lost(let loss):
            return stopped(LeaseEventText.lost(loss), licence, inputs)
        case .refused(let fault):
            return stopped(LeaseEventText.refused(fault), licence, inputs)
        }
    }

    /// A driver that has stopped acting: `released`, `lost` or `refused`, the three arms above
    /// that call this, so "stopped acting" is decided by `claim`'s one switch. The selection is
    /// `automaticClaim`'s, the status is the event, and `awaitingApply` follows the evidence.
    private static func stopped(
        _ event: StatusLine, _ licence: Licence, _ inputs: Inputs
    ) -> Claim {
        (automaticClaim(licence, inputs), event, awaitingApply(inputs.automaticEvidence))
    }

    /// `StatusLine.awaitingApply` while no read is evidence, beside a driver that has stopped
    /// acting. Exhaustive, with no `default:`, so evidence added later has to be decided here.
    ///
    /// Beside a stopped driver, `.noRead` means an `apply` it sent is unanswered: the driver
    /// publishes it on a stop only with an `apply` unanswered, and replaces it with `readFrom` when
    /// the last one answers (`LeaseDriverReport.AutomaticEvidence.noRead`;
    /// `LeaseDriverApplyCountTests`). Beside any other state the evidence is only kept, and an
    /// `apply` may have answered since, so only `stopped` asks this.
    private static func awaitingApply(
        _ evidence: LeaseDriverReport.AutomaticEvidence
    ) -> StatusLine? {
        switch evidence {
        case .noRead:
            return .awaitingApply
        case .anyRead, .readFrom:
            return nil
        }
    }

    /// Automatic, for a driver that holds nothing and is not acquiring or releasing: ADR 0015
    /// D1's other three conditions, and the only place the selection says Automatic.
    ///
    /// - The snapshot is licensed, so it is the one on screen and speaks for this fan.
    /// - Its read began after the driver last stopped acting: the driver's evidence admits the
    ///   ticket on screen. A snapshot that shows no lease and the fan cleared can predate the
    ///   grant; only its read's timing says it does not.
    /// - It lists no lease and reports the fan cleared, `SystemSnapshot.showsAutomatic(_:)`, the
    ///   predicate `fanctl`'s safe state asks of every fan. The fan's state is the snapshot's own:
    ///   the licence holds it to the entry `renderedSnapshot` carries.
    private static func automaticClaim(_ licence: Licence, _ inputs: Inputs) -> Selection {
        guard case .licensed(let snapshot, let state, _) = licence,
            inputs.automaticEvidence.admits(inputs.renderedReadTicket),
            snapshot.showsAutomatic([state])
        else { return .unknown }
        return .automatic
    }

    private static func heldClaim(
        about index: Int, _ held: HeldLease, _ licence: Licence
    ) -> (selection: Selection, status: StatusLine?) {
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
            return (.custom(speed), StatusLine(text: customLine(speed, state), detail: nil))
        }
    }

    /// The Custom line: the speed the helper accepted, then the held target the snapshot on screen
    /// reports, named as a target so that it does not read as a measured speed beside the row's
    /// actual RPM. Under `.custom` the snapshot always states one, because `controlLoss` found
    /// every covered fan with a positive held target. The other wording is for a change that broke
    /// that: it says what is on screen rather than inventing a figure.
    private static func customLine(_ speed: FanTargetRPM, _ state: FanState) -> String {
        guard let target = state.targetRPM else {
            return "Accepted \(rpm(speed.rpm)); the snapshot on screen reports no held target for "
                + "this fan."
        }
        return "Accepted \(rpm(speed.rpm)); the snapshot on screen reports a held target of "
            + "\(rpm(target))."
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

extension FanControlPresentation.StatusLine {

    /// Why Auto is not shown selected while the driver has stopped acting with an `apply` it sent
    /// unanswered (#505). Given only beside `released`, `lost` and `refused` with evidence
    /// `.noRead`, and gone with it. Each word holds while it is shown:
    ///
    /// - **"Waiting for the helper to answer"**: an `apply` is a request to the helper, and the
    ///   driver awaits its reply. The wait ends at the answer or at the client's deadline, after
    ///   which the `apply` counts as answered (ADR 0015's assumptions), and the line goes either
    ///   way. It says neither which will end it nor when.
    /// - **"a speed change"**: an `apply`, in the words `LeaseEventText` uses for one. "A", not "the
    ///   last": the one unanswered can be an earlier lease's, and there can be several.
    /// - **"Aeolus sent"**: this driver's. A relaunch starts `idle`, which waits for nothing.
    /// - **"Auto is not shown as selected"**: `.noRead` admits no read, so `automaticClaim` answers
    ///   `.unknown` for every fan, and the all-fans control selects Auto only when every fan reads
    ///   `.automatic`. "Auto" is the segment's title, and "shown" makes it the control's, not the
    ///   fans': the line says nothing about what the fans are doing, which each row reports.
    /// - **"while Aeolus waits"**: the same wait, so the line promises nothing after it. A read
    ///   after the wait still has to list no lease and show each fan cleared (ADR 0015 D1).
    static let awaitingApply = Self(
        text: "Waiting for the helper to answer a speed change Aeolus sent.",
        detail: "Auto is not shown as selected while Aeolus waits.")
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

    /// `.released`: the driver renews no lease. That is all that holds on every path into it: the
    /// helper can still list the lease after a release it did not confirm, and an `apply` sent
    /// before it can still be unanswered (#498's S1 and S2). It says what the app is doing,
    /// nothing about the fans: what they are doing is each row's, from the helper's snapshot, and
    /// the selection's to claim. Never "automatic".
    static let released = StatusLine(
        text: "Aeolus is renewing no lease.",
        detail: "Each fan's row shows what the helper reports.")

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
        case .releaseUnconfirmed(let failure):
            return "The helper did not confirm the release: the request " + Self.failure(failure)
        }
    }

    /// What the control connection did, in the past tense, with the state's own name beside it.
    /// Not `ControlSourceDisplay`'s sentences: those describe the connection now, and a
    /// replacement connection reports `.idle`, which that text calls "not connected yet".
    ///
    /// - **`.idle` names the trigger exactly.** The driver ends a lease on the first health that is
    ///   not `.handshaken` (`LeaseDriver.watch(_:for:)`), and `.idle` is what a torn-down or
    ///   replaced connection reports: the control connection was no longer handshaken.
    /// - **`.handshaken` is unreachable.** That same watch skips every `.handshaken`, so no loss
    ///   carries it. The switch stays exhaustive, with no `default:`, so the arm says only what the
    ///   state was and claims no cause.
    private static func connection(_ health: HelperConnectionHealth) -> String {
        switch health {
        case .idle:
            return "The control connection to the helper was no longer handshaken (idle)."
        case .handshaken:
            return "The control connection reported its state as handshaken (handshaken)."
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
    /// automatic control", which is a snapshot's to show. A refused reason is said first, in the
    /// past tense (`pastTenseSummary`): `userFacingSummary` describes the reason as it stands, and
    /// this line is about an answer already given. The wire code and the reason's wire value
    /// follow as a detail, as a raw key follows a label.
    /// **Exhaustive, with no `default:`**, so a fault added to the vocabulary is a compile error
    /// here until it is rendered.
    private static func fault(_ fault: AeolusXPCFault) -> String {
        switch fault {
        case .manualControlUnavailable(let reason):
            return reason.pastTenseSummary + " (" + fault.wireCode + ": "
                + HelperAuthoredText.sanitised(reason.wireValue) + ")"
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
