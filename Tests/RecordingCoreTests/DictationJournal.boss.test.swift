import Foundation
import Testing
@testable import RecordingCore

// The journal keeps a lasting, script-readable record of every dictation. It
// must be readable by a script, and it must never be the reason a dictation fails.

private let moment = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09-10T00:26:40Z

private func entry(apiSeconds: Double? = 0.12, fallback: String? = nil, error: String? = nil,
                   characters: Int = 10) -> DictationJournalEntry {
    DictationJournalEntry(clipSeconds: 16.8, levelDecibels: -41.3, apiSeconds: apiSeconds,
                          model: "Soniox V5", characters: characters,
                          fallbackReason: fallback, error: error)
}

@Test func aLineIsOneJsonObjectWithTheFactsWeNeed() throws {
    let line = DictationJournal.line(for: entry(), at: moment)
    let parsed = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(parsed["at"] as? String == "2026-09-10T00:26:40Z")
    #expect(parsed["clip_s"] as? Double == 16.8)
    #expect(parsed["level_db"] as? Double == -41.3)
    #expect(parsed["api_s"] as? Double == 0.12)
    #expect(parsed["path"] as? String == "stream")
    #expect(parsed["model"] as? String == "Soniox V5")
    #expect(parsed["chars"] as? Int == 10)
    #expect(parsed["fallback"] is NSNull)
    #expect(parsed["error"] is NSNull)
}

@Test func theSlowPathIsDistinguishableFromTheFastOne() {
    #expect(entry(apiSeconds: 0.12).path == "stream")
    #expect(entry(apiSeconds: 0.99).path == "stream")
    #expect(entry(apiSeconds: 4.65).path == "upload")      // the slow first press after a pause
    #expect(entry(apiSeconds: nil).path == "unknown")
    #expect(entry(apiSeconds: 0.12, fallback: "offline").path == "local")
}

@Test func failuresAreRecordedToo() throws {
    let line = DictationJournal.line(for: entry(apiSeconds: nil, error: "No speech detected", characters: 0),
                                     at: moment)
    let parsed = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(parsed["error"] as? String == "No speech detected")
    #expect(parsed["chars"] as? Int == 0)
    #expect(parsed["api_s"] == nil)                         // absent rather than a made-up zero
}

@Test func quotesAndNewlinesCannotBreakTheFile() throws {
    var broken = entry()
    broken.model = "Say \"hello\"\nand more \\ here"
    let line = DictationJournal.line(for: broken, at: moment)
    #expect(!line.contains("\n"))
    let parsed = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(parsed["model"] as? String == "Say \"hello\" and more \\ here")
}

@Test func nonFiniteNumbersAreLeftOutRatherThanWritten() throws {
    var odd = entry()
    odd.clipSeconds = .nan
    odd.levelDecibels = .infinity
    let line = DictationJournal.line(for: odd, at: moment)
    let parsed = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(parsed["clip_s"] == nil)
    #expect(parsed["level_db"] == nil)
}

@Test func appendingWritesOneLinePerDictationAndKeepsThemReadable() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-\(UUID().uuidString)/dictation-log.jsonl")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    DictationJournal.append(entry(), at: moment, to: url)                      // creates the folder
    DictationJournal.append(entry(apiSeconds: 4.65), at: moment, to: url)

    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    for line in lines {
        #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
    }
}

@Test func anUnwritableLocationIsSurvived() {
    // Dictation must not fail because diagnostics could not be written.
    DictationJournal.append(entry(), at: moment, to: URL(fileURLWithPath: "/dev/null/nope/log.jsonl"))
}
