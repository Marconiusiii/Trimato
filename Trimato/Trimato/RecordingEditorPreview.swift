import SwiftUI

/// The authoring session owns its temporary mix; the Editor owns its visual display.
struct RecordingEditorPreview: View {
    @ObservedObject var session: ProjectRecordingSession
    let project: TrimatoProject

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayerView(
                player: session.player,
                captionCues: project.captionTrack?.captionCues ?? [],
                captionDuration: project.duration,
                captionRenderSize: project.format.width.flatMap { width in
                    project.format.height.map { CGSize(width: width, height: $0) }
                },
                accessibleFrame: project.hasTimelineVideo,
                frameDescription: ProjectTimecodeFormatter.string(ProjectTime(seconds: session.position))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            LabeledContent(session.purpose.toolTitle) {
                Text(ProjectTimecodeFormatter.string(ProjectTime(seconds: session.position)))
                    .monospacedDigit()
            }
            .padding(8)
            .background(EditorTheme.controlSurface)
        }
    }
}
