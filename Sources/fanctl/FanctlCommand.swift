import ArgumentParser

/// `fanctl` — the command-line client.
///
/// Read commands work standalone with no helper installed and no signing, which makes
/// this the tool of choice for headless Mac minis and SSH sessions. Write commands are a
/// thin shell over the same XPC calls the GUI makes; they require the helper, and they
/// take out the same lease.
@main
struct Fanctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fanctl",
        abstract: "Monitor and control Mac fan speeds.",
        discussion: """
            Read commands (list, sensors, watch) need no privileges and no installed \
            helper. Control commands require Aeolus.app's privileged helper to be \
            registered and approved in System Settings.

            Manual control is always held under a lease: if fanctl exits or is killed, \
            the helper returns the fans to automatic.
            """,
        version: "0.0.0-dev",
        subcommands: [List.self, Sensors.self, Watch.self, Reset.self, Dump.self]
    )
}

extension Fanctl {
    /// See `ListCommand.swift` for `run()` and the read/render logic.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List fans with their current, minimum, and maximum speeds."
        )

        @Flag(name: .long, help: "Emit JSON instead of a table.")
        var json = false
    }

    /// See `SensorsCommand.swift` for `run()` and the read/render logic.
    struct Sensors: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List every sensor this machine exposes."
        )

        @Flag(name: .long, help: "Emit JSON instead of a table.")
        var json = false

        @Flag(name: .long, help: "Show raw SMC keys only, without catalog labels.")
        var rawKeys = false
    }

    /// See `WatchCommand.swift` for `run()` and the refresh-loop logic.
    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Live-updating view of fan speeds, suitable for a terminal left open.",
            discussion: """
                Refreshes on --interval using the same targeted per-fan reads `list` \
                uses — never a full SMC enumeration — so every tick stays cheap no \
                matter how long this has been running. Exits cleanly on Ctrl-C.

                --json emits newline-delimited JSON (NDJSON): one compact object per \
                line, in the same field shape as `list --json`, rather than repeating \
                `list`'s pretty-printed document forever. A redirected or piped run \
                never receives the redrawing table's ANSI escapes either way — the \
                table falls back to a plain, timestamped block per tick instead.
                """
        )

        @Flag(
            name: .long,
            help: "Emit newline-delimited JSON (one object per line) instead of a redrawing table."
        )
        var json = false

        @Option(name: .long, help: "Seconds between refreshes.")
        var interval: Double = 1.0

        @Option(
            name: .long,
            help: "Stop after this many refreshes. Runs until Ctrl-C if omitted.")
        var count: Int?

        /// A day, in seconds. Generous for a genuine "check back tomorrow" use, and far
        /// below where `SystemWatchClock.sleep(seconds:)` would need its own fallback: an
        /// interval anywhere near `UInt64.max` nanoseconds (~1.8446744e10 seconds) is never
        /// an intentional value, only a mistyped argument, and this rejects it here with an
        /// actionable message rather than letting it reach a `Double`-to-`UInt64` runtime
        /// precondition failure.
        private static let maxIntervalSeconds: Double = 86_400

        func validate() throws {
            guard interval.isFinite, interval > 0 else {
                throw ValidationError(
                    "--interval must be a positive, finite number of seconds; got \(interval)."
                )
            }
            guard interval <= Self.maxIntervalSeconds else {
                throw ValidationError(
                    "--interval must be at most \(Self.maxIntervalSeconds) seconds (a day); "
                        + "got \(interval)."
                )
            }
            if let count, count <= 0 {
                throw ValidationError("--count must be a positive integer; got \(count).")
            }
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Return fans to automatic control.",
            discussion: """
                The panic path. Works even when the app will not launch, and is safe to \
                run at any time: handing the fans back to Apple's thermal management is \
                always a valid state.
                """
        )

        @Flag(name: .long, help: "Reset every fan and drop all leases.")
        var all = false

        func run() async throws {
            // TODO(E10b): call restoreAllToAutomatic over XPC.
            throw CleanExit.message("Not implemented yet — see epic E10b.")
        }
    }
}
