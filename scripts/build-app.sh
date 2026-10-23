#!/usr/bin/env bash
# Adapted from Mouthtype's build-app.sh (Scott Benson) and Parrot, MIT,
# Copyright (c) 2026 Humanitas Labs. See docs/THIRD-PARTY.md.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Use debug or release" >&2; exit 1 ;; esac
swift build -c "$configuration" --arch arm64 --jobs 4
bin_dir="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
app="$PWD/build/Dilated.app"
if pgrep -f "$app/Contents/MacOS/DilatedApp" >/dev/null; then
    echo "Quit the running build of Dilated before rebuilding its bundle." >&2
    exit 1
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DilatedApp" "$app/Contents/MacOS/DilatedApp"
cp "$bin_dir/dilated" "$app/Contents/MacOS/dilated"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp packaging/Dilated.icns "$app/Contents/Resources/Dilated.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp docs/THIRD-PARTY.md "$app/Contents/Resources/THIRD-PARTY.md"
for bundle in "$bin_dir"/Dilated_DilatedUI.bundle; do
    test -d "$bundle"
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
sign_as="${DILATED_SIGN_IDENTITY:--}"
for nested in "$app/Contents/Resources/"*.bundle; do
    codesign --force --options runtime --timestamp=none --sign "$sign_as" "$nested"
done
codesign --force --options runtime --timestamp=none --sign "$sign_as" "$app/Contents/MacOS/dilated"
codesign --force --options runtime --timestamp=none --sign "$sign_as" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
