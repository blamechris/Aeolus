import AeolusXPC
import ArgumentParser

/// `fanctl` — the command-line client.
///
/// Read commands work standalone with no helper installed and no signing, which makes
/// this the tool of choice for headless Mac minis and SSH sessions. Write commands are a
/// thin shell over the same XPC calls the GUI makes; they require the helper, and they
/// take out the same lease.
@main
struct Fanctl: AsyncParsableCommand {
    /// This build's own version — independent of `AeolusXPCVersion.current`. A
    /// Homebrew-installed `fanctl` and a Sparkle-updated `Aeolus.app` routinely sit at
    /// different tool versions while still speaking the same (or a compatible) XPC
    /// protocol version, so the two numbers are never conflated into one string that
    /// hides which one changed.
    static let toolVersion = "0.0.0-dev"

    /// `--version`'s full text — swift-argument-parser prints exactly this string,
    /// verbatim, and nothing else.
    ///
    /// Deliberately phrased as "this build supports", never "negotiated": reading
    /// `AeolusXPCVersion.current` is a compile-time fact baked into this binary, not a
    /// live XPC round trip. `fanctl`'s read commands (`list`/`sensors`/`watch`/`dump`)
    /// connect to nothing, and `--version` itself connects to nothing either — it cannot
    /// know what any installed helper actually accepts. ADR 0005 makes the helper enforce
    /// a real `hello` handshake that negotiates a version at connect time; wording this
    /// string as though it already proved that would let someone reasonably believe
    /// `--version` already confirms this build can talk to whatever helper is installed,
    /// which it does not.
    static var versionDescription: String {
        """
        fanctl \(toolVersion)
        XPC protocol \(AeolusXPCVersion.current) (protocol version this build supports; \
        not a negotiated connection — see docs/ADR/0005-xpc-authorisation.md for the \
        helper's own connect-time handshake)
        """
    }

    static let configuration = CommandConfiguration(
        commandName: "fanctl",
        abstract: "Monitor and control Mac fan speeds.",
        discussion: """
            Read commands (list, sensors, watch, dump) need no privileges and no \
            installed helper. status, set, auto and reset talk to Aeolus.app's privileged \
            helper, which must be registered and approved in System Settings.

            Manual control is always held under a lease: if fanctl exits or is killed, \
            the helper returns the fans to automatic. set holds one for a bounded time, \
            for the life of the process.

            Commands that talk to the helper exit with a stable code a script can branch \
            on: 0 success, 1 unexpected failure, 2 request does not fit this machine, \
            3 helper not reachable, 4 manual control refused, 5 held by another client, \
            6 control lost, 7 protocol version mismatch, 8 safe state not confirmed, \
            9 cannot return to automatic control, 64 usage. The exception is reset --all, \
            which predates this table and still exits 0 when the helper accepted the \
            request and 1 otherwise. See docs/CLI.md.
            """,
        version: versionDescription,
        subcommands: [
            List.self, Sensors.self, Watch.self, Status.self, Set.self, Auto.self, Reset.self,
            Dump.self,
        ]
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

    /// See `ResetCommand.swift` for `run()`, the XPC call, and what this command is and is
    /// not allowed to claim about the result.
    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Return fans to automatic control.",
            discussion: """
                The panic path. It reaches the helper even when the app will not launch, \
                and is safe to run at any time: handing the fans back to Apple's thermal \
                management is always a valid state to ask for.

                It reports whether the helper *accepted* the request. It does not report \
                that a fan is back under automatic control — the helper does not say so, \
                and this command will not say it on the helper's behalf. If the fans are \
                still wrong afterwards, keep going with docs/RECOVERY.md.

                Unlike the read commands, this one needs the helper installed, approved, \
                and willing to accept this binary's signature.
                """
        )

        @Flag(name: .long, help: "Reset every fan and drop all leases.")
        var all = false

        /// Where `run()` looks for the helper. **Not an argument**, and no flag reaches it —
        /// see `HelperConnection`, which is also why it decodes to the
        /// production value whatever swift-argument-parser hands it. The suite sets it
        /// directly, which is what makes `run()` itself the thing under test rather than a
        /// test-only overload of it.
        var helper = HelperConnection.production
    }

    /// See `StatusCommand.swift` for `run()` and what it is and is not allowed to claim.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what the helper reports about every fan and who holds them.",
            discussion: """
                Handshakes with the helper, asks it for one snapshot, and prints it: each \
                fan's actual speed, firmware range, mode, target and whether the system \
                has reclaimed it, whether manual control is available (and if not, why), \
                who holds the manual-control lease, and whether a thermal emergency is \
                active.

                Everything printed is what the helper reported at the capture time shown. \
                A target is what was asked for, never a speed; the speed is the actual \
                reading.

                Needs the helper installed, approved, and willing to accept this binary's \
                signature. --json prints one document with a top-level "schema" version.
                """
        )

        @Flag(name: .long, help: "Emit one JSON document instead of text.")
        var json = false

        /// Where `run()` looks for the helper — see `HelperConnection`. Not an argument.
        var helper = HelperConnection.production

        /// Where `run()` writes — see `Terminal`. Not an argument.
        var terminal = Terminal.process
    }

    /// See `SetCommand.swift` for the sequence, `SetArguments.swift` for the grammar, and
    /// `SetOutput.swift` for `run()`.
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hold one fan, or every fan, at a speed for a bounded time.",
            discussion: """
                Takes the manual-control lease, sets the speed, and renews the lease every 10 \
                seconds for as long as --for says and this process and its parent are alive. \
                Then it releases the lease and checks what the helper reports, the way `auto` \
                does. Ctrl-C (or SIGTERM or SIGHUP) ends it early; so does a closed standard \
                output. If the process is killed outright, the helper ends the lease within \
                30 seconds.

                A speed is N% of the fan's commandable range (0 to 100: 0% is the slowest speed \
                the fan can be commanded to, never zero) or Nrpm. An rpm outside the range the \
                firmware declares for the fan is refused, never clamped, and so is any speed \
                for a fan whose declared range is unusable. `all` holds every fan, each against \
                its own range, and refuses the whole command if any one cannot be held.

                It never retries and never takes the lease back: if the helper reports that \
                control is lost (a renewal refused, the lease no longer listed, a fan reclaimed \
                by the system, a thermal emergency) it releases and exits 6. The speed is a \
                target; the fan's actual speed is what the helper reports.

                --for is required, from 10s to 8h (whole seconds, minutes or hours: 30s, 10m, \
                2h). There is no way to hold longer or without an end.

                Needs the helper installed, approved, and willing to accept this binary's \
                signature. --json prints newline-delimited JSON events (started, holding, then \
                ended or failed), each with a top-level "schema" version.
                """
        )

        @Argument(help: ArgumentHelp("A fan index, or `all`.", valueName: "fan|all"))
        var fan: String

        @Argument(
            help: ArgumentHelp(
                "N% of the fan's commandable range (0 to 100), or Nrpm.", valueName: "N%|Nrpm"))
        var speed: String

        @Option(
            name: .customLong("for"),
            help: ArgumentHelp(
                "How long to hold: whole seconds, minutes or hours (30s, 10m, 2h), from 10s to 8h. "
                    + "Required.",
                valueName: "duration"))
        var holdFor: String

        @Flag(name: .long, help: "Emit newline-delimited JSON events instead of text.")
        var json = false

        /// Where `run()` looks for the helper — see `HelperConnection`. Not an argument.
        var helper = HelperConnection.production

        /// Where `run()` writes — see `Terminal`. Not an argument.
        var terminal = Terminal.process

        /// How the hold tells time and sleeps — see `SettleClock`. Not an argument.
        var clock = SettleClock.production

        /// The parent process and the signals — see `HoldEnvironment`. Not an argument.
        var environment = HoldEnvironment.production
    }

    /// See `AutoCommand.swift` for `run()` and what it is and is not allowed to claim.
    struct Auto: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask the helper to return every fan to automatic control, then check.",
            discussion: """
                Machine-wide: there is no per-fan form, and `auto all` is the same command. \
                Reads one snapshot first; if the helper already reports every fan automatic, \
                with no reason beside any of them, and no lease, it sends nothing and exits \
                0. Otherwise it sends one restore request, never a second, and reads the \
                helper's snapshot once a second for up to 10 seconds until it does. If the \
                first snapshot fails while the handshake is still in force, it sends the \
                request anyway; if it times out or the helper restarts under it, the \
                connection is dropped and nothing is sent: the message says so and names \
                `fanctl reset --all`.

                Never takes a lease. It may end another Aeolus client's lease, and says whose; \
                moving toward automatic control may override another client, moving away from \
                it may not.

                Exit 0 means the helper reports it, not that the fans are: the helper reports \
                a fan whose mode it could not read as automatic too, which is why each fan's \
                reason is read beside its mode. 9 means the helper reports a reason waiting \
                will not change (another program holds the fan, or the firmware refused every \
                handback), whatever mode the fan reads; 5 that a lease is present when the \
                wait ends; 8 that the helper did not confirm within the wait.

                Needs the helper installed, approved, and willing to accept this binary's \
                signature. --json prints one document with a top-level "schema" version.
                """
        )

        @Argument(
            help: ArgumentHelp(
                "Optional, and the only accepted value: every fan, the default.",
                valueName: "all"))
        var target: String?

        @Flag(name: .long, help: "Emit one JSON document instead of text.")
        var json = false

        /// Where `run()` looks for the helper — see `HelperConnection`. Not an argument.
        var helper = HelperConnection.production

        /// Where `run()` writes — see `Terminal`. Not an argument.
        var terminal = Terminal.process

        /// How the wait tells time and sleeps — see `SettleClock`. Not an argument.
        var clock = SettleClock.production
    }
}
