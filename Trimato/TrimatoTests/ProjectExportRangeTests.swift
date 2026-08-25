import Testing
@testable import Trimato

struct ProjectExportRangeTests {
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
