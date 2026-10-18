import SMCCore

/// The four things the Apple Silicon write path needs of an SMC connection, and nothing else:
/// the interface generation, a fresh key-info read, a raw read and the raw write.
///
/// [ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s B1 amendment, "the seam is the
/// helper's", as its B1 seam amendment corrected it. A write turn runs a synchronous job on an
/// `isolated` channel; `FirmwareSMC`, a fake that never touches IOKit, is the only conformer a test
/// has, so a write turn can be tested on a machine with no SMC.
///
/// ## `SMCConnection` conforms to nothing here
///
/// The B1 amendment had `SMCConnection` conform through an empty extension, and that was a hole.
/// `write(_:to:)`'s witness is the SPI member `SMCConnection.write(_:to:)`, and a conformance is
/// visible wherever its protocol is. `@testable import AeolusHelper` makes this internal protocol
/// visible to every helper test, so with the conformance any such test could write through a
/// concrete connection, or hand one to any helper function taking an `isolated any
/// SMCWriteChannel`, with no `@_spi(FanWrite)` opt-in at all. Without it, both fail to compile:
/// the conformance is the only thing that made a real connection a channel.
///
/// So this file does not import the SPI, and the daemon's channel is `DaemonWriteChannel`, a
/// `private actor` in `AeolusHelperMain.swift` that forwards these four members to the connection
/// on the connection's own executor. Nothing outside that file can name it.
/// `WriteChannelSeamTests.smcConnectionConformsToNoChannel` checks the absence at runtime, and
/// `WritePathAbsenceTests.noHelperFileOpensSMCConnectionsIsolation` forbids any `extension
/// SMCConnection` in the helper.
///
/// ## Never declared in SMCCore
///
/// A **public** protocol in SMCCore with this requirement, witnessed by the SPI member, would let
/// any module holding an `SMCConnection` name the write through the existential with a plain
/// `import SMCCore` — `fanctl` and the app included — and the SPI gate
/// ([ADR 0008](../../docs/ADR/0008-write-authorisation.md), 2026-09-06) would gate nothing.
/// `WriteChannelSeamTests.noSMCCoreProtocolDeclaresAWrite` holds SMCCore to declaring none.
///
/// ## The shape
///
/// Every requirement is synchronous and the protocol refines `Actor`: a job given an `isolated`
/// channel runs on the channel's executor with nothing suspended, which is the shape the B1
/// amendment rules a write turn takes. The signatures are `SMCConnection`'s own, so the forwarder
/// is four one-line calls.
///
/// ## Nothing calls the write
///
/// This requirement and the forwarder's are the helper's only declarations of the name, the
/// forwarder's body is its only use, and no write turn exists yet —
/// `WritePathAbsenceTests.helperNeverCallsWrite` counts all three.
protocol SMCWriteChannel: Actor {

    /// `SMCConnection.interfaceGeneration`: `nil` until the connection has opened, or when the
    /// firmware's interface could not be told.
    var interfaceGeneration: SMCInterfaceGeneration? { get }

    /// `SMCConnection.freshKeyInfo(for:)`: one `READ_KEYINFO`, whatever the cache holds.
    func freshKeyInfo(for key: SMCKey) throws -> SMCKeyInfo

    /// `SMCConnection.read(_:)`: the key's declared type and current bytes.
    func read(_ key: SMCKey) throws -> SMCValue

    /// `SMCConnection.write(_:to:)`: one `WRITE_BYTES` round trip, and nothing read.
    func write(_ bytes: [UInt8], to key: SMCKey) throws
}
