# Timeline clip movement regression

Status: the user confirmed working VoiceOver behavior in the diagnostic build
on September 14, 2026. Process inspection identified that build as the only
running Trimato instance. The trace recorded an accessibility focus request,
then the same clip becoming keyboard responder, then Space resolving to that
clip. Preserve the explicit native `setAccessibilityFocused` forwarding method
from that build as well as the button-cell lookup; remove diagnostic logging.
This observation does not isolate which difference from the user's earlier
Xcode session caused the improvement. A fresh Xcode/release build still needs
confirmation. The earlier Tab-based checks alone were insufficient.

## Cause and repair

With VoiceOver enabled and a Timeline clip focused, pressing Space fell through
to the macOS error sound. A temporary diagnostic build reproduced the failure:
the keyboard bridge was installed, its window was key, no sheet or menu blocked
input, and AppKit returned an `NSButtonCell` as the focused element. The Timeline
selection lookup returned nil because the identifier is on the cell's native
button, which the cell's accessibility-parent chain skipped.

The lookup now resolves `NSCell.controlView` before looking for the Timeline
identifier. The Editor's Timeline exclusion uses that same lookup. This changes
command targeting without changing controls, accessibility hierarchy, focus,
or traversal order. Temporary diagnostics were removed from the final code.

## Automated verification

- Unsigned Debug app and test targets: `build-for-testing` passed.
- ProjectPlaybackTests and MultiTrackTimelineTests: 122 tests passed in two suites after preserving the verified native focus handler.
  The opt-in physical deletion interaction test remained disabled.
- New tests exercise accessibility focus requests without Tab, actual native
  button cells, Space pickup/drop and arrow
  routing, button reuse, empty cells, and an Editor button that must not resolve
  to a Timeline clip.
- The first standalone helper run lacked bundled FFmpeg tools. After providing
  the same bundled FFmpeg/ffprobe resources used by the app, both suites passed,
  including their media rendering and preview checks.
- `git diff --check` passed.

## Running app verification

Used the rebuilt app at
`/tmp/trimato-timeline-movement-build/Build/Products/Debug/Trimato.app` and a
temporary copy of proClips. The installed app and original project were not
replaced or saved over.

With VoiceOver enabled, native keyboard navigation focused a Timeline clip.
Space changed its accessibility value to Selected. Right followed by Space
changed the clip order and cleared Selected. Undo restored the original order;
Redo reapplied movement. Returning to an Editor control let Space start and
pause playback. Returning to Timeline, opening its native Control-Return menu,
dismissing it, and pressing Space selected the clip for moving again.

These observations verify running-app state through Computer Use. They do not
replace the user's confirmation of VoiceOver speech and their usual navigation
sequence in the distributed build.
