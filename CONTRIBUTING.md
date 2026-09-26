# Contributing to Kith

Thanks for helping. Bug reports, compatibility fixes for new Claude Code or Codex versions, and small focused PRs are the most useful contributions.

## Setup

You need macOS 14+ and a Swift 6 toolchain. Command Line Tools are enough; Xcode is optional.

```sh
scripts/create-signing-identity.sh   # once, so permissions survive rebuilds
scripts/test.sh                      # unit tests + smoke checks
scripts/build-app.sh                 # dist/Kith.app
```

`Kith.xcodeproj` is generated from `project.yml`. If you change targets, settings or identifiers, edit `project.yml`, run `xcodegen generate` (`brew install xcodegen`), and commit both. CI fails when they drift apart.

## Layout

- `Sources/KithCore`: session state machine, hook parsing and installation, the local scan, and the event socket. Most logic and all tests live here.
- `Sources/KithApp`: the SwiftUI menu bar app, notifications and power client.
- `Sources/KithEvent`: `kith-event`, the tiny binary the agents' hooks run.
- `Sources/KithPowerHelper`: the optional root helper for closed-lid mode.
- `Tests/`: Swift Testing unit tests and the `Tests/Smoke` checks run by `scripts/smoke-core.sh`.

## Pull requests

- Keep each PR to one change. Match the surrounding code style.
- Add or update a test in `Tests/` for any change to `KithCore`.
- Run `scripts/test.sh` and `scripts/build-app.sh` before opening the PR.
- For changes to how Kith reads Claude Code or Codex state, say which agent versions you tested.
- Changes to the power helper, hooks or event socket get extra review. Explain the safety impact in the PR.

Kith must never report work as finished when it cannot confirm it. When a format changes, prefer marking a surface unavailable over guessing.

## Reporting bugs

Open an issue with your macOS version, Claude Code / Codex versions, which surface (CLI or Desktop), and steps to reproduce. Report security problems privately; see [SECURITY.md](SECURITY.md).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
