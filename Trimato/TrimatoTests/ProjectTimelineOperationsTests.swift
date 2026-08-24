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
        #expect(project.primaryTimeline.map(\.duration) == [
            ProjectTime(seconds: 10), ProjectTime(seconds: 5), ProjectTime(seconds: 20)
        ])
        #expect(project.duration == ProjectTime(seconds: 35))
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
