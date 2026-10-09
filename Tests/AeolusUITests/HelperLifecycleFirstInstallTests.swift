import Foundation
import Testing

@testable import AeolusUI

/// The first install, driven through the same seam `HelperLifecycleControllerTests` uses, in
/// the order the hardware produced it (Mac16,5, macOS 27.0.1, 2026-10-09; #337).
///
/// Its own suite only because the controller's suite outgrew one type body; the two share
/// `FakeHelperDaemonService` and nothing else.
@Suite("HelperLifecycleController — a first install is not broken, and a throw is not a refusal")
@MainActor
struct HelperLifecycleFirstInstallTests {

    private func controller(
        embedding: HelperEmbedding,
        service: FakeHelperDaemonService
    ) -> HelperLifecycleController {
        HelperLifecycleController(service: service, embeddingProbe: { embedding })
    }

    /// What `SMAppService.register()` throws on a first install, with the message macOS
    /// gave: the same instant Background Task Management creates the item awaiting approval.
    private static let firstInstallRegisterError = NSError(
        domain: "SMAppServiceErrorDomain", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])

    /// Everything the footer would put in front of the user for this controller right now:
    /// the status title and detail, and the failure line when there is one.
    private func footer(_ controller: HelperLifecycleController) -> String {
        let display = HelperStatusDisplay.text(for: controller.state)
        return [display.title, display.detail, controller.lastFailure?.message ?? ""]
            .joined(separator: "\n")
    }

    @Test("First install: not found, register() throws code 1 into requiresApproval, then enabled")
    func firstInstallSequenceAsObservedOnHardware() {
        // Mac16,5 / macOS 27.0.1, Developer ID Full Release in /Applications, 2026-10-09.
        let service = FakeHelperDaemonService(status: .notFound)
        service.registerError = Self.firstInstallRegisterError
        service.statusAfterFailedRegister = .requiresApproval
        let controller = controller(embedding: .embedded, service: service)

        // 1. Launch. macOS has no record of the helper, and the way forward is offered.
        #expect(controller.state == .unknownToSystem)
        let beforeInstall = HelperStatusDisplay.text(for: controller.state)
        #expect(beforeInstall.action == .register, "A first install must be able to install")
        #expect(controller.lastFailure == nil)
        #expect(!footer(controller).lowercased().contains("refused"))

        // 2. "Install Helper…". register() throws, and macOS has created the item awaiting
        //    approval: the footer is the approval walkthrough, not a refusal.
        controller.register()
        #expect(service.registerCallCount == 1)
        #expect(controller.state == .awaitingApproval)
        #expect(
            controller.lastFailure == nil,
            "A throw that leaves the item awaiting approval is not macOS refusing to install")
        let waiting = HelperStatusDisplay.text(for: controller.state)
        #expect(waiting.action == .openLoginItemsSettings)
        #expect(waiting.detail.contains("Login Items"))
        #expect(!footer(controller).lowercased().contains("refused"))

        // 3. The user approves in System Settings; the app is told nothing and re-reads on
        //    becoming active. No stale line may survive under "installed and enabled".
        service.nextStatus = .enabled
        controller.refresh()
        #expect(controller.state == .enabled)
        #expect(controller.lastFailure == nil)
        #expect(HelperStatusDisplay.text(for: controller.state).title.contains("enabled"))
        #expect(!footer(controller).lowercased().contains("refused"))
        #expect(!footer(controller).contains("Operation not permitted"))
    }

    @Test("If the status lags the throw, the refusal that showed is retracted when it catches up")
    func refusalShownWhileStatusLagsIsRetractedByTheNextRead() {
        // Not observed on hardware, where the status had already moved by the time the throw
        // was caught; this is the same sequence with the read landing a moment early. The
        // user is told what macOS said at that instant, and the next read corrects it.
        let service = FakeHelperDaemonService(status: .notFound)
        service.registerError = Self.firstInstallRegisterError
        let controller = controller(embedding: .embedded, service: service)

        controller.register()
        #expect(controller.state == .brokenInstall(.systemCannotFindService))
        #expect(controller.lastFailure == .registrationRejected("Operation not permitted"))

        service.nextStatus = .requiresApproval
        controller.refresh()
        #expect(controller.state == .awaitingApproval)
        #expect(controller.lastFailure == nil, "The item now exists, awaiting approval")

        service.nextStatus = .enabled
        controller.refresh()
        #expect(controller.state == .enabled)
        #expect(!footer(controller).contains("Operation not permitted"))
    }

    @Test("A register() that throws while macOS enables the helper is not shown as a refusal")
    func throwIntoEnabledIsNotARefusal() {
        let service = FakeHelperDaemonService(status: .notFound)
        service.registerError = Self.firstInstallRegisterError
        service.statusAfterFailedRegister = .enabled
        let controller = controller(embedding: .embedded, service: service)

        controller.register()

        #expect(controller.state == .enabled)
        #expect(controller.lastFailure == nil)
    }

    @Test("A refusal stays on screen while the system still agrees with it")
    func refusalSurvivesRefreshWhileTheStatusAgrees() {
        let service = FakeHelperDaemonService(status: .notRegistered)
        service.registerError = FakeDaemonServiceError(message: "Operation not permitted")
        let controller = controller(embedding: .embedded, service: service)

        controller.register()
        controller.refresh()
        controller.refresh()

        #expect(controller.state == .notRegistered)
        #expect(
            controller.lastFailure == .registrationRejected("Operation not permitted"),
            "Nothing has changed since macOS said no, so the complaint is still true")
    }

    @Test(
        "A registration failure does not outlive a status that contradicts it",
        arguments: [HelperDaemonStatus.requiresApproval, .enabled])
    func laterStatusRetractsARegistrationFailure(contradicting: HelperDaemonStatus) {
        let service = FakeHelperDaemonService(status: .notRegistered)
        service.registerError = FakeDaemonServiceError(message: "Operation not permitted")
        let controller = controller(embedding: .embedded, service: service)
        controller.register()
        #expect(controller.lastFailure != nil)

        // Approved, or registered some other way, outside this request.
        service.nextStatus = contradicting
        controller.refresh()

        #expect(
            controller.lastFailure == nil,
            "A refusal shown beside a status that says otherwise is a failure that did not happen")
    }

    @Test("A removal failure is not retracted by an enabled status, which is what it describes")
    func removalFailureSurvivesRefreshWhileStillEnabled() {
        let service = FakeHelperDaemonService(status: .enabled)
        service.unregisterError = FakeDaemonServiceError(message: "Service is in use")
        let controller = controller(embedding: .embedded, service: service)

        controller.unregister()
        controller.refresh()

        #expect(controller.state == .enabled)
        #expect(
            controller.lastFailure == .removalRejected("Service is in use"),
            "An unregister that failed while the helper is still enabled is a real failure")
    }

    @Test("Refreshing alone never turns a first launch into a broken install")
    func refreshWithoutRegisteringStaysUnknownToSystem() {
        let service = FakeHelperDaemonService(status: .notFound)
        let controller = controller(embedding: .embedded, service: service)

        controller.refresh()
        controller.refresh()

        #expect(controller.state == .unknownToSystem)
        #expect(service.registerCallCount == 0)
    }

    @Test("Still not found after register() is reported as broken, says why, and can be retried")
    func stillNotFoundAfterRegisteringIsBrokenButRetryable() {
        let service = FakeHelperDaemonService(status: .notFound)
        service.registerError = FakeDaemonServiceError(message: "Operation not permitted")
        let controller = controller(embedding: .embedded, service: service)
        #expect(controller.state == .unknownToSystem)

        controller.register()

        #expect(controller.state == .brokenInstall(.systemCannotFindService))
        #expect(
            controller.lastFailure == .registrationRejected("Operation not permitted"),
            "The status did not move, so the throw is the best account of what macOS returned")
        #expect(HelperStatusDisplay.text(for: controller.state).action == .register)

        // The retry is a real attempt, and a status that has moved is reported as such.
        service.registerError = nil
        service.statusAfterRegister = .requiresApproval
        controller.register()

        #expect(service.registerCallCount == 2)
        #expect(controller.state == .awaitingApproval)
        #expect(controller.lastFailure == nil)
    }

    @Test("Not found after a register() that returned cleanly is also reported as broken")
    func notFoundAfterCleanRegisterIsBroken() {
        let service = FakeHelperDaemonService(status: .notFound)
        let controller = controller(embedding: .embedded, service: service)

        controller.register()

        #expect(service.registerCallCount == 1)
        #expect(controller.state == .brokenInstall(.systemCannotFindService))
        #expect(controller.lastFailure == nil)
        #expect(HelperStatusDisplay.text(for: controller.state).action == .register)

        // The same answer again is not a new answer: macOS has still not given the helper a
        // record, so a read that finds nothing must not make the attempt forgotten.
        controller.refresh()
        #expect(
            controller.state == .brokenInstall(.systemCannotFindService),
            "A further not-found is the same not-found; the attempt still stands")
    }

    @Test(
        "An attempt is forgotten once macOS gives another answer; a later reset is a first install",
        arguments: [HelperDaemonStatus.requiresApproval, .enabled, .notRegistered])
    func attemptIsForgottenOnceTheSystemMovesOn(otherAnswer: HelperDaemonStatus) {
        let service = FakeHelperDaemonService(status: .notFound)
        let controller = controller(embedding: .embedded, service: service)
        controller.register()
        #expect(controller.state == .brokenInstall(.systemCannotFindService))

        service.nextStatus = otherAnswer
        controller.refresh()
        #expect(
            controller.state != .brokenInstall(.systemCannotFindService),
            "macOS answered something other than not-found, so nothing is broken")

        // Background Task Management is reset: macOS knows nothing of the helper again.
        service.nextStatus = .notFound
        controller.refresh()

        #expect(
            controller.state == .unknownToSystem,
            "The old attempt got another answer since; it says nothing about this not-found")
    }
}
