# Editor picture verification

The proClips regression exposed two independent problems in the spatial-audio project preview:

1. Inserting the composed video track into an AVMutableMovie in one operation retained only the first source segment. The video stopped at 6.76676 seconds in a 20.761953-second edit. Copying each source segment separately preserves every cut, timeline position, gap, and playback speed.
2. Audio sample rounding made the playback movie 20.761958333333332 seconds long, while its final video instruction ended at 20.761953333333334 seconds. AVFoundation rejected those instructions, and AVPlayer delivered no video despite reporting a ready player item. Extending the final instruction over this fractional tail restored video delivery. Preview preparation now validates the final instructions before using them.

## Verified

- The Debug app and test targets build successfully.
- Both focused Swift Testing regressions pass: fractional audio tails, and picture preservation with two sources, a gap, a speed change, and a repeated source. The latter also verifies spatial audio track structure remains preserved.
- The saved proClips edit produces nonblack preview frames matching the base timeline's sampled picture statistics at 1, 7.5, 11, and 16 seconds.
- The production AVPlayerLayer reports ready for display. Muted AVPlayer playback delivers nonblack frames and advances through all three cut boundaries, as well as within each clip.
- The detached Editor view gives its video layer a nonzero display area.
- The diagnostic confirms the saved project JSON remains unchanged.

The background checks decode video in memory without opening windows or playing audible sound. Subsequent authorized Computer Use inspection confirmed visible footage from all four clips, playback through the end, and seeking in the actual Editor. The separate Computer Use helper permissions resolved the earlier connection failure. Physical VoiceOver behavior remains unverified.

## Run

From the repository root:

```sh
xcodebuild -project Trimato/Trimato.xcodeproj -scheme Trimato \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/trimato-editor-picture-build \
  CODE_SIGNING_ALLOWED=NO build-for-testing
zsh BackgroundChecks/check-editor-picture.sh \
  /tmp/trimato-editor-picture-build/Build/Products/Debug \
  /Users/pallas/Movies/proClips/proClips.trimato
```

The background script requires Xcode, macOS 15 or later, the local iPhone test fixtures, and the original proClips sources. Its sample times and cut-boundary checks are specific to the reported proClips edit. It links the built production code and runs the two focused tests without launching Trimato. Compilation and generated media use temporary directories.

## What to test on screen

Open proClips in the rebuilt app and play the whole project in the Editor pane. Check that all four clips appear, the picture continues across every cut, and audio stays in sync. Pause and seek into each clip, then resize the window and reopen the project. Confirm that the picture remains visible and that the Editor's keyboard and VoiceOver controls still work.

## Playback control layout verification

The Editor now reserves the controls' measured height and lets the video fit the remaining space. Its minimum height includes the complete controls, heading, and a small visible video area. Standard bordered buttons, reduced spacing, and a compact timecode make better use of the pane. Native `ViewThatFits` places timecode beside transport controls when space permits, with a stacked fallback. Existing pane containers, control labels, and keyboard commands are retained.

The layout build passed. Authorized visual checks with proClips confirmed:

- All controls and the Editor heading are visible at the minimum window size and in the enlarged window.
- Moving the Editor/Timeline divider down enlarges the fitted video. Moving it upward stops before the controls become clipped.
- Video remains visible during playback and after resizing.
- Play, pause, seeking, and timecode toggling work.
- Tab navigation reaches the Editor buttons, and the existing Space-bar command starts and pauses playback.
- The accessibility tree exposes the existing Project, Editor, and Timeline containers and the control groups. This is not a physical VoiceOver validation.

Build used for the layout inspection: `/tmp/trimato-editor-layout-build/Build/Products/Debug/Trimato.app`.
