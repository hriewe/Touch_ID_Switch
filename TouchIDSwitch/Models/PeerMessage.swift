import Foundation

struct PeerMessage: Codable {
    enum Action: String, Codable {
        case connect
        case ping
        case pong
    }

    let action: Action
    let devices: [String]       // MAC addresses
    let timestamp: TimeInterval // Unix timestamp, used to resolve simultaneous switch conflicts
    let secret: String          // shared secret for auth; compared against local Keychain value
    let senderHostname: String

    init(action: Action, devices: [String] = [], secret: String) {
        self.action = action
        self.devices = devices
        self.timestamp = Date().timeIntervalSince1970
        self.secret = secret
        self.senderHostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
