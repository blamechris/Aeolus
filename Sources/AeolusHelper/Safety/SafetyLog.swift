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

    private let emit: @Sendable (String) -> Void

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "Safety") {
        let logger = Logger(subsystem: subsystem, category: category)
        emit = { logger.notice("\($0, privacy: .public)") }
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
        emit = sink
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
            """
            Critical temperature cycle degraded: \(answered) of \(requested) curated keys \
            answered (\(provenance)). Silent: \(Self.describe(silent)). The thermal \
            override is still watching, on fewer sensors than it was built with.
            """
        )
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
