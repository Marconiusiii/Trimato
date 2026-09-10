import AVFoundation
import AppKit
import SwiftUI

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var captionCues: [CaptionCue] = []
    var captionDuration = ProjectTime.zero
    var captionRenderSize: CGSize?
    var accessibleFrame = false
    var frameDescription = ""

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.configureCaptionPreview(
            cues: captionCues,
            duration: captionDuration,
            renderSize: captionRenderSize
        )
        configureAccessibility(view)
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
        nsView.configureCaptionPreview(
            cues: captionCues,
            duration: captionDuration,
            renderSize: captionRenderSize
        )
        configureAccessibility(nsView)
    }

    private func configureAccessibility(_ view: PlayerNSView) {
        let state = PlayerNSView.FrameAccessibility(isVisible: accessibleFrame, description: frameDescription)
        guard view.frameAccessibility != state else { return }
        let visibilityChanged = view.frameAccessibility?.isVisible != accessibleFrame
        view.frameAccessibility = state
        if visibilityChanged {
            view.setAccessibilityElement(accessibleFrame)
            view.setAccessibilityRole(accessibleFrame ? .image : .unknown)
            view.setAccessibilityLabel(accessibleFrame ? "Video frame" : nil)
            view.setAccessibilityIdentifier(accessibleFrame ? "trimato.editor.frame" : nil)
        }
        view.setAccessibilityValue(accessibleFrame ? frameDescription : nil)
    }
}

final class PlayerNSView: NSView {
    struct FrameAccessibility: Equatable {
        let isVisible: Bool
        let description: String
    }
    var frameAccessibility: FrameAccessibility?
    let playerLayer = AVPlayerLayer()
    private var captionSynchronizedLayer: AVSynchronizedLayer?
    private var captionContentLayer: CALayer?
    private var captionState: CaptionPreviewState?

    private struct CaptionPreviewState: Equatable {
        let playerItem: ObjectIdentifier
        let cues: [CaptionCue]
        let duration: ProjectTime
        let renderSize: CGSize
    }

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

    func configureCaptionPreview(
        cues: [CaptionCue],
        duration: ProjectTime,
        renderSize: CGSize?
    ) {
        guard let item = playerLayer.player?.currentItem,
              let renderSize,
              renderSize.width > 0,
              renderSize.height > 0,
              !cues.isEmpty,
              duration.isPositive else {
            removeCaptionPreview()
            return
        }

        let state = CaptionPreviewState(
            playerItem: ObjectIdentifier(item),
            cues: cues,
            duration: duration,
            renderSize: renderSize
        )
        guard state != captionState else { return }
        removeCaptionPreview()

        guard let content = try? CaptionOverlayRenderer.previewLayer(
            cues: cues,
            renderSize: renderSize,
            duration: duration
        ) else { return }

        let synchronized = AVSynchronizedLayer(playerItem: item)
        synchronized.addSublayer(content)
        layer?.addSublayer(synchronized)
        captionSynchronizedLayer = synchronized
        captionContentLayer = content
        captionState = state
        layoutCaptionPreview()
    }

    private func removeCaptionPreview() {
        captionSynchronizedLayer?.removeFromSuperlayer()
        captionSynchronizedLayer = nil
        captionContentLayer = nil
        captionState = nil
    }

    private func layoutCaptionPreview() {
        guard let synchronized = captionSynchronizedLayer,
              let content = captionContentLayer,
              let state = captionState else { return }
        synchronized.frame = playerLayer.videoRect
        content.bounds = CGRect(origin: .zero, size: state.renderSize)
        content.position = CGPoint(x: synchronized.bounds.midX, y: synchronized.bounds.midY)
        content.setAffineTransform(CGAffineTransform(
            scaleX: synchronized.bounds.width / state.renderSize.width,
            y: synchronized.bounds.height / state.renderSize.height
        ))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        layoutCaptionPreview()
        CATransaction.commit()
    }
}
