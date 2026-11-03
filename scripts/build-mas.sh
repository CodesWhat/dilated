#!/usr/bin/env bash
# Builds the sandboxed Mac App Store bundle: DILATED_CHANNEL=mas, bundle ID com.codeswhat.dilated.appstore,
# no Sparkle, no CLI, no helper. Mirrors scripts/build-app.sh (app shell from packaging/automation-shell).
# Usage: scripts/build-mas.sh --output-dir DIR [--adhoc]
#   --adhoc  sign with DILATED_SIGN_IDENTITY=- and skip the .pkg (no certificates needed).
# Otherwise set DILATED_SIGN_IDENTITY (Apple Distribution), DILATED_INSTALLER_IDENTITY (Mac Installer
# Distribution), DILATED_MAS_PROFILE (Mac App Store .provisionprofile) and DILATED_TEAM_ID.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
bundle_id="com.codeswhat.dilated.appstore"
output_dir=""
adhoc=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc) adhoc=true; shift ;;
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
    : "${DILATED_TEAM_ID:?DILATED_TEAM_ID is required with a real identity}"
    test -f "$DILATED_MAS_PROFILE"
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
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    INFOPLIST_FILE="$root/packaging/mas/Info-MAS.plist" -jobs 4 build >"$shell_log" 2>&1; then
    tail -n 60 "$shell_log" >&2
    echo "MAS app shell build failed. See $shell_log" >&2
    exit 1
fi
shell_app="$shell_dir/DerivedData/Build/Products/Release/DilatedApp.app"
test -d "$shell_app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$shell_app/Contents/MacOS/DilatedApp" "$app/Contents/MacOS/DilatedApp"
ditto "$shell_app/Contents/Resources/Metadata.appintents" "$app/Contents/Resources/Metadata.appintents"
# Start from the plist Xcode produced (it adds the DT* build keys) and layer the release metadata on it.
cp "$shell_app/Contents/Info.plist" "$app/Contents/Info.plist"
python3 - "$app/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys
destination = Path(sys.argv[1])
info = plistlib.loads(destination.read_bytes())
info.update(plistlib.loads(Path('packaging/Version.plist').read_bytes()))
info['DilatedSourceRevision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
destination.write_bytes(plistlib.dumps(info))
PY
cp packaging/Dilated.icns "$app/Contents/Resources/Dilated.icns"
cp packaging/Dilated.sdef "$app/Contents/Resources/Dilated.sdef"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp docs/THIRD-PARTY.md "$app/Contents/Resources/THIRD-PARTY.md"
python3 scripts/package-release.py --check-automation "$app"
ui_bundle="$bin_dir/Dilated_DilatedUI.bundle"
test -d "$ui_bundle"
ditto "$ui_bundle" "$app/Contents/Resources/$(basename "$ui_bundle")"
python3 scripts/normalize-resource-bundle.py "$app/Contents/Resources/$(basename "$ui_bundle")"
plutil -lint "$app/Contents/Resources/$(basename "$ui_bundle")/Contents/Info.plist"

timestamp="--timestamp"
if [[ "$sign_as" == "-" ]]; then timestamp="--timestamp=none"; fi
entitlements="$root/packaging/mas/Dilated-MAS.entitlements"
if [[ "$sign_as" != "-" ]]; then
    cp "$DILATED_MAS_PROFILE" "$app/Contents/embedded.provisionprofile"
    entitlements="$output_dir/Dilated-MAS.signing.entitlements"
    python3 - "$root/packaging/mas/Dilated-MAS.entitlements" "$entitlements" "$DILATED_TEAM_ID" "$bundle_id" <<'PY'
from pathlib import Path
import plistlib
import sys
source, destination, team, bundle_id = sys.argv[1:]
entitlements = plistlib.loads(Path(source).read_bytes())
entitlements['com.apple.application-identifier'] = f'{team}.{bundle_id}'
entitlements['com.apple.developer.team-identifier'] = team
Path(destination).write_bytes(plistlib.dumps(entitlements))
PY
fi
for nested in "$app/Contents/Resources/"*.bundle; do
    codesign --force "$timestamp" --sign "$sign_as" "$nested"
done
codesign --force "$timestamp" --entitlements "$entitlements" --sign "$sign_as" "$app"
codesign --verify --deep --strict "$app"
echo "app: $app"

if [[ "$sign_as" == "-" ]]; then
    echo "pkg: skipped (ad-hoc signing; pass a real DILATED_SIGN_IDENTITY to build Dilated.pkg)"
else
    productbuild --component "$app" /Applications --sign "$DILATED_INSTALLER_IDENTITY" "$output_dir/Dilated.pkg"
    pkgutil --check-signature "$output_dir/Dilated.pkg"
    echo "pkg: $output_dir/Dilated.pkg"
fi
