import Foundation

enum AutoLearnTextNormalizer {
    /// Produces a comparison-only representation of text exposed by editable
    /// web controls. The original field value remains untouched for anchoring.
    static func accessibilityComparable(_ text: String) -> String {
        let normalizedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")

        let normalizedBlankLines = normalizedLineEndings
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let value = String(line)
                return value.trimmingCharacters(in: .whitespaces).isEmpty ? "" : value
            }
            .joined(separator: "\n")

        return normalizedBlankLines
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

struct AutoLearnPasteToken: Hashable, Sendable {
    let id: UUID
}

struct AutoLearnRevision: Sendable {
    let original: String
    let corrected: String
}

struct AutoLearnFieldSnapshot: Sendable {
    let baselineFieldText: String
    let finalFieldText: String
    let pastedRange: NSRange
    let originalPastedText: String
}

struct DetectedCorrectionCandidate: Hashable, Sendable {
    let originalText: String
    let correctedText: String
}

struct AutoLearnReviewCandidate: Sendable {
    let candidateID: UUID
    let originalText: String
    let correctedText: String
}

enum AutoLearnReviewAction: String, Codable, Sendable {
    case addReplacementAndVocabulary
    case addReplacementOnly
    case addVocabularyOnly
    case rejectCorrection
}

struct AutoLearnReviewDecision: Sendable {
    let candidateID: UUID
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

enum AutoLearnUnresolvedReason: String, Sendable {
    case missingDecision
    case conflictingDecisions
    case missingRequiredActionValues
    case invalidRequiredActionValues
}

struct AutoLearnUnresolvedReview: Sendable {
    let candidateID: UUID
    let reason: AutoLearnUnresolvedReason
    let learningAction: AutoLearnReviewAction?
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

struct AutoLearnReviewResult: Sendable {
    let reviewDecisions: [AutoLearnReviewDecision]
    let unresolvedReviews: [AutoLearnUnresolvedReview]
}

struct AutoLearnReviewProposal: Codable, Identifiable, Sendable {
    let id: UUID
    let candidateID: UUID
    let originalText: String
    let correctedText: String
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
    /// The AI reviewer said no, but the user decides: in testing gemma4:12b accepted 3, 5
    /// and 2 of the same 14 corrections on three runs and threw away clear brand-name fixes.
    /// Optional so proposals saved before this field existed still load.
    var reviewerRejected: Bool? = nil

    /// Shown unticked, so applying the list as-is never adds what the reviewer refused.
    var isSelectedByDefault: Bool { reviewerRejected != true }

    var addsReplacement: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addReplacementOnly
    }

    var addsVocabulary: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addVocabularyOnly
    }

    var reviewCandidate: AutoLearnReviewCandidate {
        AutoLearnReviewCandidate(
            candidateID: candidateID,
            originalText: originalText,
            correctedText: correctedText
        )
    }

    var reviewDecision: AutoLearnReviewDecision {
        AutoLearnReviewDecision(
            candidateID: candidateID,
            learningAction: learningAction,
            incorrectTextToReplace: incorrectTextToReplace,
            correctedVocabularyTerm: correctedVocabularyTerm
        )
    }
}

struct AutoLearnReviewSelection: Sendable {
    let proposalID: UUID
    let includesReplacement: Bool
    let includesVocabulary: Bool
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String
}

struct AutoLearnMutationSummary: Sendable {
    let createdCount: Int
    let updatedCount: Int
    let vocabularyCount: Int
    let learnedCorrections: [AutoLearnAppliedCorrection]

    var hasChanges: Bool {
        createdCount > 0 || updatedCount > 0 || vocabularyCount > 0
    }

    static let empty = AutoLearnMutationSummary(
        createdCount: 0,
        updatedCount: 0,
        vocabularyCount: 0,
        learnedCorrections: []
    )
}

struct AutoLearnAppliedCorrection: Sendable {
    let incorrectTextToReplace: String
    let correctedVocabularyTerm: String
    let replacementSourceWasAdded: Bool
    let vocabularyCreationDate: Date?
}

enum AutoLearnReviewSchedule: String, CaseIterable, Identifiable {
    case immediately
    case manually

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .manually: String(localized: "Manually")
        }
    }

}

enum AutoLearnLimits {
    static let observationDurationNanoseconds: UInt64 = 60_000_000_000
    static let verificationDelayNanoseconds: UInt64 = 120_000_000
    static let focusChangeGraceNanoseconds: UInt64 = 250_000_000
    static let accessibilityTimeoutSeconds: Float = 0.20
    static let captureAccessibilityTimeoutSeconds: Float = 0.10
    static let maximumFieldUTF16Length = 100_000
    static let maximumPastedCharacters = 12_000
    static let maximumDiffSegments = 2_048
    static let maximumCandidateCharacters = 256
    static let maximumCandidateSegments = 24
    static let reviewContextSegmentsPerSide = 3
    static let maximumUnspacedCandidateCharacters = 32
    static let maximumReviewBatchCandidates = 100
    /// The review is not the 7-second enhancement call it used to share a timeout with:
    /// gemma4:12b needs about 4 s to load and 30 s to judge 14 corrections on an M4 Pro
    /// Mac mini, so every Review Now failed as a timeout. It runs in the background.
    static let reviewTimeoutSeconds: TimeInterval = 180
}
