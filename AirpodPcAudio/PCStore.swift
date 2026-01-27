import Foundation

struct SavedPC: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var ipAddress: String

    init(id: UUID = UUID(), name: String, ipAddress: String) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
    }
}

class PCStore: ObservableObject {
    @Published var pcs: [SavedPC] = []
    @Published var selectedPCId: UUID?

    private let saveKey = "savedPCs"
    private let selectedKey = "selectedPCId"

    init() {
        load()
    }

    var selectedPC: SavedPC? {
        guard let id = selectedPCId else { return nil }
        return pcs.first { $0.id == id }
    }

    func add(name: String, ipAddress: String) {
        let pc = SavedPC(name: name, ipAddress: ipAddress)
        pcs.append(pc)
        if pcs.count == 1 {
            selectedPCId = pc.id
        }
        save()
    }

    func update(_ pc: SavedPC) {
        if let index = pcs.firstIndex(where: { $0.id == pc.id }) {
            pcs[index] = pc
            save()
        }
    }

    func delete(_ pc: SavedPC) {
        pcs.removeAll { $0.id == pc.id }
        if selectedPCId == pc.id {
            selectedPCId = pcs.first?.id
        }
        save()
    }

    func select(_ pc: SavedPC) {
        selectedPCId = pc.id
        saveSelectedId()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(pcs) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
        saveSelectedId()
    }

    private func saveSelectedId() {
        if let id = selectedPCId {
            UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SavedPC].self, from: data) {
            pcs = decoded
        }
        if let idString = UserDefaults.standard.string(forKey: selectedKey),
           let id = UUID(uuidString: idString) {
            selectedPCId = id
        } else {
            selectedPCId = pcs.first?.id
        }
    }
}
