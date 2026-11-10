import Foundation

/// Persistent cache for dictionary entries. Kept separate from
/// `TranslationCache`: dictionary payloads are richer than
/// `TranslationOutput`, and they should not affect the AI/API cache counters.
///
/// Best-effort, like the translation cache: a missing/corrupt file just means
/// a network lookup. TTL is 90 days and the LRU cap is 1000 entries; the
/// payload is already trimmed by the source parser, so the file stays small.
@MainActor
final class DictionaryCache {
    static let shared = DictionaryCache()

    private struct StoredEntry: Codable {
        let key: String
        let createdAt: Date
        var lastUsedAt: Date
        let entry: DictionaryEntry
    }

    private var entries: [String: StoredEntry] = [:]
    private let storageURL: URL
    private let ttl: TimeInterval = 90 * 24 * 3600
    private let maxEntries = 1000
    private var saveTask: Task<Void, Never>?

    private init() {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(Branding.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("dictionary.json")
        load()
    }

    // MARK: - Keys

    static func key(for text: String) -> String {
        "v1|dict|en|\(normalize(text))"
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: - Access

    func get(key: String) -> DictionaryEntry? {
        guard var stored = entries[key] else { return nil }
        guard Date().timeIntervalSince(stored.createdAt) <= ttl else {
            entries.removeValue(forKey: key)
            scheduleSave()
            return nil
        }
        stored.lastUsedAt = Date()
        entries[key] = stored
        return stored.entry
    }

    func put(key: String, entry: DictionaryEntry) {
        entries[key] = StoredEntry(
            key: key,
            createdAt: Date(),
            lastUsedAt: Date(),
            entry: entry
        )
        evictIfNeeded()
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([String: StoredEntry].self, from: data) else {
            return
        }
        let now = Date()
        entries = decoded.filter { now.timeIntervalSince($0.value.createdAt) <= ttl }
        if entries.count != decoded.count {
            scheduleSave()
        }
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        let overflow = entries.count - maxEntries
        let oldest = entries
            .sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
            .prefix(overflow)
        for (key, _) in oldest {
            entries.removeValue(forKey: key)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let url = storageURL
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
