import Foundation
import ServiceManagement

// Central ObservableObject for all user-configurable settings.
// switchDelay and launchAtLogin are persisted in UserDefaults.
// sharedSecret is persisted in Keychain via KeychainManager.
final class SettingsStore: ObservableObject {

    @Published var switchDelay: Double {
        didSet { UserDefaults.standard.set(switchDelay, forKey: Keys.switchDelay) }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    @Published var sharedSecret: String = "" {
        didSet {
            try? KeychainManager.shared.saveSharedSecret(sharedSecret)
        }
    }

    private enum Keys {
        static let switchDelay = "switchDelay"
        static let launchAtLogin = "launchAtLogin"
    }

    init() {
        let delay = UserDefaults.standard.object(forKey: Keys.switchDelay) as? Double ?? 1.5
        self.switchDelay = delay
        self.launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
        self.sharedSecret = KeychainManager.shared.loadSharedSecret() ?? ""
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.launchAtLogin)
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[SettingsStore] SMAppService error: \(error.localizedDescription)")
            }
        } else {
            // macOS 12: use deprecated API
            let bundleID = Bundle.main.bundleIdentifier ?? "com.hriewe.TouchIDSwitch"
            SMLoginItemSetEnabled(bundleID as CFString, enabled)
        }
    }
}
