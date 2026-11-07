# Installation and removal

Dilated targets macOS 26 or later on Apple Silicon. Download the current public
beta as a signed, notarized DMG from
https://dilated.app/download/file, or run
`brew install --cask codeswhat/tap/dilated`. The fully qualified name trusts that
cask. Running `brew info` or `brew fetch` on the bare tap may ask for
`brew trust --cask codeswhat/tap/dilated`. The GitHub release at
https://github.com/CodesWhat/dilated/releases carries the DMG,
ZIP, source tarball, sha256 files and `release-manifest.json`.

The notarized 1.0.0-beta.9 build passed these checks on the maintainer's Mac with
macOS 27.2, and beta.10 through beta.12 don't change the direct closed-lid path: `macOS27ClosedLid`, `appCrashRecovery`, `heartbeatExpiry`,
`stopResume` and `sudoRuleIntegrity`. `macOS26ClosedLid` and `sparkleUpgrade`
come from earlier betas. These hardware checks haven't run for this build and are
listed in the cask caveats and `latest.json`: `sudoRuleRevoked`, `guardTransitions`,
`rebootRecovery`, `adminPromptCancelled`, `helperMigration`, `uninstallNormalSleep`
and `nativeUI`. A signed or notarized build alone does not close them.

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

For closed-lid setup, use a signed, notarized candidate copied to
`/Applications/Dilated.app`. Launch that copy rather than the app on a mounted
disk image.

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

## Closed-lid permission

Ordinary awake holds need no special permission. Closed-lid mode needs one
thing: a narrow sudo rule that lets Dilated turn macOS's sleep-disable setting
on and off without a password. Dilated has no root helper or background service.

The rule is the file `/private/etc/sudoers.d/dilated`, owned by root:wheel with
mode 0440. It lets members of the `admin` group run exactly two commands as root
without a password: `/usr/bin/pmset -a disablesleep 0` and
`/usr/bin/pmset -a disablesleep 1`. Nothing else. Any process running as an admin
user can use it to toggle sleep, and you accept that when you install it.

To set it up, open Settings → Closed Lid and choose Set Up in the Permission group, or run `dilated lid-permission install`. macOS asks for an
administrator password once. Dilated writes the file, checks it with `visudo -c`
and removes it again if the check fails. An installed rule isn't a lid session:
closed-lid still has to be enabled explicitly for an awake hold.

`dilated lid-permission status [--json]` prints one of these states:

- `ready`: the rule is installed, matches exactly and works.
- `notInstalled`: no rule, and no other rule that allows the command.
- `needsRepair`: the file exists but its contents, owner or mode differ. Run
  `dilated lid-permission install` to rewrite it.
- `blocked`: the file is right but sudo doesn't honor it, for example because
  sudoers no longer includes `/private/etc/sudoers.d`.
- `notAdmin`: your account isn't an administrator, so the rule can't cover it.
- `allowedByOtherRule`: another rule already lets you run the command without a
  password, such as the one Amphetamine installs. Closed-lid works, and Dilated
  leaves that rule alone.

Standard (non-admin) accounts can't use closed-lid mode. If sudo can't run the
command when you enable closed-lid, Dilated refuses and tells you to set the
permission up again. If it can't turn sleep back on, it keeps retrying, shows
an alert with Restore normal sleep (which asks for your password), and blocks
quit and update until sleep is confirmed normal.

### If Dilated crashes

When a closed-lid session starts, Dilated writes a session marker and starts a
small detached watchdog process. If the app dies, the watchdog restores normal
sleep within seconds. If the watchdog can't, the next launch of Dilated sees the
marker and reverts sleep. While the app is running, a 90-second lease also ends
the session if the app stops responding.

A reboot is the gap. The sleep-disable setting survives a reboot. If Dilated
crashes and the watchdog doesn't get to run, and you reboot without opening
Dilated again, sleep stays disabled until Dilated next launches. Launch at login
closes that gap. You can also run `sudo pmset -a disablesleep 0` yourself. This
case is on the GA acceptance list as `rebootRecovery` and hasn't been verified
on hardware.

Closed-lid defaults are a 20% battery floor and an eight-hour closed-lid battery
limit. Battery, thermal, Low Power Mode and optional AC-only guards run inside
the app.

### Upgrading from a helper build

Earlier betas used a privileged helper approved in Login Items. The first launch
after upgrading unregisters it, confirms its launchd job is gone and, if the
helper left sleep disabled, restores it. Settings shows the result, and tells
you if anything needs attention. Set up the sudo rule afterward to use
closed-lid again. If you'd rather clean up by hand, remove the Dilated entry
under System Settings → General → Login Items & Extensions.

## Updates

Local candidates do not contact a production update feed. Release builds,
including the beta, carry the Sparkle feed at
https://dilated.app/updates/appcast.xml with updates enabled. The feed
and update archives are signed. Updates wait until
closed-lid mode is off.

A planned in-app update restores only unexpired timed holds, preserving their
original deadlines and rechecking guards. Indefinite manual holds do not return.
Stop's automation pause remains in effect. An ordinary relaunch does not re-enable closed-lid.

Manual Quit ends app-managed holds and discards saved timers. Quitting and
replacing the app therefore does not preserve timers for an update.

The Homebrew cask is published at `codeswhat/tap/dilated`. A real cask install
over a prepared earlier build passed, but an actual packaged Homebrew
upgrade/removal check is still open. Homebrew does not
expose upgrade versus uninstall to its preflight hook, so Dilated requires an
explicit preparation command instead of a generic Quit step:

1. For an upgrade, run `dilated prepare-update`. It requires closed-lid to be
   off, saves only unexpired timers with their original
   deadlines and quits the app. Launch-at-login and the owned CLI link are kept.
2. Run the Homebrew upgrade, then reopen Dilated. Timers are restored subject to
   their deadlines and current guards. Reopening within the ten-minute handoff
   window restores them. The sudo rule stays installed, so closed-lid keeps
   working after the upgrade.
3. For removal, run `dilated prepare-uninstall` before Homebrew uninstall. This
   removes the login item and owned CLI link, discards holds and quits.
   Add `--remove-lid-permission` to delete the sudo rule too (asks for your
   password). Without it the rule stays, and `brew uninstall --zap` removes it.
   Preferences remain available for a later reinstall.

Versions 1.0.0-beta.1 and beta.2 can fail `dilated prepare-update` with
"Operation not permitted" when macOS reports the old helper as not found. Update
those installs with Check for Updates in Settings instead.

Preparation requires closed-lid to be off. A failure
keeps the app open and blocks the package operation. Preparation expires after
ten minutes and is invalidated when the app starts again. The cask checks the
preparation, absence of the app, confirmed off power readings, absence of the
old helper job and absence of its process before allowing replacement or removal.
Unknown states block it. Run preparation again if the window expires or you
reopen Dilated before the package operation. `dilated package-check` is the
read-only CLI part of this preflight; it does not start the app.

## Remove Dilated

Remove the closed-lid permission while the signed app still exists in Applications:

1. In General settings, turn off Launch at login if enabled.
2. In Closed Lid settings, choose Remove in the Permission group, or run
   `dilated lid-permission remove`. Either asks for your administrator password
   and deletes `/private/etc/sudoers.d/dilated`. Dilated confirms normal sleep
   first. If it can't, leave the app installed and use the reported error.
3. In Automation settings, choose Remove command line tool if this copy installed
   the link. A link to another location is left unchanged.
4. Choose Quit Dilated. This ends app-managed holds and discards saved timers.
   A standalone `dilated run` command continues independently until its command
   finishes.
5. Move Dilated.app to Trash.

If the app is already gone, remove the rule by hand with
`sudo rm /private/etc/sudoers.d/dilated`. Check that `pmset -g | grep SleepDisabled`
shows 0; if it shows 1, run `sudo pmset -a disablesleep 0`.

Normal removal preserves preferences in
`~/Library/Application Support/Dilated`. Removing those preferences is a
separate reset, after the app has stopped. Deleting the app first does not
verify that sleep-disable was cleared.

Keep the app installed if macOS cannot confirm normal sleep. Actual uninstall
acceptance must separately verify rule removal, absence of Dilated-owned
assertions and normal sleep.

## Release acceptance

The beta shipped with the checks listed at the top still open. Before a GA
release, verify the admin prompt and cancelling it, sudo rule integrity and revocation, CLI linking without overwriting files, upgrading from a helper build,
an actual older-to-newer Sparkle update, uninstall and normal sleep. Closed-lid
acceptance also covers macOS 26 and 27, app crash, heartbeat loss, reboot,
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
pass: `heartbeatExpiry`, `stopResume` and `appCrashRecovery`, plus a closed-lid check on at least one of macOS 26 (`macOS26ClosedLid`) or macOS 27 (`macOS27ClosedLid`). Anything else that
is failed or not run stays in the record with its evidence. Staging then names
those checks as unverified in the public release manifest, `latest.json` and the
cask caveats, and the public manifest reports `acceptanceVerified: false` while
any are open. A GA version keeps the full gate above, with every required check
passed.
Accepted release staging also generates `dilated.rb` with the exact version and
DMG digest as a versioned release asset. It does not publish the Homebrew tap.

Before downgrading to an older beta, quit Dilated and back up the entire
`~/Library/Application Support/Dilated` folder, including `triggers.json`.
If you set `DILATED_STATE_DIR`, back up that directory instead. Export preferences
does not include trigger rules. Older builds may not read newly added trigger
conditions; saving triggers there can replace rules they could not load. Quit
Dilated before restoring the folder from your backup.
