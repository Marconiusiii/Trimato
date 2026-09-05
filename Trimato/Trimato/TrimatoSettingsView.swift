import SwiftUI

struct TrimatoSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AccessibilitySettingsView()
                .tabItem { Label("Accessibility", systemImage: "accessibility") }

            MediaCacheSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 600, height: 600)
    }
}

private struct GeneralSettingsView: View {
    @StateObject private var notificationModel = ExportNotificationSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Export notifications") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Permission", value: notificationModel.state.statusText)
                    Text(notificationModel.state.explanation)
                        .foregroundStyle(.secondary)

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

private struct AccessibilitySettingsView: View {
    @AppStorage(AppPreferenceKey.timecodeFeedback)
    private var timecodeFeedback = TimecodeFeedback.live
    @AppStorage(AppPreferenceKey.timecodeVerbosity)
    private var timecodeVerbosity = TimecodeVerbosity.default

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("VoiceOver") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Timecode Feedback", selection: $timecodeFeedback) {
                        ForEach(TimecodeFeedback.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if timecodeFeedback != .off {
                        Picker("Timecode Verbosity", selection: $timecodeVerbosity) {
                            ForEach(TimecodeVerbosity.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if timecodeFeedback == .onDemand {
                        Text("Press T to hear the current timecode.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}
