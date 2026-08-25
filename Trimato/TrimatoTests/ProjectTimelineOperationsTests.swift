import Testing
@testable import Trimato

struct ProjectTimelineOperationsTests {
    @Test func insertAtPlayheadSplitsAndPreservesBothSides() throws {
        let interview = fixtureAsset(name: "Interview", duration: 30)
        let cutaway = fixtureAsset(name: "Cutaway", duration: 5)
        var project = TrimatoProject()
        project.media = [interview, cutaway]
        _ = try project.append(asset: interview)

        _ = try project.insert(asset: cutaway, at: ProjectTime(seconds: 10))

        #expect(project.primaryTimeline.map(\.name) == ["Interview", "Cutaway", "Interview"])
        #expect(project.primaryTimeline.map(\.displayName) == ["Interview A", "Cutaway", "Interview B"])
        #expect(project.primaryTimeline.map(\.duration) == [
            ProjectTime(seconds: 10), ProjectTime(seconds: 5), ProjectTime(seconds: 20)
        ])
        #expect(project.duration == ProjectTime(seconds: 35))
    }

    @Test func bladeThenInsertFromTheSameSourceProducesAThenCThenB() throws {
        let source = fixtureAsset(name: "Clip01", duration: 30)
        let insertedRange = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 20),
            duration: ProjectTime(seconds: 3)
        ))]
        var project = TrimatoProject()
        project.media = [source]
        let originalID = try project.append(asset: source)

        _ = try project.splitClip(id: originalID, atTimelineTime: ProjectTime(seconds: 10))
        _ = try project.insert(
            asset: source,
            segments: insertedRange,
            at: ProjectTime(seconds: 10)
        )

        #expect(project.primaryTimeline.map(\.displayName) == ["Clip01 A", "Clip01 C", "Clip01 B"])
        #expect(project.primaryTimeline.map(\.duration) == [
            ProjectTime(seconds: 10),
            ProjectTime(seconds: 3),
            ProjectTime(seconds: 20),
        ])
    }

    @Test func insertingInsideAnUnsplitUseOfTheSameSourceProducesAThenCThenB() throws {
        let source = fixtureAsset(name: "Clip01", duration: 30)
        let insertedRange = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 24),
            duration: ProjectTime(seconds: 2)
        ))]
        var project = TrimatoProject()
        _ = try project.append(asset: source)

        _ = try project.insert(
            asset: source,
            segments: insertedRange,
            at: ProjectTime(seconds: 10)
        )

        #expect(project.primaryTimeline.map(\.displayName) == ["Clip01 A", "Clip01 C", "Clip01 B"])
    }

    @Test func movingLetteredClipsDoesNotRenameThem() throws {
        let source = fixtureAsset(name: "Clip-1", duration: 10)
        var project = TrimatoProject()
        let originalID = try project.append(asset: source)
        let rightID = try project.splitClip(
            id: originalID,
            atTimelineTime: ProjectTime(seconds: 4)
        )
        let namesBeforeMove = Dictionary(uniqueKeysWithValues: project.primaryTimeline.map { ($0.id, $0.displayName) })

        try project.moveClip(id: rightID, to: 0)

        #expect(project.primaryTimeline.map(\.displayName) == ["Clip-1 B", "Clip-1 A"])
        #expect(project.primaryTimeline.allSatisfy { namesBeforeMove[$0.id] == $0.displayName })
    }

    @Test func timelineLettersContinueAfterZ() throws {
        let source = fixtureAsset(name: "Clip01", duration: 1)
        var project = TrimatoProject()

        for _ in 0..<27 {
            _ = try project.append(asset: source)
        }

        #expect(project.primaryTimeline.first?.displayName == "Clip01 A")
        #expect(project.primaryTimeline[25].displayName == "Clip01 Z")
        #expect(project.primaryTimeline[26].displayName == "Clip01 AA")
    }

    @Test func replacingRemainderKeepsLeftAndLaterClips() throws {
        let interview = fixtureAsset(name: "Interview", duration: 30)
        let closing = fixtureAsset(name: "Closing", duration: 8)
        let replacement = fixtureAsset(name: "Replacement", duration: 5)
        var project = TrimatoProject()
        project.media = [interview, closing, replacement]
        _ = try project.append(asset: interview)
        _ = try project.append(asset: closing)

        _ = try project.replaceClipRemainder(with: replacement, at: ProjectTime(seconds: 10))

        #expect(project.primaryTimeline.map(\.name) == ["Interview", "Replacement", "Closing"])
        #expect(project.primaryTimeline.map(\.duration) == [
            ProjectTime(seconds: 10), ProjectTime(seconds: 5), ProjectTime(seconds: 8)
        ])
        #expect(project.duration == ProjectTime(seconds: 23))
    }

    @Test func cutawaysDoNotChangePrimaryDuration() throws {
        let interview = fixtureAsset(name: "Interview", duration: 30)
        let cutaway = fixtureAsset(name: "Cutaway", duration: 5)
        var project = TrimatoProject()
        project.media = [interview, cutaway]
        _ = try project.append(asset: interview)

        let id = try project.addCutaway(
            asset: cutaway,
            at: ProjectTime(seconds: 10),
            audioMode: .sourceAudio
        )

        #expect(project.duration == ProjectTime(seconds: 30))
        #expect(project.cutaways.first?.id == id)
        #expect(project.cutaways.first?.end == ProjectTime(seconds: 15))
    }

    @Test func overlappingAndOverhangingCutawaysAreRejected() throws {
        let interview = fixtureAsset(name: "Interview", duration: 30)
        let cutaway = fixtureAsset(name: "Cutaway", duration: 5)
        var project = TrimatoProject()
        project.media = [interview, cutaway]
        _ = try project.append(asset: interview)
        _ = try project.addCutaway(asset: cutaway, at: ProjectTime(seconds: 10), audioMode: .primaryAudio)

        #expect(throws: ProjectTimelineError.cutawayOverlap) {
            try project.addCutaway(asset: cutaway, at: ProjectTime(seconds: 12), audioMode: .sourceAudio)
        }
        #expect(throws: ProjectTimelineError.cutawayDoesNotFit) {
            try project.addCutaway(asset: cutaway, at: ProjectTime(seconds: 28), audioMode: .sourceAudio)
        }
    }

    @Test func movingAClipKeepsItsIdentity() throws {
        let first = fixtureAsset(name: "First", duration: 2)
        let second = fixtureAsset(name: "Second", duration: 3)
        var project = TrimatoProject()
        let firstID = try project.append(asset: first)
        _ = try project.append(asset: second)

        try project.moveClip(id: firstID, to: 1)

        #expect(project.primaryTimeline.map(\.name) == ["Second", "First"])
        #expect(project.primaryTimeline.last?.id == firstID)
    }

    @Test @MainActor func playheadResolutionFollowsMagneticClipReordering() throws {
        let first = fixtureAsset(name: "First", duration: 2)
        let second = fixtureAsset(name: "Second", duration: 3)
        var project = TrimatoProject()
        let firstID = try project.append(asset: first)
        let secondID = try project.append(asset: second)
        try project.moveClip(id: secondID, to: 0)
        let controller = ProjectController(document: ProjectDocument(project: project))

        #expect(controller.primaryTimelineClip(at: ProjectTime(seconds: 1))?.id == secondID)
        #expect(controller.primaryTimelineClip(at: ProjectTime(seconds: 4))?.id == firstID)
    }

    @Test func updatingOneUseOfASourceLeavesItsOtherTimelineEntryUnchanged() throws {
        let source = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject()
        project.media = [source]
        let firstID = try project.append(asset: source)
        let secondID = try project.append(asset: source)
        let replacement = [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 1),
            duration: ProjectTime(seconds: 3)
        ))]

        try project.updateTimelineClip(id: firstID, segments: replacement)

        #expect(project.primaryTimeline.first(where: { $0.id == firstID })?.segments == replacement)
        #expect(project.primaryTimeline.first(where: { $0.id == secondID })?.duration == ProjectTime(seconds: 10))
    }

    @Test func updatingAClipChangesDurationAndMagneticallyMovesTheFollowingClip() throws {
        let first = fixtureAsset(name: "Interview", duration: 10)
        let second = fixtureAsset(name: "Closing", duration: 5)
        var project = TrimatoProject()
        project.media = [first, second]
        let firstID = try project.append(asset: first)
        let secondID = try project.append(asset: second)

        try project.updateTimelineClip(id: firstID, segments: [SourceSegment(sourceRange: ProjectTimeRange(
            start: ProjectTime(seconds: 1),
            duration: ProjectTime(seconds: 3)
        ))])

        #expect(project.startTime(of: secondID) == ProjectTime(seconds: 3))
        #expect(project.duration == ProjectTime(seconds: 8))
    }

    @Test func shorteningTheStorylineCannotLeaveACutawayBeyondItsEnd() throws {
        let primary = fixtureAsset(name: "Interview", duration: 10)
        let cutaway = fixtureAsset(name: "Cutaway", duration: 3)
        var project = TrimatoProject()
        project.media = [primary, cutaway]
        let primaryID = try project.append(asset: primary)
        _ = try project.addCutaway(
            asset: cutaway,
            at: ProjectTime(seconds: 7),
            audioMode: .sourceAudio
        )

        #expect(throws: ProjectTimelineError.cutawayDoesNotFit) {
            try project.updateTimelineClip(id: primaryID, segments: [SourceSegment(sourceRange: ProjectTimeRange(
                start: .zero,
                duration: ProjectTime(seconds: 8)
            ))])
        }
    }
}
