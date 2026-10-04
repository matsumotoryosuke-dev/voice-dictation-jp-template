import Foundation

/// Removes the sounds people make while thinking, in English and Japanese.
///
/// The English side existed already but matched on word boundaries (`\b`), which never
/// occur in Japanese text, so えっと and あのー went straight into the document. Measured on
/// one person's real dictation (48 dictations, 3820 characters): 11 hesitations, 0.76% of the
/// text, one in roughly every four or five dictations.
///
/// Three strengths, because Japanese hedges are also real words:
/// - Pure hesitations (えっと, うーん) go wherever they stand alone.
/// - まあ is a common verbal habit (62 times in one person's 96 dictations), so it goes wherever
///   it starts a phrase or is followed by a comma. まあまあ, the word for "so-so", stays.
/// - あの and その are also "that" (あの件, その件). They go only when a comma follows,
///   which is how the transcriber marks the pause: あの、 was a hedge 37 times in 38.
/// なんか stays: it is too often the real word ("なんかあった").
enum FillerStripper {
    /// Japanese hesitations. Longer forms first so えーっと is not left as っと.
    static let japanese: [String] = [
        "えーっと", "えーと", "えっと", "えと", "えー", "えぇ",
        "あのー", "あのう", "あのぉ",
        "うーん", "うー", "うぅ",
        "あー", "あぁ",
        "んー", "んん",
        "そのー", "そのう",
        "まあ", "まぁ",
        "あの", "その",
    ]

    /// Removed at the start of a phrase or before a comma, not only between boundaries.
    static let habitual: Set<String> = ["まあ", "まぁ"]
    /// Real words too; removed only when a comma after them marks a pause.
    static let commaMarked: Set<String> = ["あの", "その"]
    private static let commas: Set<Character> = ["、", ",", "，"]

    static let english: [String] = [
        "um", "umm", "uhm", "uh", "uhh", "uhhh", "hmm", "hm", "mmm", "mm", "er", "err", "ahh",
    ]

    /// Characters a filler may sit against. A Japanese filler is only removed at one of
    /// these boundaries, so a run of kana inside a real word is never touched.
    private static let boundaries = Set("、。，．！？!?…「」『』（）()〜~ \t\n\r")

    static func strip(_ text: String, japanese japaneseFillers: [String] = japanese,
                      english englishFillers: [String] = english) -> String {
        var result = stripJapanese(text, fillers: japaneseFillers.sorted { $0.count > $1.count })
        result = stripEnglish(result, fillers: englishFillers)
        return tidy(result)
    }

    private static func stripJapanese(_ text: String, fillers: [String]) -> String {
        guard !fillers.isEmpty else { return text }
        var result = ""
        var index = text.startIndex
        var atBoundary = true                       // the start of the text counts as one

        while index < text.endIndex {
            if let filler = fillers.first(where: { candidate in
                    guard text[index...].hasPrefix(candidate) else { return false }
                    let after = text.index(index, offsetBy: candidate.count)
                    let ends = after == text.endIndex || boundaries.contains(text[after])
                    let commaFollows = after < text.endIndex && commas.contains(text[after])
                    if commaMarked.contains(candidate) {
                        return commaFollows
                    }
                    if habitual.contains(candidate) {
                        // まあまあ ("so-so") is a word; neither half of it is a habit.
                        if text[after...].hasPrefix(candidate) || result.hasSuffix(candidate) {
                            return false
                        }
                        return atBoundary || commaFollows
                    }
                    // It must also END at a boundary, or そのうち loses its head.
                    return atBoundary && ends
                })
            {
                index = text.index(index, offsetBy: filler.count)
                // Swallow the comma that usually trails a hesitation: 「えっと、今日は」
                if index < text.endIndex, text[index] == "、" || text[index] == "," {
                    index = text.index(after: index)
                }
                while index < text.endIndex, text[index] == " " || text[index] == "\u{3000}" {
                    index = text.index(after: index)
                }
                continue
            }

            let character = text[index]
            result.append(character)
            atBoundary = boundaries.contains(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func stripEnglish(_ text: String, fillers: [String]) -> String {
        var result = text
        for filler in fillers {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: filler))\\b[,.]?"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
        return result
    }

    private static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        // A filler at the head of a sentence leaves its punctuation behind: 「、今日は」「。そうですね」
        result = result.replacingOccurrences(of: #"^[ 　]*[、。,.]+[ 　]*"#, with: "",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: #"([。\n])[ 　]*[、,][ 　]*"#, with: "$1",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: #" +([、。,.!?])"#, with: "$1", options: .regularExpression)
        // 「、 text」 — the space the English pass left after a Japanese comma.
        result = result.replacingOccurrences(of: #"([、。])[ 　]+"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
