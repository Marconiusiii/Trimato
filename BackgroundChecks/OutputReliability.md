# File handling and output verification

The September 11, 2026 reliability update passed an unsigned macOS build-for-testing, 37 background tests in 10 suites, the output verification harness, and the existing voice-bypass regression check. These checks do not launch Trimato's interface or play audio.

## Behavior covered

- Exports inspect staged media for a usable duration and expected tracks before committing the destination. Cancellation is checked again at commit. Progress reaches completion after commit.
- Original source paths, symbolic links, and hard links cannot be selected as export destinations.
- Empty staging files, invalid destinations, cancelled operations, changed sources, and missing verified copies preserve existing files.
- New projects are prepared separately and moved into place without replacing an existing folder. Failed writes leave the existing project and unsaved state intact.
- Caption and description data is encoded before the main export. Companion writes are individually atomic and respect cancellation. If a companion write fails after the media is saved, the interface reports a partial result. The interface wording is compiled but was not interactively tested.
- Temporary render sessions hold a process-lifetime lock. Cleanup reclaims old unlocked sessions while keeping active sessions and unrelated files. Normal operation cleanup remains immediate. Older files outside the owned-session directory are left alone.
- Intermediate storage estimates include Float32 audio sample rate and channels, video dimensions and frame rate, alpha overhead, and a safety margin. Nonfinite or overflowing estimates fail safely.

## Measured output checks

A four-second retained edit from a two-minute synthetic recording measured -19.95 LUFS against a -20 LUFS target, with a -16.23 dBTP peak. Discarded loud material did not determine its gain. The renderer retains source timing and transition handles; matched preview, project preparation, and a crossfade were checked. Silence stayed silent. A high-crest-factor fixture respected its peak ceiling even when that prevented reaching its loudness target. Reverb/echo ordering is unchanged; an echo and final clip limiter combination was checked.

Match Loudness now measures the retained edit, then applies a constant gain constrained by its measured true peak. It does not automatically normalize the final mix. The overlapping-track check compares a stereo reference export with two identical tracks and -6 dB master gain, accounting for the mixer's mono-to-stereo routing.

The harness covered:

- Selected-range WAV 24-bit, Apple Lossless, FLAC, and AAC project exports.
- Full-project mixed audio and H.264 video.
- Standalone H.264, HEVC, and ProRes 422 video.
- Native passthrough and FFmpeg H.264 export.
- Corrupt and wrong-duration staged output rejection.
- Cancellation near audio-writer finalization while preserving an existing destination.
- Source project save/reopen and failed-write preservation.
- Spatial selected-range preservation using `appStore/test_videos/4K_30fps.MOV`, followed by HDR filtering. The original recording's SHA-256 checksum remained unchanged.
- Removal of completed filter intermediates.

The synthetic long-source timing is a local regression observation, not a performance guarantee for arbitrary recordings. Metadata validation does not decode and compare every output frame or audio sample. These checks do not establish perceptual quality, physical VoiceOver behavior, real disk-exhaustion or external-drive-disconnection recovery, Intel runtime behavior, or signed-distribution readiness.

## Run the checks

Build the app and test targets without launching them:

```sh
xcodebuild -project Trimato/Trimato.xcodeproj -scheme Trimato \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/trimato-reliability-build \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Run the background checks:

```sh
swift test --scratch-path /tmp/trimato-reliability-package
zsh BackgroundChecks/check-output-reliability.sh /tmp/trimato-reliability-build/Build/Products/Debug
zsh BackgroundChecks/check-filter-bypass.sh /tmp/trimato-reliability-build/Build/Products/Debug
```

The output harness requires the local iPhone fixture named above. It uses the compiled production code and repository FFmpeg tools, writes disposable outputs under the temporary directory, and removes them after the checks.
