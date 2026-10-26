# Installation and removal

Dilated targets macOS 26 or later on Apple Silicon. 1.0.0-beta.2 (build 7) is
public as a beta. Download the signed, notarized DMG from
https://dilated.codeswhat.com/download/file, or run
`brew install --cask codeswhat/tap/dilated`. The fully qualified name trusts that
cask. Running `brew info` or `brew fetch` on the bare tap may ask for
`brew trust --cask codeswhat/tap/dilated`. The GitHub release at
https://github.com/CodesWhat/dilated/releases/tag/v1.0.0-beta.2 carries the DMG,
ZIP, source tarball, sha256 files and `release-manifest.json`.

The beta passed these checks on the maintainer's Mac: `macOS26ClosedLid`,
`heartbeatExpiry` and `stopResume`, plus a real Homebrew cask install over a
prepared earlier build. These hardware checks are not verified yet and are listed
in the cask caveats and `latest.json`: `macOS27ClosedLid`,
`helperCrashRecovery`, `appCrashRecovery`, `guardTransitions`, `rebootRecovery`,
`approvalDenied`, `helperUpgrade`, `sparkleUpgrade`,
`uninstallNormalSleep` and `nativeUI`. A signed or notarized build alone does not
close them.

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

If saved settings can't be read, Dilated restores no timers and keeps automation
paused. Open Settings and choose Reset unreadable settings to recover. Reset
saves the original file privately under Application Support/Dilated/recovery,
persists the pause, then writes defaults. Review Battery & Safety before starting
another hold. Automation still requires an explicit Resume automation afterward.

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
Repair allows a bounded retry for macOS's transient registration failure after
unregistration. Once registered, setup waits for the helper's startup reset to
finish. A reset failure or readiness timeout remains an error.
A version/identity mismatch is an error, not permission to keep using an old
helper. After a crash, reboot or safety stop, closed-lid needs explicit
enablement again.

If an approved helper won't launch or respond, Repair and removal can recover
without its acknowledgement only when there was no active or pending lid lease
and both independent sleep-disable readings confirm off. They check again
before unregistration and afterward. Enabled/unknown readings, protocol/reset
errors and cancellation still block this recovery; the app never assumes off
from a timeout alone.

A helper waiting for approval can be unregistered without approving it first
when both sleep-disable readings are off. Removal checks those readings again
after unregistration. Enabled or unknown readings require helper recovery first.

Closed-lid defaults are a 20% battery floor and an eight-hour closed-lid battery
limit. Battery, thermal, Low Power Mode and optional AC-only guards remain
effective in the daemon if the app stops responding. Their actual hardware
recovery tests are still required before release.

## Updates

Local candidates do not contact a production update feed. Release builds,
including the beta, carry the Sparkle feed at
https://dilated.codeswhat.com/updates/appcast.xml with updates enabled. The feed
and update archives are signed. Updates wait until
closed-lid mode is off and helper changes/recovery have finished.

A planned in-app update restores only unexpired timed holds, preserving their
original deadlines and rechecking guards. Indefinite manual holds do not return.
Stop's automation pause remains in effect. Helper replacement invalidates the
previous lease; an ordinary relaunch does not re-enable closed-lid.

Manual Quit ends app-managed holds and discards saved timers. Quitting and
replacing the app therefore does not preserve timers for an update.

The Homebrew cask is published at `codeswhat/tap/dilated`. A real cask install
over a prepared earlier build passed, but an actual packaged Homebrew
upgrade/removal check is still open. Homebrew does not
expose upgrade versus uninstall to its preflight hook, so Dilated requires an
explicit preparation command instead of a generic Quit step:

1. For an upgrade, run `dilated prepare-update`. It requires closed-lid to be
   off, unregisters the helper, saves only unexpired timers with their original
   deadlines and quits the app. Launch-at-login and the owned CLI link are kept.
2. Run the Homebrew upgrade, then reopen Dilated. Timers are restored subject to
   their deadlines and current guards. Reopening within the ten-minute handoff
   window also reinstalls a previously approved helper, leaving closed-lid off.
   A helper that was never approved is not installed automatically.
3. For removal, run `dilated prepare-uninstall` before Homebrew uninstall. This
   removes the helper, login item and owned CLI link, discards holds and quits.
   Preferences remain available for a later reinstall.

Preparation requires closed-lid and helper changes to have finished. A failure
keeps the app open and blocks the package operation. Preparation expires after
ten minutes and is invalidated when the app starts again. The cask checks the
preparation, absence of the app, confirmed off power readings, absence of the
helper job and absence of its process before allowing replacement or removal.
Unknown states block it. Run preparation again if the window expires or you
reopen Dilated before the package operation. `dilated package-check` is the
read-only CLI part of this preflight; it does not start the app.

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

The beta shipped with the checks listed at the top still open. Before a GA
release, verify real helper approval and denial, CLI linking without overwriting files, helper replacement,
an actual older-to-newer Sparkle update, uninstall and normal sleep. Closed-lid
acceptance also covers macOS 26 and 27, app/helper crash, heartbeat loss, reboot,
guard transitions and power/display changes. Power-setting experiments require
bounded execution and independent cleanup.
Releases are verified on the maintainer's Mac only, with no second-machine
install check.

`scripts/package-release.py` creates checked local candidates or tagged release
packages. `scripts/stage-public-release.py` rejects candidates and requires an
acceptance record tied to the exact version, build, source revision, ZIP checksum
and DMG checksum. Required checks must have a passed status and machine, macOS
and evidence fields. Test fixtures and mock results are not hardware evidence.
Keep failed and unavailable checks open rather than substituting them.
Alpha, beta and release candidate versions use a scoped gate. The record must
still list every check with a status of `passed`, `failed` or `notRun` and
non-empty evidence, and passed checks need a machine and macOS. These three must
pass: `macOS26ClosedLid`, `heartbeatExpiry` and `stopResume`. Anything else that
is failed or not run stays in the record with its evidence. Staging then names
those checks as unverified in the public release manifest, `latest.json` and the
cask caveats, and the public manifest reports `acceptanceVerified: false` while
any are open. A GA version keeps the full gate above, with all 14 checks passed.
Accepted release staging also generates `dilated.rb` with the exact version and
DMG digest as a versioned release asset. It does not publish the Homebrew tap.
