import AeolusLeaseControl
import AeolusXPC
import FanKit
import Foundation

/// What one fan's row may draw of per-fan control, and what a click on it asks for (#154, #153's
/// PR 8b): an Auto/Custom segment, and while the fan is in Custom, an RPM field with a stepper.
///
/// Pure, like `FanControlPresentation`: no I/O, no clock and no actor. It is a function of
/// `Inputs`, read from the screen, and of what the user is typing (`FieldState`).
///
/// ## What it is derived from, and nothing else
///
/// - **The fan's `FanControlPresentation`** decides what is selected, whether taking or changing
///   control is enabled, and whether a release is offered. Nothing here judges a snapshot again.
/// - **The licensed snapshot's `FanState` for the fan**: its `controlEnvelope`, the only range a
///   speed is clamped to, and its `actualRPM`, the speed Custom starts at. Never the row's
///   minimum and maximum: those are what the row displays, not what the helper clamps to, and a
///   firmware minimum below `FanSafetyLimits.minimumManualRPM` is shown as declared and never
///   commanded.
/// - **The driver's target for the fan**, from the report on screen
///   (`LeaseDriverState.target(forFan:)`): what the field shows when nobody is typing in it.
///   **Never the snapshot's `targetRPM`**, which is what the helper says it holds, and is the
///   status line's to report (`FanControlPresentation.customLine`).
///
/// ## The segment
///
/// - **Auto** is drawn selected only when the fan's selection is `.automatic`, and enabled only
///   when the fan's `canRelease` is: per-fan Auto gives this fan back, and with nothing to give
///   back there is nothing for it to do. A disabled affordance never withholds it.
/// - **Custom** is drawn selected when the fan's selection is `.custom`, and pending under
///   `.applying` and `.checking`: asked for, never shown as achieved. It is enabled only when the
///   affordance is, the report does not already name the fan in Custom, and a default speed can be
///   named (below).
///
/// ## The RPM field (#154's ruling, Q4)
///
/// - **Shown** while the report names a target for the fan, or while the user is typing in it.
/// - **What it shows:** the draft while the user is typing; otherwise the driver's target, the
///   one queued or in flight before the one confirmed, marked pending while an `apply` of it is
///   unanswered.
/// - **The Custom segment** takes the fan at its default speed: `target(for:)` of the snapshot's
///   `actualRPM`. With no actual reading, or no envelope, nothing is sent.
/// - **Return** sends what was typed, clamped: `adjustFan` when the fan's `canRelease` is true,
///   otherwise `takeFan`, a deliberate request for control.
/// - **The stepper** is always `adjustFan`, which never acquires: a loss stays final under it.
/// - **Commit and revert.** Return and a stepper click commit; losing focus reverts. There is no
///   slider and no debounce clock: the driver's latest-wins is the rate control.
/// - **Clamp** only to `target(for:)` over the licensed snapshot's envelope, from
///   `lowestCommandableRPM` to `highestCommandableRPM`. With no snapshot, or an envelope failure,
///   nothing is sent. Text that is not a finite number reverts. A number outside the range is
///   shown clamped, with a courtesy line saying so. 0 RPM cannot be sent: every speed is a
///   `FanTargetRPM`, and the clamp's floor is never below `minimumManualRPM`.
///
/// Each click is re-read from the screen when it happens (`FanRowControlActions`), and the helper
/// clamps every speed again after it crosses (`CLAUDE.md` rule 7). This is the courtesy, not the
/// control.
///
/// ## What the per-fan control never says
///
/// **No reason of its own.** Why the control is disabled is said by the control for all fans
/// above the list, attributed to the fans it is about (`AllFansControlPresentation`), and a helper
/// refusal is also the row's own line (`FanRowModel.refusal`), which the row showed before it had
/// a control. The per-fan control adds to neither. **No control at all** where the affordance is
/// hidden and no release is offered: the `Monitor` build.
struct FanRowControlPresentation: Equatable {

    /// Whether the row draws any per-fan control.
    let drawsControl: Bool
    let automatic: Segment
    let custom: Segment
    /// `nil` when no field is drawn.
    let field: Field?
    /// Beneath the field: what the last Return clamped, until the field next gains focus or the
    /// stepper is clicked (`FieldState`).
    let courtesy: String?

    /// One segment as drawn.
    struct Segment: Equatable {
        let mark: Mark
        let isEnabled: Bool
    }

    /// How a segment is drawn: as the selection, as asked for and not yet confirmed, or neither.
    enum Mark: Equatable {
        case selected, pending, plain
    }

    /// The RPM field and its stepper.
    struct Field: Equatable {
        let text: String
        /// The driver's target, shown while an `apply` of it is unanswered. Never while the user
        /// is typing: the draft is theirs, not the driver's.
        let isPending: Bool
        /// Whether the field and the stepper may be used: only when the affordance is enabled.
        let isEnabled: Bool
        let canStepUp: Bool
        let canStepDown: Bool
    }

    /// What the row is a function of, read from the screen.
    struct Inputs: Equatable {
        let index: Int
        let presentation: FanControlPresentation
        /// The envelope of the licensed snapshot's `FanState` for this fan. `nil` with no
        /// snapshot, a snapshot that does not report the fan exactly once, or an envelope failure.
        let envelope: FanControlEnvelope?
        /// That `FanState`'s `actualRPM`, when it was measured.
        let actualRPM: Double?
        /// What the report on screen says the driver asks this fan to hold.
        let driverTarget: DriverTarget?
        /// Whether the report on screen names this fan in Custom.
        let isInCustom: Bool
    }

    /// A speed the driver is asking a fan to hold.
    struct DriverTarget: Equatable {
        let speed: FanTargetRPM
        /// An `apply` of it is in flight or queued, and the helper has not answered it.
        let isPending: Bool
    }

    /// What the user is doing in the field: view state, kept by `FanRowView`, which changes it only
    /// through the functions below and `submit(_:_:)`.
    struct FieldState: Equatable {
        /// The text being typed, while the field has focus; `nil` otherwise.
        var draft: String?
        /// The courtesy line from the last Return that clamped. Cleared when the field next gains
        /// focus, and by a stepper click; kept when focus leaves.
        var courtesy: String?

        /// The field gained or lost focus.
        ///
        /// - **Gained:** the edit starts from `shown`, what the field shows when nobody is typing,
        ///   and the last courtesy line goes.
        /// - **Lost:** the draft is dropped, so the field reverts to the driver's target and
        ///   nothing is sent. The courtesy line stays: a Return ends the edit by taking focus away,
        ///   and its line must outlive that.
        func focus(_ gained: Bool, showing shown: String) -> FieldState {
            gained
                ? FieldState(draft: shown, courtesy: nil)
                : FieldState(draft: nil, courtesy: courtesy)
        }

        /// The user typed: the draft is what the field now holds.
        func typed(_ text: String) -> FieldState {
            FieldState(draft: text, courtesy: courtesy)
        }

        /// After a stepper click: the edit ends and the courtesy line goes, so the field shows what
        /// the driver is asked for.
        static let afterStep = FieldState()
    }

    /// What a click asks the root for.
    enum Request: Equatable {
        case takeFan(Int, at: FanTargetRPM)
        case adjustFan(Int, to: FanTargetRPM)
    }

    enum StepDirection: Equatable, CaseIterable {
        case up, down
    }

    /// How far one stepper click moves the speed.
    static let stepRPM: Double = 100

    /// The sentence shown once beside the per-fan control (#154's ruling, Q2). Its wording is the
    /// maintainer's to settle at the live look.
    static let changeOfFanSet =
        "Aeolus holds one lease for every fan in Custom. Changing which fans are in Custom hands "
        + "the lease back, which returns its fans to automatic control, and asks again."

    init(_ inputs: Inputs, field state: FieldState) {
        let presentation = inputs.presentation
        let enabled = presentation.affordance == .enabled
        if case .hidden = presentation.affordance, !presentation.canRelease {
            drawsControl = false
        } else {
            drawsControl = true
        }
        automatic = Segment(
            mark: presentation.selection == .automatic ? .selected : .plain,
            isEnabled: presentation.canRelease)
        custom = Segment(
            mark: Self.customMark(presentation.selection),
            isEnabled: enabled && !inputs.isInCustom && Self.custom(inputs) != nil)
        courtesy = drawsControl ? state.courtesy : nil
        guard drawsControl, inputs.driverTarget != nil || state.draft != nil else {
            field = nil
            return
        }
        field = Field(
            text: state.draft ?? Self.shownText(inputs),
            isPending: state.draft == nil && inputs.driverTarget?.isPending == true,
            isEnabled: enabled,
            canStepUp: Self.step(.up, from: state, inputs) != nil,
            canStepDown: Self.step(.down, from: state, inputs) != nil)
    }

    private static func customMark(_ selection: FanControlPresentation.Selection) -> Mark {
        switch selection {
        case .custom: return .selected
        case .applying, .checking: return .pending
        case .automatic, .unknown: return .plain
        }
    }

    /// What the field shows when nobody is typing in it: the driver's target, or nothing.
    static func shownText(_ inputs: Inputs) -> String {
        inputs.driverTarget.map { ReadingFormatting.number($0.speed.rpm) } ?? ""
    }
}

// MARK: - Reading the screen

extension FanRowControlPresentation.Inputs {

    /// One fan's inputs: its presentation, the snapshot it was judged against, and the driver's
    /// state those presentations were judged beside.
    init(
        reading: FanPollingReading, presentation: FanControlPresentation,
        snapshot: SystemSnapshot?, driver: LeaseDriverState
    ) {
        let reported = snapshot.flatMap { Self.onlyEntry(for: reading.index, in: $0) }
        let envelope: FanControlEnvelope?
        if case .success(let found) = reported?.controlEnvelope {
            envelope = found
        } else {
            envelope = nil
        }
        self.init(
            index: reading.index, presentation: presentation, envelope: envelope,
            actualRPM: reported?.actualRPM.value,
            driverTarget: driver.target(forFan: reading.index),
            isInCustom: driver.fansInCustom?.contains(reading.index) ?? false)
    }

    /// Every fan on screen, from what `FanControlPresentation.onScreen(in:driver:)` returned and
    /// the snapshot and driver state it was read with.
    static func rows(
        _ fans: [AllFansControlPresentation.Fan], snapshot: SystemSnapshot?,
        driver: LeaseDriverState
    ) -> [Self] {
        fans.map {
            Self(
                reading: $0.reading, presentation: $0.presentation, snapshot: snapshot,
                driver: driver)
        }
    }

    /// Fan `index`'s inputs from what `polling` has on screen now, beside `report`, from one
    /// main-actor read, or `nil` when the fan is not on screen.
    @MainActor
    static func onScreen(
        fan index: Int, in polling: PollingViewModel, driver report: LeaseDriverReport
    ) -> Self? {
        let fans = FanControlPresentation.onScreen(in: polling, driver: report)
        guard let fan = fans.first(where: { $0.reading.index == index }) else { return nil }
        return Self(
            reading: fan.reading, presentation: fan.presentation,
            snapshot: polling.renderedSnapshot, driver: report.state)
    }

    /// The snapshot's one entry for fan `index`: `nil` when it reports the fan more than once,
    /// which leaves its bounds ambiguous, or not at all.
    private static func onlyEntry(for index: Int, in snapshot: SystemSnapshot) -> FanState? {
        let entries = snapshot.fans.filter { $0.index == index }
        return entries.count == 1 ? entries.first : nil
    }
}

// MARK: - What a click asks for

extension FanRowControlPresentation {

    /// The Custom segment: the fan at its default speed, `target(for:)` of the snapshot's actual
    /// reading over its envelope. `nil`, so nothing is sent, unless the affordance is enabled and
    /// both are on screen.
    static func custom(_ inputs: Inputs) -> Request? {
        guard inputs.presentation.affordance == .enabled, let envelope = inputs.envelope,
            let actual = inputs.actualRPM
        else { return nil }
        return .takeFan(inputs.index, at: envelope.target(for: actual))
    }

    /// Return in the field: what to send, and what the field holds after it.
    ///
    /// The field's edit ends either way. Text that is not a finite number is dropped and nothing
    /// is sent. A number is clamped and sent, `adjustFan` when the fan's `canRelease` is true and
    /// `takeFan` otherwise; when the clamp moved it, the courtesy line says so. With the affordance
    /// not enabled, or no envelope, nothing is sent and nothing is said.
    static func submit(_ text: String, _ inputs: Inputs) -> (request: Request?, field: FieldState) {
        let reverted = FieldState(draft: nil, courtesy: nil)
        guard inputs.presentation.affordance == .enabled, let envelope = inputs.envelope,
            let entry = Entry(text, in: envelope)
        else { return (nil, reverted) }
        let request: Request =
            inputs.presentation.canRelease
            ? .adjustFan(inputs.index, to: entry.speed) : .takeFan(inputs.index, at: entry.speed)
        return (request, FieldState(draft: nil, courtesy: entry.courtesy(in: envelope)))
    }

    /// A stepper click: always `adjustFan`, from what the field shows, one `stepRPM` up or down,
    /// clamped. `nil`, so nothing is sent, unless the affordance is enabled, the envelope is on
    /// screen, the field shows a number, and the clamp leaves the step a move.
    static func step(
        _ direction: StepDirection, from state: FieldState, _ inputs: Inputs
    ) -> Request? {
        guard inputs.presentation.affordance == .enabled, let envelope = inputs.envelope,
            let base = base(state, inputs, in: envelope)
        else { return nil }
        let delta = direction == .up ? stepRPM : -stepRPM
        let stepped = envelope.target(for: base.rpm + delta)
        guard stepped != base else { return nil }
        return .adjustFan(inputs.index, to: stepped)
    }

    /// What a step starts from: the draft when it is a number, else the driver's target.
    private static func base(
        _ state: FieldState, _ inputs: Inputs, in envelope: FanControlEnvelope
    ) -> FanTargetRPM? {
        if let draft = state.draft, let typed = Entry(draft, in: envelope) { return typed.speed }
        return inputs.driverTarget.map { envelope.target(for: $0.speed.rpm) }
    }

    /// A number typed in the field, rounded to a whole RPM and clamped.
    struct Entry: Equatable {
        /// What was typed, rounded.
        let requested: Double
        let speed: FanTargetRPM

        /// `nil` when `text` is not a finite number.
        init?(_ text: String, in envelope: FanControlEnvelope) {
            guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                value.isFinite
            else { return nil }
            requested = value.rounded()
            speed = envelope.target(for: requested)
        }

        /// The courtesy line when the clamp moved what was typed, or `nil`.
        func courtesy(in envelope: FanControlEnvelope) -> String? {
            guard speed.rpm != requested else { return nil }
            return Self.rpm(requested) + " is outside this fan's commandable range, "
                + Self.rpm(envelope.lowestCommandableRPM) + " to "
                + Self.rpm(envelope.highestCommandableRPM) + ": clamped to "
                + Self.rpm(speed.rpm) + "."
        }

        private static func rpm(_ value: Double) -> String {
            ReadingFormatting.number(value) + " RPM"
        }
    }
}

// MARK: - Per-fan Auto, and how it is recorded (#509, #154's ruling Q5)

extension FanRowControlPresentation {

    /// What per-fan Auto asks the driver for, and how the root records the request.
    enum AutomaticRoute: Equatable {
        /// The report names no fan in Custom but this one: `selectAutomatic()`, recorded as the
        /// user's Auto (`LeaseStateModel.userAskedForAutomatic()`). With this fan the only one in
        /// Custom, that is the release `releaseFan(_:)` would end in. With none, it is what Auto
        /// for all fans does, and changes nothing.
        case selectAutomatic
        /// Other fans are still in Custom, or, while releasing, the report cannot say which are:
        /// `releaseFan(_:)`, recorded as a request for control (`userAskedForControl()`). The
        /// driver takes the other fans again, which is not the user choosing Auto, and where the
        /// report cannot say, the record fails safe: it never claims Auto as the user's choice.
        case releaseFan
    }

    /// Keyed on the fans the report names in Custom (`LeaseDriverState.fansInCustom`), never on
    /// any fan's `canRelease`: that is true for every fan while releasing, whatever the driver
    /// will acquire next, and it is read only for the fans on screen.
    static func automaticRoute(forFan index: Int, in state: LeaseDriverState) -> AutomaticRoute {
        guard let custom = state.fansInCustom else { return .releaseFan }
        return custom.allSatisfy { $0 == index } ? .selectAutomatic : .releaseFan
    }
}
