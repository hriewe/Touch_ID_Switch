import Foundation
import Network
import Combine

// NetworkManager handles Bonjour peer discovery and JSON message exchange.
// Service type: _touchidswitch._tcp (advertised + browsed).
// Auth: every message carries the shared secret from Keychain; mismatches are silently dropped.
// Simultaneous-switch resolution: the peer with the larger timestamp wins (its connect message arrives later and takes effect).
final class NetworkManager: NSObject, ObservableObject {

    enum PeerState {
        case notFound
        case discovered(endpoint: NWEndpoint, name: String)
        case connected
    }

    @Published var peerState: PeerState = .notFound
    @Published var lastError: String?

    // Fired when the peer sends a connect command; carries the MAC address list.
    var onConnectCommandReceived: (([String]) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peerConnection: NWConnection?
    private var incomingConnections: [NWConnection] = []

    private let serviceType = "_touchidswitch._tcp"
    private let localPort: NWEndpoint.Port = 47822
    private let localHostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    // Tracks the timestamp of the last connect command we sent, so we can
    // discard older messages that arrive out of order or in a simultaneous-switch race.
    private var lastSentTimestamp: TimeInterval = 0

    // MARK: - Lifecycle

    func start() {
        startListener()
        startBrowsing()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        peerConnection?.cancel()
        incomingConnections.forEach { $0.cancel() }
    }

    // MARK: - Listener

    private func startListener() {
        let params = NWParameters.tcp

        do {
            listener = try NWListener(using: params, on: localPort)
        } catch {
            DispatchQueue.main.async { self.lastError = "Listener init failed: \(error.localizedDescription)" }
            return
        }

        listener?.service = NWListener.Service(name: localHostname, type: serviceType)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                DispatchQueue.main.async { self?.lastError = "Listener failed: \(err.localizedDescription)" }
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleIncoming(connection)
        }

        listener?.start(queue: .global(qos: .utility))
    }

    // MARK: - Browser

    private func startBrowsing() {
        let params = NWParameters()

        browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    // Ignore our own advertisement
                    if case .service(let name, _, _, _) = result.endpoint, name == self.localHostname {
                        continue
                    }
                    var peerName = "unknown"
                    if case .service(let name, _, _, _) = result.endpoint {
                        peerName = name
                    }
                    DispatchQueue.main.async {
                        self.peerState = .discovered(endpoint: result.endpoint, name: peerName)
                    }

                case .removed:
                    DispatchQueue.main.async {
                        self.peerState = .notFound
                        self.peerConnection = nil
                    }

                default:
                    break
                }
            }
        }

        browser?.start(queue: .global(qos: .utility))
    }

    // MARK: - Sending

    /// Sends a connect command to the peer. The caller supplies the MAC addresses and the delay
    /// is applied externally (in AppDelegate) so the device has time to become discoverable.
    func sendConnectCommand(devices: [String]) async throws {
        let secret = KeychainManager.shared.loadSharedSecret() ?? ""
        let message = PeerMessage(action: .connect, devices: devices, secret: secret)
        lastSentTimestamp = message.timestamp
        try await send(message)
    }

    func sendPing() async throws {
        let secret = KeychainManager.shared.loadSharedSecret() ?? ""
        let message = PeerMessage(action: .ping, devices: [], secret: secret)
        try await send(message)
    }

    private func send(_ message: PeerMessage) async throws {
        guard case .discovered(let endpoint, _) = peerState else {
            throw NetworkError.peerNotFound
        }

        let data = try JSONEncoder().encode(message)
        let lengthPrefix = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
        let payload = lengthPrefix + data

        if peerConnection == nil || peerConnection?.state == .cancelled {
            peerConnection = makeConnection(to: endpoint)
        }

        return try await withCheckedThrowingContinuation { continuation in
            peerConnection?.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: NetworkError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func makeConnection(to endpoint: NWEndpoint) -> NWConnection {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.peerState = .connected }
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.peerConnection = nil }
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
        return conn
    }

    // MARK: - Receiving

    private func handleIncoming(_ connection: NWConnection) {
        incomingConnections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.incomingConnections.removeAll { $0 === connection }
            }
        }
        connection.start(queue: .global(qos: .utility))
        receiveNextMessage(from: connection)
    }

    private func receiveNextMessage(from connection: NWConnection) {
        // Read 4-byte length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == 4 else { return }

            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length < 1_048_576 else { return } // sanity cap: 1 MB

            connection.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { [weak self] msgData, _, _, error in
                guard let self, error == nil, let msgData else { return }
                self.processMessage(msgData, from: connection)
                self.receiveNextMessage(from: connection)
            }
        }
    }

    private func processMessage(_ data: Data, from connection: NWConnection) {
        guard let message = try? JSONDecoder().decode(PeerMessage.self, from: data) else { return }

        let localSecret = KeychainManager.shared.loadSharedSecret() ?? ""
        guard message.secret == localSecret else {
            print("[NetworkManager] Dropped message from \(message.senderHostname): secret mismatch")
            return
        }

        // Simultaneous-switch resolution: if we sent a message more recently, ignore this one.
        if message.action == .connect, message.timestamp < lastSentTimestamp {
            print("[NetworkManager] Dropped older connect from \(message.senderHostname) (race resolution)")
            return
        }

        switch message.action {
        case .connect:
            DispatchQueue.main.async {
                self.onConnectCommandReceived?(message.devices)
            }

        case .ping:
            let secret = KeychainManager.shared.loadSharedSecret() ?? ""
            let pong = PeerMessage(action: .pong, secret: secret)
            if let pongData = try? JSONEncoder().encode(pong) {
                let prefix = withUnsafeBytes(of: UInt32(pongData.count).bigEndian) { Data($0) }
                connection.send(content: prefix + pongData, completion: .idempotent)
            }

        case .pong:
            break
        }
    }

    // MARK: - Peer Name Helper

    var peerHostname: String? {
        if case .discovered(_, let name) = peerState { return name }
        if case .connected = peerState { return peerConnection.map { _ in "connected" } }
        return nil
    }
}

// MARK: - Errors

enum NetworkError: LocalizedError {
    case peerNotFound
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .peerNotFound:
            return "Peer Mac not found on local network"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        }
    }
}
