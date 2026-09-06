@_spi(FanWrite) import SMCCore

/// Proves, at compile time, that the helper can *name* the SMC write seam — and that
/// nothing else in the tree can.
///
/// ## What it proves
///
/// `SMCConnection.write(_:to:)` and `SMCKeyType.encode(scalar:byteOrder:)` are
/// `@_spi(FanWrite) public` (see the 2026-09-06 amendment in
/// [ADR 0008](../../docs/ADR/0008-write-authorisation.md)). An SPI declaration is public
/// in the binary but unnameable through a plain `import SMCCore`: only a module that opts
/// in with `@_spi(FanWrite) import SMCCore` — this file, and no other under `Sources/` —
/// can resolve either name. That is the compile-time gate `package` used to supply and can
/// no longer, because the Xcode `AeolusHelper` target consumes `SMCCore` as a *package
/// product* and is therefore outside the package `package` visibility is computed against.
///
/// An access level is only proven by a reference the compiler must resolve, so both
/// members are named below — as compound-name function references
/// (`write(_:to:)`, `encode(scalar:byteOrder:)`), which force overload resolution and
/// access checking while producing no call. The compound form, rather than the bare name,
/// is deliberate: it pins the exact declaration by its argument labels.
///
/// ## Why this is an `enum` and not an `extension SMCConnection`
///
/// It was an `extension SMCConnection` until #226's review, and that shape defeated the
/// tripwire that guards it. Inside an extension of the actor, `self` is an `SMCConnection`,
/// so an **unqualified** `write(bytes, to: key)` resolves to the SMC write seam and is a
/// real, compiling call — while `WritePathAbsenceTests` scans for the text `.write(` and
/// cannot see it. A reviewer's mutation inserting exactly that call built clean and left
/// the whole suite green.
///
/// A free `enum` puts no instance of the actor in scope, so `write` is simply not a name
/// this file can resolve on its own — the mutation now fails to compile with
/// `cannot find 'write' in scope`. `WritePathAbsenceTests.noHelperFileOpensSMCConnectionsIsolation`
/// holds the shape closed for the rest of the target.
///
/// The write half takes an `isolated SMCConnection` parameter rather than referencing
/// `SMCConnection.write(_:to:)` as an unbound function value, because Swift will not form
/// that value: `write` is actor-isolated, and the reference from a `nonisolated` context is
/// rejected as `call to actor-isolated instance method 'write(_:to:)' in a synchronous
/// nonisolated context` (`#ActorIsolatedCall`) — with or without an explicit
/// `@Sendable (isolated SMCConnection) -> …` annotation. An `isolated` parameter puts the
/// *body* inside the actor's isolation, which is what the access check needs, without
/// putting the actor's members in unqualified scope, which is what defeated the tripwire.
///
/// ## Why nothing here is ever called
///
/// No write path exists in this tree. `write` throws `SMCError.notPermitted` and `encode`
/// throws `SMCError.encodingNotImplemented(type:)`; E3 and E4 implement them behind the
/// safety subsystem, and until then nothing may invoke either. `WritePathAbsenceTests`
/// enforces precisely that: this is the one file under `Sources/AeolusHelper/` permitted
/// to contain the text `write(`, and it is permitted zero *call sites* of it — a
/// compound-name reference is allowed, an argument list is not.
///
/// That rule is about the name `write`, and #226's delta review showed it is not enough on
/// its own: the seam is bound to a *local* here, so `try! writeSeam(bytes, key)` is a live
/// write under a name the scan does not know. `theWriteSeamProbeIsInert` closes that door
/// by forbidding, in this file, any `try`, any `await`, and any application of a local this
/// file binds — whatever it is named.
///
/// Neither probe function is referenced by anything, and
/// `nothingOutsideTheProbeNamesIt` keeps it so: an unreferenced probe cannot become a
/// write path however it is edited, which is what bounds the blast radius of everything
/// above. Both are functions rather than stored `let`s because a stored function value is
/// global mutable state under strict concurrency; a function body holds the same reference
/// with no storage at all.
///
/// ## Why the Monitor app build is the proof
///
/// `swift build` compiles the helper *inside* the SwiftPM package, where `package` would
/// have worked too — so `swift build` cannot tell the two access levels apart and cannot
/// see the defect this file exists to catch. The `Monitor app build` CI job runs
/// `xcodebuild` over the Xcode `AeolusHelper` target: the build that produces a signed
/// helper, and the only one where the package boundary is real. If the SPI gate ever stops
/// resolving there, that job fails on this file.
enum WriteSeamReachability {

    /// Names `SMCKeyType.encode(scalar:byteOrder:)` and returns. No call, no I/O.
    ///
    /// The local is typed explicitly so the declaration this file pins is the one the
    /// compiler resolved, rather than whatever a future overload makes cheapest.
    static func namesTheEncodeSeam() -> Bool {
        let encodeSeam: (SMCKeyType) -> (Double, SMCByteOrder?) throws -> [UInt8] =
            SMCKeyType.encode(scalar:byteOrder:)
        _ = encodeSeam
        return true
    }

    /// Names `SMCConnection.write(_:to:)` and returns. No call, no I/O.
    ///
    /// The parameter is `isolated` for the reason given above: the body must sit inside the
    /// actor's isolation for the reference to be legal, and a free function with an
    /// `isolated` parameter is the way to get that without an `extension SMCConnection`.
    /// The local is typed explicitly for the same reason the encode probe's is.
    static func namesTheWriteSeam(on connection: isolated SMCConnection) -> Bool {
        let writeSeam: ([UInt8], SMCKey) throws -> Void = connection.write(_:to:)
        _ = writeSeam
        return true
    }
}
