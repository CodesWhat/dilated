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

The helper, closed-lid backend, Sparkle/release packaging, triggers, AppleScript
and App Intents are later phases. No M1 runtime, build or test depends on
`.planning/`. The private roadmap owns phase tracking; shipped documentation and
CI use tracked files only.
