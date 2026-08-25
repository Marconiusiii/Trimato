import SwiftUI

struct ClipInspectorView: View {
    @ObservedObject var controller: ProjectController

    var body: some View {
        ScrollView {
            GroupBox(inspectorTitle) {
                VStack(alignment: .leading, spacing: 10) {
                    inspectorDetails
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .accessibilityLabel("\(inspectorTitle), Inspector")
    }

    private var inspectorTitle: String {
        if controller.selectedTimelineClip != nil { return "Timeline Clip Details" }
        if controller.selectedCutaway != nil { return "Cutaway Details" }
        if controller.selectedAsset != nil { return "Source Clip Details" }
        return "Project Details"
    }

    @ViewBuilder
    private var inspectorDetails: some View {
        if let clip = controller.selectedTimelineClip {
            inspectorRow("Name", clip.displayName)
            inspectorRow("Length", ProjectTimecodeFormatter.string(clip.duration))
            if let start = controller.project.startTime(of: clip.id) {
                inspectorRow("Timeline Start", ProjectTimecodeFormatter.string(start))
            }
            inspectorRow("Source Segments", "\(clip.segments.count)")
            if let asset = controller.project.asset(id: clip.assetID) {
                resolutionRows(for: asset)
            }
        } else if let cutaway = controller.selectedCutaway {
            inspectorRow("Name", cutaway.name)
            inspectorRow("Timeline Start", ProjectTimecodeFormatter.string(cutaway.start))
            inspectorRow("Length", ProjectTimecodeFormatter.string(cutaway.duration))
            inspectorRow("Audio", cutaway.audioMode == .sourceAudio ? "Source Audio" : "Primary Audio")
            if let asset = controller.project.asset(id: cutaway.assetID) {
                resolutionRows(for: asset)
            }
        } else if let asset = controller.selectedAsset {
            inspectorRow("Name", asset.name)
            inspectorRow("Length", ProjectTimecodeFormatter.string(asset.editedDuration))
            resolutionRows(for: asset)
            inspectorRow("Status", controller.resolveURL(for: asset) == nil ? "Offline" : "Ready")
            if controller.resolveURL(for: asset) == nil {
                Button("Relink Media\u{2026}") { controller.relinkSelectedAsset() }
            }
        } else {
            inspectorRow("Name", controller.project.name)
            inspectorRow("Length", ProjectTimecodeFormatter.string(controller.project.duration))
            if let target = controller.project.targetDuration {
                inspectorRow("Target Length", ProjectTimecodeFormatter.string(target))
            }
            if let width = controller.project.format.width,
               let height = controller.project.format.height {
                inspectorRow("Resolution", "\(width) by \(height)")
            } else {
                inspectorRow("Resolution", "Automatic from First Clip")
            }
            if let frameRate = controller.project.format.frameRate {
                inspectorRow("Frame Rate", frameRate.formatted())
            }
            inspectorRow("Total Clips", "\(controller.project.primaryTimeline.count)")
        }
    }

    @ViewBuilder
    private func resolutionRows(for asset: MediaAssetRecord) -> some View {
        if let width = asset.naturalWidth, let height = asset.naturalHeight {
            inspectorRow("Resolution", "\(width) by \(height)")
        }
        if let frameRate = asset.frameRate {
            inspectorRow("Frame Rate", frameRate.formatted())
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}
