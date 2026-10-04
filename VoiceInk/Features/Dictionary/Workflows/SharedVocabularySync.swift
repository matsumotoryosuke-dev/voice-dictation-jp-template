
import AppKit
import Foundation
import SwiftData

@MainActor
final class SharedVocabularySync {
    static let shared = SharedVocabularySync()

    private let queue = DispatchQueue(label: "com.prakashjoshipax.VoiceInk.sharedVocabularySync")
    private let debounceInterval: TimeInterval = 0.5

    private var modelContext: ModelContext?
    private var fileURL: URL?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var isSyncing = false
    private var started = false
    private var lastWrittenFileData: Data?
    private var lastWrittenBaseData: Data?
    // Editing the dictionary by hand posts no notification, so a slow heartbeat and the
    // app coming forward are what carry those edits to the file.
    private var heartbeat: Timer?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    func start(modelContext: ModelContext, url: URL = SharedVocabularyFile.defaultURL) {
        queue.async {
            self.modelContext = modelContext
            self.fileURL = url

            guard !self.started else {
                return
            }

            self.started = true
            self.installWatchers()
            self.scheduleSync()

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.heartbeat?.invalidate()
                let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                    Task { @MainActor [weak self] in self?.syncNow() }
                }
                self.heartbeat = timer
                self.activationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.syncNow() }
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.started = false
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil

            self.fileWatcher?.cancel()
            self.fileWatcher = nil

            self.directoryWatcher?.cancel()
            self.directoryWatcher = nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.heartbeat?.invalidate()
                self.heartbeat = nil
                if let activationObserver = self.activationObserver {
                    NotificationCenter.default.removeObserver(activationObserver)
                    self.activationObserver = nil
                }
            }

            self.modelContext = nil
            self.fileURL = nil
            self.lastWrittenFileData = nil
            self.lastWrittenBaseData = nil
        }
    }

    func syncNow() {
        Task { @MainActor [weak self] in
            await self?.performSyncIfPossible()
        }
    }

    private var baseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.prakashjoshipax.VoiceInk/shared-vocabulary-base.json")
    }

    private func scheduleSync() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            Task { @MainActor [weak self] in
                await self?.performSyncIfPossible()
            }
        }

        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func performSyncIfPossible() async {
        guard started, !isSyncing, let modelContext, let fileURL else {
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
        }

        do {
            let fileVocabulary = try readVocabulary(at: fileURL) ?? SharedVocabulary()
            let archive = try DictionaryImportExportService.makeArchive(modelContext: modelContext)
            let appVocabulary = SharedVocabularyFile.vocabulary(from: archive)
            let baseVocabulary = try readVocabulary(at: baseURL)

            let plan = SharedVocabularyFile.plan(
                base: baseVocabulary,
                file: fileVocabulary,
                app: appVocabulary
            )

            if !plan.addToApp.terms.isEmpty || !plan.addToApp.corrections.isEmpty {
                let archive = SharedVocabularyFile.archive(from: plan.addToApp, now: Date())
                _ = try await DictionaryImportExportService.apply(
                    archive: archive,
                    mode: .merge,
                    modelContext: modelContext
                )
            }

            if !plan.removeFromApp.terms.isEmpty || !plan.removeFromApp.corrections.isEmpty {
                try remove(plan.removeFromApp, from: modelContext)
            }

            let desiredFileData = try SharedVocabularyFile.encode(plan.fileContents)
            let currentFileData = try? Data(contentsOf: fileURL)

            if currentFileData != desiredFileData {
                try atomicWrite(desiredFileData, to: fileURL)
                lastWrittenFileData = desiredFileData
            }

            let desiredBaseData = try SharedVocabularyFile.encode(plan.fileContents)
            let currentBaseData = try? Data(contentsOf: baseURL)

            if currentBaseData != desiredBaseData {
                try atomicWrite(desiredBaseData, to: baseURL)
                lastWrittenBaseData = desiredBaseData
            }
        } catch {
            NSLog("SharedVocabularySync: sync failed: %@", String(describing: error))
        }
    }

    private func readVocabulary(at url: URL) throws -> SharedVocabulary? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)

            if data == lastWrittenFileData || data == lastWrittenBaseData {
                return try SharedVocabularyFile.decode(data)
            }

            return try SharedVocabularyFile.decode(data)
        } catch {
            NSLog("SharedVocabularySync: unable to read %@: %@", url.path, String(describing: error))
            return nil
        }
    }

    private func remove(
        _ vocabulary: SharedVocabulary,
        from modelContext: ModelContext
    ) throws {
        do {
            if !vocabulary.terms.isEmpty {
                let removedWords = Set(vocabulary.terms)
                let descriptor = FetchDescriptor<VocabularyWord>()
                let words = try modelContext.fetch(descriptor)

                for word in words where removedWords.contains(word.word) {
                    modelContext.delete(word)
                }
            }

            if !vocabulary.corrections.isEmpty {
                let removedSources = Set(vocabulary.corrections.keys)
                let descriptor = FetchDescriptor<WordReplacement>()
                let replacements = try modelContext.fetch(descriptor)

                for replacement in replacements {
                    let sources = WordReplacementVariants.parse(replacement.originalText)
                    let remainingSources = sources.filter { !removedSources.contains($0) }

                    guard remainingSources.count != sources.count else {
                        continue
                    }

                    if remainingSources.isEmpty {
                        modelContext.delete(replacement)
                    } else {
                        replacement.originalText = WordReplacementVariants.serialize(remainingSources)
                    }
                }
            }

            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporaryURL, options: .atomic)

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func installWatchers() {
        installDirectoryWatcher()
        installFileWatcher()
    }

    private func installDirectoryWatcher() {
        guard let fileURL else {
            return
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let descriptor = open(directoryURL.path, O_EVTONLY)

        guard descriptor >= 0 else {
            NSLog("SharedVocabularySync: unable to watch directory %@", directoryURL.path)
            return
        }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        watcher.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            self.scheduleSync()

            if watcher.data.contains(.rename) || watcher.data.contains(.delete) {
                watcher.cancel()
                self.directoryWatcher = nil
                self.installDirectoryWatcher()
                self.installFileWatcher()
            }
        }

        watcher.setCancelHandler {
            close(descriptor)
        }

        directoryWatcher?.cancel()
        directoryWatcher = watcher
        watcher.resume()
    }

    private func installFileWatcher() {
        guard let fileURL else {
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            fileWatcher?.cancel()
            fileWatcher = nil
            return
        }

        let descriptor = open(fileURL.path, O_EVTONLY)

        guard descriptor >= 0 else {
            NSLog("SharedVocabularySync: unable to watch file %@", fileURL.path)
            return
        }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        watcher.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            self.scheduleSync()

            if watcher.data.contains(.rename) || watcher.data.contains(.delete) {
                watcher.cancel()
                self.fileWatcher = nil
                self.installFileWatcher()
            }
        }

        watcher.setCancelHandler {
            close(descriptor)
        }

        fileWatcher?.cancel()
        fileWatcher = watcher
        watcher.resume()
    }
}
