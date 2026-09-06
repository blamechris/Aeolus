import Testing

@testable import AeolusUI

@Suite("LaunchAtLoginController — intent and the system's own answer never get conflated")
@MainActor
struct LaunchAtLoginControllerTests {

    private func controller(
        registrar: FakeLoginItemRegistering,
        preferencesStore: InMemoryPreferencesStore = InMemoryPreferencesStore()
    ) -> (LaunchAtLoginController, PreferencesController) {
        let preferences = PreferencesController(store: preferencesStore)
        let controller = LaunchAtLoginController(registrar: registrar, preferences: preferences)
        return (controller, preferences)
    }

    @Test("At construction, registrationStatus is the registrar's own answer, not a guess")
    func startsWithRegistrarsOwnStatus() {
        let registrar = FakeLoginItemRegistering(status: .requiresApproval)
        let (controller, _) = controller(registrar: registrar)

        #expect(controller.registrationStatus == .requiresApproval)
    }

    @Test("setEnabled(true) persists the intent and asks the registrar to register")
    func enablingPersistsIntentAndRegisters() {
        let registrar = FakeLoginItemRegistering(status: .notRegistered)
        registrar.statusAfterRegister = .enabled
        let (controller, preferences) = controller(registrar: registrar)

        controller.setEnabled(true)

        #expect(registrar.registerCallCount == 1)
        #expect(preferences.preferences.launchAtLogin == true)
        #expect(controller.registrationStatus == .enabled)
    }

    @Test("setEnabled(false) persists the intent and asks the registrar to unregister")
    func disablingPersistsIntentAndUnregisters() {
        let registrar = FakeLoginItemRegistering(status: .enabled)
        registrar.statusAfterUnregister = .notRegistered
        let (controller, preferences) = controller(registrar: registrar)

        controller.setEnabled(false)

        #expect(registrar.unregisterCallCount == 1)
        #expect(preferences.preferences.launchAtLogin == false)
        #expect(controller.registrationStatus == .notRegistered)
    }

    @Test(
        """
        A registrar that always fails (true of every production build today, per \
        SystemLoginItemRegistrar) never lets registrationStatus become .enabled just \
        because the user's intent is "on"
        """
    )
    func failingRegistrarNeverClaimsEnabled() {
        let registrar = FakeLoginItemRegistering(status: .unavailable(reason: "not wired up"))
        registrar.registerError = FakeLoginItemError(message: "not implemented")
        let (controller, preferences) = controller(registrar: registrar)

        controller.setEnabled(true)

        #expect(preferences.preferences.launchAtLogin == true, "The intent is still recorded")
        #expect(controller.lastFailure != nil)
        guard case .unavailable = controller.registrationStatus else {
            Issue.record("Expected .unavailable, got \(controller.registrationStatus)")
            return
        }
    }

    @Test("A new request clears the previous failure before it can be misread")
    func newRequestClearsPreviousFailure() {
        let registrar = FakeLoginItemRegistering(status: .notRegistered)
        registrar.registerError = FakeLoginItemError(message: "boom")
        let (controller, _) = controller(registrar: registrar)

        controller.setEnabled(true)
        #expect(controller.lastFailure != nil)

        registrar.registerError = nil
        registrar.statusAfterRegister = .enabled
        controller.setEnabled(true)

        #expect(controller.lastFailure == nil)
    }

    @Test("refresh() re-reads the registrar without changing the persisted intent")
    func refreshRereadsRegistrarOnly() {
        let registrar = FakeLoginItemRegistering(status: .requiresApproval)
        let (controller, preferences) = controller(registrar: registrar)
        let intentBefore = preferences.preferences.launchAtLogin

        registrar.nextStatus = .enabled
        controller.refresh()

        #expect(controller.registrationStatus == .enabled)
        #expect(preferences.preferences.launchAtLogin == intentBefore)
    }
}
