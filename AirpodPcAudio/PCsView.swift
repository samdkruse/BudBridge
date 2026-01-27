import SwiftUI

struct PCsView: View {
    @ObservedObject var pcStore: PCStore

    @State private var newName = ""
    @State private var newIP = ""
    @State private var editingPC: SavedPC?
    @State private var showingEditSheet = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name, ip
    }

    var body: some View {
        NavigationView {
            List {
                // Add new PC section
                Section("Add New PC") {
                    TextField("Name (e.g., Gaming PC)", text: $newName)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .ip }

                    TextField("IP Address (e.g., 192.168.1.100)", text: $newIP)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .ip)
                        .submitLabel(.done)
                        .onSubmit { addPC() }

                    Button(action: addPC) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add PC")
                        }
                    }
                    .disabled(newName.isEmpty || newIP.isEmpty)
                }

                // Saved PCs section
                if !pcStore.pcs.isEmpty {
                    Section("Saved PCs") {
                        ForEach(pcStore.pcs) { pc in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pc.name)
                                        .font(.headline)
                                    Text(pc.ipAddress)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if pcStore.selectedPCId == pc.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                pcStore.select(pc)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pcStore.delete(pc)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    editingPC = pc
                                    showingEditSheet = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }

                // iPhone IP section
                Section("My iPhone") {
                    HStack {
                        Text("IP Address")
                        Spacer()
                        if let ip = NetworkUtils.getWiFiIPAddress() {
                            Text(ip)
                                .foregroundColor(.secondary)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            Text("Not connected to WiFi")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("PCs")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                if let pc = editingPC {
                    EditPCView(pcStore: pcStore, pc: pc, isPresented: $showingEditSheet)
                }
            }
        }
    }

    private func addPC() {
        guard !newName.isEmpty && !newIP.isEmpty else { return }
        focusedField = nil  // Dismiss keyboard
        pcStore.add(name: newName.trimmingCharacters(in: .whitespaces),
                    ipAddress: newIP.trimmingCharacters(in: .whitespaces))
        newName = ""
        newIP = ""
    }
}

struct EditPCView: View {
    @ObservedObject var pcStore: PCStore
    @State var pc: SavedPC
    @Binding var isPresented: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section("PC Details") {
                    TextField("Name", text: $pc.name)
                        .textInputAutocapitalization(.words)
                        .focused($isFocused)

                    TextField("IP Address", text: $pc.ipAddress)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                }
            }
            .navigationTitle("Edit PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        pcStore.update(pc)
                        isPresented = false
                    }
                    .disabled(pc.name.isEmpty || pc.ipAddress.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isFocused = false
                    }
                }
            }
        }
    }
}

#Preview {
    PCsView(pcStore: PCStore())
}
