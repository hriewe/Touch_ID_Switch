import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    let bluetoothManager = BluetoothManager()
    let networkManager = NetworkManager()
    let settingsStore = SettingsStore()
    private let hotkeyManager = HotkeyManager()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var lastIncomingConnectAt: Date?

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
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 440)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                onPerformSwitch: { [weak self] direction in
                    guard let self else { return }
                    await self.performSwitch(direction: direction)
                }
            )
                .environmentObject(bluetoothManager)
                .environmentObject(networkManager)
                .environmentObject(settingsStore)
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            openSettingsWindow()
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    @objc func openSettingsWindow() {
        if settingsWindow == nil {
            let rootView = SettingsView()
                .environmentObject(bluetoothManager)
                .environmentObject(networkManager)
                .environmentObject(settingsStore)
            let hostingController = NSHostingController(rootView: rootView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Touch ID Switch Settings"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TouchIDSwitchSettings")
            settingsWindow = window
        }

        closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

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
                Task { await bluetoothManager.holdTrackedDisconnectedForHandoff() }
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
            let now = Date()
            if let lastIncomingConnectAt,
               now.timeIntervalSince(lastIncomingConnectAt) < 20 {
                print("[AppDelegate] Ignoring duplicate incoming connect command")
                return
            }
            lastIncomingConnectAt = now

            let delay = UInt64(settingsStore.switchDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            await bluetoothManager.acceptIncomingHandoff()
        }
    }
}
