#!/usr/bin/env bash
# Runs website/e2e in Chromium, Firefox and WebKit against website/dist.
set -euo pipefail
cd "$(dirname "$0")/../website"
npm ci
if [ "$(uname)" = "Linux" ]; then
  npx playwright install --with-deps chromium firefox webkit
else
  npx playwright install chromium firefox webkit
fi
npx playwright test
