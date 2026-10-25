# Dilated

Keeps your Mac awake. A native macOS 26 menu bar app for Apple Silicon.

The local preview includes timed and indefinite awake holds, display-sleep controls,
battery and Low Power Mode guards, four menu bar glyphs, optional compact/clock countdowns or end time, Settings,
configurable global shortcuts, local history and statistics, URL automation, AppleScript,
four Shortcuts actions, and
a CLI with renewable agent holds, file/folder download watches, opt-in Drive Alive,
notifications and sounds.
Closed-lid controls and their privileged helper are implemented, with hardware
recovery and release acceptance still pending. There is no public release yet.
Condition-based triggers are implemented locally for apps, processes, schedules,
power, displays, network identity, Wi-Fi SSIDs, mounted volumes, USB and paired
Bluetooth devices, selected audio output,
CPU load and idle time.
Automatic agent setup remains later work.

Build the local app with `bash scripts/build-app.sh`, then open
`build/Dilated.app`. This is a development build, not a notarized release. The
script uses ad-hoc signing by default; `DILATED_SIGN_IDENTITY` can select an
installed signing identity. Xcode and XcodeGen are required. The app shell extracts
App Intents metadata while the core, UI, CLI and helper remain Swift packages.
Real Shortcuts execution requires a developer-signed build on the tested Mac;
an ad-hoc build can appear in the action catalog but fail to run.

Run the checks with `bash scripts/verify.sh` using Xcode, XcodeGen, Python 3, Ruby
and Node.js 24. This entry point runs Swift tests, release packaging checks
(including an isolated app build/launch), website tests, and formatting/syntax
checks. CI uses the same entry point. After building the bundle, run the
bounded app/CLI integration check with `python3 scripts/smoke-test.py`. It uses
disposable state and cleans up its own processes. macOS UI checks are performed
against the actual app.

The package app product and internal executable are named `DilatedApp` to avoid
a case-only collision with the `dilated` CLI on macOS filesystems. The app shown
to users is Dilated.

See [installation and removal](docs/INSTALLATION.md),
[automation](docs/AUTOMATION.md), [architecture](docs/ARCHITECTURE.md), and
[third-party notices](docs/THIRD-PARTY.md). Dilated is free software under MIT.

Choose **Keep awake for → While a file downloads…** or **While a folder downloads…**
from the menu. A folder watches its `.crdownload`, `.part`, `.download` and
`.partial` items, including browser download packages. Choose 5–3600 seconds of
inactivity before ending the hold. Stalled downloads also end it. Completion,
Stop, safety guards and Quit release the watch without ending separate holds.
Download watches aren't restored after a crash, relaunch or update; choose them
again when needed. File access is requested only through your selection.

In **Settings → Drive Alive**, select volumes, enable it and choose a 30–3600
second interval. The default writes only while Dilated has an awake hold; the
optional always mode runs while the app is open without creating a hold. Stop
pauses either mode until Resume automation. Each pulse creates a new hidden
8-byte file, flushes it and removes it. Removed, ambiguous, read-only or
unwritable volumes show an error and aren't written to. Your existing files
aren't opened for writing. A drive's own firmware or server policy may still let
it sleep; Drive Alive doesn't wake a sleeping Mac.

In **Settings → Notifications & Sounds**, enable banners to request macOS
notification permission. Session and trigger starts/ends, safety reasons and
periodic awake reminders are configurable. Agent/script events are excluded by
default, and lease renewals stay quiet. Banners and sounds default off. Sounds
are independent of banners, with original short cues and custom audio import
(up to 2 MB and 10 seconds). Stop/final expiry ends reminders, and Quit cancels
pending feedback. Failed notification delivery or sound playback never changes
an awake hold. Native delivery and audible playback acceptance remain pending.

In **Settings → Menu Bar**, import a static PNG with a transparent background
(up to 512 × 512 pixels and 2 MB). Dilated copies it locally and creates crisp
menu-size template images; its colors follow macOS. Custom icons stay still and
dim when idle by default, with a separate dim preference. Pick a bundled icon to
switch back, or Remove to discard the imported copy. A missing or invalid copy
falls back to your bundled choice so the menu bar control stays visible.

**Settings → Menu Bar** also offers compact, clock and end-time text. Seconds can
follow the format default, always show or stay hidden. Hidden seconds round
remaining minutes up; the clock then reads hours:minutes. End time follows your
Mac's locale and time zone and includes a date when the hold ends on another
day. Indefinite holds still show ∞, and session time can be hidden entirely.

For a closed-lid trigger, enable **Work with the lid closed** in its editor,
save, then choose **Arm closed-lid** on that rule. This requires the approved
helper. Arming applies only to this app run; relaunch, Stop, rule edits, helper
changes and safety stops disarm it. Ordinary condition changes can start/end
that trigger's own closed-lid request while it stays armed. Disarming one rule
keeps other awake reasons running. Physical helper/trigger acceptance is pending.
