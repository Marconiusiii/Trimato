import SwiftUI

nonisolated struct ProjectMediaConformance: Equatable, Sendable {
    let fit: String?
    let frameRate: String?

    static func describe(asset: MediaAssetRecord, projectFormat: ProjectFormat) -> Self {
        var fit: String?
        if let sourceWidth = asset.naturalWidth, let sourceHeight = asset.naturalHeight,
           let projectWidth = projectFormat.width, let projectHeight = projectFormat.height {
            let sourceRatio = Double(sourceWidth) / Double(max(sourceHeight, 1))
            let projectRatio = Double(projectWidth) / Double(max(projectHeight, 1))
            if abs(sourceRatio - projectRatio) > 0.001 {
                let bars = sourceRatio < projectRatio
                    ? "pillarboxed on the left and right" : "letterboxed above and below"
                fit = "Proportional Fit; \(bars) in the \(projectWidth) by \(projectHeight) project frame. The complete image remains visible without stretching or cropping."
            } else if sourceWidth != projectWidth || sourceHeight != projectHeight {
                fit = "Proportional Fit from \(sourceWidth) by \(sourceHeight) to the \(projectWidth) by \(projectHeight) project frame without stretching or cropping."
            }
        }
        var frameRateDescription: String?
        if let sourceRate = asset.frameRate, let projectRate = projectFormat.frameRate,
           abs(sourceRate - projectRate) > 0.01 {
            frameRateDescription = "\(formatRate(sourceRate)) fps source rendered at the \(formatRate(projectRate)) fps project rate. Clip speed and audio duration remain unchanged."
        }
        return Self(fit: fit, frameRate: frameRateDescription)
    }

    private static func formatRate(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...3)))
    }
}

enum ProjectInfoTarget: Hashable, Sendable {
    case selection(EditorSelection)
    case folder(UUID)
    case editor
}

struct ProjectInfoRow: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let value: String

    init(_ label: String, _ value: String, id: String? = nil) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

struct ProjectInfoSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let rows: [ProjectInfoRow]

    init(id: UUID = UUID(), title: String, rows: [ProjectInfoRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }

    static func make(target: ProjectInfoTarget, project: TrimatoProject,
                     playhead: ProjectTime, activeTrackID: UUID?,
                     technicalDetails: FFmpegMediaProbe.Report.TechnicalDetails? = nil) -> Self {
        switch target {
        case .editor:
            let activeTrack = activeTrackID.flatMap(project.track(id:))
            let directClip = activeTrack.flatMap { track in
                track.sortedClips.first(where: { $0.timelineStart == playhead }) ??
                    track.sortedClips.first(where: { playhead >= $0.timelineStart && playhead < $0.timelineEnd })
            }
            var rows = [ProjectInfoRow("Project Time", ProjectInfoTimeFormatter.string(playhead))]
            if let activeTrack { rows.append(ProjectInfoRow("Track", activeTrack.name)) }
            if let directClip { rows.append(ProjectInfoRow("Clip", directClip.displayName)) }
            rows.append(ProjectInfoRow("Project", project.name))
            return Self(title: infoTitle(project.name), rows: rows)
        case .folder(let id):
            guard let folder = project.folders.first(where: { $0.id == id }) else {
                return projectSnapshot(project)
            }
            return Self(title: infoTitle(folder.name), rows: [
                ProjectInfoRow("Type", "Folder"),
                ProjectInfoRow("Clips", "\(folder.assetIDs.count)")
            ])
        case .selection(let selection):
            return selectionSnapshot(selection, project: project, technicalDetails: technicalDetails)
        }
    }

    private static func selectionSnapshot(
        _ selection: EditorSelection,
        project: TrimatoProject,
        technicalDetails: FFmpegMediaProbe.Report.TechnicalDetails?
    ) -> Self {
        switch selection {
        case .asset(let id):
            guard let asset = project.asset(id: id) else { return projectSnapshot(project) }
            return assetSnapshot(asset, project: project, technicalDetails: technicalDetails)
        case .timelineClip(let id):
            guard let clip = project.timelineClip(id: id) else { return projectSnapshot(project) }
            var rows = clipRows(clip, project: project)
            if let asset = project.asset(id: clip.assetID) {
                rows.append(contentsOf: mediaRows(asset, project: project, technicalDetails: technicalDetails))
            }
            return Self(title: infoTitle(clip.displayName), rows: rows)
        case .cutaway(let id):
            guard let cutaway = project.cutaways.first(where: { $0.id == id }) else {
                return projectSnapshot(project)
            }
            var rows = [
                ProjectInfoRow("Timeline Start", ProjectInfoTimeFormatter.string(cutaway.start)),
                ProjectInfoRow("Length", ProjectInfoTimeFormatter.string(cutaway.duration)),
                ProjectInfoRow("Audio", cutaway.audioMode == .sourceAudio ? "Source Audio" : "Primary Audio")
            ]
            if let asset = project.asset(id: cutaway.assetID) {
                rows.append(contentsOf: mediaRows(asset, project: project, technicalDetails: technicalDetails))
            }
            return Self(title: infoTitle(cutaway.displayName), rows: rows)
        case .transition(let id):
            guard let transition = project.transition(id: id) else { return projectSnapshot(project) }
            let position: String
            switch transition.edge {
            case .intro: position = "Fade In"
            case .outro: position = "Fade Out"
            case .between: position = "Between Clips"
            }
            return Self(title: infoTitle(transition.displayName), rows: [
                ProjectInfoRow("Duration", ProjectInfoTimeFormatter.string(transition.duration)),
                ProjectInfoRow("Position", position)
            ])
        case .track(let id):
            guard let track = project.track(id: id) else { return projectSnapshot(project) }
            return Self(title: infoTitle(track.name), rows: [
                ProjectInfoRow("Type", track.kind.title),
                ProjectInfoRow("Clips", "\(track.clips.count)")
            ])
        case .project:
            return projectSnapshot(project)
        }
    }

    private static func projectSnapshot(_ project: TrimatoProject) -> Self {
        var rows = [
            ProjectInfoRow("Name", project.name),
            ProjectInfoRow("Length", ProjectInfoTimeFormatter.string(project.duration))
        ]
        if let target = project.targetDuration {
            rows.append(ProjectInfoRow("Target Length", ProjectInfoTimeFormatter.string(target)))
        }
        if let width = project.format.width, let height = project.format.height {
            rows.append(ProjectInfoRow("Resolution", "\(width) by \(height)"))
        } else {
            rows.append(ProjectInfoRow("Resolution", "Automatic from First Clip"))
        }
        if let frameRate = project.format.frameRate {
            rows.append(ProjectInfoRow("Frame Rate", frameRate.formatted()))
        }
        rows.append(ProjectInfoRow("Total Clips", "\(project.tracks.reduce(0) { $0 + $1.clips.count })"))
        return Self(title: infoTitle(project.name), rows: rows)
    }

    private static func assetSnapshot(
        _ asset: MediaAssetRecord,
        project: TrimatoProject,
        technicalDetails: FFmpegMediaProbe.Report.TechnicalDetails?
    ) -> Self {
        var rows = [ProjectInfoRow("Length", ProjectInfoTimeFormatter.string(asset.editedDuration))]
        rows.append(contentsOf: mediaRows(asset, project: project, technicalDetails: technicalDetails))
        return Self(title: infoTitle(asset.name), rows: rows)
    }

    private static func clipRows(_ clip: TimelineClip, project: TrimatoProject) -> [ProjectInfoRow] {
        var rows = [ProjectInfoRow("Length", ProjectInfoTimeFormatter.string(clip.duration))]
        if project.tracks.contains(where: {
            $0.role == .additional && $0.clips.contains { $0.id == clip.id }
        }) {
            rows.append(ProjectInfoRow("Timeline Start", ProjectInfoTimeFormatter.string(clip.visibleTimelineStart)))
            if clip.hiddenBeforeTimeline.isPositive {
                rows.append(ProjectInfoRow("Hidden Before Timeline", ProjectInfoTimeFormatter.string(clip.hiddenBeforeTimeline)))
                rows.append(ProjectInfoRow("Visible Length", ProjectInfoTimeFormatter.string(clip.visibleDuration)))
            }
        } else if let start = project.startTime(of: clip.id) {
            rows.append(ProjectInfoRow("Timeline Start", ProjectInfoTimeFormatter.string(start)))
        }
        rows.append(ProjectInfoRow("Source Segments", "\(clip.segments.count)"))
        if project.tracks.contains(where: { $0.kind == .audio && $0.clips.contains { $0.id == clip.id } }) {
            rows.append(ProjectInfoRow("Gain", "\(clip.audioSettings.gainDecibels.formatted()) dB"))
        }
        return rows
    }

    private static func mediaRows(
        _ asset: MediaAssetRecord,
        project: TrimatoProject,
        technicalDetails: FFmpegMediaProbe.Report.TechnicalDetails?
    ) -> [ProjectInfoRow] {
        var rows: [ProjectInfoRow] = []
        if let container = technicalDetails?.container {
            rows.append(ProjectInfoRow("Container", container))
        }
        if let videoCodec = technicalDetails?.videoCodec {
            rows.append(ProjectInfoRow("Video Codec", videoCodec))
        }
        if let audioCodec = technicalDetails?.audioCodec {
            rows.append(ProjectInfoRow("Audio Codec", audioCodec))
        }
        if let encoder = technicalDetails?.encoder {
            rows.append(ProjectInfoRow("Encoder", encoder))
        }
        if let width = asset.naturalWidth, let height = asset.naturalHeight {
            rows.append(ProjectInfoRow("Resolution", "\(width) by \(height)"))
        }
        if let frameRate = asset.frameRate {
            rows.append(ProjectInfoRow("Frame Rate", frameRate.formatted()))
        }
        let conformance = ProjectMediaConformance.describe(asset: asset, projectFormat: project.format)
        if let fit = conformance.fit { rows.append(ProjectInfoRow("Project Fit", fit)) }
        if let frameRate = conformance.frameRate {
            rows.append(ProjectInfoRow("Frame Rate Conversion", frameRate))
        }
        return rows
    }

    private static func infoTitle(_ name: String) -> String {
        "\(name) Info"
    }
}

enum ProjectInfoTimeFormatter {
    static func string(_ time: ProjectTime) -> String {
        ProjectPlayerViewModel.accessibilityTimeLabel(
            time: time,
            showingFrames: false,
            frameRate: 30
        )
    }
}

struct ProjectInfoView: View {
    let snapshot: ProjectInfoSnapshot
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snapshot.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            ForEach(snapshot.rows) { row in
                Text("\(row.label): \(row.value)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 440)
        .navigationTitle(snapshot.title)
        .task {
            await Task.yield()
            headingFocused = true
        }
    }
}
