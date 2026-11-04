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
# shellcheck source=scripts/mas-check-lib.sh
source "$repo/scripts/mas-check-lib.sh"

children=()

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
    mas_uninstall_agent
    [ "$uninstall_status" -eq 0 ] || status=1
  fi
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

say "Phase A: closed-lid repair agent ($(hostname -s), $(sw_vers -productVersion))"
mas_install_agent || exit 1
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
