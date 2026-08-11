import Foundation

/// Errors this CLI's own commands raise — `list`, `sensors`, `watch`, and `dump` share
/// this one type rather than each defining its own, so the same underlying failure is
/// never described three different ways depending on which command hit it. Every case
/// renders a specific, actionable message through `errorDescription` — swift-argument-
/// parser prints exactly that string (prefixed with `Error: `) and exits non-zero, so
/// nobody running `fanctl` at a terminal or in a headless SSH session ever sees a bare
/// `nil`, an `SMCError` case name, or a stack trace.
///
/// This is deliberately separate from `ValidationError` (swift-argument-parser's own
/// type, still used directly by `Fanctl.Watch.validate()` and `Fanctl.Dump.validate()`
/// for a malformed argument): a usage mistake and a runtime I/O failure are different
/// categories of problem — one is about how the command was invoked, the other about
/// what happened once it ran — and `ValidationError` prints a usage block that would be
/// actively misleading attached to, say, a firmware rejection.
enum FanctlError: Error, LocalizedError, Equatable {
    /// `SensorProvider.isAvailable` reported `false`: no `AppleSMC` IOService on this
    /// machine at all. Expected on CI's macOS VMs and on any non-Mac host.
    case noSMC

    /// A runtime SMC I/O failure with a labelled context. Covers two shapes: `list`/
    /// `sensors` reach this only after `isAvailable` already reported `true` (so this
    /// means a read that should have succeeded failed anyway), while `dump` reaches it
    /// opening a raw `SMCConnection` directly, before availability is known at all —
    /// `context` names what was being attempted either way (e.g. "read FNum",
    /// "enumerate sensors", "open a connection to the SMC"); `reason` is the underlying
    /// error's own description, carried for diagnostics only.
    case connectionFailed(context: String, reason: String)

    /// `FNum` decoded to a value this project does not trust as a real fan count —
    /// non-finite, negative, or outside `ListCommand.maxPlausibleFanCount`. See that
    /// constant for why this exists — the same defence `SMCConnection` applies to
    /// `#KEY` itself. Carries a rendering of the raw decoded value (via
    /// `Formatting.number`, which never traps on the same class of anomaly) rather than
    /// an `Int`: the value that makes this case worth having at all — `NaN`,
    /// `Infinity`, or a magnitude that overflows `Int` outright — is often not
    /// representable as one.
    case implausibleFanCount(String)

    /// Encoding `--json` output failed. This CLI does have custom `Encodable`
    /// conformances (`ListCommand.KeyedValueJSON`, `SensorsCommand.SensorJSON`), and the
    /// case this actually guards against is a non-finite `Double` reaching the encoder:
    /// `JSONEncoder`'s default `nonConformingFloatEncodingStrategy` throws on `NaN`/
    /// `±Inf` rather than encoding them. Every reading this CLI hands to `FanctlJSON` is
    /// sanitised first — see `ListCommand`'s and `SensorsCommand`'s `sanitized`/
    /// `sanitize` helpers — specifically so that throw is never supposed to fire; this
    /// case is what surfaces it, reported rather than silently producing partial JSON,
    /// if that contract is ever violated by a call site that skips sanitisation.
    case jsonEncodingFailed(reason: String)

    /// `fanctl dump --key` named a well-formed, four-character key that simply is not
    /// among the `declaredCount` keys this machine's own index table walk produced — a
    /// fact about the hardware, not a usage mistake (the format itself is validated
    /// separately, before any hardware I/O — see `Fanctl.Dump.validate()`), so this is a
    /// runtime `FanctlError`, not a `ValidationError`.
    case keyNotFound(key: String, declaredCount: Int)

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
        case .jsonEncodingFailed(let reason):
            return "Could not encode --json output: \(reason)"
        case .keyNotFound(let key, let declaredCount):
            return
                "No key '\(key)' found among the \(declaredCount) keys this machine's "
                + "index table exposes."
        }
    }
}
