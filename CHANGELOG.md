# Changelog

All notable changes to GameMaster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
