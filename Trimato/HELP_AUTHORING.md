# Edit Trimato Help

Trimato Help is stored in:

`Trimato/Trimato/Trimato.help/Contents/Resources/en.lproj`

Each Help topic is a separate HTML file. Open the file whose name matches the topic you want to change, then edit the content inside its `main` element.

## Topic files

- `index.html`: Help landing page and topic links.
- `getting-started.html`: Complete first-project workflow.
- `workspace.html`: Project, Editor, Timeline, and Inspector.
- `projects-and-media.html`: Projects, importing, folders, and relinking.
- `storage-and-temporary-media.html`: Projects, playback proxies, temporary renders, storage limits, and cleanup.
- `clip-editor.html`: Clip editing and clip placement.
- `playback-and-markers.html`: Playback, navigation, In, and Out.
- `timeline-editing.html`: Timeline placement, blading, arrangement, and deletion.
- `saving-and-exporting.html`: Saving, project export, clip export, and progress.
- `keyboard-shortcuts.html`: Shortcut tables.
- `voiceover.html`: VoiceOver workflow.
- `troubleshooting.html`: Recovery steps and problem reports.
- `trimato-help.css`: Shared appearance.

## Write a Help topic

1. Give the page one `h1` heading.
2. Use `h2` for sections beneath the page heading.
3. Use paragraphs for short explanations.
4. Use numbered lists for procedures.
5. Use bulleted lists for choices or short reference items.
6. Describe what a control does, how to use it, and the result.
7. Use the same control and menu names shown in Trimato.
8. Do not add ARIA, JavaScript, decorative symbols, or instructions that require sight.

## Add a topic

1. Duplicate an existing topic file.
2. Change its `title`, description, `h1`, and `main` content.
3. Add a link to the new file in `index.html`.
4. Add related-topic links where useful.
5. Rebuild the Help index.

## Rebuild the Help index

From the repository root, run:

```sh
./Trimato/build-help-index.sh
```

Commit the updated `Trimato.helpindex` with the edited HTML files.
