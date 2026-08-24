import SwiftUI

struct ProjectTimelineView: View {
    @ObservedObject var controller: ProjectController

    var body: some View {
        VStack(spacing: 0) {
            if controller.project.duration.isPositive {
                Slider(
                    value: Binding(
                        get: { controller.timelinePlayhead.seconds },
                        set: { controller.timelinePlayhead = ProjectTime(seconds: $0) }
                    ),
                    in: 0...max(controller.project.duration.seconds, 0.001)
                ) {
                    Text("Timeline Playhead")
                }
                .accessibilityValue(ProjectTimecodeFormatter.string(controller.timelinePlayhead))
                .padding(8)

                Divider()
            }

            List(selection: timelineSelection) {
                Section("Primary Storyline") {
                    ForEach(Array(controller.project.primaryTimeline.enumerated()), id: \.element.id) { index, clip in
                        Text("\(clip.name), clip \(index + 1) of \(controller.project.primaryTimeline.count)")
                            .tag(EditorSelection.timelineClip(clip.id))
                    }
                }

                if !controller.project.cutaways.isEmpty {
                    Section("Cutaways") {
                        ForEach(controller.project.cutaways) { cutaway in
                            Text(cutaway.name)
                                .accessibilityValue(cutaway.audioMode == .sourceAudio
                                    ? "Cutaway with source audio"
                                    : "Cutaway over primary audio")
                                .tag(EditorSelection.cutaway(cutaway.id))
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Move to Beginning") { controller.moveSelectedClipToBeginning() }
                    .disabled(controller.selectedTimelineClip == nil)
                Button("Move Earlier") { controller.moveSelectedClip(by: -1) }
                    .disabled(controller.selectedTimelineClip == nil)
                Button("Move Later") { controller.moveSelectedClip(by: 1) }
                    .disabled(controller.selectedTimelineClip == nil)
                Button("Move to End") { controller.moveSelectedClipToEnd() }
                    .disabled(controller.selectedTimelineClip == nil)
                Button("Split at Playhead") { controller.splitSelectedClip() }
                    .disabled(controller.selectedTimelineClip == nil)
                Button("Delete") { controller.deleteSelection() }
                    .disabled(controller.selectedTimelineClip == nil && controller.selectedCutaway == nil)
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
    }

    private var timelineSelection: Binding<EditorSelection?> {
        Binding(
            get: {
                switch controller.selection {
                case .timelineClip, .cutaway: controller.selection
                case .project, .asset: nil
                }
            },
            set: { selection in
                if let selection { controller.selection = selection }
            }
        )
    }
}

enum ProjectTimecodeFormatter {
    static func string(_ time: ProjectTime) -> String {
        let milliseconds = max(Int((time.seconds * 1_000).rounded()), 0)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, remainder)
    }
}
