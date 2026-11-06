# Automation

All app, CLI and URL requests use the same hold engine. Each hold has a unique
ID; labels are descriptive and do not merge ownership.

## Command line tool

Use Install command line tool in Settings → Automation to link the bundled
command into `~/.local/bin`. Keep that directory on your PATH. You can also run
`build/Dilated.app/Contents/MacOS/dilated` directly from a local build.
The button changes to Remove command line tool when this copy owns the link.
Removal preserves other commands and the executable inside the app bundle.

| Command | Behavior |
|---|---|
| `dilated status --json` | Current holds, deadlines, pause state and error status |
| `dilated status --assertions [--json]` | Read-only list of every process's power assertions (type, name, PID, process name), with Dilated's own marked |
| `dilated on` | Keep the system awake indefinitely, allowing display sleep |
| `dilated on --for 90m --label build` | Start a timed hold and print its ID |
| `dilated on --until 17:00` | Keep awake until the next local 17:00 |
| `dilated on --for 1h --display-awake` | Keep the display awake too |
| `dilated on --for 1h --lid` | Request closed-lid for this hold using the closed-lid sudo rule |
| `dilated off` | Stop all app-managed holds and pause automation |
| `dilated off --id ID` | Stop only that hold |
| `dilated off --label build` | Stop matching automated holds without affecting manual holds |
| `dilated hold --label agent --ttl 10m` | Create a renewable hold and print its ID |
| `dilated hold --id ID --ttl 10m` | Renew that hold from now |
| `dilated release --id ID` | End the identified hold |
| `dilated run -- make test` | Keep awake while the command runs and preserve its exit status |
| `dilated lid-permission status --json` | Report the sudo rule state: `ready`, `notInstalled`, `needsRepair`, `blocked`, `notAdmin` or `allowedByOtherRule` |
| `dilated lid-permission install` | Install or repair the sudo rule, asking for an administrator password |
| `dilated lid-permission remove` | Confirm normal sleep, then remove the sudo rule (asks for a password) |

`dilated helper status|setup|remove` still work as deprecated aliases and go away in a later release.

`on --for` and `hold --ttl` (also `hold --for`) accept `90m`, `2h30`,
`for 1 hour 30 minutes` or `until 5pm`. The menu's duration field and the
Shortcuts action's Duration phrase input accept the same phrases. Choose either
minutes or a phrase in Shortcuts, not both. Ambiguous times such as `until 5`
are rejected. New phrases are limited to seven days; existing single-unit
numeric input keeps its ten-year limit. `--until` still accepts 24-hour local
time. A past time means tomorrow. `--override-low-power` permits a
new hold in Low Power Mode. The configured battery floor still applies. New
requests also respect the explicit Low Power Mode override in Settings.
`--lid` requires the app and the closed-lid sudo rule, even for `run`, and never bypasses
closed-lid safety limits or the first battery-use warning. Renewals preserve an
active lid request but cannot re-enable one that stopped. See
[installation and removal](INSTALLATION.md) for setup and current acceptance
limits.

`status --assertions` reads the system's power assertions and never releases or
changes any of them. It asks the running app for its PID so Dilated's own
assertions are marked (`*` in text, `"ours": true` in JSON). Without the app it
still lists system assertions and marks none. JSON has `appPID` (null when the
app isn't reachable), `assertions` (each with `pid`, `process`, `type`, `name`
and `ours`; `process` and `name` are null when unavailable) and `summary`
(assertion type to system-wide holder count).

Normal commands connect to the app and launch the bundled/installed app if
needed. Status only queries; it doesn't launch the app. `run` can hold a native
assertion without the app. When the app is available it registers a renewable
reason there as well. Main Stop and an individual stop of its reason release the
awake claim while its command continues. The runner does not recreate an ended
registered hold; start a new hold explicitly if needed after it is ended.

An app crash leaves a registered runner's local assertion active while the app
is unavailable, unless persisted Stop/Quit state has removed its reason. If a
relaunched app no longer recognizes the registered ID, the runner releases its
awake claim and lets the command finish. Renewable agent holds must likewise
obtain a new ID after their previous hold ends; expired IDs are not resurrected.

## Keyboard shortcuts

Settings → Hot Keys assigns global shortcuts for start/stop, default duration,
15 minutes, one hour, stopping all work, toggling display sleep for current holds,
and opening the menu bar menu. The original Control-Option-Command-D toggle is
the only default assignment. Extra actions stay unassigned until configured.

Record a combination containing Control or Command, release the keys, then Save.
Escape cancels; Clear removes the assignment. Dilated suspends its global keys
while the recorder sheet is open so recording an existing key won't start/stop
work. Recording uses local app events and requires no Accessibility permission.
Conflicting Dilated assignments are rejected, and unavailable system registrations
restore the previously working bindings. A failed save doesn't activate an
unsaved binding. Shortcuts are stored locally with the other preferences.

Use Dilated → Open Menu Bar Menu to open the same native menu from the keyboard
or while Settings is visible. A display-sleep shortcut changes current holds;
it reports when there are no active holds. Starts use manual hold semantics and
remain available during the durable automation pause.

## Shortcuts actions

The signed app provides these four automation actions:

| Action | Result |
|---|---|
| Start keeping awake | Optional minutes and display-sleep preference; returns the new hold's UUID text |
| Stop keeping awake | Ends every app-managed hold, confirms closed-lid is off and durably pauses automation |
| Get awake status | Text containing active IDs/deadlines, pause state, requested closed-lid and last observed closed-lid state |
| Set closed-lid mode | Takes a hold UUID and enabled Boolean; changes only that active hold |

### Focus filter

Create a rule in Dilated, then choose **Awake rule** in System Settings > Focus >
your Focus > Add Filter and select that rule. The filter enables the selected rule;
its normal conditions must still match. Changing Focus disables the previous
filter's rule, and leaving Focus disables its selected rule. Other rules and manual
holds keep their own settings. Use a dedicated rule if you only want it during Focus.

Stop, the master trigger switch and each rule's pause still apply. A Focus change
doesn't resume stopped automation, clear a rule's pause or arm closed-lid mode.
After relaunch, a previously Focus-controlled rule stays off until macOS returns
the current Dilated filter. A failed lookup leaves it off and reports the error.
Dilated uses its own app filter configuration and doesn't read the user's global
Focus status. The filter adds no polling timer or permission request.

Chain Start's result into Set closed-lid's Hold ID. Closed-lid enable requires
the sudo rule in place, any battery-warning review, and passing guards. It never
opens setup prompts, enables a future default or resumes automation. Disable remains
available while paused. Expired/malformed IDs and failed operations return errors.

When Shortcuts launches a closed app, normal startup runs first: eligible timers
restore, and enabled launch/trigger rules evaluate. Get status reports that state;
Stop clears it and pauses automation. This preserves normal recovery policy.
Unlike the CLI's status query, the Shortcuts action can launch the app.

macOS supports these actions in user-built shortcuts. It doesn't expose the separate
App Shortcuts/Siri phrase surface described for other Apple platforms. On the tested
Mac, ad-hoc apps appear in the action library but macOS rejects execution without a
developer team identity. Use a developer-signed build for real runtime checks.

## AppleScript

The dictionary exposes these Amphetamine-compatible commands. Change the target app
to Dilated in existing scripts; the event/parameter codes are retained. The initial
surface excludes screen-saver and Drive Alive commands while those mechanisms remain
unimplemented.

| Commands | Behavior |
|---|---|
| `session is active`, `session is Trigger` | Any active hold; any active trigger hold |
| `start new session` | Replaces only prior AppleScript-owned holds, preserving unrelated work |
| `end session` | Global Stop with durable pause; triggers cannot immediately restart |
| `session time remaining` | Longest timed lifetime in seconds; -3 inactive, 0 indefinite non-trigger, -1 trigger |
| `display sleep allowed` | Aggregate current holds, or the session default when inactive |
| `allow display sleep`, `prevent display sleep` | Changes current holds without replacing their IDs/deadlines, or changes the idle session default |
| `closed display mode enabled` | Confirmed sleep-disable state; unknown state is an error |
| `enable closed display mode`, `disable closed display mode` | Targets its own AppleScript hold, otherwise requires exactly one active hold |
| `Triggers are enabled`, `enable Triggers`, `disable Triggers` | Persistent master switch, independent of each rule and the automation pause |

For example, `tell application "Dilated" to start new session with options
{duration:5, interval:minutes, displaySleepAllowed:false}` starts a five-minute
script-owned hold with the display awake. Omit options to use current duration/display
defaults. A record may override display alone. Duration and interval must be supplied
together; duration must be an integer and interval a finite number. Explicit
`{duration:0, interval:0}` means indefinite. Unknown fields, partial durations, Boolean
numbers, invalid types and durations beyond ten years are rejected before replacement.

For mixed holds, indefinite non-trigger work takes precedence over trigger, then
timed work in the remaining-time result. Until-time holds report seconds rather than
Amphetamine's -2 sentinel. Trigger display changes affect only the current run, and
the master switch never chooses Resume automation. Closed-lid without an unambiguous
current target returns an error and never saves a future default. Start and closed-lid
enable respect Stop; manual timers from the app remain available during the pause.

Cold scripting launches use the same normal startup policy as Shortcuts. Caller-side
macOS Automation consent is separate from receiving commands in Dilated. Scripts
receive success only after state/assertion work and any closed-lid operation completes.

## Sleep and user switching

Settings → General can stop all holds when the Mac sleeps or when switching
users. Both options start off. Enabling either uses the same durable pause as
Stop, so waking or returning to the session cannot restart matching triggers
until Resume automation. The sleep option applies to all system sleep events.
Manual timers remain available while paused.

**Resume when you return** is a separate opt-in under the user-switching option.
Within the same app run, it restores the holds that were running when you
switched away, with their original deadlines, and re-evaluates triggers from
current conditions instead of replaying them. Closed-lid is never restored. Main
Stop, Quit, a sleep-policy stop or Resume automation while you're away cancels
it, and a pause that existed before you switched stays in place.

## Conditions and triggers

The weekly schedule editor includes a seven-day hourly grid. Drag a block to
replace the schedule's days and hours, or focus the grid and use arrow keys and
Space to select an hour. Clear schedule removes the selected days. The weekday
buttons and precise From/Until fields edit the same schedule, including overnight
windows and minute-level times. The grid highlights any hour touched by that
window; selecting a grid block uses whole hours.

A trigger's saved **Work with the lid closed** choice requires **Arm closed-lid**
in Settings for the current app run. Saving a rule or launching Dilated cannot
arm it. Stop, safety stops, rule edits, permission changes and relaunch revoke that
permission. CLI/AppleScript/Shortcuts closed-lid requests still target their
specified current holds through their existing gates; they don't arm future
triggers.

Settings → Triggers creates named rules. All conditions inside a rule must match;
each matching rule contributes its own awake reason. Rules can keep the display
awake and explicitly override Low Power Mode. Other battery and closed-lid safety
limits still apply. Closed-lid follows the explicit arming and permission checks above.

Conditions include a running or frontmost app, an exact process name/path, a
specific process instance, weekly/overnight schedules, battery/power, display
counts and mirroring, and IPv4/IPv6 addresses, CIDR subnets, gateways or DNS servers.
Choose an app with the file picker or enter its bundle identifier. Process-instance
selection records both PID and start time; it won't follow a reused PID.

Dwell delays a start until conditions remain true. Grace delays the end after
conditions stop matching. Schedule windows use local time, including overnight
windows beginning on the selected weekday. Equal start/end times mean the whole
selected day. Triggers cannot wake a sleeping Mac.

The trigger master switch enables or disables all rules without losing their choices.
Rules can also be disabled or paused for five minutes, an hour or until tomorrow.
An individual awake reason's Stop suppresses its rule until conditions become
false, or Resume this trigger is chosen. Main Stop blocks every trigger until
Resume automation, including after relaunch/reboot. Resuming an individual rule
never overrides the global pause. Process discovery checks every five seconds
and monitors matched process exits immediately. Global pause stops monitoring.

Mounted-volume conditions match the exact mount path, including mounted disk
images and network volumes. They observe mounts, unmounts and renames without
reading or writing files. A different volume mounted at the same path will match.

CPU load uses differences between system-wide CPU counters, including wraparound.
The first reading is a warm-up, not zero. The editor starts a new CPU condition
with 30 seconds of dwell when none is configured; adjust dwell/grace for noisy
workloads. Idle time reads Quartz's combined-session elapsed input time. It does
not record keys, move the pointer or promise another app's availability status.
Both CPU and idle conditions are checked every five seconds only while a matching
configured rule is enabled and unpaused. Unknown readings never match.

Wi-Fi conditions match the exact SSID bytes, including capitalization and spaces.
Enter a network name or choose Get current Wi-Fi network in its condition editor.
Only the explicit Allow Location access button requests macOS permission.
Dilated reads network names without requesting geographic coordinates or scanning
nearby networks. Denied or unavailable names don't match; IP, gateway and DNS
conditions still work without Location access. Network-change notifications
refresh matching, with the shared five-second coalesced timer covering SSID
changes that leave IP configuration unchanged. SSID polling runs only for an
enabled, unpaused rule with Location access. Network names contain at
most 32 bytes; an unusual non-text name selected from the current connection is
preserved as raw bytes and displayed in hexadecimal.

USB conditions select a connected device by vendor/product and serial number.
When the device supplies no serial number, the condition matches any connected
unit of that model. Selected sound-output conditions use the output's stable UID,
not its friendly name, and don't require playback. Both use native change events
without adding a polling timer.

Paired Bluetooth conditions select a device from the Mac's paired-device list,
identified by its address. Names alone don't identify a device. Allow Bluetooth
access explicitly in the condition editor, then choose a paired device. The
condition matches only while that device is connected. It doesn't scan, pair,
connect or disconnect accessories. Connection/disconnection notifications don't
add polling. Permission loss, Bluetooth off or a resetting service makes the
condition unavailable; matching resumes from current state when access and
Bluetooth return, subject to Stop's durable pause. Disabled/paused rules remove
their monitoring. Saved unavailable selections remain editable.

Configuration survives app restarts, but matching holds are rebuilt from current
conditions. A saved process/app hold is never treated as evidence the work is
still running.

## Agent lifecycle commands

`dilated agent` wraps the renewable hold API so any hook can call one contract.
`--agent` is 1-32 and `--run` 1-64 letters, digits, `-` or `_`, because they become
file names. Each run keeps its hold ID and last renew time in
`agents/AGENT.RUN.json` under the app's state directory, written atomically and
guarded by a per-run lock so concurrent hooks can't race. The lease is 10 minutes.
No command makes a model or network call. `--json` prints the usual response.

| Command | Behavior |
|---|---|
| `dilated agent begin --agent NAME --run ID [--pid N]` | Start a 10-minute hold for the run and print its hold ID. A repeat for the same run renews and prints the same ID. If the saved hold already ended, starts a fresh one, unless automation is paused |
| `dilated agent renew --agent NAME --run ID` | Renew the run's hold for another 10 minutes. Never creates one: with no saved hold, an ended hold or paused automation it fails and creates nothing |
| `dilated agent end --agent NAME --run ID` | Release only this run's hold and delete its record. Safe to repeat, and a run with no record succeeds |

Exit status is 0 on success, 4 when automation is paused and 1 for an ended hold or
any other error. An ended-ID reply deletes the run's record, so later renewals fail the
same way. Only an explicit `begin` starts a new hold after that. If the app isn't
running, `begin` and `renew` launch it like `hold` does, while `end` doesn't.

### Keeping a quiet turn alive with `--pid`

A long model turn can go longer than the 10-minute lease without firing a hook. Pass the
agent's process ID to `begin` and it also starts a small detached renewer for that run:

```
dilated agent begin --agent claude --run "$SESSION" --pid $PPID
```

In a hook's shell, `$PPID` is the agent process. `--pid` is digits only, can't be 0 or 1,
and must be a running process you own. It is accepted by `begin` only. Without it nothing
changes and the lease runs out after its 10-minute TTL.

The renewer (`dilated agent _renew`, hidden from help) runs in its own session with output
discarded, and keeps its pid and start time in the run's record. At most one runs per
run: a repeat `begin` doesn't start a second while the recorded one is alive. Every 2
minutes, while the agent process is unchanged and the record still has the same hold, it
renews the hold for another 10 minutes. It never starts or recreates a hold. It exits when:

- the agent process exits (watched directly, so a killed agent stops it at once);
- the run's record is gone, which means `end` ran;
- a renew says the hold is not found, ended, or automation is paused;
- the app is unreachable on two renews in a row. It never launches the app.

Exiting doesn't release anything. The hold lapses within one 10-minute TTL, so a
killed agent can't keep the Mac awake, and an idle open session holds nothing because
`end` releases it at the end of each turn. `end` remains the only release.

## Manual agent hook pattern

Automatic hook installation is deferred. Configure your workflow to capture the
ID from `dilated hold --label agent --ttl 10m` at the start of work, keep it in
that workflow's runtime state, and call `dilated hold --id ID --ttl 10m` while work
continues. Call `dilated release --id ID` when finished. Give concurrent agent
runs separate IDs, even when their labels match.

Run these commands from lifecycle hooks or a local workflow supervisor, outside
the model conversation. They use a local Unix socket and require no model or
network calls. Keep the ID in runtime state; don't inject heartbeat output into
the agent's prompt. A ten-minute TTL renewed every two minutes is a reasonable
starting configuration, not a measured performance guarantee. Renewal must
continue through quiet long turns without relying on tool-use events. The
supervisor must stop renewing when its associated work ends.

Release by ID when one run finishes. Don't use plain `dilated off` as an agent's
cleanup hook: it stops everyone and pauses automation. The app combines active
holds into one native assertion per system/display level, so each extra agent
doesn't add another system-awake assertion.

Renew often enough that the TTL doesn't expire during a long turn. A missing
renewal expires the hold automatically. An agent must treat a paused or ended
response as an ended hold, not create a replacement that undoes the user's Stop.
For a command whose lifetime is known, `dilated run -- command` avoids a separate
renewal loop.

## Stop and safety behavior

Main Stop pauses CLI, URL, AppleScript and Shortcuts starts and renewals until **Resume automation**
is chosen in the app. The pause survives app relaunch and Mac reboot. Local
manual holds still work. An individual reason's Stop ends only that reason.

Intentional Quit ends app-managed holds and discards saved timers. Standalone
`run` work continues. After a crash or reboot, unexpired timers restore with
their original deadlines if guards permit; indefinite manual holds do not.
A planned in-app update also restores timed holds only, with their original
deadlines. Closed-lid requests are never restored from saved timers.
Low Power Mode ends holds without an explicit override. Battery guard overrides
from the app's Start Anyway prompt apply only to the approved hold.
The ordinary battery floor is ignored on AC by default. Turn off Ignore battery
floor on AC in Battery & Safety to enforce it while connected to power too.
Changing this choice immediately checks existing holds. Closed-lid safety limits
remain separate, and Stop still requires explicit Resume automation.

CLI errors use stderr. Exit status 4 means automation is paused, 1 means another
request or connection error, and `run` returns its child command's status. With
`--json`, app responses include `ok`, optional `id`, `snapshot`, and optional
`code`/`message`; timestamps are Unix seconds. A false `ok` is a failure even when
the response also includes diagnostic state.

Unreadable app settings block new holds and renewals with `code: "settingsRecovery"`.
Status and Stop remain available. Recover settings in the app before retrying;
resetting them keeps automation paused and doesn't restore saved timers.

## Local history

Settings → Statistics shows recent app-managed awake reasons, sources, durations
and end causes. Overlapping holds count once in Hold time. These totals describe
requests made through Dilated, rather than physical Mac uptime. A standalone
`dilated run` without the app isn't included. Automation links retain their own
source, separate from command line requests.

History stays on this Mac. Recording starts enabled with 30-day retention; choose
7, 30 or 90 days, turn off future recording, export JSON or clear records. Turning
recording back on during a hold begins a new segment. Clear keeps active work
running and starts its history again from that moment. Completed history is bounded
to 2,000 records and 2 MB; up to 1,024 concurrent active entries are recorded.

After a crash, interrupted entries end at their last saved checkpoint, rather
than claiming time while the app was unavailable. Checkpoints run every 20 seconds
while holds are active. A restored timer starts a new history segment with the same
hold ID and original expiry. Durations use wall-clock dates, so changing the system
clock can affect them. Failed writes are reported and retried; corrupt history is
preserved until Clear. No diagnostic/history files are uploaded.

## Package preparation

`dilated prepare-update [--json]` prepares an external package upgrade and quits
the app, keeping only unexpired timed holds at their original deadlines.
`dilated prepare-uninstall [--remove-lid-permission] [--json]` removes the login
item and owned CLI link, discards saved holds and quits. It leaves the closed-lid
sudo rule alone unless you pass `--remove-lid-permission`, which asks for an
administrator password; `brew uninstall --zap` removes it too. Both require
closed-lid to be off. They remain available while automation is paused
and do not resume it. Errors keep the app open and prevent package preparation.

The CLI requests termination only from the app process that acknowledged the
preparation. Homebrew's read-only `dilated package-check` rejects a running app,
missing/expired preparation, unconfirmed off power readings, or a remaining
old helper job/process. Fixed read-only system checks are bounded; unknown state
refuses replacement. The cask invokes this check through declarative steps. Preparation lasts ten minutes
and is cleared at the next app start. Reopen Dilated after upgrading. See
[installation](INSTALLATION.md#updates) for the full sequence and remaining
real-package checks.

## Automation links

Links are enabled by default and can be disabled in Settings → Automation.
Supported links are `dilated://awake?for=90m&display=allow`,
`dilated://awake?until=17:00&display=prevent`, `dilated://stop`, and
`dilated://toggle`. Duplicate, conflicting and unknown parameters are rejected.
The additional `lid=closed` option requires Allow closed-lid links in Settings →
Closed Lid, which is off by default, plus the closed-lid sudo rule. Any website can
open these links, so this gate is separate from ordinary URL automation. Stop
still pauses link starts. Trigger and safety-setting changes aren't supported
by the URL interface.

## Local control protocol

The app listens on a user-only Unix socket inside a private 0700 directory under
`/tmp`. Its socket is 0600. The directory name derives from the current user and
state directory. An app lock prevents a second instance from replacing a live
socket. Messages are one JSON object per line, limited to 64 KiB, with bounded
socket reads/writes. A minimal status request is `{"action":"status"}`.

`DILATED_STATE_DIR` selects an isolated state directory for development/testing.
Normal app state lives in `~/Library/Application Support/Dilated`. Tests do not
read local planning files. This is a single-user local app, not a network service.

## Why is my Mac awake?

Choose Why is my Mac awake? from the menu, or Why Awake in Settings. The page
shows Dilated's awake reasons followed by macOS power assertions, with Dilated's
assertions first. Each assertion lists its process, PID, type and name. The page
reads a fresh snapshot when opened and doesn't poll or save other apps' history.
It can't change another process's assertions. Closed-lid settings and other macOS
behavior can also affect sleep without appearing in this list.

## Claude Code hooks

In the direct build, Settings → Automation → Claude Code hooks installs, verifies,
repairs or removes Dilated's hooks in `~/.claude/settings.json`. Existing settings
and unrelated hooks are preserved. Each edit of an existing file saves a private
`dilated-settings-<ID>.backup` beside it. Invalid JSON is refused without changing
the file. Restart existing Claude sessions after changing hooks.

The health check reports Missing, Installed or Drifted. Drifted includes partial
hooks, a changed app path, or Claude's `disableAllHooks` setting. Install and repair
refuse to write while hooks are disabled, with an explanation. Enable hooks in
Claude settings, then repair. Removal remains available and preserves that setting.

A prompt starts one ten-minute hold per Claude session, with a detached renewer
while the agent process lives, for up to one hour after the last prompt or tool
hook. Tool calls renew the hold and extend that window. Stop, StopFailure and
SessionEnd release it. Claude does not send Stop after a user interruption, so
an interrupted turn can retain the hold until that one-hour renewal window ends
and the remaining ten-minute lease expires. No hook activity means at most
70 minutes of awake time; use Dilated's Stop to release it immediately. Quiet
turns longer than an hour need an explicit timed hold. The menu and history label reads `decided by: hook`.
Dilated's Stop pauses automation, so later hooks cannot recreate an awake hold
until Resume automation. Hook errors stay quiet and never block Claude.

The hook protocol follows [Claude Code's hook reference](https://code.claude.com/docs/en/hooks).

## Other coding agents

Settings → Automation also configures Codex hooks and installs an OpenCode local
plugin. All adapters use separate run identities, stay quiet on errors and respect
Dilated's Stop pause. Automatic quiet-turn renewal is bounded to one hour since
actual hook activity, followed by at most the remaining ten-minute lease.

| Tool | Default file | Lifecycle and activation |
| --- | --- | --- |
| Codex | `~/.codex/hooks.json` | Prompt begins; tool hooks renew; Stop, Interrupt and SessionEnd release. Review and trust the new hooks in Codex `/hooks` or Settings > Hooks. Configured does not mean trusted or enabled by policy. |
| OpenCode | `~/.config/opencode/plugins/dilated.js` | Busy starts; tools renew; idle, error, deletion and plugin disposal release. Restart OpenCode after changing plugins. Other plugin files are untouched; an unrelated file at this exact path is never overwritten or removed. |

Install/repair preserves existing hooks and private backups. Removal deletes only
Dilated's entries or owned plugin. These controls target the default user paths;
custom configuration locations need the equivalent integration in that location.
They do not change Codex trust, managed policy or feature flags. Hooks require a
local runtime capable of executing the installed Dilated CLI.

Contracts: [Codex hooks](https://learn.chatgpt.com/docs/hooks),
[OpenCode plugins](https://opencode.ai/docs/plugins/) and the
[OpenCode 1.19.5 session status schema](https://github.com/anomalyco/opencode/blob/v1.19.5/packages/schema/src/session-status-event.ts).
Fixture configuration, actual CLI/socket isolation and generated plugin execution
are tested; these checks do not claim a live Codex or OpenCode model turn.

### CPU fallback presets

In Triggers, Agent preset creates an editable rule for the Claude Code, Codex or
OpenCode CLI. It combines the exact process name with total Mac CPU at least
20%, using the existing process and CPU monitors. It adds no monitor or polling
loop. The reason includes `decided by: CPU`; the hold ends on the next trigger
evaluation when either condition stops matching. Stop-pause still wins.

CPU here is system-wide, not per-process. Other work can keep the condition true
while an agent is idle, so use lifecycle hooks when available. Review process
name and threshold before saving. These presets are direct-build only.
