import Foundation
import SwiftUI

extension View {

    /// Tells `composition` when this window appears and goes, as `window`, so the root can tell
    /// when the last control window has closed (`AppComposition.windowDisappeared(_:id:)`).
    ///
    /// Synchronous on both edges, and it awaits nothing: the root starts whatever the close leads
    /// to on a task of its own (#419). Every window reports, control window or not, so which kinds
    /// release is decided in one place, `AppWindow.isControlWindow`, rather than by which views
    /// happen to call in. Each window's root view applies it in its own `body`, as its own
    /// `window`, so a kind cannot be paired with the wrong view where a scene is declared.
    func reportsPresence(as window: AppWindow, to composition: AppComposition) -> some View {
        modifier(WindowPresenceReporter(window: window, composition: composition))
    }
}

/// One window's identifier, kept for as long as SwiftUI keeps the view's state: a window's
/// lifetime, for a scene's root view.
private struct WindowPresenceReporter: ViewModifier {
    let window: AppWindow
    let composition: AppComposition
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { composition.windowAppeared(window, id: id) }
            .onDisappear { composition.windowDisappeared(window, id: id) }
    }
}
