# Changelog

All notable changes to GameMaster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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
