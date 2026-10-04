import Foundation
import Testing
@testable import AutoLearnCore

// Boss-written. The AI reviewer's rejections proved unreliable, so they stay in the review
// list, unticked, for the user to decide.

// MARK: - The changed words, taken from the diff

@Test func theChangedWordComesOutOfItsContext() {
    let pair = CorrectionDiffEngine.changedPair(
        original: "open it in Fig ma desktop",
        corrected: "open it in Figma desktop")
    #expect(pair?.source == "Fig ma")
    #expect(pair?.destination == "Figma")
}

@Test func japaneseContextIsTrimmedToo() {
    let pair = CorrectionDiffEngine.changedPair(
        original: "おそらくゲンマは— まともに", corrected: "おそらくGemmaは— まともに")
    #expect(pair?.source == "ゲンマ")
    #expect(pair?.destination == "Gemma")
}

@Test func severalChangesAreKeptAsOneStretch() {
    let pair = CorrectionDiffEngine.changedPair(
        original: "ticket draining speed if— Flow like this",
        corrected: "ticket draining speed is— slow like this")
    #expect(pair?.source.hasPrefix("if") == true)
    #expect(pair?.destination.hasSuffix("slow") == true)
}

@Test func nothingChangedGivesNothing() {
    #expect(CorrectionDiffEngine.changedPair(original: "same text", corrected: "same text") == nil)
    #expect(CorrectionDiffEngine.changedPair(original: "text", corrected: "") == nil)
}

// MARK: - The review list keeps what the reviewer refused, unticked

private func temporaryStore() -> (AutoLearnReviewProposalStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("proposals-\(UUID().uuidString)/auto-learn-review-proposals.json")
    return (AutoLearnReviewProposalStore(fileURL: url), url)
}

@Test func aRejectedCorrectionBecomesAnUntickedProposal() async throws {
    let (store, url) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let kept = AutoLearnReviewCandidate(candidateID: UUID(), originalText: "how Jemma performed",
                                        correctedText: "how Gemma performed")
    let refused = AutoLearnReviewCandidate(candidateID: UUID(),
                                           originalText: "open it in Fig ma desktop",
                                           correctedText: "open it in Figma desktop")
    try await store.append(decisions: [
        AutoLearnReviewDecision(candidateID: kept.candidateID, learningAction: .addReplacementOnly,
                                incorrectTextToReplace: "Jemma", correctedVocabularyTerm: "Gemma"),
        AutoLearnReviewDecision(candidateID: refused.candidateID, learningAction: .rejectCorrection,
                                incorrectTextToReplace: nil, correctedVocabularyTerm: nil),
    ], candidates: [kept, refused])

    let proposals = try await store.all()
    #expect(proposals.count == 2)

    let accepted = try #require(proposals.first { $0.candidateID == kept.candidateID })
    #expect(accepted.isSelectedByDefault)
    #expect(accepted.reviewerRejected != true)

    let rejected = try #require(proposals.first { $0.candidateID == refused.candidateID })
    #expect(!rejected.isSelectedByDefault)
    #expect(rejected.reviewerRejected == true)
    #expect(rejected.incorrectTextToReplace == "Fig ma")
    #expect(rejected.correctedVocabularyTerm == "Figma")
    #expect(rejected.addsReplacement)
}

@Test func theMarkSurvivesSavingAndEditing() async throws {
    let (store, url) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let refused = AutoLearnReviewCandidate(candidateID: UUID(), originalText: "おそらくゲンマは",
                                           correctedText: "おそらくGemmaは")
    try await store.append(decisions: [
        AutoLearnReviewDecision(candidateID: refused.candidateID, learningAction: .rejectCorrection,
                                incorrectTextToReplace: nil, correctedVocabularyTerm: nil),
    ], candidates: [refused])
    let id = try #require(try await store.all().first?.id)
    try await store.update(proposalID: id, incorrectTextToReplace: "ゲンマ", correctedVocabularyTerm: "Gemma 4")

    let reloaded = AutoLearnReviewProposalStore(fileURL: url)
    let proposal = try #require(try await reloaded.all().first)
    #expect(proposal.reviewerRejected == true)
    #expect(proposal.correctedVocabularyTerm == "Gemma 4")
}

@Test func proposalsSavedBeforeTheMarkExistStillLoad() async throws {
    let (store, url) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let old = """
    [{"candidateID":"\(UUID().uuidString)","correctedText":"VoiceInk","correctedVocabularyTerm":"VoiceInk",
      "id":"\(UUID().uuidString)","incorrectTextToReplace":"ボイスインク",
      "learningAction":"addReplacementAndVocabulary","originalText":"ボイスインク"}]
    """
    try old.write(to: url, atomically: true, encoding: .utf8)
    let proposal = try #require(try await store.all().first)
    #expect(proposal.reviewerRejected == nil)
    #expect(proposal.isSelectedByDefault)
}

@Test func aRejectionWithNothingToLearnIsDropped() async throws {
    let (store, url) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let same = AutoLearnReviewCandidate(candidateID: UUID(), originalText: "no change", correctedText: "no change")
    try await store.append(decisions: [
        AutoLearnReviewDecision(candidateID: same.candidateID, learningAction: .rejectCorrection,
                                incorrectTextToReplace: nil, correctedVocabularyTerm: nil),
    ], candidates: [same])
    #expect(try await store.all().isEmpty)
}
