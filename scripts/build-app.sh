#!/usr/bin/env bash
# Adapted from Mouthtype's build-app.sh (Scott Benson) and Parrot, MIT,
# Copyright (c) 2026 Humanitas Labs. See docs/THIRD-PARTY.md.
set -euo pipefail
configuration="${1:-debug}"
if [[ $# -gt 0 ]]; then shift; fi
case "$configuration" in debug|release) ;; *) echo "Use debug or release" >&2; exit 1 ;; esac
verify=false
logs=false
for option in "$@"; do
    case "$option" in
        --verify) verify=true ;;
        --logs) logs=true ;;
        *) echo "Unknown option: $option" >&2; exit 1 ;;
    esac
done
if $logs && ! $verify; then
    echo "--logs requires --verify" >&2
    exit 1
fi
if $verify && [[ -n "${DILATED_STATE_DIR:-}" ]]; then
    DILATED_STATE_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$DILATED_STATE_DIR")"
    export DILATED_STATE_DIR
fi
cd "$(dirname "$0")/.."
app="${DILATED_BUILD_DIR:-$PWD/build}/Dilated.app"
dev_pids() {
    ps -axo pid=,comm= | while read -r pid executable; do
        if [[ "$executable" == "$app/Contents/MacOS/DilatedApp" ]]; then echo "$pid"; fi
        true
    done
}
if $verify; then
    resolved_app="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$app")"
    if [[ "$resolved_app" != "$(pwd -P)/build/Dilated.app" ]]; then
        echo "--verify only operates on build/Dilated.app" >&2
        exit 1
    fi
    app="$resolved_app"
    other_app="$(ps -axo pid=,comm= | while read -r pid executable; do
        if [[ "$executable" == */Contents/MacOS/DilatedApp && "$executable" != "$app/Contents/MacOS/DilatedApp" ]]; then
            echo "$pid"
        fi
        true
    done)"
    if [[ -n "$other_app" ]]; then
        echo "Quit the other Dilated app before --verify; refusing to control another Dilated app." >&2
        exit 1
    fi
    if [[ -n "$(dev_pids)" ]]; then
        "$app/Contents/MacOS/dilated" prepare-update
        for ((attempt=0; attempt<50; attempt++)); do
            [[ -z "$(dev_pids)" ]] && break
            sleep 0.1
        done
        if [[ -n "$(dev_pids)" ]]; then
            echo "The dev app did not quit; refusing to rebuild its bundle." >&2
            exit 1
        fi
    fi
fi
swift build -c "$configuration" --arch arm64 --jobs 4
python3 scripts/build-shell.py "$configuration"
bin_dir="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
if pgrep -f "$app/Contents/MacOS/DilatedApp" >/dev/null; then
    echo "Quit the running build of Dilated before rebuilding its bundle." >&2
    exit 1
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
shell_configuration="Debug"
if [[ "$configuration" == "release" ]]; then shell_configuration="Release"; fi
shell_app="build/automation-shell/DerivedData/Build/Products/$shell_configuration/DilatedApp.app"
source scripts/build-lib.sh
dilated_copy_shell_parts "$app" "$shell_app"
cp "$bin_dir/dilated" "$app/Contents/MacOS/dilated"
# The helper plist ships for one release so macOS can unregister the job older installs still
# have. The helper executable is gone.
cp packaging/com.codeswhat.dilated.helper.plist "$app/Contents/Library/LaunchDaemons/"
cp packaging/Info.plist "$app/Contents/Info.plist"
updates="${DILATED_ENABLE_UPDATES:-0}"
if [[ "$updates" != "0" && "$updates" != "1" ]]; then
    echo "DILATED_ENABLE_UPDATES must be 0 or 1" >&2
    exit 1
fi
python3 scripts/bundle-metadata.py stamp "$app/Contents/Info.plist" --updates "$updates"
dilated_copy_static_resources "$app"
sparkle=".build/artifacts/sparkle/Sparkle"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE"
python3 scripts/package-release.py --check-automation "$app"
python3 scripts/controls-bundle.py "$app"
dilated_add_ui_bundle "$app" "$bin_dir"
sign_as="${DILATED_SIGN_IDENTITY:--}"
timestamp="--timestamp"
sign_options=(--options runtime)
if [[ "$sign_as" == "-" ]]; then
    timestamp="--timestamp=none"
    sign_options=(--options 0)
fi
framework="$app/Contents/Frameworks/Sparkle.framework"
for nested in "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app"; do
    codesign --force "${sign_options[@]}" "$timestamp" --preserve-metadata=entitlements --sign "$sign_as" "$nested"
done
codesign --force "${sign_options[@]}" "$timestamp" --sign "$sign_as" "$framework"
for nested in "$app/Contents/Resources/"*.bundle; do
    codesign --force "${sign_options[@]}" "$timestamp" --sign "$sign_as" "$nested"
done
codesign --force "${sign_options[@]}" "$timestamp" --sign "$sign_as" "$app/Contents/MacOS/dilated"
codesign --force "${sign_options[@]}" "$timestamp" --entitlements packaging/controls/DilatedControls.entitlements \
    --sign "$sign_as" "$app/Contents/PlugIns/DilatedControls.appex"
codesign --force "${sign_options[@]}" "$timestamp" --entitlements packaging/Dilated.entitlements --sign "$sign_as" "$app"
codesign --verify --deep --strict "$app"
python3 scripts/controls-bundle.py "$app" --signed
echo "$app"
if $verify; then
    launch_args=(-n)
    if [[ -n "${DILATED_STATE_DIR:-}" ]]; then
        launch_args+=(--env "DILATED_STATE_DIR=$DILATED_STATE_DIR")
    fi
    open "${launch_args[@]}" "$app"
    for ((attempt=0; attempt<50; attempt++)); do
        running="$(dev_pids)"
        if [[ -n "$running" ]]; then break; fi
        sleep 0.1
    done
    if [[ -z "$running" ]]; then
        echo "The dev app did not launch within 5 seconds." >&2
        exit 1
    fi
    echo "Running Dilated PID: $running"
    if $logs; then
        exec log stream --predicate 'process == "DilatedApp"' --timeout 5m
    fi
fi
