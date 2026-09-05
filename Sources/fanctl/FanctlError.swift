import Foundation
import SMCCore

/// The one error type every `fanctl` read command (`list`, `sensors`, `watch`, `dump`)
/// throws for a runtime failure — never a bare `throw someLibraryError`, and never a
/// second, differently-shaped type per command. `watch` reuses `ListCommand.fetch`
/// directly, so it already speaks this type without its own cases; `dump` used to throw
/// its own `DumpRuntimeError` with an independently-written message format, which made
/// the same underlying failure (an SMC connection that will not open, a key this
/// machine's table does not contain) read differently depending on which command hit it.
/// Folding it in here means one place decides what "actionable" means for this CLI.
///
/// Every case renders a specific, actionable message through `errorDescription` —
/// swift-argument-parser prints exactly that string (prefixed with `Error: `) and exits
/// with code 1, no usage block, so nobody running `fanctl` at a terminal or in a headless
/// SSH session ever sees a bare `nil`, a raw `SMCError`/`SensorReadFailure` case name, or
/// a stack trace. Conforming to `LocalizedError` (rather than a plain `Error`) is what
/// gets that "no usage block" behaviour: swift-argument-parser reserves the
/// usage-block-plus-exit-64 (`EX_USAGE`) treatment for `ValidationError`, which is
/// deliberately never thrown here — a runtime SMC failure has nothing to do with how the
/// command was invoked, and a usage block below the message would wrongly imply the user
/// typed something wrong. A malformed argument (`dump --key toolong`, a non-positive
/// `watch --interval`) stays a `ValidationError`, thrown at each command's own parse-time
/// `validate()` or argument check — this type is exclusively for failures discovered
/// after parsing succeeded.
enum FanctlError: Error, LocalizedError, Equatable {
    /// `SensorProvider.isAvailable` reported `false`: no `AppleSMC` IOService on this
    /// machine at all. Expected on CI's macOS VMs and on any non-Mac host.
    case noSMC

    /// A read, or the SMC connection/enumeration setup itself, that should have
    /// succeeded failed anyway — because `isAvailable` already reported `true` (`list`,
    /// `sensors`), or because opening a fresh `SMCConnection` or reading `#KEY` failed
    /// outright (`dump`, which has no `isAvailable` gate to check first). `context`
    /// names what was being attempted (e.g. "read FNum", "enumerate sensors", "open a
    /// connection to the SMC"); `reason` is the underlying error's own description,
    /// carried for diagnostics only.
    case connectionFailed(context: String, reason: String)

    /// `FNum` decoded to a value this project does not trust as a real fan count —
    /// non-finite, negative, or outside `SMCFanEnumeration.maxPlausibleFanCount`. See
    /// that constant for why this exists — the same defence `SMCConnection` applies to
    /// `#KEY` itself. Carries a rendering of the raw decoded value (via
    /// `Formatting.number`, which never traps on the same class of anomaly) rather than
    /// an `Int`: the value that makes this case worth having at all — `NaN`,
    /// `Infinity`, or a magnitude that overflows `Int` outright — is often not
    /// representable as one.
    case implausibleFanCount(String)

    /// `fanctl dump --key` named exactly four well-formed ASCII characters — the format
    /// itself is validated before any hardware I/O, as a `ValidationError`, by
    /// `keyFilterFormatError(_:)` — but this machine's own key table simply does not
    /// contain it. A fact about the hardware discovered only after the index walk
    /// completed, not a usage mistake, so this is a runtime error, not a
    /// `ValidationError`. `errorDescription` defers to `keyFilterNotFoundMessage(key:
    /// declaredCount:)` so there is exactly one place that composes this message.
    case keyNotFound(key: String, declaredCount: Int)

    /// Encoding `--json` output failed. This CLI does have custom `Encodable`
    /// conformances (`ListCommand.KeyedValueJSON`, `SensorsCommand.SensorJSON`), and the
    /// case this actually guards against is a non-finite `Double` reaching the encoder:
    /// `JSONEncoder`'s default `nonConformingFloatEncodingStrategy` throws on `NaN`/
    /// `±Inf` rather than encoding them. Every reading this CLI hands to `FanctlJSON` is
    /// sanitised first — by `SMCFanEnumeration.checked(_:in:)` for `list`/`watch`, and by
    /// `SensorsCommand`'s own `sanitize` helper for `sensors` — specifically so that
    /// throw is never supposed to fire; this case is what surfaces it, reported rather
    /// than silently producing partial JSON, if that contract is ever violated by a call
    /// site that skips sanitisation.
    case jsonEncodingFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .noSMC:
            return """
                No SMC found on this machine. fanctl reads fan and sensor data through \
                Apple's SMC service, which every real Mac exposes; this looks like a VM, \
                a non-Mac host, or a machine where AppleSMC could not be reached.
                """
        case .connectionFailed(let context, let reason):
            return "Could not \(context): \(reason)"
        case .implausibleFanCount(let decoded):
            return """
                FNum decoded to \(decoded), which is outside the range fanctl trusts as \
                a real fan count. This looks like a decode fault, not actual hardware — \
                refusing to enumerate that many fans.
                """
        case .keyNotFound(let key, let declaredCount):
            return keyFilterNotFoundMessage(key: key, declaredCount: declaredCount)
        case .jsonEncodingFailed(let reason):
            return "Could not encode --json output: \(reason)"
        }
    }
}

extension FanctlError {
    /// Reclassifies `SMCFanEnumeration`'s enumeration-level failures into this CLI's own
    /// vocabulary, case for case — `ListCommand.fetch(provider:now:)` throws this, never
    /// `SMCFanEnumerationError` directly, so every `fanctl` read command (`list`, and
    /// `watch`, which reuses `fetch`) keeps speaking the one error type this file's own
    /// documentation describes.
    init(_ error: SMCFanEnumerationError) {
        switch error {
        case .noSMC:
            self = .noSMC
        case .readFailed(let context, let reason):
            self = .connectionFailed(context: context, reason: reason)
        case .implausibleFanCount(let declared):
            self = .implausibleFanCount(Formatting.number(declared))
        }
    }
}
