import Foundation
import Testing
@testable import Trimato

@Suite("Media cache")
struct MediaCacheManagerTests {
    @Test func evictionUsesLeastRecentlyUsedOrderAndProtectsOpenProjects() {
        let oldest = UUID()
        let protected = UUID()
        let newest = UUID()
        let now = Date()
        let candidates = [
            MediaCacheEvictionCandidate(cacheKey: newest, byteCount: 5, lastUsed: now),
            MediaCacheEvictionCandidate(cacheKey: oldest, byteCount: 5, lastUsed: now.addingTimeInterval(-200)),
            MediaCacheEvictionCandidate(cacheKey: protected, byteCount: 5, lastUsed: now.addingTimeInterval(-100)),
        ]

        let result = MediaCacheEvictionPolicy.keysToRemove(
            candidates: candidates,
            protectedKeys: [protected],
            totalByteCount: 15,
            availableByteCount: 100,
            maximumByteCount: 10,
            minimumAvailableByteCount: 0
        )

        #expect(result == [oldest])
    }

    @Test func evictionRestoresTheFreeSpaceFloor() {
        let first = UUID()
        let second = UUID()
        let result = MediaCacheEvictionPolicy.keysToRemove(
            candidates: [
                MediaCacheEvictionCandidate(cacheKey: first, byteCount: 5, lastUsed: .distantPast),
                MediaCacheEvictionCandidate(cacheKey: second, byteCount: 5, lastUsed: .now),
            ],
            protectedKeys: [],
            totalByteCount: 10,
            availableByteCount: 2,
            maximumByteCount: 20,
            minimumAvailableByteCount: 10
        )

        #expect(result == [first, second])
    }

    @Test func sourceFingerprintChangesWhenTheSourceChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: url.path
        )
        let first = try MediaCacheManager.sourceFingerprint(for: url)

        try Data("second version".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: url.path
        )
        let second = try MediaCacheManager.sourceFingerprint(for: url)

        #expect(first != second)
    }

    @Test func finalExportNeverSelectsThePlaybackProxy() {
        var asset = fixtureAsset(name: "Proxy Source", duration: 10)
        asset.playbackMode = .cachedProxy
        asset.proxyCacheKey = UUID()

        #expect(ProjectCompositionBuilder.mediaSelection(for: asset, purpose: .preview) == .playbackProxy)
        #expect(ProjectCompositionBuilder.mediaSelection(for: asset, purpose: .finalExport) == .original)
    }

    @Test func renderIntermediateUsesTheOriginalAtFullResolutionWithoutAScaleFilter() {
        let source = URL(fileURLWithPath: "/source/Original.mkv")
        let output = URL(fileURLWithPath: "/temporary/Intermediate.mov")

        let arguments = ProjectRenderMediaManager.arguments(
            sourceURL: source,
            outputURL: output,
            hasAudio: true
        )

        #expect(arguments.contains(source.path))
        #expect(arguments.contains("prores_ks"))
        #expect(arguments.contains("pcm_s16le"))
        #expect(!arguments.contains("-vf"))
    }
}
