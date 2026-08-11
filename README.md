# vidTime

vidTime is an accessibility-first, keyboard-driven clip editor for macOS. It is designed for quickly reviewing video, moving frame by frame, marking selections, removing unwanted sections, and exporting an edited clip without modifying the original file.

Created by Marco Salsiccia.

## Features

- Open videos from the File menu, Finder, drag and drop, or Command-O.
- Play, pause, seek, and move forward or backward one frame at a time.
- Display the playhead as timecode or a frame number.
- Copy the current `hh:mm:ss.mmm` timecode as plain text.
- Mark reusable In and Out points on the edited timeline.
- Delete a selected section from the middle of a clip and immediately preview the joined result.
- Trim everything before or after the playhead with keyboard commands.
- Make repeated, non-destructive edits, including cuts that cross an earlier edit point.
- Jump among the start, In marker, Out marker, and end of the current edit.
- Export the complete edited clip or only the current In-to-Out selection.
- Preserve the source container and codec when native passthrough is available.
- Convert unsupported playback formats to an MP4 export using the bundled FFmpeg tools.
- Open common video formats through Finder after installing the app in Applications.

## Keyboard controls

### Playback and navigation

- Space: Play or pause.
- Left Arrow: Move backward one frame.
- Right Arrow: Move forward one frame.
- Hold Left Arrow: Play continuously in reverse until released.
- Hold Right Arrow: Play continuously forward until released.
- J: Play in reverse. Press repeatedly to increase reverse speed.
- K: Play or pause.
- L: Play forward. Press repeatedly to increase forward speed.
- Command-Left Arrow: Move to the previous timeline point.
- Command-Right Arrow: Move to the next timeline point.
- Command-Up Arrow: Move to the start of the edited clip.
- Command-Down Arrow: Move to the end of the edited clip.

### Marking and editing

- I: Set or replace the In marker at the playhead.
- O: Set or replace the Out marker at the playhead.
- Delete or Forward Delete: Remove the current In-to-Out selection and join the surrounding media.
- Command-[: Trim everything from the start of the clip to the playhead.
- Command-]: Trim everything from the playhead to the end of the clip.

### Files and timecode

- C: Copy the current timecode as plain text.
- Command-O: Open a video.
- Command-E: Export the edited clip or current selection.

Editor shortcuts remain available while focus is on any editor control. Native import, open, save, and export panels retain their own keyboard behavior.

## Editing model

vidTime uses a non-destructive edit timeline. Deleting or trimming media changes the in-memory playback composition, not the original file.

In and Out are general selection markers:

- Delete removes the selected section.
- Export Clip exports the selection when both markers are set.
- Export Clip exports the complete edited timeline when both markers are clear.
- An incomplete or reversed selection must be corrected or cleared before export.

After a deletion, the playhead moves to the new edit point and the markers are cleared. Reopening the source file resets the current in-memory edits. Undo and Redo are not currently available.

## Supported media

When AVFoundation can play and export a source natively, vidTime uses passthrough export to retain the source file type and codec. This commonly includes QuickTime Movie, MP4, and M4V sources whose internal codecs are supported by macOS.

When native playback is unavailable, vidTime can use its bundled FFmpeg and ffprobe tools to inspect the source and create a temporary playback proxy. Converted exports are written as MP4. Explicitly registered fallback extensions include:

- MKV
- WebM
- TS, MTS, and M2TS
- VOB
- WMV
- FLV

Format recognition does not guarantee that every possible codec or media feature inside a container can be edited. vidTime currently rejects HDR and alpha-channel sources when a safe MP4 conversion would not preserve those properties.

## Accessibility

Accessibility is part of vidTime's editing model rather than an additional mode.

- The complete editor can be operated from the keyboard.
- Native SwiftUI controls retain their standard VoiceOver roles and interactions.
- Visible section headings include VoiceOver heading traits.
- Timecode updates do not continuously interrupt VoiceOver speech.
- Import preparation appears in a native modal sheet so the inactive editor does not remain in the active VoiceOver context.
- Import and export operations provide status, progress, cancellation, and restrained spoken announcements.
- In, Out, navigation, editing, completion, and failure actions provide spoken feedback.
- The interface uses a dark charcoal editor workspace with high-contrast text and teal accents.
- Color is not the only indication of marker, progress, selection, or disabled states.

Accessibility reports from VoiceOver and other assistive technology users are especially welcome.

## Requirements

- macOS 26.4 or later
- A Mac supported by that macOS release
- Xcode with support for the project's macOS deployment target when building from source

The bundled FFmpeg and ffprobe executables contain Apple silicon and Intel slices.

## Installing a local build

From the repository root, run:

```sh
cd VidTime
./install-local.sh
```

The installer creates a Release build, places `vidTime.app` in `/Applications`, and refreshes Launch Services so vidTime can appear in Finder's Open With menu. Quit an existing copy of vidTime before running the installer.

To make vidTime the default editor for a particular video type, select a file of that type in Finder, press Command-I, choose vidTime from Open with, and activate Change All.

## Building from source

1. Clone or download this repository.
2. Open `VidTime/VidTime.xcodeproj` in Xcode.
3. Select the `VidTime` scheme and My Mac as the destination.
4. Build and run with Command-R.

For a command-line Release build from the repository root:

```sh
xcodebuild \
  -project VidTime/VidTime.xcodeproj \
  -scheme VidTime \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

Run the test suite with:

```sh
xcodebuild \
  -project VidTime/VidTime.xcodeproj \
  -scheme VidTime \
  -destination 'platform=macOS' \
  -only-testing:VidTimeTests \
  test
```

## Project layout

- `VidTime/VidTime`: Application source, editor views, timeline model, media preparation, and export code.
- `VidTime/VidTimeTests`: Unit and integration tests.
- `VidTime/VidTime.xcodeproj`: Xcode project.
- `VidTime/ThirdParty/FFmpeg`: FFmpeg build instructions, configuration, source location, and LGPL license.
- `VidTime/install-local.sh`: Local Release installer for `/Applications`.

## Privacy and temporary files

vidTime has no accounts, advertising, analytics, or tracking. Video inspection, proxy creation, editing, and export happen locally on the Mac.

The original source file is not modified. A format that macOS cannot play directly may receive a temporary MP4 playback proxy under the user's Caches directory. vidTime removes that proxy when the media is replaced, the import is canceled, or the editor window closes normally. An abnormal process termination can prevent normal cleanup code from running.

Opening the FFmpeg website from the About window leaves the app and uses the selected web browser, whose privacy policy then applies.

## Support and feedback

Bug reports, accessibility findings, and focused improvements are welcome. Include the macOS version, vidTime version, source format, assistive technology, and clear reproduction steps when reporting a problem.

- [Open a GitHub issue.](../../issues)
- [Email Marco Salsiccia.](mailto:marco@marconius.com)

## Third-party software

vidTime bundles FFmpeg 8.1.2 and ffprobe for media inspection, proxy generation, and MP4 conversion. Those tools are distributed under the GNU Lesser General Public License version 2.1 or later and are not relicensed under MIT.

- [Read the FFmpeg distribution and build notes.](VidTime/ThirdParty/FFmpeg/README.md)
- [Read the bundled GNU Lesser General Public License.](VidTime/ThirdParty/FFmpeg/COPYING.LGPLv2.1)
- [Visit the FFmpeg website.](https://ffmpeg.org/)

## License

Marco Salsiccia's original vidTime source code is available under the [MIT License.](LICENSE)

Bundled third-party components remain subject to their respective licenses.
