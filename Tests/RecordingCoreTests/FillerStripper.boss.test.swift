import Testing
@testable import RecordingCore

// Cases shaped like real dictation (hesitations before a comma) plus the ways a
// naive implementation eats real words.

@Test func removesTheHesitationsHeActuallyProduces() {
    #expect(FillerStripper.strip("えっと、資料のリンクも入れてほしい。")
            == "資料のリンクも入れてほしい。")
    #expect(FillerStripper.strip("あと、えっと、資料。") == "あと、資料。")
    #expect(FillerStripper.strip("えー、確認用の単語って何だっけ。")
            == "確認用の単語って何だっけ。")
    #expect(FillerStripper.strip("うーん、どうしようかな。") == "どうしようかな。")
}

@Test func removesEnglishHesitations() {
    #expect(FillerStripper.strip("So um, let me check the plist first.")
            == "So let me check the plist first.")
    #expect(FillerStripper.strip("Uh, hmm, that is the wrong branch.") == "that is the wrong branch.")
}

@Test func leavesRealWordsThatContainTheSameSounds() {
    // The kana of a filler appears inside ordinary words; only boundaries may be stripped.
    #expect(FillerStripper.strip("へえー、すごい。") == "へえー、すごい。")
    #expect(FillerStripper.strip("そのうち直します。") == "そのうち直します。")
    #expect(FillerStripper.strip("紅茶をいれてあーおいしい") == "紅茶をいれてあーおいしい")
    #expect(FillerStripper.strip("The album is a hit") == "The album is a hit")   // 'hm' inside a word
    #expect(FillerStripper.strip("Ahead of time") == "Ahead of time")
}

@Test func keepsWordsThatOnlyLookLikeFillers() {
    // なんか stays (too often the real word); あの and その stay when they mean "that".
    let ambiguous = "なんかあった。あの件とその件、like this, actually right now."
    #expect(FillerStripper.strip(ambiguous) == ambiguous)
    #expect(FillerStripper.strip("その一点においては同じです。") == "その一点においては同じです。")
    #expect(FillerStripper.strip("これはあのローカルの話です。") == "これはあのローカルの話です。")
}

// まあ is removed strongly (a common verbal habit); あの and その only before a comma;
// なんか never. Sentences below are ordinary dictation.

@Test func maaGoesWhereverItStartsAPhraseEvenWithoutAComma() {
    #expect(FillerStripper.strip("従来のAIと比べて、まあ優れてるところが何点かある。")
            == "従来のAIと比べて、優れてるところが何点かある。")
    #expect(FillerStripper.strip("まあ、そういった特徴があります。") == "そういった特徴があります。")
    #expect(FillerStripper.strip("チケット、まあ200〜300くらいある。") == "チケット、200〜300くらいある。")
    #expect(FillerStripper.strip("まぁいいか。") == "いいか。")
}

@Test func maaAfterAParticleGoesWhenACommaMarksThePause() {
    #expect(FillerStripper.strip("最初はまあ、Type速い人が有利。") == "最初はType速い人が有利。")
}

@Test func maamaaIsAWordAndStays() {
    #expect(FillerStripper.strip("結果はまあまあでした。") == "結果はまあまあでした。")
    #expect(FillerStripper.strip("まあまあ、落ち着いて。") == "まあまあ、落ち着いて。")
}

@Test func anoAndSonoGoOnlyWithAComma() {
    #expect(FillerStripper.strip("最近、あの、ジェミニという単語をよく使う。") == "最近、ジェミニという単語をよく使う。")
    #expect(FillerStripper.strip("やっぱりその、台本レベルで考える。") == "やっぱり台本レベルで考える。")
    #expect(FillerStripper.strip("結構、その、精度が高くて。") == "結構、精度が高くて。")
    #expect(FillerStripper.strip("あの、すみません。") == "すみません。")
}

@Test func nankaIsLeftAlone() {
    #expect(FillerStripper.strip("私、なんか、動画の台本を書いてる。") == "私、なんか、動画の台本を書いてる。")
}

@Test func theLongerFormsStillWin() {
    #expect(FillerStripper.strip("そのうち直します。") == "そのうち直します。")
    #expect(FillerStripper.strip("あのー、聞こえますか。") == "聞こえますか。")
}

@Test func longerFormsWinOverShorterOnes() {
    #expect(FillerStripper.strip("えーっと、それで。") == "それで。")      // not "っと、それで。"
    #expect(FillerStripper.strip("あのー、聞こえますか。") == "聞こえますか。")
}

@Test func punctuationIsNotLeftBehind() {
    #expect(FillerStripper.strip("えっと、") == "")
    #expect(FillerStripper.strip("えー。そうですね。") == "そうですね。")
    #expect(FillerStripper.strip("これは、えっと、無理です。") == "これは、無理です。")
}

@Test func anUtteranceThatIsOnlyAHesitationBecomesEmpty() {
    // The pipeline then reports "No speech detected" instead of pasting a stray えー.
    #expect(FillerStripper.strip("えー") == "")
    #expect(FillerStripper.strip("um") == "")
}

@Test func anEmptyListLeavesTheTextAlone() {
    let text = "えっと、um, そのままで。"
    #expect(FillerStripper.strip(text, japanese: [], english: []) == text)
}

@Test func mixedSpeechKeepsItsShape() {
    #expect(FillerStripper.strip("えっと、B-roll は Remotion で作るけど、um, text を先に確定したい。")
            == "B-roll は Remotion で作るけど、text を先に確定したい。")
}
