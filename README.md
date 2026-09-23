# Trimato

Trimato is an accessibility-first audio and video editor for macOS, designed for keyboard and VoiceOver use. Trim clips, arrange a project, write captions, record narration and audio description, mix sound, and export your finished work.

Created by Marco Salsiccia.

## Features

- Edit standalone audio and video clips or arrange multiple tracks in a saved `.trimato` project.
- Mark ranges, split and trim clips, and make non-destructive edits that preserve the original media.
- Work with portrait or landscape video, step through individual frames, and edit audio with optional static waveforms.
- Write and time captions with Captioner, import SRT and WebVTT files, and export captions as separate files or include them in the video.
- Record audio description with Describer and narration with Voicer. Adjust voice levels, match loudness, and reduce other audio during descriptions.
- Use Captioner, Describer, and Voicer beside the main video preview. Mix audio live and loop an In–Out range in a separate Mixer window.
- Mix audio tracks with volume, mute, solo, pan, stereo balance, stereo width, and channel routing controls.
- Add transitions, video and audio filters, titles, lower thirds, backgrounds, and other generated clips.
- Tap out absolute markers during playback, edit their titles, and mark chapter boundaries.
- Export a full-resolution PNG from the playhead, or export web video with a poster, optional captions, and an HTML embed fragment.
- Export video in H.264, HEVC, or ProRes, and audio in AAC, Apple Lossless, FLAC, or WAV. Preserve HDR and compatible iPhone Spatial Audio in supported exports.

## Requirements

- macOS Sonoma 14 or later.
- An Apple silicon or Intel Mac.
- Xcode to build the app from source.

## Getting started

Choose Trim a Clip on the welcome screen to edit a single file, New Project to arrange media, or Open Project to continue saved work.

In a project, use Project Source to organize media, Editor to preview it, and Timeline to arrange clips. Open Captioner, Describer, Voicer, or Mixer as needed. Choose Settings to configure recording devices, playback, timecode, and storage preferences. Choose Numeric, Time units, or Frames for timeline timecodes. Show milliseconds controls fractional seconds in displayed and spoken times. On Demand keeps timeline playhead time silent until you press T.

For editing instructions and keyboard shortcuts, open the Trimato Manual from the app's Help menu. Help buttons open the topic for the current tool or Settings page.

- [Browse the Manual source.](Trimato/Trimato/Trimato.help/Contents/Resources/en.lproj/index.html)
- [Read the keyboard shortcut reference.](Trimato/Trimato/Trimato.help/Contents/Resources/en.lproj/keyboard-shortcuts.html)

## Building from source

1. Clone or download this repository.
2. Open `Trimato/Trimato.xcodeproj` in Xcode.
3. Select the `Trimato` scheme and My Mac as the destination.
4. Configure signing for your development team if needed.
5. Build and run with Command-R.

To create a Release build from the repository root:

```sh
xcodebuild \
  -project Trimato/Trimato.xcodeproj \
  -scheme Trimato \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

To install a local Release build, quit Trimato and run:

```sh
./Trimato/install-local.sh
```

The installer replaces `/Applications/Trimato.app` with the new build and registers it for Finder's Open With menu.

## Testing

Run the app test suite from the repository root:

```sh
xcodebuild \
  -project Trimato/Trimato.xcodeproj \
  -scheme Trimato \
  -destination 'platform=macOS' \
  -only-testing:TrimatoTests \
  test
```

Run the background media and file-handling tests without launching the app:

```sh
swift test --scratch-path /tmp/trimato-media-tests
```

## Repository layout

- `Trimato/Trimato`: App source and bundled Manual.
- `Trimato/TrimatoTests`: App tests.
- `BackgroundTests`: Background media and file-handling tests.
- `Trimato/Trimato.xcodeproj`: Xcode project.
- `Trimato/ThirdParty/FFmpeg`: Bundled FFmpeg tools, build notes, and license.
- `Trimato/install-local.sh`: Local build installer.

## Privacy

Editing and media processing happen locally on your Mac. Trimato has no accounts, advertising, analytics, or tracking.

## Support and contributions

Bug reports, accessibility feedback, and contributions are welcome. For a bug report, include the Trimato version, macOS version, media format, steps to reproduce the problem, and any assistive technology involved.

- [Open a GitHub issue.](https://github.com/Marconiusiii/Trimato/issues)
- [Email Marco Salsiccia.](mailto:marco@marconius.com)

## License and third-party software

Trimato's original source code is available under the [MIT License.](LICENSE)

The bundled FFmpeg and ffprobe tools are licensed separately under the GNU Lesser General Public License version 2.1 or later.

- [Read the FFmpeg distribution and build notes.](Trimato/ThirdParty/FFmpeg/README.md)
- [Read the bundled LGPL license.](Trimato/ThirdParty/FFmpeg/COPYING.LGPLv2.1)
