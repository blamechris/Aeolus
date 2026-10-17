import Foundation

/// What the engagement driver throws when the undo of a step that may have written was itself
/// refused ([#406](https://github.com/blamechris/Aeolus/issues/406),
/// [ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 refused-hand-back amendment):
/// the fan, and the step's own refusal, exactly what the driver threw before it said so.
///
/// The fan may still be off automatic control, so its caller keeps an account of it: level 6 keeps
/// it as one whose hand-back was refused, and § 5 still holds its own record. **Every router reads
/// the cause** (`cause(of:)`), so a refusal is answered and routed as it was before the wrapper
/// existed. It is thrown for a refused undo and nothing else: an undo that landed throws the bare
/// refusal, and a refusal that wrote nothing is unchanged.
struct EngagementUndoRefused: Error, Sendable {

    /// The fan whose hand-back the firmware refused.
    let fan: Int

    /// What the step threw: an `EngagementRefusal`, a `FanControlPlaneError` or a cancellation.
    let cause: any Error

    /// `error`'s cause when it is this wrapper, and `error` itself otherwise: what every router of
    /// a driver refusal reads.
    static func cause(of error: any Error) -> any Error {
        (error as? Self)?.cause ?? error
    }
}

/// Runs `engagement`, and throws a refused undo's cause in place of the wrapper that carries it.
///
/// § 5's re-assert engages through this, so its one driver catch routes
/// `EngagementUndoRefused.cause(of:)` exactly as it routed the unwrapped error: a cause that
/// yields the fan hands it back, and anything else is a refused re-engage, attempt spent. § 5 needs
/// nothing more from the wrapper, because it keeps its own record of the fan (ADR 0014's #410
/// refused-hand-back amendment). Here, beside the wrapper, so the watchdog's change is one line.
func throwingTheCause(of engagement: @Sendable () async throws -> Void) async throws {
    do {
        try await engagement()
    } catch {
        throw EngagementUndoRefused.cause(of: error)
    }
}
