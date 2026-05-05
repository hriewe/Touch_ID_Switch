import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    let bluetoothManager = BluetoothManager()
    let networkManager = NetworkManager()
    let settingsStore = SettingsStore()
    private let hotkeyManager = HotkeyManager()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // belt-and-suspenders with LSUIElement

        setupStatusItem()
        setupPopover()

        bluetoothManager.startMonitoring()

        networkManager.start()
        networkManager.onConnectCommandReceived = { [weak self] addresses in
            self?.handleIncomingConnectCommand(addresses: addresses)
        }

        hotkeyManager.register()
        hotkeyManager.onHotKeyPressed = { [weak self] in
            Task { await self?.performSwitch(direction: .toThisMac) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkManager.stop()
        bluetoothManager.stopMonitoring()
        hotkeyManager.unregister()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "Touch ID Switch"
        )
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 440)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(bluetoothManager)
                .environmentObject(networkManager)
                .environmentObject(settingsStore)
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() { popover.performClose(nil) }

    // MARK: - Switch Logic

    enum SwitchDirection { case toThisMac, toOtherMac }

    func performSwitch(direction: SwitchDirection) async {
        let delay = UInt64(settingsStore.switchDelay * 1_000_000_000)

        switch direction {
        case .toOtherMac:
            await bluetoothManager.releaseAllTracked()
            try? await Task.sleep(nanoseconds: delay)
            let addresses = bluetoothManager.trackedDevices.map(\.macAddress)
            do {
                try await networkManager.sendConnectCommand(devices: addresses)
            } catch {
                await MainActor.run { bluetoothManager.lastError = error.localizedDescription }
            }

        case .toThisMac:
            let addresses = bluetoothManager.trackedDevices.map(\.macAddress)
            do {
                try await networkManager.sendConnectCommand(devices: addresses)
            } catch {
                await MainActor.run { bluetoothManager.lastError = error.localizedDescription }
            }
            try? await Task.sleep(nanoseconds: delay)
            await bluetoothManager.connectAllTracked()
        }
    }

    private func handleIncomingConnectCommand(addresses: [String]) {
        Task {
            let delay = UInt64(settingsStore.switchDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            await bluetoothManager.connectAllTracked()
        }
    }
}
