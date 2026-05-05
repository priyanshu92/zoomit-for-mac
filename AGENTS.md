# ZoomIt for Mac — agent instructions

A native macOS menu-bar app (Swift + AppKit, SwiftPM) that ports Sysinternals ZoomIt features to Mac. macOS 13+, Swift tools 6.0.

## Build, validate, run

```bash
swift build                       # debug build
swift run ZoomItForMacApp         # run from source
./Scripts/validate.sh             # ValidationRunner + swift build (CI-equivalent)
swift run ValidationRunner        # run all assertions
./Scripts/install.sh              # release build → /Applications/ZoomIt for Mac.app
```

There is no XCTest target — `Tests/AppCoreTests/` is intentionally empty. All automated checks live in the `ValidationRunner` executable target (`Sources/ValidationRunner/main.swift`) as a sequence of `validate*` functions wrapping `expect(...)`. To "run a single test", call the function directly from `ValidationRunner.main()` or `swift run ValidationRunner` and read the failing assertion. When you add behavior to `AppCore`, add a matching `validate*` step there — `UserDefaults`-backed stores must be exercised against a fresh `UserDefaults(suiteName:)` so the user's real prefs aren't touched (see `validateShortcutStorePersistence`).

## Architecture

Three SwiftPM targets, strict layering top-to-bottom:

- **`AppCore`** — pure models/logic, no AppKit. `ShortcutAction` enum, `ShortcutBinding` + `ShortcutCatalog` (Windows-style defaults like `Ctrl+1`), `AppSettings` + `UserDefaultsAppSettingsStore`, `CaptureGeometry` (point→pixel math).
- **`PlatformServices`** — `@MainActor` protocols + `Mac…` implementations for OS integration: `ScreenCaptureService`, `ClipboardService`, `OCRService` (Vision), `PermissionsService`, `CarbonHotKeyCenter` (`RegisterEventHotKey`).
- **`ZoomItForMacApp`** — the executable. `main.swift` sets `setActivationPolicy(.accessory)` (the app is `LSUIElement`). `AppDelegate` owns stores/services and lazily builds `FeatureCoordinator`, which is the **single router** between hotkeys and feature controllers (`ZoomOverlayController`, `DrawOverlayController`, `SnipController`, `RecordingController`, `BreakTimerController`, `DemoTypeController`, `PanoramaController`, etc.). Add a new feature by extending `ShortcutAction` + `ShortcutCatalog.windowsEquivalentDefaults`, then dispatching it inside `FeatureCoordinator.trigger`.

## Hotkey routing (read this before touching shortcuts)

There are **two parallel hotkey paths**, and a few actions live in both:

1. **Carbon `RegisterEventHotKey`** via `CarbonHotKeyCenter` — default for everything. Fed by `shortcutStore.allBindings()`, so it picks up user customizations.
2. **CGEvent tap** in `AppDelegate.swift` (`snipEventTapCallback`, `setupSnipEventTap`) — installed because Carbon hotkeys don't fire while a menu is tracking. Hard-coded by **raw keyCode** for `.draw`, `.snip`, `.saveSnip`, `.ocrSnip`, `.panorama`, `.savePanorama` (currently 19/22/28 → digits 2/6/8). The Carbon handler skips this same set when the tap is active to avoid double-firing.

Consequences:

- If you change the **default** binding for any action in that set, update the `(keyCode, hasShift, hasAlt)` switch in `snipEventTapCallback` *and* the `eventTapActions` set in `AppDelegate.applicationDidFinishLaunching`. The CGEvent tap path ignores user shortcut overrides — that's a known limitation, not a bug to "fix" with a quick patch.
- The tap also pre-captures the screen under the cursor for snip/draw/ocrSnip and forwards it as `preCapturedImage` so the menu doesn't bleed into the screenshot. Preserve that flow when adding new tap-routed actions.
- Panorama uses the tap to intercept `Esc` (keyCode 53) only while `panoramaEventTapIsActive` is true.

## Conventions

- **Concurrency**: AppKit-touching types are `@MainActor`. The CGEvent tap callback is a C function pointer, so its shared state uses `nonisolated(unsafe)` file-scope vars and dispatches back via `DispatchQueue.main.async`. Don't capture `self` in those callbacks.
- **Permissions gate**: any action that captures the screen or recording must early-return through `presentMissingPermissionAlert` if `permissionsService.snapshot().screenRecording != .granted` (see the existing branches in `FeatureCoordinator.trigger`). DemoType also gates on `.accessibility`.
- **Persistence**: settings and shortcuts go through `UserDefaults*Store` types; never read `UserDefaults.standard` directly from controllers — inject the store. `AppSettings` exposes `validated*` and `trimmed*` accessors that clamp/sanitize values; UI and consumers must read those, not the raw fields.
- **Logging**: use `zoomItDebugLog("...")` (writes to stderr with a `[ZoomIt]` prefix). No `print` for runtime diagnostics.
- **Overlay windows**: use `OverlayWindow`/`OverlayPanel` from `OverlayWindow.swift` (they override `canBecomeKey/Main`); pick `NSWindow.Level.statusBar` (or +1) for stay-on-top overlays — see `PanoramaController` constants.
- **App bundle**: there is no Xcode project. `Scripts/install.sh` emits `Info.plist` inline. `CFBundleShortVersionString` / `CFBundleVersion` in that script are currently hardcoded — bump them there when cutting a release.

## Release artifact (`.app.zip`)

GitHub releases ship a single asset, `ZoomIt-for-Mac-<version>.app.zip`, containing the `ZoomIt for Mac.app` bundle. Do not attach a raw `ZoomItForMacApp` binary.

Build the asset from the tag (not `main`) so what's released matches what's tagged:

```bash
git worktree add /tmp/zoomit-vX.Y.Z-build vX.Y.Z
cd /tmp/zoomit-vX.Y.Z-build && swift build -c release
```

Then stage a bundle that mirrors `Scripts/install.sh`:

- `ZoomIt for Mac.app/Contents/MacOS/ZoomItForMacApp` — copied from `swift build -c release --show-bin-path`.
- `ZoomIt for Mac.app/Contents/Resources/AppIcon.icns` — copied from `Resources/AppIcon.icns`.
- `ZoomIt for Mac.app/Contents/Info.plist` — same plist `Scripts/install.sh` writes, but set `CFBundleShortVersionString` and `CFBundleVersion` to the real version (the script currently hardcodes `1.0`).

Ad-hoc sign and zip with `ditto` (regular `zip` mangles the `.app` layout and `__MACOSX` resource forks confuse Gatekeeper on unzip):

```bash
codesign --force --sign - --timestamp=none "ZoomIt for Mac.app"
codesign --verify --verbose=2 "ZoomIt for Mac.app"
ditto -c -k --sequesterRsrc --keepParent "ZoomIt for Mac.app" "ZoomIt-for-Mac-X.Y.Z.app.zip"
gh release upload vX.Y.Z "ZoomIt-for-Mac-X.Y.Z.app.zip"
```

Release-notes **Install** section must walk users through the Gatekeeper bypass — the bundle is only ad-hoc signed (not Developer ID + notarized), and on macOS 15+ the old right-click → **Open** trick no longer works. Instead, instruct users to:

1. Download the zip and double-click it in Finder to unzip (preserves the bundle layout — third-party unarchivers can corrupt it).
2. Drag `ZoomIt for Mac.app` into `/Applications`.
3. Try to launch it once — macOS shows *"Apple could not verify … is free of malware"*. Click **Done** (not *Move to Bin*).
4. Open **System Settings → Privacy & Security**, scroll to the **Security** section, and click **Open Anyway** next to the ZoomIt entry; authenticate, then launch the app again.
5. Power-user fallback (skips the dialog dance) — strip the quarantine xattr from a terminal:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/ZoomIt for Mac.app"
   open "/Applications/ZoomIt for Mac.app"
   ```

Then mention the usual first-launch permission prompts (Accessibility, Screen Recording, Input Monitoring). Clean up the worktree (`git worktree remove --force …`) and the staging dir when done.

