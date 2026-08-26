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

    @Test func distinctAssetsWithTheSameFilenameReceiveUniqueTimelineNames() throws {
        let first = fixtureAsset(name: "Interview.mov", duration: 2)
        let second = fixtureAsset(name: "Interview.mov", duration: 3)
        var project = TrimatoProject()

        _ = try project.append(asset: first)
        _ = try project.append(asset: second)

        #expect(first.id != second.id)
        #expect(project.primaryTimeline.map(\.displayName) == ["Interview.mov A", "Interview.mov B"])
    }

    @Test func cutawaysShareTheTimelineNameSequence() throws {
        let primary = fixtureAsset(name: "Interview", duration: 10)
        let first = fixtureAsset(name: "Angle", duration: 2)
        let second = fixtureAsset(name: "Angle", duration: 2)
        var project = TrimatoProject()
        _ = try project.append(asset: primary)

        _ = try project.addCutaway(asset: first, at: ProjectTime(seconds: 1), audioMode: .primaryAudio)
        _ = try project.addCutaway(asset: second, at: ProjectTime(seconds: 5), audioMode: .primaryAudio)

        #expect(project.cutaways.map(\.displayName) == ["Angle A", "Angle B"])
    }

    @Test func timelineRenamesAreTrimmedAndMustRemainUnique() throws {
        let first = fixtureAsset(name: "First", duration: 2)
        let second = fixtureAsset(name: "Second", duration: 3)
        var project = TrimatoProject()
        let firstID = try project.append(asset: first)
        let secondID = try project.append(asset: second)

        try project.renameTimelineClip(id: firstID, to: "  Opening  ")

        #expect(project.primaryTimeline.first?.displayName == "Opening")
        #expect(throws: ProjectTimelineError.duplicateName) {
            try project.renameTimelineClip(id: secondID, to: "opening")
        }
        #expect(throws: ProjectTimelineError.invalidName) {
            try project.renameTimelineClip(id: secondID, to: "   ")
        }
    }

    @Test func splittingARenamedClipCreatesUniqueLetteredNames() throws {
        let source = fixtureAsset(name: "Interview", duration: 10)
        var project = TrimatoProject()
        let clipID = try project.append(asset: source)
        try project.renameTimelineClip(id: clipID, to: "Opening")

        _ = try project.splitClip(id: clipID, atTimelineTime: ProjectTime(seconds: 4))

        #expect(project.primaryTimeline.map(\.displayName) == ["Opening A", "Opening B"])
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

    @Test func automaticFormatResolvesFromTheFirstExistingTimelineClip() throws {
        var first = fixtureAsset(name: "Portrait", duration: 5)
        first.naturalWidth = 1_080
        first.naturalHeight = 1_920
        first.frameRate = 29.97
        let later = fixtureAsset(name: "Landscape", duration: 5)
        var project = TrimatoProject()
        project.media = [first, later]
        _ = try project.append(asset: first)
        _ = try project.append(asset: later)
        project.format = ProjectFormat(mode: .custom, width: 1_920, height: 1_080, frameRate: 60)

        project.applyProjectFormat(ProjectFormat(mode: .automatic))

        #expect(project.format.mode == .automatic)
        #expect(project.format.width == 1_080)
        #expect(project.format.height == 1_920)
        #expect(project.format.frameRate == 29.97)
    }

    @Test func automaticFormatRemainsUnresolvedWithoutATimelineClip() {
        var project = TrimatoProject()
        project.media = [fixtureAsset(name: "Imported Only", duration: 5)]

        project.applyProjectFormat(ProjectFormat(mode: .automatic))

        #expect(!project.format.isResolved)
    }

    @Test func customFormatValidationAcceptsFractionalRatesAndRejectsUnsafeValues() {
        #expect(ProjectFormatValidation.message(width: 1_920, height: 1_080, frameRate: 29.97) == nil)
        #expect(ProjectFormatValidation.message(width: 1_921, height: 1_080, frameRate: 30) != nil)
        #expect(ProjectFormatValidation.message(width: 1_920, height: 1_081, frameRate: 30) != nil)
        #expect(ProjectFormatValidation.message(width: 8_194, height: 1_080, frameRate: 30) != nil)
        #expect(ProjectFormatValidation.message(width: 1_920, height: 1_080, frameRate: 240.1) != nil)
    }

    @Test func projectResolutionChoicesRecognizePresetsAndPreserveUnconventionalFrames() {
        #expect(ProjectResolutionChoice.selection(width: 1_920, height: 1_080) == .fullHD)
        #expect(ProjectResolutionChoice.selection(width: 1_080, height: 1_920) == .verticalFullHD)
        #expect(ProjectResolutionChoice.selection(width: 1_080, height: 1_350) == .portraitFourByFive)
        #expect(ProjectResolutionChoice.selection(width: 1_234, height: 678) == .custom)
    }

    @Test func projectFrameRateChoicesRecognizeIntegerAndFractionalStandards() {
        #expect(ProjectFrameRateChoice.selection(frameRate: 30) == .fps30)
        #expect(ProjectFrameRateChoice.selection(frameRate: 23.976) == .fps23_976)
        #expect(ProjectFrameRateChoice.selection(frameRate: 30_000.0 / 1_001.0) == .fps29_97)
        #expect(ProjectFrameRateChoice.selection(frameRate: 48) == .custom)
    }

    @Test func aspectRatioLockAdjustsEitherDimensionAndKeepsEncoderSafeValues() {
        let widescreenRatio = 1_920.0 / 1_080.0

        #expect(ProjectAspectRatioLock.height(forWidth: 1_280, ratio: widescreenRatio) == 720)
        #expect(ProjectAspectRatioLock.width(forHeight: 720, ratio: widescreenRatio) == 1_280)
        #expect(ProjectAspectRatioLock.height(forWidth: 1_001, ratio: widescreenRatio)?.isMultiple(of: 2) == true)
        #expect(ProjectAspectRatioLock.height(forWidth: 1_920, ratio: 0) == nil)
    }

    @Test func unlockedCustomDimensionsChangeIndependently() {
        let widthEdit = ProjectAspectRatioLock.dimensions(
            afterEditingWidth: 1_234,
            currentHeight: 1_080,
            ratio: 1_920.0 / 1_080.0,
            isLocked: false
        )
        let heightEdit = ProjectAspectRatioLock.dimensions(
            afterEditingHeight: 678,
            currentWidth: widthEdit.width,
            ratio: 1_920.0 / 1_080.0,
            isLocked: false
        )

        #expect(widthEdit.width == 1_234)
        #expect(widthEdit.height == 1_080)
        #expect(heightEdit.width == 1_234)
        #expect(heightEdit.height == 678)
    }

    @Test func projectMediaConformanceExplainsPillarboxingAndFrameRateConversion() {
        var portrait = fixtureAsset(name: "Phone", duration: 5)
        portrait.naturalWidth = 1_080
        portrait.naturalHeight = 1_920
        portrait.frameRate = 60
        let description = ProjectMediaConformance.describe(
            asset: portrait,
            projectFormat: ProjectFormat(mode: .custom, width: 1_920, height: 1_080, frameRate: 30)
        )

        #expect(description.fit?.contains("pillarboxed on the left and right") == true)
        #expect(description.fit?.contains("without stretching or cropping") == true)
        #expect(description.frameRate?.contains("60 fps source rendered at the 30 fps project rate") == true)
        #expect(description.frameRate?.contains("Clip speed and audio duration remain unchanged") == true)
    }

    @Test func projectMediaConformanceExplainsLetterboxing() {
        var wide = fixtureAsset(name: "Wide", duration: 5)
        wide.naturalWidth = 2_560
        wide.naturalHeight = 1_080
        let description = ProjectMediaConformance.describe(
            asset: wide,
            projectFormat: ProjectFormat(mode: .custom, width: 1_920, height: 1_080, frameRate: 30)
        )

        #expect(description.fit?.contains("letterboxed above and below") == true)
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
