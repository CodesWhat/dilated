# Dilated

Keeps your Mac awake. A native macOS 26 menu bar app for Apple Silicon.

The local preview includes timed and indefinite awake holds, display-sleep controls,
battery and Low Power Mode guards, four animated menu bar glyphs, Settings,
a global shortcut, URL automation, and a CLI with renewable agent holds.
Closed-lid controls and their privileged helper are implemented, with hardware
recovery and release acceptance still pending. There is no public release yet.
Automatic agent setup and condition-based triggers remain later work.

Build the local app with `bash scripts/build-app.sh`, then open
`build/Dilated.app`. This is a development build, not a notarized release. The
script uses ad-hoc signing by default; `DILATED_SIGN_IDENTITY` can select an
installed signing identity.

Run the checks with `bash scripts/verify.sh`. After building the bundle, run the
bounded app/CLI integration check with `python3 scripts/smoke-test.py`. It uses
disposable state and cleans up its own processes. macOS UI checks are performed
against the actual app.

The package app product and internal executable are named `DilatedApp` to avoid
a case-only collision with the `dilated` CLI on macOS filesystems. The app shown
to users is Dilated.

See [installation and removal](docs/INSTALLATION.md),
[automation](docs/AUTOMATION.md), [architecture](docs/ARCHITECTURE.md), and
[third-party notices](docs/THIRD-PARTY.md). Dilated is free software under MIT.
