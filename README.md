# Kith

Kith is a macOS menu bar app for people who run Claude Code and Codex locally. It shows which sessions are working, which need your input and which just finished. It notifies you with a button that jumps straight to the session. It can keep your Mac awake while agents work.

It watches four surfaces: Claude Code in the terminal, Claude Code inside Claude Desktop, the Codex CLI and Codex Desktop.

- **Menu bar panel.** Sessions that need attention come first, followed by a short preview of working sessions and power controls.
- **Notifications.** "Needs input", "Finished" and "Failed" alerts say which session and why, such as "Approve Bash · Claude CLI". Each one has an Open button for the terminal, Claude or the Codex thread.
- **Keep awake.** Kith holds idle sleep while agents work and for a few minutes after. With the optional privileged helper, it can also keep the Mac awake with the lid closed.
- **Finish actions.** Kith can put the Mac to sleep or shut it down once all work is done, after a cancelable 60-second countdown.

Kith never reports work as finished while it can't confirm a session's state. Monitoring problems stay visible in the panel.

## Requirements

- macOS 14 or later
- To build: Xcode 26 or Command Line Tools 26 (the macOS 26 SDK). The built app runs on macOS 14 and later.
- Claude Code and/or Codex installed locally

Kith builds for your Mac's architecture. It is developed and tested on Apple Silicon.

## Install from source

There are no prebuilt downloads yet.

```sh
git clone https://github.com/whysosaket/kith.git
cd kith
scripts/create-signing-identity.sh   # once; recommended, see Signing
scripts/build-app.sh                 # produces dist/Kith.app
cp -R dist/Kith.app /Applications/
open /Applications/Kith.app
```

Install to `/Applications` before you install hooks. Hooks point at the `kith-event` binary inside the app, so moving the app later means reinstalling them.

### Signing

`create-signing-identity.sh` adds a self-signed "Kith Local Signing" identity to your login keychain, and `build-app.sh` picks it up automatically. macOS then sees each rebuild as the same app, so Notifications and Accessibility permissions survive rebuilds. The identity never leaves your Mac. Set `KITH_LOCAL_IDENTITY` to use a different name.

Without an identity, builds are ad hoc signed and macOS treats every rebuild as a new app. Accessibility may then stay switched on while macOS rejects the new binary. Remove Kith from System Settings → Privacy & Security → Accessibility and add it again after each ad hoc build.

The closed-lid helper only accepts a Kith app signed by the same Apple Developer team as the helper. That requires an Apple-issued identity, for example `KITH_SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh`. Monitoring, notifications and idle-sleep holding all work with self-signed builds.

## First run

1. **Hooks.** Open Kith → Settings → Monitoring → **Install hooks**. Then run `/hooks` in Codex and trust the new entries.
2. **Notifications.** Allow Kith in System Settings → Notifications, including sounds. Kith warns you in the panel when macOS disables either.
3. **Accessibility (optional, Codex Desktop only).** Codex Desktop doesn't report every prompt through hooks. With Accessibility access, Kith reads the **button titles** in Codex Desktop windows, such as "Approve" and "Deny", to tell when it's waiting for you. It reads nothing else and no other app.
4. **Power helper (optional).** Settings → Power → enable the helper and approve it under System Settings → General → Login Items & Extensions. See [Power and safety](#power-and-safety).

## How it works

- **Hooks.** Kith adds entries to `~/.claude/settings.json` and `~/.codex/hooks.json` that run `Kith.app/Contents/MacOS/kith-event`. Claude Code and Codex pass each hook event to that small binary on standard input. It keeps only the session ID, event name, working directory, turn and tool-call IDs, tool name, whether background tasks are running, and which terminal app owns the session. It then sends them to Kith over a user-only Unix socket. Prompts, tool inputs and tool outputs are dropped immediately.
- **Local scan.** Every 2 seconds Kith reads the agents' local session files to confirm state, including sessions that started before Kith. It catches anything a hook missed.
- **Install and remove.** Installing hooks backs up each file once (to `settings.json.kith-backup` and `hooks.json.kith-backup`). Kith writes through symlinks and keeps the file's permissions. **Remove hooks** deletes only Kith's entries.

## Privacy

Kith makes no network requests. Everything stays on your Mac.

To work out session state, Kith **reads**:

- Claude Code session metadata (`~/.claude/sessions/*.json`, Claude Desktop's `claude-code-sessions`), including session titles and working directories
- the last 128 KB of the current Claude Code transcript (`~/.claude/projects/**/*.jsonl`), where it looks only at message types and stop reasons
- Codex's local SQLite databases (`~/.codex/thread_history_1.sqlite`, `~/.codex/state_5.sqlite`), where it reads turn status and each thread's source, working directory, generated name and rollout path
- the last 256 KB of the current Codex rollout file (`~/.codex/sessions/**`), where it looks only at event types and call IDs
- button titles in Codex Desktop windows, if you grant Accessibility

Kith **stores** only session IDs, statuses and timestamps (`sessions.json`), plus the IDs of notifications it already sent (`state.json`). Both are in `~/Library/Application Support/Kith`. It doesn't save prompts, transcripts, tool arguments or credentials.

Notification text includes session titles and project folder names. Agents often generate titles from your first prompt. macOS keeps notifications in Notification Center and may show them on the lock screen, so adjust Kith's notification settings in System Settings if that matters to you.

## Power and safety

- **Idle sleep.** While any session is working, and for the extra time set in Settings, Kith holds a standard power assertion that stops idle sleep.
- **Closed lid.** The privileged helper runs as root and temporarily sets macOS's global `SleepDisabled` flag through `pmset`. It only takes this on a 45-second lease that the app keeps renewing, and restores the previous value when the lease ends or the app crashes. Don't run another closed-lid utility at the same time.
- **Finish actions.** Sleep and shutdown are one-shot. They start a cancelable 60-second countdown only after every monitored session is confirmed finished, and a new turn cancels it. Shutdown can lose unsaved work in other apps, so save first. These actions stay locked until you run the checks in [`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md) on your Mac and switch them on in Settings. That switch is your own sign-off; Kith can't verify it.

## Compatibility

Claude Code and Codex don't publish a stable API for session state, so Kith relies on their current local files. It reads:

- hook event names and payloads;
- Claude session JSON and transcript line types;
- Codex's `thread_turns` and `threads` tables and rollout event types;
- Codex Desktop's English button titles;
- the `codex://threads/` link format.

When one of these changes, Kith marks that surface **unavailable**, blocks finish actions, and never assumes the work is done. Please [open an issue](https://github.com/whysosaket/kith/issues) when that happens.

## Uninstall

1. Settings → Monitoring → **Remove hooks**.
2. Settings → Power → disable the helper, if you enabled it.
3. Quit Kith and delete `/Applications/Kith.app` and `~/Library/Application Support/Kith`.

## Troubleshooting

- **Codex Desktop shows as unavailable after a rebuild:** remove Kith from Accessibility and add it again, or use a signing identity (see [Signing](#signing)).
- **Notifications show a blank icon instead of the Kith logo:** macOS cached an icon from an older or icon-less copy. Restart the Mac. If that doesn't fix it, run `sudo rm -rf /Library/Caches/com.apple.iconservices.store` and then `killall Dock NotificationCenter usernoted`.
- **Codex events never arrive:** run `/hooks` in Codex and trust Kith's hooks.

## Development

```sh
scripts/test.sh        # unit tests (Swift Testing) + core smoke checks
scripts/build-app.sh   # app bundle in dist/
xcodegen generate      # regenerate Kith.xcodeproj after editing project.yml
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for details. Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Kith is an independent project and isn't affiliated with or endorsed by Anthropic or OpenAI. Claude, Claude Code and Codex are trademarks of their respective owners.
