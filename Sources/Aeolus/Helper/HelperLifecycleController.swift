import Combine
import Foundation
import ServiceManagement

/// The `SMAppService` operations Aeolus performs, behind a seam.
///
/// Every method here has a real system side effect — installing or removing a root launch
/// daemon, or opening System Settings — so tests drive a fake and never the real thing.
/// The seam is also where a future replacement for `SMAppService` would land without the
/// state machine above it changing at all.
@MainActor
protocol HelperDaemonService: AnyObject {
    /// What macOS currently reports. Queried through `HelperInstallationState.resolve`,
    /// which never asks in a build with no helper embedded.
    var status: HelperDaemonStatus { get }

    /// Asks macOS to install the daemon. Returning without throwing means the request was
    /// accepted — **not** that the daemon is enabled; that is what `status` is for.
    func register() throws

    /// Removes the daemon registration.
    func unregister() throws

    /// Opens System Settings at Login Items & Extensions, where the user approves the
    /// background item. There is no in-app equivalent: `SMAppService` cannot prompt.
    func openSystemSettingsLoginItems()
}

/// The real thing.
///
/// `SMAppService.daemon(plistName:)` constructs a handle and performs no I/O, so it is
/// safe to build one in a `Monitor` build that will never use it. Nothing here is called
/// unless `HelperLifecycleController` has first confirmed the bundle actually contains a
/// helper.
@MainActor
final class SystemHelperDaemonService: HelperDaemonService {
    private let service: SMAppService

    init(plistName: String = HelperBundleLayout.daemonPlistName) {
        service = SMAppService.daemon(plistName: plistName)
    }

    var status: HelperDaemonStatus { HelperDaemonStatus(service.status) }

    func register() throws { try service.register() }

    func unregister() throws { try service.unregister() }

    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Why a lifecycle request did not do what was asked.
///
/// Refusals that never reached `SMAppService` are distinguished from rejections that came
/// back from it, because the two mean completely different things to whoever reads the
/// message.
enum HelperLifecycleFailure: Sendable, Hashable {
    /// Refused locally: this build ships no helper, so there is nothing to install.
    case noHelperInThisBuild
    /// Refused locally: the bundle is damaged, and installing half a helper is worse than
    /// installing none.
    case installDamaged(HelperInstallDefect)
    /// macOS refused the installation request.
    case registrationRejected(String)
    /// macOS refused the removal request.
    case removalRejected(String)

    var message: String {
        switch self {
        case .noHelperInThisBuild:
            return "This build of Aeolus contains no privileged helper, so there is nothing "
                + "to install."
        case .installDamaged:
            return "Aeolus's own bundle is incomplete, so its helper was not offered to "
                + "macOS. Reinstall Aeolus."
        case .registrationRejected(let reason):
            return "macOS refused to install the helper: \(reason)"
        case .removalRejected(let reason):
            return "macOS refused to remove the helper: \(reason)"
        }
    }
}

/// Owns the helper's `SMAppService` lifecycle and publishes an honest account of it.
///
/// ## The two rules this type exists to enforce
///
/// 1. **Never ask macOS to install a daemon this build does not contain.** Every mutating
///    call re-probes the bundle first and refuses locally when the helper is absent — the
///    `Monitor` guarantee, enforced at runtime rather than by a compile-time flag that
///    may or may not reach this module. See `HelperBundleLayout`.
/// 2. **Publish the system's answer, never the call's outcome.** `register()` returning
///    successfully does not mean the daemon is running; for a daemon the normal next
///    state is `.requiresApproval`, and it stays there indefinitely until the user acts
///    in System Settings. So every mutation is followed by a fresh status read, and it is
///    that read that reaches the UI. Publishing "installed" because a call returned is
///    precisely the rule 6 failure: a UI reporting control nothing is honouring.
///
/// ## Concurrency
///
/// `@MainActor`, `ObservableObject`: bound directly by `HelperStatusView`. `register()`
/// and `unregister()` are synchronous — `SMAppService`'s own API is — and are user-driven
/// one-shot actions rather than anything on a refresh cadence, so the brief IPC they do
/// is not worth an actor hop that would make the published state harder to reason about.
@MainActor
final class HelperLifecycleController: ObservableObject {

    /// The current, honest installation state. Never optimistic: it is only ever the
    /// result of `HelperInstallationState.resolve`.
    @Published private(set) var state: HelperInstallationState

    /// The most recent failed request, if the last one failed. Cleared when a new request
    /// starts, so a stale complaint cannot linger next to a state that has since changed.
    @Published private(set) var lastFailure: HelperLifecycleFailure?

    private let service: any HelperDaemonService
    private let embeddingProbe: @MainActor () -> HelperEmbedding

    /// - Parameters:
    ///   - service: The `SMAppService` seam. Defaults to the real one.
    ///   - embeddingProbe: What this build ships. Defaults to probing the running app
    ///     bundle. Injected in tests, which have no app bundle at all — `Bundle.main`
    ///     under `swift test` is the test runner, so the default would report `.absent`
    ///     and hide every other branch.
    init(
        service: any HelperDaemonService = SystemHelperDaemonService(),
        embeddingProbe: @escaping @MainActor () -> HelperEmbedding = {
            HelperBundleLayout.embedding(inBundleAt: Bundle.main.bundleURL)
        }
    ) {
        self.service = service
        self.embeddingProbe = embeddingProbe
        state = HelperInstallationState.resolve(
            embedding: embeddingProbe(), status: service.status)
    }

    /// Re-reads the bundle and the system.
    ///
    /// Worth calling whenever the app becomes active: the approval that moves
    /// `.awaitingApproval` to `.enabled` happens in System Settings, and the app is given
    /// no notification of it.
    func refresh() {
        state = HelperInstallationState.resolve(
            embedding: embeddingProbe(), status: service.status)
    }

    /// Asks macOS to install the helper, then reports what macOS says afterwards.
    ///
    /// Refuses locally, without touching `SMAppService`, unless the helper is genuinely
    /// embedded in this bundle.
    func register() {
        lastFailure = nil

        let embedding = embeddingProbe()
        guard case .embedded = embedding else {
            refuse(embedding)
            return
        }

        do {
            try service.register()
        } catch {
            lastFailure = .registrationRejected(error.localizedDescription)
        }

        // Unconditional, and after the failure is recorded rather than instead of it: the
        // state the user sees is always the system's own answer. A successful call
        // normally lands in .awaitingApproval, and a failed one may still have changed
        // something.
        refresh()
    }

    /// Removes the helper's registration, then reports what macOS says afterwards.
    ///
    /// The supported uninstall is deleting the app — the daemon ships inside the bundle
    /// precisely so that removing the bundle removes the daemon. This is the in-app path
    /// for a user who wants the helper gone while keeping the app, and it does not
    /// replace `docs/RECOVERY.md`'s `sudo launchctl bootout`, which works when the app
    /// cannot run at all.
    func unregister() {
        lastFailure = nil

        let embedding = embeddingProbe()
        guard case .embedded = embedding else {
            refuse(embedding)
            return
        }

        do {
            try service.unregister()
        } catch {
            lastFailure = .removalRejected(error.localizedDescription)
        }

        refresh()
    }

    /// Opens System Settings where the pending approval lives.
    func openLoginItemsSettings() {
        service.openSystemSettingsLoginItems()
    }

    private func refuse(_ embedding: HelperEmbedding) {
        switch embedding {
        case .absent:
            lastFailure = .noHelperInThisBuild
        case .incomplete(.missingExecutable):
            lastFailure = .installDamaged(.helperExecutableMissing)
        case .incomplete(.missingDaemonPlist):
            lastFailure = .installDamaged(.daemonPlistMissing)
        case .embedded:
            // Unreachable: every caller has already matched `.embedded` and returned.
            return
        }

        // Resolved from the embedding alone — the status autoclosure is not evaluated for
        // a build with no usable helper, so this reports the refusal without ever asking
        // macOS about a daemon Aeolus did not ship.
        state = HelperInstallationState.resolve(embedding: embedding, status: service.status)
    }
}
