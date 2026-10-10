import Foundation
import ServiceManagement
import Testing

@testable import AeolusUI

@Suite("HelperInstallationState — the four SMAppService statuses, and the fifth we invented")
struct HelperInstallationStateTests {

    @Test("Every SMAppService.Status this SDK declares maps to its own mirror case")
    func systemStatusesMapOneToOne() {
        #expect(HelperDaemonStatus(SMAppService.Status.notRegistered) == .notRegistered)
        #expect(HelperDaemonStatus(SMAppService.Status.enabled) == .enabled)
        #expect(HelperDaemonStatus(SMAppService.Status.requiresApproval) == .requiresApproval)
        #expect(HelperDaemonStatus(SMAppService.Status.notFound) == .notFound)
    }

    @Test("A build with no helper is unavailable, and is never asked about its status")
    func absentEmbeddingNeverQueriesTheSystem() {
        var queried = false
        let state = HelperInstallationState.resolve(
            embedding: .absent,
            status: {
                queried = true
                return .notRegistered
            }(),
            registrationAttempted: false)

        #expect(state == .unavailableInThisBuild)
        #expect(
            queried == false,
            "A Monitor build must not ask SMAppService about a daemon it does not ship")
    }

    @Test("A half-embedded helper is a broken install, and is not asked about either")
    func incompleteEmbeddingIsBrokenWithoutQuerying() {
        var queried = false
        let missingExecutable = HelperInstallationState.resolve(
            embedding: .incomplete(.missingExecutable),
            status: {
                queried = true
                return .enabled
            }(),
            registrationAttempted: false)
        let missingPlist = HelperInstallationState.resolve(
            embedding: .incomplete(.missingDaemonPlist),
            status: {
                queried = true
                return .enabled
            }(),
            registrationAttempted: false)

        #expect(missingExecutable == .brokenInstall(.helperExecutableMissing))
        #expect(missingPlist == .brokenInstall(.daemonPlistMissing))
        #expect(queried == false)
    }

    @Test("A half-embedded helper stays broken whatever the attempt flag says")
    func incompleteEmbeddingIgnoresTheAttemptFlag() {
        // A missing file is a fact about the bundle; no registration attempt can change it,
        // and `.notFound` here must never be read as the first-install case.
        #expect(
            HelperInstallationState.resolve(
                embedding: .incomplete(.missingExecutable), status: .notFound,
                registrationAttempted: false) == .brokenInstall(.helperExecutableMissing))
        #expect(
            HelperInstallationState.resolve(
                embedding: .incomplete(.missingDaemonPlist), status: .notFound,
                registrationAttempted: true) == .brokenInstall(.daemonPlistMissing))
    }

    @Test(
        "An embedded helper reports the system's own answer for the three live states",
        arguments: [false, true])
    func embeddedHelperReportsSystemStatus(registrationAttempted: Bool) {
        // The attempt flag only ever changes the reading of `.notFound`. For every other
        // status the system's own answer stands whether or not Aeolus has called register().
        #expect(
            HelperInstallationState.resolve(
                embedding: .embedded, status: .notRegistered,
                registrationAttempted: registrationAttempted) == .notRegistered)
        #expect(
            HelperInstallationState.resolve(
                embedding: .embedded, status: .requiresApproval,
                registrationAttempted: registrationAttempted) == .awaitingApproval)
        #expect(
            HelperInstallationState.resolve(
                embedding: .embedded, status: .enabled,
                registrationAttempted: registrationAttempted) == .enabled)
    }

    @Test(".notFound before any registration attempt is a first install, not a broken one")
    func notFoundBeforeRegisteringIsUnknownToTheSystem() {
        // Background Task Management has no record of a helper until register() creates
        // one, and answers `.notFound` until then. Observed on hardware, #337.
        #expect(
            HelperInstallationState.resolve(
                embedding: .embedded, status: .notFound, registrationAttempted: false)
                == .unknownToSystem)
    }

    @Test(".notFound after Aeolus asked macOS to register is a broken install")
    func notFoundAfterRegisteringIsBroken() {
        #expect(
            HelperInstallationState.resolve(
                embedding: .embedded, status: .notFound, registrationAttempted: true)
                == .brokenInstall(.systemCannotFindService))
    }

    @Test("A status this version does not recognise stays unrecognised, carrying its code")
    func unrecognisedStatusIsNotGuessedAt() {
        #expect(
            HelperInstallationState.resolve(
                embedding: .embedded, status: .unrecognised(rawValue: 47),
                registrationAttempted: false) == .unrecognisedStatus(rawValue: 47))
    }
}
