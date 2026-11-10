# Kith acceptance checks

Run these on your own Mac before relying on finish actions. Keep **Allow finish actions** off in Settings → After work until every applicable check passes. Use a build whose app and privileged helper share one signing identity (Apple-issued or the local self-signed one). Install hooks, trust the Codex definitions with `/hooks`, grant notifications and Accessibility, and enable the helper.

## Session monitoring

For Claude Desktop, Claude CLI, Codex Desktop, and Codex CLI, verify:

- A session already running before Kith opens appears as Running.
- Two simultaneous turns appear independently.
- A structured question and a permission request appear as Needs input with one alert each, and clear after response.
- Completion produces one Ready alert only after the read-only state confirms the turn stopped.
- Failure and interruption appear accurately. A failed or unknown session prevents finish actions.
- Restart Kith during a turn, disable a hook, and test a changed local-state schema. The integration must show unavailable instead of silently reporting completion.
- A click on a Codex Desktop alert opens that thread. Claude Desktop activates, and CLI opens the owning terminal when identified. In Terminal and iTerm2, with Automation allowed, it brings the session's own window and tab to the front.

Check event latency against the hook invocation time: under 5 seconds for hook events and under 10 seconds for scan-only changes.

## Interface

- With no work, confirm the menu bar panel stays compact and shows an all-clear state only when monitoring is healthy.
- Start several sessions, request input in more than four, and fail one. The panel must prioritize the action items, cap its preview, and open the matching app or thread from each visible row. The shared Kith window must show the rest in Sessions, with working and recent filters and search by title, project, and source.
- Expand Power in the panel for the short controls, then open its full settings. The shared window must have a sidebar for Sessions and each settings page, keep one instance, and preserve the selected destination when reopened. Check keyboard navigation and the sidebar toggle, search and filters, light and dark appearance, and a narrow window. Monitoring and notification issues must appear beside their sidebar destinations and on Sessions. Protective stops, recovery problems, and armed countdowns must remain visible. Recovery controls must appear near the top of Power when recovery needs attention.
- Disable a monitor and notifications. Their warnings must remain visible in the panel and shared window, with links to the relevant Settings panes. An unavailable monitor must never appear as finished work.
- Arm sleep and shutdown in turn. The armed state and Cancel must remain visible while scrolling; shutdown must require confirmation, and the 60-second countdown must stay at the top of the panel.
- Check light, dark, increased contrast, VoiceOver, keyboard navigation, long titles, duplicate titles, and a small display. Settings text and controls must stay readable over the glass surface. Status must be clear without color, and the panel must remain within the display.

## Power and closed lid

Before testing, record `pmset -g` and `pmset -g custom` and save all work. Use `pmset -g assertions` to verify that Kith holds idle sleep during work and the selected extra hold. Start a manual timer with display wake enabled. Quit and force-quit Kith in separate runs and check that both assertions clear. On a supervised test Mac, suspend the running Kith process and confirm that both assertions expire within 45 seconds. Resume or terminate that process after the check.

Confirm the system-wide sleep setting and both power profiles match the baseline after these runs. Test lid close with and without a supported external display setup and confirm macOS follows its normal behavior in each case. On a test Mac with settings already recorded by an earlier Kith version, start the updated helper and check that it restores the recorded preferences. Disable the helper in Settings → Power after recovery.

Confirm that an ad hoc build, or an app signed with a different certificate than the helper, cannot use the helper and shows the error in Power. An app signed with the helper's identity must connect, and must reconnect after the helper is disabled and enabled again in Settings → Power, without relaunching Kith.

Finally test Sleep and Shutdown in a supervised session. Save other apps first; the shutdown request does not protect unsaved work. Verify no action runs while any session is Running, Needs input, Failed, or unavailable. Only enable finish actions in Settings → After work after completing these checks.

## Bounded power workflows

Run `scripts/test.sh` and `scripts/test-power-e2e.sh` first. The E2E script launches a debug app with isolated state and simulated OS power effects; it does not validate the Mac's actual sleep, thermal, audio or login behavior. The following checks require a signed app and matching helper on a supervised Mac.

- In the menu popover, start each timer preset and a custom hours/minutes duration. Check that invalid, zero, and over-24-hour durations cannot start; extensions cannot leave over 24 hours. Verify the countdown and end time match Power settings and CLI status, continue after closing/reopening the menu, and stop at zero. Add time must preserve the current period; End must release the holds. Check automatic periods show an upper limit and remain subject to agent completion and safety stops.
- Start automatic work and a manual period separately. Verify the visible deadline, a single five-minute reminder, Extend, End, and Resume. New turns, waiting prompts, and grace time must preserve the deadline. Setting a different maximum applies to the next period. Verify both system and display assertions release at the end.
- Restart the app during a period and after expiry. The original deadline must survive; an expired period must stay stopped. Launch a second app instance and verify it cannot own the same command inbox or apply power changes.
- Start a manual period while sleep or shutdown is armed. The action must cancel. Manual periods, safety stops, unavailable monitors, and unresolved power/audio recovery must block finish actions.
- Exercise AC-to-battery and battery-to-AC changes and the selected battery floor. Confirm that low-battery stops release Kith's system and display holds and require explicit resume. Use injected thermal/battery inputs for hazardous conditions; do not intentionally overheat or exhaust a Mac to test them. Confirm event wiring on hardware through normal power changes. Two unreadable battery observations on battery must stop protection; no-battery desktops must remain supported.
- Test display wake with UI automation and explicit screen locking. Display wake must be opt-in, remain bounded by the current deadline, and release at a safety stop. It must never change lock-screen preferences.
- Test lid-close muting with speakers, headphones, a device switch while closed, a user unmute, an output disconnect/reconnect, app relaunch and failed restoration. Saved outputs must restore on their own devices. Stop waiting must work only for a disconnected saved output. Audio recovery needs the user app; the root helper cannot perform it.
- Disconnect the network for less than five seconds, then for longer during work. Check one outage notification, a persistent warning and one recovery notice. End work during an outage and check that warnings clear. These events must never mark a session finished.
- Check browser warnings with and without the two background-throttling flags. Browser checks must never quit or relaunch an app, or store its arguments in diagnostics.
- Exercise the bundled CLI through start, extend, end, resume, status and JSON output, including malformed durations, a closed app, a stale request and a second simultaneous caller. Check actual holds and recovery status before retrying a request whose acknowledgment was lost.
- Toggle launch at login, deny or revoke approval in System Settings, replace the app with a newer signed build and reopen it. The control must report macOS's current state and preserve a user's disable choice.
- Click Check for updates with normal connectivity, offline, and under a service error. Verify the installed version, a clear result, stable-release filtering and the exact release destination. No check, download or installation may run automatically.
- Check recovery warnings with notifications disabled, unreadable state, an unwritable state directory, a failed restoration and a stalled power command. Preserve the journal and show pending recovery until it can be confirmed. Check diagnostic contents and account-only file permissions.
