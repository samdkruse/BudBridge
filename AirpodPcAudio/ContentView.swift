import SwiftUI

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var networkManager = NetworkManager()

    @State private var pcIPAddress = ""
    @AppStorage("lastPCIP") private var savedIP = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("AirPod PC Audio")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Status
            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(networkManager.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(networkManager.statusMessage)
                        .foregroundColor(.secondary)
                }

                if audioManager.isRunning {
                    // Mic level indicator
                    HStack {
                        Text("Mic")
                            .font(.caption)
                            .frame(width: 50, alignment: .leading)
                        ProgressView(value: Double(audioManager.inputLevel), total: 0.5)
                            .progressViewStyle(.linear)
                            .tint(.green)
                    }
                    .padding(.horizontal)

                    // PC audio level indicator
                    HStack {
                        Text("PC Audio")
                            .font(.caption)
                            .frame(width: 50, alignment: .leading)
                        ProgressView(value: Double(audioManager.pcAudioLevel), total: 0.5)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                    }
                    .padding(.horizontal)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            // IP Input
            VStack(alignment: .leading, spacing: 8) {
                Text("PC IP Address")
                    .font(.headline)

                TextField("192.168.1.100", text: $pcIPAddress)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onAppear {
                        if pcIPAddress.isEmpty {
                            pcIPAddress = savedIP
                        }
                    }
            }
            .padding(.horizontal)

            // Connect Button
            Button(action: toggleConnection) {
                HStack {
                    Image(systemName: networkManager.isConnected ? "stop.fill" : "play.fill")
                    Text(networkManager.isConnected ? "Disconnect" : "Connect")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(networkManager.isConnected ? Color.red : Color.blue)
                .cornerRadius(12)
            }
            .padding(.horizontal)
            .disabled(pcIPAddress.isEmpty && !networkManager.isConnected)

            Spacer()

            // Instructions
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup:")
                    .font(.caption)
                    .fontWeight(.bold)
                Text("1. Run the PC app on your Windows machine")
                Text("2. Enter your PC's IP address above")
                Text("3. Tap Connect")
                Text("4. AirPods audio will stream to/from PC")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding()
        }
        .padding()
        .onAppear(perform: setupBindings)
    }

    private func setupBindings() {
        // Wire up audio -> network
        audioManager.onAudioCaptured = { data in
            networkManager.sendAudio(data)
        }

        // Wire up network -> audio
        networkManager.onAudioReceived = { data in
            audioManager.playAudio(data: data)
        }
    }

    private func toggleConnection() {
        if networkManager.isConnected {
            networkManager.disconnect()
            audioManager.stop()
        } else {
            savedIP = pcIPAddress
            print("📱 Starting audio engine...")
            // Start audio engine FIRST, before network
            do {
                try audioManager.start()
                print("📱 Audio engine started, now connecting network...")
                networkManager.connect(to: pcIPAddress)
            } catch {
                print("❌ Failed to start audio: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
}
