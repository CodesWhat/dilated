#!/bin/bash
# Live check of Dilated Closed-Lid Setup, driven headless through its hidden CLI mode: builds DilatedSetup, installs for
# com.codeswhat.dilated.appstore, checks the result, removes everything and checks that too.
#
# It never shows an administrator prompt. The sudoers rule step is skipped only because another app's rule (Amphetamine's)
# already lets this user run both pmset commands; with no such rule the check stops before installing anything. It also
# refuses to start if any piece of an install is already here, and it always runs remove on exit.
#
# Usage: bash scripts/closed-lid-setup-check.sh
repo="$(cd "$(dirname "$0")/.." && pwd)"
set -u
# shellcheck disable=SC2154  # paths, label and counters come from mas-check-lib.sh

# shellcheck source=scripts/mas-check-lib.sh
source "$repo/scripts/mas-check-lib.sh"

foreign_rule="/etc/sudoers.d/amphetamine_PowerProtect"
setup_state_dir="$HOME/Library/Application Support/Dilated Closed-Lid Setup"
setup_bin=""

# mtime, size, mode and owner, plus the SHA-256 when the file is readable (the rule is 0440 root:wheel, so usually it isn't).
fingerprint() {
  local meta digest="unreadable"
  meta=$(/usr/bin/stat -f '%m %z %Lp %u:%g %i' "$foreign_rule" 2>/dev/null) || {
    echo missing
    return
  }
  if [ -r "$foreign_rule" ]; then digest=$(/usr/bin/shasum -a 256 "$foreign_rule" | /usr/bin/awk '{ print $1 }'); fi
  echo "$meta sha256=$digest"
}

json_field() {
  /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" <<<"$2" 2>/dev/null
}

expect_status() {
  local json=$1 field=$2 want=$3 got
  got=$(json_field "$field" "$json")
  if [ "$got" = "$want" ]; then say "  status $field = $got"; else fail "status $field is '$got', want '$want'"; fi
}

cleanup() {
  trap - EXIT
  if [ "$installed" = 1 ] && [ -x "$setup_bin" ]; then
    say "cleanup: removing the install"
    "$setup_bin" --remove --yes || fail "cleanup remove did not succeed"
  fi
  if [ "$(sleep_disabled)" != 0 ]; then
    /usr/bin/env -i /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 || true
  fi
  if [ "$failures" -gt 0 ]; then
    say "closed-lid-setup-check FAILED ($failures)"
    exit 1
  fi
  say "closed-lid-setup-check passed"
  exit 0
}

# Pre-flight. Nothing has changed yet, so these exit without the cleanup remove.
preflight_failed=0
refuse() {
  say "pre-flight: $*"
  preflight_failed=1
}
if ! { sudo -n -l /usr/bin/pmset -a disablesleep 1 && sudo -n -l /usr/bin/pmset -a disablesleep 0; } >/dev/null 2>&1; then
  refuse "no sudo rule already allows pmset, so install would need an administrator prompt"
fi
[ "$(sleep_disabled)" = 0 ] || refuse "SleepDisabled is already $(sleep_disabled)"
[ ! -e "$installed_script" ] || refuse "$installed_script already exists"
[ ! -e "$scripts_dir" ] || refuse "$scripts_dir already exists"
[ ! -e "$agent_plist" ] || refuse "$agent_plist already exists"
[ ! -e "$setup_state_dir" ] || refuse "$setup_state_dir already exists"
[ ! -e "$session_dir" ] || refuse "$session_dir already exists"
launchctl print "gui/$uid/$label" >/dev/null 2>&1 && refuse "$label is already loaded"
[ "$preflight_failed" -eq 0 ] || exit 1

say "building DilatedSetup"
(cd "$repo" && swift build --product DilatedSetup) || {
  say "build failed"
  exit 1
}
setup_bin="$(cd "$repo" && swift build --show-bin-path)/DilatedSetup"
[ -x "$setup_bin" ] || {
  say "no executable at $setup_bin"
  exit 1
}

rule_before=$(fingerprint)
say "foreign rule before: $rule_before"
trap cleanup EXIT

say "install"
installed=1
if "$setup_bin" --install --yes; then say "  install exited 0"; else fail "install failed"; fi

status_json=$("$setup_bin" --status --json)
say "status after install: $status_json"
expect_status "$status_json" script present
expect_status "$status_json" agent loaded
expect_status "$status_json" rule allowedByOtherRule
expect_status "$status_json" ruleInstalledByCompanion False

if [ -x "$installed_script" ] && [ "$(/usr/bin/stat -f %Lp "$installed_script")" = 755 ]; then
  say "  script is 0755 at $installed_script"
else
  fail "script missing or not 0755"
fi
expect_word "dilated-power probe" "$(/bin/bash "$installed_script" probe)" ok
if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then say "  launchctl print exited 0"; else fail "launchctl print failed"; fi

say "reinstall (idempotent)"
if "$setup_bin" --install --yes; then say "  second install exited 0"; else fail "reinstall failed"; fi
expect_status "$("$setup_bin" --status --json)" agent loaded

say "remove"
if "$setup_bin" --remove --yes; then
  say "  remove exited 0"
  installed=0
else
  fail "remove failed"
fi

status_json=$("$setup_bin" --status --json)
say "status after remove: $status_json"
expect_status "$status_json" script missing
expect_status "$status_json" agent notLoaded
expect_status "$status_json" rule allowedByOtherRule
for leftover in "$installed_script" "$scripts_dir" "$agent_plist" "$setup_state_dir"; do
  if [ -e "$leftover" ]; then fail "left behind: $leftover"; else say "  gone: $leftover"; fi
done
if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then fail "$label is still loaded"; else say "  agent is not loaded"; fi

rule_after=$(fingerprint)
say "foreign rule after:  $rule_after"
if [ "$rule_before" = "$rule_after" ]; then say "  $foreign_rule untouched"; else fail "$foreign_rule changed"; fi

if [ "$(sleep_disabled)" = 0 ]; then say "  SleepDisabled 0"; else fail "SleepDisabled is $(sleep_disabled)"; fi
