import Foundation

enum DeviceStatus: String, Codable, Equatable {
    case connected
    case disconnected
    case unknown
}

struct TrackedDevice: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var macAddress: String
    var status: DeviceStatus

    init(id: UUID = UUID(), name: String, macAddress: String, status: DeviceStatus = .unknown) {
        self.id = id
        self.name = name
        self.macAddress = macAddress
        self.status = status
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(macAddress)
    }

    static func == (lhs: TrackedDevice, rhs: TrackedDevice) -> Bool {
        lhs.macAddress == rhs.macAddress
    }
}
