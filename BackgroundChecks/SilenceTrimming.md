# Silence trimming and clip playback responsiveness

September 14, 2026.

## Implementation

Clip-editor clock updates now use a separate observable clock. Only the timecode
text, playhead slider, and audio waveform observe these updates. The surrounding
editor and Playback controls no longer receive each periodic clock notification.
The visual refresh interval is 1/30 second; this does not change AVPlayer's video
frame rate, audio playback, or frame-stepping commands.

Trim Silences uses bundled FFmpeg silence detection on the retained source audio.
Settings control the threshold, minimum pause, and retained pause. Both stereo
channels must qualify. Analysis runs off the main actor and is cancellable.

Detection produces source-range edits rather than a replacement source file.
Preview and Apply share those ranges; video and audio are cut together. Video
cut boundaries are quantized inward to the clip's nominal frame rate. Existing
In/Out points are remapped after cuts. The existing Update Clip and export paths
receive the shortened edit. Preview is before effects and filters. Help and the
dialog explain jump cuts and the effect on later clips and other tracks.

Undo/Redo restores the edit composition and markers. Undo is required before
Apply can change the draft, and history from a different loaded clip cannot
replace the current clip. A later unrelated draft edit is not overwritten by an
old silence-trim undo.

Frame-index remapping uses binary searches through the sorted source timestamps
instead of scanning the whole source for every retained range.

## Verification

- Unsigned Debug app and test targets: build-for-testing passed.
- 132 tests across SilenceTrimmingTests, ProjectPlaybackTests, and
  MultiTrackTimelineTests passed. The opt-in physical deletion interaction test
  remained disabled; the opt-in long-playback test was enabled.
- Generated WAV and H.264 MP4: detection, retained-range preview, export duration,
  original-file preservation, Apply/Undo/Redo, and saved-project JSON round trips
  passed.
- Tests cover existing cuts, selected-range marker remapping, frame boundaries,
  entirely silent selections, no detected pauses, one active stereo channel,
  invalid settings, and cancellation before processing.
- A generated 30-minute, 30 fps H.264 MP4 played muted for five seconds in a
  background check. Playback advanced about 4.9 seconds and produced two editor
  model notifications. A separate 54,000-tick test produced zero editor-model
  notifications from clock updates.
- A 54,000-frame source with 900 retained intervals mapped to the expected 27,000
  output frames.
- Help HTML parsed, the jump-cut warning is present, and the Help index rebuilt.
- git diff --check passed.

The first video-fixture attempt requested an unavailable libx264 encoder. The
fixture was corrected to use the bundled h264_videotoolbox encoder; final tests
passed.

## Repeating the background checks

Run `zsh BackgroundChecks/check-silence-trimming.sh <Debug-products-directory>`.
Set `TRIMATO_LONG_PLAYBACK_FILE` to a local video at least 30 minutes long to
include the muted long-playback test. The helper uses a prohibited activation
policy and does not open a user-facing app window.

## Remaining user-facing verification

No competing Trimato instance was launched. The tester's specific long MP4 was
not provided. Actual VoiceOver traversal while interacting inside Playback on a
slower Mac remains unverified, as does the rendered silence-trimming sheet and
its native focus/Undo integration in the user's running Xcode build. The
background playback result establishes reduced editor notifications, not a
physical VoiceOver responsiveness result or full-duration playback soak test.
