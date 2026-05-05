import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var bluetoothManager: BluetoothManager
    @EnvironmentObject var networkManager: NetworkManager
    @EnvironmentObject var settings: SettingsStore

    let onPerformSwitch: (AppDelegate.SwitchDirection) async -> Void

    @State private var showingSettings = false
    @State private var isSwitching = false

    var body: some View {
        Group {
            if showingSettings {
                embeddedSettings
            } else {
                mainContent
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            deviceList
            Divider()
            peerStatus
            Divider()
            actionButtons
        }
        .frame(width: 320)
    }

    private var embeddedSettings: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { showingSettings = false }) {
                    Image(systemName: "chevron.left")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Back")

                Text("Settings")
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            SettingsView(displayMode: .popover)
                .environmentObject(bluetoothManager)
                .environmentObject(networkManager)
                .environmentObject(settings)
        }
        .frame(width: 420)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Touch ID Switch")
                .font(.headline)
            Spacer()
            Button(action: { showingSettings = true }) {
                Image(systemName: "gear")
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Device List

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tracked Devices")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            if bluetoothManager.trackedDevices.isEmpty {
                Text("No devices tracked — open Settings to add devices.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else {
                ForEach(bluetoothManager.trackedDevices) { device in
                    deviceRow(device)
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func deviceRow(_ device: TrackedDevice) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(device.status))
                .frame(width: 8, height: 8)
            Text(device.name)
                .font(.body)
            Spacer()
            Text(device.status.rawValue.capitalized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private func statusColor(_ status: DeviceStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .disconnected: return .red
        case .unknown:      return .gray
        }
    }

    // MARK: - Peer Status

    private var peerStatus: some View {
        HStack {
            Image(systemName: peerStateIcon)
                .foregroundColor(peerStateColor)
            Text(peerStateLabel)
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var peerStateIcon: String {
        switch networkManager.peerState {
        case .notFound:   return "wifi.slash"
        case .discovered: return "wifi"
        case .connected:  return "wifi"
        }
    }

    private var peerStateColor: Color {
        switch networkManager.peerState {
        case .notFound:   return .red
        case .discovered: return .orange
        case .connected:  return .green
        }
    }

    private var peerStateLabel: String {
        switch networkManager.peerState {
        case .notFound:
            return "Peer Mac: not found"
        case .discovered(_, let name):
            return "Peer Mac: \(name)"
        case .connected:
            return "Peer Mac: connected"
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            if let error = bluetoothManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            HStack(spacing: 10) {
                switchButton(title: "Switch to This Mac", direction: .toThisMac)
                switchButton(title: "Switch to Other Mac", direction: .toOtherMac)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func switchButton(title: String, direction: AppDelegate.SwitchDirection) -> some View {
        Button(action: {
            guard !isSwitching else { return }
            isSwitching = true
            bluetoothManager.lastError = nil
            Task {
                await onPerformSwitch(direction)
                await MainActor.run { isSwitching = false }
            }
        }) {
            Text(isSwitching ? "Switching…" : title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSwitching || bluetoothManager.trackedDevices.isEmpty)
        .help(direction == .toThisMac
              ? "Signal the peer to release devices, then connect them here"
              : "Disconnect devices here and signal the peer to connect them")
    }
}
