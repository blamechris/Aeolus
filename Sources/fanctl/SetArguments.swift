import ArgumentParser
import Foundation

/// The grammar of `fanctl set`'s three inputs: which fan, how fast, and for how long.
///
/// Decided on architect review of [#317](https://github.com/blamechris/Aeolus/issues/317), and
/// held to one rule: **invalid on every machine is a usage error (64); valid but not for this
/// machine is exit 2.** Nothing here connects to anything, so nothing here can say whether a
/// speed fits a fan. `SetPlan` does that against the helper's snapshot.
///
/// ## ASCII digits only
///
/// A number is one or more of `0`-`9` and nothing else: no sign, no decimal point, no exponent,
/// no space, no digit from another script. `Int(_:)` would accept `+5`, and `Double(_:)` would
/// accept `nan` and `inf`; neither is allowed to be the way a speed or a duration reaches the
/// helper. The digits are read by hand, with the overflow checked, rather than handed to either.
enum SetArguments {

    /// A malformed input. Every one of these leaves `fanctl` with exit 64.
    struct SyntaxError: Error, Equatable, Sendable {
        let message: String
    }

    enum FanSelection: Equatable, Sendable {
        case all
        case index(Int)
    }

    /// A speed as the person typed it. Neither case is a speed yet: a percentage is a position
    /// in a fan's range and an rpm is a request, and both are judged against that fan's
    /// envelope by `SetPlan`.
    enum Speed: Equatable, Sendable {
        case percent(Int)
        case rpm(Int)
    }

    /// Everything `set` was asked for, once all three inputs parsed.
    struct Request: Equatable, Sendable {
        let selection: FanSelection
        let speed: Speed
        let duration: Duration
    }

    /// The shortest hold. Below one heartbeat the process would only churn the fan's mode
    /// register: it would acquire, write and release without ever having proved it was alive.
    static let shortestHold = 10

    /// The longest hold, in seconds. Beyond eight hours is persistence, which ADR 0007 refuses
    /// in v1; a hold that outlives its terminal is an orphan, and 8 h is the bound on one.
    static let longestHold = 8 * 60 * 60

    // MARK: - The command line

    /// All three inputs, or the first one that is malformed, as swift-argument-parser's own
    /// usage error so it leaves with 64.
    static func request(fan: String, speed: String, holdFor: String) throws -> Request {
        switch (parseFan(fan), parseSpeed(speed), parseDuration(holdFor)) {
        case (.success(let selection), .success(let speed), .success(let duration)):
            return Request(selection: selection, speed: speed, duration: duration)
        case (.failure(let error), _, _), (_, .failure(let error), _), (_, _, .failure(let error)):
            throw ValidationError(error.message)
        }
    }

    // MARK: - The fan

    /// `all`, or a non-negative integer. `ALL` is not `all`: `fanctl auto` takes the one
    /// spelling too, and a second spelling can be added later where removing one cannot.
    static func parseFan(_ text: String) -> Result<FanSelection, SyntaxError> {
        if text == "all" { return .success(.all) }
        guard let index = integer(Array(text.utf8)[...]) else {
            return .failure(
                SyntaxError(
                    message: "`\(text)` is not a fan. Write a fan index such as `0`, or `all`."))
        }
        return .success(.index(index))
    }

    // MARK: - The speed

    /// `<int>%` from 0 to 100, or `<int>rpm` with the suffix in any case.
    ///
    /// A bare number has no unit and is refused: guessing one is how `set 0 3000` turns into a
    /// percentage nobody meant. A number too large for an `Int` is malformed here rather than
    /// trapped on; it is no speed on any machine.
    static func parseSpeed(_ text: String) -> Result<Speed, SyntaxError> {
        let bytes = Array(text.utf8)[...]
        if bytes.last == UInt8(ascii: "%") {
            guard let percent = integer(bytes.dropLast()) else {
                return .failure(malformedSpeed(text))
            }
            guard percent <= 100 else {
                return .failure(
                    SyntaxError(
                        message: "`\(text)` is above 100%. A percentage is a position in the "
                            + "fan's range, from 0% to 100%."))
            }
            return .success(.percent(percent))
        }
        if hasRPMSuffix(bytes), let rpm = integer(bytes.dropLast(3)) {
            return .success(.rpm(rpm))
        }
        return .failure(malformedSpeed(text))
    }

    private static func malformedSpeed(_ text: String) -> SyntaxError {
        SyntaxError(
            message: """
                `\(text)` is not a speed. Write a percentage of the fan's range, `75%` (0 to \
                100), or an exact speed, `4000rpm`. A bare number has no unit, and a sign, a \
                decimal point or a space is not accepted.
                """)
    }

    /// `rpm` in any case, compared as ASCII. `byte | 0x20` lowers an ASCII capital and nothing
    /// else can reach a lowercase letter that way, so this matches `rpm`, `RPM` and the mixed
    /// spellings and no other three bytes. Fewer than three bytes cannot equal `rpm`.
    private static func hasRPMSuffix(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.suffix(3).map { $0 | 0x20 } == Array("rpm".utf8)
    }

    // MARK: - The duration

    /// `<int>s`, `<int>m` or `<int>h`, from `shortestHold` to `longestHold` seconds.
    ///
    /// Lowercase only: an extra spelling can be allowed later without breaking anyone, and
    /// `30M` is a likelier slip for months or megabytes than a request for thirty minutes.
    static func parseDuration(_ text: String) -> Result<Duration, SyntaxError> {
        let bytes = Array(text.utf8)[...]
        let multiplier: Int
        switch bytes.last {
        case UInt8(ascii: "s"): multiplier = 1
        case UInt8(ascii: "m"): multiplier = 60
        case UInt8(ascii: "h"): multiplier = 3_600
        default: return .failure(malformedDuration(text))
        }
        guard let count = integer(bytes.dropLast()) else {
            return .failure(malformedDuration(text))
        }
        let (seconds, overflow) = count.multipliedReportingOverflow(by: multiplier)
        guard !overflow, seconds >= shortestHold, seconds <= longestHold else {
            return .failure(
                SyntaxError(
                    message: "`--for \(text)` is outside the range a hold may last, from "
                        + "\(describe(seconds: shortestHold)) to "
                        + "\(describe(seconds: longestHold)). Below one heartbeat only churns "
                        + "the fan's mode register; beyond that is persistence, which Aeolus "
                        + "does not offer."))
        }
        return .success(.seconds(seconds))
    }

    private static func malformedDuration(_ text: String) -> SyntaxError {
        SyntaxError(
            message: "`--for \(text)` is not a duration. Write whole seconds, minutes or hours: "
                + "`30s`, `10m` or `2h`, from \(describe(seconds: shortestHold)) to "
                + "\(describe(seconds: longestHold)).")
    }

    /// A length of time the way it would be typed after `--for`: the largest unit that divides
    /// it exactly.
    static func describe(seconds: Int) -> String {
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    // MARK: - Digits

    /// A non-empty run of ASCII digits as an `Int`, or `nil` for anything else, including a
    /// number too large to hold.
    private static func integer(_ digits: ArraySlice<UInt8>) -> Int? {
        guard !digits.isEmpty else { return nil }
        var value = 0
        for byte in digits {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, sumOverflow) = shifted.addingReportingOverflow(Int(byte - UInt8(ascii: "0")))
            guard !shiftOverflow, !sumOverflow else { return nil }
            value = sum
        }
        return value
    }
}
