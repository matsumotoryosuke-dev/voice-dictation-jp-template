import Testing
@testable import ShortcutCore

// Raw values of NSEvent.ModifierFlags, spelled out so the test has no AppKit dependency.
private let command: UInt = 1 << 20
private let shift: UInt = 1 << 17
private let keyC: UInt16 = 8
private let space: UInt16 = 49
private let rightCommandKey: UInt16 = 54

private func armed(_ kind: ChordGuard<String>.Kind = .modifierOnly(modifierMask: command)) -> ChordGuard<String> {
    var guardState = ChordGuard<String>()
    guardState.pressed("dictate", kind: kind, at: 10.0)
    return guardState
}

@Test func rightCommandPlusLetterIsAChord() {
    var g = armed()
    #expect(g.observe(.keyDown(keyCode: keyC, isModifierKey: false), at: 10.2) == ["dictate"])
}

@Test func rightCommandPlusClickIsAChord() {
    var g = armed()
    #expect(g.observe(.mouseDown, at: 10.1) == ["dictate"])
}

@Test func rightCommandPlusShiftIsAChord() {
    var g = armed()
    #expect(g.observe(.flagsChanged(normalizedModifiers: command | shift), at: 10.3) == ["dictate"])
}

@Test func ownReleaseIsNotAChord() {
    var g = armed()
    #expect(g.observe(.flagsChanged(normalizedModifiers: 0), at: 10.3).isEmpty)
    #expect(g.observe(.flagsChanged(normalizedModifiers: command), at: 10.3).isEmpty)
}

@Test func modifierKeyDownIsIgnored() {
    var g = armed()
    #expect(g.observe(.keyDown(keyCode: rightCommandKey, isModifierKey: true), at: 10.1).isEmpty)
}

@Test func windowBoundaryIsInclusiveAndLaterEventsAreIgnored() {
    var atEdge = armed()
    #expect(atEdge.observe(.mouseDown, at: 11.0) == ["dictate"])
    var late = armed()
    #expect(late.observe(.mouseDown, at: 11.5).isEmpty)
    #expect(late.observe(.keyDown(keyCode: keyC, isModifierKey: false), at: 12.0).isEmpty)
}

@Test func aHoldIsReportedOnlyOnce() {
    var g = armed()
    #expect(g.observe(.mouseDown, at: 10.1) == ["dictate"])
    #expect(g.observe(.keyDown(keyCode: keyC, isModifierKey: false), at: 10.2).isEmpty)
}

@Test func releasedAndResetHoldsAreForgotten() {
    var g = armed()
    g.released("dictate")
    #expect(!g.isHeld("dictate"))
    #expect(g.observe(.mouseDown, at: 10.1).isEmpty)

    var h = armed()
    h.reset()
    #expect(h.observe(.mouseDown, at: 10.1).isEmpty)
}

@Test func pressingAgainRearms() {
    var g = armed()
    #expect(g.observe(.mouseDown, at: 10.1) == ["dictate"])
    g.released("dictate")
    g.pressed("dictate", kind: .modifierOnly(modifierMask: command), at: 20.0)
    #expect(g.observe(.mouseDown, at: 20.1) == ["dictate"])
}

@Test func keyShortcutKeepsUpstreamBehaviour() {
    var g = armed(.key(keyCode: space))
    #expect(g.observe(.keyDown(keyCode: space, isModifierKey: false), at: 10.1).isEmpty)
    #expect(g.observe(.flagsChanged(normalizedModifiers: command | shift), at: 10.1).isEmpty)
    #expect(g.observe(.mouseDown, at: 10.1).isEmpty)
    #expect(g.observe(.keyDown(keyCode: keyC, isModifierKey: false), at: 10.2) == ["dictate"])
}

@Test func mouseButtonShortcutIsNeverInterrupted() {
    var g = armed(.mouseButton)
    #expect(g.observe(.keyDown(keyCode: keyC, isModifierKey: false), at: 10.1).isEmpty)
    #expect(g.observe(.flagsChanged(normalizedModifiers: shift), at: 10.1).isEmpty)
    #expect(g.observe(.mouseDown, at: 10.1).isEmpty)
}

@Test func holdsAreIndependent() {
    var g = ChordGuard<String>()
    g.pressed("dictate", kind: .modifierOnly(modifierMask: command), at: 10.0)
    g.pressed("paste", kind: .key(keyCode: space), at: 10.0)
    #expect(g.observe(.mouseDown, at: 10.1) == ["dictate"])
    #expect(g.observe(.keyDown(keyCode: keyC, isModifierKey: false), at: 10.2) == ["paste"])
}
