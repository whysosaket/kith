# Kith user guide

[Back to the README](../README.md)

## Build requirements

- macOS 14 or later
- Xcode 26 or Command Line Tools 26 with the macOS 26 SDK
- Claude Code and/or Codex installed locally

Kith builds for your Mac's architecture. It is developed and tested on Apple Silicon.

## Install from source

```sh
git clone https://github.com/whysosaket/kith.git
cd kith
scripts/create-signing-identity.sh   # run once
scripts/build-app.sh                 # produces dist/Kith.app
cp -R dist/Kith.app /Applications/
open /Applications/Kith.app
```

Install to `/Applications` before you install hooks. Hooks point at the `kith-event` binary inside the app, so moving the app later means reinstalling them.

## Signing

`create-signing-identity.sh` adds a self-signed "Kith Local Signing" identity to your login keychain, and `build-app.sh` picks it up automatically. macOS then sees each rebuild as the same app, so Notifications and Accessibility permissions survive rebuilds. The identity stays on your Mac. Set `KITH_LOCAL_IDENTITY` to use a different name.

Without an identity, builds are ad hoc signed and macOS treats every rebuild as a new app. Accessibility may then stay switched on while macOS rejects the new binary. Remove Kith from System Settings → Privacy & Security → Accessibility and add it again after each ad hoc build.

The power helper accepts apps signed by the same Apple Developer team or, for self-signed builds, with the exact same certificate. Ad hoc builds can't use it. Monitoring, notifications and idle-sleep holding work with any build. Without a team ID, macOS ties the helper's registration to that exact build, so after each rebuild choose **Disable helper** and then **Set up helper** in Settings → Power.

## First run

1. **Hooks.** Open Kith → Settings → Monitoring → **Install hooks**. Then run `/hooks` in Codex and trust the new entries.
2. **Notifications.** Allow Kith in System Settings → Notifications, including sounds. Kith warns you in the panel when macOS disables either.
3. **Accessibility (optional, Codex Desktop only).** Codex Desktop doesn't report every prompt through hooks. With Accessibility access, Kith reads only Codex Desktop **button titles** such as “Approve” and “Deny” to detect when it’s waiting for you.
4. **Automation (optional, Terminal and iTerm2).** The first time you open a CLI session, macOS asks whether Kith may control your terminal. Allow it and Kith brings that session's own window and tab to the front. Without that permission, Kith switches to the terminal app. Other terminals always get the app only.
5. **Power helper (optional, signed source builds only).** Settings → Power → **Set up helper** and approve it under System Settings → General → Login Items & Extensions. See [Power and safety](#power-and-safety).

## How it works

- **Hooks.** Kith adds entries that run `Kith.app/Contents/MacOS/kith-event` to `~/.claude/settings.json` and `~/.codex/hooks.json`, skipping any agent that isn't installed. Claude Code and Codex pass each hook event to that small binary on standard input. It keeps only the session ID, event name, working directory, turn and tool-call IDs, tool name, whether background tasks are running, and which terminal app and tab (its tty, such as `/dev/ttys003`) own the session. It then sends them to Kith over a user-only Unix socket. Prompts, tool inputs and tool outputs are dropped immediately.
- **Local scan.** Every 2 seconds Kith reads the agents' local session files to confirm state, including sessions that started before Kith. It catches anything a hook missed.
- **Install and remove.** Installing hooks backs up each file it changes once (to `settings.json.kith-backup` and `hooks.json.kith-backup`). Kith writes through symlinks and keeps the file's permissions. **Remove hooks** deletes only Kith's entries.

## Privacy

Session monitoring and power controls stay on your Mac. Network-availability monitoring observes the system's network path without sending connectivity probes. If you click **Check for updates** in Settings → General, Kith requests the latest stable release from GitHub's public API. That request sends a fixed Kith user agent and no session, prompt, project, or device data. Kith never checks automatically and never downloads or installs updates.

Kith **reads** local session state from these sources.

- Claude Code session metadata (`~/.claude/sessions/*.json`, Claude Desktop's `claude-code-sessions`), including session titles and working directories
- the last 128 KB of the current Claude Code transcript (`~/.claude/projects/**/*.jsonl`), where it looks only at message types and stop reasons
- Codex's local SQLite databases (`~/.codex/thread_history_1.sqlite`, `~/.codex/state_5.sqlite`), where it reads turn status and each thread's source, working directory, generated name and rollout path
- the last 256 KB of the current Codex rollout file (`~/.codex/sessions/**`), where it looks only at event types and call IDs
- button titles in Codex Desktop windows, if you grant Accessibility

For agent monitoring, Kith **stores** session IDs, statuses and timestamps (`sessions.json`), plus the IDs of notifications it already sent (`state.json`). Both are in `~/Library/Application Support/Kith`. It doesn't save prompts, transcripts, tool arguments or credentials.

Power controls additionally store preferences (`power-preferences.json`), the current wake period and stop reason (`power.json`), saved audio-device identities (`audio-recovery.json`), and up to 200 local diagnostic entries (`power-diagnostics.json`). These files are private to your account. Diagnostics describe power operations and errors, without agent prompts or browser command lines. Review copied diagnostics before sharing them.

Notification text includes session titles and project folder names. Agents often generate titles from your first prompt. macOS keeps notifications in Notification Center and may show them on the lock screen, so adjust Kith's notification settings in System Settings if that matters to you.

## Power and safety

- **Menu timer.** Open Kith in the menu bar to start an awake timer with a preset or custom hours and minutes. The live countdown shares its deadline with Settings and the CLI. Use **Add time** to extend it or **End** to release Kith's protection. At most 24 hours can remain. For agent-driven periods, the countdown shows the upper limit; protection can end earlier when work finishes.
- **Idle sleep.** While any session is working, and for the extra time set in Settings, Kith holds a standard power assertion that stops idle sleep.
- **Deadlines.** A wake period defaults to four hours and can be configured from one to 24 hours. A five-minute reminder offers time to extend it in Power. New turns, waiting prompts, and extra awake time cannot reset that period's deadline. Maximum-duration setting changes apply to the next period. Kith renews system and display assertions while it is responsive. Each renewal lasts up to 45 seconds, subject to the period's deadline. macOS releases the assertions when Kith exits. An expired period remains stopped across app restarts until you resume.
- **Battery and heat.** Warnings start at 20% battery and serious heat. On battery, protection stops at 10% by default. Choose 5%, 10%, or 15% in Power. Two consecutive unreadable battery observations also stop protection on battery. The second read occurs after 30 seconds if no battery event arrives. A Mac without a battery is exempt from battery rules. Critical heat stops protection on AC and battery. Plugging in or cooling down does not resume it automatically. These rules require the app to remain responsive.
- **Closed lid.** macOS decides whether the Mac sleeps on lid close. For closed-lid work, use a supported external display setup. [Apple's setup instructions](https://support.apple.com/en-us/102501)
- **Display wake.** Optional computer-use mode holds the display awake within the same deadline. It can leave the screen unlocked. An explicit lock still applies, and UI automation with the lid closed depends on the app.
- **Upgrading.** Earlier versions wrote system-wide sleep and Low Power Mode preferences. Those controls have been removed. If Power shows pending recovery, enable the power helper and use **Retry recovery** to restore the settings recorded by the earlier version. A system-wide sleep warning can also reflect a setting from outside Kith.
- **Audio.** Optional lid-close muting affects the current output when it provides a software mute control, preserving its device identity before muting. Unsupported outputs show an error and stay unchanged. Opening the lid, ending protection, or reopening Kith restores connected outputs. Disconnected outputs remain listed until they reconnect while Kith is open. **Stop waiting** drops that saved entry and leaves the device unchanged. Reopen Kith after an app crash to restore user audio.
- **Connectivity and browsers.** Optional network warnings appear after five seconds without an available network path during active work, and clear on recovery. An available path does not establish that an agent service is reachable. Browser diagnostics inspect launch options of supported running browsers for background throttling; they never quit or relaunch a browser.
- **Finish actions.** Sleep and shutdown are one-shot. They start a cancelable 60-second countdown only after every monitored session is confirmed finished, and a new turn cancels it. Shutdown can lose unsaved work in other apps, so save first. These actions stay locked until you complete the live checks on your Mac and turn on **Allow finish actions** in Settings → After work. That switch records your own sign-off. [Live acceptance checks](ACCEPTANCE.md)

Protective stops release Kith's wake holds and let agents continue running. Another app's wake assertion can still keep the Mac awake. Starting a manual period cancels an armed finish action, and manual periods, protective stops, or unresolved recovery block arming a new one.

## Power CLI and startup

Open Kith before using the bundled CLI. You can add an alias for it in your shell configuration.

```sh
/Applications/Kith.app/Contents/MacOS/kith power status --json
/Applications/Kith.app/Contents/MacOS/kith power start --for 2h
/Applications/Kith.app/Contents/MacOS/kith power extend --for 30m
/Applications/Kith.app/Contents/MacOS/kith power end
/Applications/Kith.app/Contents/MacOS/kith power resume
```

Durations accept whole seconds, minutes, or hours, from `1s` through `24h`. Commands return an acknowledgment and exit nonzero on failure. Status distinguishes requested protection from actual system/display holds and helper recovery. The CLI cannot arm sleep or shutdown. Requests expire after eight seconds. If an acknowledgment is lost, check status before retrying.

Settings → General includes **Launch Kith at login** and **Check for updates**. Disabling the login item in macOS Settings is respected. Update checks open a release page only when requested.

`KITH_HOME` changes the app's support directory and CLI inbox. Set it consistently for both processes. It does not relocate or sandbox the privileged helper, which still uses `/var/db/kith-power-state.json`.

## Compatibility

Kith relies on hook event names and payloads, Claude session JSON and transcript events, Codex’s `thread_turns` and `threads` tables and rollout events, English button titles in Codex Desktop, and `codex://threads/` links.

When one of these changes, Kith marks the affected surface **unavailable** and blocks finish actions. Please report the compatibility issue. [GitHub Issues](https://github.com/whysosaket/kith/issues)

## Uninstall

End awake protection, retry any pending recovery, and restore or stop waiting for disconnected audio outputs before removing the app. Disable Launch Kith at login in General if enabled. If the power helper cannot confirm restoration, keep it installed and resolve the warning first.

1. Settings → Monitoring → **Remove hooks**.
2. Settings → Power → **Disable helper**, if you enabled it.
3. Quit Kith and delete `/Applications/Kith.app` and `~/Library/Application Support/Kith`.

## Troubleshooting

- **Codex Desktop shows as unavailable after a rebuild.** Remove Kith from Accessibility and add it again, or use a signing identity (see [Signing](#signing)).
- **Notifications show a blank icon instead of the Kith logo.** macOS cached an icon from an older or icon-less copy. Restart the Mac. If that doesn't fix it, run `sudo rm -rf /Library/Caches/com.apple.iconservices.store` and then `killall Dock NotificationCenter usernoted`.
- **Codex events never arrive.** Run `/hooks` in Codex and trust Kith's hooks.

## Development

See the contributor guide for build, test, and Xcode project instructions. Run `scripts/package-release.sh` to produce the universal DMG, ZIP, and checksums in `dist/`. [Contributing](../CONTRIBUTING.md)

Report security issues privately. [Security policy](../SECURITY.md)

Power E2E tests do not change real sleep settings, audio, network connections, or login items. Debug fault injection requires both `KITH_E2E=1` and a `/tmp/kith-e2e-*` support path and is unavailable in release builds. Real-hardware checks remain in [live acceptance checks](ACCEPTANCE.md). Set `KITH_BUILD_SYSTEM` to select a local build system and `SDKROOT` to select an installed compatible SDK.
