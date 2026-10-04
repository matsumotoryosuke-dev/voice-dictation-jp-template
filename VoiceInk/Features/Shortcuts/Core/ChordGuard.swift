import Foundation

/// Decides when a held recording shortcut turns out to be the first half of a chord
/// (Right ⌘ + C, Right ⌘ + click, Right ⌥ + ⇧ …) rather than a dictation press.
///
/// Push-to-talk and Hybrid start recording on key-down so no speech is clipped, which
/// means a chord can only be undone after the fact. This type owns that decision and
/// nothing else: it has no AppKit or app dependencies so it can be unit tested with
/// `swift test` (see Package.swift). `ShortcutMonitor` feeds it events.
///
/// A hold is interrupted at most once, and only within `window` seconds of the press.
/// After that the user is already speaking, and throwing the recording away would cost
/// more than an accidental keystroke does.
struct ChordGuard<Action: Hashable> {
    enum Kind: Equatable {
        /// A bare modifier. `modifierMask` is the shortcut's own normalized modifier flags.
        case modifierOnly(modifierMask: UInt)
        case key(keyCode: UInt16)
        case mouseButton
    }

    enum Event: Equatable {
        case keyDown(keyCode: UInt16, isModifierKey: Bool)
        /// Normalized modifier flags after the change.
        case flagsChanged(normalizedModifiers: UInt)
        case mouseDown
    }

    let window: TimeInterval
    private var holds: [Action: Hold] = [:]

    private struct Hold {
        let kind: Kind
        let pressedAt: TimeInterval
        var isInterrupted = false
    }

    init(window: TimeInterval = 1.0) {
        self.window = window
    }

    mutating func pressed(_ action: Action, kind: Kind, at time: TimeInterval) {
        holds[action] = Hold(kind: kind, pressedAt: time)
    }

    mutating func released(_ action: Action) {
        holds[action] = nil
    }

    mutating func reset() {
        holds.removeAll()
    }

    func isHeld(_ action: Action) -> Bool {
        holds[action] != nil
    }

    /// Returns the held actions this event interrupts. Each hold is reported once.
    mutating func observe(_ event: Event, at time: TimeInterval) -> [Action] {
        var interrupted: [Action] = []
        for (action, hold) in holds where !hold.isInterrupted && time - hold.pressedAt <= window {
            guard Self.interrupts(event, kind: hold.kind) else { continue }
            holds[action]?.isInterrupted = true
            interrupted.append(action)
        }
        return interrupted
    }

    private static func interrupts(_ event: Event, kind: Kind) -> Bool {
        switch (event, kind) {
        case (.keyDown(_, true), _):
            return false
        case (.keyDown, .modifierOnly):
            return true
        case (.keyDown(let keyCode, _), .key(let ownKeyCode)):
            return keyCode != ownKeyCode
        case (.flagsChanged(let flags), .modifierOnly(let mask)):
            // Another modifier is down alongside the shortcut's own. The shortcut's own
            // release clears bits and adds none, so it never counts.
            return flags & ~mask != 0
        case (.mouseDown, .modifierOnly):
            return true
        case (.keyDown, .mouseButton), (.flagsChanged, _), (.mouseDown, _):
            return false
        }
    }
}
