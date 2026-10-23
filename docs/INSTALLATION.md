# Installation and removal

Dilated targets macOS 26 or later on Apple Silicon. There is no public release
yet. The app, helper, update integration and packaging are implemented locally;
the required hardware recovery, packaged upgrade and second-Mac checks remain
open. A signed or notarized candidate alone does not close those checks.

## Local builds and first launch

Run `bash scripts/build-app.sh` from the repository. The resulting
`build/Dilated.app` is ad-hoc signed by default. An installed Developer ID identity
can be selected with `DILATED_SIGN_IDENTITY`; signing alone does not notarize it.
Local builds have updates disabled.

Open the app bundle to review ordinary keep-awake behavior. The first Keep Awake
starts an indefinite system hold, allows display sleep and leaves closed-lid off.
Stop ends app holds and pauses automation until Resume automation is chosen.
That pause survives relaunch and reboot. A manual hold remains available while
automation is paused.

For helper setup, use a signed, notarized candidate copied to
`/Applications/Dilated.app`. Launch that copy rather than the app on a mounted
disk image. A bare SwiftPM executable or an ad-hoc development bundle does not
establish that the privileged service can be registered.

## Command line tool

Settings → Automation → Install command line tool creates
`~/.local/bin/dilated`, pointing at the CLI in the current app bundle. The
installer refuses to replace another file or a link owned by another app.
Once installed, the same button becomes Remove command line tool. Removal
unlinks only the command pointing into this copy of the app, including a broken
link to that exact path. It preserves the bundled CLI and unrelated commands.
Keep `~/.local/bin` on PATH. The bundled CLI also works directly, for example
`/Applications/Dilated.app/Contents/MacOS/dilated status --json`.

`dilated status --json` queries the running app without launching it. See
[automation](AUTOMATION.md) for holds, command runners, exit statuses and pause
behavior.

## Closed-lid helper

Ordinary awake holds do not require a privileged helper. Closed-lid mode does.
In Settings → Closed Lid, choose Set up closed-lid and complete the approval
shown by macOS in Login Items. An approval request is not an enabled lid session:
closed-lid must still be enabled explicitly for an awake hold.

`dilated helper status --json` reports service registration and any authenticated
helper state. `helperInstallation: "enabled"` means registered/approved. A usable
helper must also report `helper.ready: true`. When protection is off, expect
`helper.enabled: false` and both
`helper.readback.storedDisabled` and `helper.readback.effectiveDisabled` to be
`false`. A missing value is unknown, not confirmation of normal sleep. The
command's successful exit by itself does not prove the helper is ready or off.

`dilated helper setup` uses the same setup/repair flow as Settings and may open
macOS approval. A changed helper is disabled, unregistered and re-registered.
A version/identity mismatch is an error, not permission to keep using an old
helper. After a crash, reboot or safety stop, closed-lid needs explicit
enablement again.

Closed-lid defaults are a 20% battery floor and an eight-hour closed-lid battery
limit. Battery, thermal, Low Power Mode and optional AC-only guards remain
effective in the daemon if the app stops responding. Their actual hardware
recovery tests are still required before release.

## Updates

Local candidates do not contact a production update feed. Release builds use
Sparkle with a signed feed and signed update archives. Updates wait until
closed-lid mode is off and helper changes/recovery have finished.

A planned in-app update restores only unexpired timed holds, preserving their
original deadlines and rechecking guards. Indefinite manual holds do not return.
Stop's automation pause remains in effect. Helper replacement invalidates the
previous lease; an ordinary relaunch does not re-enable closed-lid.

Manual Quit ends app-managed holds and discards saved timers. Quitting and
replacing the app therefore does not provide timer-preserving update behavior.
The Homebrew cask and its upgrade lifecycle are still pending. It must not ship
with a generic Quit step that silently discards timers during an upgrade.

## Remove Dilated

Remove the helper while the signed app still exists in Applications:

1. In General settings, turn off Launch at login if enabled.
2. In Closed Lid settings, choose Turn off and remove helper. The CLI equivalent
   is `dilated helper remove --json`. It first clears closed-lid requests,
   verifies normal sleep and awaits service unregistration. If it fails, leave
   the app installed and use the reported error or helper repair flow.
3. In Automation settings, choose Remove command line tool if this copy installed
   the link. A link to another location is left unchanged.
4. Choose Quit Dilated. This ends app-managed holds and discards saved timers.
   A standalone `dilated run` command continues independently until its command
   finishes.
5. Move Dilated.app to Trash.

Normal removal preserves preferences in
`~/Library/Application Support/Dilated`. Removing those preferences is a
separate reset, after the app and helper have stopped. Deleting the app first or
stopping its launchd job alone does not verify that sleep-disable was cleared.

If the app was moved or removed before helper cleanup, restore the matching
signed bundle to Applications and use its setup/repair and removal flow. Keep
the app installed if macOS cannot confirm normal sleep. Actual uninstall
acceptance must separately verify service removal, absence of Dilated-owned
assertions and normal sleep.

## Release acceptance

Before public release, verify a clean install on another Mac, real helper
approval and denial, CLI linking without overwriting files, helper replacement,
an actual older-to-newer Sparkle update, uninstall and normal sleep. Closed-lid
acceptance also covers macOS 26 and 27, app/helper crash, heartbeat loss, reboot,
guard transitions and power/display changes. Power-setting experiments require
bounded execution and independent cleanup.

`scripts/package-release.py` creates checked local candidates or tagged release
packages. `scripts/stage-public-release.py` rejects candidates and requires an
acceptance record tied to the exact version, build, source revision, ZIP checksum
and DMG checksum. Required checks must have a passed status and machine, macOS
and evidence fields. Test fixtures and mock results are not hardware evidence.
Keep failed and unavailable checks open rather than substituting them.
