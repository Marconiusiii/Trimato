import SwiftUI

struct ProjectTimelineView: View {
    @ObservedObject var controller: ProjectController
    let openClipEditor: (EditorSelection) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            Text("Timeline")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(EditorTheme.controlSurface)

            Divider()

            if controller.project.primaryTimeline.isEmpty {
                Text("No clips in the project timeline")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 2) {
                            ForEach(Array(controller.project.primaryTimeline.enumerated()), id: \.element.id) { index, clip in
                                timelineClipButton(clip, index: index)
                            }
                        }

                        if !controller.project.cutaways.isEmpty {
                            ZStack(alignment: .leading) {
                                ForEach(controller.project.cutaways) { cutaway in
                                    cutawayButton(cutaway)
                                        .offset(x: xPosition(for: cutaway.start))
                                }
                            }
                            .frame(width: timelineWidth, alignment: .leading)
                            .frame(minHeight: cutawayMinimumHeight, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .accessibilityLabel("Timeline clips")
            }

            Divider()

            HStack {
                Menu("Selected Clip Actions") { selectedClipActions }
                    .disabled(!hasSelectedClip)
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
    }

    private var hasSelectedClip: Bool {
        controller.selectedTimelineClip != nil || controller.selectedCutaway != nil
    }

    private var minimumClipWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 220 : 140
    }

    private var maximumClipWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 520 : 420
    }

    private var cutawayMinimumHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 72 : 48
    }

    private var timelineWidth: CGFloat {
        controller.project.primaryTimeline.reduce(0) { $0 + clipWidth(for: $1.duration) } +
            CGFloat(max(controller.project.primaryTimeline.count - 1, 0)) * 2
    }

    private func clipWidth(for duration: ProjectTime) -> CGFloat {
        min(max(CGFloat(duration.seconds * 18), minimumClipWidth), maximumClipWidth)
    }

    private func xPosition(for time: ProjectTime) -> CGFloat {
        var elapsed = ProjectTime.zero
        var position: CGFloat = 0
        for clip in controller.project.primaryTimeline {
            let end = elapsed + clip.duration
            let width = clipWidth(for: clip.duration)
            if time <= end, clip.duration.isPositive {
                let fraction = min(max((time - elapsed).seconds / clip.duration.seconds, 0), 1)
                return position + width * CGFloat(fraction)
            }
            elapsed = end
            position += width + 2
        }
        return position
    }

    private func cutawayWidth(_ cutaway: TimelineCutaway) -> CGFloat {
        max(xPosition(for: cutaway.end) - xPosition(for: cutaway.start), minimumClipWidth)
    }

    private func timelineClipButton(_ clip: TimelineClip, index: Int) -> some View {
        let selection = EditorSelection.timelineClip(clip.id)
        return Button {
            select(selection)
            openClipEditor(selection)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.displayName)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(ProjectTimecodeFormatter.string(clip.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(.plain)
        .frame(width: clipWidth(for: clip.duration), alignment: .topLeading)
        .frame(minHeight: 56, alignment: .topLeading)
        .background(clipBackground(for: selection), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorTheme.separator))
        .accessibilityLabel("\(clip.displayName), clip \(index + 1) of \(controller.project.primaryTimeline.count)")
        .contextMenu { primaryClipActions(clip, index: index) }
    }

    private func cutawayButton(_ cutaway: TimelineCutaway) -> some View {
        let selection = EditorSelection.cutaway(cutaway.id)
        return Button {
            select(selection)
            openClipEditor(selection)
        } label: {
            Text(cutaway.name)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .buttonStyle(.plain)
        .frame(width: cutawayWidth(cutaway), alignment: .leading)
        .frame(minHeight: cutawayMinimumHeight, alignment: .leading)
        .background(clipBackground(for: selection), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorTheme.accent.opacity(0.75)))
        .accessibilityLabel("\(cutaway.name), cutaway")
        .accessibilityValue(cutaway.audioMode == .sourceAudio
            ? "Uses source audio"
            : "Uses primary audio")
        .contextMenu { cutawayActions(cutaway) }
    }

    private func clipBackground(for selection: EditorSelection) -> Color {
        controller.selection == selection
            ? EditorTheme.accent.opacity(0.28)
            : EditorTheme.raisedSurface
    }

    @ViewBuilder
    private var selectedClipActions: some View {
        if let clip = controller.selectedTimelineClip,
           let index = controller.project.primaryTimeline.firstIndex(where: { $0.id == clip.id }) {
            primaryClipActions(clip, index: index)
        } else if let cutaway = controller.selectedCutaway {
            cutawayActions(cutaway)
        }
    }

    @ViewBuilder
    private func primaryClipActions(_ clip: TimelineClip, index: Int) -> some View {
        Button("Open Clip Editor") {
            select(.timelineClip(clip.id))
            openClipEditor(.timelineClip(clip.id))
        }
        if index > 0 {
            Button("Move to Beginning") {
                select(.timelineClip(clip.id))
                controller.moveSelectedClipToBeginning()
            }
            Button("Move Earlier") {
                select(.timelineClip(clip.id))
                controller.moveSelectedClip(by: -1)
            }
        }
        if index < controller.project.primaryTimeline.count - 1 {
            Button("Move Later") {
                select(.timelineClip(clip.id))
                controller.moveSelectedClip(by: 1)
            }
            Button("Move to End") {
                select(.timelineClip(clip.id))
                controller.moveSelectedClipToEnd()
            }
        }
        Divider()
        Button("Delete from Timeline", role: .destructive) {
            select(.timelineClip(clip.id))
            controller.deleteSelection()
        }
    }

    @ViewBuilder
    private func cutawayActions(_ cutaway: TimelineCutaway) -> some View {
        Button("Open Clip Editor") {
            select(.cutaway(cutaway.id))
            openClipEditor(.cutaway(cutaway.id))
        }
        Divider()
        Button("Delete from Timeline", role: .destructive) {
            select(.cutaway(cutaway.id))
            controller.deleteSelection()
        }
    }

    private func select(_ selection: EditorSelection) {
        controller.selection = selection
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
