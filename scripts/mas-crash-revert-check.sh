#!/bin/bash
# Phase B for the Mac App Store closed-lid repair agent (slice DIL-MAS-BUILD.4b): builds the ad-hoc
# sandboxed bundle, installs the real dilated-power script and LaunchAgent, starts a closed-lid
# session through AppleScript, kill -9s the app and proves the agent reverts SleepDisabled, then
# proves a relaunch doesn't turn it back on. Removes everything it installed.
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

power() { /usr/bin/env -i HOME="$HOME" /bin/bash "$installed_script" "$@"; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Runs one command of the app's AppleScript dictionary against the test app by bundle ID. It only
# runs while our pid is alive, so a dead app is never relaunched by Apple Events. A 15 second Apple
# Event timeout means the app is stuck, most likely behind a dialog.
dilated() {
  pid_alive "$app_pid" || { echo "app not running"; return 1; }
  /usr/bin/osascript \
    -e 'with timeout of 15 seconds' \
    -e "tell application id \"$bundle\" to $1" \
    -e 'end timeout' 2>&1
}

# Opens the ad-hoc app and sets app_pid to the one process running from our temp build.
launch_app() {
  /usr/bin/open -n "$app" || return 1
  local i pids
  for i in $(seq 1 40); do
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

# Polls the closed-lid permission state through "closed display mode enabled". It answers false once
# the helper readback is confirmed, and returns an error while the state is unknown.
wait_for_ready() {
  local limit=$1 start out
  start=$(now)
  while pid_alive "$app_pid"; do
    out=$(dilated "closed display mode enabled")
    if [ "$out" = false ]; then
      elapsed_since "$start"
      return 0
    fi
    if [ "$(/usr/bin/perl -e 'print(($ARGV[1] - $ARGV[0]) > $ARGV[2] ? 1 : 0)' "$start" "$(now)" "$limit")" = 1 ]; then
      say "  last answer: $out" >&2
      elapsed_since "$start"
      return 1
    fi
    /bin/sleep 0.5
  done
  elapsed_since "$start"
  return 1
}

# Quits the test app by bundle ID and waits for its pid to go. Kills only that pid if it won't quit.
quit_app() {
  pid_alive "$app_pid" || return 0
  /usr/bin/osascript -e 'with timeout of 10 seconds' -e "tell application id \"$bundle\" to quit" -e 'end timeout' >/dev/null 2>&1
  local i
  for i in $(seq 1 40); do
    pid_alive "$app_pid" || { say "  app $app_pid quit"; return 0; }
    /bin/sleep 0.25
  done
  say "  app $app_pid did not quit, killing that pid"
  kill "$app_pid" 2>/dev/null
  for i in $(seq 1 20); do
    pid_alive "$app_pid" || return 0
    /bin/sleep 0.25
  done
  kill -9 "$app_pid" 2>/dev/null
}

# shellcheck disable=SC2329  # runs from the EXIT trap
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  say "cleanup"
  quit_app
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

say "setup: dilated-power and the repair agent"
mas_install_agent || exit 1
/bin/sleep 2

say "launch: open -n the ad-hoc app"
launch_app || { fail "the app did not start"; exit 1; }
say "  pid $app_pid"
if took=$(wait_for_ready 30); then
  say "  closed-lid permission state ready after ${took}s"
else
  fail "closed-lid permission state not ready after ${took}s (a dialog on the app would show here)"
  exit 1
fi

say "session: start a session with closed-lid on"
out=$(dilated "start new session with options {duration:0, interval:0}")
[ -z "$out" ] || { fail "start new session answered '$out'"; exit 1; }
[ "$(dilated "session is active")" = true ] || { fail "no session is active after start"; exit 1; }
t0=$(now)
out=$(dilated "enable closed display mode")
[ -z "$out" ] || { fail "enable closed display mode answered '$out'"; exit 1; }
expect_sleep_disabled "enable" 1 5 || exit 1
say "  closed display mode enabled: $(dilated "closed display mode enabled")"
say "  check: $(power check)"
[ -f "$session_dir/session" ] || fail "no session file under $session_dir"

say "kill: kill -9 the app ($app_pid)"
t0=$(now)
kill -9 "$app_pid"
while pid_alive "$app_pid"; do /bin/sleep 0.1; done
expect_sleep_disabled "kill" 0 40
say "  revert took $(elapsed_since "$t0")s after the kill (limit 40s)"
say "  check after revert: $(power check)"
[ -f "$session_dir/session" ] && fail "session file still there after the revert"

say "relaunch: the app must not turn it back on"
launch_app || { fail "the app did not relaunch"; exit 1; }
say "  pid $app_pid"
if took=$(wait_for_ready 30); then
  say "  closed-lid permission state ready after ${took}s"
else
  fail "closed-lid permission state not ready after relaunch (${took}s)"
  exit 1
fi
t0=$(now)
while [ "$(/usr/bin/perl -e 'print(($ARGV[1] - $ARGV[0]) > 30 ? 1 : 0)' "$t0" "$(now)")" = 0 ]; do
  if [ "$(sleep_disabled)" != 0 ]; then
    fail "SleepDisabled went to $(sleep_disabled) $(elapsed_since "$t0")s after the relaunch"
    break
  fi
  /bin/sleep 0.5
done
[ "$(sleep_disabled)" = 0 ] && say "  SleepDisabled stayed 0 for $(elapsed_since "$t0")s"
say "  closed display mode enabled: $(dilated "closed display mode enabled")"
say "  session active: $(dilated "session is active")"
[ -f "$session_dir/session" ] && fail "session file exists after the relaunch"
after=$(power check)
say "  check after relaunch: $after"
case "$after" in
  none) ;;
  *) fail "recovery state after relaunch is '$after', want none" ;;
esac

say "quit: by bundle ID"
quit_app
pid_alive "$app_pid" && fail "the app is still running"

exit 0
