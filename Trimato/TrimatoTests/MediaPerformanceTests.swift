import Foundation
import Darwin
import Testing
@testable import Trimato

@MainActor
@Suite(.serialized)
struct MediaPerformanceTests {
    @Test func repeatedVoicePreviewsReleaseTheirTemporaryFiles() async throws {
        let fixture = AudioEditorRevisionTests()
        let source = try fixture.fixture(duration: 30) { time in
            Float(0.1 * sin(2 * .pi * 220 * time))
        }
        defer { try? FileManager.default.removeItem(at: source) }
        let directory = try TemporaryMediaSession.directory(named: "TrimatoClipFilters")
        func files() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        }
        let initialFiles = files()
        var filter = ClipFilter(kind: .reverb)
        filter.values["amount"] = 60
        var settings = AudioClipSettings.neutral
        settings.midGainDecibels = 3
        var elapsed: [Double] = []
        for _ in 0..<10 {
            let start = ContinuousClock.now
            let output = try await ClipFilterRenderer.render(
                source: source, filters: [filter], audio: true, duration: 30,
                segments: [fixture.segment(30)], audioSettings: settings
            )
            let duration = start.duration(to: .now).components
            elapsed.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            try FileManager.default.removeItem(at: output)
            #expect(files() == initialFiles, "A completed preview left an intermediate file behind")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("Media benchmark: ten 30-second reverb and EQ previews; first \(elapsed[0]) s; mean \(elapsed.reduce(0, +) / Double(elapsed.count)) s; peak process resident memory \(usage.ru_maxrss) bytes; temporary-file growth \(files().count - initialFiles.count).")
    }
}
