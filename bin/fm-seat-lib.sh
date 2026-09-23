# shellcheck shell=bash
# Shared Claude seat resolution, used by bin/fm-seat.sh and bin/fm-spawn.sh.
# Usage: . bin/fm-seat-lib.sh   (after FM_ROOT, FM_HOME, and CONFIG are set)
#
# A "seat" is one Claude account, reached through a Claude Code profile
# directory named by CLAUDE_CONFIG_DIR. Claude Code derives that profile's
# Keychain service name from the directory path itself, so two seats never share
# a credential store and a worker pointed at a seat that was never logged in
# fails with "Not logged in" rather than silently spending the default account.
# docs/claude-seats.md owns the operator procedure and the login steps; this
# library owns only the resolution rules the spawn path and the seat command
# must agree on.
#
# The contract that makes a switch safe is that it changes only what the NEXT
# claude worker gets. A live worker keeps the profile it launched with, because
# that profile is recorded in its own task record at spawn time and every later
# launch for that task reads the RECORD, never this resolution. Moving a running
# worker between accounts would strand its session history, which lives under
# the profile directory, so the recorded value is a correctness requirement and
# not only a billing one.
#
# Three settings, all optional, all one line, all gitignored, and all inherited
# by LOCAL secondmate homes but never by a remote route
# (FM_MACHINE_LOCAL_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh):
#   config/claude-seat            active seat NAME for new claude workers
#   config/claude-seats-root      where seat profile directories live
#   config/claude-seat-threshold  percent remaining that trips an auto switch
# docs/configuration.md "Claude seats" owns their schema.

# The reserved seat name for "the default login", which is the ambient profile
# Claude Code uses with no CLAUDE_CONFIG_DIR set. It is never a directory under
# the seats root, and switching to it clears config/claude-seat.
FM_SEAT_DEFAULT_NAME=default

# fm_seat_root
# Absolute directory holding one subdirectory per named seat. Seats live outside
# the firstmate home on purpose: the account owner logs into a seat once and
# every home on the machine, primary and secondmate alike, reaches the same
# profile. A home that wants its own set overrides the root.
fm_seat_root() {
  local root=
  if [ -f "$CONFIG/claude-seats-root" ]; then
    root=$(sed -n '1p' "$CONFIG/claude-seats-root" 2>/dev/null | tr -d '[:space:]')
  fi
  [ -n "$root" ] || root="${HOME:-}/.claude-seats"
  printf '%s\n' "$root"
}

# fm_seat_name_valid <name>
# Seat names become a single path component under the seats root, so they are
# restricted to a conservative set rather than sanitized after the fact.
fm_seat_name_valid() {
  local name=${1-}
  local LC_ALL=C
  [ -n "$name" ] || return 1
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  case "$name" in
    . | .. | *..*) return 1 ;;
  esac
  return 0
}

# fm_seat_dir <name>
# Absolute profile directory for a seat name. The default seat has no directory
# of its own, so it prints nothing and returns 1: callers treat that as "no
# CLAUDE_CONFIG_DIR", which is exactly the ambient default.
fm_seat_dir() {
  local name=${1-} root
  [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] || return 1
  fm_seat_name_valid "$name" || return 1
  root=$(fm_seat_root)
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$root" "$name"
}

# fm_seat_active
# The configured active seat NAME, or the default seat name when unset. An
# unreadable or malformed value is reported as the default rather than guessed
# at, because the default is the one seat that always exists.
fm_seat_active() {
  local name=
  if [ -f "$CONFIG/claude-seat" ]; then
    name=$(sed -n '1p' "$CONFIG/claude-seat" 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$name" ] || ! fm_seat_name_valid "$name"; then
    printf '%s\n' "$FM_SEAT_DEFAULT_NAME"
    return 0
  fi
  printf '%s\n' "$name"
}

# fm_seat_config_dir <name>
# The CLAUDE_CONFIG_DIR a claude worker launched on seat <name> gets, or empty
# for the ambient default. Resolution order, most specific first:
#   1. the named seat's profile directory, when <name> is not the default seat
#   2. firstmate's OWN ambient CLAUDE_CONFIG_DIR, which predates seats and is
#      how a home running under a non-default profile already hands that same
#      store to its workers
#   3. empty - the single-store default, which adds no launch prefix at all
# The login probe and the threshold read resolve through this too, so they
# always inspect the same profile a worker on that seat would spend.
fm_seat_config_dir() {
  local name=${1-} dir
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] && dir=$(fm_seat_dir "$name"); then
    printf '%s\n' "$dir"
    return 0
  fi
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-}"
}

# fm_seat_spawn_config_dir
# The CLAUDE_CONFIG_DIR a NEW claude worker should launch with: the active
# seat's, resolved by fm_seat_config_dir. Only a fresh spawn calls this. A
# relaunch reads the task's recorded value.
fm_seat_spawn_config_dir() {
  fm_seat_config_dir "$(fm_seat_active)"
}

# fm_seat_list
# Every seat name that has a profile directory under the root, one per line, in
# a stable order. The set is read from the filesystem on every call, so nothing
# assumes which seats exist.
#
# The default seat is not listed here: it has no directory, and callers that
# present it add it themselves. A directory literally NAMED "default" is skipped
# for the same reason - that name is reserved for the ambient login, so such a
# directory can never be selected, and listing it would show a seat that every
# switch then refuses.
fm_seat_list() {
  local root entry name
  root=$(fm_seat_root)
  [ -d "$root" ] || return 0
  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    name=${entry##*/}
    [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] || continue
    fm_seat_name_valid "$name" || continue
    printf '%s\n' "$name"
  done
}

# fm_seat_logged_in [config-dir]
# Exit 0 when the profile holds usable Claude credentials, 1 when it plainly
# does not, and 2 when the probe could not reach a verdict.
#
# The probe is `quota-axi --provider claude`, run with the profile's own
# CLAUDE_CONFIG_DIR, and a logged-in profile is the one that reports an oauth
# source. It deliberately does NOT use --profile-only: that flag reads only a
# credential FILE and never the Keychain, and on macOS a logged-in profile keeps
# its credentials in the Keychain, so --profile-only reports "credentials
# missing" for a perfectly good seat. --no-credential-refresh keeps the read
# from delegating a token renewal to the vendor CLI.
fm_seat_logged_in() {
  local dir=${1-} out
  command -v quota-axi >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  # quota-axi exits non-zero when the provider is unavailable but still prints
  # the report that SAYS so, and that report is exactly the "not logged in"
  # verdict this probe needs. So the exit status is deliberately ignored and the
  # decision comes from the document; only unreadable or invalid output is
  # undecided.
  out=$(CLAUDE_CONFIG_DIR="$dir" quota-axi --provider claude --no-credential-refresh --full --json 2>/dev/null </dev/null || true)
  [ -n "$out" ] || return 2
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 2
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .source == "oauth"
  ' >/dev/null 2>&1 && return 0
  # Tell a clean "not logged in" apart from a probe that could not decide, so a
  # switch refuses on the first and reports uncertainty on the second. Only a
  # report where every credential source was actually consulted and came back
  # empty proves the profile holds no login.
  #
  # `keychain_unreachable` is NOT such a report: it says the store could not be
  # read, not that it is empty. Measured read-only against the installed
  # quota-axi on macOS, a profile that was never logged into and a profile that
  # IS signed in but whose one-time Keychain approval has not been granted yet
  # produce the same shape - every source skipped, the keychain unreachable. So
  # that shape cannot distinguish them and must stay undecided; treating it as
  # proof of absence would refuse a correctly signed-in seat with no way
  # through, exactly the state an owner is in moments after logging a seat in.
  # A signed-in seat whose quota endpoint is rate limited is also "unavailable",
  # and stays undecided for the same reason: its keychain attempt got past the
  # lookup and failed afterwards.
  #
  # An undecided read (2) is what `switch --force` may cross, and crossing it is
  # safe: a forced switch to a genuinely empty seat stops the next worker on its
  # first message with "Not logged in" rather than spending another account.
  # A proven-empty read (1) is never crossable. On a file-backed credential
  # store, where an empty profile really can be read and found empty, 1 remains
  # reachable; on macOS it correctly is not.
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .source == "unavailable"
      and ((.attempts // []) | length > 0
        and all(.status == "skipped" and .error == "credentials_missing"))
  ' >/dev/null 2>&1 && return 1
  return 2
}

# fm_seat_account [config-dir]
# The account email a profile is logged in as, when the probe can read one.
# Identity only; no token or credential content is ever read or printed.
fm_seat_account() {
  local dir=${1-} out
  command -v quota-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$(CLAUDE_CONFIG_DIR="$dir" quota-axi --provider claude --no-credential-refresh --full --json 2>/dev/null </dev/null || true)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -er '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .account.email // empty
  ' 2>/dev/null
}

# fm_seat_threshold
# The configured auto-switch percentage, or empty when unset. Empty means no
# automatic switching at all: there is deliberately no default that would move
# accounts on a home that never asked for it.
fm_seat_threshold() {
  local v=
  [ -f "$CONFIG/claude-seat-threshold" ] || return 1
  v=$(sed -n '1p' "$CONFIG/claude-seat-threshold" 2>/dev/null | tr -d '[:space:]')
  [ -n "$v" ] || return 1
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  jq -en --arg v "$v" '($v | tonumber) > 0 and ($v | tonumber) <= 100' >/dev/null 2>&1 || return 1
  printf '%s\n' "$v"
}
