# Changelog

All notable changes to GameMaster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.3.15] — 2026-07-14

Further hardening from a code-review pass over 0.3.14.

### Fixed
- **Updating the graphics runtime and running a game can no longer overlap.**
  The update now takes an exclusive lock that every way of starting a Windows
  process shares, so it can't begin while any Wine command is in flight —
  closing a narrow timing window where changing a bottle's settings could still
  touch the runtime mid-update.
- **Graphics-acceleration setup writes its per-bottle files atomically too.**
  Two programs launching in one bottle at once can no longer leave a support
  library momentarily missing or fail each other; each file is placed in a
  single atomic step.

## [0.3.14] — 2026-07-14

Follow-up hardening from a code-review pass over 0.3.13.

### Fixed
- **Updating the graphics runtime is refused while other work is underway.** A
  GPTK import stands down while a program is launching or running, a bottle is
  being created or deleted, or an install is in progress.
- **Activating MetalFX's shared shim is written atomically.** Two bottles
  preparing MetalFX on the shared runtime at the same time can no longer expose
  a half-written shim or fail each other.

## [0.3.13] — 2026-07-14

Hardening and reliability from a code-review pass over 0.3.12, plus a build-
pipeline security fix.

### Fixed
- **Updating the graphics runtime holds a maintenance lease.** Importing Apple's
  D3DMetal is held under a lease for its whole duration: it won't start while a
  game is launching, a bottle is being created, or an install is running, and
  those same actions are refused while it's underway.
- **MetalFX checks both halves of its shim.** A runtime missing either the unix
  or the Windows MetalFX library now reports a clear error instead of enabling
  MetalFX half-prepared.
- **A failed bottle setup detects leftovers more reliably.** Cleanup now checks
  the bottle's folder on disk directly, so it can't miss a partially-removed
  bottle.

### Performance
- **Very large, still-growing logs open with a strict size cap** — the viewer
  reads a bounded, up-to-date tail rather than potentially more than intended.

### Security
- **The signing/notarization step no longer runs alongside freshly-installed
  build tools.** The release pipeline was split so linters installed from
  Homebrew run only in a separate, credential-free verification stage, isolated
  from the job that holds the Developer ID certificate and signing keys.

## [0.3.12] — 2026-07-14

More fixes from a code-review pass over 0.3.11 — one is a regression 0.3.11
introduced.

### Fixed
- **Steam always stops cleanly, even with a damaged MetalFX setup.** 0.3.11's
  Stop fix missed Steam's own `-shutdown` path, so a broken MetalFX file on a
  GPTK bottle could still block it. It no longer depends on graphics preparation.
- **MetalFX says so when it can't be enabled.** If the runtime doesn't include
  the MetalFX libraries, turning MetalFX on now reports a clear, actionable error
  at launch instead of silently doing nothing.
- **Updating the graphics runtime waits for a quiet moment.** Importing Apple's
  D3DMetal is now refused while a program is running or an install is in progress,
  so the shared runtime can't be replaced out from under a live game.
- **A failed bottle setup tells you if leftovers remain.** If the automatic
  cleanup after a failed setup can't remove the half-created bottle, the app now
  says so instead of leaving it to reappear silently.

### Performance
- **Opening a log or showing program cards no longer stutters the UI.** Logs are
  read off the main thread (and only the recent tail of very large logs), and
  program-icon extraction from big executables runs in the background.

Follow-up fixes from a code-review pass over 0.3.10 — two of these are
regressions 0.3.10 introduced.

### Fixed
- **Starting a second install no longer clashes with one already running.**
  0.3.10 scoped install progress per bottle, which accidentally let you kick off
  a second install (even into another bottle) on top of a running one; now other
  bottles show "Another install is in progress…" until the first finishes.
- **Stop / Force Stop All work even when a bottle's MetalFX files are damaged.**
  0.3.10 routed graphics preparation through the same path used to stop a
  program, so a broken MetalFX file could leave a bottle unstoppable. Stopping no
  longer depends on that preparation.
- **New bottles on the default runtime keep Retina on.** The "tuned to your Mac"
  defaults were turning Retina off without enabling MetalFX to restore
  sharpness, giving a needlessly soft default image; Retina is now only lowered
  when MetalFX will upscale it back.
- The app icon no longer logs an asset-size warning on every build.

## [0.3.10] — 2026-07-14

Reliability and correctness fixes from a code-review pass — no behavior you
asked for changes, several sharp edges go away.

### Fixed
- **"Recommend for this Mac" no longer clears a frame-rate cap you set by hand.**
  It only ever touched Retina/MetalFX, but was silently resetting the cap to
  uncapped; now it leaves it alone.
- **A bottle whose first boot fails is rolled back instead of lingering.**
  Previously a failed setup left a half-initialized "ghost" bottle on disk that
  reappeared on the next refresh or restart.
- **"Add to Library and Run" now tracks the program's running state**, so the
  new card shows Starting/Running instead of offering Play on a program that is
  already running (which could start a duplicate).
- **Install progress stays on the bottle being installed into.** Starting an
  install in one bottle and switching to another no longer shows the second
  bottle the first one's progress bar.
- **A corrupt hand-edited MetalFX upscale factor can no longer crash a launch**
  — persisted values are clamped to a sane range on load.
- **GPTK MetalFX preparation is non-destructive and no longer fails silently.**
  It copies its shims instead of consuming the shared runtime's originals, and a
  preparation failure surfaces instead of launching with MetalFX only pretending
  to be on.

## [0.3.9] — 2026-07-13

Graphics tuning, grounded in on-device measurement. Profiling CS2 on Apple
silicon showed the bottleneck is the CPU/x86-translation layer, not the GPU —
so this round fixes a misleading setting and adds real, verified DXMT controls
rather than chasing FPS the graphics path can't deliver.

### Added
- **Bottles are tuned to your Mac's display.** New bottles now start with
  graphics defaults matched to your screen — rendering at the logical (Retina-off)
  resolution and letting MetalFX upscale to native, which is sharp and nearly
  free when the GPU has headroom. A **"Recommend for this Mac"** button in Bottle
  Settings re-applies them on demand. Existing bottles are never changed on their
  own.
- **MetalFX quality and a frame-rate limit** (DXMT runtimes). Choose how far
  MetalFX upscales (1.5× / 2.0×) and cap the frame rate (60 / 120 / 240,
  Metal-paced) for steadier frame times. Both merge cleanly with any DXMT_CONFIG
  set by hand in the advanced field.

### Changed
- **The MetalFX explanation is now accurate.** It previously claimed MetalFX
  "renders internally at a lower resolution" for a "big FPS gain"; in fact MetalFX
  enlarges the output — the lower render resolution comes from turning Retina off.
  The help text now says so, and recommends pairing the two.

## [0.3.8] — 2026-07-13

A follow-up hardening round: the third security review's actionable findings,
fixed test-first.

### Fixed
- **Stopping a stubborn program no longer freezes its card.** When a program
  ignored the close request (a save dialog, a Steam update), the card could
  stay stuck on a "Closing…" spinner with no button until the program finally
  exited or you Force Stopped the whole bottle. It now reverts to Running with
  a working Stop button once the wait times out.
- **A crash right after installing a runtime can no longer lose it.** The
  runtime's metadata is now written together with its files in a single
  atomic step, so an interrupted install can't leave a runtime that reads as
  "missing" and re-downloads. A hiccup in the startup runtime-recovery pass
  also no longer blanks the rest of the app's refresh.

### Security
- **The release build pins XcodeGen.** The tool that generates the project the
  app is signed from is now downloaded at a fixed version and checksum instead
  of a floating formula, keeping the signed artifact reproducible.
- **The Steam runtime download's source is reproducible.** Its release tag now
  points at the commit that actually produced the archive (with the bundled
  license texts), rather than an earlier one.

## [0.3.7] — 2026-07-13

A second hardening round: all nine findings of the follow-up security review,
fixed test-first.

### Security
- **GPTK imports verify the whole payload, not one file.** The importer used
  to check a single anchor dylib's Apple signature and then copy the entire
  directory; a crafted DMG could ride unsigned libraries in beside a genuine
  Apple file. Every Mach-O in the payload is now individually verified,
  symlinks may not escape the payload, and the anchor is pinned to its known
  Apple signing identifier.
- **The release pipeline is pinned to content.** Sparkle is locked to an
  exact version with the resolution file committed, the appcast tool
  download is checksum-verified before it runs near the update-signing key,
  and GitHub Actions reference full commit SHAs instead of movable tags.
- **Icon extraction from dropped .exe files is bounded.** Crafted resource
  trees with self-referencing directories no longer hang or crash the app,
  and icon assembly caps entry count and total bytes.
- **The Steam runtime download now ships its licenses.** The bundle carries
  the license texts and a per-component THIRD-PARTY-NOTICES file with
  source-code pointers for the Wine engine, DXMT, and every bundled library.

### Fixed
- **Running games are recognized after relaunching GameMaster.** Programs
  keep running when the app quits (by design); the app now shows them as
  running on relaunch instead of offering Play again, and stop requests
  verify the processes actually ended instead of assuming success.
- **A failed Retina toggle stays retryable.** The Wine registry is updated
  first and the setting saved only on success; previously a regedit failure
  left the saved setting permanently out of sync with Wine.
- **Runtimes no longer vanish after a crash or a corrupt metadata file.**
  A crash mid-replace is repaired at startup from the on-disk backup,
  corrupt runtime metadata is reported instead of silently hidden (both
  used to trigger a pointless re-download), metadata writes are atomic,
  and a failed GPTK overlay leaves the runtime exactly as it was.
- Adding or removing a program no longer overwrites bottle changes made
  concurrently (the last snapshot-save holdouts are now transactional).

## [0.3.6] — 2026-07-13

### Fixed
- **Saving bottle settings no longer freezes the sheet.** A Retina change
  re-runs wine's registry tool, which can cold-boot the prefix for seconds;
  the sheet now closes immediately and the work continues in the background
  (errors still surface in the main window).
- **Creating a bottle shows progress.** wineboot takes seconds — much longer
  right after a runtime download, while Rosetta first translates the wine
  binaries — and the click used to feel ignored.
- **"New Bottle" moved into the sidebar footer.** As a window-toolbar item it
  migrated into a "»" overflow menu after collapsing and reopening the
  sidebar (a NavigationSplitView quirk); the bottom-of-list button is also
  the Finder/Notes convention.
- The Advanced section of Bottle Settings is no longer cramped (proper row
  spacing) and its header toggles from the whole row, not just the tiny
  chevron.
- Toolbar buttons show their titles alongside icons — macOS tooltips take
  over a second to appear (a system-wide delay), so icon-only buttons left
  their purpose guessable.

## [0.3.5] — 2026-07-13

A hardening release: every finding of an independent full-codebase review,
verified and fixed test-first.

### Fixed
- **Changes made during a long install no longer vanish.** Installers and the
  settings sheet used to save whole-bottle snapshots taken minutes earlier;
  renaming a bottle mid-install (or leaving settings open through one) lost
  one side's changes. All writers now apply only their own fields on the
  bottle's current state, transactionally inside the store.
- **Deleting a bottle is guarded**: refused while an install writes into it,
  and refused while Windows programs are running in it. A deleted bottle can
  no longer be resurrected as a "ghost" by an install finishing late.
- **The Retina toggle now works on existing bottles.** It lives in the Wine
  registry, which was only written at bottle creation; changing it later
  saved JSON and did nothing. The registry tweak is re-applied on change.
- **Steam install retries are no longer poisoned by old failures**: Steam's
  bootstrap log is append-only across attempts, and failure lines from a
  previous bad-network run made every retry declare "offline" instantly.
  Only failures new to the current attempt count now.
- **Play/Run Once failures are reported.** A program dying right after
  launch used to flick the card back to idle silently; it now surfaces the
  exit code (late nonzero exits from quitting games stay ignored).
- **Running games survive an app restart — visibly.** GameMaster now detects
  live wineservers per bottle on launch (via the lock wineserver holds, not
  stale directories), shows a green dot, and won't delete a bottle out from
  under a running game.
- **Replacing a runtime can't lose the old one**: the previous
  remove-then-move had a window where a crash deleted the runtime outright;
  it's now a backup-swap with rollback.
- Corrupt bottle metadata is reported to the user instead of silently hiding
  the bottle; metadata writes are atomic so crashes can't truncate them.
- The PE icon parser survives crafted/truncated executables (64-bit bounds
  arithmetic, memory-mapped reads, 256 MB size gate) instead of crashing
  the app.
- `release.sh` fails closed when Sparkle's appcast tool is missing and
  removes stale appcasts up front.

### Security
- **DMG imports are signature-verified.** The D3DMetal import now requires
  the payload to be signed by Apple before any file is copied into the
  runtime, and auto-detected disk images show their full path in a
  confirmation dialog first. Detection alone was name-based — a look-alike
  DMG in ~/Downloads could previously plant executable code.

### Changed
- The app version is now single-sourced from `project.yml` (the committed
  Info.plist references build settings; CI fails on drift).
- DXMT bottles no longer offer a "DirectX translation: Off" that silently
  did nothing (DXMT is built into Wine itself); the ⓘ text explains why.
- NOTICE/README/SECURITY now describe the runtime licensing story exactly:
  GameMaster re-hosts no Apple code; the default community runtime includes
  Apple's evaluation libraries as its own project packages them; the Steam
  runtime's Sikarugir/DXMT components are fully attributed with pinned
  sources.

## [0.3.4] — 2026-07-13

### Added
- **Graceful Stop button** on running program cards. Steam gets its own
  `-shutdown` command routed through the running instance (saves state, syncs
  the cloud); other programs receive WM_CLOSE via `taskkill` — the same as
  clicking the window's close button, so they can show their own save dialogs.
  "Force Stop All" in the toolbar remains the hard kill for stuck processes.
- Product Hunt launch badge in the READMEs.

### Changed
- Launch logs are now pruned to the 10 most recent per bottle (Wine sessions
  are chatty; unbounded logs quietly ate disk).
- The window-lifecycle poll relaxes to a 3-second interval while a game is
  running (it previously woke every second for the whole play session).

## [0.3.3] — 2026-07-12

### Fixed
- **The real reason fresh installs sat at "Configuring…" for the client's
  whole lifetime**: launching Steam fire-and-forget (`wine start /unix`) waited
  for the output pipe to reach EOF — but the `start` helper exits instantly
  while Steam inherits the pipe, so the await only returned when Steam itself
  died (e.g. the user dismissing a fatal dialog). The readiness poll never even
  started; not even the timeout could fire. Fire-and-forget launches no longer
  capture output (no pipe, completion = helper exit), pinned by a regression
  test that fails in 30 s of hang without the fix.
- **Steam CDN failures now fail fast with a clear message.** The bootstrap
  watches Steam's own `bootstrap_log.txt` for terminal failure lines ("Steam
  needs to be online to update", "Failed to determine download location" — the
  live-lock where two packages 404 but the updater keeps spinning). Each hit
  triggers an immediate relaunch (CDN hiccups are transient — verified: a
  failed round succeeded on relaunch); once the retry budget is spent the
  install stops with a network error instead of burning the 15-minute timeout.
- **"The Steam installer failed (exit code 2)" on reinstall**: a previous
  failed attempt can leave the client running in the bottle (quitting the app
  doesn't always kill wine children), and the NSIS installer can't replace the
  locked files. The bottle is now stopped before the installer runs.
- Error messages from the engine (install failures, runtime errors, launch
  errors) are now localized in all four languages — they were English-only,
  and the CI localization gate now covers the engine sources too.

## [0.3.2] — 2026-07-12

### Fixed
- **Fresh Steam installs actually work now.** Two independent bugs, both
  reproduced end-to-end on a pristine bottle and fixed:
  - The first-run bootstrap was launched with `-noverifyfiles` (a day-to-day
    startup speedup), which makes Steam's bootstrapper *skip installation
    verification* — but on a fresh install, verification is exactly what
    triggers the client download. The bootstrapper concluded the stub install
    was fine, steam.exe tried to load the not-yet-downloaded steamui.dll, and
    died with "Failed to load steamui.dll". Confirmed in `bootstrap_log.txt`
    ("Verification skipped"). The bootstrap now launches with `-allosarches`
    only (catalog `bootstrap.launchArguments`); regular launches keep
    `-noverifyfiles`. Installs that worked before were all bottles
    bootstrapped by v0.1.0–0.1.2, which predate the flag.
  - Even with the download running, the install stayed at "Configuring…"
    forever: the readiness poll checked the file size via
    `URL.resourceValues`, which **caches on the URL object** — the poll reused
    one URL, read "missing" once, and never saw steamui.dll finish
    downloading. The poll now stats the file fresh each round
    (`FileManager.attributesOfItem`).

### Added
- Bottles can be **renamed** in Bottle Settings (name field at the top).

## [0.3.1] — 2026-07-12

### Fixed
- **Fresh installs no longer hang at "Configuring Steam"** when Steam's first
  self-update dies (the "Failed to load steamui.dll" dialog, most often seen
  on clean machines with flaky access to Steam's CDN). The bootstrap now
  watches the client's install tree for download activity; if nothing is
  written for a minute it kills the dead client and relaunches it (up to 3
  times) — Steam resumes the download where it stopped. If the download still
  can't finish, the install fails with the existing "check your connection"
  error instead of appearing stuck.

## [0.3.0] — 2026-07-12

### Fixed
- **D3D11 games launched through Steam (e.g. CS2) now render via Metal.** The
  Steam bottle's run runtime is now `sikarugir-10.0-6-dxmt-0.80`: a Sikarugir
  Wine 10 engine with DXMT 0.80 (Direct3D 10/11 → Metal) preinstalled as wine
  builtins. Verified end-to-end: CS2 reaches gameplay (bot match on Dust 2)
  with full rendering. Existing Steam bottles migrate automatically on next
  launch — the new runtime is downloaded and the bottle switched over, games
  and login stay in place.
  - Why the engine swap: DXMT needs `macdrv_functions` from wine's macOS
    driver to create its Metal presentation layer. Vanilla Gcenx builds strip
    that symbol (verified: metal-view creation fails); the Sikarugir engine
    exports it. The engine still fixes the steamwebhelper restart loop the
    same way Wine 11 did (verified: startcount stays 0).
  - The runtime tarball is assembled by `scripts/assemble-steam-runtime.sh`
    (engine + wrapper-template dylibs + DXMT, all sha256-pinned) and hosted as
    a GameMaster release asset, itself sha256-pinned in the runtime manifest.

### Changed
- Steam bottles get performance tuning when switching to the run runtime:
  **msync** (Mach-port synchronization, faster than esync; supported by the
  CrossOver-derived Sikarugir build) and **Rosetta AVX advertising** (Source 2
  ships AVX-optimized code paths). Both applied by catalog data
  (`runTuning`), not hard-coded.
- **MetalFX upscaling now works on both translation layers**: on DXMT runtimes
  the toggle enables DXMT's spatial swapchain upscaler
  (`DXMT_METALFX_SPATIAL_SWAPCHAIN`, renders internally at lower resolution
  and upscales — a large FPS gain); on GPTK runtimes it activates D3DMetal's
  DLSS-to-MetalFX shims, which previously shipped in the app but were never
  wired up (nvngx preparation now runs on launch).
- Every expert bottle setting now has an ⓘ explanation popover (Retina,
  DirectX translation, MetalFX, sync mode, Metal HUD, AVX, DXR), and the sync
  picker is reordered fastest-first (MSync → ESync → None).

### Added
- **Language picker** in Settings → General: follow the system (default) or
  force English / 简体中文 / 繁體中文 / 日本語 / 한국어, with one-click relaunch.

### Removed
- The `d3dMetal` DirectX-backend value (identical in behavior to Automatic and
  never exposed in the UI). Bottles that saved it fall back to Automatic.

## [0.2.1] — 2026-07-12

### Added
- Launch feedback on the program card: clicking Play now shows a **Starting…**
  spinner from click until the program's window appears (Steam's cold start
  under Wine takes tens of seconds), and a **Closing…** spinner after you quit
  until the process has fully exited and the button re-enables. Window detection
  uses window owner names only, so it needs no Screen Recording permission.

### Known limitations
- D3D11 games launched through the Steam client (e.g. **CS2**) currently fail
  with "Failed to create DirectX 11 render device" — the Wine 11 run runtime has
  no D3D→Metal layer (D3DMetal belongs to GPTK). Adding Metal-backed D3D (DXMT or
  DXVK) to the Steam bottle, or moving to a single wine32on64 runtime, was tracked
  in the project's internal engineering notes (resolved in 0.3.0).

## [0.2.0] — 2026-07-12

### Added
- Existing Steam bottles created before the fix are migrated automatically on
  launch: the newer Wine runtime is downloaded, the web-helper wrapper is
  installed, and the bottle is switched over — with a progress bar on the Steam
  card during the one-time upgrade. No reinstall needed.

### Fixed
- Steam client UI is now actually usable (reaches and stays on the login
  screen). Three separate failures were blocking it, each fixed:
  - **steamwebhelper restart loop** — GPTK's Wine is 7.7 (2022), too old for
    modern Steam's Chromium-126 CEF handshake, so the web helper never signaled
    ready and Steam restarted it every ~10s forever. The Steam bottle now runs
    under a newer Wine (`wine-staging-11.10`, added as a second runtime), where
    the handshake completes.
  - **Black login window** — CEF's GPU compositor never completes under Wine.
    A small PE wrapper (`steamwebhelper_wrapper.exe`) replaces Steam's web
    helper and injects `--disable-gpu --disable-gpu-compositing` so CEF renders
    in software. The wrapper is reinstalled on every launch in case a Steam
    self-update overwrote it.
  - **First-run download died** — Steam's 32-bit `steamservice.exe` crashes
    (null deref) under modern Wine's new WoW64, aborting the first client
    download before `steamui.dll` arrives. Steam now installs and bootstraps
    under GPTK (whose older 32-bit path works), then the bottle switches to the
    newer Wine only for running. `steamservice.exe` still can't run there, but
    it's not needed for login — its error dialog is harmless and can be closed.
- Stray black console window next to the Steam UI: the web-helper wrapper is now
  built as a GUI-subsystem PE (`-mwindows`), so Wine no longer opens a console
  window for it.
- Recurring "Steam Service Error" dialog on launch: Steam's 32-bit
  `steamservice.exe` (which null-derefs under new WoW64) is replaced with a no-op
  stub that registers a dummy service and exits cleanly. The service is only
  needed for elevated installs, not login/downloads, so the dialog is gone with
  no functional loss for the client UI. Like the wrapper, the stub self-heals on
  every launch if a Steam update overwrites it.
- Full write-up in the project's internal engineering notes.

## [0.1.3] — 2026-07-12

### Fixed
- "Steamwebhelper is not responding" infinite restart loop: removed the
  obsolete `-cef-force-32bit` launch flag. Steam removed 32-bit CEF in 2024,
  so the flag no longer selects a 32-bit web helper (the client only ships
  cef.win64) and sending it to a current client throws steamwebhelper into a
  restart loop. New Steam entries launch with `-allosarches -noverifyfiles`;
  the flag is also stripped at launch from programs pinned by older versions.

## [0.1.2] — 2026-07-12

### Added
- Program cards now show the real icon extracted from the Windows executable
  (native PE resource parsing — works for Steam and any dropped .exe). Icons
  are extracted lazily for programs added before this release.
- Fallback cards use a per-program color gradient monogram instead of the
  plain letter tile.

## [0.1.1] — 2026-07-12

### Fixed
- Steam failed with "Failed to load steamui.dll": the installer pre-wrote
  `steam.cfg` (`BootStrapperInhibitAll=Enable`), which blocked Steam's first
  bootstrap self-update. The config file is no longer written; Steam now
  completes its initial update normally.
- Tiny fonts in Windows programs on Retina displays: Retina mode now pairs
  `RetinaMode=y` with 2x Windows DPI (`LogPixels=192`), so UI renders at the
  correct size. Disabling Retina restores 96 DPI.

## [0.1.0] — 2026-07-12

### Added
- Initial release of GameMaster: a native macOS app to run Windows games via
  Apple's Game Porting Toolkit.
- One-click install of Steam for Windows, and running any Windows `.exe`/`.msi`.
- Downloadable open-source Wine runtime (SHA-256 verified) with built-in
  DirectX 11/12 translation.
- Optional import of Apple's D3DMetal evaluation layers from a user-supplied DMG
  (never bundled or redistributed).
- Bottle management, per-bottle graphics/performance settings with progressive
  disclosure (Retina, sync mode, MetalFX, ray tracing, environment variables).
- Program library with drag-and-drop, launch logging, and process control.
- First-run onboarding wizard with Rosetta 2 detection.
- Auto-update via Sparkle; signed and notarized releases.
- Localization: English, Simplified Chinese, Traditional Chinese, Japanese,
  Korean.
