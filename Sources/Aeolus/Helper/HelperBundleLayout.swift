import Foundation

/// Where the privileged helper lives inside `Aeolus.app`, and whether the running build
/// ships one at all.
///
/// ## Why this asks the bundle instead of a compile-time flag
///
/// The `Monitor` configuration contains no helper: an ad-hoc-signed root daemon cannot
/// express a stable client code-signing requirement — no chain, no team, and a cdhash
/// pins exactly one build — and `SMAppService` daemon registration is not a supported
/// path for it. See `docs/ADR/0005-xpc-authorisation.md`.
///
/// The obvious way to enforce that in code is `#if MONITOR_ONLY`. It does not work, and
/// the reason is recorded here so nobody reaches for it a second time.
///
/// Such a condition is set in `project.yml` on the *Xcode app target*, while this file
/// compiles as part of the `AeolusUI` SwiftPM library — and whether a project-level
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` reaches a package target is an Xcode
/// implementation detail rather than a contract. **Measured**, with `MONITOR_ONLY` set on
/// `Monitor Debug` and a `#if MONITOR_ONLY` probe compiled into this target: the condition
/// is *not visible* here. A flag-based implementation would therefore have taken its
/// `#else` — helper-exists — branch in precisely the build that ships no helper, which is
/// an app offering to install a root daemon it does not contain.
///
/// `MONITOR_ONLY` has since been removed from `project.yml`: nothing read it, and a flag
/// that silently fails to arrive is worse than no flag.
///
/// Asking the bundle cannot invert that way: if `Contents/MacOS/AeolusHelper` and
/// `Contents/Library/LaunchDaemons/…plist` are not both on disk, this build has no
/// helper, whatever any flag says. The same probe also separates a `Monitor` build
/// (neither present, by design) from a damaged install (one present without the other) —
/// a distinction the UI has to draw anyway, and one no compile-time flag can draw at all.
enum HelperBundleLayout {

    /// File name of the launchd job description, and the argument
    /// `SMAppService.daemon(plistName:)` is keyed on.
    ///
    /// `SMAppService` resolves it against `Contents/Library/LaunchDaemons` in the calling
    /// app's own bundle, so this is a file name and never a path.
    /// `LaunchDaemonPlistTests` asserts the file in `Configs/LaunchDaemons/` matches.
    static let daemonPlistName = "com.blamechris.Aeolus.Helper.plist"

    /// The helper's location, relative to the app bundle root.
    ///
    /// Must equal `BundleProgram` in the launchd plist: launchd resolves that key against
    /// the app bundle, so a disagreement is a daemon that registers and then never
    /// starts. Asserted by `LaunchDaemonPlistTests` and re-checked at build time by the
    /// embed script in `project.yml`.
    static let executableBundlePath = "Contents/MacOS/AeolusHelper"

    /// The launchd plist's location, relative to the app bundle root.
    static let daemonPlistBundlePath = "Contents/Library/LaunchDaemons/\(daemonPlistName)"

    static func executableURL(inBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(executableBundlePath)
    }

    static func daemonPlistURL(inBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(daemonPlistBundlePath)
    }

    /// What the bundle at `bundleURL` actually contains.
    ///
    /// - Parameters:
    ///   - bundleURL: The app bundle root — `Bundle.main.bundleURL` in the running app.
    ///   - fileExists: Injected so the classification is testable without building four
    ///     app bundles. The default is the real filesystem.
    /// - Returns: `.embedded` only when both pieces are present. Anything else is a
    ///   build that must not attempt registration.
    static func embedding(
        inBundleAt bundleURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> HelperEmbedding {
        let hasExecutable = fileExists(executableURL(inBundleAt: bundleURL))
        let hasDaemonPlist = fileExists(daemonPlistURL(inBundleAt: bundleURL))

        switch (hasExecutable, hasDaemonPlist) {
        case (true, true):
            return .embedded
        case (false, false):
            return .absent
        case (true, false):
            return .incomplete(.missingDaemonPlist)
        case (false, true):
            return .incomplete(.missingExecutable)
        }
    }
}

/// What the running app bundle contains, as opposed to what it was supposed to.
enum HelperEmbedding: Sendable, Hashable {
    /// Executable and launchd description both present: a `Full` build.
    case embedded

    /// Neither present. The `Monitor` configuration, by design — not a fault, and never
    /// to be described as one. There is nothing here to register, so nothing is asked of
    /// `SMAppService` at all.
    case absent

    /// Exactly one of the two present. Never a state the build system produces; it means
    /// the bundle was damaged, partially copied, or partially deleted after the fact.
    case incomplete(HelperEmbeddingDefect)
}

/// Which half of a half-embedded helper is missing.
enum HelperEmbeddingDefect: Sendable, Hashable {
    /// The launchd description is present; the binary it names is not.
    case missingExecutable
    /// The binary is present; nothing tells launchd how to run it.
    case missingDaemonPlist
}
