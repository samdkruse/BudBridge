import Foundation
import Network

class NetworkManager: ObservableObject {
    private var connection: NWConnection?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "network", qos: .userInteractive)

    @Published var isConnected = false
    @Published var statusMessage = "Disconnected"

    // Ports
    private let sendPort: UInt16 = 4810    // PC listens here (receives mic audio)
    private let receivePort: UInt16 = 4811 // iPhone listens here (receives PC audio)

    // Debug stats
    private var rxPacketCount = 0
    private var rxByteCount = 0
    private var txPacketCount = 0
    private var txByteCount = 0
    private var lastStatsTime = Date()
    private var nonZeroSamples = 0

    // Callback when audio data received from PC
    var onAudioReceived: ((Data) -> Void)?

    deinit {
        disconnect()
    }

    func connect(to host: String) {
        disconnect()

        // Create UDP connection to PC
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: sendPort)!)
        connection = NWConnection(to: endpoint, using: .udp)

        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.statusMessage = "Connected to \(host)"
                    print("Connected to \(host):\(self?.sendPort ?? 0)")
                case .failed(let error):
                    self?.isConnected = false
                    self?.statusMessage = "Failed: \(error.localizedDescription)"
                    print("Connection failed: \(error)")
                case .cancelled:
                    self?.isConnected = false
                    self?.statusMessage = "Disconnected"
                case .waiting(let error):
                    self?.statusMessage = "Waiting: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }

        connection?.start(queue: queue)

        // Start listener for incoming PC audio
        startListener()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil

        DispatchQueue.main.async {
            self.isConnected = false
            self.statusMessage = "Disconnected"
        }
    }

    // MARK: - Send (mic audio to PC)

    func sendAudio(_ data: Data) {
        guard isConnected, let connection = connection else { return }

        // Chunk data to avoid UDP fragmentation (max ~1400 bytes per packet)
        let chunkSize = 1400
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            txPacketCount += 1
            txByteCount += chunk.count
            connection.send(content: chunk, completion: .contentProcessed { error in
                if let error = error {
                    print("Send error: \(error)")
                }
            })
            offset = end
        }
    }

    // MARK: - Receive (PC audio to iPhone)

    private func startListener() {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: receivePort)!)

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleIncomingConnection(newConnection)
            }

            listener?.stateUpdateHandler = { state in
                print("Listener state: \(state)")
            }

            listener?.start(queue: queue)
            print("Listening for PC audio on port \(receivePort)")

        } catch {
            print("Failed to create listener: \(error)")
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        print("🔗 Incoming connection from: \(connection.endpoint)")
        connection.stateUpdateHandler = { state in
            print("   Connection state: \(state)")
            if case .ready = state {
                self.receiveLoop(connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                self?.rxPacketCount += 1
                self?.rxByteCount += data.count

                // Count non-zero samples to detect silence
                data.withUnsafeBytes { ptr in
                    if let samples = ptr.bindMemory(to: Int16.self).baseAddress {
                        let count = data.count / 2
                        for i in 0..<count {
                            if samples[i] != 0 {
                                self?.nonZeroSamples += 1
                            }
                        }
                    }
                }

                // Log stats every second
                let now = Date()
                if let lastTime = self?.lastStatsTime, now.timeIntervalSince(lastTime) >= 1.0 {
                    let samples = data.count / 2
                    let preview = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("📦 RX: \(self?.rxPacketCount ?? 0) pkts, \(self?.rxByteCount ?? 0) bytes | Last: \(data.count)B (\(samples) samples)")
                    print("   Non-zero samples: \(self?.nonZeroSamples ?? 0) | Preview: \(preview)")
                    print("📤 TX: \(self?.txPacketCount ?? 0) pkts, \(self?.txByteCount ?? 0) bytes")

                    self?.rxPacketCount = 0
                    self?.rxByteCount = 0
                    self?.txPacketCount = 0
                    self?.txByteCount = 0
                    self?.nonZeroSamples = 0
                    self?.lastStatsTime = now
                }

                self?.onAudioReceived?(data)
            }
            if let error = error {
                print("❌ Receive error: \(error)")
            } else {
                self?.receiveLoop(connection)
            }
        }
    }
}
