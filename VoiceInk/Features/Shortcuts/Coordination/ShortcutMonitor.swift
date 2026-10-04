import AppKit
import CoreGraphics
import Foundation
import os

final class ShortcutMonitor {
    fileprivate enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
        case mouseDown
        case mouseDragged
        case mouseUp
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
        var requiresStandaloneRelease = false
    }

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var pressedKeyCodes = Set<UInt16>()
    private var suppressedMouseButtons = Set<UInt16>()
    private var interruptibleActions: Set<ShortcutAction> = []
    private var standaloneModifierActions: Set<ShortcutAction> = []
    private var onShortcutDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    private var onStandaloneModifierChord: ((ShortcutAction) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    // Left/right clicks are observed on a separate listen-only tap so that no click on the
    // Mac ever waits for this app's main thread, which the active tap above would do.
    private var mouseEventTap: CFMachPort?
    private var mouseEventTapRunLoopSource: CFRunLoopSource?
    private var chordGuard = ChordGuard<ShortcutAction>(window: ShortcutMonitor.shortcutInterruptionWindow)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ShortcutMonitor")

    private static let shortcutInterruptionWindow: TimeInterval = 1.0

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        standaloneModifierActions: Set<ShortcutAction> = [],
        onShortcutDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil,
        onStandaloneModifierChord: ((ShortcutAction) -> Void)? = nil
    ) -> Bool {
        stop()

        for (action, shortcut) in shortcuts {
            self.shortcuts[action] = ShortcutState(shortcut: shortcut)
        }

        guard !self.shortcuts.isEmpty else {
            return true
        }

        self.interruptibleActions = interruptibleActions
        self.standaloneModifierActions = standaloneModifierActions
        self.onShortcutDown = onShortcutDown
        self.onShortcutUp = onShortcutUp
        self.onShortcutInterrupted = onShortcutInterrupted
        self.onStandaloneModifierChord = onStandaloneModifierChord

        return installEventTap()
    }

    func updateStandaloneModifierActions(_ actions: Set<ShortcutAction>) {
        standaloneModifierActions = actions
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let mouseEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseEventTapRunLoopSource, .commonModes)
            self.mouseEventTapRunLoopSource = nil
        }

        if let mouseEventTap {
            CFMachPortInvalidate(mouseEventTap)
            self.mouseEventTap = nil
        }

        chordGuard.reset()
        shortcuts = [:]
        pressedKeyCodes = []
        suppressedMouseButtons = []
        interruptibleActions = []
        standaloneModifierActions = []
        onShortcutDown = nil
        onShortcutUp = nil
        onShortcutInterrupted = nil
        onStandaloneModifierChord = nil
    }

    private func installEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.resetPressedShortcutsAfterTapInterruption()
                if let eventTap = monitor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            logger.error("Failed to install global shortcut event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        // Clicks only matter for held modifier-only shortcuts (chords, Toggle candidates).
        if shortcuts.values.contains(where: { $0.shortcut.isModifierOnly }) {
            installMouseEventTap()
        }
        return true
    }

    /// Best effort: without it, clicks simply do not cancel an accidental start.
    private func installMouseEventTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let mouseEventTap = monitor.mouseEventTap {
                    CGEvent.tapEnable(tap: mouseEventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            monitor.handleMouseDownForChords(eventTime: ProcessInfo.processInfo.systemUptime)
            return Unmanaged.passUnretained(event)
        }

        let mask = (CGEventMask(1) << Int(CGEventType.leftMouseDown.rawValue))
            | (CGEventMask(1) << Int(CGEventType.rightMouseDown.rawValue))

        guard
            let mouseEventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mouseEventTap, 0)
        else {
            logger.error("Failed to install listen-only mouse tap; clicks will not cancel accidental starts")
            return
        }

        self.mouseEventTap = mouseEventTap
        mouseEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: mouseEventTap, enable: true)
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard UserSessionInputPolicy.allowsShortcutHandling else {
            clearPressedShortcutState()
            return false
        }

        guard let eventKind = EventKind(type) else {
            return false
        }

        let inputCode: UInt16
        switch eventKind {
        case .keyDown, .keyUp, .flagsChanged:
            inputCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        case .mouseDown, .mouseDragged, .mouseUp:
            inputCode = UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        return handleEvent(
            kind: eventKind,
            inputCode: inputCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func resetPressedShortcutsAfterTapInterruption() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
    }

    private func clearPressedShortcutState() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
        suppressedMouseButtons.removeAll()
    }

    private func releasePressedShortcuts(eventTime: TimeInterval) {
        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else { continue }
            let shouldDispatchUp = state.isDown && !state.requiresStandaloneRelease
            state.isDown = false
            state.pressedAt = nil
            state.isInterrupted = false
            state.requiresStandaloneRelease = false
            shortcuts[action] = state
            if shouldDispatchUp {
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }
        chordGuard.reset()
        pressedKeyCodes.removeAll()
    }

    private func handleEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) -> Bool {
        var shouldSuppress: Bool
        switch kind {
        case .mouseDragged:
            shouldSuppress = suppressedMouseButtons.contains(inputCode)
        case .mouseUp:
            shouldSuppress = suppressedMouseButtons.remove(inputCode) != nil
        case .keyDown, .keyUp, .flagsChanged, .mouseDown:
            shouldSuppress = false
        }

        updatePressedKeyCodes(kind: kind, inputCode: inputCode)
        invalidateStandaloneModifierCandidateForKeyboardEvent(
            kind: kind,
            inputCode: inputCode,
            modifierFlags: modifierFlags
        )

        switch kind {
        case .keyDown:
            if !Shortcut.isModifierKeyCode(inputCode) {
                // Upstream's double-tap mode needs to hear that a modifier became part of a chord.
                for action in standaloneModifierActions {
                    guard shortcuts[action]?.shortcut.isModifierOnly == true else { continue }
                    onStandaloneModifierChord?(action)
                }
            }
            interruptChords(
                .keyDown(keyCode: inputCode, isModifierKey: Shortcut.isModifierKeyCode(inputCode)),
                eventTime: eventTime
            )
        case .flagsChanged:
            let normalizedFlags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: inputCode)
            interruptChords(.flagsChanged(normalizedModifiers: normalizedFlags.rawValue), eventTime: eventTime)
        case .mouseDown:
            handleMouseDownForChords(eventTime: eventTime)
        case .keyUp, .mouseDragged, .mouseUp:
            break
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else {
                continue
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime
                )
                continue
            }

            let transition: ShortcutTransition
            switch state.shortcut.kind {
            case .key:
                transition = transitionForKeyShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            case .mouseButton:
                transition = transitionForMouseShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    buttonNumber: inputCode,
                    modifierFlags: modifierFlags
                )
            case .modifierOnly:
                transition = .none
            }

            switch transition {
            case .none:
                break
            case .suppress:
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
            case .keyDown:
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                if state.shortcut.kind == .mouseButton {
                    suppressedMouseButtons.insert(inputCode)
                }
                if interruptibleActions.contains(action) {
                    let kind: ChordGuard<ShortcutAction>.Kind =
                        state.shortcut.kind == .mouseButton ? .mouseButton : .key(keyCode: state.shortcut.keyCode)
                    chordGuard.pressed(action, kind: kind, at: eventTime)
                }
                shouldSuppress = true
                dispatchShortcutDown(for: action, eventTime: eventTime)
            case .keyUp:
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                chordGuard.released(action)
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }

        return shouldSuppress
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .mouseDown, .mouseDragged, .mouseUp:
            return .none
        }
    }

    private func transitionForMouseShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        buttonNumber: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .mouseDown:
            guard shortcut.matchesMouseEvent(
                buttonNumber: buttonNumber,
                modifierFlags: modifierFlags
            ) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .mouseUp:
            return isDown && buttonNumber == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil)
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .keyDown, .keyUp, .mouseDragged:
            return .none
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                let shouldTrigger =
                    state.requiresStandaloneRelease
                    && !state.isInterrupted
                let shouldDispatchUp = !state.requiresStandaloneRelease
                let pressedAt = state.pressedAt
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                state.requiresStandaloneRelease = false
                shortcuts[action] = state
                chordGuard.released(action)
                if shouldTrigger, let pressedAt {
                    dispatchShortcutDown(for: action, eventTime: pressedAt)
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                } else if shouldDispatchUp {
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                }
            }

            return
        }

        if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
            state.isDown = true
            state.pressedAt = eventTime
            state.requiresStandaloneRelease = standaloneModifierActions.contains(action)
            state.isInterrupted = state.requiresStandaloneRelease && !pressedKeyCodes.isEmpty
            shortcuts[action] = state
            if !state.requiresStandaloneRelease {
                if interruptibleActions.contains(action) {
                    chordGuard.pressed(
                        action,
                        kind: .modifierOnly(modifierMask: state.shortcut.modifierFlags.rawValue),
                        at: eventTime
                    )
                }
                dispatchShortcutDown(for: action, eventTime: eventTime)
            }
        }
    }

    private func updatePressedKeyCodes(kind: EventKind, inputCode: UInt16) {
        switch kind {
        case .keyDown:
            pressedKeyCodes.insert(inputCode)
        case .keyUp:
            pressedKeyCodes.remove(inputCode)
        case .flagsChanged, .mouseDown, .mouseDragged, .mouseUp:
            break
        }
    }

    private func invalidateStandaloneModifierCandidateForKeyboardEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard kind == .keyDown || kind == .keyUp || kind == .flagsChanged else {
            return
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action],
                state.isDown,
                state.requiresStandaloneRelease,
                !state.isInterrupted
            else {
                continue
            }

            let isReleaseEvent = kind == .flagsChanged
                && state.shortcut.shouldReleaseModifierEvent(
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            if !isReleaseEvent {
                state.isInterrupted = true
                shortcuts[action] = state
            }
        }
    }

    /// A held shortcut that turns out to be part of a chord (Right ⌘ + C, + click, + ⇧)
    /// is reported as interrupted so an accidental recording start can be cancelled.
    private func interruptChords(_ event: ChordGuard<ShortcutAction>.Event, eventTime: TimeInterval) {
        for action in chordGuard.observe(event, at: eventTime) {
            guard interruptibleActions.contains(action), var state = shortcuts[action], state.isDown else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: eventTime)
        }
    }

    private func handleMouseDownForChords(eventTime: TimeInterval) {
        // A click also disqualifies a Toggle-mode modifier waiting for a clean release.
        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action],
                state.isDown,
                state.requiresStandaloneRelease,
                !state.isInterrupted
            else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
        }

        interruptChords(.mouseDown, eventTime: eventTime)
    }

    private func dispatchShortcutDown(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutDown] in
            onShortcutDown?(action, eventTime)
        }
    }

    private func dispatchShortcutUp(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutUp] in
            onShortcutUp?(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutInterrupted] in
            onShortcutInterrupted?(action, eventTime)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged,
        CGEventType.otherMouseDown,
        CGEventType.otherMouseDragged,
        CGEventType.otherMouseUp,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        case .otherMouseDown:
            self = .mouseDown
        case .otherMouseDragged:
            self = .mouseDragged
        case .otherMouseUp:
            self = .mouseUp
        default:
            return nil
        }
    }
}
