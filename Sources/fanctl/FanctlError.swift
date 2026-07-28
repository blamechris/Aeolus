import Foundation

/// Errors this CLI's own commands raise. Every case renders a specific, actionable
/// message through `errorDescription` — swift-argument-parser prints exactly that string
/// (prefixed with `Error: `) and exits non-zero, so nobody running `fanctl` at a terminal
/// or in a headless SSH session ever sees a bare `nil`, an `SMCError` case name, or a
/// stack trace.
enum FanctlError: Error, LocalizedError, Equatable {
    /// `SensorProvider.isAvailable` reported `false`: no `AppleSMC` IOService on this
    /// machine at all. Expected on CI's macOS VMs and on any non-Mac host.
    case noSMC

    /// A read that should have succeeded — because `isAvailable` already reported
    /// `true` — failed anyway. `context` names what was being attempted (e.g. "read
    /// FNum", "enumerate sensors"); `reason` is the underlying error's own description,
    /// carried for diagnostics only.
    case connectionFailed(context: String, reason: String)

    /// `FNum` decoded to a value this project does not trust as a real fan count. See
    /// `ListCommand.maxPlausibleFanCount` for why this exists and how the bound was
    /// chosen — the same defence `SMCConnection` applies to `#KEY` itself.
    case implausibleFanCount(Int)

    /// Encoding `--json` output failed. Not expected in practice — every JSON payload
    /// this CLI produces is built from `Codable` structs with no custom encoding — but
    /// reported rather than force-unwrapped if it ever does.
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
        case .implausibleFanCount(let count):
            return """
                FNum decoded to \(count), which is outside the range fanctl trusts as a \
                real fan count. This looks like a decode fault, not actual hardware — \
                refusing to enumerate that many fans.
                """
        case .jsonEncodingFailed(let reason):
            return "Could not encode --json output: \(reason)"
        }
    }
}
