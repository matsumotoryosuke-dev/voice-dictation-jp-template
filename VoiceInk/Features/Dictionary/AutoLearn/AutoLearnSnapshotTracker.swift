import Foundation

/// Follows a pasted stretch while the user edits it and keeps the last state that is
/// still recognisably the same text.
///
/// Auto Learn used to read the field once, at the end: when focus left, or 60 seconds
/// later. In a chat box the user fixes the word and presses Return, the box empties
/// and focus stays, so that one late read found nothing to compare. The edit worth
/// learning is the one just before the text disappeared, so every read goes through
/// here and the tracker says when the paste is gone.
struct AutoLearnSnapshotTracker {
    enum Step: Equatable {
        case keepWatching
        case finish(reason: String)
    }

    let baselineFieldText: String
    let pastedRange: NSRange
    let originalPastedText: String
    private(set) var lastGood: AutoLearnFieldSnapshot?
    private(set) var finishReason: String?

    init(baselineFieldText: String, pastedRange: NSRange, originalPastedText: String) {
        self.baselineFieldText = baselineFieldText
        self.pastedRange = pastedRange
        self.originalPastedText = originalPastedText
    }

    mutating func observe(_ fieldText: String) -> Step {
        if let finishReason { return .finish(reason: finishReason) }

        let snapshot = AutoLearnFieldSnapshot(
            baselineFieldText: baselineFieldText,
            finalFieldText: fieldText,
            pastedRange: pastedRange,
            originalPastedText: originalPastedText
        )

        switch FinalSnapshotDiffEngine.assess(snapshot) {
        case .unchanged:
            // Nothing edited yet, or every edit undone: there is nothing to learn.
            lastGood = nil
            return .keepWatching
        case .lost(let why):
            return finish("paste-gone:\(why)")
        case let .revised(original, corrected):
            guard !corrected.isEmpty else { return finish("paste-emptied") }
            guard Self.isRecognisablyTheSame(original, corrected) else {
                return finish("replaced-by-other-text")
            }
            lastGood = snapshot
            return .keepWatching
        }
    }

    /// A reading could not be taken at all (the element went away, say). Nothing more
    /// will be learned from this paste.
    mutating func targetUnreadable() -> Step {
        finish("target-unreadable")
    }

    private mutating func finish(_ reason: String) -> Step {
        finishReason = reason
        return .finish(reason: reason)
    }

    /// Whether the edited text is the paste with corrections, rather than whatever the
    /// user typed next after sending it. Half of the pasted words must survive. A paste
    /// of three words or fewer can lose every one to a single correction (ジェミニ → Gemini),
    /// so it only has to stay about the same size.
    static func isRecognisablyTheSame(_ original: String, _ corrected: String) -> Bool {
        let originalWords = CorrectionDiffEngine.segmentTexts(in: original)
        guard !originalWords.isEmpty else { return false }

        if originalWords.count <= 3 {
            return corrected.count <= max(original.count * 3, 24)
        }

        var available: [String: Int] = [:]
        for word in CorrectionDiffEngine.segmentTexts(in: corrected) {
            available[word, default: 0] += 1
        }
        var kept = 0
        for word in originalWords where (available[word] ?? 0) > 0 {
            available[word]! -= 1
            kept += 1
        }
        return kept * 2 >= originalWords.count
    }
}
