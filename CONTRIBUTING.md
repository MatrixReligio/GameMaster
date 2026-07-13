# Contributing to GameMaster

Thanks for your interest! GameMaster aims to make running Windows games on a Mac
effortless for ordinary users, and contributions of all kinds are welcome.

## Ground rules

- **Test-driven.** Write the failing test first, watch it fail, then implement.
  The core (`Sources/GM*`) is fully testable without Xcode via `swift test`.
- **Keep it native and simple.** Follow the macOS Human Interface Guidelines.
  Default paths must stay one-click; expert options belong behind progressive
  disclosure.
- **Don't re-host proprietary components in this repository.** This repo and
  GameMaster's own release assets contain no Apple proprietary code. Runtimes
  are fetched at runtime from their upstream projects via the manifest, not
  committed here — the default is a community Game Porting Toolkit build that
  packages Apple's D3DMetal, and newer D3DMetal can additionally be imported
  from Apple's evaluation-environment DMG. PRs that vendor proprietary
  components into this repo will be declined. See [SECURITY.md](SECURITY.md).
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
