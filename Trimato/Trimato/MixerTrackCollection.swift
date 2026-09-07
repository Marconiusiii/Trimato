import AppKit
import SwiftUI

/// Native track items keep their identity when selection or mix values change.
struct MixerTrackCollection: NSViewRepresentable {
    let tracks: [MixerTrack]
    let selectedID: UUID?
    let soloIDs: Set<UUID>
    let select: (UUID) -> Void
    let play: () -> Void
    let edit: () -> Void
    let shuttle: (String) -> Void
    let navigate: (UInt16) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 210, height: 72)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        let collection = MixerCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.setAccessibilityLabel("Audio Tracks")
        collection.register(MixerCollectionItem.self, forItemWithIdentifier: .init("MixerTrack"))
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.keyAction = { [weak coordinator = context.coordinator] in coordinator?.key($0) ?? false }
        context.coordinator.collection = collection
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var collection: MixerCollectionView?
        var source: MixerTrackCollection?
        var updating = false
        func update(_ next: MixerTrackCollection) {
            let structureChanged = source?.tracks.map(\.id) != next.tracks.map(\.id)
            source = next
            updating = true
            defer { updating = false }
            if structureChanged { collection?.reloadData() }
            else {
                for item in collection?.visibleItems() ?? [] {
                    guard let item = item as? MixerCollectionItem,
                          let index = collection?.indexPath(for: item)?.item else { continue }
                    configure(item, at: index)
                }
            }
            let paths: Set<IndexPath> = next.tracks.firstIndex(where: { $0.id == next.selectedID })
                .map { [IndexPath(item: $0, section: 0)] } ?? []
            if collection?.selectionIndexPaths != paths { collection?.selectionIndexPaths = paths }
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { source?.tracks.count ?? 0 }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("MixerTrack"), for: indexPath) as! MixerCollectionItem
            configure(item, at: indexPath.item)
            return item
        }
        fileprivate func configure(_ item: MixerCollectionItem, at index: Int) {
            guard let source, source.tracks.indices.contains(index) else { return }
            let track = source.tracks[index]
            let selected = track.id == source.selectedID
            var values = ["Volume \(MixerValue.decibels(track.mix.volumeDB))"]
            if selected { values.insert("Selected", at: 0) }
            if track.muted { values.append("Muted") }
            if source.soloIDs.contains(track.id) { values.append("Solo") }
            let value = values.joined(separator: ", ")
            let button = item.button
            let title = track.name + "\n" + values.joined(separator: ", ")
            if button.title != title { button.title = title }
            if button.accessibilityLabel() != track.name { button.setAccessibilityLabel(track.name) }
            if button.accessibilityValue() as? String != value { button.setAccessibilityValue(value) }
            button.setAccessibilityIdentifier("trimato.mixer.track.\(track.id)")
            button.focusTrack = { [weak self] in
                guard let self, !updating, self.source?.selectedID != track.id else { return }
                self.source?.select(track.id)
            }
            button.keyAction = { [weak self] in self?.key($0) ?? false }
            button.selectedTrack = selected
            button.refreshSurface()
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !updating, let source, let index = indexPaths.first?.item, source.tracks.indices.contains(index) else { return }
            source.select(source.tracks[index].id)
        }
        func key(_ event: NSEvent) -> Bool {
            guard let source else { return false }
            let modifiers = event.modifierFlags.intersection([.command,.option,.control,.shift])
            if modifiers == .command, [123, 124, 125, 126].contains(event.keyCode) {
                if !event.isARepeat { source.navigate(event.keyCode) }
                return true
            }
            guard modifiers.isEmpty else { return false }
            if let character = event.charactersIgnoringModifiers?.lowercased(), ["j", "k", "l"].contains(character) {
                if !event.isARepeat { source.shuttle(character) }
                return true
            }
            switch event.keyCode {
            case 49: if !event.isARepeat { source.play() }; return true
            case 36, 76: source.edit(); return true
            case 123, 124:
                guard !source.tracks.isEmpty else { return true }
                let index = source.tracks.firstIndex { $0.id == source.selectedID } ?? 0
                let next = min(max(index + (event.keyCode == 123 ? -1 : 1), 0), source.tracks.count-1)
                source.select(source.tracks[next].id)
                let path = IndexPath(item: next, section: 0)
                collection?.selectionIndexPaths = [path]
                collection?.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
                if let item = collection?.item(at: path) as? MixerCollectionItem {
                    collection?.window?.makeFirstResponder(item.button)
                }
                return true
            default: return false
            }
        }
    }
}

final class MixerCollectionView: NSCollectionView {
    var keyAction: ((NSEvent) -> Bool)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.initialFirstResponder = self
    }
    override func keyDown(with event: NSEvent) {
        if keyAction?(event) != true { super.keyDown(with: event) }
    }
}

private final class MixerCollectionItem: NSCollectionViewItem {
    let button = MixerTrackButton()
    override func loadView() {
        view = button
        button.bezelStyle = .rounded
        button.alignment = .left
        button.lineBreakMode = .byWordWrapping
        button.cell?.wraps = true
        button.setButtonType(.momentaryPushIn)
    }
}

private final class MixerTrackButton: NSButton {
    var focusTrack: (() -> Void)?
    var keyAction: ((NSEvent) -> Bool)?
    var selectedTrack = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(selectTrack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectTrack() { focusTrack?() }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusTrack?() }
        return result
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused { focusTrack?() }
    }
    override func keyDown(with event: NSEvent) {
        if keyAction?(event) != true { super.keyDown(with: event) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); refreshSurface()
    }
    func refreshSurface() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 6
            layer?.borderWidth = selectedTrack ? 3 : 1
            layer?.borderColor = (NSColor(named: selectedTrack ? "AccentColor" : "Separator") ?? .separatorColor).cgColor
        }
    }
}
