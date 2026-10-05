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
    @Test func transitionEasePersistsAndOlderTransitionsDefaultToLinear() throws {
        var transition = TimelineTransition(trackID: UUID(), edge: .between, kind: .video(.wipeLeft),
            duration: ProjectTime(seconds: 2), leadingClipID: UUID(), trailingClipID: UUID())
        // An absent optional property matches projects saved before easing was introduced.
        let legacyData = try JSONEncoder().encode(transition)
        #expect(!String(decoding: legacyData, as: UTF8.self).contains("videoEase"))
        #expect(try JSONDecoder().decode(TimelineTransition.self, from: legacyData).effectiveVideoEase == .linear)
        for ease in VideoTransitionEase.allCases {
            transition.videoEase = ease
            let decoded = try JSONDecoder().decode(TimelineTransition.self, from: JSONEncoder().encode(transition))
            #expect(decoded == transition)
            #expect(decoded.effectiveVideoEase == ease)
        }
    }

    @Test func easingIsRestrictedToMovementTransitions() {
        let families: [VideoTransitionFamily] = [.wipes, .slide, .cover, .reveal, .circle]
        for type in VideoTransitionType.allCases {
            let transition = TimelineTransition(trackID: UUID(), edge: .between, kind: .video(type),
                duration: ProjectTime(seconds: 2), videoEase: .easyEase)
            #expect(type.supportsEasing == families.contains(type.family))
            #expect(transition.effectiveVideoEase == (families.contains(type.family) ? .easyEase : .linear))
        }
        let audio = TimelineTransition(trackID: UUID(), edge: .between, kind: .audio(.crossFade),
            duration: ProjectTime(seconds: 2), videoEase: .easeIn)
        #expect(audio.effectiveVideoEase == .linear)
    }

    @Test func easingPreservesSourceTimingAndLinearRendering() throws {
        for type in VideoTransitionType.allCases where type.supportsEasing {
            let name = try #require(FFmpegTimelineEffectRenderer.videoTransitionName(type))
            let linear = FFmpegTimelineEffectRenderer.videoTransitionGraph(leadingStart: 7, trailingStart: 1,
                type: name, duration: 2, width: 160, height: 90, frameRate: 24)
            #expect(linear.contains("xfade=transition=\(name):duration=2:offset=0"))
            for ease in VideoTransitionEase.allCases where ease != .linear {
                let graph = FFmpegTimelineEffectRenderer.videoTransitionGraph(leadingStart: 7, trailingStart: 1,
                    type: name, ease: ease, duration: 2, width: 160, height: 90, frameRate: 24)
                #expect(graph.contains("xfade=transition=custom:expr="))
                #expect(graph.contains("[0:v:0]trim=start=7:duration=2,"))
                #expect(graph.contains("[1:v:0]trim=start=1:duration=2,"))
                #expect(graph.contains(":duration=2:offset=0"))
                #expect(graph.hasSuffix("trim=duration=2,setpts=PTS-STARTPTS[outv]"))
            }
        }
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
