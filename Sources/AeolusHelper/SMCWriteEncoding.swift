@_spi(FanWrite) import SMCCore

/// The forward writes' encoder: `SMCKeyType.encode(scalar:byteOrder:)`, the SPI member, named here
/// and nowhere else in the write plane.
///
/// ## Why the encoder has a file of its own
///
/// `encode` is half of the write seam, so it is `@_spi(FanWrite)` like the write itself
/// ([ADR 0008](../../docs/ADR/0008-write-authorisation.md)'s 2026-09-06 amendment), and naming it
/// takes the opt-in. The write turns (`SMCWriteTurns`) need it — an engagement's `1` and a target
/// command's RPM go on the wire through it — but they reach the firmware only through
/// `SMCWriteChannel`'s requirements, which need no opt-in. So the opt-in lives here, in a free
/// `enum` with no connection in scope, and the turn file keeps a plain `import SMCCore`: with no
/// opt-in there, `SMCConnection.write(_:to:)` is a name the turn file **cannot resolve**, which is
/// the compiler holding what a scan would otherwise have to. This file names no write, which
/// `WritePathAbsenceTests.helperNeverCallsWrite` holds with every other helper file.
///
/// The SPI's members stay two (`WriteSeamAccessTests.smcCoreDeclaresExactlyTwoSPIMembers`); its
/// importers under `Sources/` are three: the daemon's forwarder, the reachability probe, and this.
///
/// ## What it decides, and what it does not
///
/// The byte order is resolved as a read resolves it, from the key info the turn just took and the
/// connection's interface generation (ADR 0004). A generation that could not be told is `nil`, and
/// `encode` refuses a `flt` with no order rather than guess one. Whether the value is a **safe**
/// one is not this file's question: the target command refuses one below the fan's floor before it
/// gets here (`SMCWriteTurns.command`), and a restore's zero bytes never come through here at all
/// (ADR 0014's B1 amendment).
enum SMCWriteEncoding {

    /// `scalar` as the bytes `info`'s declared type carries, in the order `generation` and the
    /// key's attributes give. Throws what `encode` throws — `SMCError.notPermitted` for a value the
    /// type cannot carry exactly or a `flt` with no order — before anything is written.
    static func bytes(
        for scalar: Double, declaredBy info: SMCKeyInfo, generation: SMCInterfaceGeneration?
    ) throws -> [UInt8] {
        let order = generation.map {
            resolveByteOrder(generation: $0, attributes: info.attributes, type: info.type)
        }
        return try info.type.encode(scalar: scalar, byteOrder: order)
    }
}
