#!/usr/bin/env bash
# Runs website/e2e in Chromium, Firefox and WebKit against website/dist.
set -euo pipefail
cd "$(dirname "$0")/../website"
npm ci
npx playwright install chromium firefox webkit
npx playwright test
