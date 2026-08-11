//
//  VidTimeTests.swift
//  VidTimeTests
//
//  Created by Marco Salsiccia on 5/5/26.
//

import AVFoundation
import Testing
import UniformTypeIdentifiers
@testable import VidTime

struct VidTimeTests {

    @Test func settingInAndOutMarkersReplacesPreviousValues() {
        let viewModel = VideoPlayerViewModel()
        let firstIn = CMTime(seconds: 2, preferredTimescale: 600)
        let replacementIn = CMTime(seconds: 4, preferredTimescale: 600)
        let firstOut = CMTime(seconds: 8, preferredTimescale: 600)
        let replacementOut = CMTime(seconds: 10, preferredTimescale: 600)

        viewModel.setInMarker(at: firstIn)
        viewModel.setInMarker(at: replacementIn)
        viewModel.setOutMarker(at: firstOut)
        viewModel.setOutMarker(at: replacementOut)

        #expect(viewModel.inMarker == replacementIn)
        #expect(viewModel.outMarker == replacementOut)
    }

    @Test func exportRangeRequiresInBeforeOut() {
        let earlier = CMTime(seconds: 2, preferredTimescale: 600)
        let later = CMTime(seconds: 8, preferredTimescale: 600)

        #expect(VideoPlayerViewModel.validExportRange(inMarker: earlier, outMarker: later) != nil)
        #expect(VideoPlayerViewModel.validExportRange(inMarker: later, outMarker: earlier) == nil)
        #expect(VideoPlayerViewModel.validExportRange(inMarker: earlier, outMarker: earlier) == nil)
    }

    @Test func timelinePointsAreChronologicalWhenMarkersAreReversed() {
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        let points = VideoPlayerViewModel.orderedTimelinePoints(
            duration: duration,
            inMarker: CMTime(seconds: 9, preferredTimescale: 600),
            outMarker: CMTime(seconds: 3, preferredTimescale: 600)
        )

        #expect(points.map(\.kind) == [.start, .outMarker, .inMarker, .end])
    }

    @Test func duplicateTimelinePositionsAreCollapsed() {
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        let points = VideoPlayerViewModel.orderedTimelinePoints(
            duration: duration,
            inMarker: .zero,
            outMarker: duration
        )

        #expect(points.count == 2)
        #expect(points.map(\.kind) == [.start, .outMarker])
    }

    @Test func timelineNavigationMovesStrictlyInTheRequestedDirection() {
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        let inMarker = CMTime(seconds: 3, preferredTimescale: 600)
        let outMarker = CMTime(seconds: 9, preferredTimescale: 600)

        let next = VideoPlayerViewModel.timelineDestination(
            from: inMarker,
            movingForward: true,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker
        )
        let previous = VideoPlayerViewModel.timelineDestination(
            from: outMarker,
            movingForward: false,
            duration: duration,
            inMarker: inMarker,
            outMarker: outMarker
        )

        #expect(next?.kind == .outMarker)
        #expect(previous?.kind == .inMarker)
    }

    @Test func trimmedFilenamePreservesSourceExtension() {
        let sourceURL = URL(fileURLWithPath: "/tmp/Example Clip.mp4")

        #expect(VideoPlayerViewModel.trimmedFilename(for: sourceURL) == "Example Clip-trimmed.mp4")
    }

    @Test func passthroughUsesTheOriginalContainerType() throws {
        let fileType = try ClipExporter.passthroughFileType(
            for: .mpeg4Movie,
            supportedFileTypes: [.mp4, .mov]
        )

        #expect(fileType == .mp4)
    }

    @Test func unsupportedPassthroughDoesNotFallBackToConversion() {
        do {
            _ = try ClipExporter.passthroughFileType(
                for: .mpeg4Movie,
                supportedFileTypes: [.mov]
            )
            Issue.record("Expected unsupported passthrough to throw")
        } catch let error as ClipExportError {
            #expect(error == .unsupportedFileType)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

}
