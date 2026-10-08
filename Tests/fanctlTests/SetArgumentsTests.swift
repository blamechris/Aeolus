import ArgumentParser
import Foundation
import Testing

@testable import fanctl

/// What `fanctl set` accepts on the command line, and what is refused before any connection.
///
/// The rule the grammar follows ([#317](https://github.com/blamechris/Aeolus/issues/317)):
/// **invalid on every machine is a usage error (64); valid but not for this machine is 2**, and
/// 2 is decided later, against the helper's snapshot (`SetPlanTests`). Nothing here connects.
@Suite("fanctl set's arguments")
struct SetArgumentsTests {

    private static func parse(_ arguments: [String]) throws -> Fanctl.Set {
        try #require(Fanctl.parseAsRoot(["set"] + arguments) as? Fanctl.Set)
    }

    /// The exit code `fanctl` would leave with for this command line, or `nil` if it parses.
    private static func refusal(_ arguments: [String]) -> Int32? {
        do {
            _ = try Fanctl.parseAsRoot(["set"] + arguments)
            return nil
        } catch {
            return Fanctl.exitCode(for: error).rawValue
        }
    }

    // MARK: - The speed

    @Test(
        "A percentage is an integer from 0 to 100 and a percent sign",
        arguments: [("0%", 0), ("1%", 1), ("75%", 75), ("100%", 100), ("075%", 75)])
    func percentages(text: String, value: Int) {
        #expect(SetArguments.parseSpeed(text) == .success(.percent(value)))
    }

    @Test(
        "An rpm speed is an integer and the suffix, in any case",
        arguments: [
            ("1350rpm", 1350), ("1350RPM", 1350), ("1350Rpm", 1350), ("1350rPM", 1350),
            ("0rpm", 0), ("007rpm", 7),
        ])
    func rpmSpeeds(text: String, value: Int) {
        #expect(SetArguments.parseSpeed(text) == .success(.rpm(value)))
    }

    /// Every one of these is malformed on every machine. A bare number has no unit, and
    /// guessing one is how `set 0 3000` becomes a percentage nobody meant.
    ///
    /// **Mutation:** accept a bare integer as a percentage in `SetArguments.parseSpeed`. Run:
    /// red on `75`.
    @Test(
        "A bare number, a sign, a decimal, an exponent, a space or a non-number is refused",
        arguments: [
            "75", "", "%", "rpm", "-5%", "+5%", "7.5%", "7,5%", "1e3rpm", "1e3%", "nan%",
            "inf%", "NaN", "infinity", "75 %", " 75%", "75% ", "75%%", "75rpmrpm", "75pm",
            "75 rpm", "٣٠%", "٣٠rpm", "0x10%", "１０%", "75percent", "%75", "rpm75",
        ])
    func malformedSpeeds(text: String) {
        guard case .failure(let error) = SetArguments.parseSpeed(text) else {
            Issue.record("`\(text)` parsed as a speed")
            return
        }
        #expect(!error.message.isEmpty)
    }

    /// 100 is the top of the range; 101 is not a position in it.
    ///
    /// **Mutation:** loosen the bound in `SetArguments.parseSpeed` from `> 100` to `> 1000`.
    /// Run: red on `101%`.
    @Test("A percentage above 100 is refused, however large", arguments: ["101%", "1000%"])
    func percentagesAboveAHundred(text: String) {
        guard case .failure(let error) = SetArguments.parseSpeed(text) else {
            Issue.record("`\(text)` parsed as a speed")
            return
        }
        #expect(error.message.contains("100"))
    }

    /// A number no `Int` holds is not a speed on any machine; it is refused as malformed, not
    /// trapped on.
    @Test("A number too large to represent is refused rather than overflowing")
    func overflow() {
        for text in ["99999999999999999999%", "99999999999999999999rpm"] {
            guard case .failure = SetArguments.parseSpeed(text) else {
                Issue.record("`\(text)` parsed")
                return
            }
        }
    }

    // MARK: - The fan

    @Test("A fan is all, or a non-negative integer")
    func fans() {
        #expect(SetArguments.parseFan("all") == .success(.all))
        #expect(SetArguments.parseFan("0") == .success(.index(0)))
        #expect(SetArguments.parseFan("12") == .success(.index(12)))
        for text in [
            "", "ALL", "All", "-1", "+1", "1.5", "a", "0,1", "fan0", "٣", "99999999999999999999",
        ] {
            guard case .failure = SetArguments.parseFan(text) else {
                Issue.record("`\(text)` parsed as a fan")
                continue
            }
        }
    }

    // MARK: - The duration

    @Test(
        "A duration is an integer and s, m or h, from 10 seconds to 8 hours",
        arguments: [
            ("10s", 10), ("30s", 30), ("90s", 90), ("1m", 60), ("30m", 1_800), ("90m", 5_400),
            ("1h", 3_600), ("2h", 7_200), ("8h", 28_800), ("480m", 28_800), ("28800s", 28_800),
        ])
    func durations(text: String, seconds: Int) {
        #expect(SetArguments.parseDuration(text) == .success(.seconds(seconds)))
    }

    /// 10 s is one heartbeat: below it the hold only churns the mode register. 8 h is the most
    /// a process may hold: beyond it is persistence, which ADR 0007 refuses in v1.
    ///
    /// **Mutation:** widen the lower bound in `SetArguments.parseDuration` to 1 second, or the
    /// upper to 24 hours. Run: red on `9s` or on `8h1s`-sized values (`481m`).
    @Test(
        "A duration below 10 seconds or above 8 hours is refused",
        arguments: ["0s", "1s", "9s", "0m", "0h", "481m", "29h", "28801s", "9h", "100h"])
    func durationBounds(text: String) {
        guard case .failure(let error) = SetArguments.parseDuration(text) else {
            Issue.record("`\(text)` parsed as a duration")
            return
        }
        #expect(error.message.contains("10s"))
        #expect(error.message.contains("8h"))
    }

    @Test(
        "A malformed duration is refused",
        arguments: [
            "", "30", "s", "m", "h", "30d", "30sec", "30 s", " 30s", "-30s", "+30s", "1.5h", "1e1s",
            "30S", "30M", "2H", "٣٠s", "30ms", "1h30m", "PT30S", "99999999999999999999h",
            "9999999999999999h",
        ])
    func malformedDurations(text: String) {
        guard case .failure = SetArguments.parseDuration(text) else {
            Issue.record("`\(text)` parsed as a duration")
            return
        }
    }

    /// A count whose product with the unit overflows `Int` and wraps back into the permitted
    /// range: 5124095576030432 x 3600 is 2^64 + 3584, which wraps to 3584 seconds, and
    /// 307445734561825861 x 60 is 2^64 + 44, which wraps to 44. Refused because the product
    /// overflowed, not because the wrapped number happened to be out of range.
    ///
    /// **Mutation:** delete `!overflow` from the range guard in `SetArguments.parseDuration`.
    /// Run: red on both.
    @Test(
        "A duration whose product wraps into range is still refused",
        arguments: ["5124095576030432h", "307445734561825861m"])
    func wrappingDuration(text: String) {
        guard case .failure = SetArguments.parseDuration(text) else {
            Issue.record("`\(text)` wrapped into a valid duration")
            return
        }
    }

    @Test("A duration is shown the way it is written")
    func describingADuration() {
        #expect(SetArguments.describe(seconds: 10) == "10s")
        #expect(SetArguments.describe(seconds: 90) == "90s")
        #expect(SetArguments.describe(seconds: 1_800) == "30m")
        #expect(SetArguments.describe(seconds: 5_400) == "90m")
        #expect(SetArguments.describe(seconds: 7_200) == "2h")
        #expect(SetArguments.describe(seconds: 28_800) == "8h")
    }

    // MARK: - The command line

    @Test("A well-formed invocation parses, with --json optional")
    func wellFormed() throws {
        let command = try Self.parse(["0", "75%", "--for", "30m"])
        #expect(command.fan == "0")
        #expect(command.speed == "75%")
        #expect(command.holdFor == "30m")
        #expect(!command.json)
        #expect(try Self.parse(["all", "3000rpm", "--for", "2h", "--json"]).json)
        #expect(try Self.parse(["--json", "all", "100%", "--for=10s"]).holdFor == "10s")
    }

    /// `--for` is required on every `set`: a terminal cannot be told from an automated caller
    /// (chroxy, `ssh -t`, tmux and expect all allocate a PTY), and relaxing it later breaks
    /// nobody where tightening it later breaks every integrator.
    ///
    /// **Mutation:** give `Fanctl.Set.holdFor` a default value (`= "30m"`). Run: red.
    @Test("--for is required")
    func forIsRequired() {
        #expect(Self.refusal(["0", "75%"]) == 64)
        #expect(Self.refusal(["all", "75%", "--json"]) == 64)
    }

    @Test("A malformed speed, fan or duration is a usage error before any connection")
    func usageErrors() {
        #expect(Self.refusal(["0", "75", "--for", "30s"]) == 64, "a bare number")
        #expect(Self.refusal(["0", "101%", "--for", "30s"]) == 64, "above 100 percent")
        #expect(Self.refusal(["0", "-5%", "--for", "30s"]) == 64, "a sign")
        #expect(Self.refusal(["0", "75%", "--for", "9s"]) == 64, "below ten seconds")
        #expect(Self.refusal(["0", "75%", "--for", "9h"]) == 64, "above eight hours")
        #expect(Self.refusal(["0", "75%", "--for", "30"]) == 64, "a duration without a unit")
        #expect(Self.refusal(["fan0", "75%", "--for", "30s"]) == 64, "not a fan")
        #expect(Self.refusal(["0", "--for", "30s"]) == 64, "no speed")
        #expect(Self.refusal(["--for", "30s"]) == 64, "no fan and no speed")
        #expect(Self.refusal(["0", "75%", "extra", "--for", "30s"]) == 64, "an extra argument")
        #expect(Self.refusal(["0", "75%", "--for", "30s"]) == nil)
    }

    /// 0 RPM is valid on every machine's command line and fits none: it is an exit 2 against
    /// the snapshot, never a usage error and never clamped to the floor on the client
    /// (`SetPlanTests`). The parser must hand it through unchanged for that to be reachable.
    @Test("0rpm parses: it is refused later, against the fan's range")
    func zeroRPMParses() {
        #expect(Self.refusal(["0", "0rpm", "--for", "30s"]) == nil)
    }

    /// Persistence past the life of the process is ADR 0007's refusal, and the flag does not
    /// exist to be refused: it is absent, so the parser says it is unknown.
    ///
    /// **Mutation:** add `@Flag var persist = false` to `Fanctl.Set`. Run: red here and in the
    /// help assertion below.
    @Test("There is no --persist flag, and nothing like one")
    func noPersist() {
        #expect(Self.refusal(["0", "75%", "--for", "30s", "--persist"]) == 64)
        #expect(Self.refusal(["0", "75%", "--for", "30s", "--persist=true"]) == 64)
        let help = Fanctl.Set.helpMessage(columns: 1_000)
        for word in ["persist", "forever", "indefinite", "--no-for"] {
            #expect(!help.lowercased().contains(word), "`\(word)` appears in set's help")
        }
        #expect(help.contains("--for"))
    }

    @Test("set is registered, with its own help")
    func registered() {
        #expect(Fanctl.configuration.subcommands.contains { $0 == Fanctl.Set.self })
        #expect(Fanctl.helpMessage(columns: 1_000).contains("set"))
        let help = Fanctl.Set.helpMessage(columns: 1_000)
        #expect(help.contains("--json"))
        #expect(help.contains("10s"))
        #expect(help.contains("8h"))
    }
}
