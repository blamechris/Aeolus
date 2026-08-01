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
            }())

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
            }())
        let missingPlist = HelperInstallationState.resolve(
            embedding: .incomplete(.missingDaemonPlist),
            status: {
                queried = true
                return .enabled
            }())

        #expect(missingExecutable == .brokenInstall(.helperExecutableMissing))
        #expect(missingPlist == .brokenInstall(.daemonPlistMissing))
        #expect(queried == false)
    }

    @Test("An embedded helper reports the system's own answer for the three live states")
    func embeddedHelperReportsSystemStatus() {
        #expect(
            HelperInstallationState.resolve(embedding: .embedded, status: .notRegistered)
                == .notRegistered)
        #expect(
            HelperInstallationState.resolve(embedding: .embedded, status: .requiresApproval)
                == .awaitingApproval)
        #expect(
            HelperInstallationState.resolve(embedding: .embedded, status: .enabled) == .enabled)
    }

    @Test(".notFound with both files on disk is a broken install, not a missing helper")
    func notFoundWithFilesPresentIsBroken() {
        #expect(
            HelperInstallationState.resolve(embedding: .embedded, status: .notFound)
                == .brokenInstall(.systemCannotFindService))
    }

    @Test("A status this version does not recognise stays unrecognised, carrying its code")
    func unrecognisedStatusIsNotGuessedAt() {
        #expect(
            HelperInstallationState.resolve(
                embedding: .embedded, status: .unrecognised(rawValue: 47))
                == .unrecognisedStatus(rawValue: 47))
    }
}
