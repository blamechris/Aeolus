import Testing

@testable import AeolusUI

@Suite("SystemLoginItemRegistrar — a stub must never claim what it never asked for")
@MainActor
struct SystemLoginItemRegistrarTests {

    @Test("status is always .unavailable, never .enabled or any other system-confirmed state")
    func statusIsAlwaysUnavailable() {
        let registrar = SystemLoginItemRegistrar()

        guard case .unavailable = registrar.status else {
            Issue.record("Expected .unavailable, got \(registrar.status)")
            return
        }
    }

    @Test("register() throws rather than silently succeeding")
    func registerThrows() {
        let registrar = SystemLoginItemRegistrar()

        #expect(throws: LoginItemRegistrationError.self) {
            try registrar.register()
        }
    }

    @Test("unregister() throws rather than silently succeeding")
    func unregisterThrows() {
        let registrar = SystemLoginItemRegistrar()

        #expect(throws: LoginItemRegistrationError.self) {
            try registrar.unregister()
        }
    }

    @Test("status never changes as a side effect of a failed register()/unregister() call")
    func statusIsUnaffectedByFailedCalls() {
        let registrar = SystemLoginItemRegistrar()
        let before = registrar.status

        try? registrar.register()
        try? registrar.unregister()

        guard case .unavailable(let beforeReason) = before,
            case .unavailable(let afterReason) = registrar.status
        else {
            Issue.record("Expected .unavailable before and after")
            return
        }
        #expect(beforeReason == afterReason)
    }
}
