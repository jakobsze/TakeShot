# Changelog

Every change to Takeshot, newest first. Each entry says **what** changed, **why**, and its
**status**:

- ✅ **Verified**: tested on real hardware or with the QA harness, with the evidence noted
- 🟡 **Shipped, not verified**: built and installed, but not confirmed working end to end
- ❌ **Reverted / failed**: kept for history

When you change something, add an entry at the top (date, status). If a later test
confirms or disproves an earlier entry, update that entry's status rather than deleting it.

---

## 2026-10-18 · Release 0.4.0: first public version, updates from GitHub ✅ (install on another Mac 🟡)
- **Why:** Matt wants the code public on GitHub and the app installable on other Macs with
  automatic updates.
- **Release:** `./scripts/release.sh 0.4.0` (build 4) produced a universal (x86_64 + arm64)
  `Takeshot-0.4.0.zip` and `appcast.xml`. The build is signed with the Apple Development
  certificate (no Developer ID, so not notarized), and the update is EdDSA-signed with Matt's key.
- **Updates:** `SUFeedURL` = `https://github.com/jakobsze/TakeShot/releases/latest/download/appcast.xml`.
  Releases go on the public repo's GitHub Releases page (`release.config`, not committed).
- **README.md** added: features, install steps (including the one-time "Open Anyway"), build from
  source, and the donation button.
- **Verified:** unzipped the release and checked the version, build, feed URL, public key,
  donation URL, both architectures, a strict signature check, bundled Sparkle and the donation
  images. The appcast entry points at the zip with the correct length and signature.
- **Published:** code and tag `v0.4.0` pushed to `github.com/jakobsze/TakeShot`; release
  https://github.com/jakobsze/TakeShot/releases/tag/v0.4.0 has the zip and `appcast.xml`. GitHub
  CLI (`gh`, via Homebrew) is installed and logged in as jakobsze, so future releases can be
  published with `gh release create`.
- **Verified from outside:** the public `latest/download` links serve the feed and the zip (HTTP
  200, byte-identical), and the update signature verifies. **End to end:** a copy re-labelled
  0.3.9 found 0.4.0 on GitHub, downloaded and installed it, and relaunched as 0.4.0 (build 4) with
  a valid signature.
- **Not verified yet:** installing on a different Mac (Gatekeeper "Open Anyway" path).

## 2026-10-17 · Designed donation banner in the Recordings grid and card in export ✅
- **Update:** the banner's ✕ now hides it for **7 days** instead of 30 (`Support.bannerSnoozeDays`).
  Matt's existing hide (clicked 2026-10-13) was shortened to match, so it ends on 2026-10-20.
- **Update (same day):** at Matt's request the banner moved out of the grid. It is now a single
  banner pinned right below the toolbar ("Recordings" title and search), outside the scroll view,
  so it stays visible while scrolling. The grid is a plain grid again. Verified with a screenshot.
- **Why:** Matt designed both in Figma (file "FocusLock-UI", nodes 14:30 and 14:102). He asked
  for the banner to appear "every two records" inside the recordings list, and for the card
  to appear in export.
- **Recordings grid (first version, replaced the same day; see the update above):** the banner (app
  icon, "Takeshot is free…", orange "Buy me a coffee" pill, ✕) appeared after every **2 rows** of
  recordings. I read "every two records" as rows; it is one
  constant (`rowsBetweenBanners`). A short list still ends with one banner. The ✕ hides them
  all for 30 days. The old banner above the grid was removed.
- **Export:** the card (large icon, thank-you text, large orange button) shows above the progress
  bar **while the video renders**. It replaces the one-time card after the 10th export (removed,
  along with its milestone flag; exports are still counted).
- **Assets:** the design's background images, icon, cup and ✕ were downloaded to
  `Resources/Donation/`. The SVGs were rendered to 4× PNGs because macOS 13 can't load SVG, and
  the duplicated 4.8 MB icon was cut to one 256 px copy. The Makefile and `release.sh` now copy
  them into the bundle.
- **Verified:** screenshots of the Recordings grid (banner after 2 rows of 3) and of a real
  export of a recording copy at 37% with the card showing. Both match the Figma renders.

## 2026-10-16 · Donations switched on: "Buy me a coffee" button ✅
- **Why:** Matt sent his donation button (the embed code and a picture of it) to use as the
  donation banner.
- **What:** `DonateURL` is now `https://buymeacoffee.com/touchdesign`. A native `CoffeeButton`
  copies the look of his button (#FFDD00 rounded rectangle, black text, a takeaway cup drawn in
  SwiftUI; the system font stands in for Poppins). It replaces the "Support…" buttons in
  the Recordings banner, the 10th-export thank-you card and (at Matt's request) the editor
  toolbar, where it replaces the cup icon and sits at the far right, after Export. Menu items now read "Buy Me a Coffee…". The README shows the same button, linking to his page.
- **Verified:** screenshots of the editor toolbar (on a copy of a recording) and the Recordings
  banner with the new button (the banner snooze was
  lifted for the screenshot and then restored to Matt's value). Not seen: the thank-you card,
  which only appears after the 10th export.

## 2026-10-16 · New app icon ✅
- **Why:** Matt supplied his own icon artwork and asked to use it. The same day he replaced his
  first choice (a camera character on a blue-violet square) with the final one: a winking film
  clapperboard on a bright blue rounded square.
- **What:** the full-size artwork is kept at `Resources/icon-source/AppIcon-artwork.png`. It filled
  the whole 1024 px canvas, which would look oversized next to other macOS icons, so it was
  scaled onto Apple's grid: 824 px body centred on a 1024 canvas, with a soft drop shadow. All
  sizes from 16 to 1024 px went into `Resources/AppIcon.icns` (via `iconutil`). This replaces the
  generated icon from 2026-10-07.
  The same steps were rerun for the clapperboard artwork.
- **Verified:** the installed bundle contains the new .icns, and after re-registering the app
  with LaunchServices, `NSWorkspace.icon(forFile:)` returns the new icon. The Dock may show the
  old one until it refreshes.

## 2026-10-14 · Docking the pill to screen edges and corners ✅ (drag gesture 🟡)
- **Why:** Matt wants to drag the pill into a corner or onto an edge (including top centre) and
  have it stay there, upright on the left/right sides, with the recording widget in the same spot.
- **How it works:** dropping the pill within 72 pt of an edge of a display's usable area (menu bar,
  camera housing and Dock excluded via `visibleFrame`) docks it there: top or bottom → horizontal,
  left or right → vertical (icons only). Along the edge it snaps to start / centre / end by thirds.
  In a corner the current orientation wins; pushing further into one edge picks that edge. Dropped
  anywhere else it stays free, as before.
- **Recording widget:** appears at the same dock (upright on left/right), or centred on the pill's
  free spot; at the default spot it stays bottom centre of the recorded display.
- **Menu:** ⚙︎ › Dock Pill lists the 8 spots plus "Reset to Default Position". The Compact toggle
  is disabled while the pill is upright.
- **Saved:** `pillDock` in UserDefaults (side, spot, display ID), kept across launches.
- **Code:** `UI/PillDock.swift` (model, geometry, drop rules), `AppDelegate.finishBarDrag` /
  `dockBar`, `AnyLayout` in `RecordControlBar` and `RecordingWidgetView`.
- **Verified:**
  - Pill docked left/centre, top/right and bottom/left: screenshots checked, 12 pt from the edges,
    below the menu bar and above the Dock.
  - Recording self-test with right/bottom and top/centre docks: widget upright at the bottom right
    (60×220) and horizontal at top centre.
  - Drop rules tested on real screen geometry: middle → free, near left → left centre, past the
    right edge → right bottom, both orientations in the top-left corner, top middle → top centre.
  - Not verified by hand: the actual mouse drag and drop (can't be automated here).
- **Drag guides (added the same day) ✅ visuals / 🟡 live drag:** as soon as the pill moves, every
  screen dims slightly and outlines the dock spots in the shape the pill would take there (upright
  on the sides). The spot it would snap to if dropped now is highlighted in the accent colour.
  - Code: `UI/DockGuides.swift`. Drag tracking now polls the pill's frame at 60 Hz while the
    button is held (`AppDelegate.trackBarDrag`), replacing the debounced move notification.
  - Dev hook: `TAKESHOT_TEST_DOCK_GUIDES=<side>:<spot>` shows the guides with that target.
  - Verified: screenshot with the hook (`left:start` highlighted upright at the top left, the 8
    spots outlined). Not verified: the guides following a real hand drag.
- **Magnet snapping (replaces the edge-distance rule above) ✅ logic / 🟡 hand drag:** Matt asked
  for the pill to be pulled into the right place when dropped near a chosen spot. A drop now
  docks into the outlined spot nearest the **cursor** (each outline in the shape the pill takes
  there), when the cursor is within 150 pt of it (`PillDock.magnetRadius`); otherwise the pill
  stays free. Only the 8 outlined spots can be targets, so the highlight always matches the result.
  - Verified on real screen geometry: middle → free; 100 pt from the left outline → left centre,
    200 pt → free; just below the top-left outline → top left; top middle 120 pt below → top
    centre; past the bottom-right corner → bottom right; right edge a third down → right centre.
- **Instant snap 🟡:** Matt saw the snap only when the orientation changed, then only after a
  delay. Cause: AppKit's window drag (`isMovableByWindowBackground`) moves the window
  asynchronously and applies its final position after mouse-up, overriding the snap. Fix: the app
  now moves the pill itself (local monitor on mouse down/dragged/up in
  `installBarDragTracking`), AppKit window dragging is off, and the snap happens on mouse-up
  with no animation. A drag that starts on a pill button is sent "away" from the controls
  so the button is cancelled, not clicked; opening a pill menu cancels the drag.
  - Dev hook `TAKESHOT_TEST_DRAG=fromX,fromY,toX,toY` posts a real drag (needs Accessibility).
  - Not verified: on 2026-10-14 Takeshot had **no Accessibility permission** (lost with the
    bundle-ID change), so synthetic drags were dropped by macOS. Waiting on Matt's hand test.

## 2026-10-13 · Original identity throughout ✅
- **Why:** Matt wants nothing in the product that points to any other product.
- **Name:** the app, executable, package, sources (`Sources/Takeshot/`) and bundle ID
  (`com.touchdesign.takeshot`) are all Takeshot. A quick web search found no screen recorder or
  trademark with that name (not a legal clearance; check EUIPO/USPTO before a commercial launch).
- **Defaults:** the cursor, camera and click spring defaults were retuned to our own values, and
  the motion "feel" presets are now Gentle / Smooth / Brisk / Snappy. The first gradient preset and
  one colour swatch were changed.
- **Dev hooks:** environment variables are now `TAKESHOT_*`, and the donation key is `DonateURL`.
- **Housekeeping:** settings and the recordings folder (`~/Movies/Takeshot`, 53 items) were carried
  over on Matt's Mac. The one-time migration code was then removed, since no other installs exist.
- **Note:** macOS privacy permissions are tied to the bundle ID and must be granted once more.
- **Project:** the folder is now `~/Desktop/takeshot`; the git history was restarted from a single
  clean commit (Matt's choice), and build folders were rebuilt from scratch. Old settings and
  cache files from the previous bundle ID were moved to the Trash.
- **Verified:**
  - Build and install from the new folder.
  - QA: 88 checks pass; the 5 remaining "failures" are known sampling artifacts on that test
    recording.
  - No file in the project and no string in the compiled app refers to another product.

## 2026-10-13 · Movable/compact pill, timeline multi-select, playhead fix, automatic updates
- **Pill ✅:** can be dragged anywhere (grip at the left, or any empty part). Its centre is saved
  (`pillCenter`) and it stays there across launches and width changes, kept on screen. The ⚙︎ menu
  has "Reset position to bottom centre" and "Compact (icons only)" (names become tooltips; menus
  open on click).
  - Verified: compact pill is 381 pt wide vs ~810 pt; a saved centre of (700, 900) positions it
    exactly there.
  - Not verified: an actual mouse drag (it can't be automated here). Drag tracking uses a
    mouse-down-on-pill monitor.
- **Timeline multi-select ✅:** Shift- or ⌘-click adds/removes items, and dragging across empty
  timeline space rubber-band selects. Dragging one of several selected zooms/masks/layouts moves
  the group. Delete removes all selected as one undo step. The inspector shows "N items selected".
  Model: `EditorModel.multiSelection`, `select(_:extend:)`, `selectMany`, `deleteSelected`,
  `moveRanges`.
  - Verified with `TAKESHOT_TEST_MULTISELECT=1`: 12 zooms selected, group-moved by 0.5 s, deleted
    (12 → 0), and one undo restored all 12; screenshot checked.
  - Not verified by hand: the shift-click and marquee gestures themselves.
- **Playhead ✅:** the triangle is now centred on the red line (it was drawn 6 pt to the left).
- **Automatic updates (Sparkle 2.10) 🟡:** the update flow works, but nothing is hosted yet.
  - Sparkle is added via SwiftPM, embedded and signed by the Makefile. Code: `App/Updater.swift`.
  - "Check for Updates…" is in the app menu, the pill's ⚙︎ menu and the menu-bar menu. Settings ›
    General has the automatic check/install toggles.
  - An EdDSA signing key was generated: the private key is in Matt's Keychain, the public key is in
    Info.plist (`SUPublicEDKey`).
  - `scripts/release.sh <version>` (or `make release VERSION=…`) builds a universal app (arm64 +
    x86_64 built separately and merged with lipo, because only the Command Line Tools are
    installed), signs it, notarizes it if configured, zips it and updates `release/appcast.xml`.
    Config goes in `release.config` (template: `release.config.example`).
  - Verified end to end on this Mac: a 0.3.0 copy pointed at a local test feed found 0.3.1,
    downloaded it, verified it, replaced itself and relaunched (version, architectures and
    signature checked afterwards).
  - Still needed before it reaches other computers: a real `SUFeedURL` (hosting, e.g. GitHub
    Releases) and a Developer ID certificate + notarization. Until `SUFeedURL` is set the updater
    stays off and the menu item explains why.

## 2026-10-09 · Support / donation entry points 🟡 (link not set yet)
- **Heart "Support" button:** in the editor toolbar, the pill's ⚙︎ menu and the menu-bar icon's
  menu.
- **Recordings window banner:** a slim banner at the top; its ✕ hides it for 30 days
  (`supportBannerHiddenUntil` in UserDefaults).
- **Thank-you note:** shown once, ever, in the export sheet after the user's 10th successful export.
  `ExportJob` counts exports (`supportExportCount`, `supportThankYouShown`).
- **Donation link:** the `DonateURL` key in `Resources/Info.plist`, **currently empty**. Until
  it's set, Support buttons show a "link not set yet" alert. Code is in `App/Support.swift`.
- **Verified:** screenshots of the toolbar heart, the Recordings banner, and the thank-you card
  (counter forced to 9, then an export). The test counters were reset afterwards.
  Status stays 🟡 until a real donation URL is added and the button is clicked through.

## 2026-10-08 · Instant preview refresh; darker dimming outside the recorded area ✅
- **Live refresh:** changing any setting now redraws the editor canvas immediately; before, it
  only updated after scrubbing. **Cause:** the refresh sought the player to the time it was already
  at, which AVPlayer treats as a no-op. `EditorModel.refreshFrame()` now re-assigns a copy of the
  item's video composition, forcing the compositor to re-render the current frame.
  - **Verified:** a dev hook (`TAKESHOT_TEST_LIVE_REFRESH=1`) changes the background 6 s after opening.
    Before/after screenshots show the canvas switching from gradient to red with the playhead
    untouched.
- **Dimming while recording** (`NonRecordedDisplayOverlay` rewritten):
  - Area: everything outside the selected area is dimmed.
  - Window: everything except the window is dimmed, and the cut-out follows the window at 15 Hz.
  - Display: other displays are dimmed.
  - Darkness raised from 55% to 78%. Before, area and window recordings had no dimming at all.
  - **Verified:** mid-recording screenshots for area and window modes; the recorded area video
    contains no dimming (overlays are our own windows, excluded from capture).

## 2026-10-08 · Camera panel: "not working" report ✅
- **Report:** the user said the camera settings weren't working. **Cause:** "Hide camera" was on in
  that project ("Finder 2026-10-08 02.16"), so the camera wasn't drawn and no other camera setting
  had a visible effect. Rendering the same project with the camera shown applied every setting
  correctly.
- **UX fixes so this can't look broken again:**
  - "Hide camera" is now a "Show camera" switch. When it's off, the other camera controls are
    disabled and an orange note explains why.
  - The corner buttons are replaced with a segmented picker (↖ ↗ ↙ ↘ Custom) that shows the
    current selection; previously nothing indicated which corner was chosen.
- **Remove background:** the cut-out is now trimmed to the camera shape, so Roundness applies, and
  Shadow casts a soft shadow around the person's silhouette (it was ignored before). Border is
  disabled for cut-outs, with an explanation.
- **Verified:** all 17 camera/layout options PASS in the QA harness on a copy of the user's
  recording. The cut-out render was checked on white and wallpaper backgrounds.

## 2026-10-07 · macOS native design (Apple HIG) ✅
- **Why:** user asked to adopt Apple's macOS design system. Apple's Design Resources are Figma/Sketch
  kits for designing apps, not code, so in code this means building the UI from native controls,
  materials, system colours, SF Symbols and standard window patterns.
- **Recording pill, widget, countdown:** frosted behind-window material (`NSVisualEffectView` .hudWindow),
  and Liquid Glass (`glassEffect`) automatically on macOS 26+. System colours, so light and dark
  mode both work. Text styles instead of fixed font sizes. The selected source has an
  accent-coloured highlight. The record/stop buttons are native red-dot symbols. Added
  accessibility labels.
- **Editor:**
  - The custom top bar is replaced with a real window toolbar: unified title bar with project name
    and duration subtitle, Rename, Undo/Redo control group, aspect-ratio menu, Presets menu, and a
    prominent Export button.
  - Inspector: segmented icon picker plus grouped `Form` sections (System Settings style), with
    sliders as `LabeledContent` rows.
  - Timeline colours are system colours (`TrackColor`). Layouts get their own lane, so they no
    longer overlap masks.
- **Settings:** the standard macOS `Settings` scene (⌘,) with toolbar tabs: General, Recording,
  New Projects, Shortcuts. It opens via SwiftUI `openSettings` on macOS 14+.
- **Recordings window:** native toolbar search (`.searchable`), toolbar Refresh and Show in Finder
  buttons, and a navigation subtitle.
- **App icon:** a new `Resources/AppIcon.icns` drawn to Apple's macOS icon grid (1024 canvas,
  824 body, ~185 px corners, drop shadow); the app had none before.
- **Verified:** screenshots of the pill, editor (Camera and Cursor tabs), Settings window and icon;
  export QA matrix still 0 failures. Light mode and the Liquid Glass path (macOS 26) not seen yet,
  because this Mac is on macOS 15 in dark mode.

## 2026-10-06 · Control pill pinned to bottom centre ✅
- The recording bar ("pill") always sits centred at the bottom of the **main display** (the one with
  the menu bar), 24 pt above the Dock. It is re-centred on launch, after each recording, when its
  width changes and when displays change. It is no longer draggable.
- **Why:** user request.
- **Verified:** window bounds checked with CGWindowList. Centre x = 1280 on a 2560-wide display, both
  at 765 pt wide and at 884 pt (after selecting camera and mic), and after a recording finished.

## 2026-10-06 · Full QA pass and capture fixes ✅
A test matrix covering every camera, mic, display, capture source, style option, audio option,
export setting and edit operation found these bugs, all now fixed:
- **Bluetooth mic audio was 2× too long** (Bose QC35 at 16 kHz): the AAC writer resampled wrongly.
  Capture now delivers 48 kHz Float32 to the encoder.
- **Continuity Camera (iPhone)**
  - Added `NSCameraUseContinuityCameraDeviceType` to Info.plist.
  - The iPhone stamped frames on its own clock (days off), so samples are re-stamped onto the host
    clock, falling back to arrival time if the device clock is more than 1 s off.
  - Starting the camera/mic no longer blocks the screen recording.
- **Static window/area recordings came out about half length:** the pause gap had been measured from
  frame timestamps, and ScreenCaptureKit sends no frames while content is static. Pauses are now
  measured on the host clock, and a closing frame is written at stop.
- **Screen writer failure after resume (-16364):** a resumed frame could reuse the last timestamp.
  Non-increasing timestamps are now dropped.
- Added `App/TestHarness.swift` (`TAKESHOT_QA`) and a configurable recording self-test (see AGENTS.md).
- **Verified:**
  - Recording matrix: LG 5K display, built-in display, window, area, MacBook camera + mic, iPhone
    camera + mic, Bose mic, system audio. All passed.
  - Options: 59/60, 61/62 and 43/44 on three projects; the rest were test-sampling artifacts, each
    confirmed on another project.
  - Audio options: all passed. Export matrix: 11/11 plus quality ordering and cancel.
  - Edit operations: all passed. Captions transcribed a `say`-generated sentence correctly.
- **Known:** the Bose QC35 records pure digital silence (hardware/Bluetooth profile, not the app). The
  editor now warns about silent mic tracks.

## 2026-10-06 · Camera and mic split, pause-safe camera, camera from frame 1 ✅
- Camera → `webcam.mov` and mic → `mic.m4a` now have independent writers (`Project.micFileName` /
  `micOffset`). A mic failure can no longer discard the camera video.
- The camera pause gap is measured on the capture clock. Before this, the camera writer failed right
  after resume (-16364) in 2 of 4 takes.
- The composition holds a settled camera frame (taken 0.3 s in, because first frames are often black)
  over the start gap, so the bubble is visible from the first frame.
- The editor warns when the mic recorded silence.
- **Verified:** two consecutive camera + mic recordings with pause/resume both completed; the render
  shows the bubble at t=0.

## 2026-10-06 · Camera missing from videos: fixed; auto-framing and camera zoom ✅
- **Root cause:** `AVCaptureMovieFileOutput` failed with -11805 "Cannot Record". The user's camera
  files were about 3 s long and started 13–20 s late. It was replaced with
  `AVCaptureVideoDataOutput`/`AudioDataOutput` feeding our own `AVAssetWriter`, stamped on the host
  clock.
- Added face auto-framing (Vision face detection, smoothed, run every 4th frame), a camera zoom
  control, and a larger default bubble (0.32).
- **Verified:** camera now covers the whole take (5.7 s of 5.9 s, offset 0.1 s).

## 2026-10-06 · Full feature rewrite ✅
- Rebuilt the app around a full editing feature set; everything was written from scratch.
- **New render pipeline:** `CompositionBuilder` → `StudioCompositor` (AVVideoCompositing) →
  `FrameRenderer` (Core Image). The same pipeline drives the live preview (AVPlayer) and export.
- **Background:** macOS wallpapers (read from the system, not bundled), gradients, colour, image,
  blur.
- **Frame:** padding, inset, corner radius, directional shadow, window frames (macOS light/dark,
  glass), aspect ratios, crop.
- **Cursor:** spring-smoothed, uses the real recorded system cursor shapes, size, tilt, idle-hide,
  shake removal, loop-to-start, ripple/press click effects, click sounds, motion blur.
- **Zoom:** ranges in auto (follow cursor) or manual mode, instant, always-zoomed-in, spring presets,
  motion blur.
- **Timeline:** split, delete, trim, per-segment speed/volume/hide-cursor, waveform, undo/redo.
- **Camera:** position, size, roundness, aspect, mirror, shrink-on-zoom, background removal, shadow,
  border. Layouts: camera only, screen only, side by side.
- **Captions, overlays and audio:** captions (on-device Speech), keystroke overlay,
  blur/pixelate/spotlight masks, mic enhancement, background music, remove silences, speed up typing.
- **Export:** MP4/MOV/GIF; H.264/HEVC/ProRes; 720p–4K; 24/30/60 fps; three quality levels.
- **Recorder:** countdown, pause/resume/restart/cancel widget, camera preview, hide desktop icons,
  30/60 fps, keystroke recording, global hotkeys.
- **App:** Recordings library, Settings window, style presets.
- **Fixes in this commit:** screen/camera/cursor sync offsets (previously ignored); idle SCK frames
  were being appended to the writer.
- Projects migrated v1 → v2 (keyframes → zoom ranges). Migration is in-memory only and writes v2 on
  the first edit.
- **Not built:** device mockups (window frames instead), bundled wallpapers/music, cloud share links,
  window-resize presets.

## 2026-10-06 · Snapshot of the original app 🟡
- The pre-rewrite code (v0.1), committed so the rewrite can be compared or reverted.
- Many recordings from this version were 0 bytes or never finalised; the likely cause is idle frames
  being appended to the writer.
