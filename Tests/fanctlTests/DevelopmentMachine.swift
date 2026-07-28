import Foundation

/// Whether this test run is on this project's sole verified machine, `Mac16,5` — same
/// rationale and implementation as `Tests/SMCCoreTests/DevelopmentMachine.swift`,
/// duplicated here because `fanctlTests` is a separate test target and cannot see that
/// file's `internal` declaration. Keep the two in sync if the check itself ever changes.
func isDevelopmentMachine() -> Bool {
    modelIdentifier() == "Mac16,5"
}

private func modelIdentifier() -> String? {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}
