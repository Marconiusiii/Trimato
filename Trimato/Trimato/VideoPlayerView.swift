import AVFoundation
import AppKit
import SwiftUI

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var accessibleFrame = false
    var frameDescription = ""

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        configureAccessibility(view)
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
        configureAccessibility(nsView)
    }

    private func configureAccessibility(_ view: PlayerNSView) {
        view.setAccessibilityElement(accessibleFrame)
        view.setAccessibilityRole(accessibleFrame ? .image : .unknown)
        view.setAccessibilityLabel(accessibleFrame ? "Video frame" : nil)
        view.setAccessibilityValue(accessibleFrame ? frameDescription : nil)
        view.setAccessibilityIdentifier(accessibleFrame ? "trimato.editor.frame" : nil)
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
