import Foundation

@MainActor
final class TranscriptHistoryStore: ObservableObject {
    static let shared = TranscriptHistoryStore()

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let text: String
        let createdAt: Date

        init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let defaults = UserDefaults.standard
    private let maxEntries = 20
    private let key = "OpenAssist.transcriptHistory"

    private init() {
        load()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.insert(Entry(text: trimmed), at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func remove(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        save()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else {
            entries = []
            return
        }

        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            entries = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: key)
        } catch {
            // best effort persistence
        }
    }
}
