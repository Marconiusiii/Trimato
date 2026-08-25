import Testing
@testable import Trimato

@Suite("Project source hierarchy")
struct ProjectSourceItemTests {
    @Test func timelineAndClipsFolderAppearUnderTheProjectRoot() {
        let first = makeAsset(name: "Interview")
        let second = makeAsset(name: "Cutaway")
        var project = TrimatoProject(name: "Documentary")
        project.media = [first, second]

        let root = ProjectSourceItem.hierarchy(for: project)

        #expect(root.id == .project(project.id))
        #expect(root.children.map(\.id) == [
            .timeline(project.id),
            .clips(project.id),
        ])
        #expect(root.children[1].children.map(\.id) == [.asset(first.id), .asset(second.id)])
    }

    @Test func folderedClipsAppearOnceInsideTheirFolder() {
        let unfiled = makeAsset(name: "Interview")
        let filed = makeAsset(name: "B-roll")
        let folder = ProjectFolder(name: "Exterior", assetIDs: [filed.id])
        var project = TrimatoProject(name: "Documentary")
        project.media = [unfiled, filed]
        project.folders = [folder]

        let root = ProjectSourceItem.hierarchy(for: project)

        #expect(root.children.map(\.id) == [
            .timeline(project.id),
            .clips(project.id),
            .folder(folder.id),
        ])
        #expect(root.children[1].children.map(\.id) == [.asset(unfiled.id)])
        #expect(root.children.last?.children.map(\.id) == [.asset(filed.id)])
    }

    private func makeAsset(name: String) -> MediaAssetRecord {
        MediaAssetRecord(
            name: name,
            originalPath: "/tmp/\(name).mov",
            duration: ProjectTime(seconds: 5),
            hasAudio: true,
            sourceEdit: [SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero,
                duration: ProjectTime(seconds: 5)
            ))]
        )
    }
}
