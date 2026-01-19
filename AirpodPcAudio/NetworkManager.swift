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

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error)")
            }
        })
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
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                self.receiveLoop(connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                self?.onAudioReceived?(data)
            }
            if error == nil {
                self?.receiveLoop(connection)
            }
        }
    }
}
