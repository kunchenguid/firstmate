#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

# --- markdown-to-beads migration resolution ----------------------------------
#
# A home on the Beads backend no longer carries the legacy markdown ids a scout
# report attested: fm-hold-migration rehomed each held row under a prefixed fm-
# id and recorded its markdown identity in the row's notes as the exact line
# "migrated from data/backlog.md id <legacy id>". The fixture graph is driven
# through bd directly where possible because the npm-published tasks-axi ships
# the markdown backend only; the hold itself needs a beads-capable tasks-axi,
# so that family probes once and skips itself with an explicit reason on
# markdown-only installs, mirroring tests/fm-control-relaunch.test.sh.

# Build a fixture home whose configured backend is a scratch Beads graph.
# Echoes "<home>|<graph-beads-dir>". The graph repo dir is named "fm" because
# bd derives the row-id prefix from the repo directory name.
make_beads_home() {  # <name>
  local name=$1 case_dir home graph fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  graph="$case_dir/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$graph"
  (umask 077; mkdir -p "$home/state")
  git -C "$graph" init -q
  if ! (cd "$graph" && bd init >"$case_dir/bd-init.log" 2>&1); then
    cat "$case_dir/bd-init.log" >&2
    fail "fixture bd init failed on $graph"
  fi
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  fb=$(fm_fakebin "$home")
  fm_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home|$graph/.beads"
}

bdrow() {  # <beads-dir> <args...>
  BEADS_DIR="$1" bd "${@:2}"
}

# One capability probe for the migration family: can the installed tasks-axi
# operate on a beads-backed home? The npm-published tasks-axi cannot, and the
# hold fixture needs its beads backend; those installs skip with this reason.
probe_tasks_axi_beads() {
  local probe_home="$TMP_ROOT/.probe" probe_graph="$TMP_ROOT/.probe-fm"
  rm -rf "$probe_home" "$probe_graph"
  mkdir -p "$probe_home/data" "$probe_graph"
  git -C "$probe_graph" init -q
  (cd "$probe_graph" && bd init >/dev/null 2>&1) || return 1
  cat > "$probe_home/.tasks.toml" <<PROBEEOF
backend = "beads"

[beads]
path = "$probe_graph/.beads"
binary = "bd"
prefix = "fm"
PROBEEOF
  (cd "$probe_home" && tasks-axi list) >/dev/null 2>&1
}
TASKS_AXI_BEADS_OK=0
if bd --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 \
   && probe_tasks_axi_beads; then
  TASKS_AXI_BEADS_OK=1
fi

require_tasks_axi_beads() {  # <what>
  [ "$TASKS_AXI_BEADS_OK" = 1 ] && return 0
  pass "skipped on markdown-only tasks-axi: $1"
  return 1
}

write_scout_with_attested_inventory() {  # <home> <scout-id> <keys>
  local home=$1 scout=$2 keys=$3
  mkdir -p "$home/data/$scout"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout" \
    "decisions_reviewed=1" \
    "decision_keys=$keys"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"
}

test_verify_resolves_a_hold_migrated_to_beads_notes() {
  local fixture home beads scout
  require_tasks_axi_beads "verify against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-notes)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-beads-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "Origin: herald-retire
Decision key: github-delete
State: awaiting captain decision.

migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_scout_with_attested_inventory "$home" "$scout" \
    herald-retire-decision-github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the attested legacy id through its migrated beads row"
  pass "verify resolves a captain hold migrated to a beads row with a marker note"
}

# A tasks-axi stub that knows ONLY the row ids it is given. The real
# beads-capable tasks-axi resolves a bare legacy id onto its prefixed row
# itself, answering before any migration lookup runs; against this stub the
# migrated-hold resolution order is what has to answer.
write_known_rows_stub() {  # <fakebin> <row-id...>
  local fb=$1 known
  shift
  known=$(printf '%s|' "$@")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.5' ;;
  update)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '  --kind captain'
    ;;
  show)
    case "${2:-}" in
      @KNOWN@) ;;
      *) printf 'error: no task %s in this backlog\n' "${2:-}" >&2; exit 1 ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$2"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain' '  body: ""'
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s%@KNOWN@%${known%|}%" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"
}

test_verify_resolves_a_hold_migrated_under_the_configured_prefix() {
  local fixture home scout out
  require_tasks_axi_beads "verify against a prefix-migrated hold" || return 0
  fixture=$(make_beads_home migrated-prefix)
  home=${fixture%%|*}
  scout=sample-prefix-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-other-legacy-row \
    "Second migrated hold" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the prefix-migrated fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-other-legacy-row \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the prefix-migrated fixture row"
  # No row in this graph carries a marker note, so the narrowed prefix guess is
  # the only resolution left for the attested legacy id.
  write_known_rows_stub "$(fm_fakebin "$home")" fm-other-legacy-row
  write_scout_with_attested_inventory "$home" "$scout" other-legacy-row

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the legacy id under the configured prefix"
  out=$(run_captain "$home" complete "$scout" other-legacy-row) \
    || fail "the completion gate refused the prefix-resolved hold"
  assert_contains "$out" "other-legacy-row=fm-other-legacy-row" \
    "completion did not name the row the prefix guess attested against"
  pass "verify resolves a captain hold whose id is the legacy id under the configured prefix"
}

# The prefix guess is a name, not evidence: when a row actually carries the
# migration marker, that row is the one attested even though an unrelated
# captain-held task occupies the <prefix>-<legacy id> name.
test_marker_noted_row_wins_over_a_prefix_namesake() {
  local fixture home beads scout row out
  require_tasks_axi_beads "prefer a marker-noted row over a prefix namesake" || return 0
  fixture=$(make_beads_home migrated-marker-wins)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-marker-wins-scout
  for row in fm-dual-row fm-marked-dual-row fm-solo-row; do
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi add "$row" "Captain call $row" \
      --repo sample) >/dev/null 2>&1 || fail "could not create the fixture row $row"
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold "$row" --kind captain \
      --reason "captain must decide") >/dev/null 2>&1 \
      || fail "could not hold the fixture row $row"
  done
  bdrow "$beads" note fm-marked-dual-row \
    "migrated from data/backlog.md id dual-row on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_known_rows_stub "$(fm_fakebin "$home")" \
    fm-dual-row fm-marked-dual-row fm-solo-row
  write_scout_with_attested_inventory "$home" "$scout" "dual-row,solo-row"

  out=$(run_captain "$home" complete "$scout" dual-row solo-row) \
    || fail "the completion gate refused an inventory carrying both migrated shapes"
  assert_not_contains "$out" "dual-row=fm-dual-row" \
    "the bare prefix namesake shadowed the row carrying the migration marker"
  assert_contains "$out" "solo-row=fm-solo-row" \
    "completion did not name the row the prefix guess attested against"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve both migrated shapes after completion"
  pass "the marker-noted row wins over an unrelated row holding the prefix namesake"
}

test_complete_accepts_a_migrated_inventory_on_beads() {
  local fixture home scout
  require_tasks_axi_beads "complete against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-complete)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-complete-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  mkdir -p "$home/data/$scout"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"

  run_captain "$home" complete "$scout" herald-retire-decision-github-delete >/dev/null \
    || fail "the completion gate refused an inventory resolved through a migrated beads row"
  assert_grep "decision_keys=herald-retire-decision-github-delete" \
    "$home/state/$scout.meta" \
    "the attestation did not record the attested legacy id"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve the attested legacy id after completion"
  pass "the completion gate attests an inventory resolved through a migrated beads row"
}

test_verify_names_the_unresolvable_legacy_id_once() {
  local fixture home scout err rc
  require_tasks_axi_beads "verify an unresolvable beads legacy id" || return 0
  fixture=$(make_beads_home migrated-absent)
  home=${fixture%%|*}
  scout=sample-absent-scout
  write_scout_with_attested_inventory "$home" "$scout" ghost-legacy-id

  rc=0
  err=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted an attested id that resolves to nothing"
  assert_contains "$err" "ghost-legacy-id" \
    "the refusal did not name the id it could not resolve"
  [ "$(printf '%s\n' "$err" | grep -c '^fm-captain-hold:')" = 1 ] \
    || fail "the refusal emitted more than one line: $err"
  pass "an unresolvable legacy id is refused once, naming the id"
}

test_verify_resolves_a_pre_collapse_key_through_its_derived_marker() {
  local fixture home beads scout
  require_tasks_axi_beads "verify a derived pre-collapse key" || return 0
  fixture=$(make_beads_home migrated-derived)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-derived-scout
  # The row was migrated under the DERIVED pre-collapse identity, keyed by a
  # bare decision key the origin's old metadata attests.
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-dec-call \
    "Migrated pre-collapse call" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the derived-marker fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-dec-call \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the derived-marker fixture row"
  bdrow "$beads" note fm-dec-call \
    "migrated from data/backlog.md id $scout-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the derived-id marker note"
  write_scout_with_attested_inventory "$home" "$scout" github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not probe the derived pre-collapse identity for its migrated row"
  pass "a pre-collapse key resolves through its derived identity's migration marker"
}

# The captain-hold mutation wrapper must address the configured backend like
# the transition library does: on a beads-configured home its hold/answer/done
# calls reach tasks-axi with no markdown file override. Fully portable - the
# stubbed tasks-axi fakes the beads backend, so no bd or beads-capable install
# is needed.
test_captain_hold_mutations_address_the_beads_backend() {
  local home id fb log
  home="$TMP_ROOT/captain-stub-beads/home"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = "graph/.beads"
binary = "bd"
prefix = "fm"
EOF
  id=fm-stub-held-row
  fb=$(fm_fakebin "$home")
  log="$home/tasks-axi-calls"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "@LOG@"
case "${1:-}" in
  --version) printf '%s\n' '0.2.5' ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--archive-body'
      exit 0
    fi
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads update received a markdown file override' >&2
        exit 1
        ;;
    esac
    stub_prev=
    stub_path=
    for stub_arg in "$@"; do
      if [ "$stub_prev" = --body-file ]; then stub_path=$stub_arg; fi
      stub_prev=$stub_arg
    done
    [ -n "$stub_path" ] && cp -- "$stub_path" "@HOME@/last-body"
    printf 'ok: update %s\n' "${2:-}"
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    case " $* " in
      *" --help "*) printf '%s\n' '  --kind captain' ; exit 0 ;;
      *" --file "*)
        printf '%s\n' 'error: beads hold received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: hold %s\n' "${2:-}"
    ;;
  done)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads done received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: done %s\n' "${2:-}"
    ;;
  show)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads show received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "@ID@"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain'
    if [ -f "@HOME@/last-body" ]; then
      printf '%s' '  body: '
      perl -MJSON::PP -e 'local $/; print encode_json(<STDIN>)' < "@HOME@/last-body"
      printf '\n'
    else
      printf '%s\n' '  body: ""'
    fi
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s|@HOME@|$home|g; s|@ID@|$id|g; s|@LOG@|$log|g" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"

  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "captain must decide" >/dev/null \
    || fail "holding on a beads-configured home failed without a markdown backlog"
  assert_grep "hold $id" "$log" \
    "the captain-hold mutation never reached the configured backend"

  decision="$home/captain-decision.txt"
  printf 'Ship the gold-only plan.\n' > "$decision"
  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$decision" >/dev/null \
    || fail "answering on a beads-configured home failed without a markdown backlog"
  assert_grep "update $id --body-file" "$log" \
    "the captain answer never reached the configured backend"
  assert_grep "done $id" "$log" \
    "the captain answer close never reached the configured backend"
  assert_no_grep " --file " "$log" \
    "a captain-hold mutation passed a markdown file override to a beads home"
  pass "captain-hold mutations address the beads backend without a markdown override"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out snap
  home=$(make_home release-work)
  cat > "$home/widget-body.txt" <<'EOF'
The widget plan body. Literal escape: \n. Unicode: café.
Captain hold set: 2025-01-02T03:04:05Z
EOF
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body-file "$home/widget-body.txt" >/dev/null \
    || fail "could not create the held work item"
  FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Not urgent; ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Not urgent; ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  assert_contains "$show" "Captain hold set: 2025-01-02T03:04:05Z" \
    "hold stamping deleted matching user content outside the leading stamp"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed after re-hold"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-widget")
    | .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "a new hold lifecycle reused historical timestamp or answer text: $snap"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Not urgent; ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# The hold-set stamp must be durable before the captain hold becomes visible.
# A wrapper observes the real tasks-axi hold boundary, and a forced stamp-write
# failure proves the command never publishes the hold without its timestamp.
test_hold_stamp_precedes_hold_visibility() {
  local home show
  home=$(make_home hold-stamp-order)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-old-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)
- [ ] sample-stamp-failure - Existing task whose stamp fails (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = update ] && [ "${2:-}" = sample-stamp-failure ]; then
  exit 92
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = sample-old-call ]; then
  show=$("$REAL_TASKS_AXI" show "$2" --full) || exit 93
  printf '%s\n' "$show" | grep -F 'Captain hold set: 2026-07-14T12:00:00Z' >/dev/null || exit 94
  : > "$FM_HOME/hold-observed-after-stamp"
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-old-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "hold was published before its hold-set stamp"
  assert_present "$home/hold-observed-after-stamp" \
    "the tasks-axi hold boundary was not observed"
  show=$(tasks_in "$home" show sample-old-call --full)
  assert_contains "$show" "hold_kind: captain" "the stamped task was not captain-held"
  assert_contains "$show" "Captain hold set: 2026-07-14T12:00:00Z" \
    "the visible captain hold lost its timestamp"

  if FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-stamp-failure \
    --reason "captain route choice pending" > "$home/stamp-failure.out" 2> "$home/stamp-failure.err"; then
    fail "hold succeeded after its timestamp update failed"
  fi
  show=$(tasks_in "$home" show sample-stamp-failure --full)
  assert_contains "$show" "held: no" "a failed timestamp update still published the hold"
  assert_contains "$show" 'hold_kind: "-"' "a failed timestamp update retained captain-hold provenance"
  pass "captain holds become visible only after their hold-set timestamp is durable"
}

test_interrupted_answer_preserves_hold_age() {
  local home snap show
  home=$(make_home interrupted-answer-age)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-interrupted-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-interrupted-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "could not hold the interrupted-answer fixture"
  printf 'Not urgent in the historical answer.\n' > "$home/interrupted-answer.txt"
  mkdir -p "$home/at-close"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/close-failed-once" ]; then
  cp "$FM_HOME/data/backlog.md" "$FM_HOME/at-close/backlog.md" || exit 93
  : > "$FM_HOME/close-failed-once"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/normalize-failed-once" ]; then
  state=$("$REAL_TASKS_AXI" show "$2" --full | sed -n 's/^  state: //p' | head -1)
  if [ "$state" = done ]; then
    : > "$FM_HOME/normalize-failed-once"
    exit 94
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/answer.out" 2> "$home/answer.err"; then
    fail "the forced answer close failure reported success"
  fi
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/at-close" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at interrupted close boundary"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-interrupted-call")
    | .captain_actionable == true
      and .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "an interrupted answer lost the fresh hold age basis: $snap"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/normalize.out" 2> "$home/normalize.err"; then
    fail "the forced post-close normalization failure reported success"
  fi
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" "state: done" "the normalization failure undid the successful close"
  run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" >/dev/null \
    || fail "the closed answer could not normalize on retry"
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" 'body: "Resolution recorded by fm-captain-hold.' \
    "the matching done retry did not restore resolution-first body ordering"
  pass "an interrupted answer preserves its hold age until close retry"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-existing-call - Decide an existing sample task (repo: sample) (kind: captain) (since 2026-06-01)
- [ ] sample-near-marker - Decide a deferred sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  Captain hold set: 2026-07-14T12:00:00Z
  abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij DEFERRED
- [ ] sample-late-marker - Decide a documented sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  This deliberately long decision context fills the bounded display excerpt without changing the durable classification contract. Additional synthetic context keeps extending the body beyond that display boundary while remaining ordinary task prose. More synthetic context places the presentation marker after the excerpt cutoff. DEFERRED

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not hold the existing task"
  FM_CAPTAIN_HOLD_NOW=2026-07-20T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not repeat the existing task hold"
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and $existing.since == "2026-06-01" and $existing.hold_set == "2026-07-14T12:00:00Z"
      and $existing.hold_age_days == 0 and $existing.hold_bucket == "live"
      and ([.backlog.records[] | select(.id == "sample-near-marker")][0].hold_bucket == "live")
      and ([.backlog.records[] | select(.id == "sample-late-marker")][0].hold_bucket == "live")
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate, hold-set age, or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-existing-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == true
      and $existing.hold_age_days == 18 and $existing.hold_bucket == "aged"
  ' >/dev/null || fail "a due deferral did not resurface or a stamped hold did not age from its hold date"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.
test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    "$channel" "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    "$channel" "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    "$channel" "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    "$channel" "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    "$channel" "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"sample-headline-call\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"question\": \"sample-gated-work\",\n  \"answer\": \"go\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"question\": \"sample-nonexistent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

# Retention happens after destructive cleanup, through the same pending record
# an ordinary close stages first. A cleanup that fails part-way leaves that
# record available to an answer and the next session replay.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap json
  home=$(make_home teardown-held-interrupted)
  id=sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  printf 'Accept the completed report.\n' > "$home/interrupted-answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/interrupted-answer.txt" >/dev/null \
    || fail "the interrupted captain call could not be answered"
  assert_present "$home/state/$id.backlog-close" \
    "the answer discarded the pending cleanup record before replay"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answer erased the interrupted row"
  assert_contains "$show" "state: done" "the answer did not close the captain call"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the completion carried by the pending cleanup record"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay the interrupted retention: $bootstrap"
  assert_contains "$bootstrap" "the captain had already answered its call" \
    "session start did not reconcile the answered interrupted call"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "session start erased the captain call"
  assert_contains "$show" "state: done" "session start reopened the answered captain call"
  assert_contains "$show" "hold_kind: captain" "session start dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "session start did not preserve the pending completed report"
  json=$(run_bearings "$home") || fail "Bearings failed after interrupted cleanup replay"
  printf '%s' "$json" | jq -e --arg id "$id" \
    --arg report "data/$id/report.md" '
      .landed | any(.id == $id and .artifact == $report)
    ' >/dev/null || fail "Bearings omitted the report preserved across interrupted cleanup: $json"
  pass "an answered interrupted cleanup preserves its completed delivery through replay"
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not FM_HOME/data.
test_teardown_retains_captain_calls_in_a_relocated_backlog() {
  local home data id show json
  home=$(make_home teardown-relocated-hold)
  data="$home/ team; records"
  mv "$home/data" "$data"
  id=sample-relocated-hold
  mkdir -p "$home/data" "$data/$id"
  # A backlog at the default location stays empty, so a wrongly addressed read
  # would find no row at all.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated sample hold" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated captain-hold fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated hold\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose the relocated sample outcome" >/dev/null \
    || fail "could not hold the relocated work item"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the relocated captain hold"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the relocated captain hold failed: $(cat "$home/teardown.err")"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated captain-held row disappeared"
  assert_not_contains "$show" "state: done" "cleanup closed the relocated captain call"
  assert_contains "$show" "state: queued" "cleanup left the relocated captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the relocated captain hold"
  assert_contains "$show" "Deliverable of the finished work: report  team; records/$id/report.md" \
    "cleanup did not record the deliverable in the relocated backlog"
  assert_absent "$home/state/$id.meta" "cleanup left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "cleanup left its pending record behind"
  assert_no_grep "$id" "$home/data/backlog.md" "cleanup wrote to the empty default-location backlog"
  printf 'Accept the relocated report.\n' > "$home/relocated-answer.txt"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" \
    --decision-file "$home/relocated-answer.txt" >/dev/null \
    || fail "could not answer the relocated captain hold"
  json=$(FM_DATA_OVERRIDE="$data" run_bearings "$home") \
    || fail "Bearings failed for the relocated completed report"
  printf '%s' "$json" | jq -e --arg id "$id" \
    --arg report " team; records/$id/report.md" '
      .landed | any(.id == $id and .artifact == $report)
    ' >/dev/null || fail "Bearings omitted the relocated completed report: $json"
  pass "cleanup retains and Bearings lands captain calls in relocated data"
}

test_merge_approval_releases_before_zero_done_retention() {
  local home id archive repo wt pr show
  home=$(make_home zero-done-retention)
  id=sample-zero-retention-merge
  archive="$home/data/done-archive.md"
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  pr="https://github.com/sample/sample/pull/19"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' \
    'path = "data/backlog.md"' 'archive = "data/done-archive.md"' \
    'done_keep = 0' > "$home/.tasks.toml"
  fm_git_worktree "$repo" "$wt" fm/zero-retention-merge
  tasks_in "$home" add "$id" "Ship zero-retention merge $pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the zero-retention fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the zero-retention merge"
  printf 'Merge the approved change.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved zero-retention merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge row disappeared"
  assert_contains "$show" "state: in_flight" \
    "merge approval completed the zero-retention row before landing"
  assert_contains "$show" "Resolution mode: released" \
    "merge approval did not record the existing release mode"
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "zero-retention cleanup failed: $(cat "$home/teardown.err")"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "zero-retention cleanup kept the completed row in the active backlog"
  assert_grep "$id" "$archive" "zero-retention cleanup did not archive the completed row"
  assert_grep "Deliverable of the finished work: PR $pr" "$archive" \
    "zero-retention archival lost completion provenance"
  assert_grep "Merge the approved change." "$archive" \
    "zero-retention archival lost the recorded merge approval"
  assert_absent "$home/state/$id.meta" "zero-retention cleanup retained task metadata"
  assert_absent "$home/state/$id.backlog-close" \
    "zero-retention cleanup retained its pending close record"
  pass "merge approval releases before zero-retention cleanup records completion"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}

test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_hold_stamp_precedes_hold_visibility
test_interrupted_answer_preserves_hold_age
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_secondmate_home_publishes_holds_and_answers
test_bound_channel_answers_close_at_answer_time
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_teardown_never_closes_a_captain_held_task
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_teardown_retains_captain_calls_in_a_relocated_backlog
test_merge_approval_releases_before_zero_done_retention
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
test_verify_resolves_a_hold_migrated_to_beads_notes
test_verify_resolves_a_hold_migrated_under_the_configured_prefix
test_marker_noted_row_wins_over_a_prefix_namesake
test_complete_accepts_a_migrated_inventory_on_beads
test_verify_names_the_unresolvable_legacy_id_once
test_verify_resolves_a_pre_collapse_key_through_its_derived_marker
test_captain_hold_mutations_address_the_beads_backend
