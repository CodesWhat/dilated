#!/usr/bin/env bash
# Builds the Mac App Store channel (DILATED_CHANNEL=mas) in its own build path and fails if the app binary links Sparkle.
# Usage: scripts/check-mas-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=.build-mas
DILATED_CHANNEL=mas swift build --arch arm64 --jobs 4 --scratch-path "$scratch" --product DilatedApp
binary="$(DILATED_CHANNEL=mas swift build --arch arm64 --scratch-path "$scratch" --show-bin-path)/DilatedApp"
test -x "$binary"
if otool -L "$binary" | grep -qi sparkle; then
  echo "check-mas-build: $binary links Sparkle" >&2
  exit 1
fi
echo "check-mas-build: MAS channel builds and does not link Sparkle"
