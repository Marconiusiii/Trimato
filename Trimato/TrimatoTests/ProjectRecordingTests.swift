import AppKit
import AVFoundation
import Testing
import SwiftUI
@testable import Trimato

@MainActor
@Suite(.serialized)
struct ProjectRecordingTests {
    @Test func recordingTimecodeFormatsAndParsesHumanReadableTimes() throws {
        let format = RecordingTimeFormat()
        #expect(format.format(2.234435) == "00:00:02.234")
        #expect(format.format(59.9999) == "00:01:00.000")
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
        controller.requestRecording(.audioDescription)
        for _ in 0..<50 where RecordingWindowRegistry.shared.closeWindow == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let tool = try #require(NSApp.windows.first { $0.title == "Describer" && $0.isVisible })
        #expect(tool.sheetParent == nil)
        #expect(tool !== coordinator.attachedWindow)
        tool.performClose(nil)
        for _ in 0..<50 where controller.recordingSession != nil { try await Task.sleep(for: .milliseconds(20)) }
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

    @Test func recordingRegistryClosesTheToolAndReleasesTheSession() async {
        let controller = ProjectController(document: ProjectDocument())
        controller.requestRecording(.voiceOver)
        guard let session = controller.recordingSession else { Issue.record("Missing session"); return }
        let registry = RecordingWindowRegistry.shared
        registry.session = session
        var closeRequests = 0
        controller.dismissRecording()
        #expect(closeRequests == 0)
        registry.installCloseAction(id: session.id) { closeRequests += 1 }
        #expect(closeRequests == 1)
        registry.finished(session)
        #expect(registry.session == nil)
        #expect(registry.closeWindow == nil)
        #expect(controller.recordingSession == nil)
        await Task.yield()
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

    @Test func describerFieldsHaveNativeLabelsAndNoPlaceholders() async throws {
        let controller = ProjectController(document: ProjectDocument())
        let session = ProjectRecordingSession(controller: controller, purpose: .audioDescription)
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
        for name in ["Clip name", "In", "Out", "Audio Ducking Amount", "Fade time, seconds", "Description text"] {
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
