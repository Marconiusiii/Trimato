import AppKit

nonisolated enum MixerWindowCommand: Equatable {
    case close, save, previousTrack, nextTrack

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, character: String? = nil) -> Self? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            if character?.lowercased() == "w" || (character == nil && keyCode == 13) { return .close }
            if character?.lowercased() == "s" || (character == nil && keyCode == 1) { return .save }
        }
        if modifiers == [.command, .option] {
            if keyCode == 126 { return .previousTrack }
            if keyCode == 125 { return .nextTrack }
        }
        return nil
    }
}

nonisolated enum MixerTrackNavigation {
    static func adjacent<ID: Equatable>(_ direction: Int, selected: ID?, tracks: [ID]) -> ID? {
        guard !tracks.isEmpty else { return nil }
        let index = tracks.firstIndex { $0 == selected } ?? 0
        return tracks[((index + direction) % tracks.count + tracks.count) % tracks.count]
    }
}
