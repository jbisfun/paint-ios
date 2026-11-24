import FossifyCommons
import SwiftUI

/// SettingsActivity.
struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var config = config
        VStack(spacing: 0) {
            TopBar(title: "Settings")
            ScrollView {
                VStack(spacing: 0) {
                    Text("Color customization").sectionHeader(palette)
                    SettingsItem("Customize colors") { router.push(.customizeColors) }

                    Text("General").sectionHeader(palette)
                    SettingsToggle("Prevent phone from sleeping while the app is in foreground", isOn: $config.preventPhoneFromSleeping)
                    SettingsToggle("Show brush size tool", isOn: $config.showBrushSize)
                    SettingsToggle("Allow zooming and moving the canvas with gestures", isOn: $config.allowZoomingCanvas)
                    SettingsToggle("Adjust brush size based on zoom level", isOn: $config.relativeBrushSize)
                    SettingsToggle("Force portrait mode", isOn: $config.forcePortraitMode)
                }
                .padding(.bottom, 32)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
    }
}

extension AppInfo {
    public static let paint = AppInfo(
        name: "Paint", icon: "paintbrush.pointed", upstream: "Paint", port: "paint-ios", policy: "paint"
    )
}
