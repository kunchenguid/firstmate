#!/usr/bin/env bash
# Behavioral coverage for idea capture, triage, merge, and decisions.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IDEA="$ROOT/bin/fm-idea.sh"
TMP_ROOT=$(fm_test_tmproot fm-idea)

make_tasks_stub() {
  local bin=$1
  cat >"$bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -eu
home=${FM_HOME:-$PWD}
data=${FM_DATA_OVERRIDE:-$home/data}
backlog=$data/backlog.md
mkdir -p "$data"
case "${1:-}" in
  --version) printf '%s\n' 'tasks-axi 0.2.5'; exit 0 ;;
  update)
    if [ "${2:-}" = --help ]; then printf '%s\n' '--archive-body'; exit 0; fi
    id=${2:-}; body=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --body ]; then body=${2:-}; shift 2; continue; fi
      if [ "$1" = --body-file ]; then body=$(<"${2:-}"); shift 2; continue; fi
      shift
    done
    printf '%s' "$body" >"$data/.stub-body-$id"
    ;;
  mv)
    if [ "${2:-}" = --help ]; then printf '%s\n' '[<id>...]'; exit 0; fi
    ;;
  hold)
    if [ "${2:-}" = --help ]; then printf '%s\n' '--kind captain'; exit 0; fi
    id=${2:-}; reason=; until=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) reason=${2:-}; shift 2 ;;
        --kind) kind=${2:-}; shift 2 ;;
        --until) until=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'hold %s %s %s\n' "$id" "$reason" "$until" >>"$data/.stub-tasks-log"
    hold_tmp=$(mktemp "$backlog.XXXXXX")
    while IFS= read -r current; do
      case "$current" in
        *"$id - "*)
          current="$current (hold: $reason) (hold-kind: captain)"
          [ -n "$until" ] && current="$current (hold-until: $until)"
          ;;
      esac
      printf '%s\n' "$current"
    done <"$backlog" >"$hold_tmp"
    mv "$hold_tmp" "$backlog"
    ;;
  add)
    id=${2:-}; title=${3:-}; kind=ship
    while [ "$#" -gt 0 ]; do
      case "$1" in --kind) kind=${2:-}; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "- [ ] $id - $title (repo: firstmate) (kind: $kind)" >>"$backlog"
    ;;
  show)
    id=${2:-}
    grep -F -- "- [ ] $id - " "$backlog" >/dev/null || { printf '%s\n' 'code: NOT_FOUND'; exit 1; }
    held=no; hold_kind=-; hold_reason=-; hold_until=-
    row=$(grep -F -- "- [ ] $id - " "$backlog")
    case "$row" in *'(hold-kind: captain)'*) held=yes; hold_kind=captain ;; esac
    hold_reason=$(printf '%s\n' "$row" | sed -n 's/.*(hold: \([^)]*\)).*/\1/p'); hold_reason=${hold_reason:--}
    hold_until=$(printf '%s\n' "$row" | sed -n 's/.*(hold-until: \([^)]*\)).*/\1/p'); hold_until=${hold_until:--}
    body=; [ -f "$data/.stub-body-$id" ] && body=$(<"$data/.stub-body-$id")
    printf 'task:\n  id: %s\n  title: stub\n  state: queued\n  held: %s\n  hold_reason: %s\n  hold_kind: %s\n  hold_until: %s\n  body: %s\n' "$id" "$held" "$hold_reason" "$hold_kind" "$hold_until" "${body:-\"\"}"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$bin/tasks-axi"
}

new_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
}

idea_id() { sed -n 's/^- \[\([^]]*\)\].*/\1/p' "$1" | head -1; }

setup_case() {
  local name=$1
  CASE_HOME="$TMP_ROOT/$name"
  CASE_BIN="$CASE_HOME/bin"
  mkdir -p "$CASE_BIN"
  new_home "$CASE_HOME"
  make_tasks_stub "$CASE_BIN"
  export FM_HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$CASE_HOME/data"
  export PATH="$CASE_BIN:$PATH"
}

test_add_list_and_triage() {
  setup_case basic
  printf '%s\n' '- [seed-1234] 2026-09-11 raw: Keep this seed' >"$CASE_HOME/data/ideas.md"
  id1=$("$IDEA" add 'Build a tiny dashboard')
  id2=$("$IDEA" add 'Write a song about logs')
  printf '%s\n' "$id1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{4}$' \
    || fail "add did not print a date plus four hex characters"
  assert_contains "$("$IDEA" list raw)" 'seed-1234' "raw list includes an existing seed"
  assert_contains "$("$IDEA" list raw)" "$id1" "raw list includes first idea"
  assert_contains "$("$IDEA" list raw)" "$id2" "raw list includes second idea"
  assert_not_contains "$("$IDEA" list cased)" "$id1" "cased list excludes raw idea"
  triage=$("$IDEA" triage)
  [ -f "$triage" ] || fail "triage did not print an existing report path"
  assert_contains "$(<"$triage")" 'Keep this seed' "triage includes an existing seed"
  assert_contains "$(<"$triage")" "For:" "triage includes For template"
  assert_contains "$(<"$triage")" "Against:" "triage includes Against template"
  assert_contains "$(<"$triage")" "Cost in minutes:" "triage includes cost template"
  assert_contains "$(<"$triage")" "Proposal: bet|queue|drop" "triage includes proposal template"
  assert_contains "$("$IDEA" list cased)" "$id1" "triage marks ideas cased"
  pass "add, list filters, and triage work"
}

test_rule_branches() {
  setup_case rules
  id_bet=$("$IDEA" add 'Bet on this')
  id_queue=$("$IDEA" add 'Queue this')
  id_drop=$("$IDEA" add 'Drop this')
  "$IDEA" triage >/dev/null
  "$IDEA" rule "$id_bet" bet --why 'clear upside'
  "$IDEA" rule "$id_queue" queue --until 2099-01-02
  "$IDEA" rule "$id_drop" drop --why 'not worth the cost'
  assert_contains "$("$IDEA" list bet)" "$id_bet" "bet rule marks bet"
  assert_contains "$(<"$CASE_HOME/data/backlog.md")" 'Bet on this' "bet rule adds backlog work"
  assert_contains "$("$IDEA" list queued)" "$id_queue" "queue rule marks queued"
  assert_contains "$(<"$CASE_HOME/data/.stub-tasks-log")" '2099-01-02' "queue rule records resurface date"
  assert_contains "$(<"$CASE_HOME/data/backlog.md")" 'hold-kind: captain' "queue rule creates a hold"
  assert_contains "$(<"$CASE_HOME/data/ideas-archive.md")" 'not worth the cost' "drop rule archives its reason"
  assert_not_contains "$(<"$CASE_HOME/data/ideas.md")" "$id_drop" "drop rule removes source row"
  pass "bet, queue, and drop rules work"
}

test_merge() {
  setup_case merge
  id1=$("$IDEA" add 'Uncertain idea')
  id2=$("$IDEA" add 'Good idea')
  triage=$("$IDEA" triage)
  first="$CASE_HOME/critic-a.md"
  second="$CASE_HOME/critic-b.md"
  cat >"$first" <<EOF
## [$id1] Uncertain idea
For: cheap
Against: unclear
Cost in minutes: 30
Proposal: bet
Reason: test cheaply

## [$id2] Good idea
For: useful
Against: none
Cost in minutes: 10
Proposal: bet
Reason: obvious value
EOF
  cat >"$second" <<EOF
## [$id1] Uncertain idea
For: cheap
Against: unclear
Cost in minutes: 30
Proposal: drop
Reason: weak demand

## [$id2] Good idea
For: useful
Against: none
Cost in minutes: 10
Proposal: bet
Reason: obvious value
EOF
  merged=$("$IDEA" merge "$triage" "$first" "$second")
  [ -f "$merged" ] || fail "merge did not print an existing report path"
  report=$(<"$merged")
  assert_contains "$report" "| $id1 | Uncertain idea | queue |" "split verdict queues an idea"
  assert_contains "$report" 'disagreement' "split verdict records disagreement"
  assert_contains "$report" "| $id2 | Good idea | bet |" "unanimous bet remains bet"
  pass "critic verdicts merge into one decision table"
}

test_help() {
  setup_case help
  help=$("$IDEA" --help)
  for word in 'add' 'list' 'triage' 'merge' 'rule' '--until' '--why'; do
    assert_contains "$help" "$word" "help documents $word"
  done
  pass "help documents verbs and flags"
}

test_add_list_and_triage
test_rule_branches
test_merge
test_help
