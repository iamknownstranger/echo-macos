import Foundation
import Network

actor DiscordRPC {
    static let shared = DiscordRPC()

    private var connection: NWConnection?
    private var isConnected = false
    private let clientID = "1198426027387330560" // Echo Music Discord App ID

    init() {}

    /// Connects to local Discord IPC socket if running.
    func connectIfNeeded() {
        guard connection == nil else { return }

        let tmpDir = NSTemporaryDirectory()
        let socketPath = (tmpDir as NSString).appendingPathComponent("discord-ipc-0")
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        let endpoint = NWEndpoint.unix(path: socketPath)
        let conn = NWConnection(to: endpoint, using: .tcp)

        conn.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    await self.setConnected(true)
                    await self.startReading()
                    await self.sendHandshake()
                case .failed, .cancelled:
                    await self.setConnected(false)
                    await self.closeConnection()
                default:
                    break
                }
            }
        }

        self.connection = conn
        conn.start(queue: .global(qos: .utility))
    }

    private func setConnected(_ val: Bool) {
        self.isConnected = val
    }

    private func closeConnection() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    private func sendHandshake() {
        let handshake: [String: Any] = [
            "v": 1,
            "client_id": clientID
        ]
        send(opcode: 0, payload: handshake)
    }

    private func startReading() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { [weak self] content, _, isComplete, error in
            Task { [weak self] in
                guard let self, let content, content.count == 8 else {
                    if isComplete || error != nil { await self?.closeConnection() }
                    return
                }
                let len = content.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                if len > 0 {
                    await self.readPayload(length: Int(len))
                } else {
                    await self.startReading()
                }
            }
        }
    }

    private func readPayload(length: Int) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] _, _, isComplete, error in
            Task { [weak self] in
                guard let self else { return }
                if isComplete || error != nil {
                    await self.closeConnection()
                } else {
                    await self.startReading()
                }
            }
        }
    }

    func updateActivity(track: Track?, position: Double, duration: Double, isPlaying: Bool) {
        guard let track else {
            clearActivity()
            return
        }

        connectIfNeeded()
        guard isConnected else { return }

        let startTimestamp = isPlaying ? Int(Date().timeIntervalSince1970 - position) : nil
        let endTimestamp = (isPlaying && duration > 0) ? Int(Date().timeIntervalSince1970 + (duration - position)) : nil

        var activity: [String: Any] = [
            "details": track.title,
            "state": track.artist,
            "assets": [
                "large_image": track.artwork?.absoluteString ?? "echo_icon",
                "large_text": track.album ?? "Echo Music",
                "small_image": isPlaying ? "play" : "pause",
                "small_text": isPlaying ? "Playing" : "Paused"
            ]
        ]

        if let start = startTimestamp, let end = endTimestamp {
            activity["timestamps"] = ["start": start, "end": end]
        }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": activity
            ],
            "nonce": UUID().uuidString
        ]

        send(opcode: 1, payload: payload)
    }

    func clearActivity() {
        guard isConnected else { return }
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": NSNull()
            ],
            "nonce": UUID().uuidString
        ]
        send(opcode: 1, payload: payload)
    }

    private func send(opcode: UInt32, payload: [String: Any]) {
        guard let connection, isConnected || opcode == 0 else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var header = Data(count: 8)
        var op = opcode.littleEndian
        var len = UInt32(jsonData.count).littleEndian

        header.replaceSubrange(0..<4, with: Data(bytes: &op, count: 4))
        header.replaceSubrange(4..<8, with: Data(bytes: &len, count: 4))

        var packet = header
        packet.append(jsonData)

        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
}
