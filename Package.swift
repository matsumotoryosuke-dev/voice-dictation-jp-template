// swift-tools-version:5.9
// Unit tests for the app's pure decision logic, runnable without Xcode: `make test-core`.
// The target compiles the SAME files the app does (VoiceInk/ is a synchronized folder in
// the Xcode project), so tests exercise shipped code. Test files must stay outside
// VoiceInk/ or the app target would compile them too.
import PackageDescription

let package = Package(
    name: "VoiceInkCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ShortcutCore", path: "VoiceInk/Features/Shortcuts/Core"),
        .testTarget(name: "ShortcutCoreTests", dependencies: ["ShortcutCore"], path: "Tests/ShortcutCoreTests"),
        .target(name: "RecordingCore", path: "VoiceInk/Features/Recording/Core"),
        // Two files, not a directory: the codec sits beside SwiftData code it must not pull in.
        .target(name: "DictionaryCore", path: "VoiceInk/Features/Dictionary",
                sources: ["Core/SharedVocabularyFile.swift", "Workflows/DictionaryArchive.swift"]),
        .testTarget(name: "DictionaryCoreTests", dependencies: ["DictionaryCore"],
                    path: "Tests/DictionaryCoreTests"),
        .testTarget(name: "RecordingCoreTests", dependencies: ["RecordingCore"], path: "Tests/RecordingCoreTests"),
        // The text side of Auto Learn: what counts as a correction, and when a paste is gone.
        .target(name: "AutoLearnCore", path: "VoiceInk/Features/Dictionary/AutoLearn",
                sources: ["AutoLearnTypes.swift", "CorrectionDiffEngine.swift",
                          "FinalSnapshotDiffEngine.swift", "AutoLearnSnapshotTracker.swift",
                          "AutoLearnReviewText.swift", "AutoLearnReviewProposalStore.swift"]),
        .testTarget(name: "AutoLearnCoreTests", dependencies: ["AutoLearnCore"],
                    path: "Tests/AutoLearnCoreTests"),
        // What Soniox has charged, from its usage API.
        .target(name: "UsageCore", path: "VoiceInk/Features/Dashboard/Usage",
                sources: ["SonioxUsage.swift"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"], path: "Tests/UsageCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
