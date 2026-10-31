# Dilated

Keeps your Mac awake. A native macOS 26 menu bar app for Apple Silicon.

From [CodesWhat](https://codeswhat.com): small, sharp tools from one developer and a lot of agents.

The local preview includes timed and indefinite awake holds, display-sleep controls,
battery and Low Power Mode guards, four menu bar glyphs, optional compact/clock countdowns or end time, Settings,
configurable global shortcuts, local history and statistics, URL automation, AppleScript,
four Shortcuts actions, and
a CLI with renewable agent holds, file/folder download watches, opt-in Drive Alive,
notifications and sounds.
Closed-lid controls and their privileged helper are implemented, with hardware
recovery and release acceptance still pending.
Condition-based triggers are implemented locally for apps, processes, schedules,
power, displays, network identity, Wi-Fi SSIDs, mounted volumes, USB and paired
Bluetooth devices, selected audio output,
CPU load and idle time.
Automatic agent setup remains later work.

1.0.0-beta.7 is a public beta for macOS 26+ on Apple Silicon. Install it from the
website download or with `brew install --cask codeswhat/tap/dilated`. Closed-lid
mode is experimental, and crash, reboot and update recovery haven't been verified
on hardware yet. Report issues on GitHub.

Build the local app with `bash scripts/build-app.sh`, then open
`build/Dilated.app`. This is a development build, not a notarized release. The
script uses ad-hoc signing by default; `DILATED_SIGN_IDENTITY` can select an
installed signing identity. Xcode and XcodeGen are required. The app shell extracts
App Intents metadata while the core, UI, CLI and helper remain Swift packages.
`bash scripts/build-app.sh debug --verify` safely stops the running dev copy,
rebuilds it, launches it and reports its PID. It refuses alternate output paths
and waits for other Dilated copies to be quit first. Add `--logs` to stream app
logs for five minutes after launch.

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
second interval. Volumes inherit the default unless you choose **While keeping
awake** or **Always while open** for that volume. Always doesn't create an awake
hold. Existing choices keep their previous behavior. Stop pauses every volume
until Resume automation, and Off prevents all writes. Each pulse creates a new hidden
8-byte file, flushes it and removes it. Removed, ambiguous, read-only or
unwritable volumes show an error and aren't written to. Your existing files
aren't opened for writing. A drive's own firmware or server policy may still let
it sleep; Drive Alive doesn't wake a sleeping Mac.

In **Settings → Battery & Safety**, the ordinary battery floor ignores AC power
by default. Turn off **Ignore battery floor on AC** to enforce it while connected
to power too. Changing the choice immediately checks existing holds. **Start
Anyway** overrides the floor for one hold only; Low Power Mode and closed-lid
safety limits remain separate.

If settings can't be read, no saved timers restore and new holds stay blocked.
Settings offers an explicit reset that privately backs up the unreadable file,
saves the paused state, then writes defaults. Automation remains paused until
you choose **Resume automation**.

In **Settings → Notifications & Sounds**, enable banners to request macOS
notification permission. Session and trigger starts/ends, safety reasons and
periodic awake reminders are configurable. Agent/script events are excluded by
default, and lease renewals stay quiet. Banners and sounds default off. Sounds
are independent of banners, with original short cues and custom audio import
(up to 2 MB and 10 seconds). Stop/final expiry ends reminders, and Quit cancels
pending feedback. Failed notification delivery or sound playback never changes
an awake hold. Native delivery and audible playback acceptance remain pending.

In **Settings → Menu Bar**, import a static active PNG with a transparent
background (up to 512 × 512 pixels and 2 MB). Add an optional idle PNG for a distinct
resting state, or use the active PNG for both. Both stay still, use crisp template
images and follow the menu bar's color. Idle dimming has a separate preference.
Remove idle PNG returns to the active image; Remove icons discards both imported
copies and selects the last bundled icon. Replacement/removal preserves any copy
still used by the other state. A missing idle image falls back to the active
image with a warning; a broken active image falls back to the bundled icon.

**Settings → Menu Bar** also offers compact, clock and end-time text. Seconds can
follow the format default, always show or stay hidden. Hidden seconds round
remaining minutes up; the clock then reads hours:minutes. End time follows your
Mac's locale and time zone and includes a date when the hold ends on another
day. Choose the Mac's clock setting or force 12/24-hour end times, plus small or
standard time text. Countdown durations keep their usual format. Indefinite
holds still show ∞, and session time can be hidden entirely.

For a closed-lid trigger, enable **Work with the lid closed** in its editor,
save, then choose **Arm closed-lid** on that rule. This requires the approved
helper. Arming applies only to this app run; relaunch, Stop, rule edits, helper
changes and safety stops disarm it. Ordinary condition changes can start/end
that trigger's own closed-lid request while it stays armed. Disarming one rule
keeps other awake reasons running. Physical helper/trigger acceptance is pending.
