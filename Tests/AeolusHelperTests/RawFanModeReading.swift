import Foundation
import SMCCore

@testable import AeolusHelper

/// One `F<n>Md` read that keeps the byte the firmware handed back, for the hardware prints
/// whose output is transcribed into `docs/SMC-RESEARCH.md`.
///
/// ## Why this exists ([#208](https://github.com/blamechris/Aeolus/issues/208))
///
/// Those prints used to render `FirmwareFanMode`, which is `value == 0 ? .automatic : .manual`
/// (`FirmwareFanMode(declaredByFirmware:)`), as `0` or `1`. The `1` in that table meant
/// "non-zero", not "the firmware declared `1`" — `2`, `0x80`, or a decode artefact would have
/// produced the same row — and the research document's headline claim, that the key
/// "genuinely takes the value `1`", rested on it. A reader coding the Apple Silicon unlock
/// against that sentence would have been writing a value whose provenance was a fold.
///
/// So this type reads the key through `SMCConnection.read(_:)` — the same public read path
/// the rest of the suite uses, no scheduler turn, nothing in the SPI write group — and
/// reports the declared type and the **bytes**, rendered in hex, before anything decodes them.
/// The decoded mode is printed beside the raw value rather than in place of it: the fold is
/// what production acts on, and a recording that shows both shows where they could differ.
///
/// ## What a raw read does not establish
///
/// It is a second read. The production read (the plane's, or the snapshot's) and this one are
/// two round trips, and a key that moves between them — the competing tool on this machine
/// releases a fan within minutes, `docs/SMC-RESEARCH.md` — can make them disagree. That is
/// reported as a disagreement and never resolved in favour of either: the line says what each
/// read returned.
struct RawFanModeReading: Sendable, Equatable {

    enum Outcome: Sendable, Equatable {
        /// The firmware answered. The value carries the declared type and the bytes untouched.
        case read(SMCValue)
        /// The raw read failed. Recorded as exactly that: this says nothing about what the key
        /// holds, and in particular is never rendered as `0x00`.
        case unreadable(reason: String)
    }

    let fan: Int
    let outcome: Outcome

    /// The key's name as it appears in the recording, always printed beside the value.
    var keyName: String { "F\(fan)Md" }

    // MARK: - Reading

    /// Reads `F<fan>Md` through `connection`, keeping the bytes. Never throws: a recording must
    /// say a read failed rather than abort the row that is trying to record it.
    static func read(fan: Int, through connection: SMCConnection) async -> RawFanModeReading {
        await read(fan: fan) { key in
            // Idempotent, and a no-op once the production read has opened the connection; here
            // so the helper does not depend on being called after one.
            try await connection.open()
            return try await connection.read(key)
        }
    }

    /// The read with its source injected, so the mapping from a thrown error to `.unreadable`
    /// is exercised without an SMC: the hardware rows reach it only when a real read fails,
    /// which is a state a passing run never produces. `readKey` is never called for a fan
    /// whose key cannot be formed.
    static func read(
        fan: Int, using readKey: (SMCKey) async throws -> SMCValue
    ) async -> RawFanModeReading {
        guard let key = SMCKey.fanMode(fan) else {
            return RawFanModeReading(
                fan: fan, outcome: .unreadable(reason: "F\(fan)Md is not a well-formed key"))
        }
        do {
            return RawFanModeReading(fan: fan, outcome: .read(try await readKey(key)))
        } catch {
            return RawFanModeReading(
                fan: fan, outcome: .unreadable(reason: String(describing: error)))
        }
    }

    // MARK: - Rendering

    /// What the two columns of an `entry(...)` are, printed under every recording so a table
    /// transcribed from it cannot be read as a table of bytes in the `decoded` column or of
    /// folds in the `raw` one.
    static let legend =
        "`raw` is the declared type and the bytes of a second read through SMCConnection.read, "
        + "before any decode. `decoded` is the production plane's read, one supervisor turn per "
        + "fan exactly as startup reconciliation reads them, folded by FirmwareFanMode: exactly "
        + "0 is automatic (Apple's thermal management) and any other value is manual. A decoded "
        + "`manual` therefore means non-zero, and only the raw bytes say which value (#208)."

    /// The whole print of the `everyFanModeIsReadableAtStart` row: one entry per line, the
    /// legend, then the row's own note about fans found in manual (empty when there are none).
    static func startupReport(entries: [String], note: String) -> String {
        "startup fan modes on Mac16,5:\n  " + entries.joined(separator: "\n  ") + "\n" + legend
            + note
    }

    /// `ui8 0x00`: the declared type, then every byte, in hex, each byte separately written
    /// and in the order the firmware returned them (`ui16 0x01 0x02`, never `0x0102`, which
    /// would read as one integer in an order this type does not claim). Or
    /// `unreadable (<reason>)`.
    ///
    /// Never a decoded number. A `ui8` of `0x02` renders as `0x02`; the only place the word
    /// "manual" or the digit `1` can come from is the decoded side of `entry(...)`.
    var rawDescription: String {
        switch outcome {
        case .read(let value):
            let type = value.type.fourCharString.trimmingCharacters(in: .whitespaces)
            guard !value.bytes.isEmpty else { return "\(type) (no bytes)" }
            let hex = value.bytes.map { String(format: "0x%02x", $0) }.joined(separator: " ")
            return "\(type) \(hex)"
        case .unreadable(let reason):
            return "unreadable (\(reason))"
        }
    }

    /// What the fold would say about the bytes this read returned, or `nil` when it cannot be
    /// asked: the raw read failed, or the declared type does not decode to a scalar.
    private var foldedAutomatic: Bool? {
        guard case .read(let value) = outcome,
            let scalar = try? value.scalar()
        else { return nil }
        return FirmwareFanMode(declaredByFirmware: scalar) == .automatic
    }

    /// The recording for one fan: the raw value, then the mode the production read decoded.
    ///
    /// - Parameter decodedAutomatic: whether the production read (the plane's, or the
    ///   snapshot's) decoded this fan as automatic. Taken as a `Bool` because the two callers
    ///   hold different mode types. They do not decode identically: the plane's read throws
    ///   on a key it cannot read, while the snapshot's folds an unreadable key into automatic
    ///   as well ([#178](https://github.com/blamechris/Aeolus/issues/178)).
    /// - Returns: One line, with the raw value first and any disagreement or failure flagged
    ///   in brackets after it.
    func entry(decodedAutomatic: Bool) -> String {
        var line =
            "\(keyName) raw \(rawDescription); "
            + "decoded \(decodedAutomatic ? "automatic" : "manual (non-zero)")"
        if let folded = foldedAutomatic, folded != decodedAutomatic {
            line +=
                " [DISAGREE: the raw bytes fold to \(folded ? "automatic" : "manual"); the key "
                + "moved between the two reads, or one of them is wrong]"
        }
        if case .unreadable = outcome, decodedAutomatic {
            // The snapshot path folds an unreadable key into automatic (#178), so on that path
            // a decoded `automatic` is not evidence of a zero byte. This read is the one that
            // could have told the cases apart, and it failed; the line says no byte was seen.
            line +=
                " [raw read failed, so no byte was seen here: the decoded automatic is the "
                + "production read's alone, and on the snapshot path an unreadable key also "
                + "decodes as automatic (#178)]"
        }
        return line
    }
}
