import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `HelperSnapshotSource` as the running app builds it: no client at all for a bundle with no
/// helper, the shipping entry point reading the real bundle, and what the client calls itself.
@Suite("HelperSnapshotSource — what the bundle ships decides the client", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceBundleTests {

    typealias Support = SnapshotTestSupport

    // MARK: - No helper in the build, and the shipping entry point

    /// **Mutation (M9):** in `HelperSnapshotSource.forBundle`, build the reader for `.absent`
    /// too — `case .absent: return HelperSnapshotSource(reader: makeReader(), refreshInterval:
    /// refreshInterval)`. Run: red at `built == 0` and at the `.noHelperInThisBuild`
    /// expectation.
    @Test("The Monitor build constructs no helper client at all")
    func theMonitorBuildConstructsNoClient() {
        var built = 0
        let source = HelperSnapshotSource.forBundle(
            .absent, refreshInterval: { 1 },
            makeReader: {
                built += 1
                return FakeSnapshotHelper()
            })
        source.start()
        source.stop()

        #expect(built == 0)
        #expect(source.authority() == .readDirectly(.noHelperInThisBuild))
    }

    @Test(
        "A damaged bundle constructs no helper client either",
        arguments: [HelperEmbeddingDefect.missingExecutable, .missingDaemonPlist])
    func aDamagedBundleConstructsNoClient(_ defect: HelperEmbeddingDefect) {
        var built = 0
        let source = HelperSnapshotSource.forBundle(
            .incomplete(defect), refreshInterval: { 1 },
            makeReader: {
                built += 1
                return FakeSnapshotHelper()
            })

        #expect(built == 0)
        #expect(source.authority() == .readDirectly(.helperInstallIncomplete))
    }

    /// The control: the factory is reachable, so `built == 0` above is a finding and not a
    /// closure nothing could call.
    @Test("A bundle that ships a helper constructs exactly one client")
    func anEmbeddedHelperConstructsOneClient() {
        var built = 0
        let source = HelperSnapshotSource.forBundle(
            .embedded, refreshInterval: { 1 },
            makeReader: {
                built += 1
                return FakeSnapshotHelper()
            })

        #expect(built == 1)
        #expect(source.authority() == .awaitHelper(.helperConnection(.idle)))
    }

    /// The shipping entry point asks the running bundle, and the test runner's bundle ships no
    /// helper. **Mutation (O1):** pass `.embedded` in `forRunningApp` instead of reading
    /// `Bundle.main`. Run: red here.
    @Test("forRunningApp reads the running bundle, which under the test runner has no helper")
    func forRunningAppReadsTheRunningBundle() {
        let source = HelperSnapshotSource.forRunningApp(refreshInterval: { 1 })
        #expect(source.authority() == .readDirectly(.noHelperInThisBuild))
    }

    @Test("The client calls itself Aeolus.app with its version, and plainly without one")
    func theClientDescriptionCarriesTheVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-client-description-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func bundle(version: String?) throws -> Bundle {
            let url = root.appendingPathComponent("\(UUID().uuidString).bundle")
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.example.\(UUID().uuidString)"]
            if let version { info["CFBundleShortVersionString"] = version }
            let data = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return try #require(Bundle(url: url))
        }

        #expect(
            HelperSnapshotSource.clientDescription(of: try bundle(version: "0.3.0"))
                == "Aeolus.app 0.3.0")
        #expect(HelperSnapshotSource.clientDescription(of: try bundle(version: "")) == "Aeolus.app")
        #expect(
            HelperSnapshotSource.clientDescription(of: try bundle(version: nil)) == "Aeolus.app")
    }
}
