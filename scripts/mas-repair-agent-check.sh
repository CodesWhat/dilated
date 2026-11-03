#!/bin/bash
# Phase A for the Mac App Store closed-lid repair agent (slice DIL-MAS-BUILD.4): installs the real
# dilated-power script and the real LaunchAgent for a few minutes, proves the agent reverts a
# killed, silent and bogus-pid session, and removes everything it installed.
#
# It really changes this Mac's SleepDisabled setting through the sudoers rule, so it refuses to run
# unless the rule is there, the Mac is on AC, sleep is currently enabled, and nothing of ours is
# already installed. It takes about 6 minutes. Every step prints its measured seconds.
# Usage: bash scripts/mas-repair-agent-check.sh
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
label="com.codeswhat.dilated.closed-lid-repair"
bundle="com.codeswhat.dilated.appstore"
uid=$(id -u)
scripts_dir="$HOME/Library/Application Scripts/$bundle"
installed_script="$scripts_dir/dilated-power"
agent_plist="$HOME/Library/LaunchAgents/$label.plist"
session_dir="$HOME/Library/Application Support/dilated-power"

installed=0
created_scripts_dir=0
children=()
failures=0

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
elapsed_since() { /usr/bin/perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$1" "$(now)"; }
sleep_disabled() { pmset -g | /usr/bin/awk '/SleepDisabled/ { print $2 }'; }
say() { echo "[$(date +%H:%M:%S)] $*"; }

fail() {
  say "FAIL: $*"
  failures=$((failures + 1))
}

# Polls until SleepDisabled equals $1, for at most $2 seconds. Prints the seconds it took on
# stdout and returns 1 on timeout.
wait_for_sleep_disabled() {
  local want=$1 limit=$2 start
  start=$(now)
  while true; do
    if [ "$(sleep_disabled)" = "$want" ]; then
      elapsed_since "$start"
      return 0
    fi
    if [ "$(/usr/bin/perl -e 'print(($ARGV[1] - $ARGV[0]) > $ARGV[2] ? 1 : 0)' "$start" "$(now)" "$limit")" = 1 ]; then
      elapsed_since "$start"
      return 1
    fi
    /bin/sleep 0.25
  done
}

expect_word() {
  local what=$1 got=$2 want=$3
  if [ "$got" = "$want" ]; then say "  $what printed $got"; else fail "$what printed '$got', want '$want'"; fi
}

expect_sleep_disabled() {
  local label_text=$1 want=$2 limit=$3 took
  if took=$(wait_for_sleep_disabled "$want" "$limit"); then
    say "  $label_text: SleepDisabled $want after ${took}s (limit ${limit}s)"
  else
    fail "$label_text: SleepDisabled still not $want after ${took}s (limit ${limit}s)"
    return 1
  fi
}

start_child() {
  /bin/sleep 600 &
  children+=("$!")
  child=$!
}

# shellcheck disable=SC2329  # runs from the EXIT trap
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  say "cleanup"
  local child_pid
  for child_pid in ${children[@]+"${children[@]}"}; do
    kill -9 "$child_pid" 2>/dev/null
    wait "$child_pid" 2>/dev/null
  done
  if [ "$installed" -eq 1 ]; then
    launchctl bootout "gui/$uid/$label" 2>/dev/null
    /bin/rm -f "$agent_plist" "$installed_script"
    [ "$created_scripts_dir" -eq 1 ] && /bin/rmdir "$scripts_dir" 2>/dev/null
    /bin/rm -rf "$session_dir"
    if /usr/bin/env -i /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; then
      if [ "$(sleep_disabled)" = 0 ]; then
        say "  SleepDisabled 0 after cleanup"
      else
        say "FAIL: SleepDisabled is still $(sleep_disabled) after cleanup"
        status=1
      fi
    else
      say "FAIL: could not run pmset -a disablesleep 0 during cleanup"
      status=1
    fi
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      say "FAIL: $label is still loaded"
      status=1
    fi
  fi
  [ "$failures" -eq 0 ] || status=1
  if [ "$status" -eq 0 ]; then say "PASS"; else say "FAILED"; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Pre-flight: change nothing unless all of it holds.
preflight_failed=0
refuse() {
  say "pre-flight: $*"
  preflight_failed=1
}
sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 || refuse "no sudo rule for pmset -a disablesleep 1"
pmset -g batt | grep -q 'AC Power' || refuse "not on AC power"
[ "$(sleep_disabled)" = 0 ] || refuse "SleepDisabled is already $(sleep_disabled)"
[ ! -e "$installed_script" ] || refuse "$installed_script already exists"
[ ! -e "$agent_plist" ] || refuse "$agent_plist already exists"
[ ! -e "$session_dir" ] || refuse "$session_dir already exists"
launchctl print "gui/$uid/$label" >/dev/null 2>&1 && refuse "$label is already loaded"
if [ "$preflight_failed" -eq 1 ]; then
  trap - EXIT
  exit 2
fi

say "Phase A: closed-lid repair agent ($(hostname -s), $(sw_vers -productVersion))"
installed=1
if [ ! -d "$scripts_dir" ]; then
  /bin/mkdir -p "$scripts_dir" || exit 1
  created_scripts_dir=1
fi
/bin/cp "$repo/packaging/mas/dilated-power" "$installed_script" || exit 1
/bin/chmod 755 "$installed_script"
/usr/bin/sed "s|__HOME__|$HOME|g" "$repo/packaging/mas/$label.plist" >"$agent_plist" || exit 1
plutil -lint "$agent_plist" >/dev/null || exit 1
t0=$(now)
launchctl bootstrap "gui/$uid" "$agent_plist" || exit 1
say "agent bootstrapped in $(elapsed_since "$t0")s"
/bin/sleep 2

power() { /usr/bin/env -i HOME="$HOME" /bin/bash "$installed_script" "$@"; }

say "step 1: on <pid> disables sleep"
start_child
pid1=$child
t0=$(now)
out=$(power on "$pid1")
expect_word "on $pid1" "$out" ok
expect_sleep_disabled "step 1" 1 2

say "step 2: beat every 20s for 70s keeps it disabled"
t0=$(now)
for _ in 1 2 3; do
  /bin/sleep 20
  power beat >/dev/null
  [ "$(sleep_disabled)" = 1 ] || fail "step 2: SleepDisabled dropped at $(elapsed_since "$t0")s"
done
/bin/sleep 10
if [ "$(sleep_disabled)" = 1 ]; then
  say "  step 2: still SleepDisabled 1 after $(elapsed_since "$t0")s of beats"
else
  fail "step 2: SleepDisabled dropped by $(elapsed_since "$t0")s"
fi
say "  check while beating: $(power check)"

say "step 3: kill -9 the owner, the agent reverts"
t0=$(now)
kill -9 "$pid1"
wait "$pid1" 2>/dev/null
expect_sleep_disabled "step 3" 0 40
out=$(power on "$pid1")
expect_word "on $pid1" "$out" reverted
say "  step 3 total $(elapsed_since "$t0")s"

say "step 4: a silent owner (no beats) is reverted as stale"
start_child
pid2=$child
t0=$(now)
out=$(power on "$pid2")
expect_word "on $pid2" "$out" ok
expect_sleep_disabled "step 4 enable" 1 2
expect_sleep_disabled "step 4" 0 170
say "  step 4 total $(elapsed_since "$t0")s"

say "step 5: a session file for a pid that doesn't exist, then kickstart"
bogus=99999
while kill -0 "$bogus" 2>/dev/null; do bogus=$((bogus - 1)); done
/usr/bin/env -i /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1 || fail "step 5: could not set up"
(umask 077 && printf '%s Thu Jan  1 00:00:00 1970\n' "$bogus" >"$session_dir/session")
expect_sleep_disabled "step 5 setup" 1 2
t0=$(now)
launchctl kickstart -k "gui/$uid/$label" || fail "step 5: kickstart failed"
expect_sleep_disabled "step 5" 0 10
say "  step 5 total $(elapsed_since "$t0")s"
say "  check after repair: $(power check)"

exit 0
