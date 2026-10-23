#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --arch arm64 --jobs 4
bash scripts/swift-test.sh --jobs 4
python3 -m unittest discover -s Tests/ReleaseTests
swift format lint --strict --recursive Sources Tests Package.swift design/menubar/generate.swift design/app-icon/generate.swift scripts/dmg/background.swift scripts/dmg/volume-icon.swift
bash -n scripts/build-app.sh scripts/swift-test.sh scripts/verify.sh
python3 -c 'import ast; from pathlib import Path; [ast.parse(file.read_text(), filename=str(file)) for file in Path("scripts").rglob("*.py")]'
plutil -lint packaging/Info.plist
plutil -lint packaging/com.codeswhat.dilated.helper.plist
plutil -lint packaging/Version.plist
