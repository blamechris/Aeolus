import Foundation

/// Whether this test run is on this project's sole verified machine, `Mac16,5` (see
/// `docs/SMC-RESEARCH.md`), read from `hw.model` via `sysctlbyname`.
///
/// `SMCConnection.isHardwareAvailable()` is true of every Mac — every real Mac has an
/// `AppleSMC` IOService, fanless MacBook Air included. A number of hardware-gated test
/// assertions in this target are not facts about "a Mac with an SMC"; they are facts
/// about *this* machine specifically: that fan 0 exists at all, the exact keys behind its
/// three observed read-failure modes, the exact oversized key. Gating those on
/// `isHardwareAvailable()` alone would make them skip correctly on CI (no SMC at all) but
/// genuinely fail on any other real Mac a contributor happens to run the suite on —
/// exactly the "claims support for hardware nobody verified" mistake CLAUDE.md forbids.
/// Combining `isHardwareAvailable()` with this check means a contributor on different
/// hardware gets a skip, never a failure.
///
/// Deliberately not `uname -m`: that reports only the CPU architecture (`arm64` /
/// `x86_64`), never the model identifier, and this project keys behaviour on the SMC's
/// own declared type rather than the architecture string — the same principle applies to
/// identifying which machine this is.
func isDevelopmentMachine() -> Bool {
    modelIdentifier() == "Mac16,5"
}

/// The current machine's model identifier, e.g. `Mac16,5`, read from `hw.model`. `nil`
/// if the sysctl is unavailable for any reason, which `isDevelopmentMachine()` treats the
/// same as "not the development machine" rather than crashing.
private func modelIdentifier() -> String? {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}
