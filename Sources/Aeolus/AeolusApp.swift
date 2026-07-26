import AeolusXPC
import FanKit
import SwiftUI

/// The SwiftUI application.
///
/// This target is a *view* of helper state, not an owner of it. It edits configuration
/// and renders snapshots; it never writes to the SMC and never holds authoritative fan
/// state. Closing the window or quitting the app is always safe.
///
/// Built two ways:
///   * `Monitor` — read-only, no helper, no entitlements. Ad-hoc signable, so anyone can
///     build and run it. All of the UI work happens here.
///   * `Full` — embeds and registers the privileged helper. Needs a Developer ID.
///
/// - Note: `@main` is applied by the Xcode app target generated from `project.yml`. This
///   type is compiled as a plain library under `swift build` so CI type-checks the views
///   without needing an app bundle.
public struct AeolusApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainView()
        }

        // TODO(E7): MenuBarExtra with multiple simultaneous readouts and sparklines.
    }
}

/// The two-pane main window: fans on the left, sensors on the right.
struct MainView: View {
    var body: some View {
        HSplitView {
            FanListView()
            SensorListView()
        }
        .frame(minWidth: 720, minHeight: 420)
    }
}

struct FanListView: View {
    // TODO(E7): bind to the helper snapshot stream.
    var body: some View {
        VStack {
            Text("Fans")
                .font(.headline)
            Spacer()
        }
        .frame(minWidth: 320)
        .padding()
    }
}

struct SensorListView: View {
    // TODO(E7): sensor table with raw key always visible and confidence badges.
    var body: some View {
        VStack {
            Text("Sensors")
                .font(.headline)
            Spacer()
        }
        .frame(minWidth: 320)
        .padding()
    }
}
