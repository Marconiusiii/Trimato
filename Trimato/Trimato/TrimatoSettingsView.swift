import AppKit
import SwiftUI

struct SettingsCloseAction {
    let capture: AudioCaptureSession
    var closeWindow: () -> Void = { NSApp.keyWindow?.performClose(nil) }

    func callAsFunction() {
        capture.close()
        closeWindow()
    }
}

private struct SettingsCloseActionKey: FocusedValueKey {
    typealias Value = SettingsCloseAction
}

extension FocusedValues {
    var closeSettings: SettingsCloseAction? {
        get { self[SettingsCloseActionKey.self] }
        set { self[SettingsCloseActionKey.self] = newValue }
    }
}

struct TrimatoSettingsView: View {
    @StateObject private var capture = AudioCaptureSession()
    var body: some View {
        TabView {
            SettingsHelpPage(topic: .generalSettings) { GeneralSettingsView() }
                .tabItem { Label("General", systemImage: "gearshape") }

            SettingsHelpPage(topic: .audioSettings) { AudioRecordingSettingsView(capture: capture) }
                .tabItem { Label("Audio", systemImage: "waveform") }

            SettingsHelpPage(topic: .videoSettings) { VideoSettingsView() }
                .tabItem { Label("Video", systemImage: "video") }

            SettingsHelpPage(topic: .accessibilitySettings) { AccessibilitySettingsView() }
                .tabItem { Label("Accessibility", systemImage: "accessibility") }

            SettingsHelpPage(topic: .storageSettings) { MediaCacheSettingsView() }
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .accessibilityIdentifier(SettingsToolbarAccessibility.contentIdentifier)
        .frame(width: 600, height: 680)
        .focusedSceneValue(\.closeSettings, SettingsCloseAction(capture: capture))
        .task {
            await Task.yield()
            SettingsToolbarAccessibility.update()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            SettingsToolbarAccessibility.update()
        }
    }
}

/// SwiftUI applies TabView accessibility labels to the content, not its window toolbar.
/// Identify the owning window without adding a view or replacing its native toolbar.
@MainActor
enum SettingsToolbarAccessibility {
    static let contentIdentifier = "trimato.settings.content"

    static func update() {
        for window in NSApp.windows {
            guard let content = window.contentView,
                  containsSettingsContent(content),
                  let frame = content.superview else { continue }
            labelToolbar(in: frame)
        }
    }

    private static func containsSettingsContent(_ element: NSObject) -> Bool {
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        if element.responds(to: identifier),
           element.perform(identifier)?.takeUnretainedValue() as? String == contentIdentifier {
            return true
        }
        let children = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: children),
              let descendants = element.perform(children)?.takeUnretainedValue() as? [NSObject] else {
            return false
        }
        return descendants.contains(where: containsSettingsContent)
    }

    private static func labelToolbar(in view: NSView) {
        if view.accessibilityRole() == .toolbar {
            view.setAccessibilityLabel("Settings")
            return
        }
        for child in view.subviews { labelToolbar(in: child) }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(AppPreferenceKey.markerAudio) private var markerAudio = true
    @AppStorage(AppPreferenceKey.processingSounds) private var processingSounds = true
    @AppStorage(AppPreferenceKey.exportCompletionSound) private var exportCompletionSound = true
    @AppStorage(AppPreferenceKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(AppPreferenceKey.accentColor) private var accentColor = EditorAccent.teal
    @AppStorage(AppPreferenceKey.importedFileHandling) private var importedFileHandling = ImportedFileHandling.keep
    @AppStorage(AppPreferenceKey.autoSaveEnabled) private var autoSaveEnabled = false
    @AppStorage(AppPreferenceKey.autoSaveMinutes)
    private var autoSaveMinutes = AppPreferences.defaultAutoSaveMinutes

    private static let minutesFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: AppPreferences.autoSaveMinutesRange.lowerBound)
        formatter.maximum = NSNumber(value: AppPreferences.autoSaveMinutesRange.upperBound)
        return formatter
    }()

    @StateObject private var notificationModel = ExportNotificationSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Accent color", selection: $accentColor) {
                ForEach(EditorAccent.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)

            Text("Saving")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Auto-Save", isOn: $autoSaveEnabled)
                    if autoSaveEnabled {
                        LabeledContent("Minutes between saves") {
                            TextField("Minutes between saves", value: $autoSaveMinutes,
                                      formatter: Self.minutesFormatter, prompt: Text(""))
                                .labelsHidden()
                                .frame(width: 80)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("File handling")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker("Imported files", selection: $importedFileHandling) {
                ForEach(ImportedFileHandling.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text("Sounds").font(.headline).accessibilityAddTraits(.isHeader)
            Toggle("Marker audio", isOn: $markerAudio)
            Toggle("Processing sounds", isOn: $processingSounds)
            Toggle("Export completion sound", isOn: $exportCompletionSound)

            Text("Export notifications")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Export notification access", value: notificationModel.state.statusText)
                        .accessibilityElement(children: .combine)

                    if notificationModel.state == .notRequested {
                        Button("Allow export notifications…") {
                            notificationModel.requestAuthorization()
                        }
                        .disabled(notificationModel.isRequesting)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onAppear { notificationModel.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            notificationModel.refresh()
        }
    }
}

struct AccessibilitySettingsView: View {
    @AppStorage(AppPreferenceKey.precisionTimecode) private var precisionTimecode = true
    @AppStorage(AppPreferenceKey.timecodeFeedback)
    private var timecodeFeedback = TimecodeFeedback.live
    @AppStorage(AppPreferenceKey.timecodeVerbosity)
    private var timecodeVerbosity = TimecodeVerbosity.default

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("VoiceOver")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Timecode Feedback", selection: $timecodeFeedback) {
                        ForEach(TimecodeFeedback.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Precision Timecode", isOn: $precisionTimecode)

                    if timecodeFeedback != .off {
                        Picker("Timecode Verbosity", selection: $timecodeVerbosity) {
                            ForEach(TimecodeVerbosity.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}

struct VideoSettingsView: View {
    @AppStorage(AppPreferenceKey.preserveHDR) private var preserveHDR = true

    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Preserve HDR", isOn: $preserveHDR)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

/// Each Settings page scrolls independently above its final native Help button.
struct SettingsHelpPage<Content: View>: View {
    let topic: TrimatoHelp.Topic
    let content: Content

    init(topic: TrimatoHelp.Topic, @ViewBuilder content: () -> Content) {
        self.topic = topic
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                ContextualHelpButton(topic: topic)
            }
            .padding(20)
        }
    }
}
