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
        try Self.compile(Self.text)
        let connection = transport.makeConnection()
        connection.setCodeSigningRequirement(Self.text)
        return connection
    }

    /// Compiles `text`, and throws rather than handing an uncompiled string onward.
    static func compile(_ text: String) throws {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &compiled)
        guard status == errSecSuccess else {
            throw HelperClientError.protocolViolation(
                detail: "the test requirement did not compile (\(status))")
        }
    }
}

/// Counts the connections a client asked it to build, under whatever requirement it is given.
///
/// "The client dropped the dead connection and built another" is a claim about a *new*
/// object, and from outside the actor one connection object is indistinguishable from its
/// replacement — the listener may never see either, which is the whole case being tested.
/// The count is taken where the connection is actually made.
///
/// `requirement` defaults to none. Handed `ImpossibleClientPinning.text` it makes every
/// message on the connection fail at libxpc, which is how the drop-and-rebuild path is
/// reached **without** depending on what tearing a listener down does to its clients — a
/// thing that differs between macOS versions, as this project measured the hard way.
final class CountingClientPinning: HelperConnectionPinning, @unchecked Sendable {

    private let requirement: String?
    private let lock = NSLock()
    private var built = 0

    init(requirement: String? = nil) {
        self.requirement = requirement
    }

    var connectionsBuilt: Int {
        lock.lock()
        defer { lock.unlock() }
        return built
    }

    func pinnedConnection(over transport: HelperClientTransport) throws -> NSXPCConnection {
        lock.lock()
        built += 1
        lock.unlock()
        let connection = transport.makeConnection()
        if let requirement {
            try ImpossibleClientPinning.compile(requirement)
            connection.setCodeSigningRequirement(requirement)
        }
        return connection
    }
}
