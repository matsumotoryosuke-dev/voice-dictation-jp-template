import Testing
@testable import AutoLearnCore

// Boss-written. The fenced answer is the exact shape gemma4:12b returned in testing.

@Test func aFencedJSONAnswerIsUnwrapped() {
    let answer = """
    ```json
    [{"candidateID": 1, "learningAction": "addReplacementAndVocabulary"}]
    ```
    """
    #expect(AutoLearnReviewText.unwrappingCodeFence(answer)
            == #"[{"candidateID": 1, "learningAction": "addReplacementAndVocabulary"}]"#)
}

@Test func aFenceWithoutALanguageIsUnwrappedToo() {
    #expect(AutoLearnReviewText.unwrappingCodeFence("```\n[]\n```") == "[]")
}

@Test func plainJSONIsLeftAlone() {
    #expect(AutoLearnReviewText.unwrappingCodeFence("  [1, 2]\n") == "[1, 2]")
}

@Test func anythingButOneWholeFenceIsLeftForTheDecoderToReject() {
    // Prose around the fence, or two fences, is not a clean answer; the decoder should
    // still see it and log it as invalid rather than have us guess.
    let prose = "Here you go:\n```json\n[]\n```"
    #expect(AutoLearnReviewText.unwrappingCodeFence(prose) == prose)
    let two = "```json\n[]\n```\n```json\n[]\n```"
    #expect(AutoLearnReviewText.unwrappingCodeFence(two) == two)
    #expect(AutoLearnReviewText.unwrappingCodeFence("```") == "```")
}

@Test func knownVocabularyIsDeduplicatedAndCapped() {
    let terms = ["Obsidian", "obsidian", " Notion ", "", "Figma"]
    #expect(AutoLearnReviewText.knownVocabulary(from: terms) == ["Obsidian", "Notion", "Figma"])
    #expect(AutoLearnReviewText.knownVocabulary(from: terms, limit: 2) == ["Obsidian", "Notion"])
}

// One malformed decision used to fail the whole review and strand the queue.

@Test func aValidAnswerDecodesAsBefore() throws {
    let answer = #"[{"candidateID": 5, "learningAction": "addReplacementAndVocabulary", "incorrectTextToReplace": "ディーターラム", "correctedVocabularyTerm": "ディーター・ラムス"}]"#
    let decoded = try #require(AutoLearnReviewText.decisions(from: answer))
    #expect(decoded.dropped.isEmpty)
    #expect(decoded.decisions == [AutoLearnReviewText.Decision(
        candidateID: 5, learningAction: .addReplacementAndVocabulary,
        incorrectTextToReplace: "ディーターラム", correctedVocabularyTerm: "ディーター・ラムス")])
}

@Test func missingNullFieldsAndExtraKeysNoLongerSinkTheBatch() throws {
    let answer = """
    ```json
    [{"candidateID": 0, "learningAction": "rejectCorrection"},
     {"candidateID": "1", "learningAction": "addReplacementOnly", "incorrectTextToReplace": "Jemma",
      "correctedVocabularyTerm": "Gemma", "reason": "phonetic match"}]
    ```
    """
    let decoded = try #require(AutoLearnReviewText.decisions(from: answer))
    #expect(decoded.dropped.isEmpty)
    #expect(decoded.decisions.map(\.candidateID) == [0, 1])
    #expect(decoded.decisions[0].incorrectTextToReplace == nil)
    #expect(decoded.decisions[1].correctedVocabularyTerm == "Gemma")
}

@Test func onlyTheBrokenDecisionIsSkipped() throws {
    let answer = #"[{"candidateID": 0, "learningAction": "addReplacement"}, "oops", {"learningAction": "rejectCorrection"}, {"candidateID": 3, "learningAction": "rejectCorrection", "incorrectTextToReplace": null, "correctedVocabularyTerm": null}]"#
    let decoded = try #require(AutoLearnReviewText.decisions(from: answer))
    #expect(decoded.decisions.map(\.candidateID) == [3])
    #expect(decoded.dropped == ["unknown-action", "not-an-object", "missing-candidate-id"])
}

@Test func anAnswerThatIsNotAnArrayIsStillAFailure() {
    #expect(AutoLearnReviewText.decisions(from: #"{"decisions": []}"#) == nil)
    #expect(AutoLearnReviewText.decisions(from: "I cannot help with that.") == nil)
}
