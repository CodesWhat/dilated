# shellcheck shell=bash
# Steps shared by scripts/build-app.sh and scripts/build-mas.sh. Source it from the repository root.

# dilated_copy_shell_parts APP SHELL_APP: the automation shell's executable, intents metadata and plug-ins.
dilated_copy_shell_parts() {
    local app="$1" shell_app="$2"
    cp "$shell_app/Contents/MacOS/DilatedApp" "$app/Contents/MacOS/DilatedApp"
    ditto "$shell_app/Contents/Resources/Metadata.appintents" "$app/Contents/Resources/Metadata.appintents"
    ditto "$shell_app/Contents/PlugIns" "$app/Contents/PlugIns"
}

# dilated_copy_static_resources APP: icon, scripting definition and licenses.
dilated_copy_static_resources() {
    local app="$1"
    cp packaging/Dilated.icns "$app/Contents/Resources/Dilated.icns"
    cp packaging/Dilated.sdef "$app/Contents/Resources/Dilated.sdef"
    cp LICENSE "$app/Contents/Resources/LICENSE"
    cp docs/THIRD-PARTY.md "$app/Contents/Resources/THIRD-PARTY.md"
}

# dilated_add_ui_bundle APP BIN_DIR [--mas-build]: the SwiftPM resource bundle, normalized and lint-checked.
dilated_add_ui_bundle() {
    local app="$1" bundle="$2/Dilated_DilatedUI.bundle"
    test -d "$bundle"
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
    python3 scripts/normalize-resource-bundle.py "$app/Contents/Resources/$(basename "$bundle")" ${3:+"$3"}
    plutil -lint "$app/Contents/Resources/$(basename "$bundle")/Contents/Info.plist"
}
