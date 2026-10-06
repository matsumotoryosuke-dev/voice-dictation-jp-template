import Foundation
import Testing
@testable import AutoLearnCore

// Boss-written, 2026-10-06. An answer that left corrections without a decision used to put
// them in the review list as "AI rejected", a verdict the AI never gave. Now they get one more
// ask; if still missing, they stay queued and raise the warning. The answers here are
// substituted, except the all-rejected one, which is gemma4:12b's real answer.

/// Stands in for the AI: hands out the given answers in order and records what was asked.
private actor ScriptedReviewer {
    private var answers: [String]
    private(set) var asked: [[Int]] = []

    init(_ answers: [String]) { self.answers = answers }

    func answer(_ indices: [Int]) -> String {
        asked.append(indices)
        return answers.isEmpty ? "[]" : answers.removeFirst()
    }
}

private func answer(_ ids: [Int], _ action: String = "addReplacementOnly") -> String {
    let decisions = ids.map {
        #"{"candidateID":\#($0),"learningAction":"\#(action)","incorrectTextToReplace":"x","correctedVocabularyTerm":"y"}"#
    }
    return "[" + decisions.joined(separator: ",") + "]"
}

// MARK: - Case 1: the answer leaves corrections out, and so does the retry

@Test func anEmptyAnswerTwiceLeavesEveryCorrectionUndecided() async throws {
    let ai = ScriptedReviewer(["[]", "[]"])
    let outcome = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 18) { await ai.answer($0) }
    #expect(outcome.decisions.isEmpty)
    #expect(outcome.undecided == Array(0..<18))
    #expect(outcome.retried)
    #expect(await ai.asked == [Array(0..<18), Array(0..<18)])
}

@Test func aShortListAsksAgainOnlyAboutTheMissing() async throws {
    let ai = ScriptedReviewer([answer([0, 2]), "[]"])
    let outcome = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 3) { await ai.answer($0) }
    #expect(outcome.decisions.map(\.candidateID) == [0, 2])
    #expect(outcome.undecided == [1])
    #expect(await ai.asked == [[0, 1, 2], [1]])
}

@Test func decisionsThatMatchNoCandidateDoNotCount() async throws {
    // Three corrections were sent as 0, 1 and 2; the answer names 3 and 7.
    let ai = ScriptedReviewer([answer([3, 7]), answer([1, 3])])
    let outcome = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 3) { await ai.answer($0) }
    #expect(outcome.decisions.map(\.candidateID) == [1])
    #expect(outcome.undecided == [0, 2])
}

@Test func anUnreadableAnswerCountsAsNoDecision() async throws {
    let ai = ScriptedReviewer(["I cannot help with that.", #"{"decisions": []}"#])
    let outcome = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 2) { await ai.answer($0) }
    #expect(outcome.undecided == [0, 1])
    #expect(outcome.retried)
}

@Test func onlyMissingDecisionsCountAsUndecided() {
    let missing = UUID()
    let conflicting = UUID()
    let result = AutoLearnReviewResult(reviewDecisions: [], unresolvedReviews: [
        AutoLearnUnresolvedReview(candidateID: missing, reason: .missingDecision, learningAction: nil,
                                  incorrectTextToReplace: nil, correctedVocabularyTerm: nil),
        AutoLearnUnresolvedReview(candidateID: conflicting, reason: .conflictingDecisions,
                                  learningAction: .addReplacementOnly, incorrectTextToReplace: "a",
                                  correctedVocabularyTerm: "b"),
    ])
    #expect(result.undecidedCandidateIDs == [missing])
}

@Test func theWarningSaysHowManyAreStillWaiting() {
    let error = AutoLearnUndecidedReviewError(undecidedCount: 18, candidateCount: 18)
    #expect(error.errorDescription == "The AI did not return a decision for 18 of 18 corrections.")
    #expect(error.recoverySuggestion?.contains("not marked as rejected") == true)
    // The Dictionary warning reads both through NSError.
    let bridged = error as NSError
    #expect(bridged.localizedDescription == error.errorDescription)
    #expect(bridged.localizedRecoverySuggestion == error.recoverySuggestion)
}

// MARK: - Case 2: the retry fills the gap

@Test func theRetryFillsWhatTheFirstAnswerLeftOut() async throws {
    let ai = ScriptedReviewer(["[]", answer(Array(0..<18))])
    let outcome = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 18) { await ai.answer($0) }
    #expect(outcome.undecided.isEmpty)
    #expect(outcome.decisions.count == 18)
    #expect(outcome.retried)
}

@Test func aCompleteAnswerIsNotAskedAgain() async throws {
    let ai = ScriptedReviewer([answer([0, 1, 2])])
    let outcome = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 3) { await ai.answer($0) }
    #expect(!outcome.retried)
    #expect(await ai.asked == [[0, 1, 2]])
}

@Test func anAIErrorStillFailsTheReview() async {
    // A timeout or a network failure is not an answer; the review fails as before.
    await #expect(throws: URLError.self) {
        _ = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 2) { _ in
            throw URLError(.timedOut)
        }
    }
}

// MARK: - Case 3: the AI really rejects everything

/// gemma4:12b on Ollama, 2026-10-06, given three ordinary edits (a space, punctuation, "go" →
/// "leave"). The same answer came back on three runs.
private let gemmaRejectsAll = #"[{"candidateID":0,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null},{"candidateID":1,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null},{"candidateID":2,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null}]"#

@Test func aRealRejectionOfEverythingReachesTheListWithTheNotice() async throws {
    let candidates = [
        AutoLearnReviewCandidate(candidateID: UUID(), originalText: "明日の打ち合わせは 三時から です",
                                 correctedText: "明日の打ち合わせは 三時からです"),
        AutoLearnReviewCandidate(candidateID: UUID(), originalText: "資料を送りました 確認して ください",
                                 correctedText: "資料を送りました。確認してください"),
        AutoLearnReviewCandidate(candidateID: UUID(), originalText: "I think we should go now",
                                 correctedText: "I think we should leave now"),
    ]
    let ai = ScriptedReviewer([gemmaRejectsAll])
    let outcome = try await AutoLearnReviewText.reviewWithOneRetry(candidateCount: 3) { await ai.answer($0) }
    #expect(outcome.undecided.isEmpty)
    #expect(!outcome.retried)
    #expect(outcome.decisions.allSatisfy { $0.learningAction == .rejectCorrection })

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("proposals-\(UUID().uuidString)/auto-learn-review-proposals.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AutoLearnReviewProposalStore(fileURL: url)
    try await store.append(decisions: outcome.decisions.map {
        AutoLearnReviewDecision(candidateID: candidates[$0.candidateID].candidateID,
                                learningAction: $0.learningAction,
                                incorrectTextToReplace: $0.incorrectTextToReplace,
                                correctedVocabularyTerm: $0.correctedVocabularyTerm)
    }, candidates: candidates)
    let proposals = try await store.all()
    #expect(!proposals.isEmpty)
    #expect(proposals.allSatisfy { !$0.isSelectedByDefault })
    #expect(AutoLearnReviewText.acceptedNone(proposals))
}

@Test func oneAcceptedCorrectionOrAnEmptyListShowsNoNotice() {
    func proposal(rejected: Bool?) -> AutoLearnReviewProposal {
        AutoLearnReviewProposal(id: UUID(), candidateID: UUID(), originalText: "Jemma",
                                correctedText: "Gemma", learningAction: .addReplacementOnly,
                                incorrectTextToReplace: "Jemma", correctedVocabularyTerm: "Gemma",
                                reviewerRejected: rejected)
    }
    #expect(!AutoLearnReviewText.acceptedNone([]))
    #expect(!AutoLearnReviewText.acceptedNone([proposal(rejected: true), proposal(rejected: nil)]))
    #expect(AutoLearnReviewText.acceptedNone([proposal(rejected: true), proposal(rejected: true)]))
}
