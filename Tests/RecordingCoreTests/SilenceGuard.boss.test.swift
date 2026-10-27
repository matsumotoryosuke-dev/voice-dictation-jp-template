import Testing
@testable import RecordingCore

// Boss-written, 2026-10-26. Rio tapped the dictation key twice without speaking and got
// "うん。" pasted. The levels below are the real ones from his dictation journal.

@Test func aLoneUnOnASilentClipIsDropped() {
    #expect(SilenceGuard.isNoiseOnly("うん。", meanLevelDecibels: -67.3))
    #expect(SilenceGuard.isNoiseOnly("うん。", meanLevelDecibels: -63.8))
    #expect(SilenceGuard.isNoiseOnly(" うん ", meanLevelDecibels: -64.8))
    #expect(SilenceGuard.isNoiseOnly("ん。", meanLevelDecibels: -66.0))
}

@Test func anUnActuallySaidIsKept() {
    // A short clip with speech in it is far louder than silence.
    #expect(!SilenceGuard.isNoiseOnly("うん。", meanLevelDecibels: -45.5))
}

@Test func quietRealDictationsAreKept() {
    // Rio's quietest real dictations: as low as −65 dB, but never a lone interjection.
    #expect(!SilenceGuard.isNoiseOnly("自宅に。", meanLevelDecibels: -62.2))
    #expect(!SilenceGuard.isNoiseOnly("うんうん、それでいいと思う。", meanLevelDecibels: -65.1))
    #expect(!SilenceGuard.isNoiseOnly("うんざりする。", meanLevelDecibels: -66.0))
}

@Test func anUnknownLevelNeverDropsText() {
    #expect(!SilenceGuard.isNoiseOnly("うん。", meanLevelDecibels: nil))
}

// Boss-written, 2026-10-27. Rio still got "うん。" in front of real dictations. The texts and
// silent-start seconds below are the real ones from his history.

@Test func aLeadingUnAfterASilentStartIsDropped() {
    #expect(SilenceGuard.droppingLeadingInterjection("うん。 打ち合わせも兼ねて、。", silentStartSeconds: 3.70)
            == "打ち合わせも兼ねて、。")
    #expect(SilenceGuard.droppingLeadingInterjection("うん。 Okay, done.", silentStartSeconds: 2.05) == "Okay, done.")
    #expect(SilenceGuard.droppingLeadingInterjection("うん。本当に。", silentStartSeconds: 1.40) == "本当に。")
    #expect(SilenceGuard.droppingLeadingInterjection("ん。 次は", silentStartSeconds: 2.0) == "次は")
}

@Test func aLeadingUnAfterAPromptStartIsKept() {
    #expect(SilenceGuard.droppingLeadingInterjection("うん。 I told you what I wanted", silentStartSeconds: 0.15)
            == "うん。 I told you what I wanted")
    #expect(SilenceGuard.droppingLeadingInterjection("うん。 で。", silentStartSeconds: 1.2) == "うん。 で。")
}

@Test func onlyAStandaloneLeadingUnIsTouched() {
    // "うん、" leads into the sentence and starts promptly like any other dictation.
    #expect(SilenceGuard.droppingLeadingInterjection("うん、だから結局、その—", silentStartSeconds: 7.5)
            == "うん、だから結局、その—")
    #expect(SilenceGuard.droppingLeadingInterjection("うんざりする。", silentStartSeconds: 3.0) == "うんざりする。")
    #expect(SilenceGuard.droppingLeadingInterjection("うんうん。それでいい。", silentStartSeconds: 3.0)
            == "うんうん。それでいい。")
    #expect(SilenceGuard.droppingLeadingInterjection("オッケー。 うん。 次へ。", silentStartSeconds: 3.0)
            == "オッケー。 うん。 次へ。")
}

@Test func aLoneUnIsLeftToTheNoiseCheck() {
    #expect(SilenceGuard.droppingLeadingInterjection("うん。", silentStartSeconds: 3.0) == "うん。")
}

@Test func anUnreadableClipNeverDropsText() {
    #expect(SilenceGuard.droppingLeadingInterjection("うん。 次へ。", silentStartSeconds: nil) == "うん。 次へ。")
}
