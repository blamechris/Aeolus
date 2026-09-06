@testable import AeolusUI

/// Stands in for `SMAppService.mainApp` so `LaunchAtLoginController` is testable without a
/// real login-item registration touching the test machine's own login items — same
/// purpose `FakeHelperDaemonService` serves for the privileged helper's `SMAppService`
/// surface.
@MainActor
final class FakeLoginItemRegistering: LoginItemRegistering {
    /// What `status` reports next. Assign to model an out-of-band change.
    var nextStatus: LoginItemStatus

    /// Applied by `register()` on success, modelling that a request being accepted is not
    /// the same as it landing in `.enabled` — see `LoginItemStatus`'s own documentation.
    var statusAfterRegister: LoginItemStatus?
    var statusAfterUnregister: LoginItemStatus?

    var registerError: Error?
    var unregisterError: Error?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: LoginItemStatus = .notRegistered) {
        nextStatus = status
    }

    var status: LoginItemStatus { nextStatus }

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
}

/// A stand-in error for whatever a real registrar might throw, with a message worth
/// showing.
struct FakeLoginItemError: Error, Equatable {
    let message: String
}
