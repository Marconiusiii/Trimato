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
    case audioOnlyCutaway
    case trackNotFound
    case protectedPrimaryTrack
    case incompatibleTrackKind
    case transitionNotAvailable(String)

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
        case .audioOnlyCutaway: "Insert on Top requires a clip with video. Add this audio clip to the primary timeline instead."
        case .trackNotFound: "The selected track is no longer available."
        case .protectedPrimaryTrack: "The primary track cannot be deleted."
        case .incompatibleTrackKind: "Copy or move video clips to video tracks and audio clips to audio tracks."
        case .transitionNotAvailable(let message): message
        }
    }
}

extension TrimatoProject {
    mutating func ensureTrackModel() {
        guard tracks.isEmpty else { return }
        tracks = Self.migratedTracks(
            primaryTimeline: &primaryTimeline,
            cutaways: cutaways,
            media: media
        )
    }

    @discardableResult
    mutating func createTrack(kind: TimelineTrackKind, name requestedName: String? = nil) -> UUID {
        ensureTrackModel()
        let base = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = kind == .video ? "Video" : "Audio"
        let existing = tracks.filter { $0.kind == kind }.count
        let name = (base?.isEmpty == false ? base! : "\(prefix) \(existing + 1)")
        let track = TimelineTrack(name: name, kind: kind)
        tracks.append(track)
        return track.id
    }

    mutating func renameTrack(id: UUID, to requestedName: String) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.trackNotFound
        }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectTimelineError.invalidName }
        guard !tracks.contains(where: {
            $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw ProjectTimelineError.duplicateName }
        tracks[index].name = name
    }

    mutating func moveTrack(id: UUID, by offset: Int) throws {
        guard let source = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.trackNotFound
        }
        let destination = min(max(source + offset, 0), tracks.count - 1)
        guard source != destination else { return }
        let track = tracks.remove(at: source)
        tracks.insert(track, at: destination)
    }

    mutating func removeTrack(id: UUID) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.trackNotFound
        }
        guard tracks[index].role == .additional else {
            throw ProjectTimelineError.protectedPrimaryTrack
        }
        let clipIDs = Set(tracks[index].clips.map(\.id))
        transitions.removeAll {
            $0.trackID == id ||
                $0.leadingClipID.map(clipIDs.contains) == true ||
                $0.trailingClipID.map(clipIDs.contains) == true
        }
        tracks.remove(at: index)
    }

    @discardableResult
    mutating func append(
        asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        toTrack trackID: UUID
    ) throws -> UUID {
        ensureTrackModel()
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectTimelineError.trackNotFound
        }
        var clip = try makeTimelineClip(asset: asset, segments: segments)
        clip.timelineStart = tracks[index].end
        if tracks[index].kind == .audio, asset.hasVideo { clip.name = "\(clip.displayName) Audio" }
        tracks[index].clips.append(clip)
        resolveAutomaticFormat(from: asset)
        return clip.id
    }

    @discardableResult
    mutating func insert(
        asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        at playhead: ProjectTime,
        onTrack trackID: UUID
    ) throws -> UUID {
        ensureTrackModel()
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectTimelineError.trackNotFound
        }
        guard playhead >= .zero, playhead <= duration else { throw ProjectTimelineError.invalidPlayhead }
        var incoming = try makeTimelineClip(asset: asset, segments: segments)
        incoming.timelineStart = playhead
        if tracks[trackIndex].kind == .audio, asset.hasVideo { incoming.name = "\(incoming.displayName) Audio" }
        if let containingIndex = tracks[trackIndex].clips.firstIndex(where: {
            playhead > $0.timelineStart && playhead < $0.timelineEnd
        }) {
            let original = tracks[trackIndex].clips[containingIndex]
            let halves = try split(original, at: playhead - original.timelineStart)
            var left = halves.0
            var right = halves.1
            left.timelineStart = original.timelineStart
            right.timelineStart = playhead + incoming.duration
            tracks[trackIndex].clips.replaceSubrange(containingIndex...containingIndex, with: [left, incoming, right])
            for index in tracks[trackIndex].clips.indices where
                index > containingIndex + 2 && tracks[trackIndex].clips[index].timelineStart >= original.timelineEnd {
                tracks[trackIndex].clips[index].timelineStart = tracks[trackIndex].clips[index].timelineStart + incoming.duration
            }
            resolveAutomaticFormat(from: asset)
            return incoming.id
        }
        let shift = incoming.duration
        for index in tracks[trackIndex].clips.indices where tracks[trackIndex].clips[index].timelineStart >= playhead {
            tracks[trackIndex].clips[index].timelineStart = tracks[trackIndex].clips[index].timelineStart + shift
        }
        tracks[trackIndex].clips.append(incoming)
        tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        shiftTransitions(onTrack: trackID, atOrAfter: playhead, by: shift)
        resolveAutomaticFormat(from: asset)
        return incoming.id
    }

    @discardableResult
    mutating func replaceRemainder(
        with asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        at playhead: ProjectTime,
        onTrack trackID: UUID
    ) throws -> UUID {
        ensureTrackModel()
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectTimelineError.trackNotFound
        }
        guard playhead >= .zero, playhead <= duration else { throw ProjectTimelineError.invalidPlayhead }
        var incoming = try makeTimelineClip(asset: asset, segments: segments)
        incoming.timelineStart = playhead
        if tracks[trackIndex].kind == .audio, asset.hasVideo { incoming.name = "\(incoming.displayName) Audio" }
        if let containingIndex = tracks[trackIndex].clips.firstIndex(where: {
            playhead >= $0.timelineStart && playhead < $0.timelineEnd
        }) {
            let original = tracks[trackIndex].clips[containingIndex]
            let remainder = original.timelineEnd - playhead
            var replacement: [TimelineClip] = [incoming]
            if playhead > original.timelineStart {
                var left = try split(original, at: playhead - original.timelineStart).0
                left.timelineStart = original.timelineStart
                replacement.insert(left, at: 0)
            }
            tracks[trackIndex].clips.replaceSubrange(containingIndex...containingIndex, with: replacement)
            let difference = incoming.duration - remainder
            for index in tracks[trackIndex].clips.indices where tracks[trackIndex].clips[index].timelineStart >= original.timelineEnd {
                tracks[trackIndex].clips[index].timelineStart = tracks[trackIndex].clips[index].timelineStart + difference
            }
        } else {
            _ = try insert(asset: asset, segments: segments, at: playhead, onTrack: trackID)
        }
        resolveAutomaticFormat(from: asset)
        return incoming.id
    }

    mutating func updateAudioSettings(clipID: UUID, settings: AudioClipSettings) throws {
        for trackIndex in tracks.indices where tracks[trackIndex].kind == .audio {
            if let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                tracks[trackIndex].clips[clipIndex].audioSettings = settings
                return
            }
        }
        throw ProjectTimelineError.clipNotFound
    }

    mutating func updateTrackClip(id: UUID, segments: [SourceSegment]) throws {
        if primaryTimeline.contains(where: { $0.id == id }) {
            try updateTimelineClip(id: id, segments: segments)
            return
        }
        let selected = segments.filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        guard let trackIndex = tracks.firstIndex(where: { track in track.clips.contains { $0.id == id } }),
              let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let oldEnd = tracks[trackIndex].clips[clipIndex].timelineEnd
        let difference = selected.reduce(.zero) { $0 + $1.duration } - tracks[trackIndex].clips[clipIndex].duration
        tracks[trackIndex].clips[clipIndex].segments = selected
        for index in tracks[trackIndex].clips.indices where tracks[trackIndex].clips[index].timelineStart >= oldEnd {
            tracks[trackIndex].clips[index].timelineStart = tracks[trackIndex].clips[index].timelineStart + difference
        }
    }

    mutating func renameTrackClip(id: UUID, to requestedName: String) throws {
        if primaryTimeline.contains(where: { $0.id == id }) {
            try renameTimelineClip(id: id, to: requestedName)
            return
        }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectTimelineError.invalidName }
        guard let trackIndex = tracks.firstIndex(where: { track in track.clips.contains { $0.id == id } }),
              let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        guard !tracks.flatMap(\.clips).contains(where: {
            $0.id != id && $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw ProjectTimelineError.duplicateName }
        tracks[trackIndex].clips[clipIndex].customName = name
        if let linkedID = tracks[trackIndex].clips[clipIndex].linkedClipID,
           let linkedTrack = tracks.firstIndex(where: { track in track.clips.contains { $0.id == linkedID } }),
           let linkedClip = tracks[linkedTrack].clips.firstIndex(where: { $0.id == linkedID }) {
            tracks[linkedTrack].clips[linkedClip].customName = tracks[linkedTrack].kind == .audio ? "\(name) Audio" : name
        }
    }

    mutating func removeTrackClip(id: UUID) throws {
        if primaryTimeline.contains(where: { $0.id == id }) {
            try removeClip(id: id)
            return
        }
        guard let trackIndex = tracks.firstIndex(where: { track in track.clips.contains { $0.id == id } }),
              let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let removed = tracks[trackIndex].clips.remove(at: clipIndex)
        for index in tracks[trackIndex].clips.indices where tracks[trackIndex].clips[index].timelineStart >= removed.timelineEnd {
            tracks[trackIndex].clips[index].timelineStart = tracks[trackIndex].clips[index].timelineStart - removed.duration
        }
        transitions.removeAll { $0.leadingClipID == id || $0.trailingClipID == id }
    }

    mutating func moveTrackClip(id: UUID, to destination: Int) throws {
        if primaryTimeline.contains(where: { $0.id == id }) {
            try moveClip(id: id, to: destination)
            return
        }
        guard let trackIndex = tracks.firstIndex(where: { track in track.clips.contains { $0.id == id } }) else {
            throw ProjectTimelineError.clipNotFound
        }
        disconnectLinkedClip(id)
        var ordered = tracks[trackIndex].sortedClips
        guard let source = ordered.firstIndex(where: { $0.id == id }) else { throw ProjectTimelineError.clipNotFound }
        let clip = ordered.remove(at: source)
        ordered.insert(clip, at: min(max(destination, 0), ordered.count))
        var cursor = ProjectTime.zero
        for index in ordered.indices {
            ordered[index].timelineStart = cursor
            cursor = cursor + ordered[index].duration
        }
        tracks[trackIndex].clips = ordered
        removeInvalidBetweenTransitions(on: [tracks[trackIndex].id])
    }

    @discardableResult
    mutating func duplicateTrackClip(id sourceID: UUID, after targetID: UUID) throws -> UUID {
        ensureTrackModel()
        guard let sourceTrackIndex = tracks.firstIndex(where: { $0.clips.contains { $0.id == sourceID } }),
              let source = tracks[sourceTrackIndex].clips.first(where: { $0.id == sourceID }),
              let targetTrackIndex = tracks.firstIndex(where: { $0.clips.contains { $0.id == targetID } }) else {
            throw ProjectTimelineError.clipNotFound
        }
        guard tracks[sourceTrackIndex].kind == tracks[targetTrackIndex].kind else {
            throw ProjectTimelineError.incompatibleTrackKind
        }

        var copied = source
        copied.id = UUID()
        copied.linkedClipID = nil
        copied.timelineStart = .zero
        copied.customName = uniqueCopiedClipName(for: source)

        var destinationClips = tracks[targetTrackIndex].sortedClips
        guard let targetIndex = destinationClips.firstIndex(where: { $0.id == targetID }) else {
            throw ProjectTimelineError.clipNotFound
        }
        destinationClips.insert(copied, at: targetIndex + 1)
        tracks[targetTrackIndex].clips = magnetized(destinationClips)
        removeInvalidBetweenTransitions(on: [tracks[targetTrackIndex].id])
        return copied.id
    }

    mutating func moveTrackClip(id sourceID: UUID, after targetID: UUID) throws {
        ensureTrackModel()
        guard let sourceTrackIndex = tracks.firstIndex(where: { $0.clips.contains { $0.id == sourceID } }),
              let targetTrackIndex = tracks.firstIndex(where: { $0.clips.contains { $0.id == targetID } }) else {
            throw ProjectTimelineError.clipNotFound
        }
        guard tracks[sourceTrackIndex].kind == tracks[targetTrackIndex].kind else {
            throw ProjectTimelineError.incompatibleTrackKind
        }
        guard sourceID != targetID else { return }

        disconnectLinkedClip(sourceID)
        var sourceClips = tracks[sourceTrackIndex].sortedClips
        guard let sourceIndex = sourceClips.firstIndex(where: { $0.id == sourceID }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let moving = sourceClips.remove(at: sourceIndex)

        if sourceTrackIndex == targetTrackIndex {
            guard let targetIndex = sourceClips.firstIndex(where: { $0.id == targetID }) else {
                throw ProjectTimelineError.clipNotFound
            }
            sourceClips.insert(moving, at: targetIndex + 1)
            tracks[sourceTrackIndex].clips = magnetized(sourceClips)
        } else {
            var destinationClips = tracks[targetTrackIndex].sortedClips
            guard let targetIndex = destinationClips.firstIndex(where: { $0.id == targetID }) else {
                throw ProjectTimelineError.clipNotFound
            }
            destinationClips.insert(moving, at: targetIndex + 1)
            tracks[sourceTrackIndex].clips = magnetized(sourceClips)
            tracks[targetTrackIndex].clips = magnetized(destinationClips)
        }

        let affectedTrackIDs = Set([tracks[sourceTrackIndex].id, tracks[targetTrackIndex].id])
        transitions.removeAll { transition in
            transition.leadingClipID == sourceID || transition.trailingClipID == sourceID
        }
        removeInvalidBetweenTransitions(on: affectedTrackIDs)
    }

    private func magnetized(_ clips: [TimelineClip]) -> [TimelineClip] {
        var result = clips
        var cursor = ProjectTime.zero
        for index in result.indices {
            result[index].timelineStart = cursor
            cursor = cursor + result[index].duration
        }
        return result
    }

    private mutating func disconnectLinkedClip(_ id: UUID) {
        guard let linkedID = timelineClip(id: id)?.linkedClipID else { return }
        for trackIndex in tracks.indices {
            for clipIndex in tracks[trackIndex].clips.indices {
                if tracks[trackIndex].clips[clipIndex].id == id ||
                    tracks[trackIndex].clips[clipIndex].id == linkedID {
                    tracks[trackIndex].clips[clipIndex].linkedClipID = nil
                }
            }
        }
    }

    private mutating func removeInvalidBetweenTransitions(on trackIDs: Set<UUID>) {
        let affectedTracks = Dictionary(uniqueKeysWithValues: tracks
            .filter { trackIDs.contains($0.id) }
            .map { ($0.id, $0) })
        transitions.removeAll { transition in
            guard trackIDs.contains(transition.trackID), transition.edge == .between,
                  let track = affectedTracks[transition.trackID] else { return false }
            let ordered = track.sortedClips
            guard let leading = transition.leadingClipID,
                  let trailing = transition.trailingClipID,
                  let leadingIndex = ordered.firstIndex(where: { $0.id == leading }),
                  let trailingIndex = ordered.firstIndex(where: { $0.id == trailing }) else { return true }
            return trailingIndex != leadingIndex + 1
        }
    }

    private func uniqueCopiedClipName(for clip: TimelineClip) -> String {
        let base = "\(clip.displayName) Copy"
        let used = Set(tracks.flatMap(\.clips).map { $0.displayName.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var ordinal = 2
        while used.contains("\(base) \(ordinal)".lowercased()) { ordinal += 1 }
        return "\(base) \(ordinal)"
    }

    mutating func addTransition(_ transition: TimelineTransition) throws {
        ensureTrackModel()
        guard let track = track(id: transition.trackID) else { throw ProjectTimelineError.trackNotFound }
        guard transition.duration.isPositive else {
            throw ProjectTimelineError.transitionNotAvailable("Enter a transition duration greater than zero.")
        }
        guard !transitions.contains(where: {
            $0.trackID == transition.trackID &&
                $0.leadingClipID == transition.leadingClipID &&
                $0.trailingClipID == transition.trailingClipID
        }) else {
            throw ProjectTimelineError.transitionNotAvailable("A transition already exists at this edit.")
        }
        try validateTransition(transition, on: track)
        transitions.append(transition)
    }

    mutating func updateTransition(_ transition: TimelineTransition) throws {
        guard let index = transitions.firstIndex(where: { $0.id == transition.id }),
              let track = track(id: transition.trackID) else {
            throw ProjectTimelineError.transitionNotAvailable("The selected transition is no longer available.")
        }
        try validateTransition(transition, on: track)
        transitions[index] = transition
    }

    mutating func removeTransition(id: UUID) {
        transitions.removeAll { $0.id == id }
    }

    private func validateTransition(_ transition: TimelineTransition, on track: TimelineTrack) throws {
        let leading = transition.leadingClipID.flatMap { id in track.clips.first { $0.id == id } }
        let trailing = transition.trailingClipID.flatMap { id in track.clips.first { $0.id == id } }
        if transition.edge == .between {
            guard let leading, let trailing, leading.timelineEnd == trailing.timelineStart else {
                throw ProjectTimelineError.transitionNotAvailable("Cross transitions require two clips that meet at the same edit.")
            }
            let half = ProjectTime(seconds: transition.duration.seconds / 2)
            guard sourceHandleAfter(leading) >= half, sourceHandleBefore(trailing) >= half else {
                throw ProjectTimelineError.transitionNotAvailable("The adjoining clips do not have enough unused source media for that duration.")
            }
        } else {
            guard let clip = leading ?? trailing, transition.duration < clip.duration else {
                throw ProjectTimelineError.transitionNotAvailable("The transition must be shorter than the clip.")
            }
        }
    }

    private func sourceHandleBefore(_ clip: TimelineClip) -> ProjectTime {
        clip.segments.first?.sourceRange.start ?? .zero
    }

    private func sourceHandleAfter(_ clip: TimelineClip) -> ProjectTime {
        guard let asset = asset(id: clip.assetID), let last = clip.segments.last else { return .zero }
        return max(asset.duration - last.sourceRange.end, .zero)
    }

    private mutating func shiftTransitions(onTrack trackID: UUID, atOrAfter time: ProjectTime, by amount: ProjectTime) {}
    mutating func applyProjectFormat(_ requestedFormat: ProjectFormat) {
        guard requestedFormat.mode == .automatic else {
            format = requestedFormat
            return
        }
        format = ProjectFormat(mode: .automatic)
        guard let asset = primaryTimeline.compactMap({ clip in
            self.asset(id: clip.assetID)
        }).first(where: \.hasVideo),
              let width = asset.naturalWidth,
              let height = asset.naturalHeight else { return }
        format.width = width
        format.height = height
        format.frameRate = ProjectFormat.stableFrameRate(asset.frameRate ?? 30)
    }

    mutating func append(asset: MediaAssetRecord, segments: [SourceSegment]? = nil) throws -> UUID {
        let clip = labelForInsertion(try makeTimelineClip(asset: asset, segments: segments))
        primaryTimeline.append(clip)
        resolveAutomaticFormat(from: asset)
        synchronizeLegacyTimelineToTracks()
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
        synchronizeLegacyTimelineToTracks()
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
            synchronizeLegacyTimelineToTracks()
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
                synchronizeLegacyTimelineToTracks()
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
        synchronizeLegacyTimelineToTracks()
        return incoming.id
    }

    mutating func addCutaway(
        asset: MediaAssetRecord,
        segments: [SourceSegment]? = nil,
        at playhead: ProjectTime,
        audioMode: CutawayAudioMode
    ) throws -> UUID {
        guard asset.hasVideo else { throw ProjectTimelineError.audioOnlyCutaway }
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
        resolveAutomaticFormat(from: asset)
        synchronizeLegacyTimelineToTracks()
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
        synchronizeLegacyTimelineToTracks()
        return halves.1.id
    }

    mutating func updateTimelineClip(id: UUID, segments: [SourceSegment]) throws {
        let selected = segments.filter { $0.duration.isPositive }
        guard !selected.isEmpty else { throw ProjectTimelineError.emptyIncomingClip }
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        primaryTimeline[index].segments = selected
        let updatedPrimaryDuration = primaryTimeline.reduce(.zero) { $0 + $1.duration }
        guard cutaways.allSatisfy({ $0.end <= updatedPrimaryDuration }) else {
            throw ProjectTimelineError.cutawayDoesNotFit
        }
        synchronizeLegacyTimelineToTracks()
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
        synchronizeLegacyTimelineToTracks()
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
        synchronizeLegacyTimelineToTracks()
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
        synchronizeLegacyTimelineToTracks()
    }

    mutating func removeClip(id: UUID) throws {
        guard let index = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        primaryTimeline.remove(at: index)
        synchronizeLegacyTimelineToTracks()
    }

    mutating func moveClip(id: UUID, to destination: Int) throws {
        guard let source = primaryTimeline.firstIndex(where: { $0.id == id }) else {
            throw ProjectTimelineError.clipNotFound
        }
        let clip = primaryTimeline.remove(at: source)
        let bounded = min(max(destination, 0), primaryTimeline.count)
        primaryTimeline.insert(clip, at: bounded)
        synchronizeLegacyTimelineToTracks()
    }

    mutating func synchronizeLegacyTimelineToTracks() {
        let existingVideo = tracks.first { $0.role == .primaryVideo }
        let existingAudio = tracks.first { $0.role == .primaryAudio }
        var videoClips: [TimelineClip] = []
        var audioClips: [TimelineClip] = []
        var cursor = ProjectTime.zero

        for legacy in primaryTimeline {
            guard let source = asset(id: legacy.assetID) else { continue }
            if source.hasVideo {
                var video = existingVideo?.clips.first(where: { $0.id == legacy.id }) ?? legacy
                video.segments = legacy.segments
                video.timelineStart = cursor
                video.customName = legacy.customName
                video.labelOrdinal = legacy.labelOrdinal
                if source.hasAudio {
                    var audio: TimelineClip
                    if let linkedID = video.linkedClipID,
                       let current = existingAudio?.clips.first(where: { $0.id == linkedID }) {
                        audio = current
                    } else {
                        audio = TimelineClip(
                            assetID: legacy.assetID,
                            name: "\(legacy.displayName) Audio",
                            segments: legacy.segments,
                            timelineStart: cursor,
                            linkedClipID: video.id
                        )
                    }
                    audio.segments = legacy.segments
                    audio.timelineStart = cursor
                    audio.name = "\(legacy.displayName) Audio"
                    audio.linkedClipID = video.id
                    video.linkedClipID = audio.id
                    audioClips.append(audio)
                }
                videoClips.append(video)
            } else if source.hasAudio {
                var audio = existingAudio?.clips.first(where: { $0.id == legacy.id }) ?? legacy
                audio.timelineStart = cursor
                audio.segments = legacy.segments
                audioClips.append(audio)
            }
            cursor = cursor + legacy.duration
        }

        let additional = tracks.filter { $0.role == .additional }
        var rebuilt: [TimelineTrack] = []
        if !videoClips.isEmpty {
            rebuilt.append(TimelineTrack(
                id: existingVideo?.id ?? UUID(),
                name: existingVideo?.name ?? "Primary Video",
                kind: .video,
                role: .primaryVideo,
                clips: videoClips
            ))
        }
        if !audioClips.isEmpty {
            rebuilt.append(TimelineTrack(
                id: existingAudio?.id ?? UUID(),
                name: existingAudio?.name ?? "Primary Audio",
                kind: .audio,
                role: .primaryAudio,
                clips: audioClips
            ))
        }
        tracks = rebuilt + additional
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
        format.frameRate = ProjectFormat.stableFrameRate(asset.frameRate ?? 30)
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
