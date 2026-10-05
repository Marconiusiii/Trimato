import Foundation
import Testing
@testable import Trimato

struct TrimatoProjectTests {
    @Test func projectTimeRoundTripsWithoutFloatingPointPersistence() throws {
        let original = ProjectTime(value: 12_345, timescale: 1_000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectTime.self, from: data)

        #expect(decoded == original)
        #expect(abs(decoded.seconds - 12.345) < 0.000_001)
    }

    @Test func projectRoundTripPreservesStableIdentifiersAndSegments() throws {
        let asset = fixtureAsset(name: "Interview", duration: 30)
        var project = TrimatoProject(name: "Documentary")
        project.media = [asset]
        let clipID = try project.append(asset: asset)
        _ = try project.splitClip(id: clipID, atTimelineTime: ProjectTime(seconds: 12))

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)

        #expect(decoded == project)
        #expect(decoded.primaryTimeline.first?.assetID == asset.id)
        #expect(decoded.primaryTimeline.map(\.displayName) == ["Interview A", "Interview B"])
        #expect(decoded.duration == ProjectTime(seconds: 30))
    }
    @Test func generatedClipsSupplyHandlesForEveryVideoTransition() throws {
        var black = fixtureAsset(name: "Black", duration: 5)
        black.hasAudio = false
        black.generator = GeneratorDefinition()
        var gradient = black
        gradient.id = UUID()
        gradient.name = "Gradient"
        gradient.generator?.kind = .gradient
        var project = TrimatoProject(name: "Generator transitions")
        project.media = [black, gradient]
        let leading = try project.append(asset: black)
        let trailing = try project.append(asset: gradient)
        let track = try #require(project.tracks.first { $0.kind == .video })
        for type in VideoTransitionType.allCases where type != .fade {
            for seconds in [0.1, 0.5, 1, 2, 5, 10] {
                var candidate = project
                try candidate.addTransition(TimelineTransition(trackID: track.id, edge: .between,
                    kind: .video(type), duration: ProjectTime(seconds: seconds),
                    leadingClipID: leading, trailingClipID: trailing))
                #expect(candidate.duration == ProjectTime(seconds: 10))
                #expect(candidate.track(id: track.id)?.clips == track.clips)
                #expect(candidate.media == project.media)
            }
            var candidate = project
            #expect(throws: ProjectTimelineError.self) {
                try candidate.addTransition(TimelineTransition(trackID: track.id, edge: .between,
                    kind: .video(type), duration: ProjectTime(seconds: 11),
                    leadingClipID: leading, trailingClipID: trailing))
            }
        }
    }

    @Test func everyVideoTransitionAcceptsSufficientImportedSourceRanges() throws {
        var first = fixtureAsset(name: "First trimmed recording", duration: 14)
        first.sourceEdit = [SourceSegment(sourceRange:
            ProjectTimeRange(start: ProjectTime(seconds: 3), duration: ProjectTime(seconds: 5)))]
        var second = first
        second.id = UUID()
        second.name = "Second trimmed recording"
        var project = TrimatoProject(name: "Imported transition timing")
        project.media = [first, second]
        let leading = try project.append(asset: first)
        let trailing = try project.append(asset: second)
        let track = try #require(project.tracks.first { $0.kind == .video })
        for type in VideoTransitionType.allCases where type != .fade {
            for seconds in [0.1, 0.5, 1, 2, 6] {
                var candidate = project
                try candidate.addTransition(TimelineTransition(trackID: track.id, edge: .between,
                    kind: .video(type), duration: ProjectTime(seconds: seconds),
                    leadingClipID: leading, trailingClipID: trailing))
                #expect(candidate.duration == project.duration)
            }
        }
    }

    @Test func importedMediaRetainsHandlesWhileColorFadesUseSelectedTime() throws {
        let first = fixtureAsset(name: "First", duration: 5)
        let second = fixtureAsset(name: "Second", duration: 5)
        var project = TrimatoProject(name: "Recorded sources")
        project.media = [first, second]
        let leading = try project.append(asset: first)
        let trailing = try project.append(asset: second)
        let track = try #require(project.tracks.first { $0.kind == .video })
        for type in VideoTransitionType.allCases where type != .fade {
            var candidate = project
            let transition = TimelineTransition(trackID: track.id, edge: .between,
                kind: .video(type), duration: ProjectTime(seconds: 2),
                leadingClipID: leading, trailingClipID: trailing)
            if type == .fadeOutIn || type == .fadeThroughWhite {
                try candidate.addTransition(transition)
                #expect(candidate.duration == ProjectTime(seconds: 10))
            } else {
                #expect(throws: ProjectTimelineError.self) { try candidate.addTransition(transition) }
            }
        }
    }

}

func fixtureAsset(name: String, duration: Double) -> MediaAssetRecord {
    let range = ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: duration))
    return MediaAssetRecord(
        name: name,
        originalPath: "/tmp/\(name).mov",
        duration: range.duration,
        naturalWidth: 1_920,
        naturalHeight: 1_080,
        frameRate: 30,
        hasAudio: true,
        sourceEdit: [SourceSegment(sourceRange: range)]
    )
}
