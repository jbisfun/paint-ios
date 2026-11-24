import FossifyCommons
import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
    case settings
    case customizeColors
    case about
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []
    var toast: String?
    var openURL: URL?

    func push(_ r: Route) { path.append(r) }
}

/// The whole app as one view: the standalone app's window content, and what
/// the launcher presents. `openURL` is an image or SVG handed over by the launcher.
public struct PaintRoot: View {
    @State private var router = Router()
    private let openURL: URL?

    public init(openURL: URL? = nil) {
        self.openURL = openURL
    }

    public var body: some View {
        RootView()
            .environment(router)
            .environment(Config.shared)
            .fossifyTheme()
            .onOpenURL { url in router.openURL = url }
            .onAppear { if let openURL { router.openURL = openURL } }
    }
}

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            MainView()
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case .settings: SettingsView()
                        case .customizeColors: CustomizeColorsView()
                        case .about: AboutView(app: .paint)
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .paletteBackground()
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .toast($router.toast)
        .onAppear {
            updateIdleTimer()
            OrientationLock.set(portrait: config.forcePortraitMode)
        }
        .onChange(of: phase) { updateIdleTimer() }
        .onChange(of: config.preventPhoneFromSleeping) { updateIdleTimer() }
        .onChange(of: config.forcePortraitMode) { OrientationLock.set(portrait: config.forcePortraitMode) }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationLock.set(portrait: false)
        }
    }

    /// FLAG_KEEP_SCREEN_ON while the app is in front.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = config.preventPhoneFromSleeping && phase == .active
    }
}
