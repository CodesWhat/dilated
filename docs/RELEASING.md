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

`checks` needs an entry for every name in `ACCEPTANCE_CHECKS` in `scripts/stage-public-release.py`: `macOS26ClosedLid`, `macOS27ClosedLid`, `helperCrashRecovery`, `appCrashRecovery`, `heartbeatExpiry`, `stopResume`, `guardTransitions`, `rebootRecovery`, `approvalDenied`, `helperUpgrade`, `sparkleUpgrade`, `uninstallNormalSleep` and `nativeUI`. Each has `status`, `machine`, `macOS` and `evidence`.

For a GA version every check in `ACCEPTANCE_CHECKS` must be `passed`. For an alpha, beta or rc, `macOS26ClosedLid`, `heartbeatExpiry` and `stopResume` must be `passed`. The others can be `failed` or `notRun`, with evidence saying why. Staging lists those as unverified in the manifest, `latest.json` and the cask caveats. Fixtures and mock runs aren't hardware evidence.

## 5. Stage the public release

```sh
python3 scripts/stage-public-release.py /absolute/path/to/release-output/<version> \
  --public-dir build/public-release-assets --acceptance /absolute/path/to/acceptance.json
```

It re-checks the tag, digests, notarization and the extracted app, builds the source tarball from the tag, generates and verifies the signed appcast, writes `latest.json` and `dilated.rb`, and adds the release to `build/public-release-assets`. Keep that directory between releases. Published versioned files are immutable and only the feed and `latest.json` get replaced.

## 6. Publish the website

```sh
python3 scripts/publish-website.py --public-dir build/public-release-assets
python3 scripts/publish-website.py --public-dir build/public-release-assets --production
```

The first run only validates. `--production` deploys the committed `website/dist` plus the retained `releases/` and `updates/` to the Vercel project. The checkout has to be clean, and `/download/file` and `/source` in `website/vercel.json` have to point at the staged release. Update them in the version bump if they don't.

## 7. Homebrew and GitHub

Copy the staged `dilated.rb` from `releases/<version>/` into `Casks/dilated.rb` in `CodesWhat/homebrew-tap` and push it. Attach the DMG, ZIP, their `.sha256` files and `release-manifest.json` to the GitHub release for `v<display version>`, marked as a prerelease for alpha, beta and rc.

## 8. Verify after publishing

Fetch these without any authentication and compare checksums against the manifest:

- `https://dilated.codeswhat.com/updates/appcast.xml`
- `https://dilated.codeswhat.com/releases/latest.json`
- `https://dilated.codeswhat.com/download/file`, the full DMG, then its SHA-256
- `https://dilated.codeswhat.com/source`

Check the downloaded DMG with `codesign`, `stapler validate` and `spctl`. A 200 or a signed feed doesn't prove an update installs over an older build, so test that separately.

## Signing

The Sparkle signing key lives in the Keychain under account `com.codeswhat.dilated`. Never export it into source, deployment files or logs.
