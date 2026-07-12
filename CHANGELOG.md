# Changelog

All notable changes to GameMaster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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
- Full write-up in `docs/steam-webhelper-resolution.md`.

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
