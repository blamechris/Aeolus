import AeolusXPCClient
import Foundation

// Where the running app's `HelperSnapshotSource` comes from: the bundle decides whether there is
// a helper to read at all. Its own file because it is the one part of the source that touches
// `Bundle` and constructs a `HelperClient`, and the part the Monitor guarantee rests on.

extension HelperSnapshotSource {

    /// The source for this bundle: a `HelperClient` only when the bundle ships a helper.
    ///
    /// - Parameters:
    ///   - embedding: What the bundle contains (`HelperBundleLayout.embedding`).
    ///   - refreshInterval: Seconds between requests, read afresh each time.
    ///   - makeReader: Builds the reader. **Never called** unless `embedding` is `.embedded`:
    ///     a `Monitor` build constructs no client, and so cannot reach the helper's mach name
    ///     even by accident.
    /// - Returns: A source reading the new client, or a source with no reader that says why.
    static func forBundle(
        _ embedding: HelperEmbedding,
        refreshInterval: @escaping @MainActor () -> TimeInterval,
        makeReader: () -> any HelperSnapshotReading
    ) -> HelperSnapshotSource {
        switch embedding {
        case .absent:
            return HelperSnapshotSource(withoutHelper: .noHelperInThisBuild)
        case .incomplete:
            return HelperSnapshotSource(withoutHelper: .helperInstallIncomplete)
        case .embedded:
            return HelperSnapshotSource(reader: makeReader(), refreshInterval: refreshInterval)
        }
    }

    /// The running app's source: its own bundle, and a `HelperClient` on the default
    /// transport and pinning if, and only if, that bundle ships a helper.
    static func forRunningApp(
        refreshInterval: @escaping @MainActor () -> TimeInterval
    ) -> HelperSnapshotSource {
        forBundle(
            HelperBundleLayout.embedding(inBundleAt: Bundle.main.bundleURL),
            refreshInterval: refreshInterval
        ) {
            HelperClient(clientDescription: clientDescription(of: .main))
        }
    }

    /// What the app calls itself in the helper's log: `Aeolus.app <version>`.
    static func clientDescription(of bundle: Bundle) -> String {
        guard
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty
        else { return "Aeolus.app" }
        return "Aeolus.app \(version)"
    }
}
