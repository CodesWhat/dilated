#!/bin/bash
# Shared pieces of the Mac App Store closed-lid checks (mas-repair-agent-check.sh and
# mas-crash-revert-check.sh): paths, timing helpers, the pre-flight and the agent install and removal.
# Source it after setting `repo`; it runs nothing on its own.

label="com.codeswhat.dilated.closed-lid-repair"
bundle="com.codeswhat.dilated.appstore"
uid=$(id -u)
scripts_dir="$HOME/Library/Application Scripts/$bundle"
installed_script="$scripts_dir/dilated-power"
agent_plist="$HOME/Library/LaunchAgents/$label.plist"
session_dir="$HOME/Library/Application Support/dilated-power"

installed=0
failures=0
uninstall_status=0

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

# Returns 1 (nothing changed) unless the sudoers rule is there, the Mac is on AC, sleep is
# enabled and nothing of ours is installed.
mas_preflight() {
  local failed=0
  refuse() {
    say "pre-flight: $*"
    failed=1
  }
  sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 || refuse "no sudo rule for pmset -a disablesleep 1"
  pmset -g batt | grep -q 'AC Power' || refuse "not on AC power"
  [ "$(sleep_disabled)" = 0 ] || refuse "SleepDisabled is already $(sleep_disabled)"
  [ ! -e "$installed_script" ] || refuse "$installed_script already exists"
  [ ! -e "$agent_plist" ] || refuse "$agent_plist already exists"
  [ ! -e "$session_dir" ] || refuse "$session_dir already exists"
  launchctl print "gui/$uid/$label" >/dev/null 2>&1 && refuse "$label is already loaded"
  return "$failed"
}

# Installs the real dilated-power script and the rendered LaunchAgent, and bootstraps the agent.
# Sets installed=1 first so cleanup removes whatever got installed.
mas_install_agent() {
  local t0
  # shellcheck disable=SC2034 # Read by the sourcing script during cleanup.
  installed=1
  if [ ! -d "$scripts_dir" ]; then
    /bin/mkdir -p "$scripts_dir" || return 1
  fi
  # shellcheck disable=SC2154 # The sourcing script sets its repository root.
  /bin/cp "$repo/packaging/mas/dilated-power" "$installed_script" || return 1
  /bin/chmod 755 "$installed_script"
  /usr/bin/sed "s|__HOME__|$HOME|g" "$repo/packaging/mas/$label.plist" >"$agent_plist" || return 1
  plutil -lint "$agent_plist" >/dev/null || return 1
  t0=$(now)
  launchctl bootstrap "gui/$uid" "$agent_plist" || return 1
  say "agent bootstrapped in $(elapsed_since "$t0")s"
}

# Removes what mas_install_agent installed and puts SleepDisabled back to 0. Sets
# uninstall_status to 1 when anything could not be restored.
mas_uninstall_agent() {
  uninstall_status=0
  launchctl bootout "gui/$uid/$label" 2>/dev/null
  /bin/rm -f "$agent_plist" "$installed_script"
  # rmdir only takes an empty folder; the sandboxed app can create it on launch.
  /bin/rmdir "$scripts_dir" 2>/dev/null
  /bin/rm -rf "$session_dir"
  if /usr/bin/env -i /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; then
    if [ "$(sleep_disabled)" = 0 ]; then
      say "  SleepDisabled 0 after cleanup"
    else
      say "FAIL: SleepDisabled is still $(sleep_disabled) after cleanup"
      uninstall_status=1
    fi
  else
    say "FAIL: could not run pmset -a disablesleep 0 during cleanup"
    uninstall_status=1
  fi
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    say "FAIL: $label is still loaded"
    # shellcheck disable=SC2034 # Returned through shared state to the sourcing script.
    uninstall_status=1
  fi
}
