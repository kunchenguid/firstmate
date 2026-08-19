#!/usr/bin/env bash
# tests/fm-prime-agent-lib.test.sh - cwd-scoped retirement of prime-agent's
# detached daemon sessions (bin/fm-prime-agent-lib.sh), which teardown runs
# before its generic leaked-process reaper.
#
# The load-bearing contract:
#   1. Only sessions whose recorded cwd IS the directory or lives INSIDE it are
#      stopped. A sibling directory that merely shares a name prefix, and any
#      other home's session, must survive - the daemon is fleet-wide, so a
#      wrong selection would kill the captain's own work.
#   2. Retirement is best effort. A missing prime-agent binary, a failing
#      listing, and an unparseable listing are silent no-ops that return 0, so
#      a cleanup courtesy can never fail the teardown around it.
#   3. A session id that is not a plain token is never handed to the CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot prime-agent-lib)

# fake_prime_agent <dir> <list-stdout> [list-exit]
# Installs a `prime-agent` stub on PATH that answers `list --json` with the
# given payload and appends every other invocation to <dir>/calls.
fake_prime_agent() {
  local dir=$1 listing=$2 list_exit=${3:-0} fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s' "$listing" > "$dir/listing.json"
  cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
if [ "\$1" = list ]; then
  cat "$dir/listing.json"
  exit $list_exit
fi
printf '%s\n' "\$*" >> "$dir/calls"
exit 0
SH
  chmod +x "$fakebin/prime-agent"
  : > "$dir/calls"
  printf '%s\n' "$fakebin"
}

# stop_under <dir> <target> -> echoes the stub's recorded calls.
stop_under() {
  local dir=$1 target=$2 fakebin=$3
  PATH="$fakebin:$PATH" bash -c '
    set -u
    . "$1"
    fm_prime_agent_stop_sessions_under "$2"
  ' _ "$ROOT/bin/fm-prime-agent-lib.sh" "$target" 2>/dev/null
  cat "$dir/calls"
}

session() {  # <id> <cwd>
  printf '{"id":"%s","cwd":"%s"}' "$1" "$2"
}

test_only_sessions_under_the_directory_are_stopped() {
  local dir target fakebin calls
  dir="$TMP_ROOT/scope"; mkdir -p "$dir"
  target="$dir/wt"; mkdir -p "$target/nested"
  # A sibling whose path shares the target's prefix is the case a naive
  # `startswith($dir)` gets wrong, so it is pinned explicitly.
  mkdir -p "$dir/wt-other"
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[
    $(session inside "$target"),
    $(session nested "$target/nested"),
    $(session sibling "$dir/wt-other"),
    $(session elsewhere "$dir")
  ]}")
  calls=$(stop_under "$dir" "$target" "$fakebin")
  [ "$calls" = "stop inside
stop nested" ] || fail "expected only the target's own and nested sessions to stop, got: $calls"
  pass "fm_prime_agent_stop_sessions_under: stops the directory's own and nested sessions, never a prefix sibling"
}

test_a_symlinked_target_matches_either_recorded_form() {
  local dir target link fakebin calls
  # The fixture root itself must be physical, or the recorded "physical" cwd
  # below would carry a logical prefix that no launch ever produces (macOS
  # puts TMPDIR under /var, a symlink to /private/var).
  dir="$(cd "$TMP_ROOT" && pwd -P)/symlinked"; mkdir -p "$dir"
  target="$dir/real"; mkdir -p "$target"
  link="$dir/link"; ln -s "$target" "$link"
  # prime-agent records whichever form the session was launched under, so a
  # worktree reached through a symlinked prefix must retire either way or it
  # goes back to the pool with a live worker still on it.
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[
    $(session logical "$link"),
    $(session physical "$target")
  ]}")
  calls=$(stop_under "$dir" "$link" "$fakebin")
  [ "$calls" = "stop logical
stop physical" ] || fail "expected both recorded forms of the symlinked target to stop, got: $calls"
  pass "fm_prime_agent_stop_sessions_under: a symlinked target stops sessions recorded under either form"
}

test_missing_binary_is_a_silent_no_op() {
  local dir status err
  dir="$TMP_ROOT/nobinary"; mkdir -p "$dir/fakebin"
  # jq is reachable and nothing else is, so no prime-agent installed to a user
  # prefix can stand in for the absent one and the jq guard cannot answer for
  # the binary guard. A machine without prime-agent is exactly the machine
  # teardown must not fail on, and "silent" is half the contract: reaching the
  # CLI at all would put a "command not found" on teardown's stderr.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/jq"
  chmod +x "$dir/fakebin/jq"
  ln -sf "$(command -v dirname)" "$dir/fakebin/dirname"
  # shellcheck disable=SC2016  # the positional args are the inner shell's.
  err=$(PATH="$dir/fakebin" "$BASH" -c '
    set -u
    . "$1"
    fm_prime_agent_stop_sessions_under "$2"
  ' _ "$ROOT/bin/fm-prime-agent-lib.sh" "$dir" 2>&1 >/dev/null)
  status=$?
  [ "$status" -eq 0 ] || fail "a missing prime-agent binary must be a silent no-op, got exit $status"
  [ -z "$err" ] || fail "a missing prime-agent binary must stay silent, got: $err"
  pass "fm_prime_agent_stop_sessions_under: a missing prime-agent binary is a silent no-op"
}

test_unusable_listing_stops_nothing() {
  local dir fakebin calls case_id
  for case_id in failing unparseable shapeless; do
    dir="$TMP_ROOT/listing-$case_id"; mkdir -p "$dir"
    case "$case_id" in
      failing) fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[$(session x "$dir")]}" 1) ;;
      unparseable) fakebin=$(fake_prime_agent "$dir" 'not json at all') ;;
      shapeless) fakebin=$(fake_prime_agent "$dir" '{"sessions":"not-an-array"}') ;;
    esac
    calls=$(stop_under "$dir" "$dir" "$fakebin")
    [ -z "$calls" ] || fail "an unusable listing ($case_id) must stop nothing, got: $calls"
  done
  pass "fm_prime_agent_stop_sessions_under: a failing, unparseable, or wrongly shaped listing stops nothing"
}

test_unsafe_session_id_is_never_passed_to_the_cli() {
  local dir fakebin calls
  dir="$TMP_ROOT/unsafe"; mkdir -p "$dir"
  # A leading dash is the second half of the case: prime-agent would read
  # `--all` as an option rather than as the session it must stop.
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[
    $(session 'a b; rm -rf /' "$dir"),
    $(session '--all' "$dir"),
    $(session good-1 "$dir")
  ]}")
  calls=$(stop_under "$dir" "$dir" "$fakebin")
  [ "$calls" = "stop good-1" ] || fail "expected only the plain-token id to reach the CLI, got: $calls"
  pass "fm_prime_agent_stop_sessions_under: a session id that is not a plain token never reaches the CLI"
}

test_only_sessions_under_the_directory_are_stopped
test_a_symlinked_target_matches_either_recorded_form
test_missing_binary_is_a_silent_no_op
test_unusable_listing_stops_nothing
test_unsafe_session_id_is_never_passed_to_the_cli
