import SwiftUI

@main
struct TouchIDSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows; the app lives entirely in the menu bar (LSUIElement = YES).
        // A Settings scene is provided as a target for the standard menu item
        // but the primary settings UI opens from the popover gear button.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.bluetoothManager)
                .environmentObject(appDelegate.networkManager)
                .environmentObject(appDelegate.settingsStore)
        }
    }
}
