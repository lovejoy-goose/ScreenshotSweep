import Combine
import Foundation

/// Single navigation state of the app. Dashboard links append routes; incoming URLs
/// replace the stack deterministically. Has no access to pairing, events, PhotoKit or the
/// camera, so opening a URL can only show a screen.
@MainActor
final class AppNavigator: ObservableObject {
    @Published var path: [AppRoute] = []

    init(path: [AppRoute] = []) {
        self.path = path
    }

    /// Handles `katana-connector://open?…`. Invalid links change nothing. Returns whether the link was valid.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let action = try? ConnectorURLRouter.parse(url) else { return false }
        apply(action)
        return true
    }

    /// Shows exactly the link's routes on top of Dashboard: whatever was open (and its sheets) is closed.
    /// Repeating the same link while that screen is already shown changes nothing.
    func apply(_ action: ConnectorURLAction) {
        switch action {
        case .open(let feature):
            let target = [feature.route]
            if path != target { path = target }
        case .openDestination(let destination):
            let target = destination.routes
            if path != target { path = target }
        }
    }
}
