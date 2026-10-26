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
