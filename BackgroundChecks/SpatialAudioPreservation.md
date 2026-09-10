# Spatial Audio integration and validation

Spatial preservation is integrated into Trimato's normal Clip Editor and project preview/export paths through `SpatialAudioPlan`. Ordered cuts with unchanged audio preserve the original encoding and metadata. A separate processing path now supports volume, mute, fades, crossfades, reordered/repeated sections, and gaps across compatible source recordings and audio tracks. Video rendering remains independent. Export offers Preserve Spatial Audio and High-quality Stereo. Edits that cannot preserve spatial channels use a labeled stereo preview and an explicit stereo export choice.

## App integration checks

`SpatialAudioIntegrationTests` exercises normal app entry points using the three supplied iPhone 16 Pro recordings. It checks full and trimmed Clip Editor exports, full and marked-range HDR project exports, ordered cuts, video-filter output, native player readiness, live mixer safeguards, preserved channel layouts and alternate groups, spatial metadata, and decoded samples. Unsupported exports must leave an existing destination untouched.

Run the app tests with:

```sh
xcodebuild -project Trimato/Trimato.xcodeproj -scheme Trimato -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/trimato-spatial-integration -parallel-testing-enabled NO -only-testing:TrimatoTests/SpatialAudioIntegrationTests test CODE_SIGNING_ALLOWED=NO
```

The twelve main app exports are written to `/tmp/trimato-spatial-app-integration`. Verified copies, converted clip examples, ordered-cut examples, and reports from the integration run are saved in `appStore/test_videos/spatial-app-integration-results`. The standalone decoder below can independently compare them with the originals. The September 10 integration run passed all twenty-four comparisons: full-length audio was identical, AAC trims were identical, and APAC trims differed by at most `2.98e-8`. The app tests also compare the samples across removed middle sections and video-filter processing.

The preservation path keeps the original movie edit lists and removes unwanted intervals before replacing picture. Tests caught changed decoder timing when rebuilding compressed tracks individually; that approach was removed. Reordered and repeated source ranges use the decoded processing path because compressed native insertion did not preserve the same decoder results.

Detection includes APAC, ambisonic PCM layouts, and spatial fallback associations. No original iPhone ProRes spatial sample has been supplied, so that capture variant is not yet device-verified. Physical VoiceOver, head tracking, and subjective video appearance are also unverified.

## Spatial processing checks

`SpatialAudioProcessingTests` checks project export through `ProjectExporter` and preview through `ProjectCompositionBuilder`. It compares all channels of the stereo alternative and spatial soundtrack with independently calculated volume and transition envelopes. Volume plus an introductory fade is tested against all three supplied recordings; both between-clip transitions and repeated processing use the five-channel Cinematic recording. The live Master Volume test checks the rebuilt player asset.

The renderer decodes the source once per preparation into temporary Float32 files, processes bounded blocks, and writes uncompressed audio with the original channel layout and sample rate. Preview and export share the edit plan. Repeated Volume changes are debounced but currently rebuild the soundtrack; a reusable decoded-source cache is not implemented. Long recordings can therefore take time and temporary disk space.

Matching Float32 PCM is read directly. Requesting an unnecessary Core Audio conversion changed the five-channel hybrid layout by adding part of the first channel to the others; raw stored samples were correct. Regression checks cover reprocessing a generated movie. Zero-sample decoder drain markers are skipped. Other multichannel PCM working formats are rejected for processing until conversion is verified.

Processed movies retain alternate audio grouping and the stereo fallback association. They do not copy original recording-analysis metadata. Apple's spatial metadata sample generator is unavailable on macOS, so these exports must not be described as retaining Apple's editable Audio Mix analysis. Native player readiness and sample comparisons do not establish head-tracked rendering on a physical playback device.

The resumed September 10 run passed 12 tests in 3 suites: spatial preservation, spatial processing, and Help. Processed samples and a short report are saved in `appStore/test_videos/spatial-processing-results`. All processing sample comparisons met the `1e-6` tolerance.

## Multiple recordings and export audio choice

The renderer assigns a source URL to each edit region, decodes each recording separately, and processes all regions at their timeline positions. It accepts matching spatial layouts and the standard iPhone four-channel SN3D layout combined with the Cinematic SN3D-plus-center five-channel layout. For four-channel regions, the fifth channel is silent; the original four coefficients are copied without a conversion or normalization change. Other layouts or rates require stereo and are checked before offering spatial export.

`MultiSourceSpatialTests` reads the optional `~/Movies/proClips/proClips.trimato/project.json` fixture, adds the third imported recording to an in-memory edit, round-trips project serialization, prepares spatial preview, exports spatial video and 24-bit stereo audio, compares source samples, and checks that the original project JSON is unchanged. Another test blends four- and five-channel recordings and checks every channel. Standalone native and FFmpeg-routed clip exports are also checked for explicit stereo delivery.

For compatible spatial edits, stereo project export takes the stereo alternative from the same sample-aligned rendered soundtrack used for spatial output. For other effects, stereo project rendering copies each recording's existing stereo alternative into a temporary source without another audio encoding step, and the ordinary mixer and effects engine process these sources; the final selected format determines uncompressed, lossless, or high-quality AAC encoding. The export panel remembers the audio choice, identifies its encoding, and limits formats to compatible choices. Processed spatial exports remain uncompressed Float32 with a stereo alternative.

The final multiple-recording run passed 79 tests in seven suites. Generated spatial and 24-bit stereo examples are saved in `appStore/test_videos/multi-recording-results`. Shared rendering fixes per-cut stereo timing rounding; PCM movie timescales and rounded sample-count export ranges retain the complete audio duration.

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
