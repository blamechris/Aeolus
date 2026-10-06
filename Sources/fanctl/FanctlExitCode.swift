import AeolusXPC
import AeolusXPCClient
import ArgumentParser
import FanKit
import Foundation

/// The exit codes of every `fanctl` command that talks to the helper through a handshake —
/// `status`, `set` and `auto` — in one place.
///
/// **These numbers are a public contract.** A remote caller (a script, an SSH session, a tool
/// driving `fanctl` on someone's behalf) branches on them without parsing any text, so a
/// number is never reused for a different meaning and never renumbered. A new outcome gets a
/// new number. `docs/CLI.md` carries the same table and `FanctlExitCodeTests` holds the two
/// together.
///
/// 64 is swift-argument-parser's own `EX_USAGE`, listed so the table is complete; nothing here
/// throws it. `reset --all` predates this table and still exits 0 or 1 — see `docs/CLI.md`.
enum FanctlExitCode: Int32, CaseIterable, Sendable {

    /// The command did what it was asked, and what it reports was observed.
    case success = 0

    /// Anything this table does not name: the helper answered with something this build cannot
    /// read, a request whose outcome is unknown because no answer came back, an error this
    /// client did not anticipate. The message says which.
    case failure = 1

    /// The request does not fit this machine: a fan index it does not have, a speed outside
    /// the fan's firmware range, a percentage for a fan whose range could not be read.
    case requestDoesNotFit = 2

    /// The helper could not be reached, or would not be trusted: not installed, not approved,
    /// refused this binary's signature, or answered with a signature this binary refuses.
    case helperNotReachable = 3

    /// The helper refused manual control of a fan it can see. The message carries the reason
    /// and the recovery advice for it — `ManualControlAvailability.Reason`.
    case manualControlRefused = 4

    /// Another client holds the manual-control lease. Only one lease exists at a time.
    case heldByAnotherClient = 5

    /// Control was held and then lost: the lease was not renewed, the helper ended it, the
    /// system reclaimed a fan, or a thermal emergency took over.
    case controlLost = 6

    /// This `fanctl` and the installed helper speak protocol versions neither accepts.
    case protocolVersionMismatch = 7

    /// A request for the safe state — releasing a lease, returning fans to automatic — that
    /// could not be confirmed. The helper's lease expiry still applies; the message says what
    /// to do next.
    case safeStateNotConfirmed = 8

    /// A malformed command line. swift-argument-parser's, never thrown by `fanctl` itself.
    case usage = 64

    var exitCode: ExitCode { ExitCode(rawValue) }

    /// The stable identifier `--json` output carries beside the number.
    var kind: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .requestDoesNotFit: return "requestDoesNotFit"
        case .helperNotReachable: return "helperNotReachable"
        case .manualControlRefused: return "manualControlRefused"
        case .heldByAnotherClient: return "heldByAnotherClient"
        case .controlLost: return "controlLost"
        case .protocolVersionMismatch: return "protocolVersionMismatch"
        case .safeStateNotConfirmed: return "safeStateNotConfirmed"
        case .usage: return "usage"
        }
    }
}

/// Whether the command held a lease when the error arrived.
///
/// The same refusal means two different things either side of that line. `reclaimedBySystem`
/// before a lease is "you cannot have this fan" (4); while holding one it is "you had it and
/// lost it" (6). A table that ignored the phase would report one of the two wrongly.
enum HelperCommandPhase: Sendable {
    case beforeControl
    case holdingControl
}

/// One failure, classified: the exit code a caller branches on and the text a person reads.
struct HelperCommandFailure: Error, Equatable, Sendable {
    typealias Phase = HelperCommandPhase

    let code: FanctlExitCode
    let message: String

    init(_ code: FanctlExitCode, _ message: String) {
        self.code = code
        self.message = message
    }

    /// Classifies anything a `HelperClient` verb can throw.
    ///
    /// Exhaustive over `HelperClientError` and `AeolusXPCFault` — no `default` arm in either
    /// switch — so a case added to either type is a compile error here rather than a silent
    /// exit 1. The message is always the error's own `errorDescription`: the client and the
    /// fault vocabulary already distinguish "unreachable", "never answered" and "answer lost",
    /// and a paraphrase here would be free to drift from what they decided.
    init(classifying error: any Error, during phase: HelperCommandPhase) {
        let message =
            (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        if let failure = error as? HelperCommandFailure {
            self = failure
        } else if let clientError = error as? HelperClientError {
            self.init(Self.code(for: clientError, during: phase), message)
        } else if let fault = error as? AeolusXPCFault {
            self.init(Self.code(for: fault, during: phase), message)
        } else {
            self.init(.failure, message)
        }
    }

    /// Before a lease is held: what kind of "no" this was.
    ///
    /// While one is held the answer is always `controlLost`, whatever the error: a renewal
    /// that was refused, never answered, or lost on the way back leaves this client unable to
    /// say it still holds the fans, and `CLAUDE.md` rule 6 forbids reporting control nothing
    /// has confirmed. The lease then ends by expiry, which restores automatic control.
    static func code(for error: HelperClientError, during phase: Phase) -> FanctlExitCode {
        guard phase == .beforeControl else { return .controlLost }
        switch error {
        case .clientCannotVerifyHelper, .helperUnreachable, .helperSignatureRejected:
            return .helperNotReachable
        case .helperRestarted, .helperNeverAnswered, .replyNotDelivered, .protocolViolation:
            return .failure
        }
    }

    static func code(for fault: AeolusXPCFault, during phase: Phase) -> FanctlExitCode {
        guard phase == .beforeControl else { return .controlLost }
        switch fault {
        case .versionMismatch:
            return .protocolVersionMismatch
        case .manualControlUnavailable(.leaseHeldByAnotherClient):
            return .heldByAnotherClient
        case .manualControlUnavailable, .boundsImplausible, .reclaimedBySystem,
            .thermalEmergencyActive:
            return .manualControlRefused
        case .leaseExpired, .leaseUnknown, .leaseNotHeldByThisConnection:
            // Only reachable with a lease ID in hand, and every one of them says the lease
            // this command was using is not a lease any more.
            return .controlLost
        case .invalidParameter:
            return .requestDoesNotFit
        case .handshakeRequired, .malformedPayload, .helperFailed, .unknown:
            return .failure
        }
    }
}

/// Helper-authored text on its way to a terminal: another client's holder description, a
/// reading's unavailable reason.
///
/// The helper validates holder descriptions on the way in, but this client does not get to
/// assume the process answering is well-behaved, so control and formatting characters are
/// removed before anything reaches a terminal and the length is capped.
enum DisplayText {
    static let maxLength = 200

    static func sanitised(_ text: String) -> String {
        let stripped = String(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(unprintable)" }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }
}
