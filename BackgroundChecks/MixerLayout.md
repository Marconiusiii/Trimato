# Mixer layout measurement

Run `zsh BackgroundChecks/check-mixer-layout.sh <Debug-products-directory> --bounded` after a `build-for-testing` build. This links the built implementation into a separate background process. It creates an unshown window with prohibited application activation; it never launches Trimato, posts input events, or shows screenshots.

The check hosts the actual Mixer view, advances its clock, changes Pan 80 times, drains scheduled updates, and forces host layout. It also checks small, large, and restored viewport sizes. The timing includes a one-millisecond scheduling yield. The sample project has no media; this isolates layout work, not AVPlayer decoding or real VoiceOver navigation. Use the separate muted playback and stress checks for transport and mix persistence.

On September 23, 2026, the existing layout measured median 30.35 ms, p95 37.15 ms, maximum 64.25 ms. Native external slider labels plus bounded host sizing measured median 7.74 ms, p95 8.89 ms, maximum 12.98 ms on the same machine. These are local comparisons, not universal timing thresholds.

The original user capture showed substantial main-thread SwiftUI measurement work, including window sizing and slider mark-label placement, with two microhangs of 350 and 382 ms. The background benchmark does not prove that those user-observed hangs are fixed.

If the hidden host exposes an accessibility tree, the check validates Pan's native slider role, label, and increment/decrement precision. On the current macOS build it does not expose that tree, so the check explicitly reports accessibility as unverified. Confirm spoken slider labels, values, adjustment precision, and navigation during actual playback with VoiceOver before considering usability resolved.
