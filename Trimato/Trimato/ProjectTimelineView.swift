import SwiftUI

struct ProjectTimelineView: View {
    @ObservedObject var controller: ProjectController
    let linkedNamespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Timeline")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

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
            }

            List {
                Section("Primary Storyline") {
                    ForEach(Array(controller.project.primaryTimeline.enumerated()), id: \.element.id) { index, clip in
                        Button {
                            controller.selection = .timelineClip(clip.id)
                        } label: {
                            Text("\(clip.name), clip \(index + 1) of \(controller.project.primaryTimeline.count)")
                        }
                    }
                }

                if !controller.project.cutaways.isEmpty {
                    Section("Cutaways") {
                        ForEach(controller.project.cutaways) { cutaway in
                            Button(cutaway.name) { controller.selection = .cutaway(cutaway.id) }
                                .accessibilityValue(cutaway.audioMode == .sourceAudio
                                    ? "Cutaway with source audio"
                                    : "Cutaway over primary audio")
                        }
                    }
                }
            }
            .accessibilityLinkedGroup(id: "timeline-inspector", in: linkedNamespace)

            HStack {
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
            }
        }
        .padding(10)
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
