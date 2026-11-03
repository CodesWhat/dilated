# Architecture

`DilatedCore` owns holds, wall-clock deadlines, assertion aggregation, safety
policy and persisted state. It imports no AppKit. Clocks and power inputs are
explicit in the engine, and the UI model accepts injected power/assertion
adapters. One native assertion per system/display level represents active app
holds. Assertions have a maximum 90-second timeout refreshed from the main
actor, so a hung app can't retain them indefinitely.

`DilatedControl` defines the validated CLI/URL request shapes, routes them into
the engine, and implements the user-only local socket. Holds are identified by
UUID rather than by label. Renewals only extend a still-active lease or runner
ID. Main Stop is durable and blocks new automation until explicit Resume.

`DilatedUI` adapts Mouthtype's Dock, login item, hotkeys, template image loading,
fonts, adaptive palette and glass Settings patterns. The app delegate wires
power, wake, clock and accessibility notifications. Idle operation has no engine
timer; opt-in Drive Alive has its own eligible-write schedule, and active holds use a coalesced timer for expiry/countdown and a slower native
assertion refresh. Icon animation uses short bursts capped at 8 fps, with still
frames for Off/Reduce Motion.

The app executable is `DilatedApp`. The CLI product is `dilated`. They must not
differ only by case, either in SwiftPM products or inside the app bundle.
`dilated run` owns an independent native assertion and registers a 30-second
renewable reason with the app when reachable. Stop ends the claim, never the
wrapped command. The CLI forwards interrupt/termination signals to its child.

State is atomically saved to a private application-support directory. Only
unexpired timed holds are restored; agent leases and runner IDs aren't replayed
as work after a crash. Explicit Quit clears saved holds. Broken state is reported
and automation starts paused. Settings decode missing keys with safe defaults.

There is no privileged helper. Closed-lid power changes run inside the app
through `sudo -n /usr/bin/pmset -a disablesleep 0|1`, allowed by a fixed sudoers
rule at `/private/etc/sudoers.d/dilated` (root:wheel, 0440, `%admin` only, those
two commands only). `ClosedLidPermission` installs, detects and removes it with
one admin prompt, and reports `notInstalled`, `needsRepair`, `blocked`, `ready`,
`notAdmin` or `allowedByOtherRule`. Non-admin accounts can't use closed-lid. The
sudo call runs with an empty environment under a bounded timeout.

Stored power settings are read through CFPreferences, synchronized before each
read. Reading the plist directly can return an old disk snapshot after macOS has
accepted a change. Effective sleep-disable is checked separately in IORegistry;
both readings must match, and missing or non-boolean values stay unknown.

Closed-lid mode uses fixed-argument `pmset` operations through a serialized,
bounded driver. Both stored and effective sleep-disable readings must confirm the
requested state. The closed-lid service runs in the app, off the main thread, and resets the flag
before it starts. It checks a continuous-clock lease, battery, power source,
thermal state and Low Power Mode every second. Main-actor heartbeats renew a
lease of at most 90 seconds; an app hang cannot renew it through a detached task.
Clearing sleep-disable precedes an explicit Sleep request.

Crash recovery has three layers. Before enabling, the app writes a session marker
(pid and generation) to its state directory and starts a detached watchdog
process, which restores sleep within seconds of the app exiting and then clears
the marker. At launch, a leftover marker triggers a revert. Sleep that is
disabled with no marker is treated as someone else's (Amphetamine, a manual
`pmset`) and left alone with a notice. A reboot with no relaunch can leave sleep
disabled, because the setting persists, until Dilated next launches. A failed
disable keeps retrying and blocks quit and update until sleep is confirmed
normal. These mechanisms are implemented, but real lid, crash, reboot and
power-transition acceptance remains open. Unit tests do not establish hardware
recovery.

On first launch after upgrading from a helper build, `HelperMigration`
unregisters the old LaunchDaemon, checks that its launchd job is gone and
reverts sleep if needed. The old plist stays in the bundle for now so
unregistering can work.

`AppUpdater` isolates the pinned Sparkle driver. Checks and installation defer
while closed-lid protection or recovery is in progress.
Before a planned update, the app confirms closed-lid is off and saves only
unexpired timed holds with their original deadlines. Intentional Quit clears all
app holds instead. Closed-lid is never restored from saved
timers. Local candidate builds disable updates; release builds require the
configured HTTPS feed, EdDSA public key, signed feed and pre-extraction validation.

Packaging scripts verify signed/notarized app and DMG files. Public staging also
requires acceptance records for the exact source, build and artifact checksums,
including macOS 26/27. Publication remains gated on that evidence.
See [installation and removal](INSTALLATION.md) for the supported lifecycle and
current limits.

A thin XcodeGen bundle target compiles the AppKit entry point and four App Intents,
linking the SwiftPM UI product. Its executable and extracted Metadata.appintents
are preserved during final assembly. Packaging validates the metadata and SDEF
before signing and again when verifying release bundles. Xcode shell builds do
not register the app with Launch Services.

One main-actor AutomationService binds the delegate's existing model after startup
and rejects unavailable/quitting work. Shortcuts uses AppDependency; the command-only
SDEF uses an Objective-C-visible NSScriptCommand subclass. Script commands suspend
inside their handler and resume on the main actor after the actual operation.
Receiving scripts adds no outgoing Apple Events or Accessibility permission.
Trusted in-process origins retain Shortcut/AppleScript attribution without accepting
a caller-selected source in the socket protocol. Script starts replace only prior
script-owned work, and trigger master changes preserve per-rule choices and Stop's pause.

Cold automation launches follow normal startup, including eligible timer recovery
and enabled startup/trigger rules, before executing the requested command. A status
action reports that resulting state; Stop clears it and pauses automation. AppKit's
default-launch flag does not distinguish every Shortcuts launch. No launch heuristic
or arbitrary startup delay is used. macOS exposes actions for user-built Shortcuts;
the App Shortcuts provider's phrase metadata does not promise Siri phrase support.

`TriggerEvaluator` combines conditions with AND within each rule and contributes
an independent hold for every matching rule. Stops suppress only that rule until
conditions change or it is explicitly resumed; global Stop retains the durable
automation pause. Condition holds are never replayed from disk. Only rule
configuration persists, and native inputs are read again after launch/wake.

`TriggerMonitor` uses Workspace, display, clock and SystemConfiguration events.
Schedule boundaries and dwell/grace use one-shot timers; elapsed dwell/grace is
monotonic. Process discovery is coalesced at five seconds only while a configured
process rule is enabled and unpaused, with kernel exit notifications for matches.
Specific processes are identified by PID and start time to avoid PID reuse.
CPU/idle conditions share the same five-second coalesced poll, enabled only for
active configured criteria. CPU counters require two samples; cached results
avoid sampling more often than four seconds during event bursts. Wake resets
the CPU baseline. Mounted paths use Workspace mount/unmount/rename notifications
and no file access. Global automation pause removes monitoring and polling. Network identity uses
IP/subnet, gateway and DNS configuration without Location access.

Wi-Fi SSID conditions store raw name bytes and read CoreWLAN only with Location
authorization. A lazily created authorization source requests permission only
from the condition editor's explicit button, never from trigger evaluation.
SystemConfiguration network-change events refresh current state. The existing
five-second coalesced poll also runs for enabled, unpaused SSID rules with access,
covering name changes that don't alter IP configuration. Permission loss removes
SSID polling and blocks reads; no cached SSID can match afterward. Generation
checks ignore queued permission callbacks after teardown. Only the app receives
the Location entitlement; the CLI doesn't. The documented
CoreWLAN event entitlement causes launch termination on the tested Mac with both
ad-hoc and Developer ID signing, so it is excluded and the app does not register
for CoreWLAN events. No geographic location updates or nearby scans are started.

Paired Bluetooth conditions normalize IOBluetooth device addresses into a
validated identity rather than using names. CoreBluetooth's static authorization
check precedes manager allocation. Only an explicit editor action requests
access; an already authorized manager observes power/reset/permission changes
while a rule or editor needs it. IOBluetooth connect and per-connected-device
disconnect registrations refresh the paired list. Unavailable/denied reads never
reuse a cached connection. Generation checks fence queued callbacks after stop
or restart, partial setup is cleaned up, and the last consumer releases the
authorization manager. No scanning, connection, pairing or polling is started.
The app carries NSBluetoothAlwaysUsageDescription; no new entitlement or helper
permission is needed outside the sandbox.

The engine emits bounded start/end events carrying the actual hold and end cause.
`SessionHistory` tracks app-managed reasons and calculates their interval union in
O(n log n), so concurrent holds don't multiply total requested time. It does not
measure hardware uptime or standalone assertions while the app is unavailable.

`HistoryStore` atomically compacts completed JSONL records to the selected 7/30/90
day retention, at most 2,000 records and 2 MB. Active reasons use a separate private
checkpoint, saved at transitions and every 20 seconds using the existing active
hold timer. Completed history is rewritten only when it changes or retention is
changed. No extra idle timer is created. Up to 1,024 concurrent history entries
are retained without limiting the hold engine. Files use 0600 within the private
application-support directory. On recovery, old entries end at the last checkpoint
with an interrupted cause; restored timers begin new segments. Corrupt history is
preserved until explicit Clear and never prevents stopping or starting awake work.
Statistics provides local JSON export, source filtering, recording and clear controls.

No runtime, build or test depends on `.planning/`. The private roadmap owns phase
tracking; shipped documentation and CI use tracked files only.

## Download completion

An explicit file/folder selection creates its own manual hold and transient
`DownloadMonitor`. Each selection owns an FSEvents stream before its first
metadata read. File writes, renames and root changes trigger a coalesced background
scan; no file contents are read or changed. Folder mode includes only direct
partial-download items, recursively inspecting partial browser packages. A
10,000-entry scan budget rejects oversized trees, and symbolic links aren't
followed. Unrelated completed files don't reset the quiet deadline.

An unchanged snapshot ends the hold at the configured inactivity deadline. The
existing active-hold timer requests a final rescan at that deadline, covering
missed/coalesced events without an additional polling timer. Growth resets it;
partial-item disappearance ends it, including a selected file renamed by a
browser. Missing folders, permission/read errors and failed event registration
end that hold and surface an explanation. This is an inactivity heuristic, not
proof that a browser completed successfully. A stalled download also ends.

Global Stop, individual release, power guards and shutdown dispose of the stream
and cancel pending work. Generation checks discard late callbacks and reads.
Separate manual/agent/trigger work continues after a download ends. Watches and
paths aren't saved; their indefinite manual hold is excluded from timer recovery.
A new explicit selection is allowed while automation is paused, without resuming
it. No watcher or automatic hold is recreated by Resume automation.

## Drive Alive

Persisted Drive Alive settings default off, at a 60 second interval and only while
Dilated has an applied awake assertion. Each selected volume can inherit that
global default, require an awake hold or run while the app is open. Missing mode
fields preserve inheritance; unknown/malformed mode values become awake-only
without resetting unrelated settings. Always mode doesn't create an assertion
or wake the Mac. Every volume requires the feature enabled and automation
unpaused. Stop, disabling, loss of a volume's eligibility and shutdown prevent
its next pulse. Kernel filesystem work can finish after cancellation.

Per-volume monotonic deadlines share one one-shot timer and one serial writer.
The configured interval is at least 30 seconds. An awake-state change only starts
newly eligible volumes; already eligible Always volumes keep their due time.
Losing eligibility cancels that volume's in-flight work and clears its status,
then other due volumes continue after cleanup. Configuration changes invalidate
the generation and wait for an existing write before applying the new schedule.
A schedule identity rejects stale callbacks, and late results can't recreate work
after Stop or shutdown. Failed writes wait their normal interval.

Selection uses the volume UUID, or filesystem type plus mounted source when a
UUID isn't available. A missing or ambiguous identity never falls back to its
old path. The catalog uses the cached `getfsstat(MNT_NOWAIT)` mount table and
includes hidden/no-browse mounts. Each pulse resolves the current mount, rejects
read-only media, opens the root with `O_DIRECTORY | O_NOFOLLOW`, then rechecks its
filesystem ID, mount point and write flag on that descriptor before creating a
file. A changed or unmounted volume cannot silently become a directory on its
parent filesystem.

A fresh random `.dilated-drive-alive-…` file uses mode 0600, `O_CREAT | O_EXCL |
O_NOFOLLOW`, writes 8 bytes, calls `fsync`, then unlinks that exact file relative
to its root descriptor. Existing files and symlinks aren't overwritten or
removed, including on a name collision. Error and cancellation paths close
descriptors and attempt removal of only the file created by this pulse. A crash
or failed filesystem cleanup can leave that tiny app-created file; no wildcard
cleanup touches other files. Failures remain visible in Settings and retry only
at the configured interval, never in a rapid loop. Settings remain mode 0600 locally.
Closed-lid and its sudo rule aren't involved.

Native checks use an owned writable HFS+ disk image and the same image remounted
read-only, checking the actual catalog/write path and preservation of a user-file
fixture. This doesn't prove physical enclosure spin behavior, NAS policy or
physical unplug handling. Those acceptance checks remain separate.

## Notifications and sounds

`FeedbackController` receives the same committed hold events as history before
history's recording/availability gate. Typed start/extend/end events distinguish
an explicit extension from a lease renewal. Renewal doesn't emit feedback or
create a new history segment. Baseline recovery is silent, and transient holds that fail before commit don't
announce successful starts or ordinary ends. An explicit closed-lid failure can
still report its guard reason. Event batches coalesce starts/ends; manual/trigger categories, automation
inclusion and safety reports have independent preferences. Closed-lid guard ends
can report their reason without ending the underlying system-awake hold. The
existing dedicated closed-lid warning beep takes precedence over the general
end cue, avoiding duplicate audio.

Banners and start/end/extend sounds default off. Notification permission is
requested only by an explicit Settings enable action. Ordinary events read the
current authorization and never prompt. The native notification center is lazy
and requires Dilated's actual installed bundle identity, so an unbundled test
host can't accidentally request or publish notifications. Foreground delivery
opts into banners/list; Focus, macOS permissions and preview policy still apply.
Each of the three kinds retains at most its latest request. UUIDs and generation
checks ensure a late send cannot cancel a newer request. Stop/final hold removal
cancels pending start/reminder work before optional end feedback; passive idle
refreshes preserve the completed end notice. Shutdown cancels all pending work.

Reminders use monotonic deadlines checked by the existing active-hold timer.
There are no future OS notification triggers or an additional reminder timer.
An overdue reminder produces one current notice, then moves its deadline forward;
it doesn't replay missed intervals after a hang. Final hold removal ends it.
Notifications and sounds cannot alter the hold engine, automation pause or closed-lid.

Three original short WAV cues are generated deterministically by
`design/sounds/generate.py`. Custom files are read with a 2 MB bound, decoded by
NSSound and limited to 10 seconds, copied under the private application-support
sounds directory using UUID filenames and mode 0600. Settings retain an ID/name,
never an arbitrary playback path. Import rolls back the new file if saving the
setting fails; replacing a custom choice removes the previous file only when
no other cue references it. Audio stays local, and no microphone permission or
sudo rule is used. Decoder checks don't establish audible output.

Injected tests cover permission denial, late authorization/send/explicit-permission
results, history-disabled delivery, source filtering, failed starts, guard reasons,
reminder deadlines, custom import rollback and shared asset lifetime. Installed
permission allow/deny/revoke, foreground/background/Focus delivery, actual sound
output and native picker/readability acceptance remain separate gates.

## Custom menu bar icons

Custom PNG selection is separate from the four bundled glyphs. Preferences retain
the last bundled choice, UUID/names for the active and optional idle copies,
selection state and a separate idle-dim option (default true). Input reads are
bounded to 2 MB. ImageIO checks complete PNG type, one static frame and dimensions up to 512 × 512 before
decoding. Empty and fully opaque images are rejected. Rendering preserves aspect
ratio on a 32 × 30 transparent canvas and converts visible pixels to black while
retaining alpha. Metadata is discarded during PNG re-encoding. The owned copy
uses mode 0600 under a private glyphs directory; arbitrary source paths aren't
retained. The original file is read only.

A template NSImage provides 16 × 15 and 32 × 30 representations. Import saves the
asset before preferences, rolls the new file back on preference failure and
removes the previous copy only after successful replacement and when neither
state references it. Idle import requires a valid active image. Removing idle
persists the active fallback before deleting an unreferenced idle asset; removing
both persists the bundled choice first and deduplicates shared IDs. Corrupt
reference metadata is isolated from unrelated preferences. A missing/corrupt idle
copy falls back to the active image with a separate icon issue; a broken active
copy uses the bundled fallback. Holds and pause are unchanged.

Selection identity includes both asset UUIDs; replacing either image clears old
cached frames. Idle/active holds select their corresponding image; legacy single
images remain the fallback for both states. Custom icons have no animation timer,
and the static Cat cans glyph no longer schedules useless motion bursts. Timer delivery keeps non-Sendable Timer
objects outside actor callbacks; a Boolean callback result controls invalidation.
The regular awake timer/countdown and animated bundled glyphs retain their
existing behavior. Custom idle dimming is independent of the bundled preference.

Native renderer/format checks cover both resolutions, aspect ratio, template
color conversion, animated/other-format rejection, oversized/empty/opaque data,
private permissions, transaction rollback, persistence, fallback, cache refresh
and static scheduling. Offscreen controls render with an imported image. Actual
installed picker, light/dark menu appearance, small-size readability and wider
energy acceptance remain separate checks.

## Session time in the menu bar

Countdown format and seconds visibility are persisted separately. Missing or
unknown values preserve the existing compact/clock displays. Explicit seconds
adds seconds to compact text; hiding them rounds remaining minutes up and
formats clock text as hours:minutes. End-time text uses an autoupdating locale
and calendar/time zone, with a date for deadlines on another day. It uses the
existing awake refresh timer and the latest finite deadline. Any indefinite
hold takes precedence as ∞; hidden and idle text remain empty. End-time hour
cycle can inherit the Mac or force a 12/24-hour clock through Locale.Components,
preserving localized digits, date and calendar/time zone. Small and standard text
use 11 and 12 pt monospaced digits; the independent amber symbol stays 12 pt bold.
Old/unknown/malformed new preferences preserve Mac/standard defaults without
resetting unrelated settings. These preferences
do not change holds, deadlines, pause state or closed-lid behavior.

## Closed-lid trigger options

A rule persists its closed-lid preference, defaulting to off for older files.
The core evaluator exposes rule-to-hold IDs but never sets a closed-lid request
from a saved preference. The UI model owns an explicit, non-persisted set of
armed rules. Arming checks the current closed-lid permission state and the battery warning.
Eligible matching holds pass through the same acknowledged enable/heartbeat,
policy, persistence and pending-request validation as manual/automation requests.
One finite task handles a snapshot of eligible holds serially, with no polling
or retries. New matching holds schedule work from existing commits. Permission
work finishes before queued trigger work proceeds; all requests share one lease.

Stop, quit/update preparation, permission changes, policy changes and
safety/lost-lease events revoke arming. Ordinary battery/Low Power Mode hold
stops also revoke trigger arming, independently of history preferences. Rule edits
revoke that rule's permission only after the configuration is saved. Disarming
a rule or turning off its active hold's closed-lid option preserves base awake
holds and other requests. Conditions may end/restart requests during the same
armed run; crash/relaunch never restore arming. Pending replies cannot restore
permission after Stop/Resume, disarm or edit. Closed-lid failures remain visible and
require a new explicit arm. The native closed-lid and installed UI acceptance gates
remain separate from injected tests and offscreen rendering.

## Mac App Store build

`DILATED_CHANNEL=mas` defines `MAS_CHANNEL` and drops Sparkle (see `Distribution.current`). These surfaces are
compiled out with `#if MAS_CHANNEL`, not hidden:

- Donate and sponsor links: `SupportLinks`, the "Support Dilated" menu item and the About credits line.
- Command line install: the Automation row, the `CommandLineInstallation` type and its package-removal call.
- Process triggers: both process kinds in the trigger editor, `ProcessCatalog`, and process evaluation in
  `TriggerMonitor`. Saved process rules stay in the data, show a note in the editor and never match.
- Helper migration: `HelperMigration` and its launch, package and Closed Lid settings call sites.
- Update controls: the General updates group, the About update row and both "Check for Updates…" menu items.
  `AppUpdater.statusText` reads "Updates come from the Mac App Store."

Closed-lid mode in this channel can't spawn `sudo` from the sandbox. `LocalClosedLidTransport` uses
`SerialPowerDriver(runner: UserScriptPowerRunner())`, which runs `~/Library/Application Scripts/<bundle id>/dilated-power`
through `NSUserUnixTask` (`LiveUserScriptLauncher`, 3 second bound; a task can't be killed, so a timeout drops the result).
The script runs unsandboxed as the user and the sudoers rule does the elevation. A separate companion, Dilated
Closed-Lid Setup, installs the script and the rule; the app never installs either. The source is
`packaging/mas/dilated-power`.

The companion is the `DilatedSetup` target (SwiftUI window; logic in `DilatedSetupCore`, every side effect behind a protocol). It
runs unsandboxed. Install order: the sudoers rule (skipped with no prompt when `ClosedLidPermission` already reads `ready` or
`allowedByOtherRule`, otherwise `ClosedLidPermission.install`, one admin prompt), then `dilated-power` into
`~/Library/Application Scripts/com.codeswhat.dilated.appstore/` (0755, temp file and rename, SHA-256 checked against
`ClosedLidSetupAssets.expectedScriptSHA256` before anything is written; a test fails if the script changes without it), then
the rendered LaunchAgent plist and `launchctl bootstrap gui/<uid>` after a `bootout`, so reinstall is idempotent. Remove order:
`dilated-power off` if a session file exists, boot out the agent and delete the plist, delete the script and its empty folder,
then the rule only if the companion created it. That fact is a 0600 record under `~/Library/Application Support/Dilated
Closed-Lid Setup/`, set only when the rule file was absent at install. The rule is the direct build's (same path and content),
so the two builds share it: the direct build's "remove" also removes the rule the Mac App Store build relies on, and the
companion never removes a rule it didn't create (Amphetamine's, or one the direct build installed first). Hidden headless mode
for `scripts/closed-lid-setup-check.sh`: `DilatedSetup --install --yes`, `--remove --yes`, `--status --json`; it never shows an
admin prompt.

The script takes one verb: `on <pid>` (exactly one argument, all digits, at most 10), or `beat`, `off`, `check`, `repair`,
`probe` with no argument. Anything else prints `usage` to stderr and exits 64. It uses absolute paths, runs
`/usr/bin/env -i /usr/bin/sudo -n`, and reads only `HOME`. `probe` runs `sudo -n -l` for both `pmset -a disablesleep`
commands. It prints one word, then exits:

| Word | Exit | Meaning |
| --- | --- | --- |
| `ok` | 0 | The command ran, or sudo allows both commands. |
| `reverted` | 4 | `on` from a pid the repair agent already reverted. |
| `norule` | 3 | sudo needs a password, doesn't allow the command, or the user may not run sudo. |
| `failed` | the failing status, or 1 | Anything else. |
| `none` | 0 | `beat` or `check` with no session. |
| `live`, `dead`, `stale`, `reverted` | 0 | `check` only. It reads and changes nothing. |

The script test hooks (`DILATED_POWER_TEST_SUDO`, `DILATED_POWER_TEST_WAKE`) are honored only when the script runs from
`<repo>/packaging/mas` next to `Package.swift`. The installed copy ignores them, so the environment of a `NSUserUnixTask`
or a local shell can't redirect sudo.

The sandbox gives the app no crash watchdog, so the script owns the revert. `on <pid>` writes
`~/Library/Application Support/dilated-power/session` (`<pid> <ps lstart>`, mode 0600 in a 0700 directory, written by temp
file and `mv`) before it disables sleep. Its mtime is the heartbeat. The record lives outside the container because other
processes can't read the container under TCC. The app passes `getpid()` to `on` and the session guard calls `beat` every 20
seconds (`ClosedLidSessionGuard.scriptHeartbeatInterval`, wired only under `MAS_CHANNEL`).

The companion installs the user LaunchAgent `com.codeswhat.dilated.closed-lid-repair`
(`packaging/mas/com.codeswhat.dilated.closed-lid-repair.plist`, `StartInterval` 30, `RunAtLoad`; the file carries a
`__HOME__` placeholder because launchd doesn't expand `~`). It runs `dilated-power repair`, which does nothing with no
session. Otherwise it reverts (`pmset -a disablesleep 0`, delete the session, write the tombstone `reverted <pid>`) when the
recorded pid is gone, its start time differs, or the heartbeat is older than 120 seconds while `kern.waketime` is also older
than 120 seconds (a hung app, not a sleeping Mac). `check` prints which of `live`, `dead`, `stale`, `reverted`, `none`
applies. A later `on` from the tombstoned pid prints `reverted` once and exits 4, and the app maps it to
`ClosedLidSessionError.revertedWhileUnresponsive`. That covers a crash, `kill -9` or force quit within 30 seconds, a hang
within 150, and a forced logout or reboot at the next login. `scripts/mas-repair-agent-check.sh` proves this on a real Mac.

The app reads the first stdout word, not the exit status, because `NSUserUnixTask` only reports an `Error`. `norule` and a
missing script become `ClosedLidPowerError.permissionUnavailable`, a timeout becomes `.commandTimedOut`, and the rest
`.commandFailed`. `ClosedLidScriptState` (`scriptMissing`, `ruleMissing`, `ready`) comes from `probe`; a timeout or failure
reads as `ruleMissing`. `ClosedLidPermissionModel` shows plain copy for each state and no install or remove button.

Download targets in this channel are `DownloadTargetRecord`s (path, folder flag, optional `bookmark`; old records decode with no bookmark). `SecurityScopedBookmarks` creates `.withSecurityScope` data from an open-panel URL, re-creates stale data, throws `missingTarget` for a deleted target, and hands `AppModel.startDownload` a `BookmarkAccess` that the monitor holds until it's released. The default `~/Downloads` needs no bookmark, only the `files.downloads.read-only` entitlement in `packaging/mas/Dilated-MAS.entitlements`; `DownloadTarget.systemDownloads()` resolves it through `FileManager`, never `NSHomeDirectory()`. The direct build keeps plain paths.

Drive Alive needs write access, so `files.user-selected.read-write` is in the entitlements and each volume carries its own
read-write bookmark (`DriveAliveVolume.grant`, `SecurityScopedBookmarks.liveReadWrite`). Turning a volume on opens a panel at
its mount point, and the picked folder must be the volume root (`DriveAliveGrants`). Every pulse resolves the bookmark,
holds scoped access for the write, and refuses a bookmark that resolves to a different path; a volume with no grant reports
"Grant access". A mount notification makes every eligible volume due at once, so a remounted drive writes without waiting out
the interval. `DriveAliveWriter` keeps its `O_NOFOLLOW` and `fstatfs` checks. The custom glyph and feedback sound pickers
already copy the picked file into the state directory (the container here), so settings hold an id and a name, never a path.
The trigger app picker stores the bundle ID only.

There is no watchdog process in this channel (`ClosedLidWatchdogSpawner` is compiled out); the repair agent above replaces
it. The in-app lease and the relaunch revert still run.

`scripts/check-mas-build.sh` builds this channel in `.build-mas`; CI also runs the `MASChannel` tests there.
