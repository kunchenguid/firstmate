#!/usr/bin/env bash
# Behavioral coverage for the internal /stow cascade enumerator: per-home budget
# accounting that never sums a fleet total, one stanza per registered home,
# local versus remote transport routing, the facts a per-home completion receipt
# is built from, and the bound that keeps one slow home from blocking the sweep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CASCADE="$ROOT/bin/fm-stow-cascade.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-cascade)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A fake ssh standing in for the whole remote transport. It decodes fm-on.sh's
# NUL argv stream so each remote leg can answer as its own command, and its mode
# selects a reachable host, an unreachable one, or one that never answers.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
# After --: host, entrypoint, protocol, root, home, argv.
[ "$#" -eq 6 ] || exit 92
argv=$6
# tr runs inside the pipeline because command substitution drops NUL bytes.
command=$(printf '%s' "$argv" | base64 --decode 2>/dev/null | tr '\000' '\n' | head -1)
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  hang) sleep 45; exit 0 ;;
esac
case "$command" in
  fm-startup-memory-budget.sh)
    cat "$FM_FAKE_REMOTE_BUDGET"
    ;;
  fm-remote-secondmate-control.sh)
    printf '%s\n' "${FM_FAKE_REMOTE_AGENT_STATE:-alive}"
    ;;
  *) exit 91 ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

# A tmux whose pane reports a running agent, so the local endpoint probe has a
# real backend read to classify rather than a stubbed verdict.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *list-windows*) printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-}" ;;
  *list-panes*) printf '%s\n' "${FM_FAKE_TMUX_PANE:-}" ;;
  *display-message*'#{pane_current_command}'*) printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-claude}" ;;
  *display-message*'#{pane_pid}'*) printf '%s\n' "$$" ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1' ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0 ;;
  *capture-pane*) printf '\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

# new_home <name> [budget] -> path to a seeded local secondmate home.
new_home() {
  local name=$1 budget=${2:-10} home
  home="$TMP_ROOT/homes/$name"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/bin" "$home/projects"
  printf '%s\n' "$name" > "$home/.fm-secondmate-home"
  printf '%s\n' '# secondmate instructions' > "$home/AGENTS.md"
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
  printf '%s\n' "$home"
}

new_primary() {
  local name=$1 home
  home="$TMP_ROOT/primaries/$name"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '%s\n' "$home"
}

# Registry lines use the parser-owned suffix form for local and remote routes.
local_record() { # <id> <home>
  printf -- '- %s - domain summary (home: %s; scope: %s work; projects: alpha; added 2026-08-07)\n' \
    "$1" "$2" "$1"
}
remote_record() { # <id> <host> <root> <home>
  printf -- '- %s - domain summary (host: %s; root: %s; home: %s; scope: %s work; projects: alpha; added 2026-08-07)\n' \
    "$1" "$2" "$3" "$4" "$1"
}

run_cascade() { # <primary-home> [env assignments...]
  local home=$1
  shift
  env -i \
    PATH="$FAKEBIN:$BASE_PATH" \
    HOME="${HOME:-/tmp}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    FM_HOME="$home" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    "$@" \
    "$CASCADE"
}

# stanza <output> <id>: the block of key=value lines for one secondmate.
stanza() {
  printf '%s\n' "$1" | awk -v id="secondmate=$2" '
    $0 == id { inside = 1 }
    inside && $0 == "" { inside = 0 }
    inside { print }
  '
}

value_in() { # <stanza> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

test_budget_is_enforced_per_home_and_never_summed() {
  local primary a b out sa sb
  primary=$(new_primary per-home)
  a=$(new_home over-budget 10)
  b=$(new_home within-budget 10)
  # Home A alone exceeds its own 10-token allowance.
  printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$a/data/captain.md"
  # Home B is comfortably inside the same allowance, and would only look
  # over-budget if the cascade added another home's total to its own.
  printf '%s\n' 'bbbbbb' > "$b/data/captain.md"
  {
    local_record over-budget "$a"
    local_record within-budget "$b"
  } > "$primary/data/secondmates.md"

  set +e
  out=$(run_cascade "$primary")
  set -e
  sa=$(stanza "$out" over-budget)
  sb=$(stanza "$out" within-budget)

  [ "$(value_in "$sa" effective_budget_tokens)" = 10 ] \
    || fail "over-budget home did not report its own allowance"
  [ "$(value_in "$sb" effective_budget_tokens)" = 10 ] \
    || fail "within-budget home did not report its own allowance"
  [ "$(value_in "$sa" total_estimated_tokens)" = 13 ] \
    || fail "over-budget home total was not its own files: $(value_in "$sa" total_estimated_tokens)"
  [ "$(value_in "$sb" total_estimated_tokens)" = 3 ] \
    || fail "within-budget home total was not its own files: $(value_in "$sb" total_estimated_tokens)"
  [ "$(value_in "$sa" budget_status)" = over-budget ] \
    || fail "the over-budget home was not classified against its own allowance"
  [ "$(value_in "$sb" budget_status)" = within-budget ] \
    || fail "a within-budget home was penalized for another home's memory"
  [ "$(value_in "$sa" role)" = secondmate ] \
    || fail "per-home accounting did not run in the secondmate home"
  pass "each home is accounted against its own allowance instead of a fleet total"
}

test_every_registered_home_is_enumerated_exactly_once() {
  local primary a b c out count dup rc
  primary=$(new_primary enumerate)
  a=$(new_home enum-a)
  b=$(new_home enum-b)
  c=$(new_home enum-c)
  {
    local_record enum-a "$a"
    local_record enum-b "$b"
    local_record enum-c "$c"
  } > "$primary/data/secondmates.md"
  # Two live endpoint records naming the same home must not multiply its stanza:
  # the registry, not the endpoint inventory, is the enumeration source.
  fm_write_secondmate_meta "$primary/state/enum-a.meta" "$a"
  fm_write_secondmate_meta "$primary/state/enum-a-stale.meta" "$a"

  set +e
  out=$(run_cascade "$primary")
  set -e
  count=$(printf '%s\n' "$out" | grep -c '^secondmate=')
  [ "$count" -eq 3 ] || fail "expected one stanza per registered home, got $count"
  [ "$(printf '%s\n' "$out" | grep -c '^secondmate=enum-a$')" -eq 1 ] \
    || fail "a home with two endpoint records was enumerated more than once"
  [ "$(printf '%s\n' "$out" | sed -n 's/^secondmates=//p')" = 3 ] \
    || fail "the cascade total did not match the registered homes"

  dup=$(new_primary enumerate-dup)
  {
    local_record enum-a "$a"
    local_record enum-other "$a"
  } > "$dup/data/secondmates.md"
  set +e
  out=$(run_cascade "$dup" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a registry that double-counts a home should refuse the cascade"
  assert_contains "$out" 'duplicate secondmate home assignment' \
    "the double-counted home was not named"
  pass "the cascade emits one stanza per registered home and refuses a double-counted registry"
}

test_transport_routes_by_placement_and_liveness() {
  local primary live idle remote out s
  primary=$(new_primary transport)
  live=$(new_home live-local)
  idle=$(new_home idle-local)
  remote="$TMP_ROOT/homes/remote-home"
  {
    local_record live-local "$live"
    local_record idle-local "$idle"
    remote_record remote-live remote-mac "$TMP_ROOT/remote-root" "$remote"
  } > "$primary/data/secondmates.md"
  fm_write_secondmate_meta "$primary/state/live-local.meta" "$live" 'firstmate:fm-live-local' alpha claude
  fm_write_secondmate_meta "$primary/state/remote-live.meta" "$remote" 'fm-remote:fm-remote-live' alpha claude
  printf 'role=secondmate\neffective_budget_tokens=7500\ntotal_estimated_tokens=100\nbudget_status=within-budget\n' \
    > "$TMP_ROOT/remote-budget.txt"

  set +e
  out=$(run_cascade "$primary" \
    FM_FAKE_TMUX_WINDOW='fm-live-local' \
    FM_FAKE_REMOTE_BUDGET="$TMP_ROOT/remote-budget.txt" \
    FM_FAKE_REMOTE_AGENT_STATE=alive)
  set -e
  [ "$(value_in "$(stanza "$out" live-local)" transport)" = agent ] \
    || fail "a local home with a live agent was not routed to that agent"
  [ "$(value_in "$(stanza "$out" idle-local)" placement)" = local ] \
    || fail "a local home was not reported as local"
  [ "$(value_in "$(stanza "$out" idle-local)" transport)" = direct ] \
    || fail "a local home with no live agent was not routed to direct curation"
  s=$(stanza "$out" remote-live)
  [ "$(value_in "$s" placement)" = remote ] || fail "a remote home was not reported as remote"
  [ "$(value_in "$s" host)" = remote-mac ] || fail "a remote home did not name its host"
  [ "$(value_in "$s" transport)" = agent ] \
    || fail "a remote home with a live agent was not routed to that agent"
  [ "$(value_in "$s" total_estimated_tokens)" = 100 ] \
    || fail "the remote home's own accounting was not reported"

  set +e
  out=$(run_cascade "$primary" \
    FM_FAKE_TMUX_WINDOW='fm-live-local' \
    FM_FAKE_REMOTE_BUDGET="$TMP_ROOT/remote-budget.txt" \
    FM_FAKE_REMOTE_AGENT_STATE=dead)
  set -e
  s=$(stanza "$out" remote-live)
  [ "$(value_in "$s" transport)" = deferred ] \
    || fail "a remote home with no live agent was not deferred: $(value_in "$s" transport)"
  assert_contains "$s" 'no remote memory write path' \
    "the deferred remote home did not state why it cannot be curated in place"
  pass "transport follows placement and live-agent state, and a remote home without an agent defers"
}

test_receipt_facts_are_complete_and_show_before_and_after() {
  local primary home before after s
  primary=$(new_primary receipt)
  home=$(new_home receipt-home 20)
  printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$home/data/captain.md"
  printf '%s\n' 'bbbbbb' > "$home/data/learnings.md"
  local_record receipt-home "$home" > "$primary/data/secondmates.md"

  set +e
  before=$(run_cascade "$primary")
  set -e
  s=$(stanza "$before" receipt-home)
  [ "$(value_in "$s" placement)" = local ] || fail "receipt stanza lacks placement"
  [ "$(value_in "$s" home)" = "$home" ] || fail "receipt stanza lacks the home it accounted"
  [ "$(value_in "$s" budget_report)" = ok ] || fail "receipt stanza lacks an accounting outcome"
  [ -n "$(value_in "$s" transport)" ] || fail "receipt stanza lacks a transport"
  local file
  for file in captain.md captain-shared.md learnings.md; do
    assert_contains "$s" "file=data/$file " "receipt stanza lacks a per-file action input for $file"
  done
  [ "$(value_in "$s" budget_status)" = over-budget ] \
    || fail "the over-budget home was not surfaced before curation"

  # Curation shrinks this home's editable memory; the same command is the
  # after-pass, so before and after totals come from one accounting contract.
  printf '%s\n' 'aaa' > "$home/data/captain.md"
  set +e
  after=$(run_cascade "$primary")
  set -e
  s=$(stanza "$after" receipt-home)
  [ "$(value_in "$s" budget_status)" = within-budget ] \
    || fail "the after pass did not reflect this home's curation"
  [ "$(value_in "$(stanza "$before" receipt-home)" total_estimated_tokens)" \
    -gt "$(value_in "$s" total_estimated_tokens)" ] \
    || fail "the after total did not drop below the before total"
  pass "each stanza carries the facts a per-home receipt needs, before and after curation"
}

test_a_slow_remote_is_bounded_and_the_rest_still_report() {
  local primary home remote out rc started elapsed s
  primary=$(new_primary bounded)
  home=$(new_home bounded-local 10)
  printf '%s\n' 'cccccc' > "$home/data/captain.md"
  remote="$TMP_ROOT/homes/bounded-remote"
  {
    remote_record bounded-remote remote-mac "$TMP_ROOT/remote-root" "$remote"
    local_record bounded-local "$home"
  } > "$primary/data/secondmates.md"
  fm_write_secondmate_meta "$primary/state/bounded-remote.meta" "$remote" 'fm-remote:fm-bounded-remote'
  printf 'role=secondmate\n' > "$TMP_ROOT/remote-budget.txt"

  started=$(date +%s)
  set +e
  out=$(run_cascade "$primary" \
    FM_STOW_CASCADE_TIMEOUT=2 \
    FM_FAKE_SSH_MODE=hang \
    FM_FAKE_REMOTE_BUDGET="$TMP_ROOT/remote-budget.txt")
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 30 ] || fail "the sweep waited $elapsed s on a host that never answered"
  s=$(stanza "$out" bounded-remote)
  [ "$(value_in "$s" budget_report)" = timeout ] \
    || fail "an unanswered home did not report a bounded exception"
  [ "$(value_in "$s" transport)" = unavailable ] \
    || fail "an unanswered home claimed a transport conclusion"
  s=$(stanza "$out" bounded-local)
  [ "$(value_in "$s" budget_report)" = ok ] \
    || fail "the healthy home was blocked by the unanswered one"
  [ "$(value_in "$s" total_estimated_tokens)" = 3 ] \
    || fail "the healthy home's own accounting was lost"
  expect_code 3 "$rc" "a reported per-home exception should be distinguishable from a clean sweep"
  assert_contains "$out" 'exceptions=1' "the sweep did not count the unreachable home"

  set +e
  out=$(run_cascade "$primary" \
    FM_FAKE_SSH_MODE=unreachable \
    FM_FAKE_REMOTE_BUDGET="$TMP_ROOT/remote-budget.txt")
  rc=$?
  set -e
  [ "$(value_in "$(stanza "$out" bounded-remote)" budget_report)" = error ] \
    || fail "an unreachable host was not reported as a per-home exception"
  [ "$(value_in "$(stanza "$out" bounded-local)" budget_report)" = ok ] \
    || fail "an unreachable host blocked the healthy home"
  expect_code 3 "$rc" "an unreachable host should still finish the sweep"
  pass "one slow or unreachable home is bounded and every other home still reports"
}

test_no_cascade_without_secondmates_or_from_a_secondmate_home() {
  local primary secondmate out rc
  primary=$(new_primary quiet)
  set +e
  out=$(run_cascade "$primary")
  rc=$?
  set -e
  expect_code 0 "$rc" "a home with no registered secondmates should be a clean no-op"
  assert_contains "$out" 'secondmates=0' "an empty cascade did not say so"
  assert_not_contains "$out" 'secondmate=' "an empty cascade invented a home"

  secondmate=$(new_home quiet-secondmate)
  local_record quiet-secondmate "$secondmate" > "$secondmate/data/secondmates.md"
  set +e
  out=$(run_cascade "$secondmate")
  rc=$?
  set -e
  expect_code 0 "$rc" "a secondmate home should not fail its own stow"
  assert_contains "$out" 'role=secondmate' "a secondmate home was not recognized"
  assert_contains "$out" 'secondmates=0' "a secondmate home cascaded to its own registry"
  pass "the cascade stays silent with no secondmates and never runs from a secondmate home"
}

test_budget_is_enforced_per_home_and_never_summed
test_every_registered_home_is_enumerated_exactly_once
test_transport_routes_by_placement_and_liveness
test_receipt_facts_are_complete_and_show_before_and_after
test_a_slow_remote_is_bounded_and_the_rest_still_report
test_no_cascade_without_secondmates_or_from_a_secondmate_home
