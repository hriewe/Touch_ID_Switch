import Foundation
import IOBluetooth
import Combine

// BluetoothManager wraps IOBluetooth connect/disconnect/unpair operations.
//
// Unpair strategy (in order):
//   1. Private API: IOBluetoothDevice.removeFromFavorites() via perform(Selector)
//   2. blueutil fallback: /opt/homebrew/bin/blueutil --unpair <address>
// The strategy used is logged to console so it is auditable.
final class BluetoothManager: NSObject, ObservableObject {

    @Published var trackedDevices: [TrackedDevice] = []
    @Published var pairedDevices: [TrackedDevice] = []
    @Published var lastError: String?

    private var statusTimer: Timer?
    private let userDefaultsKey = "trackedDeviceAddresses"

    override init() {
        super.init()
        loadTrackedDevices()
    }

    // MARK: - Persistence

    func loadTrackedDevices() {
        let addresses = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        let all = fetchPairedDevices()
        trackedDevices = all.filter { addresses.contains($0.macAddress) }
    }

    func saveTrackedDevices() {
        let addresses = trackedDevices.map(\.macAddress)
        UserDefaults.standard.set(addresses, forKey: userDefaultsKey)
    }

    func addTrackedDevice(_ device: TrackedDevice) {
        guard !trackedDevices.contains(device) else { return }
        trackedDevices.append(device)
        saveTrackedDevices()
    }

    func removeTrackedDevice(_ device: TrackedDevice) {
        trackedDevices.removeAll { $0 == device }
        saveTrackedDevices()
    }

    // MARK: - Discovery

    func fetchPairedDevices() -> [TrackedDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() else { return [] }
        return paired.compactMap { obj -> TrackedDevice? in
            guard let device = obj as? IOBluetoothDevice,
                  let name = device.name,
                  let address = device.addressString else { return nil }
            let status: DeviceStatus = device.isConnected() ? .connected : .disconnected
            return TrackedDevice(name: name, macAddress: address, status: status)
        }
    }

    // MARK: - Status Monitoring

    func startMonitoring() {
        updateStatuses()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateStatuses()
        }
    }

    func stopMonitoring() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func updateStatuses() {
        let all = fetchPairedDevices()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in self.trackedDevices.indices {
                if let fresh = all.first(where: { $0.macAddress == self.trackedDevices[i].macAddress }) {
                    self.trackedDevices[i].status = fresh.status
                } else {
                    self.trackedDevices[i].status = .unknown
                }
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connectDevice(_ device: TrackedDevice) async throws {
        guard let bt = IOBluetoothDevice(addressString: device.macAddress) else {
            throw BluetoothError.deviceNotFound(device.macAddress)
        }
        let result = bt.openConnection()
        guard result == kIOReturnSuccess else {
            throw BluetoothError.connectionFailed(device.name, result)
        }
    }

    func disconnectDevice(_ device: TrackedDevice) async throws {
        guard let bt = IOBluetoothDevice(addressString: device.macAddress) else {
            throw BluetoothError.deviceNotFound(device.macAddress)
        }
        let result = bt.closeConnection()
        guard result == kIOReturnSuccess else {
            throw BluetoothError.disconnectionFailed(device.name, result)
        }
    }

    // MARK: - Unpair

    func unpairDevice(_ device: TrackedDevice) async throws {
        guard let bt = IOBluetoothDevice(addressString: device.macAddress) else {
            throw BluetoothError.deviceNotFound(device.macAddress)
        }

        // Strategy 1: private API
        let sel = Selector(("removeFromFavorites"))
        if bt.responds(to: sel) {
            print("[BluetoothManager] Unpairing \(device.name) via private API removeFromFavorites")
            bt.perform(sel)
            return
        }

        // Strategy 2: blueutil CLI
        let blueutil = "/opt/homebrew/bin/blueutil"
        guard FileManager.default.isExecutableFile(atPath: blueutil) else {
            throw BluetoothError.unpairUnavailable(device.name)
        }
        print("[BluetoothManager] Unpairing \(device.name) via blueutil fallback")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: blueutil)
        process.arguments = ["--unpair", device.macAddress]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BluetoothError.unpairFailed(device.name, process.terminationStatus)
        }
    }

    // MARK: - Batch Operations

    /// Disconnects (and optionally unpairs) all tracked devices in preparation for a switch.
    func releaseAllTracked(unpair: Bool = false) async {
        for device in trackedDevices {
            do {
                try await disconnectDevice(device)
                if unpair {
                    try await unpairDevice(device)
                }
            } catch {
                await setError(error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 s gap between devices
        }
    }

    /// Attempts to connect all tracked devices, retrying up to 3 times with 1 s intervals.
    func connectAllTracked() async {
        for device in trackedDevices {
            var succeeded = false
            for attempt in 1...3 {
                do {
                    try await connectDevice(device)
                    succeeded = true
                    break
                } catch {
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
            if !succeeded {
                await setError("Failed to connect \(device.name) after 3 attempts")
            }
        }
        updateStatuses()
    }

    // MARK: - Helpers

    @MainActor
    private func setError(_ message: String) {
        lastError = message
    }
}

// MARK: - Errors

enum BluetoothError: LocalizedError {
    case deviceNotFound(String)
    case connectionFailed(String, IOReturn)
    case disconnectionFailed(String, IOReturn)
    case unpairUnavailable(String)
    case unpairFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let addr):
            return "Device not found: \(addr)"
        case .connectionFailed(let name, let code):
            return "Failed to connect \(name) (IOReturn 0x\(String(code, radix: 16)))"
        case .disconnectionFailed(let name, let code):
            return "Failed to disconnect \(name) (IOReturn 0x\(String(code, radix: 16)))"
        case .unpairUnavailable(let name):
            return """
            Cannot unpair \(name): private API unavailable and blueutil is not installed. \
            Install it with: brew install blueutil
            """
        case .unpairFailed(let name, let code):
            return "blueutil failed to unpair \(name) (exit \(code))"
        }
    }
}
