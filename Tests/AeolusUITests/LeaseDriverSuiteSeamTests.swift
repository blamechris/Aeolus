import Foundation
import Testing

/// `LeaseDriver.runningHeartbeat` is for the suite alone, and this suite holds `Sources/` to that
/// (#486).
///
/// ## What the compiler holds, and why this is a scan
///
/// No access level can draw this line. `@testable import` reaches exactly `internal`, and so does
/// every file in the module, so any level the suite can name, the app's own wiring can name too.
/// What the compiler does hold is what the accessor hands out: a `HeartbeatHandle` keeps no
/// `Task`, only a closure that waits for one, and only `LeaseDriver.swift` can make one. So
/// nothing that names it can cancel the beat, which is the capability #486 found handed out.
///
/// This scan is the second layer, and it claims **accidents only**: a caller in `Sources/` that
/// waits on the beat, through a wait no cancellation ends.
///
/// ## How it fails closed
///
/// - It counts the two identifiers as raw text, in code, comments and strings alike, so it never
///   has to decide what is a comment. A mention in a comment is red too.
/// - Every count is exact, the declaring file's included: a second use there is red, and so is
///   a declaration deleted or renamed.
/// - Every file under `Sources/` is read, whatever its extension. Hidden files are skipped: the
///   build compiles none of them, and Finder writes `.DS_Store`.
/// - A symbolic link, a file that is not UTF-8, or a tree without `LeaseDriver.swift` is red
///   rather than skipped.
///
/// ## What it cannot see
///
/// A second route to the beat under another name. An accessor that returned the `Task` itself
/// would mention neither identifier. That is a new seam, not a mention of this one, and
/// `HeartbeatHandle`'s doc says why it must not exist.
@Suite("The lease driver's suite-only seam stays in the suite")
struct LeaseDriverSuiteSeamTests {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    /// The file the seam is declared in, relative to `Sources/`.
    private static let declaringFile = "AeolusLeaseControl/LeaseDriver.swift"

    /// Every mention `Sources/` may hold, by file and identifier. `HeartbeatHandle` appears three
    /// times: its declaration, the accessor's type, and the `map` that makes one.
    /// `runningHeartbeat` appears once, as the accessor's own name.
    private static let permitted: [String: [String: Int]] = [
        declaringFile: ["runningHeartbeat": 1, "HeartbeatHandle": 3]
    ]

    private static let identifiers = ["runningHeartbeat", "HeartbeatHandle"]

    /// **Mutation:** in `LeaseLifecycle.systemWillPowerOff()`, add
    /// `_ = await driver.runningHeartbeat`. Red, naming `LeaseLifecycle.swift`. **Mutation:** in
    /// `LeaseDriver.shutDown()`, add `_ = runningHeartbeat`. Red on the declaring file's count.
    @Test("Nothing in Sources names runningHeartbeat or its handle, bar the declaration")
    func onlyTheDeclarationNamesTheSeam() throws {
        let files = try Self.files(under: Self.repositoryRoot.appendingPathComponent("Sources"))
        try #require(
            files[Self.declaringFile] != nil,
            "\(Self.declaringFile) is not under Sources/: the scan would vouch for nothing")

        var found: [String: [String: Int]] = [:]
        for (path, text) in files {
            for identifier in Self.identifiers {
                let count = text.components(separatedBy: identifier).count - 1
                if count > 0 { found[path, default: [:]][identifier] = count }
            }
        }

        let mentions = found.sorted { $0.key < $1.key }
        #expect(
            found == Self.permitted,
            """
            Sources/ mentions the lease driver's suite-only seam as \(mentions). \
            Only \(Self.permitted) is permitted. `runningHeartbeat` is for the suite: its handle \
            waits on a `Task.value`, which no cancellation ends, so app code waiting on it could \
            wait for as long as the lease is held. If a mention in the declaring file changed on \
            purpose, update the count here and say why in the review.
            """)
    }

    /// Every regular, non-hidden file under `root`, by its path relative to `root`, with its text.
    private static func files(under root: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]))
        let prefix = root.standardizedFileURL.path + "/"
        var files: [String: String] = [:]
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                Issue.record("\(path) is a symbolic link; the scan cannot vouch for where it leads")
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard path.hasPrefix(prefix) else {
                Issue.record("\(path) is not under \(prefix)")
                continue
            }
            let relative = String(path.dropFirst(prefix.count))
            files[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }
}
