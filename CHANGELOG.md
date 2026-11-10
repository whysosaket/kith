# Changelog

## Unreleased

- Add bounded automatic and manual wake periods, extension reminders, battery and thermal guardrails, and visible recovery status.
- Add display-awake mode, optional lid-close audio muting, network warnings, and browser-throttling diagnostics.
- Remove the closed-lid sleep override and automatic Low Power Mode. Recover settings saved by earlier versions and expire awake holds if Kith becomes unresponsive.
- Bundle the `kith power` CLI and add launch-at-login and user-initiated update settings.
- Add power policy, helper recovery, audio, request protocol, and debug app-to-CLI end-to-end tests.

## 0.1.0 (2026-09-30)

First public release.

- Menu bar panel and window for Claude Code (CLI and Claude Desktop) and Codex (CLI and Desktop) sessions
- Notifications for input requests, finished turns and failures, with an Open action that jumps to the session, down to its tab in Terminal and iTerm2
- Idle-sleep hold while agents work, optional closed-lid helper, and one-shot sleep or shutdown after work finishes
- Hook installer with one-time backups that preserves symlinks and permissions
- Power helper checks callers with a team-pinned code signing requirement; builds use hardened runtime
- Universal macOS DMG and ZIP downloads for Apple Silicon and Intel, with SHA-256 checksums
