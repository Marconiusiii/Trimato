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

    @Test func renamingAProjectKeepsTheRootNodeAndDoesNotChangeStructure() {
        var project = TrimatoProject(name: "Untitled Project")
        let node = ProjectSourceNode(item: ProjectSourceItem.hierarchy(for: project))
        let originalNode = node

        project.name = "Documentary"
        let change = node.reconcile(with: ProjectSourceItem.hierarchy(for: project))

        #expect(node === originalNode)
        #expect(node.name == "Documentary")
        #expect(!change.structureChanged)
        #expect(change.renamedIDs == [.project(project.id)])
    }

    @Test func unchangedProjectSourceHierarchyProducesNoUpdate() {
        let project = TrimatoProject(name: "Documentary")
        let hierarchy = ProjectSourceItem.hierarchy(for: project)
        let node = ProjectSourceNode(item: hierarchy)

        let change = node.reconcile(with: hierarchy)

        #expect(!change.hasChanges)
    }

    @Test func importingAClipChangesStructureButKeepsExistingNodeIdentity() {
        var project = TrimatoProject(name: "Documentary")
        let node = ProjectSourceNode(item: ProjectSourceItem.hierarchy(for: project))
        let originalClipsNode = node.item(withID: .clips(project.id))
        let interview = makeAsset(name: "Interview")

        project.media = [interview]
        let change = node.reconcile(with: ProjectSourceItem.hierarchy(for: project))

        #expect(change.structureChanged)
        #expect(node.item(withID: .clips(project.id)) === originalClipsNode)
        #expect(node.item(withID: .asset(interview.id)) != nil)
    }

    @Test func reconciledHierarchyStillResolvesSelectionIDs() {
        let interview = makeAsset(name: "Interview")
        var project = TrimatoProject(name: "Documentary")
        project.media = [interview]
        let node = ProjectSourceNode(item: ProjectSourceItem.hierarchy(for: project))

        project.name = "Renamed Documentary"
        _ = node.reconcile(with: ProjectSourceItem.hierarchy(for: project))

        #expect(node.item(withID: .timeline(project.id)) != nil)
        #expect(node.item(withID: .asset(interview.id)) != nil)
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
