import Foundation

class FillerWordManager: ObservableObject {
    static let shared = FillerWordManager()

    /// English hesitations, plus common Japanese ones. まあ, あの and
    /// その are included with stricter matching (see FillerStripper); なんか is left out on
    /// purpose, since it is too often the real word.
    static let defaultFillerWords = FillerStripper.english + FillerStripper.japanese

    /// Earlier shipped lists. A user who never edited the list gets the new defaults;
    /// anyone who did keeps their own.
    private static let legacyDefaults: [[String]] = [
        // Upstream, before Japanese was handled at all.
        ["uh", "um", "uhm", "umm", "uhh", "uhhh", "hmm", "hm", "mmm", "mm", "mh", "ehh"],
        // Pure hesitations only, before まあ / あの / その were added.
        ["um", "umm", "uhm", "uh", "uhh", "uhhh", "hmm", "hm", "mmm", "mm", "er", "err", "ahh",
         "えーっと", "えーと", "えっと", "えと", "えー", "えぇ", "あのー", "あのう", "あのぉ",
         "うーん", "うー", "うぅ", "あー", "あぁ", "んー", "んん", "そのー", "そのう"],
    ]

    private let fillerWordsKey = "FillerWords"

    @Published var fillerWords: [String] {
        didSet {
            UserDefaults.standard.set(fillerWords, forKey: fillerWordsKey)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: fillerWordsKey) {
            self.fillerWords = Self.legacyDefaults.contains(saved) ? Self.defaultFillerWords : saved
        } else {
            self.fillerWords = Self.defaultFillerWords
        }
    }

    func addWord(_ word: String) -> Bool {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        guard !fillerWords.contains(where: { $0.lowercased() == normalized }) else { return false }
        fillerWords.append(normalized)
        return true
    }

    func removeWord(_ word: String) {
        fillerWords.removeAll { $0.lowercased() == word.lowercased() }
    }

}
