# Spatial Audio integration and validation

Spatial preservation is integrated into Trimato's normal Clip Editor and project preview/export paths through `SpatialAudioPlan`. Supported edits keep one continuous source soundtrack, with cuts in recording order and neutral audio settings. Video filters and rendering are independent of the preserved audio. Unsupported mixing, effects, fades, gaps, overlaps, repeated/reordered ranges, and MP4/audio-only exports fail explicitly.

## App integration checks

`SpatialAudioIntegrationTests` exercises normal app entry points using the three supplied iPhone 16 Pro recordings. It checks full and trimmed Clip Editor exports, full and marked-range HDR project exports, ordered cuts, video-filter output, native player readiness, live mixer safeguards, preserved channel layouts and alternate groups, spatial metadata, and decoded samples. Unsupported exports must leave an existing destination untouched.

Run the app tests with:

```sh
xcodebuild -project Trimato/Trimato.xcodeproj -scheme Trimato -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/trimato-spatial-integration -parallel-testing-enabled NO -only-testing:TrimatoTests/SpatialAudioIntegrationTests test CODE_SIGNING_ALLOWED=NO
```

The twelve main app exports are written to `/tmp/trimato-spatial-app-integration`. Verified copies, converted clip examples, ordered-cut examples, and reports from the integration run are saved in `appStore/test_videos/spatial-app-integration-results`. The standalone decoder below can independently compare them with the originals. The September 10 integration run passed all twenty-four comparisons: full-length audio was identical, AAC trims were identical, and APAC trims differed by at most `2.98e-8`. The app tests also compare the samples across removed middle sections and video-filter processing.

The preservation path keeps the original movie edit lists and removes unwanted intervals before replacing picture. Tests caught changed decoder timing when rebuilding compressed tracks individually; that approach was removed. Reordered and repeated source ranges remain unsupported because native insertion did not preserve the same decoder results.

Detection includes APAC, ambisonic PCM layouts, and spatial fallback associations. No original iPhone ProRes spatial sample has been supplied, so that capture variant is not yet device-verified. Physical VoiceOver, head tracking, and subjective video appearance are also unverified.

## Earlier standalone prototype

The standalone prototype predates integration. It preserves a recording's AAC/APAC tracks for full-length and one-to-five-second exports, including pairing them with previously rendered HDR video. Its listening samples were approved by the user; that listening result does not substitute for checking the new app paths.

### Prototype approach

Open the original recording as an `AVMutableMovie`, retaining its alternate audio group, fallback relationship, channel layouts, and metadata tracks. For the HDR variants, replace only the video track with the video from the earlier Trimato export. Export a self-contained movie with `AVAssetExportPresetPassthrough` and `audioTrackGroupHandling = .preserveAlternateTracks`, without an audio mix.

The prototype refuses to overwrite existing movie files or validation reports. Run it into a new results directory. The input recordings and earlier HDR exports are read-only inputs.

### Run the standalone checks

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

### Standalone verification

- The exporter checks channel layouts, sample rates, enabled states, AAC fallback relationships, alternate group sizes, duration, and the result of Apple's Spatial Audio inspection API. When inspection succeeds, its metadata hash and default rendering parameters must match the original.
- The decoder compares both audio tracks against native decoding of the original, including the first samples after a trim. Full exports retain the original decoded length; trimmed exports must contain exactly four seconds. The permitted maximum difference is one millionth of full-scale amplitude, allowing floating-point decoder rounding.
- The packet verifier checks compressed AAC/APAC payloads, presentation timing, metadata payloads, HDR format properties, copied video payloads, and self-contained media references. It uses the repository's bundled FFprobe.
- Container export can omit encoded padding outside the original presentation interval. Full-length checks therefore require identical presented audio packets and decoded samples, while separately recording raw packet counts. Trimmed video may omit unneeded decoder preroll packets; exported video payloads must remain an ordered subset of the input.

### Earlier prototype results

The September 10, 2026 run produced twelve movies and passed twenty-four native decoded-audio comparisons. All full-length decoded audio was identical. Stereo trims were identical; the largest spatial trim difference was approximately `2.98e-8` in normalized Float32 samples.

The user subsequently listened to the supplied samples and confirmed that they all sounded good. This listening result is separate from the automated comparisons; head-tracked playback was not specifically assessed.

Apple's `CNAssetSpatialAudioInfo` recognizes the 30 fps and 120 fps originals and all their exported variants. The Cinematic original and all its variants return `CNCinematicErrorDomain:3` (incomplete information). Its five-channel APAC audio still decodes successfully and passes the same sample comparisons. Matching that original API limitation is recorded separately from successful spatial recognition.

### Prototype limits

This establishes preservation for these single-source recordings, including audio paired with independently rendered HDR video. It does not implement spatial filtering, crossfades, gain changes, mixed narration/music, multiple-source assembly, or normal app integration by itself. The app integration described above now supplies preview and export support for the stated edit scope. The listening approval applies to the supplied samples, not all possible sources or playback devices. Head-tracked playback, video appearance, and editable Cinematic focus/depth behavior remain unverified. The HDR variants reuse the previous Trimato render and retain its existing video frame-timing limitations.

Apple documents alternate audio groups in [TN3177](https://developer.apple.com/documentation/technotes/tn3177-understanding-alternate-audio-track-groups-in-movie-files) and the export/audio-mix restriction in [audioTrackGroupHandling](https://developer.apple.com/documentation/avfoundation/avassetexportsession/audiotrackgrouphandling).
