import Foundation

/// Locating and loading the catalog Aeolus ships, from FanKit's own SPM resource bundle.
///
/// Split out of `CatalogLoader.swift` because finding the resource bundle in the first
/// place is a surprisingly large amount of code for what sounds like a one-liner — see
/// `loadBundled()`'s doc comment for why `Bundle.module` isn't good enough here.
extension CatalogLoader {

    /// Loads the catalog Aeolus ships, from FanKit's own SPM resource bundle.
    ///
    /// A missing or unreadable bundled resource means the build is broken, not that the
    /// user did anything wrong — it still degrades to `.empty` plus a warning rather
    /// than throwing, because "no labels" must always be a reachable, working state.
    ///
    /// - Important: This deliberately does **not** use SwiftPM's generated
    ///   `Bundle.module`. That accessor calls `fatalError` if it can't find
    ///   `Aeolus_FanKit.bundle` next to the running executable or at the exact absolute
    ///   `.build` path that built it — fine for `swift test` and the Xcode app, but a
    ///   trap waiting for anything installed without its resource bundle alongside it: a
    ///   Homebrew-packaged `fanctl`, or `Aeolus.app/Contents/MacOS/fanctl` invoked
    ///   directly as `docs/RECOVERY.md` describes. `FanKit` is also a dependency of
    ///   `AeolusHelper`, so a `fatalError`-reachable function here is one call away from
    ///   crashing the root daemon. `locateResourceBundle()` below searches the same
    ///   candidate locations by hand and returns `nil` instead of trapping when none of
    ///   them pan out, which this function turns into the same
    ///   `bundledCatalogUnavailable` warning as any other missing-resource case.
    public static func loadBundled() -> CatalogLoadOutcome {
        loadBundled(searching: defaultCandidateDirectories())
    }

    /// Same as `loadBundled()`, with the candidate search directories injectable so a
    /// test can exercise the real "search exhausted, degrade gracefully" path — the one
    /// that replaces `Bundle.module`'s `fatalError` — without needing to relocate the
    /// actual build output out from under the test process.
    static func loadBundled(searching candidateDirectories: [URL?]) -> CatalogLoadOutcome {
        guard let bundle = locateResourceBundle(searching: candidateDirectories) else {
            return CatalogLoadOutcome(
                catalog: .empty,
                warnings: [
                    .bundledCatalogUnavailable(
                        reason:
                            "Aeolus_FanKit.bundle could not be located near the running executable"
                    )
                ])
        }
        return loadBundled(bundle: bundle)
    }

    /// A type with no purpose but to anchor `Bundle(for:)`, which returns the bundle
    /// containing the compiled code for whatever module `self` belongs to. Combined with
    /// `Bundle.main`, this covers every context FanKit actually runs in: a plain `swift
    /// build` executable (both `Bundle.main` and `Bundle(for:)` resolve to the directory
    /// holding the binary), the `swift test` runner (`Bundle.main` is the toolchain's
    /// test helper and useless, but `Bundle(for:)` resolves to the `.xctest` bundle,
    /// whose *parent* directory holds the sibling resource bundle), and the Xcode app
    /// (`Bundle.main.resourceURL` is `Contents/Resources`, where the resource bundle is
    /// copied).
    private final class BundleAnchor {}

    /// The real candidate directories, in search order, for the process FanKit is
    /// actually running in right now.
    static func defaultCandidateDirectories() -> [URL?] {
        let anchor = Bundle(for: BundleAnchor.self)
        return [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,
            anchor.bundleURL,
            anchor.bundleURL.deletingLastPathComponent(),
            anchor.resourceURL,
        ]
    }

    /// Searches `candidateDirectories`, in order, for an `Aeolus_FanKit.bundle` that
    /// actually contains `catalog.json` at its root, returning the first match. Never
    /// traps — an exhausted search just returns `nil`. See `loadBundled()`'s doc comment
    /// for why this exists instead of `Bundle.module`.
    static func locateResourceBundle(searching candidateDirectories: [URL?]) -> Bundle? {
        let bundleName = "Aeolus_FanKit.bundle"

        for directory in candidateDirectories {
            guard let directory else { continue }
            let candidateURL = directory.appendingPathComponent(bundleName)
            guard let candidateBundle = Bundle(url: candidateURL) else { continue }
            let hasResource =
                candidateBundle.url(forResource: resourceName, withExtension: resourceExtension)
                != nil
            if hasResource {
                return candidateBundle
            }
        }
        return nil
    }

    /// The catalog resource's name and extension within FanKit's resource bundle. Only
    /// `catalog.json` is copied in — see `Package.swift`'s `resources:` entry for
    /// `FanKit` — `catalog.schema.json` is a development-time artifact validated by CI
    /// directly against the source tree and has no reason to ship inside the app.
    fileprivate static let resourceName = "catalog"
    fileprivate static let resourceExtension = "json"

    /// Same as `loadBundled()`, with the resource bundle injectable so tests can exercise
    /// "the bundle doesn't have the resource" without a real broken build.
    static func loadBundled(bundle: Bundle) -> CatalogLoadOutcome {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension)
        else {
            return CatalogLoadOutcome(
                catalog: .empty,
                warnings: [
                    .bundledCatalogUnavailable(
                        reason: "catalog.json was not found in the FanKit resource bundle")
                ])
        }
        return loadBundled(from: url)
    }

    /// Loads a bundled-style catalog from an explicit file URL. Exposed for testing the
    /// "bundle is broken" path without needing a real, malformed resource bundle.
    static func loadBundled(from url: URL) -> CatalogLoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return CatalogLoadOutcome(
                catalog: .empty,
                warnings: [.bundledCatalogUnavailable(reason: describe(error))])
        }
        switch decode(data) {
        case .success(let catalog):
            return CatalogLoadOutcome(catalog: catalog)
        case .failure(let error):
            return CatalogLoadOutcome(
                catalog: .empty,
                warnings: [.bundledCatalogUnavailable(reason: error.description)])
        }
    }
}
