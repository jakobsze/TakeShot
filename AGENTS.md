# Takeshot: project memory for AI assistants

Read this before changing anything. Then read `CHANGELOG.md` for what has been done and how it was
verified. `CHANGELOG.md` is local only: it is in `.gitignore` and not published to GitHub (Matt's
choice, 2026-10-19), so never `git add -f` it. **When you make a change, add a CHANGELOG entry and update this file if any fact below
changes.**

## What this is
A native macOS screen recorder and editor that turns raw recordings into polished videos: automatic
zooms, smooth cursor, camera bubble, backgrounds, captions.
It is written from scratch in Swift: SwiftUI, ScreenCaptureKit, AVFoundation, Core Image and Vision.
All code and assets are original. Never copy code, assets, names or default values from any other
product, and don't name other products in the app, code, docs or commit messages. Wallpapers are
read at runtime from `/System/Library/Desktop Pictures`, and music is chosen by the user.

- Owner: Matt. He wants a polished recorder that is local only and free.
- Platform: macOS 13+ (developed on macOS 15, Apple Silicon). Swift 5 language mode, SwiftPM.
- Size: ~9k lines across `Sources/Takeshot/`.

## Naming
- The app is **Takeshot** (bundle ID `com.touchdesign.takeshot`). Use only this name in UI,
  identifiers, docs and commit messages.
- Dev environment variables use the `TAKESHOT_` prefix.
- The repository is `~/Desktop/takeshot`. Its git history was restarted on 2026-10-13, so
  `CHANGELOG.md` is the record of everything before that.

## Current state (2026-10-13)
- **Version:** 0.4.0 (first public release), installed at `/Applications/Takeshot.app`. Recordings live in
  `~/Movies/Takeshot`.
- **Works and tested:**
  - recording: displays, windows, areas, camera, mic, system audio, pause/resume
  - the full editor, live preview and export (MP4/MOV/GIF)
  - captions, native macOS UI and timeline multi-select
  - the movable/compact pill, which docks to screen edges and corners (`UI/PillDock.swift`;
    left/right docks are upright, and the recording widget uses the same dock)
  - Support entry points (heart button, Recordings banner, 10th-export thank-you)
  - Sparkle self-update (tested against a local feed)
- **Waiting on Matt:**
  - optionally a Developer ID certificate
- **After the 2026-10-13 bundle-ID change,** macOS privacy permissions must be re-granted once on
  each Mac.

## Build, install, run
```bash
make app       # swift build -c release + bundle + codesign → dist/Takeshot.app
make install   # app + copy to /Applications + launch
make run       # app + launch from dist/
```
- The bundle is signed with the "Apple Development" identity (see `Makefile`) so that macOS privacy
  grants (Screen Recording, Camera, Mic, Accessibility, Input Monitoring, Speech) survive rebuilds.
  Don't switch to ad-hoc signing.
- **Launch through LaunchServices** (`open …` / `open -n --env KEY=VAL …`), never by running
  `dist/…/MacOS/Takeshot` from a shell for anything involving capture or input events. From
  a shell, macOS attributes permissions to the terminal, and the cursor event tap silently receives
  nothing. Headless render/QA modes can run the binary directly.
- Projects are saved to `~/Movies/Takeshot/<date>/` (configurable in Settings). **Those are
  the user's recordings:** test on copies in a temp folder. Move your own test takes to the Trash
  when you're done.

## Architecture
```
Capture/      RecordingSession orchestrates:
              ScreenCaptureEngine (SCStream → AVAssetWriter screen.mov [+ system audio])
              WebcamCaptureEngine (one AVCaptureSession for preview + data outputs →
                                   separate writers webcam.mov and mic.m4a)
              InputEventRecorder (CGEventTap: mouse taps; keys in a separate tap) → events.json
              CursorShapeRecorder (NSCursor.currentSystem @30 Hz) → cursors.json + cursors/*.png
Model/        Project (v2 JSON), StyleConfig (all style options, presets), InputEvent, ClipMap
Compositing/  MotionTracks (spring-simulated CursorTrack & ViewportTrack, KeystrokeTrack, precomputed)
              FrameGeometry (layout maths shared with UI), RenderAssets (wallpapers, cursors, text)
              FrameRenderer (Core Image: draws one frame), StudioCompositor (AVVideoCompositing)
              CompositionBuilder (AVMutableComposition: clips, speed, music, click sounds, audio mix)
Editing/      EditorModel (document + undo/redo + AVPlayer preview + all edit ops),
              AudioTools (waveform, silences, mic enhancement, Speech captions), AutoZoomGenerator
Export/       VideoExporter (reader/writer for MP4/MOV, ImageIO for GIF), ExportJob
UI/           NativeStyle (materials/Liquid Glass, settings opener, TrackColor),
              RecordControlBar (the pill + RecorderViewModel), EditorWindow, TimelineView,
              InspectorViews, ExportSheet, ProjectsWindow (+ SettingsView), RecordingOverlays
              (countdown, recording widget, camera preview, global hotkeys), AreaSelectionOverlay
App/          TakeshotApp (AppDelegate, status item, scenes), AppSettings + PresetStore,
              DebugHooks (TAKESHOT_RENDER_TEST), TestHarness (TAKESHOT_QA)
```
**Key principle:** preview and export use the *same* pipeline (CompositionBuilder → StudioCompositor
→ FrameRenderer). If the preview looks right, the export will too. Don't add a separate render path.

### Time bases (the source of most bugs)
- **Session time:** seconds since recording start on the host clock (`CACurrentMediaTime`), with
  pauses removed. Used by events and cursor changes.
- **Source time:** screen.mov time. `Project.screenOffset` = session time of screen.mov t=0.
- **Camera/mic files:** `webcamOffset` / `micOffset` = screen time at which that file's t=0 occurs.
  Any of these can be positive (the device started late, e.g. an iPhone takes ~2 s) or slightly
  negative.
- **Output time:** the edited timeline after cuts and speed changes. `ClipMap` converts between
  output and source. Zoom ranges, masks, layouts and captions are stored in **source** time.
- Every capture writer stamps samples on the **host clock**, and pauses are measured on the host
  clock, never from frame gaps.

### Project folder (v2)
`project.json`, `screen.mov`, `webcam.mov`?, `mic.m4a`?, `events.json`, `cursors.json`, `cursors/`,
`mic-enhanced.m4a`? (generated), `thumbnail.jpg` (generated).
- v1 projects (zoomKeyframes, mic inside webcam.mov) are migrated in memory on load.
- `Project.micSource` resolves where the mic audio lives, for both v1 and v2.

## Testing (do this after any capture/render/export change)
- **Headless render + export** of one project. Writes `render-test/` frames and an export:
  `TAKESHOT_RENDER_TEST=<folder> [TAKESHOT_RENDER_TEST_EDITS=1] [TAKESHOT_RENDER_TEST_GIF=1] [TAKESHOT_RENDER_TEST_STYLE='{"cursorSize":3}'] dist/Takeshot.app/Contents/MacOS/Takeshot`
- **QA harness.** Logs `QA: PASS/FAIL` lines and exits with code 2 on failures:
  `TAKESHOT_QA=<folder> TAKESHOT_QA_PARTS=options,audio,export,edits [TAKESHOT_QA_CAPTIONS=1] [TAKESHOT_QA_MIC_ONLY=1] …/Takeshot`
  - Options: each style option must change the rendered pixels (≥3 changed pixels at 320×180).
  - Audio: the RMS of the mixed audio moves in the expected direction.
  - Export: an 11-case matrix checked for size, codec, fps, duration and audio, plus cancel.
  - Captions need Speech permission. Run that part via `open` and feed it `say`-generated speech.
- **Real recording self-test.** It moves the mouse, pauses and resumes, then stops:
  `open -n -W --env TAKESHOT_AUTO_RECORD_TEST=1 --env TAKESHOT_TEST_QUIT=1 --env TAKESHOT_TEST_SOURCE=display|window|area --env TAKESHOT_TEST_DISPLAY=0 --env TAKESHOT_TEST_CAMERA_NAME=MacBook --env TAKESHOT_TEST_MIC_NAME=MacBook --env TAKESHOT_TEST_SYSAUDIO=1 --env TAKESHOT_TEST_KEYS=1 dist/Takeshot.app`
  Then inspect the new folder: durations of screen/webcam/mic should agree, offsets should be small,
  and mic peak > 0.
- Other dev hooks: `TAKESHOT_AUTO_OPEN_EDITOR=1` (+ `TAKESHOT_AUTO_OPEN_EDITOR_PATH`), `TAKESHOT_EDITOR_TAB=camera`,
  `TAKESHOT_OPEN_WINDOW=projects|settings`, `TAKESHOT_AUTO_EXPORT=1`,
  `TAKESHOT_TEST_DOCK_GUIDES=left:start` (shows the pill's drag guides with that target),
  `TAKESHOT_TEST_DRAG=fromX,fromY,toX,toY` (posts a real mouse drag; needs Accessibility).
- The pill is dragged by the app itself, not AppKit (`installBarDragTracking`); don't turn
  `isMovableByWindowBackground` back on, or snapping becomes late or gets undone.
- Screenshot only our own windows: get the window ID via CGWindowList, then `screencapture -l <id>`.

### Hardware on Matt's Mac (as of 2026-10-06)
- Displays: LG Ultra HD 5K (main, 2560×1440 pt) and built-in Retina (1728×1117 pt).
- Cameras: MacBook Pro Camera, iPhone (Continuity).
- Mics: Bose QC35 II (default; **records silence**), MacBook Pro Microphone, iPhone.

## UI conventions (macOS native, Apple HIG)
- Use native controls, system colours (`Color(nsColor: .systemRed)`, `.primary`, `.secondary`,
  `.accentColor`), text styles (`.callout`, `.headline`) and SF Symbols. Don't hard-code
  RGB/white/black colours or point font sizes.
- Floating surfaces (pill, recording widget, countdown) use `.floatingSurface(shape)` from
  `UI/NativeStyle.swift`: Liquid Glass on macOS 26+, an `NSVisualEffectView` material before.
- Inspector panels are grouped `Form` sections (`Group2` wraps `Section`). Window actions go in
  `.toolbar`. Settings are the SwiftUI `Settings` scene; open it with `openAppSettings()`.
- Timeline colours come from `TrackColor`. The app icon is Matt's artwork (2026-10-16), kept full
  size at `Resources/icon-source/AppIcon-artwork.png`. It is scaled onto Apple's grid (824 px body on
  a 1024 canvas, soft drop shadow) and built into `Resources/AppIcon.icns`, which the Makefile
  copies into the bundle. Rebuild the .icns from the artwork if it changes; see CHANGELOG 2026-10-16.

## Gotchas learned the hard way
- `AVAssetTrack` does **not** retain its `AVAsset`. Keep assets alive until composition inserts are
  done, or the inserts fail with -12780 (see `CompositionBuilder`).
- `AVCaptureMovieFileOutput` failed with -11805 on this machine. Use data outputs and our own writers.
- Never feed an AVAssetWriter input a non-increasing PTS. The writer fails with -16364 and the whole
  file is lost. All writers guard against this.
- Scaling a composition time range that runs past a track's end corrupts that track. Pad tracks with
  empty ranges, as `CompositionBuilder` does.
- Read export audio with its own `AVAssetReader`, separate from the custom-compositor video output.
- ScreenCaptureKit sends no frames while the screen is static. Don't infer time from frame gaps.
- SwiftUI `keyboardShortcut` with no modifiers steals keys from text fields. The editor uses
  `EditorKeyMonitor` for Space, Delete and the arrow keys.
- `@StateObject` init can run several times per window, so editor models are cached per folder
  (`ProjectLoader`).
- Motion blur uses a half-frame shutter. Earlier, stronger values smeared whole zoom transitions.

## Releases and automatic updates (Sparkle)
- `App/Updater.swift` wraps Sparkle. It only starts when Info.plist has both `SUFeedURL` and
  `SUPublicEDKey`.
- **Hosting: GitHub Releases of the public repo `https://github.com/jakobsze/TakeShot`.**
  `SUFeedURL` = `https://github.com/jakobsze/TakeShot/releases/latest/download/appcast.xml`. Every
  release must upload **both** the zip and `appcast.xml` to a GitHub release marked "Latest". The
  feed and the zip URL point at `latest/download/`, so the newest release must contain both files.
- The private update-signing key is in Matt's login Keychain ("Private key for signing Sparkle
  updates"). Never export it into the repo. Back it up with
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>`; losing it means existing
  installs can't be updated.
- Publishing (GitHub CLI is installed and logged in as jakobsze):
  `gh release create v<ver> release/Takeshot-<ver>.zip release/appcast.xml --repo jakobsze/TakeShot --title "Takeshot <ver>" --latest`.
  Commit the bumped `Resources/Info.plist`, then tag and push first.
- Release: copy `release.config.example` to `release.config`, fill in `FEED_URL` and
  `DOWNLOAD_URL_PREFIX`, run `./scripts/release.sh 0.3.1`, and upload `release/appcast.xml` plus
  the zip. The first run shows a Keychain prompt for the signing key; choose "Always Allow".
- Other Macs will only open the app once it is signed with a Developer ID certificate and
  notarized. The script does both automatically when the certificate and `NOTARY_PROFILE` exist.
- Local test of the whole flow: serve `release/` with `python3 -m http.server 8765`, give an older
  copy `SUFeedURL=http://127.0.0.1:8765/appcast.xml` plus `NSAllowsLocalNetworking`, re-sign it,
  and launch it with `TAKESHOT_CHECK_UPDATES=1`.
- Builds: the Intel half uses `--scratch-path .build-intel`; sharing `.build` between
  architectures corrupts SwiftPM's build database.

## Support / donations
- `App/Support.swift`, built from Matt's Figma designs:
  - **Recordings banner** (`SupportBanner`, Figma node 14:30): one banner pinned below the toolbar
    of the Recordings window, outside the scroll view so it stays visible while scrolling. The ✕
    hides it for 7 days.
  - **Export card** (`ExportSupportCard`, node 14:102): shown in the export sheet while the video
    renders.
  - Both use an orange (#FF4800) button and the images in `Resources/Donation/`, which the
    Makefile and `release.sh` copy into the bundle. The system font stands in for the design's
    Inter.
  - The yellow `CoffeeButton` is at the far right of the editor toolbar. Menus have a plain
    "Buy Me a Coffee…" item.
  - The URL is Info.plist `DonateURL` = `https://buymeacoffee.com/touchdesign`.

## Open issues / ideas (not done)
- **Requested by Matt, to do later (2026-10-17):** an on/off toggle so the camera recording is not
  zoomed in/out (the camera stays the same size when the screen zooms).
- Distribution: releases are on GitHub (see "Releases and automatic updates"). Without a
  Developer ID certificate + notarization, other Macs need "Open Anyway" once (README explains).
  The release is signed with Matt's Apple Development certificate, whose name contains his email
  address; a Developer ID would show his name instead.
- Device mockups (MacBook/iPhone frames), window-resize presets before recording, and cloud share
  links are not built.
- A recording that fails at stop leaves a project folder without `project.json`. The library ignores
  it, but it should be cleaned up or recovered.
- Swift 6 strict-concurrency warnings remain (the package builds in Swift 5 mode). They are harmless
  for now.
