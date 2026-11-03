#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --arch arm64 --jobs 4
# Mounted views render synchronously on the main actor; keep deadline tests in a separate run.
mounted_suites='Settings(ContentInteraction|GroupLayout|Render|Scroll)Tests|MountedSettingsTests|TriggerEditorInteractionTests|PackageSheetDismissalTests'
# DILATED_COVERAGE=1 (set by CI) instruments both runs and exports Sources/ coverage to .build/coverage/lcov.info.
coverage_args=()
if [ -n "${DILATED_COVERAGE:-}" ]; then
  coverage_args=(--enable-code-coverage)
  rm -rf .build/coverage
fi
bash scripts/swift-test.sh --jobs 4 ${coverage_args[@]+"${coverage_args[@]}"} --skip "$mounted_suites"
[ -z "${DILATED_COVERAGE:-}" ] || bash scripts/coverage-lcov.sh save
bash scripts/swift-test.sh --jobs 4 ${coverage_args[@]+"${coverage_args[@]}"} --filter "$mounted_suites"
if [ -n "${DILATED_COVERAGE:-}" ]; then
  bash scripts/coverage-lcov.sh save
  bash scripts/coverage-lcov.sh export
fi
python3 -m unittest discover -s Tests/ReleaseTests
node --test website/tests/*.test.mjs
for module in website/dist/*.mjs; do node --check "$module"; done
swift format lint --strict --recursive Sources Tests Package.swift design/menubar/generate.swift design/app-icon/generate.swift scripts/dmg/background.swift scripts/dmg/volume-icon.swift
for script in scripts/build-app.sh scripts/swift-test.sh scripts/verify.sh scripts/verify-website-browsers.sh scripts/coverage-lcov.sh scripts/check-commit-msg.sh; do bash -n "$script"; done
bash -n packaging/mas/dilated-power
bash -n scripts/build-mas.sh
python3 -m unittest Tests/ReleaseTests/test_check_mas_bundle.py
plutil -lint packaging/mas/Info-MAS.plist
plutil -lint packaging/mas/Dilated-MAS.entitlements
bash -n scripts/mas-check-lib.sh
bash -n scripts/mas-repair-agent-check.sh
bash -n scripts/mas-crash-revert-check.sh
bash -n scripts/closed-lid-setup-check.sh
plutil -lint packaging/mas/com.codeswhat.dilated.closed-lid-repair.plist
python3 -c 'import ast; from pathlib import Path; [ast.parse(file.read_text(), filename=str(file)) for file in Path("scripts").rglob("*.py")]'
plutil -lint packaging/Info.plist
plutil -lint packaging/Dilated.entitlements
plutil -lint packaging/com.codeswhat.dilated.helper.plist
plutil -lint packaging/Version.plist
