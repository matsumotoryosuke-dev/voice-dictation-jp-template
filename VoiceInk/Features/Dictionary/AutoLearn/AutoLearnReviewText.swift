import Foundation

/// Text handling around the Auto Learn review call, kept free of app types so the test
/// package can build it.
enum AutoLearnReviewText {
    /// Local models answer with the JSON inside a markdown fence however firmly the
    /// prompt forbids it. gemma4:12b did so on every run in testing, and the review
    /// then failed as "invalid response" after doing all the work. One fence that wraps
    /// the whole answer is unwrapped; anything else is returned as it came.
    static func unwrappingCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6 else {
            return trimmed
        }
        guard let firstNewline = trimmed.firstIndex(of: "\n") else { return trimmed }
        let body = trimmed[trimmed.index(after: firstNewline)...].dropLast(3)
        guard !body.contains("```") else { return trimmed }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Decision: Equatable {
        let candidateID: Int
        let learningAction: AutoLearnReviewAction
        let incorrectTextToReplace: String?
        let correctedVocabularyTerm: String?
    }

    /// Reads the reviewer's answer one decision at a time. The upstream decoder failed the
    /// whole batch when any one decision left out a null field or added a key, so a
    /// whole queue of corrections could sit behind one malformed line. Returns nil
    /// only when the answer is not a JSON array at all; `dropped` says why any single
    /// decision was skipped, without its text.
    static func decisions(from text: String) -> (decisions: [Decision], dropped: [String])? {
        let payload = unwrappingCodeFence(text)
        guard let array = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [Any] else {
            return nil
        }
        var decisions: [Decision] = []
        var dropped: [String] = []
        for element in array {
            guard let object = element as? [String: Any] else {
                dropped.append("not-an-object")
                continue
            }
            let id: Int?
            switch object["candidateID"] {
            case let value as Int: id = value
            case let value as String: id = Int(value)
            default: id = nil
            }
            guard let candidateID = id else {
                dropped.append("missing-candidate-id")
                continue
            }
            guard let actionName = object["learningAction"] as? String,
                let action = AutoLearnReviewAction(rawValue: actionName)
            else {
                dropped.append("unknown-action")
                continue
            }
            decisions.append(Decision(
                candidateID: candidateID,
                learningAction: action,
                incorrectTextToReplace: object["incorrectTextToReplace"] as? String,
                correctedVocabularyTerm: object["correctedVocabularyTerm"] as? String
            ))
        }
        return (decisions, dropped)
    }

    /// What a review produced once its single retry is spent.
    struct Outcome: Equatable {
        /// Every usable decision, keyed to the candidate's index in the batch.
        let decisions: [Decision]
        /// Indices still without a decision. They stay queued; they are not rejections.
        let undecided: [Int]
        let retried: Bool
    }

    /// Asks for a decision on every candidate, then asks once more about the ones the answer
    /// left out: an empty list, a short list, IDs that match no candidate, or an answer that
    /// is not a list at all. An answer that leaves corrections out used to put them in the
    /// review list as "AI rejected", which reads as a verdict the AI never gave.
    static func reviewWithOneRetry(
        candidateCount: Int,
        ask: ([Int]) async throws -> String
    ) async throws -> Outcome {
        let everyCandidate = Array(0..<candidateCount)
        let first = usableDecisions(from: try await ask(everyCandidate), asked: everyCandidate)
        let missing = undecidedIndices(first, asked: everyCandidate)
        guard !missing.isEmpty else {
            return Outcome(decisions: first, undecided: [], retried: false)
        }
        let second = usableDecisions(from: try await ask(missing), asked: missing)
        return Outcome(
            decisions: first + second,
            undecided: undecidedIndices(second, asked: missing),
            retried: true
        )
    }

    /// Decisions about a candidate that was asked about; any other ID matches nothing.
    static func usableDecisions(from text: String, asked: [Int]) -> [Decision] {
        let askedIDs = Set(asked)
        return (decisions(from: text)?.decisions ?? []).filter { askedIDs.contains($0.candidateID) }
    }

    /// The asked candidates that no decision names, in the order asked.
    static func undecidedIndices(_ decisions: [Decision], asked: [Int]) -> [Int] {
        let named = Set(decisions.map(\.candidateID))
        return asked.filter { !named.contains($0) }
    }

    /// True when the review list holds corrections and the AI accepted none of them, so the
    /// panel can warn before "Dismiss All" throws away fixes the AI was wrong about.
    static func acceptedNone(_ proposals: [AutoLearnReviewProposal]) -> Bool {
        !proposals.isEmpty && proposals.allSatisfy { !$0.isSelectedByDefault }
    }

    /// Terms the user has already confirmed, for the reviewer to recognise its own
    /// vocabulary. In testing, gemma4:12b rejected corrections toward a brand name that was
    /// already in the dictionary; given the vocabulary it accepted them and added nothing
    /// wrong.
    static func knownVocabulary(from terms: [String], limit: Int = 200) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
            if result.count == limit { break }
        }
        return result
    }
}
