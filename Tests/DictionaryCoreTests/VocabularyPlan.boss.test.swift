import Foundation
import Testing
@testable import DictionaryCore

// A user deleted two words in VoiceInk and the file put them straight back,
// because the merge could only add. These pin the three-way behaviour that fixes it.

private func vocab(_ terms: [String], _ corrections: [String: String] = [:]) -> SharedVocabulary {
    SharedVocabulary(terms: terms, corrections: corrections)
}

@Test func firstSyncWithNoBaseIsAUnion() {
    let plan = SharedVocabularyFile.plan(base: nil,
                                         file: vocab(["東京タワー"], ["東京たわー": "東京タワー"]),
                                         app: vocab(["Soniox"]))
    #expect(plan.addToApp.terms == ["東京タワー"])
    #expect(plan.removeFromApp == vocab([]))
    #expect(plan.fileContents.terms == ["東京タワー", "Soniox"])
    #expect(plan.fileContents.corrections == ["東京たわー": "東京タワー"])
}

@Test func aWordAddedToTheFileReachesTheApp() {
    let base = vocab(["Obsidian"])
    let plan = SharedVocabularyFile.plan(base: base, file: vocab(["Obsidian", "Soniox"]), app: vocab(["Obsidian"]))
    #expect(plan.addToApp.terms == ["Soniox"])
    #expect(plan.removeFromApp.terms.isEmpty)
    #expect(plan.fileContents.terms == ["Obsidian", "Soniox"])
}

@Test func aWordAddedInTheAppReachesTheFile() {
    let plan = SharedVocabularyFile.plan(base: vocab(["Obsidian"]), file: vocab(["Obsidian"]),
                                         app: vocab(["Obsidian", "誤変換モンスターズ"]))
    #expect(plan.addToApp.terms.isEmpty)
    #expect(plan.removeFromApp.terms.isEmpty)
    #expect(plan.fileContents.terms == ["Obsidian", "誤変換モンスターズ"])
}

@Test func deletingInTheAppRemovesItFromTheFile() {
    let plan = SharedVocabularyFile.plan(base: vocab(["Obsidian", "シンクテスト単語"]),
                                         file: vocab(["Obsidian", "シンクテスト単語"]),
                                         app: vocab(["Obsidian"]))
    #expect(plan.fileContents.terms == ["Obsidian"])
    #expect(plan.addToApp.terms.isEmpty)          // must NOT be re-added, the bug being fixed
    #expect(plan.removeFromApp.terms.isEmpty)     // already gone there
}

@Test func deletingInTheFileRemovesItFromTheApp() {
    let plan = SharedVocabularyFile.plan(base: vocab(["Obsidian", "テスト用の単語"]),
                                         file: vocab(["Obsidian"]),
                                         app: vocab(["Obsidian", "テスト用の単語"]))
    #expect(plan.removeFromApp.terms == ["テスト用の単語"])
    #expect(plan.fileContents.terms == ["Obsidian"])
    #expect(plan.addToApp.terms.isEmpty)
}

@Test func deletedCorrectionsPropagateBothWays() {
    let base = vocab([], ["東京たわー": "東京タワー", "ノーション": "Notion"])
    let fromFile = SharedVocabularyFile.plan(base: base, file: vocab([], ["東京たわー": "東京タワー"]),
                                             app: vocab([], ["東京たわー": "東京タワー", "ノーション": "Notion"]))
    #expect(fromFile.removeFromApp.corrections == ["ノーション": "Notion"])
    #expect(fromFile.fileContents.corrections == ["東京たわー": "東京タワー"])

    let fromApp = SharedVocabularyFile.plan(base: base, file: vocab([], ["東京たわー": "東京タワー", "ノーション": "Notion"]),
                                            app: vocab([], ["東京たわー": "東京タワー"]))
    #expect(fromApp.fileContents.corrections == ["東京たわー": "東京タワー"])
    #expect(fromApp.addToApp.corrections.isEmpty)
}

@Test func aWordGoneFromBothSidesStaysGone() {
    let plan = SharedVocabularyFile.plan(base: vocab(["Obsidian", "probe"]), file: vocab(["Obsidian"]),
                                         app: vocab(["Obsidian"]))
    #expect(plan.fileContents.terms == ["Obsidian"])
    #expect(plan.addToApp == vocab([]))
    #expect(plan.removeFromApp == vocab([]))
    #expect(plan.isEmpty)
}

@Test func theAppWinsWhenACorrectionDisagrees() {
    let plan = SharedVocabularyFile.plan(base: vocab([], ["ノーション": "Notion"]),
                                         file: vocab([], ["ノーション": "Notion"]),
                                         app: vocab([], ["ノーション": "マツモト"]))
    #expect(plan.fileContents.corrections == ["ノーション": "マツモト"])
    #expect(plan.addToApp.corrections["ノーション"] == nil || plan.addToApp.corrections["ノーション"] == "マツモト")
    #expect(plan.removeFromApp.corrections.isEmpty)
}

@Test func nothingToDoIsReportedAsEmpty() {
    let same = vocab(["Obsidian"], ["オブシディアン": "Obsidian"])
    let plan = SharedVocabularyFile.plan(base: same, file: same, app: same)
    #expect(plan.isEmpty)
    #expect(plan.fileContents == same)
}

@Test func anAdditionAndARemovalNeverNameTheSameEntry() {
    let plan = SharedVocabularyFile.plan(base: vocab(["a", "b"]), file: vocab(["a", "c"]), app: vocab(["a", "b"]))
    let added = Set(plan.addToApp.terms)
    let removed = Set(plan.removeFromApp.terms)
    #expect(added.intersection(removed).isEmpty)
    #expect(added == ["c"])
    #expect(removed == ["b"])
}
