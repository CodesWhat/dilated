#!/usr/bin/env bash
# Adapted from Mouthtype's build-app.sh (Scott Benson) and Parrot, MIT,
# Copyright (c) 2026 Humanitas Labs. See docs/THIRD-PARTY.md.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Use debug or release" >&2; exit 1 ;; esac
swift build -c "$configuration" --arch arm64 --jobs 4
bin_dir="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
app="${DILATED_BUILD_DIR:-$PWD/build}/Dilated.app"
if pgrep -f "$app/Contents/MacOS/DilatedApp" >/dev/null; then
    echo "Quit the running build of Dilated before rebuilding its bundle." >&2
    exit 1
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
cp "$bin_dir/DilatedApp" "$app/Contents/MacOS/DilatedApp"
cp "$bin_dir/dilated" "$app/Contents/MacOS/dilated"
cp "$bin_dir/dilated-helper" "$app/Contents/MacOS/dilated-helper"
cp packaging/com.codeswhat.dilated.helper.plist "$app/Contents/Library/LaunchDaemons/"
cp packaging/Info.plist "$app/Contents/Info.plist"
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
cp LICENSE "$app/Contents/Resources/LICENSE"
cp docs/THIRD-PARTY.md "$app/Contents/Resources/THIRD-PARTY.md"
sparkle=".build/artifacts/sparkle/Sparkle"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE"
for bundle in "$bin_dir"/Dilated_DilatedUI.bundle; do
    test -d "$bundle"
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
sign_as="${DILATED_SIGN_IDENTITY:--}"
timestamp="--timestamp"
if [[ "$sign_as" == "-" ]]; then timestamp="--timestamp=none"; fi
framework="$app/Contents/Frameworks/Sparkle.framework"
for nested in "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app"; do
    codesign --force --options runtime "$timestamp" --preserve-metadata=entitlements --sign "$sign_as" "$nested"
done
codesign --force --options runtime "$timestamp" --sign "$sign_as" "$framework"
for nested in "$app/Contents/Resources/"*.bundle; do
    codesign --force --options runtime "$timestamp" --sign "$sign_as" "$nested"
done
codesign --force --options runtime "$timestamp" --sign "$sign_as" "$app/Contents/MacOS/dilated"
codesign --force --identifier com.codeswhat.dilated.helper --options runtime "$timestamp" --sign "$sign_as" "$app/Contents/MacOS/dilated-helper"
codesign --force --options runtime "$timestamp" --sign "$sign_as" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
