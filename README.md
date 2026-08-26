# Trimato

Trimato is an accessibility-first, keyboard-driven lightweight video editor for macOS. Its focused clip editor remains the primary place to mark, trim, and remove sections. Edited source clips can then be arranged non-destructively in a saved Trimato project and exported as a finished video or audio file.

Created by Marco Salsiccia.

## Release status

Trimato 1.0.0 is a TestFlight-only beta of the focused clip editor and will not be released to the production App Store. The current source expands Trimato into a complete project editor and is being prepared as the first production App Store release.

## Features

- Create and save `.trimato` project packages with automatic or custom dimensions and frame rate.
- Organize imported media in project folders without moving the original files in Finder.
- Open a source clip, timeline clip, or cutaway in Trimato's focused clip editor.
- Arrange clips in a magnetic primary storyline with no empty gaps.
- Append clips, insert and split at the playhead, or replace the remainder of the clip at the playhead.
- Add a single-layer cutaway that temporarily replaces the picture, either with its source audio or while retaining the primary storyline audio.
- Split, rename, delete, and reorder timeline clips while preserving non-destructive source ranges. Repeated names receive stable A, B, and later suffixes across primary clips and cutaways.
- Preview and export the complete arranged project as H.264 or HEVC MP4, H.264 or HEVC QuickTime, ProRes 422 LT, ProRes 422, ProRes 422 HQ, M4A AAC, M4A Apple Lossless, FLAC, 16-bit WAV, or 24-bit WAV.
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

### Project editing

- Command-Shift-I: Import media into the current project.
- Command-E: Export the current project when the project workspace is active.
- Command-B: Split the selected timeline clip at the project playhead.
- Option-Command-Left Arrow: Move the selected timeline clip earlier.
- Option-Command-Right Arrow: Move the selected timeline clip later.

Media can also be dragged from Finder into the Project Browser. The Project Timeline and Project Browser provide native buttons for every operation, including moving a clip directly to the beginning or end.

Editor shortcuts remain available while focus is on any editor control. Native import, open, save, and export panels retain their own keyboard behavior.

## Editing model

Trimato uses a non-destructive edit timeline. Deleting or trimming media changes the in-memory playback composition, not the original file.

In and Out are general selection markers:

- Delete removes the selected section.
- Export Clip exports the selection when both markers are set.
- Export Clip exports the complete edited timeline when both markers are clear.
- An incomplete or reversed selection must be corrected or cleared before export.

After a clip-editor deletion, the playhead moves to the new edit point and the markers are cleared. In a Trimato project, the resulting source ranges are saved with the media or timeline clip. Project changes participate in the standard Undo and Redo commands.

The project timeline is a magnetic primary storyline. Insert at Playhead splits the clip under the playhead and preserves both sides. Replace Clip Remainder preserves the portion before the playhead, discards that clip's remaining portion, and leaves later clips in place. A cutaway changes neither the primary clip nor the total project duration; it temporarily takes over the picture and either takes over the audio or leaves the primary audio playing.

Every primary clip and cutaway has a distinct displayed timeline name. Repeated filenames and additional uses of the same source receive stable letter suffixes. Choose Rename Clip from the item's context menu or Selected Clip Actions to give an instance a unique custom name. Timeline renames are saved in the project and participate in Undo and Redo.

## Export formats

Video exports include H.264 MP4, HEVC MP4, H.264 QuickTime, HEVC QuickTime, ProRes 422 LT, ProRes 422, and ProRes 422 HQ. Audio-only exports include M4A AAC, M4A Apple Lossless, FLAC, 16-bit WAV, and 24-bit WAV. Audio-only choices are available when the edited clip or project contains exportable audio.

## Mixed media and project format

Each project has one resolution and frame rate. Automatic from First Clip uses the first clip placed on the primary timeline, not the first file imported into the Project Browser. A project created directly from a standalone clip uses that clip's displayed dimensions and nominal frame rate. Later clips retain their own source properties while Trimato conforms them to the project during preview and export.

Trimato uses proportional Fit for source dimensions and orientation. The complete source image remains visible and its aspect ratio is preserved:

- A vertical or narrower source in a landscape project is centered and pillarboxed with black space on the left and right.
- A source wider than the project frame is centered and letterboxed with black space above and below.
- A source with the same aspect ratio is scaled proportionally to the project frame.
- Trimato does not stretch, automatically crop, or rotate a source merely to fill the frame.

Fit can scale a lower-resolution source up until one dimension reaches the project boundary, but it never enlarges the source past that boundary to eliminate letterboxing or pillarboxing. Fill, manual crop, positioning, and background controls are not currently part of the project timeline.

The project frame rate establishes a fixed output cadence. Frames from higher-rate sources are omitted as needed, and frames from lower-rate sources are repeated as needed. This conversion does not change clip speed or audio duration. Trimato does not currently use optical flow to synthesize intermediate frames, so conversions such as 24 fps to 30 fps can retain visible motion judder.

Custom projects provide common landscape, vertical, square, and portrait resolution presets, plus standard frame rates from 23.976 through 120 fps. Choose Custom dimensions or Custom frame rate when a preset does not match the intended output. Custom dimensions accept even width and height values from 2 through 8,192 pixels, and custom frame rates accept values from 1 through 240 fps.

When entering custom dimensions, Lock aspect ratio is on initially. Changing either dimension calculates the other from the locked ratio and rounds the calculated value to an even pixel count. Turn the checkbox off to set width and height independently, including unconventional project frames. Turning it back on locks the dimensions at their current ratio. The Inspector identifies proportional fitting and frame-rate conversion when a selected source differs from the project.

## Supported media

When AVFoundation can play and export a source natively, Trimato uses passthrough export to retain the source file type and codec. This commonly includes QuickTime Movie, MP4, and M4V sources whose internal codecs are supported by macOS.

When native playback is unavailable, Trimato can use its bundled FFmpeg and ffprobe tools to inspect a local source and create a temporary playback proxy. Converted exports are written as MP4. The bundled tools have networking, encrypted-stream protocols, and HLS support disabled; they can access only local files and local process pipes. Explicitly registered fallback extensions include:

- MKV
- WebM
- TS, MTS, and M2TS
- VOB
- WMV
- FLV

Format recognition does not guarantee that every possible codec or media feature inside a container can be edited. Trimato currently rejects HDR and alpha-channel sources when a safe MP4 conversion would not preserve those properties.

## Accessibility

Accessibility is part of Trimato's editing model rather than an additional mode.

- The complete editor can be operated from the keyboard.
- Native SwiftUI controls retain their standard VoiceOver roles and interactions.
- Visible section headings include VoiceOver heading traits.
- The Project Browser, Clip Editor, Project Timeline, and Clip Inspector are labeled sections in structural source order. Linked browser-editor and timeline-inspector regions support VoiceOver's linked-item navigation.
- Timeline list items expose names and positions without continuously speaking start, end, and duration values. Exact timing remains available on demand in the inspector.
- Timecode updates do not continuously interrupt VoiceOver speech.
- Import preparation appears in a native modal sheet so the inactive editor does not remain in the active VoiceOver context.
- Import and export operations provide status, progress, cancellation, and restrained spoken announcements.
- In, Out, navigation, editing, completion, and failure actions provide spoken feedback.
- The interface uses a dark charcoal editor workspace with high-contrast text and teal accents.
- Color is not the only indication of marker, progress, selection, or disabled states.

Accessibility reports from VoiceOver and other assistive technology users are especially welcome.

## Requirements

- macOS Sonoma 14.0 or later
- An Apple silicon Mac or an Intel Mac supported by macOS Sonoma
- Xcode with support for the project's macOS deployment target when building from source

The Trimato application and its bundled FFmpeg and ffprobe executables are built for both Apple silicon and Intel. Release builds are checked for both architectures; hands-on Intel validation depends on beta testers with Intel hardware.

## Installing a local build

From the repository root, run:

```sh
cd Trimato
./install-local.sh
```

The installer creates a Release build, places `Trimato.app` in `/Applications`, and refreshes Launch Services so Trimato can appear in Finder's Open With menu. Quit an existing copy of Trimato before running the installer.

To make Trimato the default editor for a particular video type, select a file of that type in Finder, press Command-I, choose Trimato from Open with, and activate Change All.

## Building from source

1. Clone or download this repository.
2. Open `Trimato/Trimato.xcodeproj` in Xcode.
3. Select the `Trimato` scheme and My Mac as the destination.
4. Build and run with Command-R.

For a command-line Release build from the repository root:

```sh
xcodebuild \
  -project Trimato/Trimato.xcodeproj \
  -scheme Trimato \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

Run the test suite with:

```sh
xcodebuild \
  -project Trimato/Trimato.xcodeproj \
  -scheme Trimato \
  -destination 'platform=macOS' \
  -only-testing:TrimatoTests \
  test
```

## Project layout

- `Trimato/Trimato`: Application source, editor views, timeline model, media preparation, and export code.
- `Trimato/TrimatoTests`: Unit and integration tests.
- `Trimato/Trimato.xcodeproj`: Xcode project.
- `Trimato/ThirdParty/FFmpeg`: FFmpeg build instructions, configuration, source location, and LGPL license.
- `Trimato/install-local.sh`: Local Release installer for `/Applications`.

## Privacy and temporary files

Trimato has no accounts, advertising, analytics, or tracking. Video inspection, proxy creation, editing, and export happen locally on the Mac.

The original source file is not modified. A format that macOS cannot play directly may receive a temporary MP4 playback proxy under the user's Caches directory. Trimato removes that proxy when the media is replaced, the import is canceled, or the editor window closes normally. An abnormal process termination can prevent normal cleanup code from running.

Opening the FFmpeg website from the About window leaves the app and uses the selected web browser, whose privacy policy then applies.

## Support and feedback

Bug reports, accessibility findings, and focused improvements are welcome. Include the macOS version, Trimato version, source format, assistive technology, and clear reproduction steps when reporting a problem.

- [Open a GitHub issue.](../../issues)
- [Email Marco Salsiccia.](mailto:marco@marconius.com)

## Third-party software

Trimato bundles FFmpeg 8.1.2 and ffprobe for media inspection, proxy generation, and MP4 conversion. Those tools are distributed under the GNU Lesser General Public License version 2.1 or later and are not relicensed under MIT.

- [Read the FFmpeg distribution and build notes.](Trimato/ThirdParty/FFmpeg/README.md)
- [Read the bundled GNU Lesser General Public License.](Trimato/ThirdParty/FFmpeg/COPYING.LGPLv2.1)
- [Visit the FFmpeg website.](https://ffmpeg.org/)

## License

Marco Salsiccia's original Trimato source code is available under the [MIT License.](LICENSE)

Bundled third-party components remain subject to their respective licenses.
