import Foundation
import Testing
@testable import TrimatoMediaSupport

struct RelatedExportFileWriterTests {
    @Test func cancelledCaptionWritePreservesExistingFiles() async throws {
        let root = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("movie.mov"), captions = root.appendingPathComponent("movie.vtt")
        try Data("movie".utf8).write(to: movie)
        try Data("old captions".utf8).write(to: captions)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try RelatedExportFileWriter.write(Data("new captions".utf8), to: captions, relatedTo: movie)
        }
        do { try await task.value; Issue.record("Cancelled captions were written") } catch is CancellationError { }
        #expect(try Data(contentsOf: captions) == Data("old captions".utf8))
        #expect(try Data(contentsOf: movie) == Data("movie".utf8))
        try RelatedExportFileWriter.write(Data("new captions".utf8), to: captions, relatedTo: movie)
        #expect(try Data(contentsOf: captions) == Data("new captions".utf8))
    }

    @Test func captionWriteFailurePreservesCompletedMedia() throws {
        let root = try MediaFileTransferTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("movie.mov")
        try Data("completed movie".utf8).write(to: movie)
        let invalid = movie.appendingPathComponent("captions.vtt")
        #expect(throws: (any Error).self) {
            try RelatedExportFileWriter.write(Data("captions".utf8), to: invalid, relatedTo: movie)
        }
        #expect(try Data(contentsOf: movie) == Data("completed movie".utf8))
    }
}
