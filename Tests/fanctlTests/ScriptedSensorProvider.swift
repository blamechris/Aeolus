import SMCCore

/// A `SensorProvider` double whose answer changes from one call to the next, scripted one
/// entry per outer `WatchCommand` tick.
///
/// `FakeSensorProvider` holds its fixture data as an immutable `let`, so every tick of a
/// `watch` session sees byte-for-byte identical output — which cannot represent the cases
/// that only ever show up *after* a session has been running: a fetch that succeeds for a
/// while and then fails, a value that changes between refreshes, a NaN that appears mid-
/// stream and should not kill the loop. This type exists specifically to close those gaps
/// for `WatchCommandTests`; `FakeSensorProvider` is untouched and keeps serving `list` and
/// `sensors`, which only ever fetch once per invocation and have no "between ticks" to
/// misrepresent.
///
/// An `actor` rather than a class with `@unchecked Sendable`, for the same reason
/// `FakeWatchClock` is one: `index` is genuinely mutable state advanced across concurrent
/// protocol calls, and an actor is what makes that safe under strict concurrency without
/// asserting anything the compiler cannot check.
actor ScriptedSensorProvider: SensorProvider {
    nonisolated let identifier: String

    /// One outer tick's complete scripted answer — what `isAvailable` reports, and what
    /// `read(keys:)` should hand back for any key requested during that tick.
    struct Tick {
        let isAvailable: Bool
        let keyedResults: [String: Result<SensorReading, SensorReadFailure>]
        let readKeysError: Error?

        /// A normal tick: the provider is available, and `read(keys:)` answers only from
        /// `keyedResults`, reporting `.unknownKey` for anything not stubbed — the same
        /// fallback `FakeSensorProvider.read(keys:)` uses, so an un-stubbed key still
        /// fails loudly rather than silently returning nothing.
        static func success(
            _ keyedResults: [String: Result<SensorReading, SensorReadFailure>]
        ) -> Tick {
            Tick(isAvailable: true, keyedResults: keyedResults, readKeysError: nil)
        }

        /// Models `SensorProvider.isAvailable` reporting `false` on this tick — the
        /// "no SMC" case `ListCommand.fetch` turns into `FanctlError.noSMC` before ever
        /// calling `read(keys:)`.
        static let unavailable = Tick(isAvailable: false, keyedResults: [:], readKeysError: nil)

        /// Models `read(keys:)` itself throwing on this tick — a connection genuinely
        /// available (`isAvailable` still reports `true`) but a specific read failing
        /// outright, the case `ListCommand.fetch` turns into `FanctlError.connectionFailed`
        /// rather than a per-key `SensorReadFailure`. This is what "a fetch that succeeded
        /// for N ticks and then fails" is scripted with: a normal tick followed by one of
        /// these.
        static func readFailure(_ error: Error) -> Tick {
            Tick(isAvailable: true, keyedResults: [:], readKeysError: error)
        }
    }

    private let ticks: [Tick]

    /// Where the *next* `isAvailable` access should read from.
    private var nextIndex = 0

    /// Which tick every `read(keys:)` call answers from right now — frozen by the most
    /// recent `isAvailable` access, not by `nextIndex` itself.
    ///
    /// This split is the whole trick: `ListCommand.fetch` calls `isAvailable` exactly once
    /// at the very start of an outer tick, then `read(keys:)` zero, one, or two more times
    /// within that same tick (none if unavailable, one for a fanless machine's `FNum`-only
    /// read, two once fan keys follow). A single shared cursor advanced by whichever call
    /// happened to run first would make the *second* `read(keys:)` in a tick see the
    /// *next* tick's script entry, silently shifting every value one tick early — exactly
    /// the bug an earlier version of this fake had. `activeIndex` is what `read(keys:)`
    /// consults, and it only ever changes when `isAvailable` is accessed again, i.e. once
    /// per outer tick, regardless of how many `read(keys:)` calls follow it.
    private var activeIndex = 0

    /// - Parameters:
    ///   - identifier: A stable identifier for the provider, shown in diagnostics — see
    ///     `SensorProvider.identifier`. Defaults to a value distinct from
    ///     `FakeSensorProvider`'s own default, so a diagnostic can never be misread as
    ///     coming from the wrong test double.
    ///   - ticks: One entry per outer tick, consumed in order. Once exhausted, the final
    ///     entry repeats for any further tick — so a test scripting "two normal ticks then
    ///     one failure" for a three-tick run needs exactly three entries, never more than
    ///     the ticks it actually asserts on.
    init(identifier: String = "scripted", ticks: [Tick]) {
        precondition(!ticks.isEmpty, "ScriptedSensorProvider needs at least one scripted tick")
        self.identifier = identifier
        self.ticks = ticks
    }

    private var current: Tick { ticks[Swift.min(activeIndex, ticks.count - 1)] }

    var isAvailable: Bool {
        get async {
            activeIndex = nextIndex
            nextIndex += 1
            return current.isAvailable
        }
    }

    /// Not exercised by `WatchCommand` — see the type documentation on `enum WatchCommand` and
    /// `enum ListCommand` for why both use `read(keys:)` exclusively and never `readAll()` — but
    /// answered from the current tick rather than left to trap, in case a future caller reaches it
    /// through the `SensorProvider` existential.
    ///
    /// - Important: **A tick scripted to fail fails here too.** An earlier version returned
    ///   `keyedResults.values.compactMap { try? $0.get() }`, which on a `.readFailure` tick — whose
    ///   `keyedResults` is empty — returned an empty array *successfully*. A future test scripting a
    ///   failure on tick 3 and driving a path that reaches `readAll()` (`SensorsCommand.fetch` is
    ///   exactly such a caller) would have received a successful empty enumeration, so the assertion
    ///   under test would never see the failure and the test would pass while proving nothing. That
    ///   is the "test that cannot reach the failure it claims to cover" shape, planted in a double
    ///   other tests will build on. It now throws whatever the tick scripts, and surfaces a per-key
    ///   error rather than discarding it with `try?`.
    func readAll() async throws -> [SensorReading] {
        let tick = current
        if let readKeysError = tick.readKeysError { throw readKeysError }
        guard tick.isAvailable else { throw SMCError.connectionFailed(kernReturn: 0) }
        // Sorted so the return value is deterministic; dictionary order would make any caller that
        // depends on sequence intermittently flaky.
        return try tick.keyedResults.sorted { $0.key < $1.key }.map { try $0.value.get() }
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        let tick = current
        if let readKeysError = tick.readKeysError {
            throw readKeysError
        }
        return keys.map { key in
            let result = tick.keyedResults[key] ?? .failure(.unknownKey(key))
            return SensorReadOutcome(key: key, result: result)
        }
    }
}
