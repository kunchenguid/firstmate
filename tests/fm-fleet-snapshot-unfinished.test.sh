#!/usr/bin/env bash
# Unfinished filtering happens before runtime/provider/report/status enrichment.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-unfinished)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/fakebin"
export FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT"
TASKS="$ROOT/bin/fm-tasks-axi.sh"

for spec in 'active:in_flight' 'queued:queued' 'held:queued' 'blocked:in_flight' 'done:done' 'archived:archived'; do
  id=${spec%%:*}; state=${spec#*:}
  "$TASKS" add "$id" "$id goal" --kind ship >/dev/null || fail "create $id failed"
  case "$state" in
    in_flight) "$TASKS" start "$id" >/dev/null ;;
    done) "$TASKS" start "$id" >/dev/null; "$TASKS" 'done' "$id" >/dev/null ;;
    archived) "$TASKS" archive "$id" >/dev/null ;;
  esac
done
"$TASKS" hold held --reason "paused for captain" --kind captain --until 2026-12-01 >/dev/null
"$TASKS" block blocked --by queued >/dev/null
mkdir -p "$HOME_DIR/data/active" "$HOME_DIR/data/done" "$HOME_DIR/data/archived"
printf 'active report\n' >"$HOME_DIR/data/active/report.md"
printf 'done sentinel report\n' >"$HOME_DIR/data/done/report.md"
printf 'archived sentinel report\n' >"$HOME_DIR/data/archived/report.md"

for id in active 'done' archived; do
  printf 'spawn_gen=g1\nkind=ship\nexecutor=local-agent\nbackend=herdr\nwindow=%s-window\nendpoint_task_id=%s\n' "$id" "$id" \
    >"$HOME_DIR/state/$id.meta"
  printf 'working: %s sentinel status\n' "$id" >"$HOME_DIR/state/$id.status"
done

cat >"$HOME_DIR/fakebin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_QUERY_LOG"
case "${1:-} ${2:-}" in
  'status --json') printf '%s\n' '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}' ;;
  'pane read') printf 'idle shell\n' ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$HOME_DIR/fakebin/herdr"
export PATH="$HOME_DIR/fakebin:$PATH" FM_QUERY_LOG="$HOME_DIR/query.log"
: >"$FM_QUERY_LOG"

unfinished=$("$ROOT/bin/fm-fleet-snapshot.sh" --json --unfinished) || fail "unfinished snapshot failed"
assert_equals $'active\nblocked\nheld\nqueued' \
  "$(printf '%s' "$unfinished" | jq -r '.backlog.records[].id' | sort)" \
  "unfinished snapshot membership was wrong"
printf '%s' "$unfinished" | jq -e '.query.unfinished_only==true' >/dev/null \
  || fail "unfinished snapshot did not identify its query mode"
printf '%s' "$unfinished" | jq -e '.backlog.records|any(.[];.id=="held" and .hold_kind=="captain")' >/dev/null \
  || fail "unfinished snapshot lost a held task"
printf '%s' "$unfinished" | jq -e '.backlog.records|any(.[];.id=="blocked" and (.blocked_by_ids|length)==1)' >/dev/null \
  || fail "unfinished snapshot lost a blocked task"
assert_equals active "$(printf '%s' "$unfinished" | jq -r '.scout_reports[].id')" \
  "unfinished snapshot queried terminal report inventory"
printf '%s' "$unfinished" | jq -e '.tasks|all(.[];.id!="done" and .id!="archived")' >/dev/null \
  || fail "unfinished snapshot enriched a terminal task"
assert_no_grep 'done-window\|archived-window' "$FM_QUERY_LOG" \
  "unfinished snapshot queried an excluded terminal endpoint"
assert_no_grep 'done sentinel\|archived sentinel' "$FM_QUERY_LOG" \
  "unfinished snapshot queried excluded status evidence"

: >"$FM_QUERY_LOG"
full=$("$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "full historical snapshot failed"
printf '%s' "$full" | jq -e '
  .query.unfinished_only==false and
  (.backlog.records|map(.id)|sort)==["active","archived","blocked","done","held","queued"] and
  (.scout_reports|map(.id)|sort)==["active","archived","done"]' >/dev/null \
  || fail "full snapshot no longer preserved terminal history"

for mode in full unfinished; do
  : >"$TMP_ROOT/$mode.timings"
  for _sample in 1 2 3 4 5; do
    start=$(date +%s%N)
    if [ "$mode" = unfinished ]; then
      sample=$("$ROOT/bin/fm-fleet-snapshot.sh" --json --unfinished) || fail "$mode timing sample failed"
    else
      sample=$("$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "$mode timing sample failed"
    fi
    end=$(date +%s%N)
    printf '%s\t%s\n' "$(((end-start)/1000000))" "$(printf '%s' "$sample" | jq '.backlog.records|length')" \
      >>"$TMP_ROOT/$mode.timings"
  done
done
[ "$(cut -f2 "$TMP_ROOT/unfinished.timings" | sort -u)" = 4 ] || fail "unfinished timing fixture count drifted"
[ "$(cut -f2 "$TMP_ROOT/full.timings" | sort -u)" = 6 ] || fail "full timing fixture count drifted"

for mode in full unfinished; do
  sorted=$(cut -f1 "$TMP_ROOT/$mode.timings" | sort -n)
  printf 'evidence - %s snapshot samples_ms=%s median_ms=%s range_ms=%s-%s\n' \
    "$mode" "$(printf '%s\n' "$sorted" | paste -sd, -)" \
    "$(printf '%s\n' "$sorted" | sed -n 3p)" \
    "$(printf '%s\n' "$sorted" | head -1)" "$(printf '%s\n' "$sorted" | tail -1)"
done

pass "unfinished snapshot filters canonical business records before endpoint/status/report enrichment and preserves explicit full history"
