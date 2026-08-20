import Foundation
import SMCCore
import os

/// What the safety subsystem says about its own ability to see.
///
/// Its own category, separate from `LeaseLog`'s, because it answers a different question.
/// `LeaseLog` answers *"why are the fans not where the user left them?"*. This one answers
/// *"was the mechanism that protects them actually watching?"* — and those diverge exactly
/// when it matters, because a degraded supervisor produces no lease events at all.
///
/// ## Why a degraded cycle has to be logged
///
/// `CriticalSensorSet`'s justification for a compiled-in key list is that asking for a key
/// this firmware does not expose is *not* a failure: the seam reports it in
/// `CriticalTemperatureReport.unreadableKeys`, and partial loss is a degraded, logged cycle
/// rather than blindness. That argument is only sound if something logs it. Before this
/// type existed nothing did — `unreadableKeys` had no readers anywhere in `Sources/` — so
/// 33 of 34 curated keys could fall silent and every `acquireLease` would still be granted,
/// with nothing in `log show` and no signal to any client. "Degraded but sighted" would
/// have been indistinguishable from healthy, which is the precise property the seam's own
/// documentation says this subsystem must not have.
struct SafetyLog: Sendable {

    /// How loud a line is.
    ///
    /// Two levels and no more. `degradedCycle`'s own note already argues the distinction
    /// that matters — a fault-level line for a routine partial read would train the reader
    /// to ignore the level that real trouble uses — so the vocabulary is exactly "the
    /// mechanism is working, with something worth knowing" and "the mechanism fired, or
    /// could not".
    enum Level: Sendable, Hashable {
        /// Persisted by default, unlike `.info`, because the whole value of these lines is
        /// being there when somebody goes looking afterwards.
        case notice
        /// § 3 engaged or released, or a write on its path did not land.
        case fault
    }

    private let emit: @Sendable (Level, String) -> Void

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "Safety") {
        let logger = Logger(subsystem: subsystem, category: category)
        emit = { level, message in
            switch level {
            case .notice: logger.notice("\(message, privacy: .public)")
            case .fault: logger.fault("\(message, privacy: .public)")
            }
        }
    }

    /// A sink a test can read back.
    ///
    /// `LeaseLog` has no equivalent and its lines go unasserted, which was tolerable while
    /// the log was commentary. It is not tolerable here: "partial loss is a degraded
    /// **logged** cycle" is the stated justification for compiling a fixed key list into
    /// the helper, and a review found that sentence true of nothing — `unreadableKeys` had
    /// no reader anywhere in `Sources/`. A claim that load-bearing needs a test that fails
    /// when it stops being true, and a test cannot read `os_log`.
    init(recording sink: @escaping @Sendable (String) -> Void) {
        emit = { _, message in sink(message) }
    }

    /// Some curated keys answered and some did not.
    ///
    /// `.notice` rather than `.info`, because `.info` is not persisted by default and the
    /// whole value of this line is being there when somebody goes looking afterwards. Not
    /// `.fault` either: this is a machine still doing its job with fewer sensors, and a
    /// fault-level line for a routine partial read would train the reader to ignore the
    /// level that total blindness uses.
    ///
    /// - Note: the caller is currently `acquireLease`, so this fires at most once per lease
    ///   acquisition. When #125's supervisor polls on a cycle, an unchanged degraded set
    ///   will need collapsing — a per-cycle line at 1 Hz is not a log, it is a denial of
    ///   service against the reader. Said here rather than discovered there.
    /// - Note: every field interpolated below is compiled-in or firmware-derived — key
    ///   names, counts, and a provenance string this module wrote — so marking the whole
    ///   line `.public` discloses nothing a client chose. That is why one interpolated
    ///   string is acceptable here and would not be in `LeaseLog`, which carries
    ///   `holderDescription`.
    func degradedCycle(
        provenance: String, answered: Int, requested: Int, silent: [SMCKey]
    ) {
        emit(
            .notice,
            """
            Critical temperature cycle degraded: \(answered) of \(requested) curated keys \
            answered (\(provenance)). Silent: \(Self.describe(silent)). The thermal \
            override is still watching, on fewer sensors than it was built with.
            """
        )
    }

    /// The degraded set went away: every curated key is answering again.
    ///
    /// The other half of "log the transition, not the state". Without it a reader sees a
    /// machine lose sensors and never sees it get them back, which reads as a fault that
    /// is still current however long ago it cleared.
    func degradationCleared(provenance: String, answered: Int) {
        emit(
            .notice,
            """
            Critical temperature cycle recovered: all \(answered) curated keys are \
            answering again (\(provenance)).
            """
        )
    }

    // MARK: - docs/SAFETY.md § 3

    /// The override fired.
    ///
    /// `.fault`, and this is the line the level exists for: a root daemon has just taken
    /// the fans from a client that did nothing wrong, because the machine was too hot. If
    /// one line from this subsystem is ever read, it is this one.
    func thermalEmergencyEngaged(
        hottest: CriticalTemperature, ceiling: Double, fansHeld: Int
    ) {
        emit(
            .fault,
            """
            Thermal emergency engaged: \(hottest.key.rawValue) read \
            \(Self.celsius(hottest.celsius)) against a \(Self.celsius(ceiling)) ceiling. \
            \(fansHeld) fan(s) under manual control go to maximum and then back to \
            automatic; any lease covering them is revoked and no new lease is granted \
            while this holds.
            """
        )
    }

    /// The override let go: a fresh reading fell a hysteresis margin below the ceiling.
    func thermalEmergencyReleased(hottest: CriticalTemperature, threshold: Double) {
        emit(
            .fault,
            """
            Thermal emergency released: the hottest curated key \
            (\(hottest.key.rawValue)) read \(Self.celsius(hottest.celsius)), at or below \
            the \(Self.celsius(threshold)) release threshold. Leases may be granted again.
            """
        )
    }

    /// The bridge write landed: this fan is at its highest commandable speed, in one step.
    func emergencyCommandedMaximum(fan: Int, rpm: Double) {
        emit(
            .notice,
            """
            Thermal emergency commanded fan \(fan) to \(Int(rpm.rounded())) RPM in a \
            single write, bypassing the ramp governor (docs/SAFETY.md § 8, ADR 0007).
            """
        )
    }

    /// A write on the emergency's path did not land.
    ///
    /// `detail` is helper-authored — a `FanControlPlaneError`'s own description — never
    /// client-chosen text, which is what keeps the whole line safe to mark `.public`. The
    /// same rule the type's header states for `degradedCycle`.
    func emergencyWriteFailed(verb: String, fan: Int, detail: String) {
        emit(
            .fault,
            """
            Thermal emergency could not \(verb) fan \(fan): \(detail). The restore verb \
            is attempted regardless — under-firing is the dangerous direction.
            """
        )
    }

    /// A cycle produced no reading while the latch was engaged.
    ///
    /// The latch is **held**, not released. Stated in the log because "the override is
    /// still on and we cannot currently see why" is exactly the state an operator would
    /// otherwise mistake for a stuck mechanism.
    func thermalEmergencyHeldThroughUnreadableCycle(detail: String) {
        emit(
            .fault,
            """
            Thermal emergency latch held through an unreadable cycle: \(detail). A cycle \
            that cannot read is never a reason to release.
            """
        )
    }

    /// A cycle produced no reading while the latch was clear.
    ///
    /// Persistent read failure is treated as divergence — restore and report — by the
    /// reclamation watchdog in
    /// [#126](https://github.com/blamechris/Aeolus/issues/126), which owns the reconnect
    /// and the escalation. This line is what makes a single blind cycle visible in the
    /// meantime rather than silent.
    func thermalEmergencyCycleUnreadable(detail: String) {
        emit(
            .notice,
            """
            Thermal emergency cycle could not read a critical temperature: \(detail). The \
            latch is clear and stays clear; persistent failure is #126's to escalate.
            """
        )
    }

    /// One decimal place, so a log line does not carry a firmware float's full mantissa.
    private static func celsius(_ value: Double) -> String {
        String(format: "%.1f °C", value)
    }

    /// Caps the key list so one pathological cycle cannot write an unbounded line into a
    /// root daemon's log. The count above is the number that matters; the names are a hint
    /// for whoever is diagnosing it.
    private static func describe(_ keys: [SMCKey]) -> String {
        let names = keys.map(\.rawValue).sorted()
        guard names.count > 8 else { return names.joined(separator: ", ") }
        return names.prefix(8).joined(separator: ", ") + " and \(names.count - 8) more"
    }
}
