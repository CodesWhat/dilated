#!/bin/bash
# Phase B for the Mac App Store closed-lid repair agent (slice DIL-MAS-BUILD.4b): builds the ad-hoc
# sandboxed bundle, installs the real dilated-power script and LaunchAgent, starts a closed-lid
# session through the dilated:// URL scheme, kill -9s the app and proves the agent reverts
# SleepDisabled, then proves a relaunch doesn't turn it back on. Removes everything it installed.
#
# No Apple Events and no consent prompt: the app is driven with `open -g -a <temp app path>
# dilated://...` (exact path, never the real Dilated) and observed through SleepDisabled and `dilated-power check`. Closed-lid URLs need
# closedLidURLAutomation in the test container's settings.json, so the script merges that one key
# before the first launch and restores the file on cleanup.
#
# It really changes this Mac's SleepDisabled setting through the sudoers rule, so it refuses to run
# unless the rule is there, the Mac is on AC, sleep is currently enabled, and nothing of ours is
# already installed. It never touches the real Dilated (com.codeswhat.dilated): the test app is
# addressed only by its bundle ID com.codeswhat.dilated.appstore or its exact pid. If the app puts
# up a dialog this script does not click it; the run fails and cleans up.
# Usage: bash scripts/mas-crash-revert-check.sh
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/mas-check-lib.sh
source "$repo/scripts/mas-check-lib.sh"

build_dir=""
app=""
exe=""
app_pid=""
state_dir="$HOME/Library/Containers/$bundle/Data/Library/Application Support/Dilated"
settings_file="$state_dir/settings.json"
settings_backup=""
settings_created=0
settings_touched=0

power() { /usr/bin/env -i HOME="$HOME" /bin/bash "$installed_script" "$@"; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Sends a dilated:// URL to our temp copy of the test app by exact path (LaunchServices does not resolve the bundle ID of an app in a temp dir), without taking focus. Only while our pid is alive,
# so a URL never launches some other copy of the bundle.
send_url() {
  pid_alive "$app_pid" || return 1
  /usr/bin/open -g -a "$app" "$1"
}

# Opens the ad-hoc app and sets app_pid to the one process running from our temp build.
launch_app() {
  /usr/bin/open -g -n "$app" || return 1
  local attempt pids
  for ((attempt = 0; attempt < 40; attempt++)); do
    pids=$(/usr/bin/pgrep -f "^$exe\$" || true)
    if [ -n "$pids" ]; then
      if [ "$(echo "$pids" | /usr/bin/wc -l | tr -d ' ')" != 1 ]; then
        fail "more than one process runs $exe: $(echo "$pids" | tr '\n' ' ')"
        return 1
      fi
      app_pid=$pids
      return 0
    fi
    /bin/sleep 0.25
  done
  return 1
}

# Quits the test app by bundle ID and waits for its pid to go. Kills only that pid if it won't quit.
quit_app() {
  pid_alive "$app_pid" || return 0
  /usr/bin/osascript -e 'with timeout of 10 seconds' -e "tell application id \"$bundle\" to quit" -e 'end timeout' >/dev/null 2>&1
  local attempt
  for ((attempt = 0; attempt < 40; attempt++)); do
    pid_alive "$app_pid" || { say "  app $app_pid quit"; return 0; }
    /bin/sleep 0.25
  done
  say "  app $app_pid did not quit, killing that pid"
  kill "$app_pid" 2>/dev/null
  for ((attempt = 0; attempt < 20; attempt++)); do
    pid_alive "$app_pid" || return 0
    /bin/sleep 0.25
  done
  kill -9 "$app_pid" 2>/dev/null
}

# Merges closedLidURLAutomation=true into settings.json and nothing else.
merge_setting() {
  python3 -I - "$settings_file" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["closedLidURLAutomation"] = True
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, separators=(",", ":"))
os.replace(tmp, path)
PY
}

# Seeds the test container's settings before the app's first launch of this run.
seed_settings() {
  settings_touched=1
  if [ -f "$settings_file" ]; then
    settings_backup="$build_dir/settings.json.backup"
    /bin/cp -p "$settings_file" "$settings_backup" || return 1
  else
    say "  no settings.json yet: launch once to let the app create it"
    settings_created=1
    launch_app || return 1
    local attempt
    for ((attempt = 0; attempt < 60; attempt++)); do
      [ -f "$settings_file" ] && break
      /bin/sleep 0.5
    done
    quit_app
    [ -f "$settings_file" ] || { fail "the app never wrote $settings_file"; return 1; }
  fi
  merge_setting || return 1
  say "  closedLidURLAutomation set in $settings_file"
}

# shellcheck disable=SC2329  # runs from the EXIT trap
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  say "cleanup"
  quit_app
  if [ "$settings_touched" -eq 1 ]; then
    if [ -n "$settings_backup" ] && [ -f "$settings_backup" ]; then
      /bin/cp -p "$settings_backup" "$settings_file" && say "  settings.json restored"
    elif [ "$settings_created" -eq 1 ]; then
      /bin/rm -f "$settings_file" && say "  settings.json removed"
    fi
  fi
  if [ "$installed" -eq 1 ]; then
    mas_uninstall_agent
    [ "$uninstall_status" -eq 0 ] || status=1
  fi
  if [ -n "$exe" ] && /usr/bin/pgrep -f "^$exe\$" >/dev/null; then
    say "FAIL: a process still runs $exe"
    status=1
  fi
  [ -n "$build_dir" ] && /bin/rm -rf "$build_dir"
  [ "$failures" -eq 0 ] || status=1
  if [ "$status" -eq 0 ]; then say "PASS"; else say "FAILED"; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Pre-flight: change nothing unless all of it holds.
if ! mas_preflight; then
  trap - EXIT
  exit 2
fi

say "Phase B: crash revert on the ad-hoc MAS bundle ($(hostname -s), $(sw_vers -productVersion))"

say "build: ad-hoc MAS bundle"
build_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dilated-mas-crash.XXXXXX") || exit 1
build_dir=$(cd "$build_dir" && pwd -P)
app="$build_dir/Dilated.app"
exe="$app/Contents/MacOS/DilatedApp"
t0=$(now)
bash "$repo/scripts/build-mas.sh" --adhoc --output-dir "$build_dir" >"$build_dir/build.log" 2>&1 || {
  tail -20 "$build_dir/build.log"
  fail "build-mas.sh failed"
  exit 1
}
python3 -I "$repo/scripts/check-mas-bundle.py" "$app" >>"$build_dir/build.log" 2>&1 || {
  tail -20 "$build_dir/build.log"
  fail "check-mas-bundle.py failed"
  exit 1
}
say "  built and checked in $(elapsed_since "$t0")s"

say "setup: dilated-power, the repair agent and the URL setting"
mas_install_agent || exit 1
seed_settings || exit 1
/bin/sleep 2

say "launch: open the ad-hoc app"
launch_app || { fail "the app did not start"; exit 1; }
say "  pid $app_pid"

# Starts a closed-lid session by URL, retrying every 3s for up to 30s: the app refreshes its script
# permission state at launch, and a URL sent before that is rejected.
say "session: dilated://awake?lid=closed"
t0=$(now)
enabled=0
while [ "$(/usr/bin/perl -e 'print(($ARGV[1] - $ARGV[0]) > 30 ? 1 : 0)' "$t0" "$(now)")" = 0 ]; do
  send_url "dilated://awake?lid=closed" || { pid_alive "$app_pid" || { fail "the app died before the URL was accepted"; exit 1; }; /bin/sleep 3; continue; }
  if wait_for_sleep_disabled 1 3 >/dev/null; then
    enabled=1
    break
  fi
done
if [ "$enabled" -ne 1 ]; then
  fail "SleepDisabled never went to 1 within 30s of the URL (a dialog on the app would show here)"
  exit 1
fi
say "  SleepDisabled 1 after $(elapsed_since "$t0")s"
expect_word "check" "$(power check)" live
[ -f "$session_dir/session" ] || fail "no session file under $session_dir"

say "kill: kill -9 the app ($app_pid)"
t0=$(now)
kill -9 "$app_pid"
while pid_alive "$app_pid"; do /bin/sleep 0.1; done
expect_sleep_disabled "kill" 0 40
say "  revert took $(elapsed_since "$t0")s after the kill (limit 40s)"
expect_word "check after revert" "$(power check)" reverted
[ -f "$session_dir/session" ] && fail "session file still there after the revert"

say "relaunch: the app must not turn it back on"
launch_app || { fail "the app did not relaunch"; exit 1; }
say "  pid $app_pid"
t0=$(now)
while [ "$(/usr/bin/perl -e 'print(($ARGV[1] - $ARGV[0]) > 30 ? 1 : 0)' "$t0" "$(now)")" = 0 ]; do
  if [ "$(sleep_disabled)" != 0 ]; then
    fail "SleepDisabled went to $(sleep_disabled) $(elapsed_since "$t0")s after the relaunch"
    break
  fi
  /bin/sleep 0.5
done
[ "$(sleep_disabled)" = 0 ] && say "  SleepDisabled stayed 0 for $(elapsed_since "$t0")s"
[ -f "$session_dir/session" ] && fail "session file exists after the relaunch"
after=$(power check)
say "  check after relaunch: $after"
[ "$after" = none ] || fail "recovery state after relaunch is '$after', want none (tombstone not cleared by the relaunch)"

say "quit: by bundle ID"
quit_app
pid_alive "$app_pid" && fail "the app is still running"

exit 0
