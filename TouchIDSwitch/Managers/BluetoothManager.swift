import Foundation
import IOBluetooth
import Combine

// BluetoothManager wraps device discovery, connect/disconnect, and unpair.
//
// Device enumeration strategy:
//   1. blueutil --paired (covers Classic + BLE, e.g. Magic Keyboard / Magic Mouse)
//   2. IOBluetooth fallback (Classic BT only, used when blueutil is absent)
//
// Connect/disconnect strategy:
//   1. IOBluetoothDevice (Classic BT)
//   2. blueutil --connect / --disconnect fallback (BLE)
//
// Tracked device persistence:
//   Full TrackedDevice structs are JSON-encoded in UserDefaults so the list
//   survives restarts without needing a live BT scan on launch.
final class BluetoothManager: NSObject, ObservableObject {

    @Published var trackedDevices: [TrackedDevice] = []
    @Published var lastError: String?

    private var statusTimer: Timer?
    private let userDefaultsKey = "trackedDevicesV2"

    override init() {
        super.init()
        loadTrackedDevices()
    }

    // MARK: - Persistence

    func loadTrackedDevices() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let devices = try? JSONDecoder().decode([TrackedDevice].self, from: data) else { return }
        // Restore with unknown status; monitoring timer will refresh shortly.
        trackedDevices = devices.map {
            TrackedDevice(id: $0.id, name: $0.name, macAddress: $0.macAddress, status: .unknown)
        }
    }

    func saveTrackedDevices() {
        guard let data = try? JSONEncoder().encode(trackedDevices) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
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
        // 1. blueutil: covers Classic BT + BLE, requires external install.
        if let path = blueutilPath {
            let devices = fetchViaBlueutil(path)
            if !devices.isEmpty { return devices }
        }
        // 2. system_profiler: built-in, covers Classic BT + BLE.
        let spDevices = fetchViaSystemProfiler()
        if !spDevices.isEmpty { return spDevices }
        // 3. IOBluetooth: Classic BT only — will not find Magic Keyboard/Mouse.
        guard let paired = IOBluetoothDevice.pairedDevices() else { return [] }
        return paired.compactMap { obj -> TrackedDevice? in
            guard let device = obj as? IOBluetoothDevice,
                  let name = device.name,
                  let address = device.addressString else { return nil }
            return TrackedDevice(name: name, macAddress: address,
                                 status: device.isConnected() ? .connected : .disconnected)
        }
    }

    private func fetchViaSystemProfiler() -> [TrackedDevice] {
        let out = Pipe(), err = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let btArray = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var devices: [TrackedDevice] = []
        // Device lists appear under different keys across macOS versions.
        let deviceKeys = ["device_title", "device_connected", "device_not_connected"]
        for controller in btArray {
            for key in deviceKeys {
                guard let list = controller[key] as? [[String: Any]] else { continue }
                for entry in list {
                    guard let name = entry["_name"] as? String, !name.isEmpty,
                          let address = entry["device_address"] as? String else { continue }
                    let connected = (entry["device_isconnected"] as? String) == "attrib_Yes"
                    let device = TrackedDevice(name: name,
                                              macAddress: address.lowercased(),
                                              status: connected ? .connected : .disconnected)
                    if !devices.contains(device) { devices.append(device) }
                }
            }
        }
        return devices
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
        // Try IOBluetooth first (Classic BT).
        if let bt = IOBluetoothDevice(addressString: device.macAddress),
           bt.openConnection() == kIOReturnSuccess { return }

        // Fall back to blueutil (BLE devices like Magic Keyboard / Magic Mouse).
        guard let path = blueutilPath else {
            throw BluetoothError.bleRequiresBlueutil(device.name)
        }
        try runBlueutil(path, args: ["--connect", device.macAddress],
                        onFailure: BluetoothError.connectionFailed(device.name, 0))
    }

    func disconnectDevice(_ device: TrackedDevice) async throws {
        // Try IOBluetooth first (Classic BT).
        if let bt = IOBluetoothDevice(addressString: device.macAddress),
           bt.closeConnection() == kIOReturnSuccess { return }

        // Fall back to blueutil (BLE devices like Magic Keyboard / Magic Mouse).
        guard let path = blueutilPath else {
            throw BluetoothError.bleRequiresBlueutil(device.name)
        }
        try runBlueutil(path, args: ["--disconnect", device.macAddress],
                        onFailure: BluetoothError.disconnectionFailed(device.name, 0))
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
        guard let path = blueutilPath else {
            throw BluetoothError.unpairUnavailable(device.name)
        }
        print("[BluetoothManager] Unpairing \(device.name) via blueutil fallback")
        try runBlueutil(path, args: ["--unpair", device.macAddress],
                        onFailure: BluetoothError.unpairFailed(device.name, 0))
    }

    // MARK: - Batch Operations

    func releaseAllTracked(unpair: Bool = false) async {
        for device in trackedDevices {
            do {
                try await disconnectDevice(device)
                if unpair { try await unpairDevice(device) }
            } catch {
                await setError(error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

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

    // MARK: - blueutil helpers

    private var blueutilPath: String? {
        ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct BlueutilDevice: Decodable {
        let address: String
        let name: String?
        let isConnected: Bool
    }

    private func fetchViaBlueutil(_ path: String) -> [TrackedDevice] {
        let out = Pipe(), err = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--paired", "--format", "json"]
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let parsed = (try? JSONDecoder().decode([BlueutilDevice].self, from: data)) ?? []
        return parsed.compactMap { d in
            guard let name = d.name, !name.isEmpty else { return nil }
            return TrackedDevice(name: name, macAddress: d.address,
                                 status: d.isConnected ? .connected : .disconnected)
        }
    }

    private func runBlueutil(_ path: String, args: [String], onFailure: BluetoothError) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw onFailure }
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
    case bleRequiresBlueutil(String)
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
        case .bleRequiresBlueutil(let name):
            return "\(name) is a BLE device. Install blueutil to manage it: brew install blueutil"
        case .unpairUnavailable(let name):
            return "Cannot unpair \(name): private API unavailable and blueutil not installed (brew install blueutil)"
        case .unpairFailed(let name, let code):
            return "blueutil failed to unpair \(name) (exit \(code))"
        }
    }
}
