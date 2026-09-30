#!/usr/bin/env bash
# Real-Herdr regression for cleaning up completed scouts whose records still
# name a persistent secondmate home seeded into their reused pool slot.
# bin/fm-teardown.sh lets such a scout skip the duplicate-record refusal only
# when the recovery-grade classifier reads its exact recorded endpoint dead or
# missing, so the endpoints here are real panes in an isolated named lab
# session: a shell-only pane (dead), a closed pane (missing), a registered
# agent over a claude-named process (alive), and that process unregistered
# (unreadable). The test drives the real bin/fm-home-seed.sh claim-slot and
# bin/fm-teardown.sh. Every adapter call goes through the guarded lab helper,
# and Treehouse is a logging stub that refuses, so a pool operation against the
# seeded home fails the test instead of running. No agent is launched and no
# model tokens are spent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_TEARDOWN_PERSISTENT_SLOT_HERDR_E2E herdr jq

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
REAL_HERDR=$(command -v herdr)
TMP_ROOT=$(fm_test_tmproot fm-teardown-persistent-slot-herdr-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
RUNTIME_LOG="$TMP_ROOT/runtime.log"
mkdir -p "$FAKEBIN"
: > "$RUNTIME_LOG"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-persistent-slot)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH REAL_HERDR RUNTIME_LOG

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated Herdr lab"

# Log every production-adapter call, strip its already-validated trailing lab
# session flag, and send it through the lab helper, which alone appends the
# real session flag. The adapter's session-independent version read cannot pass
# the helper's leading-option guard, so only that read goes straight to the
# real binary with the same explicit lab session. Any other session refuses.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf 'herdr' >> "$RUNTIME_LOG"
printf ' <%s>' "$@" >> "$RUNTIME_LOG"
printf '\n' >> "$RUNTIME_LOG"
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "$RUNTIME_LOG"
printf ' <%s>' "$@" >> "$RUNTIME_LOG"
printf '\n' >> "$RUNTIME_LOG"
exit 92
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

endpoint_state() {  # <pane_id>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_agent_state herdr "$2:$3"
  ' _ "$ROOT" "$HERDR_LAB_SESSION" "$1"
}

pane_present() {  # <pane_id>
  lab pane get "$1" >/dev/null 2>&1
}

# --- The seeded home: a Treehouse pool slot leased to the secondmate ---------
MATE=harbor
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
POOL="$TMP_ROOT/pool"
fm_git_init_commit "$PROJECT" >/dev/null
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$POOL/1"
git -C "$PROJECT" worktree add -q --detach "$POOL/1/project"
SLOT=$(cd "$POOL/1/project" && pwd -P)
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
  "$SLOT" "$MATE" > "$POOL/treehouse-state.json"
printf '%s\n' "$MATE" > "$SLOT/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$SLOT/.fm-secondmate-parent"
mkdir -p "$SLOT/data" "$SLOT/state" "$SLOT/config" "$SLOT/projects"
printf 'saved review\n' > "$SLOT/data/review.md"
fm_git_init_commit "$SLOT/projects/$MATE" >/dev/null
printf -- '- %s - Persistent fixture domain (home: %s; scope: persistent work; projects: %s; added 2026-09-29)\n' \
  "$MATE" "$SLOT" "$MATE" > "$HOME_DIR/data/secondmates.md"
# The slot's claim still names the scout that used it before the seed.
printf 'task=old-scout-a\nhome=%s\n' "$HOME_DIR" > "$POOL/1/.fm-slot-owner"

home_fingerprint() {
  (
    cd "$POOL" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s %s\n' "$(cksum < "$path")" "$path"
    done
    git -C 1/project rev-parse HEAD
    git -C "1/project/projects/$MATE" rev-parse HEAD
  )
}

# --- Four completed scouts, each bound to a real lab pane --------------------
CREATE=$(lab workspace create --cwd "$TMP_ROOT" --label persistent-slot --no-focus) \
  || fail "could not create the lab workspace"
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') || fail "no workspace id"
CONTROL_PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') || fail "no control pane id"

new_scout_pane() {  # <id> -> "<tab_id> <pane_id>"
  local out
  out=$(lab tab create --workspace "$WS" --cwd "$TMP_ROOT" --label "fm-$1" --no-focus) \
    || fail "could not create the lab tab for $1"
  printf '%s %s\n' \
    "$(printf '%s' "$out" | jq -er '.result.tab.tab_id')" \
    "$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id')"
}

write_scout() {  # <id> <tab_id> <pane_id>
  mkdir -p "$HOME_DIR/data/$1"
  printf 'Complete fixture report with no unresolved choices.\n' > "$HOME_DIR/data/$1/report.md"
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=$HERDR_LAB_SESSION:$3" "endpoint_task_id=$1" \
    "worktree=$SLOT" "project=$PROJECT" "kind=scout" "backend=herdr" \
    "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$WS" \
    "herdr_tab_id=$2" "herdr_pane_id=$3" \
    "decisions_reviewed=1" "decision_keys="
}

read -r TAB_A PANE_A <<EOF
$(new_scout_pane old-scout-a)
EOF
read -r TAB_B PANE_B <<EOF
$(new_scout_pane old-scout-b)
EOF
read -r TAB_C PANE_C <<EOF
$(new_scout_pane old-scout-c)
EOF
read -r TAB_D PANE_D <<EOF
$(new_scout_pane old-scout-d)
EOF
write_scout old-scout-a "$TAB_A" "$PANE_A"
write_scout old-scout-b "$TAB_B" "$PANE_B"
write_scout old-scout-c "$TAB_C" "$PANE_C"
write_scout old-scout-d "$TAB_D" "$PANE_D"

# old-scout-a: a shell-only pane. old-scout-b: its pane is closed.
# old-scout-c: a claude-named process under a registered agent.
# old-scout-d: the same process with no registration.
lab pane close "$PANE_B" >/dev/null || fail "could not close old-scout-b's pane"
lab pane run "$PANE_C" "(exec -a claude sleep 600)" >/dev/null || fail "could not start old-scout-c's process"
lab pane run "$PANE_D" "(exec -a claude sleep 600)" >/dev/null || fail "could not start old-scout-d's process"
for _ in $(seq 1 50); do
  lab pane process-info --pane "$PANE_C" 2>/dev/null | grep -q '"argv0":"claude"' \
    && lab pane process-info --pane "$PANE_D" 2>/dev/null | grep -q '"argv0":"claude"' && break
  sleep 0.2
done
lab pane report-agent --source fm-test --agent claude --state idle "$PANE_C" >/dev/null \
  || fail "could not register old-scout-c's agent"
# Herdr detects the claude-named process on its own; classify only once it has,
# so a slow detection cannot read as an agent-free pane.
for _ in $(seq 1 100); do
  lab agent get "$PANE_C" 2>/dev/null | jq -e '.result.agent' >/dev/null 2>&1 \
    && lab agent get "$PANE_D" 2>/dev/null | jq -e '.result.agent' >/dev/null 2>&1 && break
  sleep 0.2
done
lab agent get "$PANE_D" 2>/dev/null | jq -e '.result.agent' >/dev/null 2>&1 \
  || fail "Herdr never detected old-scout-d's claude-named process"

run_teardown() {  # <id>
  : > "$RUNTIME_LOG"
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    "$ROOT/bin/fm-teardown.sh" "$1" > "$TMP_ROOT/$1.out" 2> "$TMP_ROOT/$1.err"
}

assert_refused_untouched() {  # <id> <pane_id> <description>
  local id=$1 pane=$2 description=$3 before_meta
  before_meta=$(cksum < "$HOME_DIR/state/$id.meta")
  if run_teardown "$id"; then
    fail "$description: teardown finished: $(cat "$TMP_ROOT/$id.out")"
  fi
  [ "$(cksum < "$HOME_DIR/state/$id.meta")" = "$before_meta" ] || fail "$description: the record changed"
  [ "$(home_fingerprint)" = "$BEFORE" ] || fail "$description: the seeded home, lease, or claim changed"
  ! grep -Eq 'treehouse|pane> <close' "$RUNTIME_LOG" \
    || fail "$description: a pool or close operation ran: $(cat "$RUNTIME_LOG")"
  pane_present "$pane" || fail "$description: its pane was closed"
}

# Before the claim is reconciled the stale claim names old-scout-a, so its
# cleanup would have returned the home; it refuses and names the reconciliation.
BEFORE=$(home_fingerprint)
assert_refused_untouched old-scout-a "$PANE_A" "stale claim"
assert_contains "$(cat "$TMP_ROOT/old-scout-a.err")" "claim-slot $MATE" \
  "the stale-claim refusal should name the claim reconciliation"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" "$ROOT/bin/fm-home-seed.sh" claim-slot "$MATE" \
  > "$TMP_ROOT/claim.out" 2> "$TMP_ROOT/claim.err" \
  || fail "claim-slot refused a proved persistent home: $(cat "$TMP_ROOT/claim.err")"
BEFORE=$(home_fingerprint)

# The real classifier verdicts this cleanup path depends on.
STATE_A=$(endpoint_state "$PANE_A")
STATE_B=$(endpoint_state "$PANE_B")
STATE_C=$(endpoint_state "$PANE_C")
STATE_D=$(endpoint_state "$PANE_D")
printf 'evidence: %s endpoint states: shell-only=%s closed=%s registered-claude=%s unregistered-claude=%s\n' \
  "$("$FAKEBIN/herdr" --version --session "$HERDR_LAB_SESSION" 2>/dev/null | head -1)" "$STATE_A" "$STATE_B" "$STATE_C" "$STATE_D"
[ "$STATE_A" = dead ] || fail "a shell-only pane classified '$STATE_A', want dead"
[ "$STATE_B" = missing ] || fail "a closed pane classified '$STATE_B', want missing"
[ "$STATE_C" = alive ] || fail "a registered claude process classified '$STATE_C', want alive"
[ "$STATE_D" = unreadable ] || fail "an unregistered claude process classified '$STATE_D', want unreadable"

assert_refused_untouched old-scout-c "$PANE_C" "live old endpoint"
assert_contains "$(cat "$TMP_ROOT/old-scout-c.err")" "is also task" \
  "a live old endpoint should keep the duplicate-record refusal"
assert_refused_untouched old-scout-d "$PANE_D" "unreadable old endpoint"
assert_contains "$(cat "$TMP_ROOT/old-scout-d.err")" "is also task" \
  "an unreadable old endpoint should keep the duplicate-record refusal"
pass "real Herdr: a live or unreadable old endpoint keeps the duplicate-record refusal on a reconciled persistent home"

run_teardown old-scout-a || fail "the dead-endpoint scout did not finish: $(cat "$TMP_ROOT/old-scout-a.err")"
assert_absent "$HOME_DIR/state/old-scout-a.meta" "the dead-endpoint scout's record remained"
pane_present "$PANE_A" && fail "the dead-endpoint scout's own pane was not closed"
[ "$(home_fingerprint)" = "$BEFORE" ] || fail "the dead-endpoint cleanup changed the seeded home, lease, or claim"
! grep -Fq treehouse "$RUNTIME_LOG" || fail "the dead-endpoint cleanup ran a pool operation: $(cat "$RUNTIME_LOG")"

run_teardown old-scout-b || fail "the missing-endpoint scout did not finish: $(cat "$TMP_ROOT/old-scout-b.err")"
assert_absent "$HOME_DIR/state/old-scout-b.meta" "the missing-endpoint scout's record remained"
[ "$(home_fingerprint)" = "$BEFORE" ] || fail "the missing-endpoint cleanup changed the seeded home, lease, or claim"
! grep -Fq treehouse "$RUNTIME_LOG" || fail "the missing-endpoint cleanup ran a pool operation: $(cat "$RUNTIME_LOG")"

for pane in "$CONTROL_PANE" "$PANE_C" "$PANE_D"; do
  pane_present "$pane" || fail "an unrelated or refused endpoint $pane was closed"
done
assert_present "$HOME_DIR/state/old-scout-c.meta" "the live scout's record was removed"
assert_present "$HOME_DIR/state/old-scout-d.meta" "the unreadable scout's record was removed"
pass "real Herdr: completed scouts whose endpoints are dead or missing finish without touching the reconciled persistent home"
