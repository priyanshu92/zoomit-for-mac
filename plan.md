# ZoomIt for macOS implementation plan

## Problem

Build a macOS application that reaches practical feature parity with Microsoft PowerToys ZoomIt, based on the current upstream module in `microsoft/PowerToys/src/modules/ZoomIt`.

## Current state

- The local workspace is now a Git-initialized Swift package with a native macOS menu bar app target.
- This is a greenfield implementation, not a port of an existing macOS codebase.
- The current implementation includes:
  - Windows-equivalent default shortcuts, including the extended shortcut-parity set (`Ctrl+Shift+4`, `Ctrl+Shift+5`, `Ctrl+Alt+5`, `Ctrl+Shift+6`, `Ctrl+Shift+7`)
  - Editable shortcut settings with validation and live global hotkey reload
  - Zoom and live zoom overlays with HUD, panning, recentering, freeze/follow behavior, and zoom controls
  - Draw overlay with pen, highlight, blur, rectangle, ellipse, line, arrow, text annotations, undo, clear, and on-screen tool help
  - Break timer overlay with progress, elapsed time, status messaging, and completion signaling
  - Recording that can save GIF or MP4 output to a configurable directory, with recording HUD and richer export summaries
  - Interactive snip, OCR snip, and panorama capture with clipboard copy, file save, and stronger OCR fallback handling
  - DemoType behavior that switches between preview mode and clipboard/typing-oriented delivery depending on permissions
  - Persisted app settings and a preferences window
  - Actionable permission onboarding, System Settings shortcuts, path browsers, settings reset, and shortcut reset flows
  - Follow-up regression fixes for overlay dismissal via Esc/cancel, key-capable borderless overlay windows, and correctly enabled actionable menu bar items
  - A local validation runner wired through `Scripts/validate.sh`
- Upstream ZoomIt currently spans these user-facing capabilities:
  - Zoom and live zoom
  - Draw/annotate with freehand, shapes, blur/highlight, and text
  - Break timer
  - Recording (GIF and MP4, with audio options)
  - Snip capture
  - OCR snip
  - Panorama/scrolling capture
  - DemoType scripted typing
  - Tray/menu integration, theme, hotkeys, save locations, and trim UI

## Upstream feature map

The upstream Windows module appears to center on:

- `Zoomit.cpp`: main orchestration, hotkeys, overlays, snipping, recording, and mode switching
- `ZoomItSettings.h`: effective feature inventory and defaults
- `BreakTimer.cpp`: break timer rendering and behavior
- `DemoType.cpp`: scripted typing engine
- `SelectRectangle.cpp`: selection overlays
- `GifRecordingSession.cpp` and `VideoRecordingSession.cpp`: recording/export
- `AudioSampleGenerator.cpp` and `LoopbackCapture.cpp`: audio handling
- `PanoramaCapture.cpp`: scrolling capture
- `ZoomItSettingsInterop/ZoomItSettings.cpp`: settings serialization and PowerToys integration

## macOS constraints that shape the design

- Screen Recording permission is required for zoom/live zoom, snip, recording, OCR, and panorama.
- Accessibility and Input Monitoring permissions are required for global hotkeys, input capture, and DemoType/event injection.
- Many Windows APIs used upstream have no direct macOS equivalent:
  - Magnification API -> custom render pipeline
  - Win32 tray/hotkeys/hooks -> AppKit + event taps / hotkey wrappers
  - Registry -> `UserDefaults` or plist-backed persistence
  - Windows OCR -> Vision
  - Windows capture/encoding stack -> ScreenCaptureKit + AVFoundation + ImageIO/CoreGraphics
- Some features need explicit feasibility checkpoints on macOS:
  - System audio capture behavior
  - Panorama/scrolling capture across third-party apps
  - Lock-workstation equivalent during break timer
  - Mac App Store sandbox compatibility

## Recommended product shape

- Build this as a real Git-managed software project from day one, not just an app folder. Repository setup, branching discipline, and repeatable validation belong in the foundation work.
- Build a menu bar app with a preferences window and full-screen overlay windows.
- Use Swift as the primary language.
- Prefer AppKit for overlay/control windows, with SwiftUI for settings and onboarding.
- Build explicit service boundaries so the app is not another monolithic `Zoomit.cpp`.
- Make keyboard shortcuts a parity feature: default mappings should stay as close as possible to Windows ZoomIt so switchers do not need to relearn the product.

## Shortcut strategy

- Preserve the upstream ZoomIt defaults as the target interaction model:
  - Zoom: `Ctrl+1`
  - Draw: `Ctrl+2`
  - Break timer: `Ctrl+3`
  - Live Zoom: `Ctrl+4`
  - Record: `Ctrl+5`
  - Snip: `Ctrl+6`
  - DemoType: `Ctrl+7`
  - Panorama snip: `Ctrl+8`
  - OCR snip: `Ctrl+Alt+6`
- Implement these as the macOS defaults unless a hard platform-level conflict makes a specific shortcut unreliable.
- If a shortcut must diverge on macOS, document the reason and keep the alternative as close as possible to the Windows muscle-memory pattern.
- Expose all shortcuts in settings, but optimize the out-of-box experience for Windows ZoomIt users moving to Mac.

## Proposed architecture

### 1. Repository and developer workflow

- Initialize Git in the repo immediately
- Add `.gitignore`, project bootstrap files, and a predictable folder layout
- Define branch and checkpoint strategy so major features land incrementally
- Add local validation commands and, once the project exists, CI-ready build/test entry points

### 2. App shell

- Menu bar app lifecycle
- Preferences window
- Permission onboarding flows
- Login item / launch at login support

### 3. Platform services

- Global hotkeys with Windows-equivalent default mappings
- Event tap / input monitoring
- Accessibility-driven event injection
- Display/screen enumeration
- Clipboard/file dialog helpers
- Settings storage and migration

### 4. Capture and render engine

- ScreenCaptureKit frame acquisition
- Zoom transforms for standard zoom and live zoom
- Overlay composition for cursor, drawing, text, and selection
- Frame timing and image smoothing

### 5. Annotation subsystem

- Tool model: pen, highlighter, blur, rectangle, ellipse, line, arrow, text
- Annotation scene graph
- Undo history
- Font and color configuration

### 6. Recording subsystem

- MP4 pipeline via AVFoundation
- GIF export path
- Audio capture inputs and routing
- Save/export flows
- Trim and preview UI

### 7. Snip subsystem

- Region selection
- Clipboard/save output
- OCR extraction with Vision
- Panorama capture strategy and stitching

### 8. Break subsystem

- Countdown window
- Background/image/faded-desktop modes
- Opacity and placement
- Alarm playback
- Elapsed-time behavior

### 9. DemoType subsystem

- Script parser
- User-driven typing mode
- Safe text/event injection
- Clipboard-aware paste/typing paths

### 10. Validation layer

- Unit tests for parsers, settings, geometry, and image-processing logic
- Integration checks for permissions, overlays, capture, recording, and hotkeys
- Manual validation checklist for multi-display, Retina, and accessibility-sensitive flows
- Shortcut parity validation against the Windows default key map, including conflict checks and customization flows
- Repeatable build/test commands that can run locally on every milestone

## Implementation phases

### Phase 0: Repository foundation

- Initialize Git in the current folder.
- Create the initial project structure, `.gitignore`, and baseline developer workflow files.
- Decide early on how milestones will be committed so the project can evolve safely and be rolled back/debugged cleanly.

### Phase 1: App and service foundation

- Create the macOS app project and baseline build/test targets.
- Add a menu bar item, preferences shell, and permission onboarding.
- Establish service protocols for hotkeys, capture, injection, settings, export, and validation hooks.
- Implement the Windows-equivalent default shortcut map early so every later feature is wired against the intended keybindings from the start.

### Phase 2: Zoom core

- Implement screen capture and overlay rendering.
- Add standard zoom, live zoom, panning, initial magnification, smooth image, and animated zoom.
- Validate behavior on multi-display and Retina setups.

### Phase 3: Annotation and text

- Add draw-without-zoom and draw-on-zoomed-screen modes.
- Implement pens, shapes, blur/highlight, undo, and text annotations.
- Wire font and appearance settings.

### Phase 4: Break timer

- Implement configurable timer duration, position, opacity, sound, background options, and elapsed-time display.
- Decide and document the best macOS equivalent for workstation lock behavior.

### Phase 5: Recording

- Add MP4 recording first, then GIF export.
- Support zoom/annotation capture in recordings.
- Add microphone selection, audio capture policy, scaling, frame-rate controls, and trim UI.

### Phase 6: Snip, OCR, and panorama

- Implement region snip to clipboard/file.
- Add OCR extraction with Vision.
- Prototype panorama capture early, because it carries the most platform risk outside audio/input injection.

### Phase 7: DemoType

- Port scripted typing and user-driven modes.
- Add control-sequence parsing and reliable event injection with permission/error handling.

### Phase 8: Validation

- Add automated tests for parsing, settings, geometry, annotation state, and image-processing components.
- Add repeatable validation for hotkeys, permissions, recording, OCR, panorama, and DemoType.
- Run a dedicated compatibility pass on multi-monitor and Retina setups.
- Verify that the shipped default shortcuts remain aligned with the Windows ZoomIt defaults and are documented anywhere macOS needs an exception.
- Capture a regression checklist so feature parity work remains stable as later phases land.

### Phase 9: Polish and packaging

- Finish settings parity.
- Add onboarding for permissions and failure states.
- Prepare code signing, notarization, and release packaging.

## Key decisions and assumptions

- Optimize for local installation on your Mac first. Distribution-channel constraints are intentionally out of scope for the initial implementation plan.
- Treat feature parity as the goal, but keep feasibility checkpoints for:
  - system audio capture
  - panorama capture
  - break-timer lock behavior
- Treat Git support as part of the initial foundation, including repository initialization, incremental commits, and validation-friendly project structure.
- Treat keyboard shortcut parity as part of feature parity, with Windows-equivalent defaults as the starting point rather than a later customization option.
- Build MP4 first and layer GIF export afterward.
- Build the app as a native macOS product, not a cross-platform wrapper.

## Risks and mitigation

- **Permissions complexity**: front-load onboarding and diagnostics.
- **Panorama capture reliability**: spike early and define fallback behavior if app-controlled scrolling is unavailable.
- **System audio capture**: validate legal/technical capture path early on the target macOS versions.
- **Repository drift in a greenfield project**: initialize Git and keep features landing in coherent milestones from the start.
- **Shortcut conflicts on macOS**: validate Windows-equivalent defaults early and define the minimum necessary exceptions where the OS or common apps make a binding unusable.
- **Overlay performance**: isolate capture/rendering from UI state and test on Retina + multi-monitor setups early.
- **Input injection safety**: keep DemoType isolated behind explicit permissions and defensive state handling.
- **Late discovery of regressions**: add a dedicated validation phase and milestone-level checks instead of relying on end-of-project manual testing.

## Todo breakdown

1. Initialize Git and repository foundation
2. Bootstrap macOS app shell
3. Build platform service layer
4. Implement zoom and overlay engine
5. Implement annotation and type modes
6. Implement break timer feature
7. Implement recording and export pipeline
8. Implement snip, OCR, and panorama capture
9. Implement DemoType playback
10. Add validation and regression coverage
11. Finish settings, QA, and packaging

## Notes

- The upstream Windows implementation is heavily Win32-centric and monolithic; reproducing behavior on macOS will be faster and safer with a modular native architecture.
- `ZoomItSettings.h` indicates additional parity targets beyond the public docs, including panorama snip, OCR snip, system-audio options, theme override, and trim dialog persistence.
- Git setup and validation are now explicit deliverables, not cleanup work to be postponed until the end.
- Shortcut parity is now explicit too: the default Mac experience should feel familiar to Windows ZoomIt users.
- Distribution and packaging decisions can be deferred until after core feature parity is working locally.

## Implementation progress

- Repository foundation, validation, and native app shell are complete.
- Core shortcut-driven flows are implemented and wired through the menu bar app.
- Settings persistence is implemented for recording format/save paths, zoom factor, break duration, annotation font size, and DemoType speed/text.
- Preferences now allow direct shortcut editing, reset-to-default behavior, and immediate hotkey re-registration without restarting the app.
