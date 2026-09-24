import AppKit
import AVFoundation
import Testing
import SwiftUI
@testable import Trimato

@MainActor
@Suite(.serialized)
struct ProjectRecordingTests {
    @Test func storageCancellationAndDenialPreserveTakeAndStaySilentUntilRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let take = root.appendingPathComponent("take.wav")
        let data = InterfaceSounds.wave(notes: [440], noteLength: 1, volume: 0.01)
        try data.write(to: take)
        let backend = StoredTakeBackend(url: take)
        let capture = AudioCaptureSession(routes: AudioOutputManager(observeHardware: false),
            backend: backend, preparationDelay: .zero, playCue: { _, _ in })
        capture.record(request: AudioCaptureRequest(inputDeviceID: 10, inputUID: "test",
            outputDeviceID: 20, outputUID: "test", channel: 0, bitDepth: 24))
        for _ in 0..<100 where capture.state == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(capture.state == .recording)
        capture.stop(playCue: false)
        for _ in 0..<100 where capture.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(capture.testURL == take)
        let controller = ProjectController(document: ProjectDocument())
        var cues = 0
        let sounds = InterfaceSounds(playback: { _ in cues += 1 })
        var attempts = 0
        let session = ProjectRecordingSession(controller: controller, purpose: .voiceOver,
            capture: capture, processingSound: ProcessingSound(sounds: sounds), recordingDirectory: {
                attempts += 1
                try await Task.sleep(for: .milliseconds(800))
                #expect(cues == 0, "Folder interaction must not produce processing audio")
                if attempts == 1 { throw CancellationError() }
                if attempts == 2 { throw CocoaError(.fileWriteNoPermission) }
                return root
            })
        defer { session.close() }
        for _ in 0..<2 {
            do { try await session.saveForQuit(); Issue.record("Expected storage to stop this attempt") }
            catch { }
            #expect(!session.busy && !session.saving)
            #expect(session.capture.testURL == take)
            #expect(try Data(contentsOf: take) == data)
            #expect(controller.project.media.isEmpty)
        }
        try await session.saveForQuit()
        #expect(attempts == 3)
        #expect(controller.project.media.count == 1)
        #expect(!session.busy && !session.saving)
        let completedCueCount = cues
        try await Task.sleep(for: .milliseconds(800))
        #expect(cues == completedCueCount, "Processing sound must stop after saving")
    }

    @Test(arguments: [RecordingPurpose.voiceOver, .audioDescription])
    func recordKeepsWindowAndFocusStableForFreshAndCachedPreviews(purpose: RecordingPurpose) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try tone(at: source, seconds: 2)
        var project = TrimatoProject()
        var sourceAsset = asset(.voiceOver)
        sourceAsset.originalPath = source.path
        project.putRecording(sourceAsset, at: .zero)
        let controller = ProjectController(document: ProjectDocument(project: project))
        let backend = StoredTakeBackend(url: root.appendingPathComponent("unused.wav"))
        let capture = AudioCaptureSession(routes: AudioOutputManager(observeHardware: false),
            backend: backend, preparationDelay: .zero, playCue: { _, _ in })
        let request = AudioCaptureRequest(inputDeviceID: 10, inputUID: "test", outputDeviceID: 20,
            outputUID: "test", channel: 0, bitDepth: 24)
        let session = ProjectRecordingSession(controller: controller, purpose: purpose, capture: capture,
            startCapture: { capture.record(request: request) },
            prepareCapture: { capture.prepareInput { request } })
        let host = NSHostingView(rootView: ProjectRecordingView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); session.close() }
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<200 where session.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!session.busy)
        for _ in 0..<100 where !capture.isInputPrepared { try await Task.sleep(for: .milliseconds(10)) }
        #expect(capture.isInputPrepared)
        #expect(backend.prepareCount == 1)
        #expect(backend.beginCount == 0)
        let frame = window.frame
        let keyWindow = NSApp.keyWindow
        let responder = window.firstResponder
        let windows = Set(NSApp.windows.map(\.windowNumber))
        // A project change invalidates the cached preview for the first Record action.
        controller.document.project.masterVolumeDB = -1
        for take in 1...2 {
            #expect(capture.isInputPrepared)
            #expect(backend.prepareCount == take)
            session.toggleRecording(true)
            #expect(AudioCaptureSession.suppressesAnnouncements)
            for _ in 0..<300 where capture.state != .recording {
                try await Task.sleep(for: .milliseconds(10))
                #expect(window.frame == frame)
            }
            #expect(capture.state == .recording)
            #expect(backend.prepareCount == take, "Record must reuse the already-open input")
            #expect(backend.beginCount == take)
            #expect(window.firstResponder === responder)
            #expect(NSApp.keyWindow === keyWindow)
            #expect(Set(NSApp.windows.map(\.windowNumber)) == windows,
                "Unexpected windows: \(NSApp.windows.filter { !windows.contains($0.windowNumber) }.map { "\($0.windowNumber): \($0.title), \(type(of: $0)), visible=\($0.isVisible)" })")
            #expect(session.message == nil && capture.message == nil)
            session.toggleRecording(true)
            #expect(capture.state == .recording)
            session.toggleRecording(false)
            for _ in 0..<200 where capture.isBusy || session.busy { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!AudioCaptureSession.suppressesAnnouncements)
            #expect(window.frame == frame)
        }
    }

    @Test func newRecordingNamesAreEmpty() {
        let controller = ProjectController(document: ProjectDocument())
        for purpose in [RecordingPurpose.voiceOver, .audioDescription] {
            let session = ProjectRecordingSession(controller: controller, purpose: purpose)
            #expect(session.name.isEmpty)
            #expect(!session.hasPendingQuitEdits)
            session.close()
        }
    }

    @Test func mediaStorageObtainsAccessBeforeWritingAfterSaveAs() async throws {
        let project = URL(fileURLWithPath: "/Movies/BuddyTheCat.trimato")
        for grant in [nil, URL(fileURLWithPath: "/Movies/proClips")] {
            var events: [String] = []
            let destination = try await ProjectMediaStorage.prepare(projectURL: project, name: "Recordings",
                grantedFolder: grant, requestAccess: {
                    events.append("choose")
                    return project.deletingLastPathComponent()
                }, prepareDirectory: { url in
                    events.append("write")
                    #expect(url.path == "/Movies/Recordings")
                })
            #expect(events == ["choose", "write"])
            #expect(destination.path == "/Movies/Recordings")
        }
    }

    @Test func validMediaFolderGrantDoesNotPromptAgain() async throws {
        let project = URL(fileURLWithPath: "/Movies/BuddyTheCat.trimato")
        var writes = 0
        _ = try await ProjectMediaStorage.prepare(projectURL: project, name: "Clips",
            grantedFolder: project.deletingLastPathComponent(), requestAccess: {
                Issue.record("An existing matching grant must not prompt again")
                throw CancellationError()
            }, prepareDirectory: { _ in writes += 1 })
        #expect(writes == 1)
    }

    @Test func cancelledOrIncorrectFolderSelectionNeverWritesAndCanRetry() async throws {
        let project = URL(fileURLWithPath: "/Movies/BuddyTheCat.trimato")
        var writes = 0
        for cancelled in [true, false] {
            do {
                _ = try await ProjectMediaStorage.prepare(projectURL: project, name: "Recordings",
                    grantedFolder: nil, requestAccess: {
                        if cancelled { throw CancellationError() }
                        return URL(fileURLWithPath: "/Movies/Other")
                    }, prepareDirectory: { _ in writes += 1 })
                Issue.record("Storage must reject a cancelled or incorrect selection")
            } catch { }
        }
        #expect(writes == 0)
        _ = try await ProjectMediaStorage.prepare(projectURL: project, name: "Recordings",
            grantedFolder: nil, requestAccess: { project.deletingLastPathComponent() },
            prepareDirectory: { _ in writes += 1 })
        #expect(writes == 1)
    }

    @Test func failedDirectoryPreparationDoesNotRetryOrPromptInALoop() async throws {
        let project = URL(fileURLWithPath: "/Movies/BuddyTheCat.trimato")
        var prompts = 0
        var writes = 0
        do {
            _ = try await ProjectMediaStorage.prepare(projectURL: project, name: "Recordings",
                grantedFolder: nil, requestAccess: {
                    prompts += 1
                    return project.deletingLastPathComponent()
                }, prepareDirectory: { _ in
                    writes += 1
                    throw CocoaError(.fileWriteNoPermission)
                })
            Issue.record("The write failure must reach the recording session")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        }
        #expect(prompts == 1)
        #expect(writes == 1)
    }

    @Test func recordingTimecodeFormatsAndParsesHumanReadableTimes() throws {
        let format = RecordingTimeFormat()
        #expect(format.format(2.234435) == "00:02.234")
        #expect(format.format(59.9999) == "01:00.000")
        #expect(try format.parseStrategy.parse("01:02:03.456") == 3723.456)
        #expect(try format.parseStrategy.parse("2.25") == 2.25)
        #expect(try format.parseStrategy.parse("02:03.5") == 123.5)
        for invalid in ["", "-2", "NaN", "1:60", "1::2", "1.5:02", "infinity"] {
            #expect(throws: (any Error).self) { try format.parseStrategy.parse(invalid) }
        }
    }

    @Test func duckingSwitchPersistsAndAutomaticallyUpdatesTheProject() async throws {
        let legacy = try JSONDecoder().decode(DescriptionDucking.self, from: Data(#"{"decibels":-5,"fadeSeconds":0.25}"#.utf8))
        #expect(legacy.enabled)
        let controller = ProjectController(document: ProjectDocument())
        let session = ProjectRecordingSession(controller: controller, purpose: .audioDescription)
        defer { session.close() }
        session.ducking.enabled = false
        session.ducking.decibels = -9
        await session.applyDucking()
        #expect(controller.project.descriptionDucking == session.ducking)
        let decoded = try JSONDecoder().decode(DescriptionDucking.self, from: JSONEncoder().encode(session.ducking))
        #expect(!decoded.enabled)
        #expect(decoded.decibels == -9)
        #expect(decoded.volume == 1)
        var project = TrimatoProject()
        project.putRecording(asset(.audioDescription), at: .zero)
        #expect(decoded.ranges(in: project).isEmpty)
        session.ducking.enabled = true
        await session.applyDucking()
        #expect(controller.project.descriptionDucking.enabled)
        #expect(controller.project.descriptionDucking.decibels == -9)
    }

    @Test func openRecorderReloadsTheInputSelectionChangedInSettings() throws {
        let name = "Trimato-input-recovery-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("disconnected-headset", forKey: AppPreferenceKey.audioInputDevice)
        let routes = AudioOutputManager(defaults: defaults, observeHardware: false)
        let recording = AudioInputManager(defaults: defaults, routes: routes)
        let settings = AudioInputManager(defaults: defaults, routes: routes)
        #expect(recording.selectedUID == "disconnected-headset")
        settings.selectedUID = ""
        settings.channel = 0
        settings.bitDepth = 16
        recording.refresh()
        #expect(recording.selectedUID.isEmpty)
        #expect(recording.channel == 0)
        #expect(recording.bitDepth == 16)
        #expect(defaults.string(forKey: AppPreferenceKey.audioInputDevice) == "")
    }

    @Test func projectReplacementWaitsForCloseAndRespectsCancellation() {
        let gate = ProjectReplacementGate()
        let project = ProjectController(document: ProjectDocument())
        var finishClose: ((Bool) -> Void)?
        project.installCloseProjectAction { finishClose = $0 }
        var result: Bool?
        gate.prepare(project: project, hasOpenDocuments: true) { result = $0 }
        #expect(result == nil)
        var secondRequest: Bool?
        gate.prepare(project: project, hasOpenDocuments: true) { secondRequest = $0 }
        #expect(secondRequest == false)
        finishClose?(false)
        #expect(result == false)
        result = nil
        gate.prepare(project: project, hasOpenDocuments: true) { result = $0 }
        #expect(result == nil)
        finishClose?(true)
        #expect(result == true)
        gate.prepare(project: nil, hasOpenDocuments: true) { result = $0 }
        #expect(result == false)
        gate.prepare(project: nil, hasOpenDocuments: false) { result = $0 }
        #expect(result == true)
    }

    @Test func openingProjectsReplacesTheDocumentAndReusesAnAlreadyOpenProject() async throws {
        #expect(NSDocumentController.shared.documents.isEmpty)
        guard NSDocumentController.shared.documents.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try ProjectDocument.writeNewProject(TrimatoProject(name: "First"), toFolderAt: folder.appendingPathComponent("First"))
        let second = try ProjectDocument.writeNewProject(TrimatoProject(name: "Second"), toFolderAt: folder.appendingPathComponent("Second"))
        defer {
            for document in NSDocumentController.shared.documents where [first, second].contains(document.fileURL) {
                document.close()
            }
        }
        for url in [first, first, second] {
            await withCheckedContinuation { continuation in
                SingleProjectCoordinator.shared.openDocument(at: url) { continuation.resume() }
            }
            try await Task.sleep(for: .milliseconds(250))
            #expect(NSDocumentController.shared.documents.count == 1)
            #expect(NSDocumentController.shared.documents.first?.fileURL == url)
            let controller = try #require(ExternalMediaOpenCoordinator.shared.activeProjectController)
            controller.updateProjectSettings(name: "Saved by shortcut", format: controller.project.format, targetDuration: controller.project.targetDuration)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                isARepeat: false, keyCode: 1))
            #expect(ProjectSaveKeyboard.handle(event, controller: controller) == nil)
            for _ in 0..<20 {
                let saved = try ProjectDocument.decodeProject(from: FileWrapper(url: url))
                if saved.name == "Saved by shortcut" && !controller.document.hasUnsavedChanges { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let saved = try ProjectDocument.decodeProject(from: FileWrapper(url: url))
            #expect(saved.name == "Saved by shortcut")

        }

        // Exercise the delegate entry point used for external URL opens as well.
        NSApp.delegate?.application?(NSApp, open: [first])
        for _ in 0..<20 {
            if NSDocumentController.shared.documents.first?.fileURL == first { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(NSDocumentController.shared.documents.count == 1)
        #expect(NSDocumentController.shared.documents.first?.fileURL == first)
    }

    @Test func descriptionChangesRequireAnExplicitCloseDecisionEvenWhenNativeDocumentIsClean() async throws {
        guard NSDocumentController.shared.documents.isEmpty else { Issue.record("Expected an isolated document test"); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try ProjectDocument.writeNewProject(TrimatoProject(name: "Save baseline"), toFolderAt: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        await withCheckedContinuation { continuation in
            SingleProjectCoordinator.shared.openDocument(at: url) { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(250))
        let controller = try #require(ExternalMediaOpenCoordinator.shared.activeProjectController)
        let coordinator = try #require(controller.projectSaveCoordinator)
        let native = try #require(NSDocumentController.shared.document(for: url))
        defer { native.close() }
        let backend = StoredTakeBackend(url: folder.appendingPathComponent("unused.wav"))
        let capture = AudioCaptureSession(routes: AudioOutputManager(observeHardware: false),
            backend: backend, preparationDelay: .seconds(2), playCue: { _, _ in })
        let request = AudioCaptureRequest(inputDeviceID: 10, inputUID: "test", outputDeviceID: 20,
            outputUID: "test", channel: 0, bitDepth: 24)
        controller.recordingSession = ProjectRecordingSession(controller: controller, purpose: .audioDescription,
            capture: capture, startCapture: { capture.record(request: request) },
            prepareCapture: { capture.prepareInput { request } })
        controller.toolPane = .describer
        try await Task.sleep(for: .milliseconds(250))
        #expect(!NSApp.windows.contains { $0.title == "Describer" && $0.isVisible })
        #expect(coordinator.attachedWindow?.isVisible == true)
        #expect(controller.recordingSession?.hasPendingQuitEdits == false,
            "Preparing a microphone without a take must not prompt to save on close")
        controller.requestCloseToolPane()
        #expect(controller.recordingSession == nil)

        let cue = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "The door opens.")
        try controller.addProjectRecording(asset: nil, at: .zero, cue: cue, ducking: DescriptionDucking())
        try await Task.sleep(for: .milliseconds(100))
        native.updateChangeCount(.changeCleared)
        #expect(controller.document.hasUnsavedChanges)
        var result: Bool?
        coordinator.requestClose { result = $0 }
        #expect(coordinator.isConfirmingClose)
        #expect(result == nil)
        coordinator.chooseCloseDecision(.cancel)
        coordinator.closeConfirmationDismissed()
        #expect(result == false)
        #expect(controller.project.descriptionTranscriptTrack?.captionCues.first?.text == cue.text)
        #expect(NSDocumentController.shared.document(for: url) === native)

        // The native close button must enter the same confirmation path.
        coordinator.attachedWindow?.performClose(nil)
        for _ in 0..<50 where !coordinator.isConfirmingClose { try await Task.sleep(for: .milliseconds(20)) }
        #expect(coordinator.isConfirmingClose)
        coordinator.chooseCloseDecision(.cancel)
        coordinator.closeConfirmationDismissed()
        try await Task.sleep(for: .milliseconds(200))
        #expect(NSDocumentController.shared.document(for: url) === native)

        let quitReply = NSApp.delegate?.applicationShouldTerminate?(NSApp)
        #expect(quitReply == .terminateLater)
        for _ in 0..<50 where !coordinator.isConfirmingClose { try await Task.sleep(for: .milliseconds(20)) }
        #expect(coordinator.isConfirmingClose)
        coordinator.chooseCloseDecision(.cancel)
        coordinator.closeConfirmationDismissed()
        try await Task.sleep(for: .milliseconds(200))
        #expect(NSDocumentController.shared.document(for: url) === native)

        // Model an autosave without advancing Trimato's explicit-save baseline.
        native.updateChangeCount(.changeDone)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            native.autosave(withImplicitCancellability: false) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let autosaved = try ProjectDocument.decodeProject(from: FileWrapper(url: url))
        #expect(autosaved.descriptionTranscriptTrack?.captionCues.first?.text == cue.text)
        #expect(controller.document.hasUnsavedChanges)
        result = nil
        coordinator.requestClose { result = $0 }
        coordinator.chooseCloseDecision(.discard)
        coordinator.closeConfirmationDismissed()
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(result == true)
        let disk = try ProjectDocument.decodeProject(from: FileWrapper(url: url))
        #expect(disk.descriptionTranscriptTrack == nil)
        #expect(NSDocumentController.shared.document(for: url) == nil)
    }

    @Test func quitDelegateDefersToTheProjectCloseDecision() async throws {
        guard ExternalMediaOpenCoordinator.shared.activeProjectController == nil else { Issue.record("Expected no active project"); return }
        let controller = ProjectController(document: ProjectDocument())
        let routes = ExternalMediaOpenCoordinator.shared
        routes.register(controller: controller, openClipEditor: { _ in })
        routes.activate(controller: controller)
        defer { routes.unregister(controller: controller) }
        var asked = false
        controller.installCloseProjectAction { completion in
            asked = true
            completion(false)
        }
        let reply = NSApp.delegate?.applicationShouldTerminate?(NSApp)
        #expect(reply == .terminateLater)
        for _ in 0..<20 where !asked { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked)
    }

    @Test func failedCloseSaveKeepsChangesAndCanBeRetried() throws {
        let model = ProjectDocument(project: TrimatoProject(name: "Baseline"))
        let controller = ProjectController(document: model)
        try controller.addProjectRecording(asset: asset(.audioDescription), at: .zero,
            cue: CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "A light turns on."), ducking: DescriptionDucking())
        let native = CloseSaveTestDocument()
        native.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("save-test-\(UUID()).trimato")
        native.fileType = "com.marconius.trimato.project"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        native.addWindowController(NSWindowController(window: window))
        NSDocumentController.shared.addDocument(native)
        defer { native.close() }
        let coordinator = ProjectWindowSaveCoordinator(projectDocument: model)
        coordinator.attach(to: window)
        var result: Bool?
        coordinator.requestClose { result = $0 }
        #expect(coordinator.isConfirmingClose)
        coordinator.chooseCloseDecision(.save)
        coordinator.closeConfirmationDismissed()
        #expect(result == false)
        #expect(model.hasUnsavedChanges)
        #expect(model.project.descriptionTranscriptTrack?.captionCues.count == 1)
        #expect(model.project.media.contains { $0.recordingPurpose == .audioDescription })
        #expect(coordinator.presentedError != nil)
        #expect(NSDocumentController.shared.documents.contains(native))
        result = nil
        coordinator.requestClose { result = $0 }
        coordinator.chooseCloseDecision(.discard)
        coordinator.closeConfirmationDismissed()
        #expect(result == false)
        #expect(model.hasUnsavedChanges)
        #expect(model.project.descriptionTranscriptTrack?.captionCues.count == 1)
        #expect(model.project.media.contains { $0.recordingPurpose == .audioDescription })
        native.failSave = false
        result = nil
        coordinator.requestClose { result = $0 }
        coordinator.chooseCloseDecision(.save)
        coordinator.closeConfirmationDismissed()
        #expect(result == true)
        #expect(!model.hasUnsavedChanges)
        #expect(!NSDocumentController.shared.documents.contains(native))
    }

    @Test func recordingPaneClosesAndReleasesTheSession() async {
        let controller = ProjectController(document: ProjectDocument())
        controller.requestRecording(.voiceOver)
        #expect(controller.recordingSession != nil)
        #expect(controller.toolPane == .voicer)
        controller.requestCloseToolPane()
        #expect(!controller.isConfirmingToolClose)
        #expect(controller.recordingSession == nil)
        #expect(controller.toolPane == nil)
        await Task.yield()
    }

    @Test func switchingToolsPreservesDraftUntilDiscardIsConfirmed() {
        let controller = ProjectController(document: ProjectDocument())
        controller.requestRecording(.voiceOver)
        let original = controller.recordingSession
        original?.name = "Unfinished take"
        controller.requestRecording(.audioDescription)
        #expect(controller.isConfirmingToolClose)
        #expect(controller.recordingSession === original)
        controller.cancelToolCloseReview()
        controller.finishToolCloseReview()
        #expect(controller.recordingSession === original)
        controller.requestRecording(.audioDescription)
        controller.discardToolChanges()
        #expect(controller.recordingSession === original, "Wait until the confirmation sheet has dismissed")
        controller.finishToolCloseReview()
        #expect(controller.toolPane == .describer)
        #expect(controller.recordingSession !== original)
        controller.dismissRecording()
    }

    @Test func reopeningRecordingToolOnlyRequestsFocus() {
        let controller = ProjectController(document: ProjectDocument())
        controller.requestRecording(.voiceOver)
        let original = controller.recordingSession
        let revision = controller.toolFocusRevision
        original?.name = "Keep this draft"
        controller.requestRecording(.voiceOver)
        #expect(controller.recordingSession === original)
        #expect(controller.recordingSession?.name == "Keep this draft")
        #expect(controller.toolFocusRevision == revision + 1)
        #expect(!controller.isConfirmingToolClose)
        controller.dismissRecording()
    }

    @Test func longerTakeRemainsUnchangedWithoutAnExplicitFitChoice() async throws {
        let url = URL(fileURLWithPath: "/unused-test-take.wav")
        for duration in [2.0001, 8.0] {
            let result = try await RecordingTakeProcessor.prepare(url: url, duration: duration, available: 2, speedUp: false, trim: false)
            #expect(result.url == url)
            #expect(result.duration == duration)
        }
    }

    @Test func saveShortcutDoesNotDependOnPaneFocus() throws {
        for (flags, expected) in [(NSEvent.ModifierFlags.command, Optional(false)),
                                  ([.command, .shift], Optional(true)),
                                  ([.command, .option], nil), ([.control, .option], nil)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                isARepeat: false, keyCode: 1))
            #expect(ProjectSaveKeyboard.saveAsCommand(event) == expected)
        }
    }

    @Test(arguments: [RecordingPurpose.audioDescription, .voiceOver])
    func recordingFieldsHaveNativeLabelsAndNoPlaceholders(purpose: RecordingPurpose) async throws {
        let controller = ProjectController(document: ProjectDocument())
        var preparations = 0
        let session = ProjectRecordingSession(controller: controller, purpose: purpose, prepareCapture: { preparations += 1 })
        let host = NSHostingView(rootView: ProjectRecordingView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); session.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        func attribute(_ item: NSObject, _ key: String) -> Any? {
            item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) : nil
        }
        func descendants(_ item: NSObject) -> [NSObject] {
            [item] + ((attribute(item, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(descendants)
        }
        let elements = descendants(host)
        let names = ["\(purpose.toolTitle) Clip Name"] + (session.isDescriber
            ? ["In", "Out", "Audio Ducking Amount", "Fade time, seconds"] : ["Insert at"])
        for name in names {
            let label = try #require(elements.first {
                attribute($0, "accessibilityRole") as? String == "AXStaticText" &&
                attribute($0, "accessibilityValue") as? String == name
            })
            let targets = try #require(attribute(label, "accessibilityServesAsTitleForUIElements") as? [NSObject])
            #expect(targets.count == 1)
            let target = try #require(targets.first)
            let field = try #require(descendants(target).first {
                ["AXTextField", "AXTextArea"].contains(attribute($0, "accessibilityRole") as? String ?? "")
            }, "Missing native field for visible label: \(name)")
            #expect((attribute(field, "accessibilityPlaceholderValue") as? String ?? "").isEmpty)
        }
        if session.isDescriber {
            let editor = try #require(elements.first {
                attribute($0, "accessibilityRole") as? String == "AXTextArea" &&
                attribute($0, "accessibilityLabel") as? String == "Description text"
            })
            #expect((attribute(editor, "accessibilityPlaceholderValue") as? String ?? "").isEmpty)
            let frame = try #require(attribute(editor, "accessibilityFrame") as? NSValue)
            #expect(frame.rectValue.width >= 500, "Transcript must use the pane width instead of a narrow label column")
        }
        func tab(_ name: String) throws -> NSTabViewItem {
            try #require(descendants(host).compactMap { $0 as? NSTabViewItem }.first { $0.label == name })
        }
        let adjustmentsTab = try tab("Voice Adjustments")
        let tabView = try #require(adjustmentsTab.tabView)
        func visibleText(_ text: String) -> Bool {
            descendants(host).contains { attribute($0, "accessibilityValue") as? String == text }
        }
        func playbackButtonCount() -> Int {
            descendants(host).filter {
                attribute($0, "accessibilityRole") as? String == "AXButton" &&
                    (attribute($0, "accessibilityTitle") as? String == "Play Take" ||
                     attribute($0, "accessibilityLabel") as? String == "Play Take")
            }.count
        }
        #expect(!visibleText("Dialogue reference In"))
        #expect(playbackButtonCount() == 1)
        tabView.selectTabViewItem(adjustmentsTab)
        try await Task.sleep(for: .milliseconds(250))
        #expect(visibleText("Dialogue reference In"))
        #expect(playbackButtonCount() == 1)
        #expect(visibleText("\(purpose.toolTitle) Clip Name"))
        tabView.selectTabViewItem(try tab("Recording"))
        try await Task.sleep(for: .milliseconds(250))
        #expect(!visibleText("Dialogue reference In"))
        #expect(playbackButtonCount() == 1)
        #expect(preparations == 1, "Changing tabs must not prepare the microphone again")
        #expect(session.inputPreparationStarted)
        session.ducking.enabled = false
        try await Task.sleep(for: .milliseconds(250))
        #expect(!descendants(host).contains { attribute($0, "accessibilityValue") as? String == "Audio Ducking Amount" })
    }

    func asset(_ purpose: RecordingPurpose, duration: Double = 2) -> MediaAssetRecord {
        let length = ProjectTime(seconds: duration)
        var asset = MediaAssetRecord(name: purpose.title, originalPath: "/recording.wav", duration: length,
                                     hasAudio: true, sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: length))])
        asset.recordingPurpose = purpose
        asset.recordingRelativePath = "Recordings/recording.wav"
        return asset
    }

    @Test func recordingsRoundTripAsEditableAudioAndSeparateTranscript() throws {
        var project = TrimatoProject()
        let voice = asset(.voiceOver)
        let description = asset(.audioDescription)
        let voiceID = project.putRecording(voice, at: ProjectTime(seconds: 7))
        project.putRecording(description, at: ProjectTime(seconds: 3))
        let cue = CaptionCue(start: ProjectTime(seconds: 3), end: ProjectTime(seconds: 5), text: "A door opens.")
        try project.putDescription(cue)
        try project.addCaptionCues([CaptionCue(start: .zero, end: ProjectTime(seconds: 1), text: "Hello.")])
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
        #expect(decoded.timelineClip(id: voiceID)?.isIndependentAudio == true)
        #expect(decoded.timelineClip(id: voiceID)?.timelineStart == ProjectTime(seconds: 7))
        #expect(decoded.captionTrack?.captionCues.map(\.text) == ["Hello."])
        #expect(decoded.descriptionTranscriptTrack?.captionCues.map(\.text) == ["A door opens."])
        #expect(decoded.descriptionTranscriptTrack?.captionCues.first?.displayName == "Description: A door opens.")
        #expect(decoded.asset(id: voice.id)?.recordingRelativePath == "Recordings/recording.wav")
    }

    @Test func duckingUsesOnlyAudibleDescriptionClipsAndFollowsTheirTiming() {
        var project = TrimatoProject()
        project.putRecording(asset(.voiceOver), at: .zero)
        let id = project.putRecording(asset(.audioDescription), at: ProjectTime(seconds: 3))
        let settings = project.descriptionDucking
        var ranges = settings.ranges(in: project)
        #expect(ranges == [ProjectTimeRange(start: ProjectTime(seconds: 3), duration: ProjectTime(seconds: 2))])
        #expect(settings.volume(at: ProjectTime(seconds: 1), ranges: ranges) == 1)
        #expect(abs(settings.volume(at: ProjectTime(seconds: 4), ranges: ranges) - Float(pow(10, -5.0 / 20))) < 0.0001)
        let fading = settings.volume(at: ProjectTime(seconds: 2.875), ranges: ranges)
        #expect(fading > settings.volume && fading < 1)
        let index = project.tracks.firstIndex { $0.clips.contains { $0.id == id } }!
        project.tracks[index].clips[0].timelineStart = ProjectTime(seconds: 8)
        ranges = settings.ranges(in: project)
        #expect(ranges.first?.start == ProjectTime(seconds: 8))
        project.tracks[index].isMuted = true
        #expect(settings.ranges(in: project).isEmpty)
    }

    @Test func overlappingDescriptionsDoNotDoubleDuck() {
        let settings = DescriptionDucking()
        let ranges = [ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 3)),
                      ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 3))]
        #expect(settings.volume(at: ProjectTime(seconds: 2), ranges: ranges) == settings.volume)
    }

    @Test func upAndDownInvokeNativeSliderActionsWithoutKeyboardFocus() throws {
        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.setAccessibilityIdentifier(SettingsSliderKeyboard.identifier)
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code))
        }
        #expect(SettingsSliderKeyboard.handle(try key(126), focused: slider) == nil)
        #expect(slider.doubleValue > 50)
        #expect(SettingsSliderKeyboard.handle(try key(125), focused: slider) == nil)
        #expect(abs(slider.doubleValue - 50) < 0.001)
        #expect(SettingsSliderKeyboard.handle(try key(126, modifiers: .command), focused: slider) != nil)
        slider.setAccessibilityIdentifier("another-slider")
        #expect(SettingsSliderKeyboard.handle(try key(126), focused: slider) != nil)
    }

    @Test func newProjectIncludesRecordingsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProjectDocument.writeNewProject(TrimatoProject(name: "Test"), toFolderAt: root)
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings").path, isDirectory: &directory))
        #expect(directory.boolValue)
    }

    @Test func olderProjectsDefaultDuckingAndNoDescriptionTrack() throws {
        let data = Data(#"{"schemaVersion":4,"name":"Old project"}"#.utf8)
        let project = try JSONDecoder().decode(TrimatoProject.self, from: data)
        #expect(project.descriptionDucking == DescriptionDucking())
        #expect(project.descriptionTranscriptTrack == nil)
    }

    @Test func addingRecordingAndTranscriptIsOneUndoableProjectChange() throws {
        let document = ProjectDocument(project: TrimatoProject())
        let controller = ProjectController(document: document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.installUndoManager(undo)
        let before = document.project
        let recording = asset(.audioDescription)
        let cue = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "A door opens.")
        undo.beginUndoGrouping()
        try controller.addProjectRecording(asset: recording, at: .zero, cue: cue, ducking: DescriptionDucking())
        undo.endUndoGrouping()
        #expect(document.project.media.count == 1)
        #expect(document.project.descriptionTranscriptTrack?.captionCues.count == 1)
        undo.undo()
        #expect(document.project == before)
        undo.redo()
        #expect(document.project.media.first?.id == recording.id)
    }

    @Test func voicerKeepsItsInsertionPointAndHasNoSettingsTestLimit() {
        let controller = ProjectController(document: ProjectDocument())
        controller.timelinePlayhead = ProjectTime(seconds: 12)
        let session = ProjectRecordingSession(controller: controller, purpose: .voiceOver)
        defer { session.close() }
        controller.timelinePlayhead = ProjectTime(seconds: 30)
        #expect(session.start == 12)
        #expect(session.capture.maximumDuration == nil)
    }

    @Test func closingDescriptionEditingRestoresItsTimelineOrigin() throws {
        var project = TrimatoProject()
        let cue = CaptionCue(start: .zero, end: ProjectTime(seconds: 2), text: "A door opens.")
        try project.putDescription(cue)
        let controller = ProjectController(document: ProjectDocument(project: project))
        controller.requestRecording(.audioDescription, cue: cue)
        controller.dismissRecording()
        controller.recordingWindowDidDismiss()
        #expect(controller.timelineFocusRestoreTarget == .caption(cue.id))
        #expect(controller.activeTimelineTrackID == project.descriptionTranscriptTrack?.id)
    }

    private func tone(at url: URL, seconds: Double, frequency: Double = 440) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { channel[index] = Float(sin(Double(index) * 2 * .pi * frequency / 48_000) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @Test func speedToFitPreservesPitchAndNeverLengthensShortTakes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try tone(at: url, seconds: 2)
        let unchanged = try await RecordingTakeProcessor.prepare(url: url, duration: 2, available: 4, speedUp: true, trim: false)
        #expect(unchanged.url == url)
        #expect(unchanged.duration == 2)
        let fitted = try await RecordingTakeProcessor.prepare(url: url, duration: 2, available: 1, speedUp: true, trim: false)
        defer { try? FileManager.default.removeItem(at: fitted.url) }
        #expect(fitted.duration > 0.9 && fitted.duration <= 1)
        let file = try AVAudioFile(forReading: fitted.url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        let lower = Int(buffer.frameLength) / 5
        let upper = Int(buffer.frameLength) * 4 / 5
        let crossings = (lower..<upper).filter { samples[$0] <= 0 && samples[$0 + 1] > 0 }.count
        let frequency = Double(crossings) / (Double(upper - lower) / file.processingFormat.sampleRate)
        #expect(abs(frequency - 440) < 10)
    }

    @Test func descriptionMixDucksShowAndExportsAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let showURL = root.appendingPathComponent("show.wav")
        let descriptionURL = root.appendingPathComponent("description.wav")
        try tone(at: showURL, seconds: 4)
        try tone(at: descriptionURL, seconds: 2, frequency: 660)
        var show = asset(.voiceOver, duration: 4)
        show.originalPath = showURL.path
        show.playbackMode = .nativePassthrough
        var description = asset(.audioDescription)
        description.originalPath = descriptionURL.path
        description.playbackMode = .nativePassthrough
        var project = TrimatoProject()
        project.putRecording(show, at: .zero)
        project.putRecording(description, at: ProjectTime(seconds: 1))
        let urls = [show.id: showURL, description.id: descriptionURL]
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls)
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let parameters = try #require(result.audioMix?.inputParameters)
        var levels: [Float] = []
        for input in parameters {
            var start: Float = 0
            var end: Float = 0
            var range = CMTimeRange.zero
            #expect(input.getVolumeRamp(for: ProjectTime(seconds: 2).cmTime, startVolume: &start, endVolume: &end, timeRange: &range))
            levels.append(start)
        }
        #expect(levels.contains { abs($0 - project.descriptionDucking.volume) < 0.001 })
        #expect(levels.contains { abs($0 - 1) < 0.001 })
        let output = root.appendingPathComponent("mixed.wav")
        try await ProjectExporter.export(project: project, mediaURLs: urls, format: .wav, to: output, progress: { _ in })
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 4) < 0.1)
    }

    @Test func mixedTrackCrossfadeKeepsDescriptionOutsideDucking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let showURL = root.appendingPathComponent("show.wav")
        let descriptionURL = root.appendingPathComponent("description.wav")
        try tone(at: showURL, seconds: 6)
        try tone(at: descriptionURL, seconds: 6, frequency: 660)
        var show = asset(.voiceOver, duration: 6)
        var description = asset(.audioDescription, duration: 6)
        show.originalPath = showURL.path
        description.originalPath = descriptionURL.path
        show.playbackMode = .nativePassthrough
        description.playbackMode = .nativePassthrough
        let segments = [SourceSegment(sourceRange: ProjectTimeRange(start: ProjectTime(seconds: 1), duration: ProjectTime(seconds: 2)))]
        show.sourceEdit = segments
        description.sourceEdit = segments
        var project = TrimatoProject()
        let leading = project.putRecording(show, at: .zero)
        let trailing = project.putRecording(description, at: ProjectTime(seconds: 2))
        project.tracks[0].clips.append(contentsOf: project.tracks[1].clips)
        project.tracks.remove(at: 1)
        try project.addTransition(TimelineTransition(trackID: project.tracks[0].id, edge: .between, kind: .audio(.crossFade),
                                                      duration: ProjectTime(seconds: 1), leadingClipID: leading, trailingClipID: trailing))
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: [show.id: showURL, description.id: descriptionURL])
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let inputs = try #require(result.audioMix?.inputParameters)
        #expect(inputs.count == 4)
        var levels: [Float] = []
        for input in inputs {
            var start: Float = 0
            var end: Float = 0
            var range = CMTimeRange.zero
            #expect(input.getVolumeRamp(for: ProjectTime(seconds: 2).cmTime, startVolume: &start, endVolume: &end, timeRange: &range))
            levels.append(start)
        }
        #expect(levels.filter { $0 == 0 }.count == 2)
        #expect(levels.contains { abs($0 - project.descriptionDucking.volume) < 0.001 })
        #expect(levels.contains { abs($0 - 1) < 0.001 })
    }

    @Test func overlappingTakesUseSeparateTracksAndKeepInsertionTimes() {
        var project = TrimatoProject()
        let first = project.putRecording(asset(.voiceOver), at: .zero)
        let second = project.putRecording(asset(.voiceOver), at: ProjectTime(seconds: 1))
        #expect(project.tracks.filter { $0.kind == .audio }.count == 2)
        #expect(project.timelineClip(id: first)?.timelineStart == .zero)
        #expect(project.timelineClip(id: second)?.timelineStart == ProjectTime(seconds: 1))
    }

    @Test func nativeSwiftUIMicrophoneSliderRespondsToVerticalArrows() async throws {
        var latest = 50.0
        let host = NSHostingView(rootView: TestMicrophoneVolume { latest = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func find(_ element: NSObject) -> NSObject? {
            if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               element.value(forKey: "accessibilityIdentifier") as? String == SettingsSliderKeyboard.identifier {
                return element
            }
            guard element.responds(to: NSSelectorFromString("accessibilityChildren")),
                  let children = element.value(forKey: "accessibilityChildren") as? [NSObject] else { return nil }
            return children.lazy.compactMap(find).first
        }
        let slider = try #require(find(host))
        #expect(slider.value(forKey: "accessibilityRole") as? String == "AXSlider")
        for (key, expected) in [(UInt16(126), 51.0), (125, 50.0)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            #expect(SettingsSliderKeyboard.handle(event, focused: slider) == nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(latest == expected)
        }
    }

}

private struct TestMicrophoneVolume: View {
    @State private var value = 50.0
    let changed: (Double) -> Void
    var body: some View {
        MicrophoneVolumeSlider(value: $value).onChange(of: value) { _, value in changed(value) }
    }
}


@MainActor
private final class CloseSaveTestDocument: NSDocument {
    var failSave = true
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        completionHandler(failSave ? CocoaError(.fileWriteNoPermission) : nil)
    }
}

@MainActor
private final class StoredTakeBackend: AudioCaptureBackend {
    var isReady = false
    var configurationChanged: (() -> Void)?
    let url: URL
    init(url: URL) { self.url = url }
    var prepareCount = 0
    var beginCount = 0
    func prepare(_ request: AudioCaptureRequest) async throws { prepareCount += 1; isReady = false }
    func settle() async throws { isReady = true }
    func begin() async throws { beginCount += 1 }
    func progress() -> (AudioRecordingSummary, String?) { (AudioRecordingSummary(frames: 48_000, sampleRate: 48_000), nil) }
    func finish(playCue: Bool) async -> AudioCaptureResult {
        isReady = false
        return AudioCaptureResult(url: url, summary: AudioRecordingSummary(frames: 48_000, sampleRate: 48_000))
    }
}
