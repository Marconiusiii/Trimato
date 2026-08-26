import Foundation

enum ProjectTimelineError: LocalizedError, Equatable {
    case emptyIncomingClip
    case invalidPlayhead
    case clipNotFound
    case cannotSplitAtBoundary
    case cutawayDoesNotFit
    case cutawayOverlap
    case invalidName
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .emptyIncomingClip: "The edited clip does not contain any media."
        case .invalidPlayhead: "The timeline playhead is outside the project."
        case .clipNotFound: "The selected timeline clip is no longer available."
        case .cannotSplitAtBoundary: "Move the playhead inside a clip before splitting it."
        case .cutawayDoesNotFit: "The cutaway extends beyond the end of the project."
        case .cutawayOverlap: "Another cutaway already occupies that position."
        case .invalidName: "Enter a name for the timeline clip."
        case .duplicateName: "Choose a name that is not already used in the timeline."
        }
    }
}

extension TrimatoProject {
    mutating func append(asset: MediaAssetRecord, segments: [SourceSegment]? = nil) throws -> UUID {
        let clip = labelForInsertion(try makeTimelineClip(asset: asset, segments: segments))
        primaryTimeline.append(clip)
        resolveAutomaticFormat(from: asset)
        return clip.id
    }

    mutating func insert(asset: MediaAssetRecord, segments: [SourceSegment]? = nil, at playhead: ProjectTime) throws -> UUID {
        var incoming = try makeTimelineClip(asset: asset, segments: segments)
        let destination = try timelineDestination(at: playhead, allowsEnd: true)
        if let destination, destination.offset > .zero, destination.offset < destination.clip.duration {
            let halves = try labeledSplit(at: destination.index, offset: destination.offset)
            primaryTimeline.replaceSubrange(destination.index...destination.index, with: [halves.0, halves.1])
            incoming = labelForInsertion(incoming)
            primaryTimeline.insert(incoming, at: destination.index + 1)
        } else if let destination {
            incoming = labelForInsertion(incoming)
            let insertionIndex = destination.offset == destination.clip.duration
                ? destination.index + 1
                : destination.index
            primaryTimeline.insert(incoming, at: insertionIndex)
        } else {
            incoming = labelForInsertion(incoming)
            primaryTimeline.append(incoming)
        }
        resolveAutomaticFormat(from: asset)
        return incoming.id
    }

    mutating func replaceClipRemainder(
        with asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        at playhead: ProjectTime
    ) throws -> UUID {
        var incoming = try makeTimelineClip(asset: asset, segments: segments)
        guard let destination = try timelineDestination(at: playhead, allowsEnd: true) else {
            incoming = labelForInsertion(incoming)
            primaryTimeline.append(incoming)
            resolveAutomaticFormat(from: asset)
            return incoming.id
        }

        if destination.offset <= .zero {
            if incoming.assetID == destination.clip.assetID {
                ensureInstanceLabels(named: destination.clip.name)
                incoming.labelOrdinal = primaryTimeline[destination.index].labelOrdinal
            } else {
                primaryTimeline.remove(at: destination.index)
                incoming = labelForInsertion(incoming)
                primaryTimeline.insert(incoming, at: destination.index)
                resolveAutomaticFormat(from: asset)
                return incoming.id
            }
            primaryTimeline[destination.index] = incoming
        } else if destination.offset >= destination.clip.duration {
            incoming = labelForInsertion(incoming)
            primaryTimeline.insert(incoming, at: destination.index + 1)
        } else {
            ensureInstanceLabels(named: destination.clip.name)
            let labeledDestination = primaryTimeline[destination.index]
            var left = try split(labeledDestination, at: destination.offset).0
            left.labelOrdinal = labeledDestination.labelOrdinal
            primaryTimeline[destination.index] = left
            incoming = labelForInsertion(incoming)
            primaryTimeline.insert(incoming, at: destination.index + 1)
        }
        resolveAutomaticFormat(from: asset)
        return incoming.id
    }

    mutating func addCutaway(
        asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        at playhead: ProjectTime,
        audioMode: CutawayAudioMode
    ) throws -> UUID {
        let selectedSegments = (segments ?? asset.sourceEdit).filter { $0.duration.isPositive }
        guard !selectedSegments.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        var cutaway = TimelineCutaway(
            assetID: asset.id,
            name: asset.name,
            start: playhead,
            segments: selectedSegments,
            audioMode: audioMode
        )
        guard playhead >= .zero, cutaway.end <= duration else {
            throw ProjectTimelineError.cutawayDoesNotFit
        }
        guard !cutaways.contains(where: { existing in
            cutaway.start < existing.end && existing.start < cutaway.end
        }) else {
            throw ProjectTimelineError.cutawayOverlap
        }
        cutaway = labelForInsertion(cutaway)
        cutaways.append(cutaway)
        cutaways.sort { $0.start < $1.start }
        return cutaway.id
    }

    mutating func splitClip(id: UUID, atTimelineTime playhead: ProjectTime) throws -> UUID {
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }),
              let start = startTime(of: id) else {
            throw ProjectTimelineError.clipNotFound
        }
        let offset = playhead - start
        let halves = try labeledSplit(at: index, offset: offset)
        primaryTimeline.replaceSubrange(index...index, with: [halves.0, halves.1])
        return halves.1.id
    }

    mutating func updateTimelineClip(id: UUID, segments: [SourceSegment]) throws {
        let selected = segments.filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        primaryTimeline[index].segments = selected
        guard cutaways.allSatisfy({ $0.end <= duration }) else {
            throw ProjectTimelineError.cutawayDoesNotFit
        }
    }

    mutating func updateCutaway(id: UUID, segments: [SourceSegment]) throws {
        let selected = segments.filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        guard let index = cutaways.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let updatedEnd = cutaways[index].start + selected.reduce(.zero) { $0 + $1.duration }
        guard updatedEnd <= duration else { throw ProjectTimelineError.cutawayDoesNotFit }
        guard !cutaways.contains(where: { other in
            other.id != id && cutaways[index].start < other.end && other.start < updatedEnd
        }) else { throw ProjectTimelineError.cutawayOverlap }
        cutaways[index].segments = selected
    }

    mutating func renameTimelineClip(id: UUID, to customName: String) throws {
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let cleanName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw ProjectTimelineError.invalidName }
        guard isTimelineNameAvailable(cleanName, excluding: id) else {
            throw ProjectTimelineError.duplicateName
        }
        primaryTimeline[index].customName = cleanName
    }

    mutating func renameCutaway(id: UUID, to customName: String) throws {
        guard let index = cutaways.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let cleanName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw ProjectTimelineError.invalidName }
        guard isTimelineNameAvailable(cleanName, excluding: id) else {
            throw ProjectTimelineError.duplicateName
        }
        cutaways[index].customName = cleanName
    }

    mutating func removeClip(id: UUID) throws {
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        primaryTimeline.remove(at: index)
    }

    mutating func moveClip(id: UUID, to destination: Int) throws {
        guard let source = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let clip = primaryTimeline.remove(at: source)
        let bounded = min(max(destination, 0), primaryTimeline.count)
        primaryTimeline.insert(clip, at: bounded)
    }

    private mutating func labelForInsertion(_ clip: TimelineClip) -> TimelineClip {
        guard automaticEntries(named: clip.name) > 0 || !isTimelineNameAvailable(clip.name) else {
            return clip
        }
        ensureInstanceLabels(named: clip.name)
        var labeled = clip
        labeled.labelOrdinal = nextAvailableLabelOrdinal(named: clip.name)
        return labeled
    }

    private mutating func labelForInsertion(_ cutaway: TimelineCutaway) -> TimelineCutaway {
        guard automaticEntries(named: cutaway.name) > 0 || !isTimelineNameAvailable(cutaway.name) else {
            return cutaway
        }
        ensureInstanceLabels(named: cutaway.name)
        var labeled = cutaway
        labeled.labelOrdinal = nextAvailableLabelOrdinal(named: cutaway.name)
        return labeled
    }

    private mutating func ensureInstanceLabels(named baseName: String) {
        var used = Set(allTimelineDisplayNames().map { $0.lowercased() })
        for index in primaryTimeline.indices where primaryTimeline[index].name == baseName &&
            primaryTimeline[index].customName == nil && primaryTimeline[index].labelOrdinal == nil {
            used.remove(primaryTimeline[index].displayName.lowercased())
            let ordinal = nextAvailableLabelOrdinal(named: baseName, usedNames: used)
            primaryTimeline[index].labelOrdinal = ordinal
            used.insert(primaryTimeline[index].displayName.lowercased())
        }
        for index in cutaways.indices where cutaways[index].name == baseName &&
            cutaways[index].customName == nil && cutaways[index].labelOrdinal == nil {
            used.remove(cutaways[index].displayName.lowercased())
            let ordinal = nextAvailableLabelOrdinal(named: baseName, usedNames: used)
            cutaways[index].labelOrdinal = ordinal
            used.insert(cutaways[index].displayName.lowercased())
        }
    }

    private func nextAvailableLabelOrdinal(named baseName: String) -> Int {
        nextAvailableLabelOrdinal(
            named: baseName,
            usedNames: Set(allTimelineDisplayNames().map { $0.lowercased() })
        )
    }

    private func nextAvailableLabelOrdinal(named baseName: String, usedNames: Set<String>) -> Int {
        var ordinal = 0
        while usedNames.contains("\(baseName) \(TimelineClip.letterLabel(for: ordinal))".lowercased()) {
            ordinal += 1
        }
        return ordinal
    }

    private func automaticEntries(named baseName: String) -> Int {
        primaryTimeline.filter { $0.name == baseName && $0.customName == nil }.count +
            cutaways.filter { $0.name == baseName && $0.customName == nil }.count
    }

    private func allTimelineDisplayNames(excluding id: UUID? = nil) -> [String] {
        primaryTimeline.filter { $0.id != id }.map(\.displayName) +
            cutaways.filter { $0.id != id }.map(\.displayName)
    }

    private func isTimelineNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        !allTimelineDisplayNames(excluding: id).contains {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private mutating func labeledSplit(
        at index: Int,
        offset: ProjectTime
    ) throws -> (TimelineClip, TimelineClip) {
        let original = primaryTimeline[index]
        if let customName = original.customName {
            var halves = try split(original, at: offset)
            let used = Set(allTimelineDisplayNames(excluding: original.id).map { $0.lowercased() })
            halves.0.name = customName
            halves.0.customName = nil
            halves.0.labelOrdinal = nextAvailableLabelOrdinal(named: customName, usedNames: used)
            var usedWithLeft = used
            usedWithLeft.insert(halves.0.displayName.lowercased())
            halves.1.name = customName
            halves.1.customName = nil
            halves.1.labelOrdinal = nextAvailableLabelOrdinal(named: customName, usedNames: usedWithLeft)
            return halves
        }
        ensureInstanceLabels(named: original.name)
        let clip = primaryTimeline[index]
        var halves = try split(clip, at: offset)
        halves.0.labelOrdinal = clip.labelOrdinal
        halves.1.labelOrdinal = nextAvailableLabelOrdinal(named: clip.name)
        return halves
    }

    private mutating func resolveAutomaticFormat(from asset: MediaAssetRecord) {
        guard format.mode == .automatic, !format.isResolved,
              let width = asset.naturalWidth, let height = asset.naturalHeight else { return }
        format.width = width
        format.height = height
        format.frameRate = asset.frameRate ?? 30
    }

    private func makeTimelineClip(asset: MediaAssetRecord, segments: [SourceSegment]?) throws -> TimelineClip {
        let selected = (segments ?? asset.sourceEdit).filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        return TimelineClip(assetID: asset.id, name: asset.name, segments: selected)
    }

    private func timelineDestination(
        at playhead: ProjectTime,
        allowsEnd: Bool
    ) throws -> (index: Int, clip: TimelineClip, offset: ProjectTime)? {
        guard playhead >= .zero, playhead < duration || (allowsEnd && playhead == duration) else {
            throw ProjectTimelineError.invalidPlayhead
        }
        var cursor = ProjectTime.zero
        for (index, clip) in primaryTimeline.enumerated() {
            let end = cursor + clip.duration
            if playhead < end || (playhead == end && index == primaryTimeline.count - 1) {
                return (index, clip, playhead - cursor)
            }
            cursor = end
        }
        return nil
    }

    private func split(_ clip: TimelineClip, at offset: ProjectTime) throws -> (TimelineClip, TimelineClip) {
        guard offset > .zero, offset < clip.duration else {
            throw ProjectTimelineError.cannotSplitAtBoundary
        }
        var leftSegments: [SourceSegment] = []
        var rightSegments: [SourceSegment] = []
        var remaining = offset

        for segment in clip.segments {
            if remaining <= .zero {
                rightSegments.append(segment)
            } else if remaining >= segment.duration {
                leftSegments.append(segment)
                remaining = remaining - segment.duration
            } else {
                leftSegments.append(SourceSegment(sourceRange: ProjectTimeRange(
                    start: segment.sourceRange.start,
                    duration: remaining
                )))
                rightSegments.append(SourceSegment(sourceRange: ProjectTimeRange(
                    start: segment.sourceRange.start + remaining,
                    duration: segment.duration - remaining
                )))
                remaining = .zero
            }
        }
        guard !leftSegments.isEmpty, !rightSegments.isEmpty else {
            throw ProjectTimelineError.cannotSplitAtBoundary
        }
        return (
            TimelineClip(assetID: clip.assetID, name: clip.name, segments: leftSegments, customName: clip.customName),
            TimelineClip(assetID: clip.assetID, name: clip.name, segments: rightSegments, customName: clip.customName)
        )
    }
}
