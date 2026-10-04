import Foundation
import Testing
@testable import AutoLearnCore

// Boss-written. The cases are the shape of a real failure: a user corrected a mis-heard
// product name by hand after dictating, and nothing was ever learned.

private func candidates(_ original: String, _ corrected: String,
                        rejected: inout [String]) -> [DetectedCorrectionCandidate] {
    var reasons: [String] = []
    let found = CorrectionDiffEngine.candidates(
        from: AutoLearnRevision(original: original, corrected: corrected),
        rejected: { reasons.append($0) }
    )
    rejected = reasons
    return found
}

private func candidates(_ original: String, _ corrected: String) -> [DetectedCorrectionCandidate] {
    var ignored: [String] = []
    return candidates(original, corrected, rejected: &ignored)
}

// MARK: - Japanese is cut into word-sized pieces

@Test func aOneWordFixInsideAJapaneseSentenceIsOneSmallCandidate() {
    let found = candidates("ジェミニのプロジェクトについて話しました。",
                           "Geminiのプロジェクトについて話しました。")
    #expect(found.count == 1)
    let candidate = try! #require(found.first)
    #expect(candidate.originalText.hasPrefix("ジェミニ"))
    #expect(candidate.correctedText.hasPrefix("Gemini"))
    // Context for the reviewer, not the whole sentence.
    #expect(!candidate.originalText.contains("話しました"))
}

@Test func aSentenceWithTwoFixesGivesTwoCandidates() {
    let found = candidates("グーグルという会社から、Jemini、ジェミニというAIが最近リリースされました。",
                           "グーグルという会社から、Gemini、GeminiというAIが最近リリースされました。")
    #expect(found.count == 2)
    #expect(found.contains { $0.originalText.contains("Jemini") && $0.correctedText.contains("Gemini") })
    #expect(found.contains { $0.originalText.contains("ジェミニ") && $0.correctedText.contains("Gemini") })
}

@Test func aLongUnpunctuatedClauseNoLongerHidesTheFix() {
    // 36 characters with no space or punctuation: before the fix this was one segment,
    // the candidate was the whole clause, and the 32-character unspaced limit dropped it.
    let original = "今日はジェミニを使って新しいワークフローを試してみたんだけどかなり良かった"
    let corrected = original.replacingOccurrences(of: "ジェミニ", with: "Gemini")
    var rejected: [String] = []
    let found = candidates(original, corrected, rejected: &rejected)
    #expect(original.count > 32)
    #expect(found.count == 1, "rejected: \(rejected)")
    #expect(found.first?.correctedText.contains("Gemini") == true)
}

@Test func prolongedSoundMarksStayWithTheirWord() {
    #expect(CorrectionDiffEngine.segmentTexts(in: "データベースのジェミニ")
            == ["データベース", "の", "ジェミニ"])
    #expect(CorrectionDiffEngine.segmentTexts(in: "えーと、M5 Maxで2日")
            == ["えーと", "M5", "Max", "で", "2", "日"])
}

@Test func fullWidthPunctuationSeparates() {
    // Kanji and its kana ending part too (新|しい): the split is by script, not by
    // dictionary word. The reviewer sees three pieces of context either side.
    #expect(CorrectionDiffEngine.segmentTexts(in: "「ジェミニ」（新しいAI）。")
            == ["ジェミニ", "新", "しい", "AI"])
}

@Test func englishStillWorksAsBefore() {
    let found = candidates("I use Jemini for my workflow", "I use Gemini for my workflow")
    #expect(found.count == 1)
    #expect(found.first?.originalText.contains("Jemini") == true)
    #expect(found.first?.correctedText.contains("Gemini") == true)
}

@Test func droppedStretchesSayWhy() {
    var rejected: [String] = []
    _ = candidates("ジェミニです。", "ジェミニです。追加の文。", rejected: &rejected)
    #expect(rejected.contains("insertion-only"))

    let longKatakana = String(repeating: "ア", count: 40)
    _ = candidates("\(longKatakana)です", "テストです", rejected: &rejected)
    #expect(rejected.contains { $0.hasPrefix("unspaced-limit") })
}

// MARK: - The paste is followed until it disappears

private let pasted = "ジェミニのプロジェクトについて話しました。"

private func chatBoxTracker() -> AutoLearnSnapshotTracker {
    // A chat box that was empty before the paste.
    AutoLearnSnapshotTracker(baselineFieldText: pasted,
                             pastedRange: NSRange(location: 0, length: pasted.utf16.count),
                             originalPastedText: pasted)
}

@Test func theFixSurvivesPressingReturnInAChatBox() {
    var tracker = chatBoxTracker()
    #expect(tracker.observe(pasted) == .keepWatching)                 // not edited yet
    #expect(tracker.lastGood == nil)
    #expect(tracker.observe("Gemのプロジェクトについて話しました。") == .keepWatching)   // mid-edit
    #expect(tracker.observe("Geminiのプロジェクトについて話しました。") == .keepWatching)
    #expect(tracker.observe("") == .finish(reason: "paste-emptied"))  // sent, box cleared

    let kept = try! #require(tracker.lastGood)
    #expect(kept.finalFieldText == "Geminiのプロジェクトについて話しました。")
    let revision = try! #require(FinalSnapshotDiffEngine.revision(from: kept))
    let found = CorrectionDiffEngine.candidates(from: revision)
    #expect(found.count == 1)
    #expect(found.first?.correctedText.hasPrefix("Gemini") == true)
}

@Test func theNextMessageIsNotMistakenForACorrection() {
    var tracker = chatBoxTracker()
    _ = tracker.observe("Geminiのプロジェクトについて話しました。")
    // Sent, and the next message typed before we looked again.
    #expect(tracker.observe("明日の打ち合わせは何時からでしたっけ") == .finish(reason: "replaced-by-other-text"))
    #expect(tracker.lastGood?.finalFieldText == "Geminiのプロジェクトについて話しました。")
}

@Test func onceFinishedItStaysFinished() {
    var tracker = chatBoxTracker()
    _ = tracker.observe("Geminiのプロジェクトについて話しました。")
    _ = tracker.observe("")
    #expect(tracker.observe("Geminiのプロジェクトについて話しました。") == .finish(reason: "paste-emptied"))
}

@Test func undoingEveryEditLeavesNothingToLearn() {
    var tracker = chatBoxTracker()
    _ = tracker.observe("Geminiのプロジェクトについて話しました。")
    #expect(tracker.observe(pasted) == .keepWatching)
    #expect(tracker.lastGood == nil)
}

@Test func inADocumentTypingOnAfterThePasteKeepsWatching() {
    let before = "前の段落です。\n"
    let after = "\n次の段落です。"
    let field = before + pasted + after
    var tracker = AutoLearnSnapshotTracker(
        baselineFieldText: field,
        pastedRange: NSRange(location: before.utf16.count, length: pasted.utf16.count),
        originalPastedText: pasted)
    let fixed = before + "Geminiのプロジェクトについて話しました。" + after
    #expect(tracker.observe(fixed) == .keepWatching)
    let typedMore = before + "Geminiのプロジェクトについて話しました。続けて書きます。" + after
    #expect(tracker.observe(typedMore) == .keepWatching)
    #expect(tracker.lastGood?.finalFieldText == typedMore)
}

@Test func editingTheTextAroundThePasteEndsIt() {
    let before = "前の段落です。\n"
    let after = "\n次の段落です。"
    var tracker = AutoLearnSnapshotTracker(
        baselineFieldText: before + pasted + after,
        pastedRange: NSRange(location: before.utf16.count, length: pasted.utf16.count),
        originalPastedText: pasted)
    _ = tracker.observe(before + "Geminiのプロジェクトについて話しました。" + after)
    let step = tracker.observe("全部書き直しました。")
    #expect(step == .finish(reason: "paste-gone:anchor-missing"))
    #expect(tracker.lastGood != nil)
}

@Test func aOneWordPasteCanBeReplacedByItsCorrection() {
    var tracker = AutoLearnSnapshotTracker(baselineFieldText: "AWZ",
                                           pastedRange: NSRange(location: 0, length: 3),
                                           originalPastedText: "AWZ")
    #expect(tracker.observe("AWS") == .keepWatching)
    #expect(tracker.lastGood?.finalFieldText == "AWS")
    #expect(tracker.observe("これは全く別の、ずっと長いメッセージで、訂正ではありません。")
            == .finish(reason: "replaced-by-other-text"))
}

@Test func anUnreadableTargetEndsTheWatch() {
    var tracker = chatBoxTracker()
    _ = tracker.observe("Geminiのプロジェクトについて話しました。")
    #expect(tracker.targetUnreadable() == .finish(reason: "target-unreadable"))
    #expect(tracker.lastGood != nil)
}
