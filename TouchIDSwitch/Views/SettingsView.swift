import SwiftUI

struct SettingsView: View {
    enum DisplayMode {
        case window
        case popover
    }

    @EnvironmentObject var bluetoothManager: BluetoothManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var settings: SettingsStore

    let displayMode: DisplayMode

    @State private var showingDevicePicker = false
    @State private var availableDevices: [TrackedDevice] = []
    @State private var pickerMessage: String?
    @State private var secretFieldText: String = ""
    @State private var secretSaved = false
    @State private var isLoadingDevices = false

    init(displayMode: DisplayMode = .window) {
        self.displayMode = displayMode
    }

    var body: some View {
        formContent
            .frame(width: 420, height: displayMode == .window ? 520 : 500)
            .onAppear {
                secretFieldText = settings.sharedSecret
            }
    }

    @ViewBuilder
    private var formContent: some View {
        if displayMode == .popover {
            popoverContent
        } else if #available(macOS 13.0, *) {
            Form {
                devicesSection
                networkSection
                switchSection
                launchSection
            }
            .formStyle(.grouped)
        } else {
            Form {
                devicesSection
                networkSection
                switchSection
                launchSection
            }
        }
    }

    private var popoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Tracked Devices") {
                    devicesContent
                }

                GroupBox("Network") {
                    networkContent
                }

                GroupBox("Switch Behavior") {
                    switchContent
                }

                GroupBox("Startup") {
                    launchContent
                }
            }
            .padding(12)
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        Section("Tracked Devices") {
            devicesContent
        }
    }

    private var devicesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bluetoothManager.trackedDevices) { device in
                HStack {
                    Image(systemName: "keyboard")
                    Text(device.name)
                    Spacer()
                    Text(device.macAddress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { bluetoothManager.removeTrackedDevice(device) }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: {
                guard !isLoadingDevices else { return }
                isLoadingDevices = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = bluetoothManager.fetchPairedDevicesForPicker()
                    DispatchQueue.main.async {
                        availableDevices = result.devices
                        pickerMessage = result.message
                        showingDevicePicker = true
                        isLoadingDevices = false
                    }
                }
            }) {
                Label(isLoadingDevices ? "Loading Devices..." : "Add Device...", systemImage: "plus")
            }
            .disabled(isLoadingDevices)
            .sheet(isPresented: $showingDevicePicker) {
                DevicePickerSheet(
                    available: availableDevices.filter { av in
                        !bluetoothManager.trackedDevices.contains(av)
                    },
                    allFound: availableDevices,
                    customMessage: pickerMessage,
                    onSelect: { device in
                        bluetoothManager.addTrackedDevice(device)
                        showingDevicePicker = false
                    },
                    onDismiss: { showingDevicePicker = false }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Network

    private var networkSection: some View {
        Section("Network") {
            networkContent
        }
    }

    private var networkContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Peer Mac")
                Spacer()
                Text(networkManager.peerHostname ?? "Not found")
                    .foregroundColor(networkManager.peerHostname == nil ? .red : .secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Shared Secret")
                HStack {
                    SecureField("Secret (stored in Keychain)", text: $secretFieldText)
                        .textFieldStyle(.roundedBorder)
                    Button(action: saveSecret) {
                        Text(secretSaved ? "Saved!" : "Save")
                    }
                    .disabled(secretFieldText == settings.sharedSecret)
                }
                Text("Both Macs must have the same secret. Changes take effect immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Switch Behavior

    private var switchSection: some View {
        Section("Switch Behavior") {
            switchContent
        }
    }

    private var switchContent: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Device release delay")
                Spacer()
                Text(String(format: "%.1f s", settings.switchDelay))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(value: $settings.switchDelay, in: 0.5...3.0, step: 0.5)
            Text("Time to wait after releasing devices before signaling the peer, so the device becomes discoverable.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Launch

    private var launchSection: some View {
        Section("Startup") {
            launchContent
        }
    }

    private var launchContent: some View {
        Toggle("Launch at login", isOn: $settings.launchAtLogin)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func saveSecret() {
        settings.sharedSecret = secretFieldText
        withAnimation { secretSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { secretSaved = false }
        }
    }
}

// MARK: - Device Picker Sheet

struct DevicePickerSheet: View {
    let available: [TrackedDevice]
    let allFound: [TrackedDevice]
    let customMessage: String?
    let onSelect: (TrackedDevice) -> Void
    let onDismiss: () -> Void

    private var emptyMessage: String {
        if let customMessage, !customMessage.isEmpty {
            return customMessage
        }
        if allFound.isEmpty {
            return "No paired Bluetooth devices found. Make sure your devices are paired in System Settings → Bluetooth."
        }
        return "All paired devices are already tracked."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Device")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onDismiss)
            }
            .padding()

            Divider()

            if available.isEmpty {
                Text(emptyMessage)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(available) { device in
                    Button(action: { onSelect(device) }) {
                        HStack {
                            Text(device.name)
                            Spacer()
                            Text(device.macAddress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 360, height: 280)
    }
}
