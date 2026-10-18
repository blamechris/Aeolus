@_spi(FanWrite) import SMCCore

/// The four things the Apple Silicon write path needs of an SMC connection, and nothing else:
/// the interface generation, a fresh key-info read, a raw read and the raw write.
///
/// [ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s B1 amendment, "the seam is the
/// helper's". It is `SMCConnectionRecycling`'s pattern for the lifecycle verbs, applied to the
/// write path: production conforms through an empty extension below, and a test conforms a fake
/// that never touches IOKit, so a write turn can be tested on a machine with no SMC.
///
/// ## Declared here, and never in SMCCore
///
/// `write(_:to:)` is witnessed by `SMCConnection.write(_:to:)`, which is `@_spi(FanWrite)`. A
/// **public** protocol in SMCCore with this requirement would let any module holding an
/// `SMCConnection` name the write through the existential, with a plain `import SMCCore` — so
/// `fanctl` and the app could write, and the SPI gate would gate nothing (the 2026-09-06
/// amendment to [ADR 0008](../../docs/ADR/0008-write-authorisation.md)). Internal to
/// `AeolusHelper`, the requirement is nameable only inside the helper and, through
/// `@testable import`, its tests.
/// `WriteChannelSeamTests.noSMCCoreProtocolDeclaresAWrite` holds SMCCore to declaring no protocol
/// with a `write` requirement.
///
/// ## The signatures are `SMCConnection`'s, exactly
///
/// So the conformance below declares no member. An empty extension puts no unqualified name in
/// scope: inside a populated `extension SMCConnection`, `self` is the actor and a bare
/// `write(bytes, to: key)` is a live SMC write that a scan for `.write(` cannot see (#226).
/// `WritePathAbsenceTests.noHelperFileOpensSMCConnectionsIsolation` permits this extension
/// because it is empty, and fails on a populated one.
///
/// Every requirement is synchronous, and the protocol refines `Actor`. A job given an `isolated`
/// channel therefore runs on the connection's actor with no suspension inside it, which is the
/// shape the B1 amendment rules a write turn takes.
///
/// ## Why this file imports the SPI
///
/// The witness for `write(_:to:)` must be visible where the conformance is declared, and a plain
/// `import SMCCore` cannot see it. This is the second file under `Sources/AeolusHelper` with the
/// opt-in, beside `WriteSeamReachability.swift`; `WriteSeamAccessTests` allows the opt-in in any
/// helper file and nowhere else.
///
/// ## Nothing calls the write
///
/// The requirement is the one place in the helper that declares the name, and no helper code
/// calls it — `WritePathAbsenceTests.helperNeverCallsWrite` counts that declaration and zero call
/// sites.
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

/// The production conformance. All four members already exist on `SMCConnection`, so this
/// declares none, and must stay empty — see this protocol's documentation.
extension SMCConnection: SMCWriteChannel {}
