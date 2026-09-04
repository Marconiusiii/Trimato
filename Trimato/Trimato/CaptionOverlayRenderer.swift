import AVFoundation
import QuartzCore

nonisolated enum CaptionOverlayRenderer {
    static func apply(
        cues: [CaptionCue],
        to videoComposition: AVMutableVideoComposition,
        renderSize: CGSize,
        duration: ProjectTime
    ) throws {
        let cues = cues.filter { $0.start < duration && $0.end > .zero }
        guard !cues.isEmpty, duration.isPositive else { return }

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.isGeometryFlipped = true
        let video = CALayer()
        video.frame = root.bounds
        root.addSublayer(video)

        try addCaptionLayers(cues: cues, to: root, renderSize: renderSize, duration: duration)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: video,
            in: root
        )
    }

    static func previewLayer(
        cues: [CaptionCue],
        renderSize: CGSize,
        duration: ProjectTime
    ) throws -> CALayer? {
        let cues = cues.filter { $0.start < duration && $0.end > .zero }
        guard !cues.isEmpty, duration.isPositive else { return nil }

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.isGeometryFlipped = true
        try addCaptionLayers(cues: cues, to: root, renderSize: renderSize, duration: duration)
        return root
    }

    private static func addCaptionLayers(
        cues: [CaptionCue],
        to root: CALayer,
        renderSize: CGSize,
        duration: ProjectTime
    ) throws {

        for cue in cues {
            var definition = GeneratorDefinition()
            definition.kind = .text
            definition.width = max(Int(renderSize.width.rounded()), 1)
            definition.height = max(Int(renderSize.height.rounded()), 1)
            definition.duration = cue.duration
            definition.textSettings.apply(.caption)
            definition.textSettings.text = cue.text
            let image = try TextGeneratorRenderer.image(definition)

            let layer = CALayer()
            layer.frame = root.bounds
            layer.contents = image
            layer.contentsGravity = .resize
            layer.opacity = 0

            let start = max(cue.start.seconds / duration.seconds, 0)
            let end = min(cue.end.seconds / duration.seconds, 1)
            let epsilon = min(0.000_001, max((end - start) / 10, 0))
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.duration = duration.seconds
            animation.values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0].map { NSNumber(value: $0) }
            animation.keyTimes = [
                0.0,
                max(start - epsilon, 0),
                start,
                end,
                min(end + epsilon, 1),
                1.0
            ].map { NSNumber(value: $0) }
            animation.calculationMode = .discrete
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "captionVisibility")
            root.addSublayer(layer)
        }
    }
}
