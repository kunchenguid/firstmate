#!/usr/bin/env bash
# tests/fm-away-continuation.test.sh - work continuation while a decision is
# blocked, and the reentry summary (bin/fm-away-continuation.sh).
#
# Coverage:
#   - pausing dependent work blocks exactly the named tasks, is idempotent, and
#     leaves independent work available (with a negative control: an unpaused
#     task is genuinely unblocked, so "independent" is not a label on nothing)
#   - the dependency frontier is the transitive closure over the existing
#     blocked_by edges, so work blocked behind paused work is dependent too
#   - the reentry summary derives its D0/D1/D2/D3 counts from the away ledger
#     rather than from a second tally
#   - a D3 item leads with the recommended ruling, then the opposing position,
#     the cost of accepting and of rejecting, reversibility, blast radius, the
#     settled architecture at stake, and the exact directive needed
#   - batch-safe marking separates a reversible, contained item from an
#     irreversible or broad one, so a materially different action cannot hide
#     inside an undifferentiated approval
#   - a session with no genuine ruling says so plainly and stays short
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONT="$ROOT/bin/fm-away-continuation.sh"
SESSION="$ROOT/bin/fm-away-session.sh"
CLASS="$ROOT/bin/fm-decision-class.sh"
RULING="$ROOT/bin/fm-ruling-request.sh"
HOLD="$ROOT/bin/fm-decision-hold.sh"
DOUBLE="$ROOT/tests/fm-sol-ruling-double.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-continuation-tests)
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# new_world <name>: an FM_HOME with a tasks-axi backlog and a throwaway repo the
# ruling requests bind their baseline to.
new_world() {
  local home="$TMP_ROOT/$1" repo="$TMP_ROOT/$1-repo"
  mkdir -p "$home/state" "$home/data"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  git init -q -b main "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  printf '%s|%s\n' "$home" "$repo"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_AWAY_LAUNCH_MODE=start-native "$@"
}

axi() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

blocked_by_of() {  # <home> <task>
  axi "$1" show "$2" --full | sed -n 's/^  blocked_by: //p' | head -1 | tr -d '"[:space:]'
}

test_pause_blocks_only_dependent_work() {
  local rec home repo hold out
  rec=$(new_world pause)
  IFS='|' read -r home repo <<EOF
$rec
EOF
  : "$repo"
  axi "$home" add widget-api "Widget API" --repo demo >/dev/null
  axi "$home" add widget-cli "Widget CLI" --repo demo >/dev/null
  axi "$home" add lint-sweep "Lint sweep" --repo demo >/dev/null
  in_home "$home" "$SESSION" start --intent afk >/dev/null 2>&1
  hold=$(in_home "$home" "$HOLD" hold widget-api shape \
    --title 'Widget API ownership' --reason 'reassigns the architectural owner' --repo demo)

  out=$(in_home "$home" "$CONT" pause --hold "$hold" --task widget-cli)
  case "$out" in *"paused widget-cli"*) : ;; *) fail "pause did not report the paused task: $out" ;; esac
  [ "$(blocked_by_of "$home" widget-cli)" = "$hold" ] \
    || fail "the dependent task was not blocked on the decision"

  # NEGATIVE CONTROL: an independent task must be genuinely unblocked, not just
  # absent from the paused list.
  [ "$(blocked_by_of "$home" lint-sweep)" = none ] \
    || fail "independent work was blocked by the decision as well"

  out=$(in_home "$home" "$CONT" pause --hold "$hold" --task widget-cli)
  case "$out" in *"already-paused widget-cli"*) : ;; *) fail "pausing twice was not idempotent: $out" ;; esac
  pass "pausing a decision blocks exactly the dependent work and leaves independent work available"
}

test_frontier_is_the_transitive_closure() {
  local rec home repo hold out dependent independent
  rec=$(new_world frontier)
  IFS='|' read -r home repo <<EOF
$rec
EOF
  : "$repo"
  axi "$home" add widget-api "Widget API" --repo demo >/dev/null
  axi "$home" add widget-cli "Widget CLI" --repo demo >/dev/null
  axi "$home" add widget-release "Widget release" --repo demo >/dev/null
  axi "$home" add lint-sweep "Lint sweep" --repo demo >/dev/null
  axi "$home" block widget-release --by widget-cli >/dev/null
  in_home "$home" "$SESSION" start --intent afk >/dev/null 2>&1
  hold=$(in_home "$home" "$HOLD" hold widget-api shape \
    --title 'Widget API ownership' --reason 'reassigns the architectural owner' --repo demo)
  in_home "$home" "$CONT" pause --hold "$hold" --task widget-cli >/dev/null

  out=$(in_home "$home" "$CONT" frontier --hold "$hold")
  dependent=$(printf '%s\n' "$out" | sed -n 's/^dependent=//p')
  independent=$(printf '%s\n' "$out" | sed -n 's/^independent=//p')

  case " $dependent " in *" widget-cli "*) : ;; *) fail "the directly paused task is not dependent: $dependent" ;; esac
  case " $dependent " in
    *" widget-release "*) : ;;
    *) fail "work blocked behind paused work was not counted as dependent: $dependent" ;;
  esac
  case " $independent " in *" lint-sweep "*) : ;; *) fail "unrelated work was not independent: $independent" ;; esac
  case " $independent " in
    *" widget-release "*) fail "a transitively dependent task was reported as independent" ;;
  esac
  case " $independent " in
    *" $hold "*) fail "the captain decision itself was reported as available work" ;;
  esac
  pass "the dependency frontier is the transitive closure over existing blocked_by edges"
}

# make_ruling <home> <repo> <task> <reversibility> <blast>: a complete D3 request
# with an accepted, operator-reserved response.
make_ruling() {
  local home=$1 repo=$2 task=$3 reversibility=$4 blast=$5 id session
  id=$(in_home "$home" "$RULING" create --task "$task" --key shape --repo "$repo" --tier D3 \
    --question "Does the $task owner move to the platform team?" \
    --why 'Two teams change the same module and neither owns it' \
    --recommendation 'Move ownership to the platform team' \
    --counterargument 'The core team holds the only regression suite' \
    --dependency-impact 'every dependent task stays paused' \
    --reversibility "$reversibility" --blast-radius "$blast" \
    --falsifier 'evidence the platform team cannot run the suite' \
    --expiry-condition 'invalid if either team reorganizes' \
    --expires "$(( $(date +%s) + 7200 ))" \
    --alternative 'keep core-team ownership with a review rule' \
    --authority-evidence 'ADR-0048 reserves authority changes to the operator' \
    --authorized-action move-ownership-to-platform \
    --authorized-action keep-core-ownership \
    --invariant 'no component declares a caller identity to satisfy the matrix' \
    --available-verification 'run the regression suite as the platform team' \
    --verifiable-precondition 'the regression suite is green')
  session=$(in_home "$home" "$SESSION" id)
  "$DOUBLE" operator-reserved "$home/state/away/$session/ruling/$id/request" > "$home/response"
  in_home "$home" "$RULING" validate "$id" --repo "$repo" --response "$home/response" >/dev/null
  printf '%s\n' "$id"
}

test_reentry_reports_decisions_not_transcripts() {
  local rec home repo hold out
  rec=$(new_world reentry)
  IFS='|' read -r home repo <<EOF
$rec
EOF
  axi "$home" add widget-api "Widget API" --repo demo >/dev/null
  axi "$home" add widget-cli "Widget CLI" --repo demo >/dev/null
  axi "$home" add lint-sweep "Lint sweep" --repo demo >/dev/null
  axi "$home" start lint-sweep >/dev/null
  in_home "$home" "$SESSION" start --intent afk >/dev/null 2>&1

  in_home "$home" "$CLASS" classify --task widget-api --key naming \
    --standing-rule 'AGENTS.md section 7' --record >/dev/null
  in_home "$home" "$CLASS" classify --task widget-api --key retry --record >/dev/null
  in_home "$home" "$CLASS" classify --task widget-api --key backoff --confidence low --record >/dev/null
  in_home "$home" "$CLASS" classify --task widget-api --key shape \
    --reassigns-authority yes --record >/dev/null

  hold=$(in_home "$home" "$HOLD" hold widget-api shape \
    --title 'Widget API ownership' --reason 'reassigns the architectural owner' --repo demo)
  in_home "$home" "$CONT" pause --hold "$hold" --task widget-cli >/dev/null
  make_ruling "$home" "$repo" widget-api 'reversible - ownership can move back' contained >/dev/null

  out=$(in_home "$home" "$CONT" reentry)

  case "$out" in
    *"D0=1 D1=1"*) : ;;
    *) fail "the reentry counts were not derived from the ledger: $out" ;;
  esac
  case "$out" in *"D2=1"*) : ;; *) fail "the assisted count was wrong: $out" ;; esac
  case "$out" in *"decisions reserved to you: D3=1"*) : ;; *) fail "the reserved count was wrong: $out" ;; esac
  case "$out" in *"work still executing:"*"lint-sweep"*) : ;; *) fail "in-flight independent work was not reported: $out" ;; esac
  case "$out" in *"decision: $hold"*) : ;; *) fail "the open decision was not reported: $out" ;; esac
  case "$out" in *"recommended ruling:"*) : ;; *) fail "no recommended ruling was rendered: $out" ;; esac
  case "$out" in *"strongest opposing position:"*) : ;; *) fail "no opposing position was rendered: $out" ;; esac
  case "$out" in *"if accepted: move-ownership-to-platform"*) : ;; *) fail "the accept consequence was missing: $out" ;; esac
  case "$out" in *"if rejected:"*) : ;; *) fail "the reject consequence was missing: $out" ;; esac
  case "$out" in *"settled architecture at stake:"*) : ;; *) fail "the invariants at stake were missing: $out" ;; esac
  case "$out" in
    *"exact directive needed: choose one of: move-ownership-to-platform, keep-core-ownership"*) : ;;
    *) fail "the exact directive was not spelled out: $out" ;;
  esac
  case "$out" in *"batch-safe: yes"*) : ;; *) fail "a reversible contained item was not marked batch-safe: $out" ;; esac
  case "$out" in *"work paused by this: widget-cli"*) : ;; *) fail "the paused work was not attributed: $out" ;; esac

  # The recommended ruling must come before the opposing position, so the
  # captain reads the recommendation first.
  local rec_line opp_line
  rec_line=$(printf '%s\n' "$out" | grep -n 'recommended ruling:' | head -1 | cut -d: -f1)
  opp_line=$(printf '%s\n' "$out" | grep -n 'strongest opposing position:' | head -1 | cut -d: -f1)
  [ "$rec_line" -lt "$opp_line" ] || fail "the opposing position was rendered before the recommended ruling"

  pass "the reentry summary is decision-oriented and leads each reserved decision with its recommended ruling"
}

test_an_irreversible_item_is_not_batch_safe() {
  local rec home repo hold out
  rec=$(new_world batch-safety)
  IFS='|' read -r home repo <<EOF
$rec
EOF
  axi "$home" add widget-api "Widget API" --repo demo >/dev/null
  in_home "$home" "$SESSION" start --intent afk >/dev/null 2>&1
  hold=$(in_home "$home" "$HOLD" hold widget-api shape \
    --title 'Widget API ownership' --reason 'reassigns the architectural owner' --repo demo)
  make_ruling "$home" "$repo" widget-api 'irreversible - the old owner loses history' broad >/dev/null

  out=$(in_home "$home" "$CONT" reentry)
  case "$out" in
    *"batch-safe: no"*) : ;;
    *) fail "an irreversible, broad decision was offered as batch-safe: $out" ;;
  esac
  : "$hold"
  pass "an irreversible or broad decision is never marked safe for an undifferentiated approval"
}

test_a_session_with_no_ruling_says_so_plainly() {
  local rec home repo out
  rec=$(new_world no-rulings)
  IFS='|' read -r home repo <<EOF
$rec
EOF
  : "$repo"
  axi "$home" add lint-sweep "Lint sweep" --repo demo >/dev/null
  in_home "$home" "$SESSION" start --intent afk >/dev/null 2>&1
  in_home "$home" "$CLASS" classify --task lint-sweep --key style --record >/dev/null

  out=$(in_home "$home" "$CONT" reentry)
  case "$out" in
    *"decisions still waiting on you:"*"(none - no genuine ruling is waiting)"*) : ;;
    *) fail "a session with no reserved decision did not say so plainly: $out" ;;
  esac
  case "$out" in
    *"batch-safe"*) fail "an empty session still rendered decision detail: $out" ;;
  esac
  pass "a session with no genuine ruling reports that plainly and keeps the summary short"
}

test_pause_blocks_only_dependent_work
test_frontier_is_the_transitive_closure
test_reentry_reports_decisions_not_transcripts
test_an_irreversible_item_is_not_batch_safe
test_a_session_with_no_ruling_says_so_plainly

echo "# fm-away-continuation.test.sh: all assertions passed"
