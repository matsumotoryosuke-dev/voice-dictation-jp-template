import Foundation

/// The user's vocabulary, as it is shared between tools.
///
/// One file — ~/.config/dictation/vocabulary.json — is read and written by VoiceInk and
/// readable by any other tool, so a name taught once is known everywhere:
///
///     {"terms": ["Obsidian", ...], "corrections": {"オブシディアン": "Obsidian"}}
///
/// `corrections` maps a wrong rendering to the right one. Anything in the file may have
/// been typed by hand, so every read validates rather than trusts.
struct SharedVocabulary: Equatable {
    var terms: [String] = []
    var corrections: [String: String] = [:]
}

/// What one sync has to do to bring the file and the dictionary back together.
struct VocabularyPlan: Equatable {
    var addToApp = SharedVocabulary()
    var removeFromApp = SharedVocabulary()
    var fileContents = SharedVocabulary()

    var isEmpty: Bool {
        addToApp == SharedVocabulary() && removeFromApp == SharedVocabulary()
    }
}

enum SharedVocabularyFile {
    static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/dictation/vocabulary.json")

    // MARK: - File

    /// Never throws: an unreadable file must not stop the app from starting.
    static func decode(_ data: Data) -> SharedVocabulary {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SharedVocabulary()
        }
        let terms = (object["terms"] as? [Any] ?? []).compactMap { clean($0 as? String) }
        var corrections: [String: String] = [:]
        for (wrong, right) in (object["corrections"] as? [String: Any] ?? [:]) {
            guard let wrong = clean(wrong), let right = clean(right as? String) else { continue }
            // A comma would split the entry when the dictionary stores its sources.
            guard !wrong.contains(","), wrong != right else { continue }
            corrections[wrong] = right
        }
        return SharedVocabulary(terms: deduplicated(terms), corrections: corrections)
    }

    /// Stable bytes: sorted keys, real UTF-8, so the file diffs cleanly and a rewrite with
    /// the same content produces the same bytes (which is how a sync loop is detected).
    static func encode(_ vocabulary: SharedVocabulary) throws -> Data {
        let object: [String: Any] = ["terms": vocabulary.terms, "corrections": vocabulary.corrections]
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Merging

    /// Union, for the first sync when there is no agreed state to compare against.
    static func merged(file: SharedVocabulary, app: SharedVocabulary) -> SharedVocabulary {
        SharedVocabulary(terms: deduplicated(file.terms + app.terms),
                         corrections: file.corrections.merging(app.corrections) { _, fromApp in fromApp })
    }

    /// Three-way merge. Without `base` a deletion is indistinguishable from an entry the
    /// other side has not seen yet, so the first sync unions and only later syncs delete.
    static func plan(base: SharedVocabulary?, file: SharedVocabulary, app: SharedVocabulary) -> VocabularyPlan {
        guard let base else {
            let union = merged(file: file, app: app)
            return VocabularyPlan(addToApp: difference(union, minus: app), fileContents: union)
        }

        var terms: [String] = []
        for term in deduplicated(file.terms + app.terms) {
            let inFile = file.terms.contains(term)
            let inApp = app.terms.contains(term)
            let known = base.terms.contains(term)
            // Present on one side and known before means the other side deleted it.
            if inFile && inApp { terms.append(term) } else if !known { terms.append(term) }
        }

        var corrections: [String: String] = [:]
        for wrong in Set(file.corrections.keys).union(app.corrections.keys) {
            let fromFile = file.corrections[wrong]
            let fromApp = app.corrections[wrong]
            let known = base.corrections[wrong] != nil
            if let fromApp, fromFile != nil {
                corrections[wrong] = fromApp                       // both sides: the app's value wins
            } else if !known {
                corrections[wrong] = fromApp ?? fromFile           // new on one side
            }
        }

        let contents = SharedVocabulary(terms: terms, corrections: corrections)
        return VocabularyPlan(addToApp: difference(contents, minus: app),
                              removeFromApp: difference(app, minus: contents),
                              fileContents: contents)
    }

    // MARK: - The app's own format

    static func archive(from vocabulary: SharedVocabulary, now: Date) -> DictionaryArchive {
        var sourcesByReplacement: [String: [String]] = [:]
        for (wrong, right) in vocabulary.corrections {
            sourcesByReplacement[right, default: []].append(wrong)
        }
        return DictionaryArchive(
            exportedAt: now,
            vocabulary: vocabulary.terms.map { DictionaryVocabularyEntry(term: $0, createdAt: now) },
            replacements: sourcesByReplacement.keys.sorted().map { replacement in
                DictionaryReplacementEntry(sources: sourcesByReplacement[replacement, default: []].sorted(),
                                           replacement: replacement, createdAt: now)
            })
    }

    static func vocabulary(from archive: DictionaryArchive) -> SharedVocabulary {
        let terms = archive.vocabulary.compactMap { clean($0.term) }
        var corrections: [String: String] = [:]
        for entry in archive.replacements {
            guard let right = clean(entry.replacement) else { continue }
            for source in entry.sources {
                guard let wrong = clean(source), !wrong.contains(",") else { continue }
                corrections[wrong] = right
            }
        }
        return SharedVocabulary(terms: deduplicated(terms), corrections: corrections)
    }

    // MARK: - Helpers

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func deduplicated(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    /// What `left` holds that `right` does not.
    private static func difference(_ left: SharedVocabulary, minus right: SharedVocabulary) -> SharedVocabulary {
        SharedVocabulary(
            terms: left.terms.filter { !right.terms.contains($0) },
            corrections: left.corrections.filter { right.corrections[$0.key] != $0.value })
    }
}
