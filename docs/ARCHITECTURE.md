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

`DilatedHelper` is a signed SMAppService LaunchDaemon. The app and helper apply
OS code-signing requirements to their XPC peers. The app also checks protocol
version and the running helper's code-directory hash against the helper packaged
in its own bundle. A helper generation change invalidates the old lease.

Stored power settings are read through CFPreferences, synchronized before each
read. Reading the plist directly can return an old disk snapshot after macOS has
accepted a change. Effective sleep-disable is checked separately in IORegistry;
both readings must match, and missing or non-boolean values stay unknown.

Closed-lid mode uses fixed-argument `pmset` operations through a serialized,
bounded driver. Both stored and effective sleep-disable readings must confirm the
requested state. The daemon resets the flag before becoming ready and retries a
failed reset. Its independent watchdog checks a continuous-clock lease, battery,
power source, thermal state and Low Power Mode. Main-actor heartbeats renew a
lease of at most 90 seconds; an app hang cannot renew it through a detached task.
Clearing sleep-disable precedes an explicit Sleep request. These mechanisms are
implemented, but real lid, crash, reboot and power-transition acceptance remains
open. Unit tests do not establish hardware recovery.

`AppUpdater` isolates the pinned Sparkle driver. Checks and installation defer
while closed-lid protection, helper replacement or recovery is in progress.
Before a planned update, the app confirms closed-lid is off and saves only
unexpired timed holds with their original deadlines. Intentional Quit clears all
app holds instead. Helper replacement disables protection and awaits service
unregistration before re-registering. Closed-lid is never restored from saved
timers. Local candidate builds disable updates; release builds require the
configured HTTPS feed, EdDSA public key, signed feed and pre-extraction validation.

Packaging scripts verify signed/notarized app and DMG files. Public staging also
requires acceptance records for the exact source, build and artifact checksums,
including macOS 26/27 and a second Mac. Publication remains gated on that evidence.
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
the Location entitlement; the CLI and privileged helper don't. The documented
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
Dilated has an applied awake assertion. Always mode doesn't create an assertion
or wake the Mac. Both modes require automation unpaused. Stop, disabling, loss of
the awake-only condition and shutdown invalidate the scheduled cycle and cancel
pending work. A single one-shot timer is created only when eligible, with at
least 30 seconds between cycles. A cycle writes selected volumes serially;
configuration changes wait for an existing write before starting another cycle.
Late results can't schedule another cycle after Stop or shutdown. An in-flight
kernel filesystem operation can finish after cancellation, without a next pulse.

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
The helper and its privileges aren't involved.

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
Notifications and sounds cannot alter the hold engine, automation pause or helper.

Three original short WAV cues are generated deterministically by
`design/sounds/generate.py`. Custom files are read with a 2 MB bound, decoded by
NSSound and limited to 10 seconds, copied under the private application-support
sounds directory using UUID filenames and mode 0600. Settings retain an ID/name,
never an arbitrary playback path. Import rolls back the new file if saving the
setting fails; replacing a custom choice removes the previous file only when
no other cue references it. Audio stays local, and no microphone permission or
helper privilege is used. Decoder checks don't establish audible output.

Injected tests cover permission denial, late authorization/send/explicit-permission
results, history-disabled delivery, source filtering, failed starts, guard reasons,
reminder deadlines, custom import rollback and shared asset lifetime. Installed
permission allow/deny/revoke, foreground/background/Focus delivery, actual sound
output and native picker/readability acceptance remain separate gates.
