# Releasing Dilated

How a build goes from version bump to a verified public download. Run the steps in order.

## 1. Bump version and notes

`packaging/Version.plist` holds the release metadata. `DilatedDisplayVersion` carries the prerelease label (`1.0.0-beta.1`). `CFBundleShortVersionString` stays numeric (`1.0.0`). `CFBundleVersion` is a positive integer that goes up for every distributed build.

Update `packaging/ReleaseNotes.txt` in the same change. It's embedded in the Sparkle appcast, so keep it to a few lines. Update the README and website copy if the version or status changed.

## 2. Tag the reviewed revision

Land the work on `main` through a dev-branch PR. Tag the reviewed `main` revision `v<display version>`, for example `v1.0.0-beta.1`, and push the tag. The release scripts refuse a dirty tree or a HEAD that isn't that tag.

## 3. Package

From the exact tag:

```sh
python3 scripts/package-release.py --output-dir /absolute/path/to/release-output
```

This builds, signs and notarizes the app, makes the ZIP, then builds, signs and notarizes the DMG. Each is stapled and checked with Gatekeeper. Notarization uses the App Store Connect key in `~/.appstoreconnect` (`config.env` plus `private_keys/AuthKey_<ASC_KEY_ID>.p8`). The script never prints the key, key ID or issuer. Pass `--notary-profile <name>` to use a Keychain profile instead. If Apple rejects a submission, read the saved log. Don't force it.

## 4. Write the acceptance record

A JSON file tied to the exact artifacts:

```json
{
  "version": "1.0.0-beta.1",
  "build": "6",
  "sourceRevision": "<40-character commit>",
  "archiveSHA256": "<ZIP digest from release-manifest.json>",
  "dmgSHA256": "<DMG digest from release-manifest.json>",
  "checks": {
    "macOS26ClosedLid": {
      "status": "passed",
      "machine": "<machine name>",
      "macOS": "26.x",
      "evidence": "<what was run and what happened>"
    }
  }
}
```

`checks` needs an entry for every name in `ACCEPTANCE_CHECKS` in `scripts/stage-public-release.py`: `macOS26ClosedLid`, `macOS27ClosedLid`, `sudoRuleRevoked`, `appCrashRecovery`, `heartbeatExpiry`, `stopResume`, `guardTransitions`, `rebootRecovery`, `adminPromptCancelled`, `helperMigration`, `sudoRuleIntegrity`, `sparkleUpgrade`, `uninstallNormalSleep` and `nativeUI`. Each has `status`, `machine`, `macOS` and `evidence`.

For GA releases, every check in `ACCEPTANCE_CHECKS` must be `passed`. For an alpha, beta or rc, `appCrashRecovery`, `heartbeatExpiry` and `stopResume` must be `passed`, and so must at least one of `macOS26ClosedLid` or `macOS27ClosedLid`, on any supported macOS. The others can be `failed` or `notRun`, with evidence saying why. Staging lists those, including whichever closed-lid check wasn't passed, as unverified in the manifest, `latest.json` and the cask caveats. Fixtures and mock runs aren't hardware evidence.

The generated cask removes the closed-lid sudo rule (`/private/etc/sudoers.d/dilated`) with a `zap` stanza only. It is never in `uninstall`, because Homebrew runs uninstall during an upgrade and that would strip the rule from every upgraded install.

## 5. Stage the public release

```sh
PUBLIC_DIR="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/build/public-release-assets"
python3 scripts/stage-public-release.py /absolute/path/to/release-output/<version> \
  --public-dir "$PUBLIC_DIR" --acceptance /absolute/path/to/acceptance.json
```

`--public-dir` is always the retained `build/public-release-assets` in the main checkout, never a per-worktree or per-release path. The `git rev-parse` line resolves to the main checkout from any worktree, and it is also the default when `--public-dir` is omitted. A Vercel deploy replaces the whole site, so publishing from a fresh directory drops every earlier release; the stage script warns on stderr when the directory has no history but https://dilated.app already has a release.

It re-checks the tag, digests, notarization and the extracted app, builds the source tarball from the tag, generates and verifies the signed appcast, writes `latest.json` and `dilated.rb`, and adds the release to `build/public-release-assets`. Keep that directory between releases. Published versioned files are immutable and only the feed and `latest.json` get replaced.

## 6. Publish the website

```sh
python3 scripts/publish-website.py --public-dir "$PUBLIC_DIR"
python3 scripts/publish-website.py --public-dir "$PUBLIC_DIR" --production
```

The first run only validates. Before deploying, `--production` fetches the live `latest.json` and appcast and refuses if the directory lacks any release they reference (a directory holding only the new release gets its own error). If dilated.app can't be fetched it refuses too, unless you pass `--allow-offline`. It then deploys the committed `website/dist` plus the retained `releases/` and `updates/` to the Vercel project. The checkout has to be clean, and `/download/file` and `/source` in `website/vercel.json` have to point at the staged release. Update them in the version bump if they don't.

## 7. Homebrew and GitHub

Copy the staged `dilated.rb` from `releases/<version>/` into `Casks/dilated.rb` in `CodesWhat/homebrew-tap` and push it. Attach the DMG, ZIP, their `.sha256` files and `release-manifest.json` to the GitHub release for `v<display version>`, marked as a prerelease for alpha, beta and rc.

## 8. Verify after publishing

Fetch these without any authentication and compare checksums against the manifest:

- `https://dilated.app/updates/appcast.xml`
- `https://dilated.app/releases/latest.json`
- `https://dilated.app/download/file`, the full DMG, then its SHA-256
- `https://dilated.app/source`

Check the downloaded DMG with `codesign`, `stapler validate` and `spctl`. A 200 or a signed feed doesn't prove an update installs over an older build, so test that separately.

## Signing

The Sparkle signing key lives in the Keychain under account `com.codeswhat.dilated`. Never export it into source, deployment files or logs.

## Building the MAS variant

The Mac App Store build is a separate sandboxed bundle (`com.codeswhat.dilated.appstore`, `DILATED_CHANNEL=mas`) with no Sparkle, CLI or helper. It uses `packaging/mas/Info-MAS.plist` and `packaging/mas/Dilated-MAS.entitlements`. The App Store Connect record is "Dilated" (app ID 6830346021, SKU `dilated-appstore`).

### Versions

The MAS build reads the same `packaging/Version.plist` as the direct build, so `DilatedDisplayVersion` and `CFBundleShortVersionString` are the same on both channels. A MAS build is only cut from a tag the direct build already shipped.

`CFBundleVersion` is one global counter shared with the direct build, not a second MAS-only series. App Store Connect rejects an upload whose build number isn't higher than every earlier upload, and a direct hotfix bumps the number too, so a single counter can't fall behind in either channel. Gaps are fine. A number that App Store Connect has already processed is spent even if the build is rejected: bump `CFBundleVersion` and rebuild instead of re-uploading.

The store can't carry a beta. Ship prereleases through TestFlight only, and submit to the store from GA onward.

### Build

The signing identities and profiles live in the login Keychain and `~/Library/MobileDevice/Provisioning Profiles/`. Look each profile up by name, not by UUID:

```sh
for f in "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile; do
  [ "$(security cms -D -i "$f" | plutil -extract Name raw -o - -)" = "Dilated App Store" ] && DILATED_MAS_PROFILE="$f"
  [ "$(security cms -D -i "$f" | plutil -extract Name raw -o - -)" = "Dilated Controls App Store" ] && DILATED_MAS_CONTROL_PROFILE="$f"
done
export DILATED_MAS_PROFILE
export DILATED_MAS_CONTROL_PROFILE
export DILATED_SIGN_IDENTITY="Apple Distribution: Scott Benson (3524374A2S)"
export DILATED_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Scott Benson (3524374A2S)"
export DILATED_TEAM_ID=3524374A2S
bash scripts/build-mas.sh --output-dir /absolute/path/to/mas-output
python3 -I scripts/check-mas-bundle.py /absolute/path/to/mas-output/Dilated.app
```

The script embeds separate profiles for `com.codeswhat.dilated.appstore` and `com.codeswhat.dilated.appstore.controls`, adds their application and team identifiers to the signing entitlements, signs the extension before the host, and runs `productbuild` to write `Dilated.pkg`. Both share the Mac Team-ID app group `3524374A2S.com.codeswhat.dilated.controls`. For a certificate-free check, `bash scripts/build-mas.sh --adhoc --output-dir ...` signs with `DILATED_SIGN_IDENTITY=-` and skips the `.pkg`. CI runs that and the checker on every push.

The checker exits 1 on a key containing `temporary-exception`, an entitlement outside the allowlist, a foreign app group, an embedded executable besides the host and validated controls extension, Sparkle or `SU*` keys, a daemon or LaunchAgent plist, a non-arm64 slice, a missing `LSApplicationCategoryType` or a wrong bundle ID. The controls checker also verifies metadata, version and signatures during assembly. Run the checks on the real build before upload, not only the ad-hoc one.

### Validate and upload

Validation and upload use the same App Store Connect key as notarization, read from `~/.appstoreconnect/config.env` (`ASC_KEY_ID`, `ASC_ISSUER_ID`) with `private_keys/AuthKey_<ASC_KEY_ID>.p8`. `altool` finds the `.p8` there on its own. Source the file without echoing it.

```sh
. ~/.appstoreconnect/config.env
xcrun altool --validate-app -f /absolute/path/to/mas-output/Dilated.pkg -t macos --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f /absolute/path/to/mas-output/Dilated.pkg -t macos --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"
```

Don't upload if validation fails. `--upload-app -f` is the form that mirrors `--validate-app` for a macOS `.pkg`. `--upload-package` is the variant that also needs the app's Apple ID and bundle metadata on the command line, so skip it. The build shows up in App Store Connect after processing, which takes a few minutes.

### TestFlight, then the store

Every build goes to TestFlight internal testing first. Install it from TestFlight on a Mac, run the closed-lid companion path, and confirm the sandboxed app launches, shows no direct-only surfaces and quits cleanly. Only then attach that same build to the store version and submit for review. Don't rebuild between TestFlight and submission, because a rebuild is a different binary with a new `CFBundleVersion`.

### MAS lags direct

Hotfixes ship direct first (see sections 1 to 8). The MAS build follows, subject to Apple review, which typically takes a day or two. There is no Sparkle in the MAS bundle, so the store is its only update channel, and the MAS app's update UI is compiled out. The Homebrew cask, appcast and GitHub release DMG don't change when a MAS build ships.

### Closed-lid setup companion

The MAS build installs nothing privileged, so `Dilated Closed-Lid Setup.app` (`com.codeswhat.dilated.closed-lid-setup`, target `DilatedSetup`) is a separate notarized Developer ID download. Package it from a clean tree:

```sh
python3 scripts/package-setup.py --output-dir /absolute/path/to/setup-output --candidate
```

Drop `--candidate` to build from the exact release tag. It builds arm64, signs inside-out with the hardened runtime and a timestamp (no entitlements, no sandbox), notarizes with the same App Store Connect key or `--notary-profile` as `package-release.py`, staples, and zips with `ditto`. Before zipping it runs the packaged app's hidden `--assets --json` and `--status --json` modes, which fail unless the bundled `dilated-power` script and LaunchAgent template resolve and the script matches `expectedScriptSHA256`. Output is the ZIP, its `.sha256` and `setup-manifest.json` (version, SHA-256, source revision). Nothing here stages or publishes it: use a separate output directory, never `build/public-release-assets`. Publish it only alongside a MAS release, since the MAS app is the only thing that points users at it, and never on a direct-only release.
