#!/usr/bin/env bash
# Commit-msg hook check: the subject must be a plain Conventional Commit.
# Usage: check-commit-msg.sh <commit-message-file>
set -euo pipefail

file="${1:?usage: check-commit-msg.sh <commit-message-file>}"
subject="$(grep -v -E '^[[:space:]]*#' "$file" | grep -m1 -v -E '^[[:space:]]*$' || true)"

fail() {
  echo "commit-msg: $1" >&2
  echo "  subject: $subject" >&2
  echo "  expected: <type>(scope)!: <description>" >&2
  echo "  types: feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert" >&2
  exit 1
}

[ -n "$subject" ] || fail "empty commit message"

if printf '%s' "$subject" | perl -CS -ne 'exit(/[\x{1F000}-\x{1FFFF}\x{2190}-\x{2BFF}\x{FE0F}]/ ? 0 : 1)'; then
  fail "no emoji in commit subjects"
fi

case "$subject" in
  "Merge "* | "Revert "* | "fixup! "* | "squash! "* | "amend! "*) exit 0 ;;
esac

if ! printf '%s' "$subject" | grep -E -q '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^()[:space:]]+\))?!?: [^[:space:]].*$'; then
  fail "subject is not a Conventional Commit"
fi
