# Contributing to GameMaster

Thanks for your interest! GameMaster aims to make running Windows games on a Mac
effortless for ordinary users, and contributions of all kinds are welcome.

## Ground rules

- **Test-driven.** Write the failing test first, watch it fail, then implement.
  The core (`Sources/GM*`) is fully testable without Xcode via `swift test`.
- **Keep it native and simple.** Follow the macOS Human Interface Guidelines.
  Default paths must stay one-click; expert options belong behind progressive
  disclosure.
- **Don't vendor proprietary components in this repository.** Runtimes — Wine
  builds and the open-source DXMT translation layer — are fetched from their
  upstream sources at runtime via the runtime manifest, not committed here.
  Apple's proprietary D3DMetal is never bundled; it is user-imported from the
  evaluation-environment DMG. PRs that vendor it will be declined.
- **Localize user-facing strings** with `String(localized:)` and add every key
  to `scripts/gen-localizations.py` for all supported languages.

## Development setup

```bash
brew install xcodegen swiftlint swiftformat
swift test                     # core tests
python3 scripts/check-localizations.py
swiftlint lint --strict
swiftformat --lint .
xcodegen generate && open GameMaster.xcodeproj
```

## Pull requests

1. Fork and branch from `main`.
2. Make your change with tests. Keep commits focused and messages descriptive.
3. Ensure `swift test`, SwiftLint, SwiftFormat, and localization coverage pass —
   CI enforces all four on macOS 26.
4. Open a PR describing the change and the motivation.

## Reporting bugs

Use the issue templates. For crashes, include the log from **Bottle → Logs → Show
in Finder** and your macOS + chip model. Please don't paste license keys or
account credentials.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to uphold it.
