# Project export hang investigation

## Report and scope

The Dayton Demo reports identify Trimato 1.6.1 build 2 on macOS 27.0 (26A428).
The matching arm64 archive UUID is `165951BC-9B7E-3E36-A919-FA04D7AEF76E`.
The second sample records the main thread inside a SwiftUI Slider update throughout the capture.
Symbolication of the first sample identifies ProjectViewerView and Timeline updates.
Media export workers are present and waiting; these samples do not establish why they are waiting.

The project contains six music clips, an additional video track, and its additional audio track.
Its duration is approximately 830.0673 seconds, with video lasting approximately 802.0633 seconds,
at 1728 by 1118 pixels and 25 frames per second. No clip filters or transitions are saved.

## Confirmed notification defect

Reporting the same staged playhead position 100 times produced 100 frame notifications and
100 timecode notifications in the unmodified model. The corrected model publishes neither
unchanged value, while moving the playhead still updates both. Unchanged export progress
also no longer publishes another project-controller update.

These changes preserve slider steps, frame navigation, native controls, and accessibility values.
They reduce repeated Editor updates; they do not by themselves prove the tester's exact hang is fixed.

## Background checks

`ProjectDisplayUpdatesCheck.swift` observes the actual production model without creating views,
windows, or playing media. Run it against a Debug build:

```sh
zsh BackgroundChecks/check-project-display-updates.sh /path/to/Build/Products/Debug
```

`ExportHangCheck.swift` decodes the supplied project JSON and generates replacement media in a
separate temporary directory. It does not resolve or alter the tester's original media, bookmarks,
or project. WAV replaces the MP3 source because the bundled FFmpeg does not provide an MP3 encoder.
Generated audio includes a small tail beyond the saved ranges to accommodate source-range rounding.
The video fixture uses the saved dimensions and frame rate. No application windows or playback occur.

```sh
zsh BackgroundChecks/check-export-hang.sh /path/to/Build/Products/Debug /path/to/project.json
```

The script prints its artifact directory. Supply that directory as the third argument to reuse
fixtures. Supply `--cancel` as the fourth argument to cancel an export and verify an existing
output file is preserved. Keep runs sequential when reusing one artifact directory.

The local system is macOS 26.6.2, whereas the tester runs macOS 27.0. Generated-media exports
cannot reproduce source-specific decoding problems or establish macOS 27 interface behavior.
Actual VoiceOver, on-screen responsiveness, and the tester's exact export remain tester checks.

## Results from this repair

- Background Debug build passed. Pre-existing Mixer Sendable and media-characteristic deprecation warnings remain.
- Model notification check failed before the repair with 100 duplicate frame and 100 duplicate timecode notifications; it passed afterward with zero duplicates and one update per display when the position changed.
- Full generated-media H.264/stereo export passed before the repair in about 90 seconds and afterward in about 89 seconds. Both outputs validated at 830.067298 seconds with audio and video tracks. This does not demonstrate an encoding speed improvement.
- The repaired export passed cancellation after two seconds and preserved the existing destination's bytes.
- Decoding the repaired output recovered the generated blue picture at 240 and 780 seconds and audible signal in the audio tail at 815 seconds. No video frame was returned at 815 seconds, after the saved video ends; these checks do not assert how individual players display the audio-only tail.
- The input project JSON remained unchanged. The exact original-media export and macOS 27 interface hang were not reproduced locally.
