import AVFoundation
import Testing
@testable import Trimato

struct ProjectExportRangeTests {
    @Test func videoPreflightRejectsAnInstructionGap() async throws {
        let asset = AVMutableComposition()
        let track = try #require(asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600000)))
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 320, height: 180)
        composition.frameDuration = CMTime(value: 1, timescale: 24)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600000))
        composition.instructions = [instruction]
        await #expect(throws: (any Error).self) {
            try await ProjectExporter.validateVideoExport(asset: asset, composition: composition,
                range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600000)))
        }
    }

    @Test func noSelectionExportsTheWholeProject() throws {
        let range = try ProjectExporter.validatedTimeRange(
            nil,
            projectDuration: ProjectTime(seconds: 10)
        )

        #expect(range == nil)
    }

    @Test func validSelectionIsPreservedForExport() throws {
        let selection = ProjectTimeRange(
            start: ProjectTime(seconds: 2),
            duration: ProjectTime(seconds: 4)
        )

        let range = try ProjectExporter.validatedTimeRange(
            selection,
            projectDuration: ProjectTime(seconds: 10)
        )

        #expect(range == selection)
    }

    @Test func selectionCannotExtendBeyondTheProject() {
        let selection = ProjectTimeRange(
            start: ProjectTime(seconds: 8),
            duration: ProjectTime(seconds: 3)
        )

        #expect(throws: ProjectExporter.ExportRangeError.invalidRange) {
            try ProjectExporter.validatedTimeRange(
                selection,
                projectDuration: ProjectTime(seconds: 10)
            )
        }
    }
}
