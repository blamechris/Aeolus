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
        subcommands: [List.self, Sensors.self, Reset.self]
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
