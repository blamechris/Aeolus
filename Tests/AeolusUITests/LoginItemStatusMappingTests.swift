import ServiceManagement
import Testing

@testable import AeolusUI

/// `SystemLoginItemRegistrar` itself is not driven here: its only collaborator is
/// `SMAppService.mainApp`, whose answer for a test host that is not an app bundle is the
/// environment's, not the code's. What the code owns is the mapping, and that is what a
/// wrong arm would break — the same split `HelperInstallationStateTests` makes for the
/// daemon's mirror.
@Suite("LoginItemStatus mirrors SMAppService.Status")
struct LoginItemStatusMappingTests {

    @Test("Each known system status maps onto its own case, never onto a neighbour")
    func knownStatusesMapOneToOne() {
        #expect(LoginItemStatus(SMAppService.Status.notRegistered) == .notRegistered)
        #expect(LoginItemStatus(SMAppService.Status.enabled) == .enabled)
        #expect(LoginItemStatus(SMAppService.Status.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(SMAppService.Status.notFound) == .notFound)
    }

    @Test("No known system status is reported as .unavailable")
    func knownStatusesAreNeverUnavailable() {
        for status in [
            SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
        ] {
            if case .unavailable(let reason) = LoginItemStatus(status) {
                Issue.record("\(status) mapped to .unavailable: \(reason)")
            }
        }
    }
}
