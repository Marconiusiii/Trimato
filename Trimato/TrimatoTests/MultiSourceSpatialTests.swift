import AVFoundation
import Testing
@testable import Trimato

@MainActor @Suite(.serialized)
struct MultiSourceSpatialTests {
    nonisolated static let userProject = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/proClips/proClips.trimato/project.json")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: userProject.path)), arguments: [ExportFormat.h264MP4, .hevcMP4])
    func savedProjectStereoMP4CoversTheExactExportDuration(format: ExportFormat) async throws {
        let project = try JSONDecoder().decode(TrimatoProject.self, from: Data(contentsOf: Self.userProject))
        let urls = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, URL(fileURLWithPath: $0.originalPath)) })
        let result = try await ProjectCompositionBuilder.build(project: project, mediaURLs: urls,
            purpose: .finalExport, preserveHDR: format == .hevcMP4, audioMode: .highQualityStereo)
        defer { for url in result.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        let video = try #require(result.videoComposition)
        let duration = try await result.composition.load(.duration)
        print("Stereo export timing: project=\(project.duration.seconds), composition=\(duration.seconds), instructions=\(video.instructions.last?.timeRange.end.seconds ?? -1)")
        #expect(video.isValid(for: result.composition, timeRange: CMTimeRange(start: .zero, duration: duration), validationDelegate: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-mp4-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("full.mp4")
        try await ProjectExporter.export(project: project, mediaURLs: urls, format: format, to: output,
            audioMode: .highQualityStereo, progress: { _ in }, preserveHDR: format == .hevcMP4)
        let exported = AVURLAsset(url: output)
        #expect(abs(try await exported.load(.duration).seconds - project.duration.seconds) < 1.0 / 24)
        let videoTracks = try await exported.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        let picture = try #require(videoTracks.first)
        let size = try await picture.load(.naturalSize)
        #expect(Int(size.width) == project.format.width)
        #expect(Int(size.height) == project.format.height)
        if format == .hevcMP4 {
            #expect(try await VideoColorPolicy.resolve(asset: exported, preserveHDR: true) == .hlg)
        }
        #expect(try await exported.loadTracks(withMediaType: .audio).count == 1)
        let audio = try await SpatialAudioProcessingTests.samples(exported, index: 0)
        #expect(audio.channels == 2)
        #expect(audio.values.contains { abs($0) > 0.0001 })
        let selection = ProjectTimeRange(start: ProjectTime(seconds: 1.125), duration: ProjectTime(seconds: 2.375))
        let selectedOutput = directory.appendingPathComponent("selection.mp4")
        try await ProjectExporter.export(project: project, mediaURLs: urls, timeRange: selection,
            format: format, to: selectedOutput, audioMode: .highQualityStereo, progress: { _ in }, preserveHDR: format == .hevcMP4)
        let selectedAsset = AVURLAsset(url: selectedOutput)
        #expect(abs(try await selectedAsset.load(.duration).seconds - selection.duration.seconds) < 1.0 / 24)
        let selectedAudio = try await SpatialAudioProcessingTests.samples(selectedAsset, index: 0)
        #expect(selectedAudio.channels == 2)
        #expect(selectedAudio.values.contains { abs($0) > 0.0001 })
    }

    @Test func invalidVideoCompositionHasAnExplanationAndTechnicalDetails() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.invalidVideoComposition.rawValue)
        let message = ProjectExporter.userFacingMessage(for: error)
        #expect(message.contains("video timeline could not be prepared"))
        #expect(message.contains("-11841"))
        #expect(!message.contains("couldn’t be completed"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: userProject.path)))
    func savedCinematicProjectPreviewsAndExportsBothAudioChoices() async throws {
        let data = try Data(contentsOf: Self.userProject)
        var project = try JSONDecoder().decode(TrimatoProject.self, from: data)
        let used = Set(project.tracks.flatMap(\.clips).map(\.assetID))
        if let third = project.media.first(where: { !used.contains($0.id) }) {
            _ = try project.append(asset: third, segments: [.init(sourceRange: .init(start: .zero, duration: ProjectTime(seconds: 1)))])
        }
        #expect(Set(project.tracks.filter { $0.kind == .audio }.flatMap(\.clips).map(\.assetID)).count == 3)
        let reopened = try JSONDecoder().decode(TrimatoProject.self, from: JSONEncoder().encode(project))
        #expect(reopened == project)
        let urls = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, URL(fileURLWithPath: $0.originalPath)) })
        let preview = try await ProjectCompositionBuilder.build(project: reopened, mediaURLs: urls)
        defer { for url in preview.temporaryMediaURLs { try? FileManager.default.removeItem(at: url) } }
        #expect(preview.spatialAudio != nil)
        #expect(preview.audioNotice == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trimato-multiple-cinematic")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("proClips-spatial.mov")
        try await ProjectExporter.export(project: reopened, mediaURLs: urls, format: .hevcMovie, to: output, progress: { _ in })
        let result = AVURLAsset(url: output)
        #expect(try await result.loadTracks(withMediaType: .audio).count == 2)
        let track = try #require(project.tracks.first { $0.kind == .audio })
        for index in 0..<2 {
            let rendered = try await SpatialAudioProcessingTests.samples(result, index: index)
            #expect(rendered.values.count == Int((project.duration.seconds * 48_000).rounded()) * rendered.channels)
            var maximum: Float = 0
            for clip in track.clips {
                let source = try #require(urls[clip.assetID])
                let original = try await SpatialAudioProcessingTests.samples(AVURLAsset(url: source), index: index)
                #expect(original.channels == rendered.channels)
                var cursor = clip.visibleTimelineStart.seconds
                for segment in clip.visibleSegments {
                    let start = Int((cursor * 48_000).rounded())
                    let end = Int(((cursor + segment.duration.seconds) * 48_000).rounded())
                    let sourceStart = Int((segment.sourceRange.start.seconds * 48_000).rounded())
                    for frame in start..<min(end, rendered.values.count / rendered.channels) {
                        for channel in 0..<rendered.channels {
                            maximum = max(maximum, abs(rendered.values[frame * rendered.channels + channel] - original.values[(sourceStart + frame - start) * original.channels + channel]))
                        }
                    }
                    cursor += segment.duration.seconds
                }
            }
            #expect(maximum < 0.000001)
        }
        let stereo = directory.appendingPathComponent("proClips-stereo.wav")
        try await ProjectExporter.export(project: reopened, mediaURLs: urls, format: .wav24, to: stereo,
            audioMode: .highQualityStereo, progress: { _ in })
        let audio = try await SpatialAudioProcessingTests.samples(AVURLAsset(url: stereo), index: 0)
        #expect(audio.channels == 2)
        let referenceStereo = try await SpatialAudioProcessingTests.samples(result, index: 0)
        #expect(zip(audio.values, referenceStereo.values).map { abs($0 - $1) }.max() ?? 1 < 0.000001)
        #expect(abs(Double(audio.values.count / 2) / 48_000 - project.duration.seconds) < 0.001)
        #expect(try Data(contentsOf: Self.userProject) == data)
    }

    @Test(.enabled(if: IPhoneMediaTests.available))
    func differentRecordingsAndCompatibleSpatialLayoutsCrossfade() async throws {
        let first = IPhoneMediaTests.sources.appendingPathComponent("4K_30fps.MOV")
        let second = IPhoneMediaTests.sources.appendingPathComponent("4K_60fps.mov")
        let plan = SpatialAudioRenderPlan(source: first, duration: 1, regions: [
            .init(sourceStart: 1, start: 0, duration: 1, gain: 1, ramp: (1, 0), sourceURL: first),
            .init(sourceStart: 2, start: 0, duration: 1, gain: 1, ramp: (0, 1), sourceURL: second)
        ])
        let output = try await plan.render()
        defer { try? FileManager.default.removeItem(at: output) }
        for index in 0..<2 {
            let a = try await SpatialAudioProcessingTests.samples(AVURLAsset(url: first), index: index)
            let b = try await SpatialAudioProcessingTests.samples(AVURLAsset(url: second), index: index)
            let result = try await SpatialAudioProcessingTests.samples(AVURLAsset(url: output), index: index)
            #expect(result.channels == b.channels)
            var maximum: Float = 0
            for frame in 0..<48_000 {
                let fraction = Float(frame) / 48_000
                for channel in 0..<result.channels {
                    let av: Float = channel < a.channels ? a.values[(48_000 + frame) * a.channels + channel] : 0
                    let bv = b.values[(96_000 + frame) * b.channels + channel]
                    maximum = max(maximum, abs(result.values[frame * result.channels + channel] - (av * (1 - fraction) + bv * fraction)))
                }
            }
            #expect(maximum < 0.000001)
        }
    }

    @Test(.enabled(if: IPhoneMediaTests.available))
    func standaloneStereoExportsKeepTheSelectedAudio() async throws {
        let source = IPhoneMediaTests.sources.appendingPathComponent("4K_60fps.mov")
        let original = try await SpatialAudioProcessingTests.samples(AVURLAsset(url: source), index: 0)
        let ranges = [CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 48_000), duration: CMTime(seconds: 1, preferredTimescale: 48_000))]
        for native in [true, false] {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: output) }
            if native {
                try await ClipExporter.export(asset: AVURLAsset(url: source), sourceRanges: ranges, sourceContentType: .quickTimeMovie,
                    format: .wav24, to: output, preserveSpatialAudio: false, progress: { _ in })
            } else {
                try await FFmpegClipExporter.export(sourceURL: source, sourceRanges: ranges, hasAudio: true,
                    format: .wav24, to: output, audioMode: .highQualityStereo, progress: { _ in })
            }
            let result = try await SpatialAudioProcessingTests.samples(AVURLAsset(url: output), index: 0)
            #expect(result.channels == 2)
            #expect(result.values.count == 96_000)
            let expected = original.values.dropFirst(96_000).prefix(96_000)
            let maximum = zip(result.values, expected).map { abs($0 - $1) }.max() ?? 1
            #expect(maximum < 0.000001)
        }
    }

    @Test func audioChoiceFiltersFormatsWithoutChangingTheChoice() {
        let model = ExportFormatSelectionModel(selectedFormat: .hevcMovie, hasCaptions: false)
        model.allFormats = [.hevcMovie, .hevcMP4, .wav24, .m4aAppleLossless]
        model.offersAudioChoice = true
        model.audioMode = .preserveSpatial
        #expect(model.availableFormats == [.hevcMovie])
        model.audioMode = .highQualityStereo
        model.selectedFormat = .wav24
        #expect(model.audioSummary.contains("24-bit"))
        model.audioMode = .preserveSpatial
        #expect(model.selectedFormat == .hevcMovie)
        #expect(model.audioMode == .preserveSpatial)
    }
}
