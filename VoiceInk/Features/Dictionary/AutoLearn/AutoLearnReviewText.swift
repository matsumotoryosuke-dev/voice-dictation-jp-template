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
