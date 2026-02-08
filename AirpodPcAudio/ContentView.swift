import SwiftUI

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var networkManager = NetworkManager()
    @StateObject private var pcStore = PCStore()

    var body: some View {
        TabView {
            ConnectionView(
                audioManager: audioManager,
                networkManager: networkManager,
                pcStore: pcStore
            )
            .tabItem {
                Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
            }

            PCsView(pcStore: pcStore)
                .tabItem {
                    Label("PCs", systemImage: "desktopcomputer")
                }
        }
        .onAppear(perform: setupBindings)
    }

    private func setupBindings() {
        // Wire up audio -> network (weak to break retain cycle)
        audioManager.onAudioCaptured = { [weak networkManager] data in
            networkManager?.sendAudio(data)
        }

        // Wire up network -> audio (weak to break retain cycle)
        networkManager.onAudioReceived = { [weak audioManager] data in
            audioManager?.playAudio(data: data)
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var networkManager: NetworkManager
    @ObservedObject var pcStore: PCStore

    var body: some View {
        VStack(spacing: 24) {
            Text("BudBridge")
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
                            .frame(width: 60, alignment: .leading)
                        ProgressView(value: Double(audioManager.inputLevel), total: 0.5)
                            .progressViewStyle(.linear)
                            .tint(.green)
                    }
                    .padding(.horizontal)

                    // PC audio level indicator
                    HStack {
                        Text("PC Audio")
                            .font(.caption)
                            .frame(width: 60, alignment: .leading)
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

            // PC Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("PC")
                    .font(.headline)

                if pcStore.pcs.isEmpty {
                    Text("No PCs saved. Go to PCs tab to add one.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    Menu {
                        ForEach(pcStore.pcs) { pc in
                            Button(action: { pcStore.select(pc) }) {
                                HStack {
                                    Text(pc.name)
                                    if pcStore.selectedPCId == pc.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(pcStore.selectedPC?.name ?? "Select a PC")
                                .foregroundColor(pcStore.selectedPC != nil ? .primary : .secondary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
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
            .disabled(pcStore.selectedPC == nil && !networkManager.isConnected)

            Spacer()

            // iPhone IP Display
            HStack {
                Text("My iPhone IP:")
                    .foregroundColor(.secondary)
                if let ip = NetworkUtils.getWiFiIPAddress() {
                    Text(ip)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text("No WiFi")
                        .foregroundColor(.red)
                }
            }
            .font(.subheadline)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)

            // Instructions
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup:")
                    .font(.caption)
                    .fontWeight(.bold)
                Text("1. Run BudBridge on your Windows PC")
                Text("2. Add your PC in the PCs tab")
                Text("3. Select the PC above and tap Connect")
                Text("4. Audio will stream between devices")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding()
        }
        .padding()
    }

    private func toggleConnection() {
        if networkManager.isConnected {
            networkManager.disconnect()
            audioManager.stop()
        } else {
            guard let pc = pcStore.selectedPC else { return }
            print("📱 Starting audio engine...")
            // Start audio engine FIRST, before network
            do {
                try audioManager.start()
                print("📱 Audio engine started, now connecting to \(pc.name) (\(pc.ipAddress))...")
                networkManager.connect(to: pc.ipAddress)
            } catch {
                print("❌ Failed to start audio: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
}
