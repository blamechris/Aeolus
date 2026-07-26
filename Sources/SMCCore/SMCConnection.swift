import Foundation
import IOKit

/// A connection to the `AppleSMC` IOService.
///
/// ## Read and write are not peers
///
/// Reading is safe, unprivileged, and available to every client. Writing requires root,
/// can damage hardware, and is therefore reachable only from `AeolusHelper`: the write
/// entry points are `package`-scoped, not `public`. Widening that access is a change to
/// the project's safety posture and needs review under the rules in `docs/SAFETY.md` —
/// it is not a refactor.
///
/// - Note: The IOKit plumbing itself is E1's work. This type currently defines the shape
///   of the API and nothing more; every method throws rather than returning a plausible
///   fabricated value.
public actor SMCConnection {
    private var connection: io_connect_t = 0

    public init() {}

    /// Opens the connection. Idempotent.
    public func open() throws {
        // TODO(E1): IOServiceGetMatchingService("AppleSMC") + IOServiceOpen.
        throw SMCError.connectionFailed(kernReturn: KERN_NOT_SUPPORTED)
    }

    public func close() {
        // TODO(E1): IOServiceClose.
        connection = 0
    }

    // MARK: - Read path (public)

    /// The number of keys this machine exposes, read from `#KEY`.
    public func keyCount() throws -> Int {
        throw SMCError.connectionFailed(kernReturn: KERN_NOT_SUPPORTED)
    }

    /// Returns the key at `index` in the SMC's key table. Used to enumerate every key on
    /// the machine without a hard-coded list.
    public func key(at index: Int) throws -> SMCKey {
        throw SMCError.connectionFailed(kernReturn: KERN_NOT_SUPPORTED)
    }

    /// Reads a key's declared type and current bytes.
    public func read(_ key: SMCKey) throws -> SMCValue {
        throw SMCError.keyNotFound(key)
    }

    // MARK: - Write path (helper-only)

    /// Writes raw bytes to a key.
    ///
    /// - Important: Requires root. Every caller must be inside `AeolusHelper`, and every
    ///   fan-speed write must already have been clamped to the firmware's own
    ///   `[F0Mn, F0Mx]` bounds and rate-limited. See E5.
    package func write(_ bytes: [UInt8], to key: SMCKey) throws {
        throw SMCError.notPermitted
    }
}
