# Trimato 1.11 performance validation

Version 1.11.0, build 4, on the faster branch introduces background import discovery, bounded media preparation, exact frame timing windows, shared render reuse, and writer-driven export delivery. This document records engineering checks and local measurements. It does not establish performance parity with Final Cut Pro.

## Architecture

Folder import discovers media and captions in a single cancellable background walk. Up to four files can prepare metadata and playback media concurrently. Imported results retain their original sorted order. Captions are decoded away from the main actor.

Cutting Board frame navigation reads original presentation timing near the playhead, then maps those timestamps through the retained source ranges. It does not require decoding and indexing the entire video before opening it. Normal timing windows cover about two seconds in the requested direction, expand for longer jumps or sparse frames, and retain at most three windows. Binary searches find frame and source-segment boundaries. Replacing or editing the clip invalidates its timing windows.

Shared media tasks track each consumer. Cancelling one consumer returns promptly while other consumers can continue. Cancelling the final consumer cancels the producer. Operation identifiers prevent a cancelled producer from completing a newer request for the same key. Proxy output stays in a unique partial file until the cache actor validates the current operation and source, then commits it.

Completed filter renders use source identity and a normalized settings recipe. Filter and source-segment identifiers do not create redundant cache entries. The render format has an explicit version in its key; future processing changes must update that version. Each consumer receives a removable hard link, or a file copy when hard links are unavailable. Removing one preview or clearing cached renders does not remove another consumer's file. Failed output is not committed to the cache. Separate usage metadata tracks recency without changing the media file or any hard-linked consumer's modification time.

Video filter preparation retains the selected source envelope and transition handles, including preceding picture samples. Prepared clip ranges are rebased to the rendered media. Unsupported native source timing falls back to full-source processing. Stateful audio effects retain source history, and loudness and voice processing retain their selection-dependent recipes.

The existing 10 GiB media-cache budget includes 256 MiB for analysis and 2 GiB for completed renders. The remainder is available for playback proxies. Active preview files also occupy temporary storage; cache eviction cannot reclaim a file that still has an active hard link. Cleanup rechecks available capacity after removing cached renders.

Short inspections have two scheduling slots, full frame analysis has one separate slot, and background FFmpeg renders have one slot. An interactive render can use a second render slot on Macs with at least eight active processors and 16 GiB of memory. Other Macs use one render slot. Waiting interactive work takes priority. Already-running work is not interrupted to satisfy a later request.

Native audio and video exports supply samples when the writer requests them rather than polling every five milliseconds. A shared serial delivery queue coordinates writer inputs and cancellation, while AVFoundation performs encoding internally. Progress updates are bounded to roughly five per second. Final progress and cancellation checks happen before validation and destination commit. Binary FFmpeg output bypasses the text-line parser. Standard output and diagnostics drain concurrently, and completion waits for the output reader before collecting its result.

Single-range FFmpeg export seeks before opening the input, retaining accurate transcoding seek behavior. The HDR renderer reuses a GPU Core Image context across jobs and disables intermediate-image retention. Intel FFmpeg binaries now enable NASM assembly routines and runtime processor detection; the universal executables and matching debug symbols were rebuilt.

## Measurements

The repeatable workload uses disposable synthetic files on an Apple M3 Pro (Mac15,6), with 12 logical processors and 18 GiB memory, running arm64 on macOS 27.0.1. The baseline measured four directory walks, linear frame lookup, uncached repeated filtering, and output-side seeking before the implementation changed. The final run measures the corresponding production paths with the same core workloads.

| Workload | Baseline | Final |
| --- | ---: | ---: |
| Discover 2,000 files | 173.445 ms | 73.350 ms |
| 200 lookups in a 432,000-frame index | 183.630 ms | 0.025 ms |
| Prepare the same filtered project twice | 369.577 ms | 195.220 ms |
| Export two seconds starting at second 55 | 443.604 ms | 186.908 ms |

The previous opening path built a full 60-second frame index in 968.0 ms. The new near-playhead timing window took 29.6 ms, a late window at second 55 took 3.0 ms, and 200 consecutive frame-step targets took 6.2 ms. These timings cover timing preparation and target selection, rather than complete window opening or AVPlayer seek latency. The retained full-index diagnostic took 624.6 ms cold and 3.0 ms warm.

The baseline host peak was 260.7 MiB. The expanded final workload reached 322.7 MiB before the GPU experiment and 337.6 MiB overall. Its child-process peak was 52.8 MiB. The additional native timing work changes the workload and framework footprint; these observations do not establish a reduction in overall application memory.

[Read the baseline measurement data.](Performance-1.11-baseline.json)

[Read the final isolated measurement data.](Performance-1.11-final.json)

### GPU evaluation

A five-second, 640 by 360, 60 fps SDR Black and White example used ProRes 422 LT in both paths. The existing software-filter path took 354.3 ms; the native Core Image prototype took 551.7 ms. The first decoded RGB frame differed by an average of 31.73 per 8-bit channel value. The prototype therefore did not meet output parity, and this cold synthetic example showed no speed advantage.

The release retains the existing SDR filter pipeline and reuses the native GPU context for HDR processing. A fully live SDR GPU pipeline needs matching color behavior and sustained-workload measurements before adoption. This small experiment does not characterize every filter, resolution, or steady playback workload.


Host memory is the test process's cumulative peak resident size, not the simultaneous memory use of Trimato and its child processes. Child peak resident size is reported separately and must not be added to the host peak as a simultaneous total. The final benchmark also includes an additional GPU prototype, so its full-process peak is not directly comparable to the original workload's peak.

## Checks

The final optimized Release run passed 49 tests with zero failures. The separate isolated benchmark passed one test. The background Swift package passed 36 tests in 10 suites. The headless output-safety harness also passed, including cancellation before destination replacement, selected-range exports, mixed audio, H.264, HEVC, ProRes, HDR filtering, and Spatial Audio preservation with an unchanged source checksum.

Both arm64 and x86_64 app/tool slices compiled. Each FFmpeg executable has matching architecture UUIDs in its rebuilt dSYM. Runtime tests were on arm64.

The focused Xcode suites cover binary search boundaries, variable-rate frame timing, deletion joins, source envelopes, transitions, native audio and video export, late excerpts compared with decode-from-start output, shared cancellation, cache cleanup and invalidation, bounded import, and existing filter behavior. The separate Swift package covers file preservation, audio mixing, scheduling, and worker cancellation.

These are background checks with generated media. They do not establish physical VoiceOver behavior, interactive playback smoothness, Intel runtime performance, real disk exhaustion, removable-drive disconnection recovery, or distribution signing readiness. Those remain separate release checks.

## Repeat the benchmark

Run the performance suite on its own after other builds and tests finish:

```sh
xcodebuild -project Trimato/Trimato.xcodeproj -scheme Trimato \
  -configuration Release ENABLE_TESTABILITY=YES \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:TrimatoTests/FasterPerformanceTests test
```

The test records a JSON attachment named trimato-performance.json in its Xcode result bundle. ENABLE_TESTABILITY applies to this test command; ordinary Release builds and archives retain the project's normal settings.

Run the background package checks separately:

```sh
swift test --scratch-path /tmp/trimato-faster-package
```

## Platform references

[Read Apple's guidance for writer readiness callbacks.](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/requestmediadatawhenready(on:using:))

[Read Apple's guidance for finishing writer inputs.](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/markasfinished())

[Read Apple's description of original-format sample output.](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput/outputsettings)

[Read FFmpeg's seeking options.](https://ffmpeg.org/ffmpeg.html)
