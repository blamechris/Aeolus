/// `PollingViewModel`'s own state, distinct from the data it last produced.
///
/// Exists so a view never has to *infer* "did this fail" from the shape of `fans`/
/// `sensors` alone — an empty array is ambiguous between "no fans on this Mac" and
/// "the last poll failed and nothing has ever succeeded" unless something says which.
/// Per `CLAUDE.md` rule 6, a UI must never render an intended value as though it were an
/// observed one; `.failed` is what lets a view say "showing the last known reading from
/// <time>" instead of silently presenting a stale or empty table as current truth.
public enum PollingPhase: Sendable, Hashable {
    /// `start()` has not been called yet, or has not completed its first tick.
    case notStarted
    /// A poll is currently in flight — the first one (which also runs sensor discovery)
    /// or a subsequent refresh.
    case polling
    /// The most recent tick completed successfully. `fans`/`sensors` reflect it.
    case ready
    /// The most recent tick failed. `fans`/`sensors` still hold whatever the last
    /// *successful* tick produced (untouched by the failure), not emptied out — see
    /// `PollingViewModel.tick()`'s documentation for why a transient failure must not
    /// erase good data.
    case failed(PollingError)
}
