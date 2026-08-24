import SwiftUI

struct ClipInspectorView: View {
    @ObservedObject var controller: ProjectController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let clip = controller.selectedTimelineClip {
                inspectorRow("Name", clip.name)
                inspectorRow("Duration", ProjectTimecodeFormatter.string(clip.duration))
                if let start = controller.project.startTime(of: clip.id) {
                    inspectorRow("Timeline Start", ProjectTimecodeFormatter.string(start))
                }
                inspectorRow("Source Portions", "\(clip.segments.count)")
            } else if let cutaway = controller.selectedCutaway {
                inspectorRow("Name", cutaway.name)
                inspectorRow("Start", ProjectTimecodeFormatter.string(cutaway.start))
                inspectorRow("Duration", ProjectTimecodeFormatter.string(cutaway.duration))
                inspectorRow("Audio", cutaway.audioMode == .sourceAudio ? "Source Audio" : "Primary Audio")
            } else if let asset = controller.selectedAsset {
                inspectorRow("Name", asset.name)
                inspectorRow("Duration", ProjectTimecodeFormatter.string(asset.editedDuration))
                inspectorRow("Status", controller.resolveURL(for: asset) == nil ? "Offline" : "Ready")
                Button("Relink Media\u{2026}") { controller.relinkSelectedAsset() }
            } else {
                inspectorRow("Project", controller.project.name)
                inspectorRow("Duration", ProjectTimecodeFormatter.string(controller.project.duration))
                if let target = controller.project.targetDuration {
                    inspectorRow("Target Duration", ProjectTimecodeFormatter.string(target))
                }
                if let width = controller.project.format.width,
                   let height = controller.project.format.height {
                    inspectorRow("Dimensions", "\(width) by \(height)")
                } else {
                    inspectorRow("Dimensions", "Automatic from First Clip")
                }
                if let frameRate = controller.project.format.frameRate {
                    inspectorRow("Frame Rate", frameRate.formatted())
                }
                inspectorRow("Clips", "\(controller.project.primaryTimeline.count)")
            }
            Spacer()
        }
        .padding(10)
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}
