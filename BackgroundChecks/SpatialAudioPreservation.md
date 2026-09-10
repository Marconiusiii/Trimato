# Spatial Audio preservation prototype

This standalone prototype preserves an iPhone movie's existing AAC and APAC audio tracks while exporting the full recording or the interval from one to five seconds. It also combines those tracks with a previously rendered Trimato HDR video. It does not change Trimato's normal export pipeline or stereo mixer.

## Approach

Open the original recording as an `AVMutableMovie`, retaining its alternate audio group, fallback relationship, channel layouts, and metadata tracks. For the HDR variants, replace only the video track with the video from the earlier Trimato export. Export a self-contained movie with `AVAssetExportPresetPassthrough` and `audioTrackGroupHandling = .preserveAlternateTracks`, without an audio mix.

The prototype refuses to overwrite existing movie files or validation reports. Run it into a new results directory. The input recordings and earlier HDR exports are read-only inputs.

## Run

From the repository root, using the macOS 26 SDK and a macOS 26 machine:

```sh
xcrun swiftc -module-cache-path /tmp/trimato-spatial-module-cache -parse-as-library BackgroundChecks/SpatialAudioPreservationCheck.swift -o /tmp/trimato-spatial-check
xcrun swiftc -module-cache-path /tmp/trimato-spatial-module-cache -parse-as-library BackgroundChecks/SpatialAudioDecodeCheck.swift -o /tmp/trimato-spatial-decode-check
```

For each of `4K_30fps.MOV`, `4K_60fps.mov`, and `4K_120fps.MOV`, run the following with the corresponding input names and the same new results directory:

```sh
/tmp/trimato-spatial-check appStore/test_videos/4K_30fps.MOV appStore/test_videos/validation-results/4K_30fps.MOV-HDR.mov /tmp/trimato-spatial-results
```

After all three clips have exported:

```sh
/tmp/trimato-spatial-decode-check appStore/test_videos /tmp/trimato-spatial-results
python3 BackgroundChecks/verify-spatial-preservation.py appStore/test_videos /tmp/trimato-spatial-results
```

Native AVFoundation operations require access to macOS media services. These tools do not play audio, capture the screen, or use an audio input device.

## Verification

- The exporter checks channel layouts, sample rates, enabled states, AAC fallback relationships, alternate group sizes, duration, and the result of Apple's Spatial Audio inspection API. When inspection succeeds, its metadata hash and default rendering parameters must match the original.
- The decoder compares both audio tracks against native decoding of the original, including the first samples after a trim. Full exports retain the original decoded length; trimmed exports must contain exactly four seconds. The permitted maximum difference is one millionth of full-scale amplitude, allowing floating-point decoder rounding.
- The packet verifier checks compressed AAC/APAC payloads, presentation timing, metadata payloads, HDR format properties, copied video payloads, and self-contained media references. It uses the repository's bundled FFprobe.
- Container export can omit encoded padding outside the original presentation interval. Full-length checks therefore require identical presented audio packets and decoded samples, while separately recording raw packet counts. Trimmed video may omit unneeded decoder preroll packets; exported video payloads must remain an ordered subset of the input.

## Results from the supplied clips

The September 10, 2026 run produced twelve movies and passed twenty-four native decoded-audio comparisons. All full-length decoded audio was identical. Stereo trims were identical; the largest spatial trim difference was approximately `2.98e-8` in normalized Float32 samples.

Apple's `CNAssetSpatialAudioInfo` recognizes the 30 fps and 120 fps originals and all their exported variants. The Cinematic original and all its variants return `CNCinematicErrorDomain:3` (incomplete information). Its five-channel APAC audio still decodes successfully and passes the same sample comparisons. Matching that original API limitation is recorded separately from successful spatial recognition.

## Limits

This establishes preservation for these single-source recordings, including audio paired with independently rendered HDR video. It does not implement spatial filtering, crossfades, gain changes, mixed narration/music, multiple-source assembly, or normal app integration. It does not certify head-tracked playback, subjective listening quality, video appearance, or editable Cinematic focus/depth behavior. The HDR variants reuse the previous Trimato render and retain its existing video frame-timing limitations.

Apple documents alternate audio groups in [TN3177](https://developer.apple.com/documentation/technotes/tn3177-understanding-alternate-audio-track-groups-in-movie-files) and the export/audio-mix restriction in [audioTrackGroupHandling](https://developer.apple.com/documentation/avfoundation/avassetexportsession/audiotrackgrouphandling).
