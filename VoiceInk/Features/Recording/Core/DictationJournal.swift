import Foundation

/// One line per dictation, so a bad day can be read back instead of guessed at.
///
/// The unified log keeps VoiceInk's messages only for a few days and needs `log show`
/// queries to read, so a misbehaving week is hard to reconstruct from it. This
/// appends a JSON line per attempt to ~/.config/dictation/dictation-log.jsonl, next to the
/// shared vocabulary, where a script can read it:
///
///     {"at":"2026-09-20T18:21:10Z","clip_s":16.8,"level_db":-41.3,"api_s":0.12,
///      "path":"stream","model":"Soniox V5","chars":142,"fallback":null,"error":null}
///
/// `path` is what actually produced the text: "stream" when the websocket finalised it,
/// "upload" when it fell back to a file upload (seconds instead of a tenth of one), or
/// "local" when the cloud failed and the local model took over.
struct DictationJournalEntry {
    var clipSeconds: Double?
    var levelDecibels: Double?
    var apiSeconds: Double?
    var model: String
    var characters: Int
    var fallbackReason: String?
    var error: String?

    /// Whether the text came back within the streaming window or from a slower path.
    var path: String {
        if fallbackReason != nil { return "local" }
        guard let apiSeconds else { return "unknown" }
        return apiSeconds < DictationJournal.streamingCeilingSeconds ? "stream" : "upload"
    }
}

enum DictationJournal {
    /// Above this, the websocket did not finalise and a file upload did the work.
    /// Measured in real use: streamed results land in 0.08-0.26 s, uploads in 3-8 s.
    static let streamingCeilingSeconds = 1.0

    static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/dictation/dictation-log.jsonl")

    /// Keeps the file from growing without bound; a week of heavy use is ~1000 lines.
    static let maximumLines = 5000

    static func line(for entry: DictationJournalEntry, at date: Date) -> String {
        var fields: [String] = ["\"at\":\"\(iso.string(from: date))\""]
        func add(_ key: String, _ value: Double?, decimals: Int) {
            guard let value, value.isFinite else { return }
            fields.append("\"\(key)\":\(String(format: "%.\(decimals)f", value))")
        }
        add("clip_s", entry.clipSeconds, decimals: 2)
        add("level_db", entry.levelDecibels, decimals: 1)
        add("api_s", entry.apiSeconds, decimals: 3)
        fields.append("\"path\":\"\(entry.path)\"")
        fields.append("\"model\":\(quoted(entry.model))")
        fields.append("\"chars\":\(entry.characters)")
        fields.append("\"fallback\":\(entry.fallbackReason.map(quoted) ?? "null")")
        fields.append("\"error\":\(entry.error.map(quoted) ?? "null")")
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func append(_ entry: DictationJournalEntry, at date: Date = Date(), to url: URL = defaultURL) {
        let text = line(for: entry, at: date) + "\n"
        guard let data = text.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            trimIfNeeded(url)
        } catch {
            // Diagnostics must never interfere with dictation itself.
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maximumLines else { return }
        lines = Array(lines.suffix(maximumLines))
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
