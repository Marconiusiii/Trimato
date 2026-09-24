import AppKit
import AVFoundation
import QuartzCore
@testable import Trimato

@main struct FrameJogCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        precondition(NSApp == nil)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 12)))
        let asset = MediaAssetRecord(name: "Jog fixture", originalPath: url.path, duration: ProjectTime(seconds: 12), naturalWidth: 640, naturalHeight: 360, frameRate: 30, hasAudio: true, sourceEdit: [segment], playbackMode: .nativePassthrough)
        var document = TrimatoProject(name: "Frame jogging")
        document.format = ProjectFormat(mode: .custom, width: 640, height: 360, frameRate: 30)
        document.media = [asset]
        document.tracks = [TimelineTrack(name: "Video", kind: .video, role: .primaryVideo, clips: [TimelineClip(assetID: asset.id, name: "Video", segments: [segment])]), TimelineTrack(name: "Audio", kind: .audio, role: .primaryAudio, clips: [TimelineClip(assetID: asset.id, name: "Audio", segments: [segment])])]
        let project = ProjectPlayerViewModel()
        project.player.volume = 0 // Route discovery cannot undo this silent test volume.
        let layer = AVPlayerLayer(player: project.player)
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let rootLayer = CALayer(); rootLayer.addSublayer(layer)
        project.prepare(project: document, mediaURLs: [asset.id: url])
        for _ in 0..<1200 { if project.canControlPlayback { break }; try await Task.sleep(for: .milliseconds(25)) }
        print("Preparation: ready=\(project.hasPreparedPlayerItem), loading=\(project.isPreparing), progress=\(String(describing: project.preparationProgress)), item=\(String(describing: project.player.currentItem?.status.rawValue))")
        precondition(project.canControlPlayback, "Preparation: \(String(describing: project.errorMessage))")

        project.seek(to: ProjectTime(seconds: 2))
        try await Task.sleep(for: .milliseconds(150))
        var onset: [Double] = []
        for index in 0..<12 {
            let target = project.currentTime.seconds + (index % 2 == 0 ? 1.0 / 30 : -1.0 / 30)
            let started = CACurrentMediaTime()
            if index % 2 == 0 { project.stepForward() } else { project.stepBackward() }
            precondition(project.playbackClock.isMoving, "Project jog did not invalidate its clock presentation")
            while !project.frameAudioPreview.isPlaying && CACurrentMediaTime() - started < 3 {
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(project.frameAudioPreview.isPlaying, "PCM preview was not scheduled")
            precondition(!project.playbackClock.isMoving, "Project jog completion did not refresh its clock presentation")
            onset.append((CACurrentMediaTime() - started) * 1000)
            precondition(project.player.rate == 0 && abs(project.player.currentTime().seconds - target) < 0.001,
                "Video must remain paused on the selected frame throughout its audio preview")
            try await Task.sleep(for: .milliseconds(220))
            precondition(abs(project.player.currentTime().seconds - target) < 0.001)
        }
        func report(_ title: String, _ values: [Double]) {
            let s = values.sorted()
            print(String(format: "%@: median %.2f ms; max %.2f ms", title, s[s.count/2], s.last!))
        }
        report("Project audio buffer scheduled", onset)
        project.seek(to: ProjectTime(seconds: 2))
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<15 { project.stepForward(); try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<5 { project.stepBackward(); try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .seconds(2))
        let expected = 2 + 10.0/30
        precondition(abs(project.player.currentTime().seconds - expected) < 0.002, "Rapid direction changes lost frame targets")
        project.seek(to: ProjectTime(seconds: 2))
        project.stepForward()
        project.seek(to: ProjectTime(seconds: 5))
        try await Task.sleep(for: .milliseconds(400))
        precondition(!project.frameAudioPreview.isPlaying && abs(project.player.currentTime().seconds - 5) < 0.002,
            "Cancelled preview restarted after a normal seek")
        let sourceAsset = AVURLAsset(url: url)
        let clip = VideoPlayerViewModel()
        clip.player.volume = 0
        let clipLayer = AVPlayerLayer(player: clip.player); rootLayer.addSublayer(clipLayer)
        clip.load(url: url, preparedSource: .native(url: url, asset: sourceAsset, contentType: nil,
            mode: .nativePassthrough,
            frameTimestamps: (0..<360).map { CMTime(value: Int64($0), timescale: 30) }, hasAudio: true))
        for _ in 0..<1000 {
            if clip.hasMedia && clip.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(clip.hasMedia && !clip.isLoadingMedia)
        clip.seek(to: 2.0 / 12)
        try await Task.sleep(for: .milliseconds(100))
        var clipOnset: [Double] = []
        for index in 0..<12 {
            let target = index % 2 == 0 ? 2 + 1.0 / 30 : 2
            let start = CACurrentMediaTime()
            if index % 2 == 0 { clip.stepForward() } else { clip.stepBackward() }
            precondition(clip.playbackClock.isMoving, "Clip jog did not invalidate its clock presentation")
            while !clip.frameAudioPreview.isPlaying && CACurrentMediaTime() - start < 3 {
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(clip.frameAudioPreview.isPlaying, "Clip audio preview did not start")
            precondition(!clip.playbackClock.isMoving, "Clip jog completion did not refresh its clock presentation")
            clipOnset.append((CACurrentMediaTime()-start)*1000)
            precondition(clip.player.rate == 0 && abs(clip.player.currentTime().seconds - target) < 0.002)
            try await Task.sleep(for: .milliseconds(220))
            precondition(abs(clip.player.currentTime().seconds - target) < 0.002)
        }
        report("Clip audio buffer scheduled", clipOnset)
        clip.seek(to: 2.0/12)
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<15 { clip.stepForward(); try await Task.sleep(for: .milliseconds(2)) }
        for _ in 0..<5 { clip.stepBackward(); try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(400))
        precondition(abs(clip.player.currentTime().seconds - expected) < 0.002)
        clip.stepForward(); clip.seek(to: 5.0 / 12)
        try await Task.sleep(for: .milliseconds(400))
        precondition(!clip.frameAudioPreview.isPlaying && abs(clip.player.currentTime().seconds - 5) < 0.002)
        print("PASS: project and clip exact frames, rapid reversals, preview cancellation and paused video during audio preview")
        let samples = try await FrameAudioSamples.read(asset: sourceAsset, mix: nil, at: CMTime(value: 60, timescale: 30))
        let next = try await FrameAudioSamples.read(asset: sourceAsset, mix: nil, at: CMTime(value: 61, timescale: 30))
        precondition(samples.count == 19200 && next.count == 19200)
        let mismatch = zip(samples.dropFirst(3200), next.prefix(16000)).map { abs($0-$1) }.max()!
        precondition(mismatch < 0.001, "Adjacent frame audio is not sample aligned: \(mismatch)")
        let silentMix = AVMutableAudioMix()
        silentMix.inputParameters = try await sourceAsset.loadTracks(withMediaType: .audio).map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.setVolume(0, at: .zero)
            return parameters
        }
        let silence = try await FrameAudioSamples.read(asset: sourceAsset, mix: silentMix, at: CMTime(seconds: 2, preferredTimescale: 30))
        precondition(silence.allSatisfy { abs($0) < 0.000001 }, "Preview ignored its audio mix")
        let tapMix = AVMutableAudioMix()
        let processor = TrackMixProcessor(trackID: UUID(), matrix: .silent)
        tapMix.inputParameters = try await sourceAsset.loadTracks(withMediaType: .audio).map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.audioTapProcessor = try processor.copyProcessor().makeTap()
            return parameters
        }
        let tapSilence = try await FrameAudioSamples.read(asset: sourceAsset, mix: tapMix, at: CMTime(seconds: 2, preferredTimescale: 30))
        precondition(tapSilence.allSatisfy { abs($0) < 0.000001 }, "Preview ignored its mix processor")
        let tail = try await FrameAudioSamples.read(asset: sourceAsset, mix: nil, at: CMTime(seconds: 11.95, preferredTimescale: 48000))
        precondition(tail.count == 4800)
        let end = try await FrameAudioSamples.read(asset: sourceAsset, mix: nil, at: CMTime(seconds: 12, preferredTimescale: 30))
        precondition(end.isEmpty)
        print("PASS: adjacent preview samples align; native mix mute is honored; end-of-media previews are bounded")
        if CommandLine.arguments.contains("--native-comparison") {
            for nativeStep in [false, true] {
                for _ in 0..<3 {
                    project.seek(to: ProjectTime(seconds: 2))
                    try await Task.sleep(for: .milliseconds(150))
                    let target = CMTime(seconds: 2 + 1.0/30, preferredTimescale: 600000)
                    let start = CACurrentMediaTime()
                    if nativeStep {
                        project.player.currentItem?.step(byCount: 1)
                        while abs(project.player.currentTime().seconds - target.seconds) > 0.002 && CACurrentMediaTime() - start < 2 {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                    } else {
                        await project.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    let landed = CACurrentMediaTime()
                    project.player.playImmediately(atRate: 1)
                    while project.player.currentTime().seconds < target.seconds + 0.005 && CACurrentMediaTime() - landed < 2 {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    print(String(format: "Native %@: seek %.2f ms; start %.2f ms", nativeStep ? "step" : "seek", (landed-start)*1000, (CACurrentMediaTime()-landed)*1000))
                    project.player.pause()
                }
            }
        }
        withExtendedLifetime((layer, rootLayer)) {}
        precondition(project.player.rate == 0 && NSApp == nil)
        print("PASS: twenty rapid directional taps retained exact final frame; muted playback, no app or focus changes. Buffer scheduling timestamps are not physical audio-output measurements.")
    }
}
