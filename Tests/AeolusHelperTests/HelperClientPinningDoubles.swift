import AeolusXPC
import FanKit
import Foundation
import Security

@testable import AeolusHelper
@testable import AeolusXPCClient

/// The pinning policies the suite drives the client through.
///
/// **They live in the test target on purpose, and they must stay there.** `Sources/`
/// contains no `HelperConnectionPinning` that skips the requirement, so no production wiring
/// can select one however it is initialised —
/// `HelperClientSeamTests.exactlyOnePinningPolicyShipsInSources` is what keeps that true.
/// What they buy is a client CI can drive with no signing identity, which is the only way
/// the client's own gates get exercised over a real connection.
///
/// What they therefore do *not* prove: that the production requirement admits the real
/// installed helper and refuses everything else. That needs a Developer ID signature and an
/// installed daemon, exists on one machine, and is a manual `Mac16,5` checklist item — see
/// `docs/ADR/0005-xpc-authorisation.md`. A green run of these files must never be read as
/// evidence the boundary holds.

/// Applies no code-signing requirement at all.
///
/// **Declared in the test target on purpose, and it must stay there.** `Sources/` contains
/// no `HelperConnectionPinning` that skips the requirement, so no production wiring can
/// select one however it is initialised —
/// `HelperClientSeamTests.exactlyOnePinningPolicyShipsInSources` is what keeps that true.
/// What this buys is a client CI can drive with no signing identity, which is the only way
/// the client's own gates get exercised over a real connection.
///
/// What it therefore does *not* prove: that the production requirement admits the real
/// installed helper and refuses everything else. That needs a Developer ID signature and an
/// installed daemon, exists on one machine, and is a manual `Mac16,5` checklist item — see
/// `docs/ADR/0005-xpc-authorisation.md`. A green run of this file must never be read as
/// evidence the boundary holds.
struct UnenforcedClientPinning: HelperConnectionPinning {
    func pinnedConnection(over transport: HelperClientTransport) throws -> NSXPCConnection {
        transport.makeConnection()
    }
}

/// Refuses to pin, exactly as an unsigned build's `HelperRequirementPinning` does.
///
/// The refusal a `Monitor` build, a plain `swift build` and `swift test` all produce in
/// production. It is reproduced here rather than reached for, because the real policy
/// answers this only when the process is unsigned — which is true under `swift test` today
/// and would silently stop being the interesting case the day someone runs the suite from a
/// signed host.
struct RefusingClientPinning: HelperConnectionPinning {
    func pinnedConnection(over transport: HelperClientTransport) throws -> NSXPCConnection {
        throw HelperClientError.clientCannotVerifyHelper(.runningProcessHasNoTeamIdentifier)
    }
}

/// Pins a requirement no peer can satisfy, so that libxpc's own refusal is observable.
///
/// The text is compiled with `SecRequirementCreateWithString` before it is handed on, for
/// the reason `PinnedHelperRequirement` records: ADR 0005 measured a malformed requirement
/// raising an uncatchable `NSInvalidArgumentException` inside libxpc — SIGABRT, exit 134 —
/// and a test that aborted the runner would look like a crash rather than a failure.
struct ImpossibleClientPinning: HelperConnectionPinning {
    static let text = "identifier \"com.example.nothing\""

    func pinnedConnection(over transport: HelperClientTransport) throws -> NSXPCConnection {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(Self.text as CFString, [], &compiled)
        guard status == errSecSuccess else {
            throw HelperClientError.protocolViolation(
                detail: "the test requirement did not compile (\(status))")
        }
        let connection = transport.makeConnection()
        connection.setCodeSigningRequirement(Self.text)
        return connection
    }
}

/// Counts the connections a client asked it to build, and applies no requirement.
///
/// "The client dropped the dead connection and built another" is a claim about a *new*
/// object, and from outside the actor one connection object is indistinguishable from its
/// replacement — the listener may never see either, which is the whole case being tested.
/// The count is taken where the connection is actually made.
final class CountingClientPinning: HelperConnectionPinning, @unchecked Sendable {

    private let lock = NSLock()
    private var built = 0

    var connectionsBuilt: Int {
        lock.lock()
        defer { lock.unlock() }
        return built
    }

    func pinnedConnection(over transport: HelperClientTransport) throws -> NSXPCConnection {
        lock.lock()
        built += 1
        lock.unlock()
        return transport.makeConnection()
    }
}
