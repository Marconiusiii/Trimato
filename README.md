# Trimato

Trimato is an accessibility-first, keyboard-driven lightweight audio and video editor for macOS. Its focused clip editor remains the primary place to mark, trim, and remove sections. Edited source clips can then be arranged non-destructively in a saved Trimato project and exported as a finished video or audio file.

Created by Marco Salsiccia.

## Release status

Trimato 1.0.0 was the TestFlight-only beta of the focused clip editor and will not be released to the production App Store. Trimato 1.2.0 build 8 is the first TestFlight build of the complete project editor and is the candidate for Trimato's first production App Store release.

## Features

- Create and save `.trimato` project packages with automatic or custom dimensions and frame rate.
- Organize imported media in project folders without moving the original files in Finder.
- Activate Trim a Clip on the welcome screen to choose an audio or video file and open the standalone Clip Editor without creating a project first, then create a project from the current edit when ready.
- Edit audio-only sources against a static waveform with a visible playhead, using the same playback, marker, trimming, timeline, and project tools as video.
- Open a source clip, timeline clip, or cutaway in Trimato's focused clip editor.
- Arrange clips on independent video and audio tracks, using one linear Timeline clips list for the track selected in the Track picker. Primary tracks retain magnetic editing, while additional tracks also support absolute positioning and gaps.
- Append clips, insert and split at the playhead, or replace the remainder of the clip at the playhead.
- Add a single-layer cutaway that temporarily replaces the picture, either with its source audio or while retaining the primary storyline audio.
- Send only the audio from an imported video clip to an existing or newly named audio track, using the complete source edit or its marked In and Out range.
- Split, rename, delete, and reorder timeline clips while preserving non-destructive source ranges. Repeated names receive stable A, B, and later suffixes across primary clips and cutaways.
- Pick up a Timeline clip with Space, choose its position with arrow keys, and drop it with Space as one undoable move. On additional tracks, plain arrows also nudge the focused clip one project frame without pickup and without overlapping neighboring clips.
- Add, edit, and remove video fades, cross dissolves, directional wipes, audio fades, and cross fades as independent timeline elements.
- Create saved Black, Solid Color, Static Gradient, Silence, and Text generators from a native Generator window.
- Apply curated video and audio filters to individual timeline clips, with editable parameters, bypass, reset, and removal. Basic audio gain remains separate.
- Reach the displayed Video frame as a VoiceOver image above the Editor playhead slider.
- Mute audio tracks for both preview and export without removing their clips or changing their timing.
- Preview and export the complete arranged project as H.264 or HEVC MP4, H.264 or HEVC QuickTime, ProRes 422 LT, ProRes 422, ProRes 422 HQ, M4A AAC, M4A Apple Lossless, FLAC, 16-bit WAV, or 24-bit WAV.
- Open audio and video files from the File menu, Finder, drag and drop, or Command-O.
- Play, pause, seek, and move forward or backward one frame at a time.
- Display the playhead as timecode or a frame number.
- Mark reusable In and Out points on the edited timeline.
- Delete a selected section from the middle of a clip and immediately preview the joined result.
- Trim everything before or after the playhead with keyboard commands.
- Make repeated, non-destructive edits, including cuts that cross an earlier edit point.
- Jump among the start, In marker, Out marker, and end of the current edit.
- Export the complete edited clip or only the current In-to-Out selection.
- Preserve the source container and codec when native passthrough is available.
- Convert unsupported playback formats to a local playback proxy using the bundled FFmpeg tools.
- Open common audio and video formats through Finder after installing the app in Applications.

## Keyboard controls

### Playback and navigation

These commands apply while focus is in Editor or Clip Editor. Timeline Clips uses Space and plain arrows for clip movement, as described below.

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

### Clip Editor marking and editing

- I: Set or replace the In marker at the playhead.
- O: Set or replace the Out marker at the playhead.
- Delete or Forward Delete: Remove the current In-to-Out selection and join the surrounding media.
- Command-[: Trim everything from the start of the clip to the playhead.
- Command-]: Trim everything from the playhead to the end of the clip.

### Files

- Command-O: Open an audio or video file.
- Command-R: Create a project from the current standalone clip edit.
- Command-E: Export the edited clip or current selection.

### Project editing

- Command-Shift-I: Import media into the current project.
- Command-E: Export the current project when the project workspace is active.
- Command-B: Split the primary timeline clip beneath the project playhead; Timeline focus or movement selection is not required.
- Command-T: Open Add Transition for the clip at the Editor playhead or the focused Timeline clips item.
- Command-[: While focus is in Editor, trim the start of the active track's announced clip to the shared project playhead.
- Command-]: While focus is in Editor, trim the end of the active track's announced clip to the shared project playhead. When a Timeline clip is focused, trim that focused clip's end instead.
- [: While focus is in Editor, move an additional-track clip so its head begins at the shared project playhead without trimming its stored source.
- ]: While focus is in Editor, move an additional-track clip so its tail ends at the shared project playhead without trimming its stored source.
- C: Open Clip Editor for the active-track clip at or immediately after the Editor playhead.
- Command-C: Copy the focused Timeline clip.
- Command-V: Paste a copy immediately after the focused Timeline clip.
- Command-Option-V: Move the picked-up Timeline clip, or the copied clip when none is picked up, immediately after the focused Timeline clip.
- Control-Enter: Open Selected Element Actions for the focused Timeline clips item.
- Option-Command-Up Arrow: Select the previous timeline track and announce its direct-edit clip.
- Option-Command-Down Arrow: Select the next timeline track and announce its direct-edit clip.
- Option-Command-Left Arrow: Move the focused clip one position earlier on a primary track, or nudge it one frame earlier on an additional track. If a clip is picked up, adjust that clip instead.
- Option-Command-Right Arrow: Move the focused clip one position later on a primary track, or nudge it one frame later on an additional track. If a clip is picked up, adjust that clip instead.
- Command-G: Open Generator from the project Editor.
- F: Open Quick Fade at the Editor playhead.
- X: Open Quick Cross Dissolve or Quick Cross Fade for the edit at the Editor playhead.

### Timeline clip movement

- Space: Pick up the focused clip for movement, or drop the picked-up clip.
- Enter or Return: Open the focused clip in Clip Editor, matching normal button activation.
- Left Arrow or Up Arrow: On primary tracks, move the picked-up clip one list position earlier. On additional tracks, nudge the focused or picked-up clip one project frame earlier.
- Right Arrow or Down Arrow: On primary tracks, move the picked-up clip one list position later. On additional tracks, nudge the focused or picked-up clip one project frame later.
- Escape: Drop the picked-up clip at its proposed position.
- Command-Z: Undo an immediate nudge or the complete pickup-and-drop move.
- VO-Command-Shift-Space: Hold the mouse button on a clip, use arrows to adjust its position, then repeat the command to release and drop it.

Additional-track nudges do not require Space first. With VoiceOver, use ordinary VO-Arrow navigation to review clips; those navigation commands do not move clips. If Quick Nav is handling plain arrows, turn it off for nudging or use the Timeline menu's Move Clip Earlier and Move Clip Later commands.

The clip context menu provides a movement-selection toggle and one Move To… submenu with Start, Before, After, and End. Pick up a source clip, focus a destination, and choose Before or After. Start and End use the active track and also work directly on the focused clip without pickup. The redundant Move Earlier and Move Later context-menu items have been removed.

Media can also be dragged from Finder into the Project Browser. Native menus provide placement, movement, and editing commands.

Editor shortcuts remain available while focus is on any editor control. Native import, open, save, and export panels retain their own keyboard behavior.

## Generators and clip filters

With a project open, choose Timeline > Generator or press Command-G. The Generator window captures the project playhead and pauses Editor playback. Choose Black, Solid Color, Static Gradient, Silence, or Text; set the relevant parameters and duration in seconds or whole project frames. Video generators use the project format, or 1920 by 1080 at 30 frames per second when it has not been resolved. Silence supports mono or stereo.

Choose a compatible Destination Track or New Track and a name. The window opens at the Generator heading. Review the generated clip in the Editor after placement. Cancel Preparation stops processing and closes the Generator without changing the project. Append, Insert and Split, and Insert and Overwrite use the captured playhead where applicable. Insert on Top in New Video Track creates an additional video track at that position. Insert and Split advances the project playhead to the new clip's end. Preparation must finish before the project changes; adding the source, track when needed, and clip is one Undo operation.

Generator definitions are saved in the project. Their playback files are internal cache files and can be regenerated without relinking an external source. Open a generated timeline clip in Clip Editor and choose Edit Generator to change its settings or duration. Update any pending clip edits first. Updating a generator creates a separate source for that instance, leaving other copies unchanged.

Text provides Center Title, Title and Subtitle, Lower Third Center/Left/Right, Name and Role, Caption, and Subtitle templates. Enter text in the multiline editor; Return inserts a line break. Title and Subtitle and Name and Role provide a second text editor with smaller supporting text. Changing templates or choosing Reset Style preserves both text fields.

Expand Typography for System Sans, Rounded Sans, Serif, or Monospaced fonts; weight, alignment, Font Size in Pixels, and Additional Line Spacing in Pixels. Line spacing adds space between lines; zero adds no extra space. Changing font size preserves the entered line spacing. Expand Appearance for named or hexadecimal colors, a Black or Transparent full-frame background, outline, shadow, and a separate text backing panel with adjustable opacity. Expand Layout for screen position, safe margins, maximum text width, and horizontal or vertical offsets. One detailed group opens at a time. Layout percentages name their reference area. Saved styles still scale with the video resolution.

Check Text Fit reports the line count and whether text fits within the safe area. It also warns about small text and low contrast against a known opaque background. It does not assess contrast over changing footage. Overflow prevents placement with an explanation; text is not silently clipped or resized. Place transparent text on a video track above the footage to retain the underlying picture. The existing transitions apply, including separately timed fades in and out. Project exports contain the composed picture; this does not add a standalone transparent-video export format.

Caption and Subtitle are static appearance templates for individually timed text clips. They do not import subtitle files or transcribe audio. Text and styling remain editable in the saved generator definition. Text layout uses macOS fonts and native text rendering; generated media preserves alpha through the supported filters and transitions.

Open a timeline video or audio clip, then choose Add Filter. The Filters section appears only when at least one filter has been added, including disabled filters. Each filter has an Enable checkbox, relevant parameters, Reset, and Remove. Activate Update Clip to save the draft settings and edit together as one Undo operation. Other instances of the source are unaffected. Gain remains in the Audio group; existing EQ and frequency filtering appear as Tone.

| Video filters | Audio filters |
| --- | --- |
| Brightness and Contrast | Tone |
| Color Adjustment | Reduce Background Noise |
| Black and White | Even Out Volume |
| Sharpen | Match Loudness |
| Reduce Video Noise | |
| Crop and Orientation | |

Filters use a fixed processing order and the same processing path for playback and export. Preparing filtered media can take time, especially with long sources and video noise reduction. No animation, keyframes, or general compositing controls are included.

The Editor exposes its displayed picture as a Video frame image directly above the project playhead slider, with a project time and frame value. VoiceOver image-description commands remain macOS commands. The availability and quality of descriptions depend on macOS and require hands-on VoiceOver testing; focusing the image does not start playback or change the playhead.

## Editing model

Trimato uses a non-destructive edit timeline. Deleting or trimming media changes Trimato's saved source-range instructions and playback composition, not the original file.

In and Out are general selection markers:

- Delete removes the selected section.
- Export Clip exports the selection when both markers are set.
- Export Clip exports the complete edited timeline when both markers are clear.
- An incomplete or reversed selection must be corrected or cleared before export.

After a clip-editor deletion, the playhead moves to the new edit point and the markers are cleared. In a Trimato project, the resulting source ranges are saved with the media or timeline clip. Project changes participate in the standard Undo and Redo commands.

The primary video and audio tracks retain magnetic editing, so operations that remove time close the resulting space on that track. Additional tracks can also contain independently positioned clips and gaps for music, effects, and layered material. Clips on different tracks can begin and end independently. The Track picker chooses the video or audio track presented as a native chronological Timeline clips list, while the Editor playhead remains shared across the complete project. Timeline clips is for reviewing and arranging the project. Clip Editor changes a source edit, Transition Editor changes transition timing, and Editor provides project playback and direct playhead-based editing.

The protected primary video and audio tracks retain the standard placement commands. Insert and Split splits the clip under the playhead and preserves both sides. After insertion, the shared project playhead advances to the incoming clip's end, so consecutive insertions stay in the order they were made. Insert and Overwrite preserves the portion before the playhead, discards that clip's remaining portion, and leaves later clips after the inserted clip. User-created tracks can be added, renamed, reordered, and deleted independently. A cutaway requires a visual source. It changes neither the primary clip nor the total project duration; it temporarily takes over the picture and either takes over the audio or leaves the primary audio playing.

Current identifies the clip beneath the playhead on the displayed track. Selected identifies only a clip picked up for movement. VoiceOver focus updates the target for clip commands and Command-I Get Info without moving the playhead or picking up a clip. In a gap, no clip is marked Current, even though Editor's C command can open the next clip.

During pickup-and-drop movement, the live timeline stays unchanged until drop. Primary-track arrows announce the proposed list position; additional-track nudges announce the proposed start frame. Ordinary navigation does not announce list positions. An immediate nudge changes only the focused clip's time and any linked audio that moves with picture. Neighboring clips stay in place. Nudges cannot overlap or cross another clip on the same track, but edges may touch. A linked-track collision also blocks the move. Clips with attached transitions must have those transitions removed before nudging. A project without a defined frame rate uses 30 fps for nudges.

When a video source contains audio, open it in Clip Editor and use the native Audio Only menu to append its audio, insert its audio at the project playhead, or insert and overwrite on an audio track. Add Audio Only to Track lists only audio tracks and can create a named audio track in the same operation. New Track from Video and New Track from Audio are also available in Clip Editor and from a Project Source clip's Actions and context menus. Each command creates a named compatible track and appends the current source edit as one undoable operation; the audio command contributes no picture to preview or export.

Every primary clip and cutaway has a distinct displayed timeline name. Repeated filenames and additional uses of the same source receive stable letter suffixes. Choose Rename Clip from the item's context menu or Selected Element Actions to give an instance a unique custom name. Timeline renames are saved in the project and participate in Undo and Redo.

## Tracks and transitions

VoiceOver focus in Timeline clips identifies the target clip or transition for timeline commands and Command-I Get Info. It does not set the Current or Selected movement states. Change the Track picker, or press Option-Command-Up Arrow and Option-Command-Down Arrow, to move between tracks without turning the complete project into one long list. When track selection begins in Editor, Trimato announces the active track and its direct-edit clip without moving VoiceOver into Timeline.

The direct-edit clip is remembered separately for each track. When no clip has been remembered, Trimato resolves the clip at the Editor playhead, preferring an incoming clip at an edit point, then a clip containing the playhead, the next clip, or the last earlier clip. Command-[ and Command-] trim that clip to the shared project playhead while VoiceOver stays in Editor. Plain [ and ] reposition the complete clip on an additional track without trimming its stored source. Press C from Editor to open the direct-edit clip. Timeline clipboard commands operate only on the focused track item and require matching video or audio track types.

Press Command-T in the Editor to add a transition at the playhead, or press it on a focused Timeline clips item. For a Fade on one clip, the controls are Fade In {clip name} and Fade Out {clip name}. Both name that same clip. Video and audio fades use Fade In Duration and Fade Out Duration, entered in seconds. The durations are independent and retain their values when a checkbox is cleared and checked again.

Press F in the Editor to open Quick Fade. At a shared cut from clip A to clip B, Fade In B applies at the beginning of B and Fade Out A applies at the end of A. Selecting both places both fades around that cut. Within a clip, at the start of the timeline, or at its final endpoint, both controls name the same clip. Fade Audio includes the matching linked audio for each selected fade.

Press X at an edit between clips to open Quick Cross Dissolve on a video track or Quick Cross Fade on an audio track. Transition durations accept fractional seconds such as `1.25`.

- Fade In: Gradually reveals the clip. On additional video tracks, underlying video remains visible during the fade.
- Fade Out: Gradually hides the clip, revealing underlying video on additional tracks. Where no picture is underneath, the background is black.
- Audio Fade In: Gradually raises the clip audio from silence.
- Audio Fade Out: Gradually lowers the clip audio to silence.
- Cross Dissolve: Fades the incoming picture over the outgoing picture across their shared edit. Crossfade Audio blends both clips' audio at the same time.
- Cross Fade: Lowers the outgoing audio while raising the incoming audio across their shared edit.
- Fade Out/Fade In: Fades the outgoing video through black into the incoming video, or fades outgoing audio through silence into incoming audio, without overlapping the two sources.
- Wipe Left: Replaces the outgoing picture with the incoming picture using an edge that moves left.
- Wipe Right: Replaces the outgoing picture with the incoming picture using an edge that moves right.
- Wipe Up: Replaces the outgoing picture with the incoming picture using an edge that moves upward.
- Wipe Down: Replaces the outgoing picture with the incoming picture using an edge that moves downward.

Wipes affect video only. Crossfade Audio blends the outgoing and incoming audio during a Cross Dissolve. Fade Audio adds the matching fade behavior. A transition appears as its own Timeline clips element and can be reopened, changed, or deleted without changing the source edit.

## Export formats

To silence a track, choose an audio track in Timeline and turn on Mute Track. Repeat for each audio track to exclude from the mix. Muting applies to preview and export, including audio transitions, and does not hide picture or change clip timing. The setting is saved with the project and participates in Undo and Redo. It affects the whole track, not only the clip beneath the playhead.

Video exports include H.264 MP4, HEVC MP4, H.264 QuickTime, HEVC QuickTime, ProRes 422 LT, ProRes 422, and ProRes 422 HQ. Audio-only exports include M4A AAC, M4A Apple Lossless, FLAC, 16-bit WAV, and 24-bit WAV. Audio-only choices are available when the edited clip or project contains exportable audio.

An audio-only clip or project offers only audio output formats because it has no picture to encode. A mixed project offers both video and audio output formats. In an audio-only project, adding the first video clip establishes the automatic project resolution and frame rate.

## Mixed media and project format

Each project that contains video has one resolution and frame rate. Automatic from First Clip uses the first video clip placed on the primary timeline, not the first file imported into the Project Browser. An earlier audio-only timeline clip does not establish a visual format. A project created directly from a standalone video uses that clip's displayed dimensions and nominal frame rate; a project created from standalone audio remains automatic until video is added. Later clips retain their own source properties while Trimato conforms them to the project during preview and export.

Trimato uses proportional Fit for source dimensions and orientation. The complete source image remains visible and its aspect ratio is preserved:

- A vertical or narrower source in a landscape project is centered and pillarboxed with black space on the left and right.
- A source wider than the project frame is centered and letterboxed with black space above and below.
- A source with the same aspect ratio is scaled proportionally to the project frame.
- Trimato does not stretch, automatically crop, or rotate a source merely to fill the frame.

Fit can scale a lower-resolution source up until one dimension reaches the project boundary, but it never enlarges the source past that boundary to eliminate letterboxing or pillarboxing. Fill, manual crop, positioning, and background controls are not currently part of the project timeline.

The project frame rate establishes a fixed output cadence. Frames from higher-rate sources are omitted as needed, and frames from lower-rate sources are repeated as needed. This conversion does not change clip speed or audio duration. Trimato does not currently use optical flow to synthesize intermediate frames, so conversions such as 24 fps to 30 fps can retain visible motion judder.

Audio-only timeline sections display as black picture in a video project while their audio continues normally. A visual cutaway can supply picture over an audio-only primary clip. Insert on Top is unavailable for an audio-only source because a cutaway must contain video.

Custom projects provide common landscape, vertical, square, and portrait resolution presets, plus standard frame rates from 23.976 through 120 fps. Choose Custom dimensions or Custom frame rate when a preset does not match the intended output. Custom dimensions accept even width and height values from 2 through 8,192 pixels, and custom frame rates accept values from 1 through 240 fps.

When entering custom dimensions, Lock aspect ratio is on initially. Changing either dimension calculates the other from the locked ratio and rounds the calculated value to an even pixel count. Turn the checkbox off to set width and height independently, including unconventional project frames. Turning it back on locks the dimensions at their current ratio. Select a source and press Command-I to read its proportional fitting and frame-rate conversion.

## Supported media

Trimato checks the media streams inside a file rather than relying only on its filename extension. Two files with the same extension can use different codecs and require different handling.

When AVFoundation can play and pass through a source natively, Trimato plays the original and can retain its file type and codec when Original format is selected for a standalone clip export. This commonly includes QuickTime Movie, MP4, M4V, M4A, WAV, AIFF, and other sources whose internal codecs are supported by macOS.

Some sources can be played by AVFoundation but cannot be passed through in their original file type or codec. Trimato still plays these sources directly, then converts them when an exported format requires it.

When AVFoundation cannot play a source, Trimato uses its bundled FFmpeg and ffprobe tools to inspect the local file and create a playback proxy. Audio-only proxies contain audio without manufacturing a video track. The proxy is used for responsive preview and editing; it does not replace the original and is not used as the final-quality source for a project export. Explicitly registered fallback extensions include:

- MKV
- WebM
- TS, MTS, and M2TS
- VOB
- WMV
- FLV

Format recognition does not guarantee that every possible codec or media feature inside a container can be edited. Trimato currently rejects HDR and alpha-channel sources when a safe MP4 conversion would not preserve those properties.

The bundled tools have networking, encrypted-stream protocols, and HLS support disabled. They can access only local files and local process pipes.

## Original media, playback proxies, and the media cache

Trimato projects save editing instructions and references to source files. They do not copy the original media into the project package. Keep the original files available at their saved locations. If a source is moved, renamed, disconnected, or deleted, use Relink Clip to locate it before previewing or exporting that part of the project.

For media that AVFoundation cannot play, Trimato stores a playback proxy in the macOS Caches directory. A project can reuse a valid proxy after it is closed and reopened. Trimato compares the source file's size and modification date with the information saved for the proxy; if the source changes, Trimato discards the stale proxy and creates a new one.

Playback proxies are disposable. Trimato recreates a missing proxy when the project next needs it, provided the original source remains accessible. macOS may also remove files from its Caches directory when storage is constrained.

Trimato manages the media cache automatically:

- The cache has an automatic limit of 10 GB.
- Trimato removes the least recently used unprotected proxies when necessary.
- Trimato requires enough storage for a new proxy while retaining at least 10 GB of available disk space.
- Proxies required by open projects and editors are protected from manual and automatic removal.
- Clear Unused Media Cache removes proxies not used in the last seven days.
- Clear All Media Cache removes every proxy not required by an open project or editor.
- Clearing the cache never deletes original media or Trimato project files.

Project export returns to the original source files rather than rendering from playback proxies. When AVFoundation cannot use an original directly in the final composition, Trimato creates a temporary full-resolution ProRes render intermediate from that original, applies the saved timeline instructions and project format, writes the chosen output, and removes the intermediate after export.

## Accessibility

Accessibility is part of Trimato's editing model rather than an additional mode.

- The complete editor can be operated from the keyboard.
- Native SwiftUI controls retain their standard VoiceOver roles and interactions.
- Visible section headings include VoiceOver heading traits.
- The Project Browser, Editor, and Timeline clips are labeled sections in structural source order. Linked regions support VoiceOver's linked-item navigation.
- The Track picker changes the track context for the linear Timeline clips list. VoiceOver focus on a clip or transition makes it the target for timeline commands and Command-I Get Info.
- Quick transition sheets return VoiceOver focus to the Editor after applying or canceling so repeated playback and editing remain in context.
- Timeline list items expose names and positions without continuously speaking start, end, and duration values. Press Command-I for exact timing and other information about the focused item.
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

Trimato has no accounts, advertising, analytics, or tracking. Media inspection, waveform generation, proxy creation, editing, and export happen locally on the Mac.

The original source file is not modified. Project playback proxies can remain in the macOS Caches directory so they can be reused across sessions. Standalone temporary proxies and final-export render intermediates are removed after their operation or editor session ends normally. Canceling an import or export removes its incomplete output. An abnormal process termination can prevent normal cleanup code from running.

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
