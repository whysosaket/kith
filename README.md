# Kith

Kith is a personal macOS menu bar companion for local Claude Code and Codex sessions. It displays session state, sends attention and completion notifications, can hold idle sleep while agents work, and offers a one-shot sleep or shutdown countdown.

The menu bar popover has an Overview tab for alerts and power controls, and a Sessions tab that groups running sessions first, then sessions needing input and other recent sessions. Both tabs show unavailable monitors; the Sessions tab does not claim work is finished while a monitor is unavailable.

## Build

On macOS 14 or later with Swift 6, run `scripts/build-app.sh`. The result is `dist/Kith.app`. Open `Kith.xcodeproj` in Xcode to build the signed app and run its tests. The project is generated from `project.yml` with `xcodegen generate`. Full Xcode is required for the XCTest target and signing workflow. This Mac currently has only Command Line Tools, so use the build script until Xcode is installed.

For closed-lid work, set `KITH_SIGN_IDENTITY` to an Apple-issued code-signing identity when building. The app and helper must use the same identity. Enable the helper in Kith settings and approve it in System Settings. The hidden `SleepDisabled` setting still needs physical validation on the target Mac before relying on it.

Ad hoc builds change their code identity when rebuilt. macOS may leave Kith's Accessibility switch on while rejecting the updated binary; turn that switch off and on again after an ad hoc update. A stable signing identity avoids repeated privacy grants.

## First run

Open Kith, then use Settings → Install hooks. Review and trust the Codex hooks with `/hooks` in Codex. Enable Kith under System Settings → Notifications, including notification sounds. Kith shows a warning when macOS disables its notifications or sounds. It only writes its own hook entries to `~/.claude/settings.json` and `~/.codex/hooks.json`; Remove hooks removes those entries while preserving unrelated settings.

Kith reads local session metadata. It does not save prompts, transcripts, tool arguments, or credentials. A monitor shown as unavailable blocks automatic power actions. Grant Accessibility for the Codex Desktop fallback. Its prompt detection and closed-lid behavior still need live acceptance tests before relying on automatic power actions.

## Safety

Sleep and shutdown are one-shot and use a cancelable 60-second countdown. A new turn cancels the countdown. Shutdown can discard unsaved work in other apps. Save work before arming it. Do not run another closed-lid utility while Kith owns the global sleep setting.

Finish actions stay locked until the target-Mac checks in `docs/ACCEPTANCE.md` are completed and enabled in Settings.
