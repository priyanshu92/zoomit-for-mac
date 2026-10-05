import Foundation

public enum TextCaptureHistory {
    public static let defaultLimit = 100

    /// Newest-first insert. Capturing the same text again moves it to the top instead of
    /// adding a duplicate row, and the list is trimmed to `limit` entries.
    public static func inserting(
        _ record: TextCaptureRecord,
        into records: [TextCaptureRecord],
        limit: Int = defaultLimit
    ) -> [TextCaptureRecord] {
        var updated = records.filter { $0.text != record.text && $0.id != record.id }
        updated.insert(record, at: 0)
        let cappedLimit = max(limit, 1)
        if updated.count > cappedLimit {
            updated.removeLast(updated.count - cappedLimit)
        }
        return updated
    }

    /// Filters by kind (nil means all kinds) and a case- and diacritic-insensitive query
    /// matched against the captured text and its source name.
    public static func filtered(
        _ records: [TextCaptureRecord],
        kind: TextCaptureKind?,
        query: String
    ) -> [TextCaptureRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            if let kind, record.kind != kind {
                return false
            }
            return matches(record, query: trimmedQuery)
        }
    }

    public static func counts(in records: [TextCaptureRecord]) -> [TextCaptureKind: Int] {
        records.reduce(into: [:]) { counts, record in
            counts[record.kind, default: 0] += 1
        }
    }

    private static func matches(_ record: TextCaptureRecord, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if record.text.range(of: query, options: options) != nil {
            return true
        }
        return record.sourceName?.range(of: query, options: options) != nil
    }
}

public protocol TextCaptureHistoryStore: AnyObject, Sendable {
    /// Records, newest first.
    func load() -> [TextCaptureRecord]
    func append(_ record: TextCaptureRecord) throws
    func remove(id: UUID) throws
    func removeAll() throws
}

/// Stores history as JSON in Application Support rather than `UserDefaults`: a single
/// full-screen OCR result can be several kilobytes, and the preferences plist is loaded
/// in full on every launch.
public final class FileTextCaptureHistoryStore: TextCaptureHistoryStore, @unchecked Sendable {
    public static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZoomIt for Mac", isDirectory: true)
            .appendingPathComponent("TextCaptureHistory.json", isDirectory: false)
    }

    private let fileURL: URL
    private let limit: Int
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL = FileTextCaptureHistoryStore.defaultFileURL, limit: Int = TextCaptureHistory.defaultLimit) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public func load() -> [TextCaptureRecord] {
        lock.lock()
        defer { lock.unlock() }
        return unlockedLoad()
    }

    public func append(_ record: TextCaptureRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try unlockedSave(TextCaptureHistory.inserting(record, into: unlockedLoad(), limit: limit))
    }

    public func remove(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try unlockedSave(unlockedLoad().filter { $0.id != id })
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func unlockedLoad() -> [TextCaptureRecord] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let entries = try? decoder.decode([LossyRecord].self, from: data)
        else {
            return []
        }
        return entries.compactMap(\.record)
    }

    private func unlockedSave(_ records: [TextCaptureRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
        // Captures can contain passwords or other private text (a Wi-Fi sticker, a 2FA
        // backup code), so keep the file readable by the owner only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Decodes one history entry without failing the whole file. A record written by a newer
/// build (for example with a kind this build does not know) is skipped instead of wiping
/// every other entry.
private struct LossyRecord: Decodable {
    let record: TextCaptureRecord?

    init(from decoder: Decoder) throws {
        record = try? TextCaptureRecord(from: decoder)
    }
}
