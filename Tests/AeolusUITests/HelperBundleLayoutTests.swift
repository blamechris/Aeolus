import Foundation
import Testing

@testable import AeolusUI

@Suite("HelperBundleLayout — a build's helper is a fact about the bundle, not about a flag")
struct HelperBundleLayoutTests {

    private let bundleURL = URL(fileURLWithPath: "/Applications/Aeolus.app")

    @Test("The daemon plist path is the plist name inside Contents/Library/LaunchDaemons")
    func daemonPlistPathIsComposedFromTheName() {
        #expect(
            HelperBundleLayout.daemonPlistBundlePath
                == "Contents/Library/LaunchDaemons/\(HelperBundleLayout.daemonPlistName)")
    }

    @Test("Both URLs resolve inside the bundle they are asked about")
    func urlsResolveInsideTheGivenBundle() {
        #expect(
            HelperBundleLayout.executableURL(inBundleAt: bundleURL).path
                == "/Applications/Aeolus.app/Contents/MacOS/AeolusHelper")
        #expect(
            HelperBundleLayout.daemonPlistURL(inBundleAt: bundleURL).path
                == "/Applications/Aeolus.app/Contents/Library/LaunchDaemons/"
                + HelperBundleLayout.daemonPlistName)
    }

    @Test("Executable and plist both present is the only .embedded case")
    func bothPresentIsEmbedded() {
        let embedding = HelperBundleLayout.embedding(inBundleAt: bundleURL) { _ in true }
        #expect(embedding == .embedded)
    }

    @Test("Neither present is .absent — the Monitor build, and not a defect")
    func neitherPresentIsAbsent() {
        let embedding = HelperBundleLayout.embedding(inBundleAt: bundleURL) { _ in false }
        #expect(embedding == .absent)
    }

    @Test("A plist with no executable behind it is a damaged install, not an absent helper")
    func plistWithoutExecutableIsIncomplete() {
        let embedding = HelperBundleLayout.embedding(inBundleAt: bundleURL) { url in
            url.lastPathComponent == HelperBundleLayout.daemonPlistName
        }
        #expect(embedding == .incomplete(.missingExecutable))
    }

    @Test("An executable with no launchd description is a damaged install too")
    func executableWithoutPlistIsIncomplete() {
        let embedding = HelperBundleLayout.embedding(inBundleAt: bundleURL) { url in
            url.lastPathComponent == "AeolusHelper"
        }
        #expect(embedding == .incomplete(.missingDaemonPlist))
    }

    @Test("The probe asks about exactly the two paths the launchd plist depends on")
    func probeAsksAboutBothPaths() {
        var probed: [String] = []
        _ = HelperBundleLayout.embedding(inBundleAt: bundleURL) { url in
            probed.append(url.path)
            return false
        }

        #expect(probed.count == 2)
        #expect(probed.contains("/Applications/Aeolus.app/Contents/MacOS/AeolusHelper"))
        #expect(
            probed.contains(
                "/Applications/Aeolus.app/Contents/Library/LaunchDaemons/"
                    + HelperBundleLayout.daemonPlistName))
    }
}
