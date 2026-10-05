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
| OCR Snip | `Ctrl+Alt+6` | Copy the text, table, link, or QR code in a screen region. See [Text Capture](#text-capture). |
| DemoType | `Ctrl+7` | Simulated typing from clipboard (prefix text with `[start]`). |
| Panorama | `Ctrl+8` | Select a region, scroll the page, then press `Esc` or `Ctrl+8` again to stitch the captures into one image and copy it to the clipboard. |
| Save Panorama | `Ctrl+Shift+8` | Same as Panorama, but writes the stitched image to a PNG via save dialog. |
| Demo Mirror | `Ctrl+9` | Mirror the source display onto a second display. |
| Demo Mirror Region | `Ctrl+Shift+9` | Select a region to mirror onto a second display. |
| Demo Mirror Window | `Ctrl+Alt+9` | Mirror the window under the pointer onto a second display. |

### Menu Bar

Every feature is also listed in the menu bar icon's menu, so you can click an item instead of remembering its shortcut.
Items are grouped by feature (zoom, draw, record, snip, text capture, panorama, Demo Mirror, DemoType, break timer) and each one shows its current shortcut on the right, including any you have customized in Preferences.
The text capture block also has **Text from Clipboard**, **Text from Image or PDF…**, and **Text Capture History…**.

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

### Demo Mirror

Connect a second display, then press `Ctrl+9` to mirror the display containing the pointer.
Use `Ctrl+Shift+9` to select a region or `Ctrl+Alt+9` to mirror the window under the pointer.
The mirrored view includes the pointer and stays above presentation or slide-show windows.
Press any Demo Mirror shortcut again to stop.

Preferences lets you choose the presentation display.
Tracked window regions include ZoomIt drawing and zoom overlays; disable tracking to mirror the window surface without overlapping content.

### Panorama

Capture a tall page or wide spreadsheet as a single image:

1. Press `Ctrl+8` and drag to select the region you want to capture (the visible content area, not the full page).
2. The selection becomes a fixed border that stays on top while you scroll.
3. Scroll the page (vertically or horizontally) at any speed; ZoomIt captures frames in the background.
4. Press `Esc`, click **Finish Panorama**, or press `Ctrl+8` again to stop. Frames are stitched and copied to the clipboard.

Use `Ctrl+Shift+8` instead to save the stitched image to a PNG file via the standard save dialog.

### Recording

Press `Ctrl+5` to record the full display, `Ctrl+Shift+5` to record a selected region, or `Ctrl+Alt+5` to record the window under the cursor. Press the same shortcut again to stop; ZoomIt opens a trim window where you can trim the start or end, save the selected range as MP4 or GIF, or cancel and discard the recording.

### Text Capture

Press `Ctrl+Alt+6` and drag over anything on screen: a paused video, a scanned PDF, a slide in a screen share, or a photo of a router sticker.
The text goes to the clipboard and a small toast shows what was copied.
Focus returns to the app you were using, so `Cmd+V` pastes there right away.

- **QR codes and barcodes:** when the selection contains a code, ZoomIt copies what it encodes instead of the text around it. Turn on **Open QR code links automatically** in Preferences to open web links; only `http` and `https` links are ever opened.
- **Tables:** a table is copied as tab-separated text plus an HTML table, so it pastes as a table into Numbers, Excel, Google Sheets, Notes, Pages, Word, and Mail. macOS 26 and later use Vision's document recognition; earlier versions rebuild rows and columns from the text positions.
- **Links:** a capture that is a single web address is filed under Links in history.
- **Clipboard and files:** **Text from Clipboard** reads a copied screenshot, image, image file, or PDF. **Text from Image or PDF…** opens a file. PDFs use their text layer when they have one, and scanned pages are read with OCR (the first 20 scanned pages).
- **History:** **Text Capture History…** lists past captures with search and All, Text, Tables, Links, and Codes filters. Double-click a capture or press `Return` to copy it again. History stays on this Mac, keeps the 100 most recent captures, and can be turned off or cleared in Preferences.

Preferences › Text Capture sets the recognition language (automatic by default), accurate or fast mode, whether to keep line breaks or join wrapped lines into paragraphs, and whether to keep table layout.

Recognition runs on your Mac with Apple's Vision framework, and nothing is uploaded.
A capture takes about 40 ms for text and 100 ms for a table on Apple silicon.
The first capture after installing ZoomIt or updating macOS can take about 25 seconds while macOS prepares Vision's models for the app.
ZoomIt does that work in the background a few seconds after launch, so you normally never wait for it.

### Automation

Every feature has a `zoomit://` URL, so Raycast, Alfred, Shortcuts (**Open URLs**), or a Stream Deck can trigger it:

```bash
open zoomit://ocr-snip        # drag over the screen to copy text
open zoomit://ocr-clipboard   # copy the text in the image on the clipboard
open zoomit://ocr-file        # choose an image or PDF to read
open zoomit://ocr-history     # show text capture history
open zoomit://preferences     # zoomit://settings also works
```

The other features use their names in lowercase with hyphens: `zoom`, `draw`, `break-timer`, `live-zoom`, `live-draw`, `record`, `crop-record`, `window-record`, `snip`, `save-snip`, `demo-type`, `previous-demo-type`, `panorama`, `save-panorama`, `demo-mirror`, `demo-mirror-region`, and `demo-mirror-window`.
You can also open an image or PDF with the app to copy its text, for example `open -a "ZoomIt for Mac" scan.png`.
URLs reach the installed app only; a build started with `swift run` has no app bundle and does not receive them.

## Requirements

- macOS 13.0 or later
- **Screen Recording** permission (for zoom, draw, snip, text capture from the screen, recording)
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
├── AppCore/               # Settings, shortcut models, capture geometry, text capture models, URL commands
├── PlatformServices/      # Screen capture, clipboard, OCR and table recognition, permissions, hotkeys
├── ValidationRunner/      # Build-time validation checks
└── ZoomItForMacApp/       # Main app
    ├── AppDelegate.swift                  # App lifecycle, CGEvent tap, Carbon hotkeys
    ├── FeatureCoordinator.swift           # Central action router
    ├── ZoomOverlayController.swift        # Zoom and Live Zoom
    ├── DrawOverlayController.swift        # Draw mode with annotations
    ├── SnipController.swift               # Screenshots and region selection
    ├── TextCaptureController.swift        # OCR, QR codes, tables, clipboard and file capture
    ├── TextCaptureHistoryWindowController.swift  # Searchable capture history
    ├── TextCaptureToastController.swift   # "Copied" feedback toast
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
