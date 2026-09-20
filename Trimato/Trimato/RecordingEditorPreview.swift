import SwiftUI

/// The authoring session owns its temporary mix; the Editor owns its visual display.
struct RecordingEditorPreview: View {
    @AppStorage(AppPreferenceKey.precisionTimecode) private var precisionTimecode = true
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
                frameDescription: AppPreferences.passiveTimecode(seconds: session.position, precision: precisionTimecode)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            LabeledContent(session.purpose.toolTitle) {
                Text(AppPreferences.passiveTimecode(seconds: session.position, precision: precisionTimecode))
                    .monospacedDigit()
            }
            .padding(8)
            .background(EditorTheme.controlSurface)
        }
    }
}
