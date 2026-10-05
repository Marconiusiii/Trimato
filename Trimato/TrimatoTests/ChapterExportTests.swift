import Foundation
import Testing
@testable import Trimato

struct ChapterExportTests {
    func chapters(_ times: [Double], type: TimelineMarkerType = .chapter) -> [TimelineMarker] {
        times.enumerated().map { TimelineMarker(index: $0.offset + 1, time: ProjectTime(seconds: $0.element),
            title: "Chapter \($0.offset + 1)", type: type) }
    }

    @Test func writesAscendingYouTubeDescriptionWithoutEditingCues() throws {
        let markers = chapters([20, 0, 10]) + chapters([2, 3], type: .marker)
        let data = try ChapterFileCodec.encode(markers: markers, duration: ProjectTime(seconds: 30))
        #expect(String(decoding: data, as: UTF8.self) == "00:00 Chapter 2\n00:10 Chapter 3\n00:20 Chapter 1\n")
    }

    @Test func selectedRangeStartsWithActiveChapterAndRelativeTimes() throws {
        let range = ProjectTimeRange(start: ProjectTime(seconds: 5), duration: ProjectTime(seconds: 35))
        let data = try ChapterFileCodec.encode(markers: chapters([0, 15, 25, 40]),
            duration: ProjectTime(seconds: 60), within: range)
        #expect(String(decoding: data, as: UTF8.self) == "00:00 Chapter 1\n00:10 Chapter 2\n00:20 Chapter 3\n")
    }

    @Test(arguments: [[1.0, 11, 21], [0, 20], [0, 9, 20], [0, 10, 10], [0, 10, 25]])
    func rejectsMissingStartCountSpacingAndShortFinalChapter(times: [Double]) {
        #expect(throws: ChapterFileCodec.ValidationError.self) {
            try ChapterFileCodec.encode(markers: chapters(times), duration: ProjectTime(seconds: 30))
        }
    }

    @Test func trimsMultilineTitlesAndFormatsLongVideos() throws {
        var markers = chapters([0, 3600, 3610])
        markers[1].title = "  Second\nchapter\t title  "
        let data = try ChapterFileCodec.encode(markers: markers, duration: ProjectTime(seconds: 3620))
        #expect(String(decoding: data, as: UTF8.self).contains("01:00:00 Second chapter title\n"))
        markers[1].title = " \n "
        #expect(throws: ChapterFileCodec.ValidationError.self) {
            try ChapterFileCodec.encode(markers: markers, duration: ProjectTime(seconds: 3620))
        }
    }

    @Test func createsTypedChaptersWithoutChangingMarkerDefaults() {
        var project = TrimatoProject()
        #expect(project.insertMarker(at: .zero).type == .marker)
        let chapter = project.insertMarker(at: ProjectTime(seconds: 10), type: .chapter)
        #expect(chapter.type == .chapter && chapter.title == "Chapter 2")
        #expect(project.markerTrack?.isMagnetic == false)
    }

    @Test func chapterTextIsADeclaredRelatedExportFileAndCanBeWrittenBesideTheMovie() throws {
        let types = try #require(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.contains {
            $0["CFBundleTypeName"] as? String == "YouTube Chapter File" &&
            ($0["LSItemContentTypes"] as? [String])?.contains("public.plain-text") == true &&
            $0["NSIsRelatedItemType"] as? Bool == true && $0["CFBundleTypeRole"] as? String == "None" &&
            $0["LSHandlerRank"] as? String == "None"
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        try Data().write(to: movie)
        let output = movie.deletingPathExtension().appendingPathExtension("chapters.txt")
        let data = try ChapterFileCodec.encode(markers: chapters([0, 10, 20]), duration: ProjectTime(seconds: 30))
        try RelatedExportFileWriter.write(data, to: output, relatedTo: movie)
        #expect(try Data(contentsOf: output) == data)
    }
}
