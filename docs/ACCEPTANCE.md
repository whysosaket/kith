# Kith acceptance checks

Run these on your own Mac before relying on finish actions or the closed-lid helper. Keep **Enable after live validation** off until every applicable check passes. Use a build whose app and privileged helper share one signing identity (Apple-issued or the local self-signed one). Install hooks, trust the Codex definitions with `/hooks`, grant notifications and Accessibility, and enable the helper.

## Session monitoring

For Claude Desktop, Claude CLI, Codex Desktop, and Codex CLI, verify:

- A session already running before Kith opens appears as Running.
- Two simultaneous turns appear independently.
- A structured question and a permission request appear as Needs input with one alert each, and clear after response.
- Completion produces one Ready alert only after the read-only state confirms the turn stopped.
- Failure and interruption appear accurately. A failed or unknown session prevents finish actions.
- Restart Kith during a turn, disable a hook, and test a changed local-state schema. The integration must show unavailable instead of silently reporting completion.
- A click on a Codex Desktop alert opens that thread. Claude Desktop activates, and CLI opens the owning terminal when identified.

Check event latency against the hook invocation time: under 5 seconds for hook events and under 10 seconds for scan-only changes.

## Interface

- With no work, confirm the menu bar panel stays compact and shows an all-clear state only when monitoring is healthy.
- Start several sessions, request input in more than four, and fail one. The panel must prioritize the action items, cap its preview, and open the matching app or thread from each visible row. The shared Kith window must show the rest in Sessions, with working and recent filters and search by title, project, and source.
- Expand Power in the panel for the short controls, then open its full settings. The shared window must have Sessions and Settings tabs, keep one instance, and preserve the selected tab when reopened.
- Disable a monitor and notifications. Their warnings must remain visible in the panel and shared window, with links to the relevant Settings panes. An unavailable monitor must never appear as finished work.
- Arm sleep and shutdown in turn. The armed state and Cancel must remain visible while scrolling; shutdown must require confirmation, and the 60-second countdown must stay at the top of the panel.
- Check light, dark, increased contrast, VoiceOver, keyboard navigation, long titles, duplicate titles, and a small display. Settings text and controls must stay readable over the glass surface. Status must be clear without color, and the panel must remain within the display.

## Power and closed lid

Before testing, note `pmset -g` → `SleepDisabled` and save all work. Verify the idle assertion exists only during work plus the selected extra hold. Test a pending question, a new turn during the 60-second countdown, and explicit Cancel.

With **no external display**, test a long-running turn with the lid closed on AC, then on battery. Change power source during a run. Confirm the agent continues and Kith shows the hold active *before* closing the lid. After each test, confirm `SleepDisabled` returns to its prior value. Repeat after killing the app, restarting the helper, and disabling the helper. The 45-second lease should restore the setting after an app crash.

Confirm that an ad hoc build, or an app signed with a different certificate than the helper, cannot use the helper and shows the error in Power. An app signed with the helper's identity must connect, and must reconnect after the helper is disabled and enabled again in Settings → Power, without relaunching Kith.

Finally test Sleep and Shutdown in a supervised session. Save other apps first; the shutdown request does not protect unsaved work. Verify no action runs while any session is Running, Needs input, Failed, or unavailable. Only enable finish actions in Power after completing these checks.
