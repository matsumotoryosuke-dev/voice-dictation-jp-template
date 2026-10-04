import Foundation
import Testing
@testable import DictionaryCore

// The shared file is written by hand and by a second tool, so nothing it contains may
// crash the app or silently drop a name the user taught it.

private func decode(_ json: String) -> SharedVocabulary {
    SharedVocabularyFile.decode(Data(json.utf8))
}

@Test func readsTermsAndCorrections() {
    let vocabulary = decode(#"{"terms":["東京タワー","RE:Issue"],"corrections":{"東京たわー":"東京タワー"}}"#)
    #expect(vocabulary.terms == ["東京タワー", "RE:Issue"])
    #expect(vocabulary.corrections == ["東京たわー": "東京タワー"])
}

@Test func rubbishYieldsNothingRatherThanThrowing() {
    #expect(decode("{not json") == SharedVocabulary(terms: [], corrections: [:]))
    #expect(decode("[1,2,3]") == SharedVocabulary(terms: [], corrections: [:]))
    #expect(decode(#"{"terms":"東京タワー","corrections":42}"#) == SharedVocabulary(terms: [], corrections: [:]))
    #expect(SharedVocabularyFile.decode(Data()) == SharedVocabulary(terms: [], corrections: [:]))
}

@Test func skipsEntriesThatCannotBeUsed() {
    let vocabulary = decode(#"""
    {"terms":["  Obsidian  ","",7,null,"Obsidian"],
     "corrections":{"オブシディアン":"Obsidian","同じ":"同じ","":"x","y":"","コンマ, 入り":"Notion","z":5}}
    """#)
    #expect(vocabulary.terms == ["Obsidian"])                       // trimmed, deduplicated
    #expect(vocabulary.corrections == ["オブシディアン": "Obsidian"])  // no self-maps, no empties
    #expect(vocabulary.corrections["コンマ, 入り"] == nil)            // a comma would split the stored sources
}

@Test func roundTripsThroughEncode() throws {
    let vocabulary = SharedVocabulary(terms: ["東京タワー", "note.com"],
                                      corrections: ["東京たわー": "東京タワー", "ノーション": "Notion"])
    let data = try SharedVocabularyFile.encode(vocabulary)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("東京タワー"))                          // readable, not \uXXXX escapes
    #expect(!text.contains("\\u"))
    #expect(!text.contains("\\/"))
    #expect(SharedVocabularyFile.decode(data) == vocabulary)
    #expect(try SharedVocabularyFile.encode(vocabulary) == data)     // stable byte-for-byte
}

@Test func mergeAddsAndNeverDeletes() {
    let file = SharedVocabulary(terms: ["東京タワー"], corrections: ["東京たわー": "東京タワー"])
    let app = SharedVocabulary(terms: ["Soniox"], corrections: ["ソニオックス": "Soniox"])
    let merged = SharedVocabularyFile.merged(file: file, app: app)
    #expect(merged.terms == ["東京タワー", "Soniox"])              // file order first
    #expect(merged.corrections.count == 2)

    // A term only the file knows survives a merge with an app that has never seen it.
    #expect(SharedVocabularyFile.merged(file: file, app: SharedVocabulary(terms: [], corrections: [:])) == file)
}

@Test func theAppWinsWhenBothSidesDisagree() {
    let merged = SharedVocabularyFile.merged(
        file: SharedVocabulary(terms: [], corrections: ["ノーション": "Notion"]),
        app: SharedVocabulary(terms: [], corrections: ["ノーション": "マツモト"]))
    #expect(merged.corrections["ノーション"] == "マツモト")
}

@Test func archiveGroupsEveryWrongFormUnderItsRightOne() {
    let vocabulary = SharedVocabulary(
        terms: ["東京タワー"],
        corrections: ["東京たわー": "東京タワー", "東京 タワー": "東京タワー", "ノーション": "Notion"])
    let archive = SharedVocabularyFile.archive(from: vocabulary, now: Date(timeIntervalSince1970: 0))
    #expect(archive.vocabulary.map(\.term) == ["東京タワー"])
    #expect(archive.replacements.count == 2)
    let brand = archive.replacements.first { $0.replacement == "東京タワー" }
    #expect(brand?.sources == ["東京 タワー", "東京たわー"])       // sorted, both kept
    #expect(brand?.createdAt == Date(timeIntervalSince1970: 0))
}

@Test func archiveAndVocabularyAreInverses() {
    let vocabulary = SharedVocabulary(
        terms: ["Claude Code", "Ollama"],
        corrections: ["クロードコード": "Claude Code", "オリアマ": "Ollama", "オラマ": "Ollama"])
    let round = SharedVocabularyFile.vocabulary(from: SharedVocabularyFile.archive(from: vocabulary, now: Date()))
    #expect(round == vocabulary)
}

@Test func vocabularyFromArchiveDropsUnusableEntries() {
    let archive = DictionaryArchive(
        vocabulary: [DictionaryVocabularyEntry(term: "  Figma ", createdAt: nil),
                     DictionaryVocabularyEntry(term: "   ", createdAt: nil)],
        replacements: [DictionaryReplacementEntry(sources: ["フィグマ", "", "同じ"], replacement: "Figma", createdAt: nil),
                       DictionaryReplacementEntry(sources: ["x"], replacement: "  ", createdAt: nil)])
    let vocabulary = SharedVocabularyFile.vocabulary(from: archive)
    #expect(vocabulary.terms == ["Figma"])
    #expect(vocabulary.corrections == ["フィグマ": "Figma", "同じ": "Figma"])
}

@Test func defaultLocationIsTheSharedPath() {
    #expect(SharedVocabularyFile.defaultURL.path.hasSuffix(".config/dictation/vocabulary.json"))
}
