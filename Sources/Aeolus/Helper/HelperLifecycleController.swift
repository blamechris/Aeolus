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
    /// `register()` threw, and the status macOS reported afterwards did not say the
    /// registration had gone through.
    ///
    /// A throw alone is not a refusal. On a first install `register()` throws
    /// (`SMAppServiceErrorDomain` code 1, "Operation not permitted") in the same instant
    /// Background Task Management creates the item awaiting approval (#337); the status
    /// is what says whether macOS refused, and `isContradicted(by:)` is how this case
    /// defers to it.
    case registrationRejected(String)
    /// macOS refused the removal request.
    case removalRejected(String)

    /// Whether `state` makes this failure untrue, so that showing it would be reporting a
    /// failure beside a status that says otherwise.
    ///
    /// A registration failure is contradicted by any state that is only reachable once
    /// macOS has the registration: awaiting approval, or enabled. A removal failure is
    /// **not** contradicted by `.enabled` — that is precisely the state an unregister that
    /// failed leaves behind. The local refusals are about what the bundle contains, not about
    /// what macOS says, so no status contradicts them; `refresh()` does re-probe the bundle,
    /// but a failure of that kind is cleared by the next request, not by a status.
    /// Exhaustive on purpose: a new failure has to decide.
    func isContradicted(by state: HelperInstallationState) -> Bool {
        switch self {
        case .registrationRejected:
            return state == .awaitingApproval || state == .enabled
        case .noHelperInThisBuild, .installDamaged, .removalRejected:
            return false
        }
    }

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
    /// starts, and dropped by any later status read that contradicts it
    /// (`HelperLifecycleFailure.isContradicted(by:)`), so a stale complaint cannot linger
    /// next to a state that has since changed — a refusal beside "installed and enabled".
    @Published private(set) var lastFailure: HelperLifecycleFailure?

    private let service: any HelperDaemonService
    private let embeddingProbe: @MainActor () -> HelperEmbedding

    /// True from a `register()` call that reached `SMAppService` until the system next
    /// reports anything other than `.notFound`.
    ///
    /// It is what separates the two readings of `.notFound`: with no attempt behind it, a
    /// first launch (`.unknownToSystem`); with one, a broken install. Dropped as soon as
    /// macOS answers anything else, so an old attempt that went on to succeed cannot make a
    /// later, unrelated "not found" look like a failed install.
    ///
    /// Per process, and not persisted: after a relaunch it starts `false` again, so a
    /// `.notFound` that survives a failed attempt reads as `.unknownToSystem` once more.
    /// That is accurate — macOS still has no record — and offers the same remedy, the
    /// `.register` action; it just no longer says an attempt was made.
    private var registrationAttempted = false

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
            embedding: embeddingProbe(), status: service.status, registrationAttempted: false)
    }

    /// Re-reads the bundle and the system.
    ///
    /// Worth calling whenever the app becomes active: the approval that moves
    /// `.awaitingApproval` to `.enabled` happens in System Settings, and the app is given
    /// no notification of it. That same approval is what retracts a registration failure
    /// recorded earlier — `register()` can throw as the item is created awaiting approval —
    /// so the read that publishes the new state also drops any failure it contradicts.
    func refresh() {
        var observed: HelperDaemonStatus?
        func read() -> HelperDaemonStatus {
            let status = service.status
            observed = status
            return status
        }

        state = HelperInstallationState.resolve(
            embedding: embeddingProbe(), status: read(),
            registrationAttempted: registrationAttempted)

        // Only a status macOS actually gave can end the attempt; a build that was never
        // asked (no helper embedded) leaves `observed` empty and the flag alone.
        if let observed, observed != .notFound {
            registrationAttempted = false
        }
        if let failure = lastFailure, failure.isContradicted(by: state) {
            lastFailure = nil
        }
    }

    /// Asks macOS to install the helper, then reports what macOS says afterwards.
    ///
    /// Refuses locally, without touching `SMAppService`, unless the helper is genuinely
    /// embedded in this bundle.
    ///
    /// A throw from `SMAppService.register()` is **not** taken as a refusal on its own. On a
    /// first install it throws code 1 ("Operation not permitted") in the same instant
    /// Background Task Management creates the item awaiting approval (#337), so the status
    /// read after the call decides: awaiting approval or enabled means macOS did accept the
    /// registration, and no refusal is shown; anything else means the throw is the best
    /// account of what macOS said, and it is shown.
    func register() {
        lastFailure = nil

        let embedding = embeddingProbe()
        guard case .embedded = embedding else {
            refuse(embedding)
            return
        }

        registrationAttempted = true
        var thrown: Error?
        do {
            try service.register()
        } catch {
            thrown = error
        }

        // Unconditional, and before the failure is judged: the state the user sees is
        // always the system's own answer. A successful call normally lands in
        // .awaitingApproval, and a failed one may still have changed something — that
        // answer is what decides whether the throw was a refusal at all.
        refresh()

        if let thrown {
            let failure = HelperLifecycleFailure.registrationRejected(thrown.localizedDescription)
            if !failure.isContradicted(by: state) {
                lastFailure = failure
            }
        }
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
        state = HelperInstallationState.resolve(
            embedding: embedding, status: service.status, registrationAttempted: false)
    }
}
