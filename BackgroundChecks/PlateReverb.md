# Plate Reverb verification

Plate Reverb uses an independently written static digital plate response: input diffusion, two cross-coupled allpass tanks, high-frequency damping, and an explicit decay envelope. This is an algorithmic plate treatment, not a sampled physical plate or a claim to reproduce a particular hardware unit.

The response is generated inside the concurrent clip-rendering path. FFmpeg convolves each input channel with the mono response, retaining the source channel count and separation. The prepared result serves playback and export. Amount crossfades dry and wet audio. Responses are temporary per render and removed on completion or failure; generation checks cancellation throughout. Existing room reverb keeps its previous settings and implementation.

Design references:

- [Dattorro topology documentation.](https://faustlibraries.grame.fr/libs/reverbs/#dattorro-reverb)
- [FFmpeg convolution filter.](https://ffmpeg.org/ffmpeg-filters.html#afir)

## Run the background checks

After building the Debug app and test targets without launching them:

```sh
zsh BackgroundChecks/check-plate-reverb.sh /private/tmp/trimato-marker-investigation/Build/Products/Debug
```

The check generates silent or synthetic fixtures and never launches NSApplication or plays audio. It checks:

- Finite, deterministic, normalized responses at 44.1, 48, 96, and 192 kHz.
- Length and Brightness effects on decay and spectral energy.
- Invalid parameter rejection and old/new filter serialization.
- Mono and stereo rendering, channel separation, and exact duration.
- Zero Amount and bypass against decoded source samples.
- Increasing Amount against measured tail energy.
- Saved-project restoration and preview/final-export sample agreement.
- Selected-range rendering with pre-cut effect history.
- Combined room reverb, Plate Reverb, and Echo rendering.
- Cancellation and temporary-response cleanup.

These checks establish rendering and persistence behavior. They do not establish perceived sound quality or physical VoiceOver usability. Those remain listening and interaction checks in the app.
