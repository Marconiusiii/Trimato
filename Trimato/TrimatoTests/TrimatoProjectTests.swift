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
        _ = try project.append(asset: asset)

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(TrimatoProject.self, from: data)

        #expect(decoded == project)
        #expect(decoded.primaryTimeline.first?.assetID == asset.id)
        #expect(decoded.duration == ProjectTime(seconds: 30))
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
