# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub: **Security → Report a vulnerability** on [whysosaket/kith](https://github.com/whysosaket/kith/security/advisories/new). Don't open a public issue.

Include the Kith commit or version, your macOS version, and steps to reproduce. You should get a reply within a week.

## Scope

These parts matter most:

- **Power helper** (`Sources/KithPowerHelper`): runs as root and can sleep or shut down the Mac and change the global `SleepDisabled` setting. It only accepts connections from a Kith app signed by the same Apple Developer team, checked against the caller's audit token.
- **Event socket and spool** (`Sources/KithCore/EventSocket.swift`, `EventSpool.swift`): user-only files under `~/Library/Application Support/Kith` that decide what Kith believes about your sessions.
- **Hook installer** (`Sources/KithCore/HookInstaller.swift`): edits `~/.claude/settings.json` and `~/.codex/hooks.json`.
- **Local reads** (`Sources/KithCore/LocalReconciler.swift`): reads agent session files and transcripts to work out status.

Processes running as your own user can already send Kith fake session events. That is outside Kith's threat model, but reports showing that such events can cause a power action while work is still running are in scope.

## Supported versions

Only the latest commit on `main` and the latest release get security fixes.
