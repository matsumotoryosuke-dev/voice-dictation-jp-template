import AppKit
import ApplicationServices
import Foundation
import OSLog

final class AutoLearnAXRuntime: @unchecked Sendable {
    private struct Session {
        let token: AutoLearnPasteToken
        let appElement: AXUIElement
        let targetElement: AXUIElement
        let bundleID: String
        var tracker: AutoLearnSnapshotTracker
        var consecutiveReadFailures = 0
    }

    private enum CaptureAttempt {
        case captured(AutoLearnPasteToken, String)
        case retry(String)
        case giveUp(String)
    }

    /// When to look for the pasted text, in milliseconds after the first attempt. The
    /// first query after switching web accessibility on makes Chromium build its tree,
    /// which a single 100 ms look never waited for.
    private static let captureRetryDelaysMilliseconds: [UInt64] = [150, 300, 600, 1_000]
    private static let retryAccessibilityTimeoutSeconds: Float = 0.4
    /// Web accessibility stays on this long after the last paste, so dictating twice in
    /// a row does not rebuild the app's accessibility tree each time.
    private static let restoreDelaySeconds: Double = 300
    /// If recording starts but nothing is ever pasted, the prewarm is undone after this.
    private static let prewarmFallbackRestoreSeconds: Double = 600
    private static let readFailuresBeforeGivingUp = 3

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.auto-learn.accessibility")
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "AutoLearnCapture"
    )
    private let textReader = AutoLearnAXTextReader()
    private var session: Session?
    private var pendingRestores: [pid_t: DispatchWorkItem] = [:]
    private var prewarmedAt: [pid_t: Date] = [:]

    /// Recording has started in `processID`'s app. Without this, the first dictation
    /// after five idle minutes found Claude's accessibility tree switched off and still
    /// unbuilt two seconds after the paste: in one day of use 21 of 26 captures failed,
    /// every one of them more than 120 s after the previous dictation.
    func prewarm(processID: pid_t) async {
        guard processID > 0, processID != ProcessInfo.processInfo.processIdentifier else { return }
        await perform { [self] in
            guard AXIsProcessTrusted() else { return }
            cancelPendingRestore(processID: processID)
            let detail = textReader.prewarm(
                processID: processID,
                timeout: Self.retryAccessibilityTimeoutSeconds
            )
            prewarmedAt[processID] = Date()
            scheduleRestore(processID: processID, after: Self.prewarmFallbackRestoreSeconds)
            logger.notice("Auto Learn prewarm pid=\(processID, privacy: .public) \(detail, privacy: .public)")
        }
    }

    /// Runs on `queue`. For the capture log: whether this capture had a prewarm.
    private func prewarmMarker(processID: pid_t) -> String {
        guard let at = prewarmedAt[processID] else { return "prewarm=none" }
        return "prewarm=\(Int(Date().timeIntervalSince(at)))s-ago"
    }

    func capturePastedText(text: String, processID: pid_t) async -> AutoLearnPasteToken? {
        let bundleID = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier ?? "pid-\(processID)"
        var failures: [String] = []

        for attempt in 0...Self.captureRetryDelaysMilliseconds.count {
            if attempt > 0 {
                let delay = Self.captureRetryDelaysMilliseconds[attempt - 1]
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000)
                } catch {
                    await perform { [self] in scheduleRestore(processID: processID) }
                    return nil
                }
            }

            let timeout = attempt == 0
                ? AutoLearnLimits.captureAccessibilityTimeoutSeconds
                : Self.retryAccessibilityTimeoutSeconds
            let outcome = await perform { [self] in
                attemptCapture(text: text, processID: processID, bundleID: bundleID, timeout: timeout)
            }

            switch outcome {
            case let .captured(token, source):
                let marker = await perform { [self] in prewarmMarker(processID: processID) }
                logger.notice(
                    "Auto Learn capture ok app=\(bundleID, privacy: .public) attempt=\(attempt + 1, privacy: .public) source=\(source, privacy: .public) \(marker, privacy: .public)"
                )
                return token
            case let .giveUp(reason):
                logger.notice(
                    "Auto Learn capture rejected app=\(bundleID, privacy: .public) reason=\(reason, privacy: .public)"
                )
                return nil
            case let .retry(detail):
                failures.append(detail)
            }
        }

        let marker = await perform { [self] () -> String in
            scheduleRestore(processID: processID)
            return prewarmMarker(processID: processID)
        }
        logger.notice(
            "Auto Learn capture rejected app=\(bundleID, privacy: .public) \(marker, privacy: .public) attempts=\(failures.count, privacy: .public) last=\(failures.last ?? "", privacy: .public) first=\(failures.first ?? "", privacy: .public)"
        )
        return nil
    }

    /// Runs on `queue`.
    private func attemptCapture(
        text: String,
        processID: pid_t,
        bundleID: String,
        timeout: Float
    ) -> CaptureAttempt {
        session = nil

        guard AXIsProcessTrusted() else { return .giveUp("accessibility-not-trusted") }
        guard processID != ProcessInfo.processInfo.processIdentifier else {
            return .giveUp("target-is-voiceink")
        }
        guard !text.isEmpty else { return .giveUp("empty-pasted-text") }
        guard text.count <= AutoLearnLimits.maximumPastedCharacters else {
            return .giveUp("pasted-text-too-large")
        }

        cancelPendingRestore(processID: processID)
        let (readings, detail) = textReader.focusedReadings(processID: processID, timeout: timeout)

        var matchedReading: AutoLearnAXTextReading?
        var pastedRange: NSRange?
        for reading in readings {
            if let resolvedRange = resolvedPastedRange(
                for: text,
                selectionAfterPaste: reading.selection,
                fieldText: reading.fieldText
            ) {
                matchedReading = reading
                pastedRange = resolvedRange
                break
            }
        }

        guard let reading = matchedReading, let pastedRange else {
            if let first = readings.first {
                let field = AutoLearnTextNormalizer.accessibilityComparable(first.fieldText)
                let pasted = AutoLearnTextNormalizer.accessibilityComparable(text)
                let selection = first.selection.map { "\($0.location),\($0.length)" } ?? "none"
                return .retry(
                    "pasted-range-invalid[\(detail) pasted=\(text.utf16.count) field=\(first.fieldText.utf16.count) sel=\(selection) contains=\(field.contains(pasted) ? "yes" : "no")]"
                )
            }
            return .retry("focused-text-reading-unavailable[\(detail)]")
        }

        let fieldText = reading.fieldText
        let observedPastedText = (fieldText as NSString).substring(with: pastedRange)

        AXUIElementSetMessagingTimeout(
            reading.appElement,
            AutoLearnLimits.accessibilityTimeoutSeconds
        )
        let token = AutoLearnPasteToken(id: UUID())
        session = Session(
            token: token,
            appElement: reading.appElement,
            targetElement: reading.targetElement,
            bundleID: bundleID,
            tracker: AutoLearnSnapshotTracker(
                baselineFieldText: fieldText,
                pastedRange: pastedRange,
                originalPastedText: observedPastedText
            )
        )
        return .captured(token, "\(reading.focusSource)/\(reading.source)")
    }

    /// The element whose value changes are worth watching for this paste.
    func targetElement(token: AutoLearnPasteToken) async -> AXUIElement? {
        await perform { [self] in
            guard let active = session, active.token == token else { return nil }
            return active.targetElement
        }
    }

    /// Reads the field now. Returns a reason once the paste is gone (sent, cleared,
    /// replaced), so the session can end with the last edit that was still there.
    func probe(token: AutoLearnPasteToken) async -> String? {
        await perform { [self] in
            guard var active = session, active.token == token else { return nil }
            let step: AutoLearnSnapshotTracker.Step
            if let value = textReader.textValue(from: active.targetElement),
                value.text.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length
            {
                active.consecutiveReadFailures = 0
                step = active.tracker.observe(value.text)
            } else {
                active.consecutiveReadFailures += 1
                step = active.consecutiveReadFailures >= Self.readFailuresBeforeGivingUp
                    ? active.tracker.targetUnreadable()
                    : .keepWatching
            }
            session = active
            if case let .finish(reason) = step { return reason }
            return nil
        }
    }

    func finishSnapshot(token: AutoLearnPasteToken) async -> AutoLearnFieldSnapshot? {
        await perform { [self] in
            guard var active = session, active.token == token else { return nil }
            session = nil
            defer { scheduleRestore(processID: AXProcessID(active.appElement)) }

            if active.tracker.finishReason == nil {
                if let value = textReader.textValue(from: active.targetElement),
                    value.text.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length
                {
                    _ = active.tracker.observe(value.text)
                } else {
                    _ = active.tracker.targetUnreadable()
                }
            }
            logger.notice(
                "Auto Learn watch ended app=\(active.bundleID, privacy: .public) reason=\(active.tracker.finishReason ?? "deadline-or-focus", privacy: .public) kept-edit=\(active.tracker.lastGood != nil, privacy: .public)"
            )
            return active.tracker.lastGood
        }
    }

    func targetIsFocused(token: AutoLearnPasteToken) async -> Bool {
        await perform { [self] in
            guard let active = session, active.token == token else { return false }
            return focusedElementMatches(active.targetElement, in: active.appElement)
        }
    }

    func discard(token: AutoLearnPasteToken? = nil) async {
        await perform { [self] in
            guard token == nil || session?.token == token else { return }
            if let active = session {
                scheduleRestore(processID: AXProcessID(active.appElement))
            }
            session = nil
        }
    }

    /// Runs on `queue`.
    private func scheduleRestore(processID: pid_t, after delay: Double = AutoLearnAXRuntime.restoreDelaySeconds) {
        guard processID > 0 else { return }
        pendingRestores[processID]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestores[processID] = nil
            self.prewarmedAt[processID] = nil
            let appElement = AXUIElementCreateApplication(processID)
            if self.textReader.restoreWebAccessibility(processID: processID, appElement: appElement) {
                self.logger.notice(
                    "Auto Learn switched web accessibility back off for pid=\(processID, privacy: .public); its earlier value was unreadable"
                )
            }
        }
        pendingRestores[processID] = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Runs on `queue`.
    private func cancelPendingRestore(processID: pid_t) {
        pendingRestores.removeValue(forKey: processID)?.cancel()
    }

    private func AXProcessID(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return pid
    }

    private func textIsExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private func focusedElementMatches(_ targetElement: AXUIElement, in appElement: AXUIElement) -> Bool {
        guard copyBoolAttribute(kAXFrontmostAttribute, from: appElement) != false else {
            return false
        }

        if let appFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ), CFEqual(appFocusedElement, targetElement) {
            return true
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        if let systemFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ), CFEqual(systemFocusedElement, targetElement) {
            return true
        }

        return copyBoolAttribute(kAXFocusedAttribute, from: targetElement) == true
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyBoolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func pastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange,
        fieldUTF16Length: Int
    ) -> NSRange? {
        guard isValid(selectionAfterPaste, inUTF16Length: fieldUTF16Length) else { return nil }

        let pastedLength = pastedText.utf16.count
        if selectionAfterPaste.length == pastedLength {
            return selectionAfterPaste
        }

        guard selectionAfterPaste.length == 0,
            selectionAfterPaste.location >= pastedLength
        else {
            return nil
        }

        return NSRange(
            location: selectionAfterPaste.location - pastedLength,
            length: pastedLength
        )
    }

    private func resolvedPastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange?,
        fieldText: String
    ) -> NSRange? {
        let field = fieldText as NSString
        let normalizedPastedText = AutoLearnTextNormalizer.accessibilityComparable(pastedText)

        if let selectionAfterPaste {
            if let inferredRange = pastedRange(
                for: pastedText,
                selectionAfterPaste: selectionAfterPaste,
                fieldUTF16Length: field.length
            ) {
                let observedText = field.substring(with: inferredRange)
                if textIsExactlyEqual(observedText, pastedText) {
                    return inferredRange
                }
                if !normalizedPastedText.isEmpty,
                    AutoLearnTextNormalizer.accessibilityComparable(observedText)
                        == normalizedPastedText
                {
                    return inferredRange
                }
            }
        }

        let exactMatches = exactMatches(for: pastedText, in: fieldText)
        if exactMatches.count == 1 {
            return exactMatches[0]
        }

        guard let selectionAfterPaste else {
            if let boundaryMatch = uniqueBoundaryWhitespaceMatch(
                for: pastedText,
                in: fieldText
            ) {
                return boundaryMatch
            }
            return nil
        }

        if let exactMatch = nearestMatch(
            in: exactMatches,
            near: selectionAfterPaste.location,
            pastedLength: pastedText.utf16.count
        ) {
            return exactMatch
        }

        guard selectionAfterPaste.length == 0 else { return nil }

        let expectedLength = pastedText.utf16.count
        let maximumLengthAdjustment = min(max(expectedLength / 4, 8), 128)
        guard !normalizedPastedText.isEmpty else { return nil }
        let caretLocation = min(max(selectionAfterPaste.location, 0), field.length)

        // Browser editors can expose the caret immediately before their own
        // trailing whitespace. Search only the closest boundaries around it.
        for endOffset in symmetricOffsets(upTo: 8) {
            let candidateEnd = caretLocation + endOffset
            guard candidateEnd >= 0, candidateEnd <= field.length else { continue }

            for lengthOffset in symmetricOffsets(upTo: maximumLengthAdjustment) {
                let candidateLength = expectedLength + lengthOffset
                guard candidateLength >= 0, candidateLength <= candidateEnd else { continue }

                let candidateRange = NSRange(
                    location: candidateEnd - candidateLength,
                    length: candidateLength
                )
                let candidateText = field.substring(with: candidateRange)
                if AutoLearnTextNormalizer.accessibilityComparable(candidateText)
                    == normalizedPastedText
                {
                    return candidateRange
                }
            }
        }

        return nil
    }

    /// Web editors may turn pasted boundary whitespace into their own leading
    /// space or trailing newline. Match the unchanged core exactly and leave
    /// the editor-owned whitespace outside the observed pasted range.
    private func uniqueBoundaryWhitespaceMatch(
        for pastedText: String,
        in fieldText: String
    ) -> NSRange? {
        let coreText = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coreText.isEmpty, !textIsExactlyEqual(coreText, pastedText) else {
            return nil
        }

        let matches = exactMatches(for: coreText, in: fieldText)
        return matches.count == 1 ? matches[0] : nil
    }

    private func symmetricOffsets(upTo maximum: Int) -> [Int] {
        guard maximum > 0 else { return [0] }
        var offsets = [0]
        offsets.reserveCapacity(maximum * 2 + 1)
        for offset in 1...maximum {
            offsets.append(offset)
            offsets.append(-offset)
        }
        return offsets
    }

    private func exactMatches(for pastedText: String, in fieldText: String) -> [NSRange] {
        let field = fieldText as NSString
        var searchRange = NSRange(location: 0, length: field.length)
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = field.range(of: pastedText, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)

            // Advance by one UTF-16 unit so overlapping occurrences are not skipped.
            let nextLocation = match.location + 1
            guard nextLocation < field.length else { break }
            searchRange = NSRange(location: nextLocation, length: field.length - nextLocation)
        }

        return matches
    }

    private func nearestMatch(
        in matches: [NSRange],
        near location: Int,
        pastedLength: Int
    ) -> NSRange? {
        let maximumDistance = max(pastedLength, 128)
        return matches.min {
            abs(NSMaxRange($0) - location) < abs(NSMaxRange($1) - location)
        }.flatMap {
            abs(NSMaxRange($0) - location) <= maximumDistance ? $0 : nil
        }
    }

    private func isValid(_ range: NSRange, inUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
