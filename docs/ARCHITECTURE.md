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
timer; active holds use a coalesced timer for expiry/countdown and a slower native
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
current limits. AppleScript and App Intents remain later phases.

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
Global automation pause removes monitoring and polling. Network identity uses
IP/subnet, gateway and DNS configuration without Location access.

No runtime, build or test depends on `.planning/`. The private roadmap owns phase
tracking; shipped documentation and CI use tracked files only.
