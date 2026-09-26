# Kith V1 acceptance on the target Mac

Keep **Enable after live validation** off until every applicable check passes. Use a signed build with the same Apple-issued identity on the app and privileged helper. Install hooks, trust the Codex definitions with `/hooks`, grant notifications and Accessibility, and enable the helper.

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

## Power and closed lid

Before testing, note `pmset -g` → `SleepDisabled` and save all work. Verify the idle assertion exists only during work plus the selected extra hold. Test a pending question, a new turn during the 60-second countdown, and explicit Cancel.

With **no external display**, test a long-running turn with the lid closed on AC, then on battery. Change power source during a run. Confirm the agent continues and Kith shows the hold active *before* closing the lid. After each test, confirm `SleepDisabled` returns to its prior value. Repeat after killing the app, restarting the helper, and disabling the helper. The 45-second lease should restore the setting after an app crash.

Finally test Sleep and Shutdown in a supervised session. Save other apps first; the shutdown request does not protect unsaved work. Verify no action runs while any session is Running, Needs input, Failed, or unavailable. Only enable finish actions in Settings after completing these checks.
