# Dilated

Keeps your Mac awake. A native macOS 26 menu bar app for Apple Silicon.

The local preview includes timed and indefinite awake holds, display-sleep controls,
battery and Low Power Mode guards, four animated menu bar glyphs, optional compact
or clock countdowns, Settings,
configurable global shortcuts, local history and statistics, URL automation, AppleScript,
four Shortcuts actions, and
a CLI with renewable agent holds.
Closed-lid controls and their privileged helper are implemented, with hardware
recovery and release acceptance still pending. There is no public release yet.
Condition-based triggers are implemented locally for apps, processes, schedules,
power, displays, network identity, mounted volumes, CPU load and idle time.
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
