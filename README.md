# Kith

Kith is a personal macOS menu bar companion for local Claude Code and Codex sessions. It displays session state, sends attention and completion notifications, can hold idle sleep while agents work, and offers a one-shot sleep or shutdown countdown.

The menu bar panel shows sessions needing attention first, then a short preview of working sessions and a compact Power disclosure. **Show all sessions** opens a resizable window with Sessions and Settings tabs. Settings contains Monitoring, Notifications, and Power. Monitoring issues stay visible in the panel and shared window; Kith does not claim work is finished while a monitor is unavailable.

## Build

On macOS 14 or later with Swift 6, run `scripts/build-app.sh`. The result is `dist/Kith.app`. Open `Kith.xcodeproj` in Xcode to build the signed app and run its tests. The project is generated from `project.yml` with `xcodegen generate`. Full Xcode is required for the XCTest target and signing workflow. This Mac currently has only Command Line Tools, so use the build script until Xcode is installed.

For closed-lid work, set `KITH_SIGN_IDENTITY` to an Apple-issued code-signing identity when building. The app and helper must use the same identity. Enable the helper in Kith settings and approve it in System Settings. The hidden `SleepDisabled` setting still needs physical validation on the target Mac before relying on it.

### Local signing

Run `scripts/create-signing-identity.sh` once before your first build. It creates a self-signed "Kith Local Signing" identity in your login keychain, and `scripts/build-app.sh` uses it automatically. macOS then recognizes each rebuild as the same app, so Accessibility and other privacy grants carry over. The identity is local to your Mac and is never committed. Set `KITH_LOCAL_IDENTITY` to use a different name.

Without it, the build falls back to ad hoc signing, which changes Kith's code identity on every rebuild. macOS may leave Kith's Accessibility switch on while rejecting the new binary, and Codex Desktop then shows as unavailable. Remove Kith from System Settings → Privacy & Security → Accessibility and add it again after each ad hoc build.

A self-signed identity is enough for monitoring and notifications. The closed-lid helper still needs an Apple-issued identity in `KITH_SIGN_IDENTITY`.

## First run

Open Kith, then use Settings → Monitoring → Install hooks. Review and trust the Codex hooks with `/hooks` in Codex. Enable Kith under System Settings → Notifications, including notification sounds. Kith shows a warning when macOS disables its notifications or sounds. If notifications show a blank icon instead of the Kith logo, macOS has cached an icon-less copy; run `sudo rm -rf /Library/Caches/com.apple.iconservices.store` and then `killall Dock NotificationCenter usernoted`. It only writes its own hook entries to `~/.claude/settings.json` and `~/.codex/hooks.json`; Remove hooks removes those entries while preserving unrelated settings.

Kith reads local session metadata. It does not save prompts, transcripts, tool arguments, or credentials. A monitor shown as unavailable blocks automatic power actions. Grant Accessibility for the Codex Desktop fallback. Its prompt detection and closed-lid behavior still need live acceptance tests before relying on automatic power actions.

## Safety

Sleep and shutdown are one-shot and use a cancelable 60-second countdown. A new turn cancels the countdown. Shutdown can discard unsaved work in other apps. Save work before arming it. Do not run another closed-lid utility while Kith owns the global sleep setting.

Finish actions stay locked until the target-Mac checks in `docs/ACCEPTANCE.md` are completed and enabled in Settings.
