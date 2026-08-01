import AppKit
import SwiftUI

/// The one place the app states where its privileged helper stands.
///
/// It renders `HelperStatusDisplay.text(for:)` and nothing else — the wording, and the
/// decision about which of the states is worth an action button, are that type's, so they
/// are unit-tested rather than eyeballed. See it for why a `Monitor` build says "no
/// privileged helper in this build" and not "the helper is not running".
///
/// The status is re-read whenever the app becomes active. That is not decoration: the
/// approval that moves a daemon from "requires approval" to "enabled" happens in System
/// Settings, and macOS sends the app no notification when it does. Without this, a user
/// who approves the helper and switches back would keep reading a stale "waiting for your
/// approval" — a message that is wrong in the most confusing possible direction.
struct HelperStatusView: View {
    @ObservedObject var controller: HelperLifecycleController

    var body: some View {
        let display = HelperStatusDisplay.text(for: controller.state)

        HStack(alignment: .top, spacing: 8) {
            icon(for: display.severity)

            VStack(alignment: .leading, spacing: 2) {
                Text(display.title)
                    .font(.caption.weight(.semibold))
                Text(display.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure = controller.lastFailure {
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            if let action = display.action {
                Button(action.title) { perform(action) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            controller.refresh()
        }
    }

    @ViewBuilder
    private func icon(for severity: HelperStatusDisplay.Severity) -> some View {
        switch severity {
        case .normal:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        case .actionNeeded:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func perform(_ action: HelperStatusDisplay.Action) {
        switch action {
        case .register:
            controller.register()
        case .openLoginItemsSettings:
            controller.openLoginItemsSettings()
        case .unregister:
            controller.unregister()
        }
    }
}
