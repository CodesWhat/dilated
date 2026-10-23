# Automation

All app, CLI and URL requests use the same hold engine. Each hold has a unique
ID; labels are descriptive and do not merge ownership.

## Command line tool

Use Install command line tool in Settings → Automation to link the bundled
command into `~/.local/bin`. Keep that directory on your PATH. You can also run
`build/Dilated.app/Contents/MacOS/dilated` directly from a local build.

| Command | Behavior |
|---|---|
| `dilated status --json` | Current holds, deadlines, pause state and error status |
| `dilated on` | Keep the system awake indefinitely, allowing display sleep |
| `dilated on --for 90m --label build` | Start a timed hold and print its ID |
| `dilated on --until 17:00` | Keep awake until the next local 17:00 |
| `dilated on --for 1h --display-awake` | Keep the display awake too |
| `dilated off` | Stop all app-managed holds and pause automation |
| `dilated off --id ID` | Stop only that hold |
| `dilated off --label build` | Stop matching automated holds without affecting manual holds |
| `dilated hold --label agent --ttl 10m` | Create a renewable hold and print its ID |
| `dilated hold --id ID --ttl 10m` | Renew that hold from now |
| `dilated release --id ID` | End the identified hold |
| `dilated run -- make test` | Keep awake while the command runs and preserve its exit status |

Durations use `s`, `m` or `h`, including decimals such as `1.5h`. Until-times use
24-hour local time. A past time means tomorrow. `--override-low-power` permits a
new hold in Low Power Mode. The configured battery floor still applies. New
requests also respect the explicit Low Power Mode override in Settings.

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
Low Power Mode ends holds without an explicit override. Battery guard overrides
from the app's Start Anyway prompt apply only to the approved hold.

CLI errors use stderr. Exit status 4 means automation is paused, 1 means another
request or connection error, and `run` returns its child command's status. With
`--json`, app responses include `ok`, optional `id`, `snapshot`, and optional
`code`/`message`; timestamps are Unix seconds. A false `ok` is a failure even when
the response also includes diagnostic state.

## Automation links

Links are enabled by default and can be disabled in Settings → Automation.
Supported links are `dilated://awake?for=90m&display=allow`,
`dilated://awake?until=17:00&display=prevent`, `dilated://stop`, and
`dilated://toggle`. Duplicate, conflicting and unknown parameters are rejected.
Closed-lid requests, trigger changes and safety-setting changes aren't supported
by the M1 URL interface.

## Local control protocol

The app listens on a user-only Unix socket inside a private 0700 directory under
`/tmp`. Its socket is 0600. The directory name derives from the current user and
state directory. An app lock prevents a second instance from replacing a live
socket. Messages are one JSON object per line, limited to 64 KiB, with bounded
socket reads/writes. A minimal status request is `{"action":"status"}`.

`DILATED_STATE_DIR` selects an isolated state directory for development/testing.
Normal app state lives in `~/Library/Application Support/Dilated`. Tests do not
read local planning files. This is a single-user local app, not a network service.
