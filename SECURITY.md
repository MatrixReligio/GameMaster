# Security Policy

GameMaster runs third-party Windows programs through a Wine-based runtime and
downloads runtime components over the network. We take its security seriously
and appreciate responsible disclosure.

## Supported versions

> **Note:** GameMaster is an early-stage project. Only the latest released
> version receives security fixes.

| Version | Supported |
|---------|-----------|
| latest  | ✅        |
| older   | ❌        |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Instead, report privately by email to:

**[contact@matrixreligio.com](mailto:contact@matrixreligio.com)**

Include:

- A description of the issue and its impact.
- Steps to reproduce (a proof of concept if possible).
- The GameMaster version, macOS version, and hardware.

We aim to acknowledge reports within a few days and to ship a fix as promptly as
the severity warrants. If you'd like to encrypt your report, say so in an
initial email and we'll arrange a key.

## Design principles that limit attack surface

- **No proprietary re-hosting.** This repository and GameMaster's own release
  assets contain no Apple proprietary components. The default runtime is a
  community Game Porting Toolkit build downloaded from its own project's
  releases (which includes Apple's D3DMetal evaluation libraries as that
  project packages them); optional D3DMetal updates are imported from Apple's
  own disk image, are verified to be signed by Apple before any file is
  copied, and stay on the user's machine.
- **Verified downloads.** Every runtime download is pinned to an exact URL and
  verified against a SHA-256 digest before it is unpacked and executed.
- **No telemetry, no account, no server.** GameMaster has no analytics and
  makes no network calls except downloading the runtime you asked for, fetching
  an installer you chose to run (e.g. Steam's official setup), and checking for
  its own updates.
- **Signed & notarized.** Releases are signed with an Apple Developer ID and
  notarized by Apple; auto-updates are verified with an EdDSA signature.

## A note on running Windows software

GameMaster runs arbitrary Windows programs you choose, inside a Wine prefix.
That prefix is **not** a strong security sandbox — treat programs you run in a
bottle with the same caution you'd apply to running them on Windows. Only
install software from sources you trust.
