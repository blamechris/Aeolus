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
/// (`SMCConnection.write(_:to:)`), which force overload resolution and access checking
/// while producing no call. The compound form, rather than the bare name, is deliberate:
/// it pins the exact declaration by its argument labels.
///
/// ## Why nothing here is ever called
///
/// No write path exists in this tree. `write` throws `SMCError.notPermitted` and `encode`
/// throws `SMCError.encodingNotImplemented(type:)`; E3 and E4 implement them behind the
/// safety subsystem, and until then nothing may invoke either. `WritePathAbsenceTests`
/// enforces precisely that: this is the one file under `Sources/AeolusHelper/` permitted
/// to contain the text `.write(`, and it is permitted zero *call sites* of it — a
/// compound-name reference is allowed, an argument list is not.
///
/// Neither probe function is referenced by anything. Both are functions rather than stored
/// `let`s because a stored function value is global mutable state under strict
/// concurrency; a function body holds the same reference with no storage at all.
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
}

extension SMCConnection {

    /// Names `SMCConnection.write(_:to:)` and returns. No call, no I/O.
    ///
    /// This half of the probe is an extension rather than a static function on
    /// `WriteSeamReachability` for one reason: `SMCConnection` is an `actor`, and an
    /// actor-isolated method cannot be *partially applied* from outside its isolation —
    /// the compiler rejects the reference before it ever gets to the access check, which
    /// would make the probe prove nothing. An extension's instance method is isolated to
    /// the actor, so the reference is legal there and the access level is what decides
    /// whether it compiles. It is still never called, from here or anywhere.
    func namesTheWriteSeam() -> Bool {
        let writeSeam: ([UInt8], SMCKey) throws -> Void = self.write(_:to:)
        _ = writeSeam
        return true
    }
}
