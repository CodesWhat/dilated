#!/usr/bin/env bash
# Builds the sandboxed Mac App Store bundle: DILATED_CHANNEL=mas, bundle ID com.codeswhat.dilated.appstore,
# no Sparkle, no CLI, no helper. Mirrors scripts/build-app.sh (app shell from packaging/automation-shell).
# Usage: scripts/build-mas.sh --output-dir DIR [--adhoc] [--candidate]
#   --adhoc      sign with DILATED_SIGN_IDENTITY=- and skip the .pkg (no certificates needed). An
#                ad-hoc bundle can't be submitted, so it skips the source checks below.
#   --candidate  a really signed build from a clean tree without a release tag (cannot be submitted).
# A really signed build, like scripts/package-release.py, needs a clean tree (untracked files
# included) with HEAD on the exact tag v<CFBundleShortVersionString>, or on the build-specific tag
# mas/v<CFBundleShortVersionString>-build<MASBundleVersion> for a rebuild after a rejected build.
# Otherwise set DILATED_SIGN_IDENTITY (Apple Distribution), DILATED_INSTALLER_IDENTITY (Mac Installer
# Distribution), DILATED_MAS_PROFILE and DILATED_MAS_CONTROL_PROFILE (host/extension
# Mac App Store .provisionprofile paths), and DILATED_TEAM_ID.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
bundle_id="com.codeswhat.dilated.appstore"
output_dir=""
adhoc=false
candidate=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc) adhoc=true; shift ;;
        --candidate) candidate=true; shift ;;
        --output-dir) output_dir="${2:?--output-dir needs a path}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
if [[ -z "$output_dir" ]]; then echo "--output-dir is required" >&2; exit 1; fi
if $adhoc; then export DILATED_SIGN_IDENTITY="-"; fi
sign_as="${DILATED_SIGN_IDENTITY:-}"
if [[ -z "$sign_as" ]]; then
    echo "Pass --adhoc or set DILATED_SIGN_IDENTITY." >&2
    exit 1
fi
if [[ "$sign_as" != "-" ]]; then
    : "${DILATED_INSTALLER_IDENTITY:?DILATED_INSTALLER_IDENTITY (Mac Installer Distribution) is required with a real identity}"
    : "${DILATED_MAS_PROFILE:?DILATED_MAS_PROFILE (provisioning profile path) is required with a real identity}"
    : "${DILATED_MAS_CONTROL_PROFILE:?DILATED_MAS_CONTROL_PROFILE (controls extension provisioning profile) is required with a real identity}"
    : "${DILATED_TEAM_ID:?DILATED_TEAM_ID is required with a real identity}"
    test -f "$DILATED_MAS_PROFILE"
    test -f "$DILATED_MAS_CONTROL_PROFILE"
fi
if [[ "$sign_as" != "-" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Release source must be clean, including untracked files." >&2
        exit 1
    fi
    if ! $candidate; then
        version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Version.plist)"
        build="$(/usr/libexec/PlistBuddy -c 'Print :MASBundleVersion' packaging/Version.plist)"
        head_sha="$(git rev-parse HEAD)"
        tagged="$(git rev-parse --verify --quiet "refs/tags/v${version}^{commit}" || true)"
        mas_tagged="$(git rev-parse --verify --quiet "refs/tags/mas/v${version}-build${build}^{commit}" || true)"
        if [[ "$tagged" != "$head_sha" && "$mas_tagged" != "$head_sha" ]]; then
            echo "HEAD must match the release tag v${version} or the build tag mas/v${version}-build${build} (use --candidate for an untagged build)." >&2
            exit 1
        fi
    fi
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
app="$output_dir/Dilated.app"
export DILATED_CHANNEL=mas

# Everything the MAS build generates stays out of the direct build's paths.
shell_dir="$root/build/mas-shell"
mkdir -p "$shell_dir"
if ! swift build -c release --arch arm64 --jobs 4 --scratch-path .build-mas --product DilatedApp >"$shell_dir/swift-build.log" 2>&1; then
    tail -n 60 "$shell_dir/swift-build.log" >&2
    echo "MAS swift build failed. See $shell_dir/swift-build.log" >&2
    exit 1
fi
bin_dir="$(swift build -c release --arch arm64 --scratch-path .build-mas --show-bin-path)"
xcodegen generate --spec packaging/automation-shell/project.yml --project "$shell_dir"
shell_log="$shell_dir/release-build.log"
if ! xcodebuild -project "$shell_dir/DilatedAutomationShell.xcodeproj" -scheme DilatedAutomationShell \
    -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$shell_dir/DerivedData" \
    -clonedSourcePackagesDirPath "$shell_dir/Packages" \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 DILATED_HOST_BUNDLE_ID="$bundle_id" DILATED_CHANNEL_FLAGS=MAS_CHANNEL \
    DILATED_HOST_INFO_PLIST="$root/packaging/mas/Info-MAS.plist" -jobs 4 build >"$shell_log" 2>&1; then
    tail -n 60 "$shell_log" >&2
    echo "MAS app shell build failed. See $shell_log" >&2
    exit 1
fi
shell_app="$shell_dir/DerivedData/Build/Products/Release/DilatedApp.app"
test -d "$shell_app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
source scripts/build-lib.sh
dilated_copy_shell_parts "$app" "$shell_app"
# Start from the plist Xcode produced (it adds the DT* build keys) and layer the release metadata on it.
cp "$shell_app/Contents/Info.plist" "$app/Contents/Info.plist"
python3 scripts/bundle-metadata.py stamp "$app/Contents/Info.plist" --display-version --mas-build
dilated_copy_static_resources "$app"
python3 scripts/package-release.py --check-automation "$app"
python3 scripts/controls-bundle.py "$app"
dilated_add_ui_bundle "$app" "$bin_dir"

timestamp="--timestamp"
if [[ "$sign_as" == "-" ]]; then timestamp="--timestamp=none"; fi
entitlements="$root/packaging/mas/Dilated-MAS.entitlements"
control_entitlements="$root/packaging/controls/DilatedControls.entitlements"
if [[ "$sign_as" != "-" ]]; then
    install -m 644 "$DILATED_MAS_PROFILE" "$app/Contents/embedded.provisionprofile"
    entitlements="$output_dir/Dilated-MAS.signing.entitlements"
    install -m 644 "$DILATED_MAS_CONTROL_PROFILE" "$app/Contents/PlugIns/DilatedControls.appex/Contents/embedded.provisionprofile"
    control_entitlements="$output_dir/DilatedControls-MAS.signing.entitlements"
    python3 scripts/bundle-metadata.py entitlements "$root/packaging/mas/Dilated-MAS.entitlements" \
        "$entitlements" "$DILATED_TEAM_ID" "$bundle_id"
    python3 scripts/bundle-metadata.py entitlements "$root/packaging/controls/DilatedControls.entitlements" \
        "$control_entitlements" "$DILATED_TEAM_ID" "$bundle_id.controls"
fi
codesign --force "$timestamp" --entitlements "$control_entitlements" --sign "$sign_as" \
    "$app/Contents/PlugIns/DilatedControls.appex"
for nested in "$app/Contents/Resources/"*.bundle; do
    codesign --force "$timestamp" --sign "$sign_as" "$nested"
done
codesign --force "$timestamp" --entitlements "$entitlements" --sign "$sign_as" "$app"
codesign --verify --deep --strict "$app"
python3 scripts/controls-bundle.py "$app" --signed
python3 -I scripts/check-mas-bundle.py "$app"
echo "app: $app"

if [[ "$sign_as" == "-" ]]; then
    echo "pkg: skipped (ad-hoc signing; pass a real DILATED_SIGN_IDENTITY to build Dilated.pkg)"
else
    productbuild --component "$app" /Applications --sign "$DILATED_INSTALLER_IDENTITY" "$output_dir/Dilated.pkg"
    pkgutil --check-signature "$output_dir/Dilated.pkg"
    echo "pkg: $output_dir/Dilated.pkg"
fi
