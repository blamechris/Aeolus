import AeolusXPC
import Foundation

/// Where a `HelperClient` looks for the helper.
///
/// Two cases, and the second one exists so the first can be tested. Production is
/// `.machService`: the name the helper registers, with `.privileged`, which is what makes
/// a per-user agent squatting the same name unreachable — see
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md). `.endpoint` is an
/// `NSXPCListenerEndpoint`, which is how the suite drives the real client against a real
/// `NSXPCListener.anonymous()` in process, with no mach registration, no privilege and no
/// signing identity.
///
/// It carries no requirement and cannot apply one. Pinning is
/// `HelperConnectionPinning`'s, and it is the thing that constructs the connection,
/// precisely so that "which endpoint" and "who is allowed to answer" cannot be chosen
/// independently of each other by a caller.
///
/// `@unchecked Sendable`: `NSXPCListenerEndpoint` is an `NSSecureCoding` value type in
/// everything but its Swift annotation — libxpc hands one across processes by design, and
/// this type only ever reads it. Permitted here and forbidden in the helper, where
/// `CLAUDE.md` rule 10 and the repository's own SwiftLint rule both apply.
public enum HelperClientTransport: @unchecked Sendable {

    /// The installed daemon, by the mach name it registers.
    case machService

    /// A listener endpoint. The suite's route to the real helper session in process.
    case endpoint(NSXPCListenerEndpoint)

    /// A connection that has been constructed and nothing else: not configured, not
    /// pinned, not resumed.
    ///
    /// `internal` so that no client of this module can build an unpinned connection with
    /// it. `HelperConnectionPinning` is the only caller.
    func makeConnection() -> NSXPCConnection {
        switch self {
        case .machService:
            // `.privileged` is not an optimisation. Without it the name resolves in the
            // per-user domain, where anything the user runs can register it first.
            return NSXPCConnection(
                machServiceName: AeolusXPCService.machServiceName,
                options: .privileged
            )
        case .endpoint(let endpoint):
            return NSXPCConnection(listenerEndpoint: endpoint)
        }
    }
}
