# raycast-ext-screen-record

A personal Raycast extension: record a screen area, trim/cut it, then export as MP4 or GIF — copy to clipboard or save to Downloads.

## Use

1. Run **Record Screen Area**. A resizable overlay appears (full-screen the first time; size and position are remembered afterwards). Drag handles to resize, drag anywhere else to move, **Return** to record, **Esc** to cancel.
2. A flashing **STOP REC** button appears in the menu bar. Click it (or run the command again) to stop.
3. An editor opens: preview, drag the yellow handles to trim, **S** to cut a gap at the playhead (drag its edges), **⌫** to cut/restore the selected piece. Pick **MP4 | GIF**, then **Copy to Clipboard** or **Download**.

## Requirements

- macOS, [Raycast](https://raycast.com), Node, Xcode command-line tools (`swiftc`)
- `ffmpeg` (`brew install ffmpeg`)
- Screen Recording permission for Raycast

## Install

```bash
npm install
npm run dev   # imports the extension into Raycast; Ctrl+C once it says "built extension successfully"
```

The Swift helpers in `assets/` are compiled on first use.
