# Kith

**See when your coding agents need you, right from the Mac menu bar.**

Kith tracks Claude Code and Codex across their CLI and desktop apps. See what’s working, waiting, or finished, and jump straight to a session from its notification.

**[Download Kith for macOS](https://github.com/whysosaket/kith/releases/latest/download/Kith-macOS-universal.dmg)** · [ZIP and checksums](https://github.com/whysosaket/kith/releases/latest) · [User guide](docs/USER-GUIDE.md)

<p align="center">
  <img src="docs/screenshots/readme/menu-bar.webp" width="430" alt="Kith’s macOS menu bar popover opens to show a live awake timer, a session that needs input, and working sessions, then closes">
</p>

*Screenshots and demos from the current source build, using sample sessions.* [Menu bar GIF](docs/screenshots/readme/menu-bar.gif)

## What you can do

- **Catch approval prompts and failures.** Sessions that need input appear first. Open the right terminal tab or desktop session with one click.
- **Keep your Mac awake.** Hold off idle sleep while agents work or start a timer from the menu bar. Protection ends at its deadline, on low battery, or at critical heat.
- **Decide what happens after work.** Arm sleep or shutdown in **After work**. Kith starts a cancelable countdown once it confirms every session is finished.

Session monitoring runs locally. Kith drops prompts and tool payloads, and marks a session’s status as unconfirmed when it can’t verify it. [Privacy details](docs/USER-GUIDE.md#privacy)

### Awake timer demo

![Animated demo of starting a one-hour timer, watching it count down, adding an hour, and ending the timer in Power settings](docs/screenshots/readme/awake-timer.webp)

[GIF version](docs/screenshots/readme/awake-timer.gif)

<details>
<summary>See the Sessions and After work screens</summary>

![Kith’s redesigned Sessions window, with a native sidebar and Claude Code and Codex sessions grouped by status](docs/screenshots/readme/sessions.webp)

![Kith’s After work page, showing the live validation checklist and the sleep and shutdown controls](docs/screenshots/readme/after-work.webp)

</details>

## Get started

1. On **macOS 14 or later** (Apple Silicon or Intel), open the DMG and drag Kith to **Applications**, then open it from there.
2. Open **Kith → Settings → Monitoring**, choose **Install hooks**, and allow Kith notifications in macOS. For Codex, run `/hooks` and trust the new entries.
3. Start a Claude Code or Codex session. Click Kith in the menu bar to see it.

The download is ad hoc signed and predates the redesign. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** after attempting to launch it. [Apple’s instructions](https://support.apple.com/102445)

### Install from source

Build with the macOS 26 SDK for the redesigned app. Use a signing identity to enable the optional helper for closed-lid work and finish actions. Sleep and shutdown require live validation on your Mac. [Build and signing instructions](docs/USER-GUIDE.md#install-from-source) · [Power and safety](docs/USER-GUIDE.md#power-and-safety) · [Live acceptance checks](docs/ACCEPTANCE.md)

## More

[Permissions and first run](docs/USER-GUIDE.md#first-run) · [Power CLI](docs/USER-GUIDE.md#power-cli-and-startup) · [Troubleshooting](docs/USER-GUIDE.md#troubleshooting) · [Uninstall](docs/USER-GUIDE.md#uninstall)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md) · [MIT License](LICENSE)

Kith is an independent project. Claude, Claude Code, and Codex are trademarks of their respective owners.
