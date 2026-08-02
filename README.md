# ZoomIt for Mac

A native macOS menu bar app that brings [Sysinternals ZoomIt](https://learn.microsoft.com/en-us/sysinternals/downloads/zoomit) functionality to Mac. Built with Swift and AppKit.

## Demo

![ZoomIt for Mac demo](docs/demo.gif)

## Features

| Feature | Shortcut | Description |
|---------|----------|-------------|
| Zoom | `Ctrl+1` | Freeze screen and zoom. Mouse pans. Click enters draw mode. |
| Draw | `Ctrl+2` | Freeze screen and annotate with ink, shapes, arrows, text. |
| Break Timer | `Ctrl+3` | Full-screen countdown timer. |
| Live Zoom | `Ctrl+4` | Real-time magnification. Click-through — use your system normally while zoomed. |
| Live Draw | `Ctrl+Shift+4` | Live zoom, then click to freeze and draw. |
| Record | `Ctrl+5` | Full-display recording with 3-second countdown, trim window, and MP4/GIF save options. |
| Crop Record | `Ctrl+Shift+5` | Record a selected region with visible border frame, then trim before saving. |
| Window Record | `Ctrl+Alt+5` | Record the hovered window, then trim before saving. |
| Snip | `Ctrl+6` | Screenshot region to clipboard. Preserves open menus. |
| Save Snip | `Ctrl+Shift+6` | Screenshot region and save to file via save dialog. |
| OCR Snip | `Ctrl+Alt+6` | Extract text from a screen region to clipboard. |
| DemoType | `Ctrl+7` | Simulated typing from clipboard (prefix text with `[start]`). |
| Panorama | `Ctrl+8` | Select a region, scroll the page, then press `Esc` or `Ctrl+8` again to stitch the captures into one image and copy it to the clipboard. |
| Save Panorama | `Ctrl+Shift+8` | Same as Panorama, but writes the stitched image to a PNG via save dialog. |

### Menu Bar

Every feature is also listed in the menu bar icon's menu, so you can click an item instead of remembering its shortcut.
Items are grouped by feature (zoom, draw, record, snip, panorama, DemoType, break timer) and each one shows its current shortcut on the right, including any you have customized in Preferences.

### Draw Mode Tools

While in draw mode (`Ctrl+1` click or `Ctrl+2`):

| Key | Tool |
|-----|------|
| `R/G/B/Y/O/P` | Ink color (Red/Green/Blue/Yellow/Orange/Pink) |
| `Shift+color` | Highlight mode |
| `T` | Text tool (`Shift+T` for right-aligned) |
| `W` / `K` | Whiteboard / Blackboard background |
| `Shift` hold | Straight line |
| `Ctrl` hold | Rectangle |
| `Tab` hold | Ellipse |
| `Ctrl+Shift` hold | Arrow |
| `Ctrl+Z` / `U` | Undo |
| `E` / `C` | Clear all |
| `Arrow keys` | Adjust brush/font size |
| `Esc` / Right-click | Exit draw mode |

### DemoType

Copy text to your clipboard with a `[start]` prefix, then press `Ctrl+7`:

```
[start]Hello, this is a demo of simulated typing!
```

Press `Esc` to stop mid-typing. Press `Ctrl+7` again to restart.

### Panorama

Capture a tall page or wide spreadsheet as a single image:

1. Press `Ctrl+8` and drag to select the region you want to capture (the visible content area, not the full page).
2. The selection becomes a fixed border that stays on top while you scroll.
3. Scroll the page (vertically or horizontally) at any speed; ZoomIt captures frames in the background.
4. Press `Esc`, click **Finish Panorama**, or press `Ctrl+8` again to stop. Frames are stitched and copied to the clipboard.

Use `Ctrl+Shift+8` instead to save the stitched image to a PNG file via the standard save dialog.

### Recording

Press `Ctrl+5` to record the full display, `Ctrl+Shift+5` to record a selected region, or `Ctrl+Alt+5` to record the window under the cursor. Press the same shortcut again to stop; ZoomIt opens a trim window where you can trim the start or end, save the selected range as MP4 or GIF, or cancel and discard the recording.

## Requirements

- macOS 13.0 or later
- **Screen Recording** permission (for zoom, draw, snip, recording)
- **Accessibility** permission (for global hotkeys, DemoType, event tap)
- **Input Monitoring** permission (for reliable hotkey detection)

The app prompts for permissions on first launch.

## Install

```bash
./Scripts/install.sh
```

This builds a release binary and creates `ZoomIt for Mac.app` in `/Applications`.

Then launch with:

```bash
open '/Applications/ZoomIt for Mac.app'
```

Or enable **Launch at Startup** from the menu bar icon.

## Development

```bash
# Run directly
swift run ZoomItForMacApp

# Validate (runs tests + build)
./Scripts/validate.sh
```

### Project Structure

```
Sources/
├── AppCore/               # Settings, shortcut models, capture geometry
├── PlatformServices/      # Screen capture, clipboard, OCR, permissions, hotkeys
├── ValidationRunner/      # Build-time validation checks
└── ZoomItForMacApp/       # Main app
    ├── AppDelegate.swift                  # App lifecycle, CGEvent tap, Carbon hotkeys
    ├── FeatureCoordinator.swift           # Central action router
    ├── ZoomOverlayController.swift        # Zoom and Live Zoom
    ├── DrawOverlayController.swift        # Draw mode with annotations
    ├── SnipController.swift               # Screenshots and OCR
    ├── RecordingController.swift          # Screen recording (GIF/MP4)
    ├── BreakTimerController.swift         # Break timer overlay
    ├── DemoTypeController.swift           # Simulated typing
    ├── PanoramaController.swift           # Scrolling-region capture lifecycle
    ├── PanoramaStitcher.swift             # Frame matching and stitching
    ├── StatusItemController.swift         # Menu bar icon and menu
    ├── PreferencesWindowController.swift  # Settings UI
    └── OverlayWindow.swift                # Custom window types
```

## License

MIT
