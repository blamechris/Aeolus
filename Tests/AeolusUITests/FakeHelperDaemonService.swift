import Foundation

@testable import AeolusUI

/// Stands in for `SMAppService` so the lifecycle state machine is testable without
/// installing a root launch daemon on whatever machine runs the suite.
///
/// It also counts status queries, which is how "a `Monitor` build never asks the system
/// about a daemon it does not ship" is asserted rather than assumed.
@MainActor
final class FakeHelperDaemonService: HelperDaemonService {
    /// What `status` reports next. Assign to model an out-of-band change — the user
    /// approving the background item in System Settings, for instance.
    var nextStatus: HelperDaemonStatus

    /// Applied by `register()` on success, modelling the fact that a daemon does not
    /// become `.enabled` just because registration was accepted.
    var statusAfterRegister: HelperDaemonStatus?
    /// Applied by `unregister()` on success.
    var statusAfterUnregister: HelperDaemonStatus?

    var registerError: Error?
    var unregisterError: Error?

    private(set) var statusQueryCount = 0
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(status: HelperDaemonStatus = .notRegistered) {
        nextStatus = status
    }

    var status: HelperDaemonStatus {
        statusQueryCount += 1
        return nextStatus
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        if let statusAfterRegister { nextStatus = statusAfterRegister }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        if let statusAfterUnregister { nextStatus = statusAfterUnregister }
    }

    func openSystemSettingsLoginItems() {
        openSettingsCallCount += 1
    }
}

/// A stand-in for whatever `SMAppService` throws, with a message worth showing.
struct FakeDaemonServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
