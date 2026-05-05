import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var bluetoothManager: BluetoothManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var settings: SettingsStore

    @State private var showingDevicePicker = false
    @State private var availableDevices: [TrackedDevice] = []
    @State private var secretFieldText: String = ""
    @State private var secretSaved = false

    var body: some View {
        formContent
            .frame(width: 420, height: 520)
            .onAppear {
                secretFieldText = settings.sharedSecret
                availableDevices = bluetoothManager.fetchPairedDevices()
            }
    }

    @ViewBuilder
    private var formContent: some View {
        if #available(macOS 13.0, *) {
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

    // MARK: - Devices

    private var devicesSection: some View {
        Section("Tracked Devices") {
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

            Button(action: { showingDevicePicker = true }) {
                Label("Add Device…", systemImage: "plus")
            }
            .sheet(isPresented: $showingDevicePicker) {
                DevicePickerSheet(
                    available: availableDevices.filter { av in
                        !bluetoothManager.trackedDevices.contains(av)
                    },
                    onSelect: { device in
                        bluetoothManager.addTrackedDevice(device)
                        showingDevicePicker = false
                    },
                    onDismiss: { showingDevicePicker = false }
                )
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section("Network") {
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
    }

    // MARK: - Switch Behavior

    private var switchSection: some View {
        Section("Switch Behavior") {
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
        }
    }

    // MARK: - Launch

    private var launchSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
        }
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
    let onSelect: (TrackedDevice) -> Void
    let onDismiss: () -> Void

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
                Text("All paired devices are already tracked.")
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
