import Foundation

nonisolated enum ProjectSourceItemID: Hashable, Sendable {
    case project(UUID)
    case timeline(UUID)
    case clips(UUID)
    case folder(UUID)
    case asset(UUID)
}

nonisolated struct ProjectSourceItem: Identifiable, Equatable, Sendable {
    let id: ProjectSourceItemID
    let name: String
    let children: [ProjectSourceItem]

    var isExpandable: Bool {
        switch id {
        case .project, .clips, .folder: true
        case .timeline, .asset: false
        }
    }

    static func hierarchy(for project: TrimatoProject) -> ProjectSourceItem {
        let filedIDs = Set(project.folders.flatMap(\.assetIDs))
        let unfiled = project.media
            .filter { !filedIDs.contains($0.id) }
            .map { ProjectSourceItem(id: .asset($0.id), name: $0.name, children: []) }
        let folders = project.folders.map { folder in
            ProjectSourceItem(
                id: .folder(folder.id),
                name: folder.name,
                children: folder.assetIDs.compactMap { id in
                    project.asset(id: id).map {
                        ProjectSourceItem(id: .asset($0.id), name: $0.name, children: [])
                    }
                }
            )
        }
        return ProjectSourceItem(
            id: .project(project.id),
            name: project.name,
            children: [
                ProjectSourceItem(id: .timeline(project.id), name: "Project Timeline", children: []),
                ProjectSourceItem(id: .clips(project.id), name: "Clips", children: unfiled),
            ] + folders
        )
    }

    func item(withID requestedID: ProjectSourceItemID) -> ProjectSourceItem? {
        if id == requestedID { return self }
        for child in children {
            if let match = child.item(withID: requestedID) { return match }
        }
        return nil
    }

    static func sourceID(for selection: EditorSelection, projectID: UUID) -> ProjectSourceItemID {
        switch selection {
        case .asset(let id): .asset(id)
        case .project, .timelineClip, .cutaway: .timeline(projectID)
        }
    }
}
