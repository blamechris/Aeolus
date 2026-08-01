import Foundation
import Testing

@testable import AeolusUI

@Suite("HelperLifecycleController — never install what is not shipped, never claim what is not so")
@MainActor
struct HelperLifecycleControllerTests {

    private func controller(
        embedding: HelperEmbedding,
        service: FakeHelperDaemonService
    ) -> HelperLifecycleController {
        HelperLifecycleController(service: service, embeddingProbe: { embedding })
    }

    // MARK: - The Monitor rule

    @Test("With no helper embedded, the controller starts unavailable and asks nothing")
    func monitorBuildNeverQueriesTheSystem() {
        let service = FakeHelperDaemonService(status: .enabled)
        let controller = controller(embedding: .absent, service: service)

        #expect(controller.state == .unavailableInThisBuild)
        #expect(service.statusQueryCount == 0)
    }

    @Test("register() in a build with no helper refuses locally and never reaches SMAppService")
    func registerRefusedWhenNoHelperIsEmbedded() {
        let service = FakeHelperDaemonService()
        let controller = controller(embedding: .absent, service: service)

        controller.register()

        #expect(service.registerCallCount == 0)
        #expect(service.statusQueryCount == 0)
        #expect(controller.lastFailure == .noHelperInThisBuild)
        #expect(controller.state == .unavailableInThisBuild)
    }

    @Test("unregister() in a build with no helper is refused the same way")
    func unregisterRefusedWhenNoHelperIsEmbedded() {
        let service = FakeHelperDaemonService()
        let controller = controller(embedding: .absent, service: service)

        controller.unregister()

        #expect(service.unregisterCallCount == 0)
        #expect(controller.lastFailure == .noHelperInThisBuild)
        #expect(controller.state == .unavailableInThisBuild)
    }

    @Test("A half-embedded helper is never offered to macOS")
    func damagedInstallIsNotRegistered() {
        let service = FakeHelperDaemonService()
        let controller = controller(embedding: .incomplete(.missingExecutable), service: service)

        controller.register()

        #expect(service.registerCallCount == 0)
        #expect(controller.lastFailure == .installDamaged(.helperExecutableMissing))
        #expect(controller.state == .brokenInstall(.helperExecutableMissing))
    }

    // MARK: - Registration reports the system's answer, not the call's

    @Test("A successful register() that lands in requiresApproval is reported as awaiting approval")
    func successfulRegistrationReportsPendingApproval() {
        let service = FakeHelperDaemonService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let controller = controller(embedding: .embedded, service: service)

        controller.register()

        #expect(service.registerCallCount == 1)
        #expect(
            controller.state == .awaitingApproval,
            "A register() that returns means the request was accepted, not that it is enabled")
        #expect(controller.lastFailure == nil)
    }

    @Test("A register() that macOS enables outright is reported as enabled")
    func registrationThatEnablesImmediatelyIsReportedEnabled() {
        let service = FakeHelperDaemonService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let controller = controller(embedding: .embedded, service: service)

        controller.register()

        #expect(controller.state == .enabled)
        #expect(controller.lastFailure == nil)
    }

    @Test("A rejected register() records why, and still republishes the system's own status")
    func rejectedRegistrationRecordsTheReason() {
        let service = FakeHelperDaemonService(status: .notRegistered)
        service.registerError = FakeDaemonServiceError(message: "Operation not permitted")
        let controller = controller(embedding: .embedded, service: service)

        controller.register()

        #expect(controller.lastFailure == .registrationRejected("Operation not permitted"))
        #expect(
            controller.state == .notRegistered,
            "A failed request shows what macOS reports now, not what was being aimed at")
    }

    @Test("Approval granted outside the app is picked up by refresh()")
    func refreshPicksUpApprovalGrantedInSystemSettings() {
        let service = FakeHelperDaemonService(status: .requiresApproval)
        let controller = controller(embedding: .embedded, service: service)
        #expect(controller.state == .awaitingApproval)

        service.nextStatus = .enabled
        controller.refresh()

        #expect(controller.state == .enabled)
    }

    // MARK: - Removal

    @Test("unregister() on an installed helper removes it and republishes the status")
    func unregisterRemovesAnInstalledHelper() {
        let service = FakeHelperDaemonService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let controller = controller(embedding: .embedded, service: service)

        controller.unregister()

        #expect(service.unregisterCallCount == 1)
        #expect(controller.state == .notRegistered)
        #expect(controller.lastFailure == nil)
    }

    @Test("A rejected unregister() says so and leaves the helper reported as still installed")
    func rejectedUnregisterIsReported() {
        let service = FakeHelperDaemonService(status: .enabled)
        service.unregisterError = FakeDaemonServiceError(message: "Service is in use")
        let controller = controller(embedding: .embedded, service: service)

        controller.unregister()

        #expect(controller.lastFailure == .removalRejected("Service is in use"))
        #expect(controller.state == .enabled)
    }

    // MARK: - Housekeeping

    @Test("A new request clears the previous failure before it can be misread")
    func newRequestClearsThePreviousFailure() {
        let service = FakeHelperDaemonService(status: .notRegistered)
        service.registerError = FakeDaemonServiceError(message: "Operation not permitted")
        let controller = controller(embedding: .embedded, service: service)

        controller.register()
        #expect(controller.lastFailure != nil)

        service.registerError = nil
        service.statusAfterRegister = .requiresApproval
        controller.register()

        #expect(controller.lastFailure == nil)
        #expect(controller.state == .awaitingApproval)
    }

    @Test("Opening Login Items settings is delegated, never simulated in-app")
    func openingLoginItemsSettingsIsDelegated() {
        let service = FakeHelperDaemonService(status: .requiresApproval)
        let controller = controller(embedding: .embedded, service: service)

        controller.openLoginItemsSettings()

        #expect(service.openSettingsCallCount == 1)
    }
}
