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
| `dilated on` | Keep the system awake indefinitely, allowing display sleep |
| `dilated on --for 90m --label build` | Start a timed hold and print its ID |
| `dilated on --until 17:00` | Keep awake until the next local 17:00 |
| `dilated on --for 1h --display-awake` | Keep the display awake too |
| `dilated on --for 1h --lid` | Request closed-lid for this hold through the approved helper |
| `dilated off` | Stop all app-managed holds and pause automation |
| `dilated off --id ID` | Stop only that hold |
| `dilated off --label build` | Stop matching automated holds without affecting manual holds |
| `dilated hold --label agent --ttl 10m` | Create a renewable hold and print its ID |
| `dilated hold --id ID --ttl 10m` | Renew that hold from now |
| `dilated release --id ID` | End the identified hold |
| `dilated run -- make test` | Keep awake while the command runs and preserve its exit status |
| `dilated helper status --json` | Query helper registration, authenticated state and power readback |
| `dilated helper setup` | Set up or repair the helper, opening macOS approval when needed |
| `dilated helper remove --json` | Confirm normal sleep before unregistering the helper |

Durations use `s`, `m` or `h`, including decimals such as `1.5h`. Until-times use
24-hour local time. A past time means tomorrow. `--override-low-power` permits a
new hold in Low Power Mode. The configured battery floor still applies. New
requests also respect the explicit Low Power Mode override in Settings.
`--lid` requires the app and approved helper, even for `run`, and never bypasses
closed-lid safety limits or the first battery-use warning. Renewals preserve an
active lid request but cannot re-enable one that stopped. See
[installation and removal](INSTALLATION.md) for setup and current acceptance
limits.

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

## Conditions and triggers

Settings → Triggers creates named rules. All conditions inside a rule must match;
each matching rule contributes its own awake reason. Rules can keep the display
awake and explicitly override Low Power Mode. Other battery and closed-lid safety
limits still apply. Closed-lid needs explicit enablement for the current hold.

Conditions include a running or frontmost app, an exact process name/path, a
specific process instance, weekly/overnight schedules, battery/power, display
counts and mirroring, and IPv4/IPv6 addresses, CIDR subnets, gateways or DNS servers.
Choose an app with the file picker or enter its bundle identifier. Process-instance
selection records both PID and start time; it won't follow a reused PID.

Dwell delays a start until conditions remain true. Grace delays the end after
conditions stop matching. Schedule windows use local time, including overnight
windows beginning on the selected weekday. Equal start/end times mean the whole
selected day. Triggers cannot wake a sleeping Mac.

Rules can be disabled or paused for five minutes, an hour or until tomorrow.
An individual awake reason's Stop suppresses its rule until conditions become
false, or Resume this trigger is chosen. Main Stop blocks every trigger until
Resume automation, including after relaunch/reboot. Resuming an individual rule
never overrides the global pause. Process discovery checks every five seconds
and monitors matched process exits immediately. Global pause stops monitoring.

Configuration survives app restarts, but matching holds are rebuilt from current
conditions. A saved process/app hold is never treated as evidence the work is
still running. Wi-Fi SSID and other device/activity criteria remain later work.

## Manual agent hook pattern

Automatic hook installation is deferred. Configure your workflow to capture the
ID from `dilated hold --label agent --ttl 10m` at the start of work, keep it in
that workflow's runtime state, and call `dilated hold --id ID --ttl 10m` while work
continues. Call `dilated release --id ID` when finished. Give concurrent agent
runs separate IDs, even when their labels match.

Renew often enough that the TTL doesn't expire during a long turn. A missing
renewal expires the hold automatically. An agent must treat a paused or ended
response as an ended hold, not create a replacement that undoes the user's Stop.
For a command whose lifetime is known, `dilated run -- command` avoids a separate
renewal loop.

## Stop and safety behavior

Main Stop pauses CLI starts, URL starts and renewals until **Resume automation**
is chosen in the app. The pause survives app relaunch and Mac reboot. Local
manual holds still work. An individual reason's Stop ends only that reason.

Intentional Quit ends app-managed holds and discards saved timers. Standalone
`run` work continues. After a crash or reboot, unexpired timers restore with
their original deadlines if guards permit; indefinite manual holds do not.
A planned in-app update also restores timed holds only, with their original
deadlines. Closed-lid requests are never restored from saved timers.
Low Power Mode ends holds without an explicit override. Battery guard overrides
from the app's Start Anyway prompt apply only to the approved hold.

CLI errors use stderr. Exit status 4 means automation is paused, 1 means another
request or connection error, and `run` returns its child command's status. With
`--json`, app responses include `ok`, optional `id`, `snapshot`, and optional
`code`/`message`; timestamps are Unix seconds. A false `ok` is a failure even when
the response also includes diagnostic state.

## Package preparation

`dilated prepare-update [--json]` prepares an external package upgrade and quits
the app, keeping only unexpired timed holds at their original deadlines.
`dilated prepare-uninstall [--json]` removes the helper, login item and owned CLI
link, discards saved holds and quits. Both require closed-lid to be off and
helper changes to be finished. They remain available while automation is paused
and do not resume it. Errors keep the app open and prevent package preparation.

The CLI requests termination only from the app process that acknowledged the
preparation. Homebrew's read-only `dilated package-check` rejects a running app,
missing/expired preparation or unconfirmed off power readings. The cask also
requires the helper job and process to be absent. Preparation lasts ten minutes
and is cleared at the next app start. Reopen Dilated after upgrading. See
[installation](INSTALLATION.md#updates) for the full sequence and remaining
real-package checks.

## Automation links

Links are enabled by default and can be disabled in Settings → Automation.
Supported links are `dilated://awake?for=90m&display=allow`,
`dilated://awake?until=17:00&display=prevent`, `dilated://stop`, and
`dilated://toggle`. Duplicate, conflicting and unknown parameters are rejected.
The additional `lid=closed` option requires Allow closed-lid links in Settings →
Closed Lid, which is off by default, plus the approved helper. Any website can
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
