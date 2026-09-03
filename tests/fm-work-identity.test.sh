#!/usr/bin/env bash
# Public-interface coverage for exact project/plan/work-unit intake and fleet projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK_IDENTITY="$ROOT/bin/fm-work-identity.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
FLEET_VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-identity)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

make_max_manifest() {  # <home> <task> <path>
  local home=$1 task=$2 path=$3
  FM_HOME="$home" "$WORK_IDENTITY" template "$task" \
    | jq '
      def padded($prefix): $prefix + ("x" * (240 - ($prefix | length)));
      def display: "🚢" * 160;
      .initiative = {namespace:"work-aligner",kind:"project",id:padded("initiative-"),label:display}
      | .plan_id = {namespace:"work-aligner",kind:"plan",id:padded("plan-"),label:display}
      | .stage = {namespace:"work-aligner",kind:"stage",id:padded("stage-"),label:display}
      | .work_units = [range(0;20) as $n
          | {namespace:"work-aligner",kind:"work-unit",id:padded("unit-\($n)-"),label:display}]
      | .sources = [range(0;20) as $n
          | {namespace:"dtm",kind:"issue",id:padded("source-\($n)-"),label:display}]
    ' > "$path"
}

make_manifest() {  # <home> <task> <path> [multi]
  local home=$1 task=$2 path=$3 multi=${4:-single}
  FM_HOME="$home" "$WORK_IDENTITY" template "$task" \
    | jq --argjson multi "$([ "$multi" = multi ] && printf true || printf false)" '
      .initiative = {namespace:"work-aligner",kind:"project",id:"wa-project-42",label:"Roadmap Accuracy"}
      | .plan_id = {namespace:"work-aligner",kind:"plan",id:"wa-plan-2026-q3",label:"Identity Plan"}
      | .stage = {namespace:"work-aligner",kind:"stage",id:"implementation",label:"Implementation"}
      | .work_units = (
          if $multi then [
            {namespace:"work-aligner",kind:"work-unit",id:"wu-exact-intake",label:"Exact Intake"},
            {namespace:"work-aligner",kind:"work-unit",id:"wu-fleet-projection",label:"Fleet Projection"}
          ] else [
            {namespace:"work-aligner",kind:"work-unit",id:"wu-exact-intake",label:"Exact Intake"}
          ] end)
      | .sources = [
          {namespace:"dtm",kind:"project",id:"dtm-project-17",label:"Delivery Tracking"},
          {namespace:"dtm",kind:"issue",id:"DTM-431",label:"Worker Relation Gap"},
          {namespace:"data-team-ticket",kind:"ticket",id:"DTT-88",label:"Dashboard Tracking"}
        ]' > "$path"
}

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_TEST_TREEHOUSE_SUCCESS_MARKER:-}" ] \
       && { [ ! -f "$FM_TEST_TREEHOUSE_SUCCESS_MARKER" ] \
         || [ "${FM_TEST_TREEHOUSE_INFLIGHT:-0}" = 1 ]; }; then
      printf '%s\n' "${FM_TEST_PROJECT_PATH:?}"
    else
      printf '%s\n' "${FM_FAKE_WORKTREE:-${FM_HOME:?}}"
    fi
    exit 0
    ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-codex}"; exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    if [ -n "${FM_TEST_ENDPOINT_LABEL:-}" ] \
       && [ -s "${FM_TEST_ENDPOINT_CREATE_LOG:-/dev/null}" ]; then
      printf '%s\n' "$FM_TEST_ENDPOINT_LABEL"
    fi
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf 'worker ready\n> \n'; exit 0 ;;
  new-window)
    if [ -n "${FM_TEST_MUTATE_BRIEF:-}" ]; then
      printf 'MUTATED_SOURCE_BRIEF\n' > "$FM_TEST_MUTATE_BRIEF"
    fi
    [ -z "${FM_TEST_ENDPOINT_CREATE_LOG:-}" ] || printf 'created\n' >> "$FM_TEST_ENDPOINT_CREATE_LOG"
    if [ -n "${FM_TEST_ENDPOINT_KILL_MARKER:-}" ] \
       && [ ! -f "$FM_TEST_ENDPOINT_KILL_MARKER" ]; then
      : > "$FM_TEST_ENDPOINT_KILL_MARKER"
      kill -KILL "$PPID"
      sleep 1
      exit 137
    fi
    printf '%%99\n'
    exit 0
    ;;
  send-keys)
    literal=0
    literal_text=
    capture_literal=0
    for arg in "$@"; do
      if [ "$capture_literal" -eq 1 ]; then
        literal_text=$arg
        capture_literal=0
      fi
      if [ "$arg" = -l ]; then
        literal=1
        capture_literal=1
      fi
    done
    if [ "$literal" -eq 0 ] && [ -n "${FM_TEST_TREEHOUSE_SUCCESS_MARKER:-}" ] \
       && printf '%s\n' "$*" | grep -Fq 'treehouse get'; then
      [ -z "${FM_TEST_TREEHOUSE_SEND_LOG:-}" ] || printf 'sent\n' >> "$FM_TEST_TREEHOUSE_SEND_LOG"
      if [ -n "${FM_TEST_TREEHOUSE_FAIL_MARKER:-}" ] \
         && [ ! -f "$FM_TEST_TREEHOUSE_FAIL_MARKER" ]; then
        : > "$FM_TEST_TREEHOUSE_FAIL_MARKER"
        exit 1
      fi
      command_arg=${@: -2:1}
      bash -c "$command_arg" || exit 1
      : > "$FM_TEST_TREEHOUSE_SUCCESS_MARKER"
      if [ -n "${FM_TEST_TREEHOUSE_KILL_MARKER:-}" ] \
         && [ ! -f "$FM_TEST_TREEHOUSE_KILL_MARKER" ]; then
        : > "$FM_TEST_TREEHOUSE_KILL_MARKER"
        kill -KILL "$PPID"
        sleep 1
        exit 137
      fi
    fi
    if [ "$literal" -eq 1 ] && [ -n "${FM_TEST_MUTATE_LAUNCH_BRIEF:-}" ]; then
      printf 'MUTATED_LAUNCH_BRIEF\n' > "$FM_TEST_MUTATE_LAUNCH_BRIEF.replacement"
      mv -f "$FM_TEST_MUTATE_LAUNCH_BRIEF.replacement" "$FM_TEST_MUTATE_LAUNCH_BRIEF"
    fi
    if [ "$literal" -eq 1 ] && [ -n "${FM_TEST_LAUNCH_COMMAND:-}" ]; then
      printf '%s\n' "$literal_text" > "$FM_TEST_LAUNCH_COMMAND"
    fi
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_DELIVERED_BRIEF:-}" ] || printf '%s' "${!#}" > "$FM_TEST_DELIVERED_BRIEF"
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status) printf '%s\n' "${FM_TEST_TREEHOUSE_STATUS_JSON:-[]}"; exit 0 ;;
  get)
    [ -z "${FM_TEST_TREEHOUSE_GET_LOG:-}" ] || printf 'get\n' >> "$FM_TEST_TREEHOUSE_GET_LOG"
    if [ -n "${FM_TEST_TREEHOUSE_NO_RESOURCE_MARKER:-}" ] \
       && [ ! -e "$FM_TEST_TREEHOUSE_NO_RESOURCE_MARKER" ]; then
      : > "$FM_TEST_TREEHOUSE_NO_RESOURCE_MARKER"
      exit 17
    fi
    case "$*" in
      *--lease*) printf '%s\n' "${FM_FAKE_WORKTREE:-${FM_TEST_ZELLIJ_WT:-}}" ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/codex" "$fakebin/treehouse" "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

record_and_brief() {  # <home> <task> <manifest> [mode]
  local home=$1 task=$2 manifest=$3 mode=${4:-no-mistakes}
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode "$mode" >/dev/null
}

write_bound_meta() {  # <home> <task> <worktree> [window]
  local home=$1 task=$2 worktree=$3 window=${4:-firstmate:fm-$2} projection hash
  projection=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task") || fail "could not verify linked fixture $task"
  hash=$(printf '%s' "$projection" | jq -r '.sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=$window" \
    "endpoint_task_id=$task" \
    "worktree=$worktree" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" \
    "work_identity_status=linked" \
    "work_identity_sha256=$hash"
}

# Record, generated instructions, spawn metadata, canonical fleet snapshot, and
# Bearings all carry one exact multi-work-unit relation without multiplying the worker.
test_intake_through_fleet_projection() {
  local home task manifest project wt fakebin out first second projection before_state after_state
  home=$(make_home end-to-end)
  task=exact-worker
  manifest="$home/manifest.json"
  project="$home/project"
  wt="$home/worker-copy"
  make_manifest "$home" "$task" "$manifest" multi
  before_state=$(find "$home/state" -mindepth 1 -print | sort)
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest") \
    || fail "valid multi-work-unit intake was refused: $out"
  after_state=$(find "$home/state" -mindepth 1 -print | sort)
  [ "$before_state" = "$after_state" ] || fail "recording identity changed runtime task state"
  first=$(sha256_file_for_test "$home/data/$task/work-identity.json")
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest") \
    || fail "idempotent record was refused: $out"
  second=$(sha256_file_for_test "$home/data/$task/work-identity.json")
  [ "$first" = "$second" ] || fail "idempotent record changed canonical bytes"
  assert_contains "$out" "(unchanged)" "idempotent intake did not report convergence"

  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "linked brief did not scaffold"
  assert_grep "Work identity contract: fm-work-identity.v1 sha256=$first" "$home/data/$task/brief.md" \
    "generated instructions did not bind the canonical digest"
  assert_grep '"id":"wu-exact-intake"' "$home/data/$task/brief.md" \
    "generated instructions lost the first exact work unit"
  assert_grep '"id":"wu-fleet-projection"' "$home/data/$task/brief.md" \
    "generated instructions lost the second exact work unit"

  fm_git_worktree "$project" "$wt" exact-worker-copy
  fakebin=$(make_fakebin "$home/fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" PATH="$fakebin:$PATH" \
    "$SPAWN" "$task" "$project" --mode no-mistakes --yolo off 2>&1)
  assert_contains "$out" "spawned $task" "linked task did not spawn"
  assert_grep 'work_identity_schema=fm-work-identity.v1' "$home/state/$task.meta" \
    "spawn metadata lost the identity schema"
  assert_grep 'work_identity_status=linked' "$home/state/$task.meta" \
    "spawn metadata lost linked status"
  assert_grep "work_identity_sha256=$first" "$home/state/$task.meta" \
    "spawn metadata lost the exact sidecar digest"

  projection=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --json)
  printf '%s' "$projection" | jq -e '
    ([.tasks[] | select(.id == "exact-worker")] | length) == 1
      and (.tasks[] | select(.id == "exact-worker")
        | .work_identity.status == "linked"
          and .work_identity.initiative == {namespace:"work-aligner",kind:"project",id:"wa-project-42",label:"Roadmap Accuracy"}
          and .work_identity.plan_id.id == "wa-plan-2026-q3"
          and .work_identity.stage.id == "implementation"
          and (.work_identity.work_units | map(.id)) == ["wu-exact-intake","wu-fleet-projection"]
          and (.work_identity.sources | map([.namespace,.kind,.id])) == [
            ["dtm","project","dtm-project-17"],
            ["dtm","issue","DTM-431"],
            ["data-team-ticket","ticket","DTT-88"]])
  ' >/dev/null || fail "canonical snapshot changed or multiplied exact task identity: $projection"
  first=$(printf '%s' "$projection" | jq -S -c .)
  second=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --json | jq -S -c .)
  [ "$first" = "$second" ] || fail "same exact state produced unstable canonical snapshot output"

  projection=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z \
    "$BEARINGS" --json)
  printf '%s' "$projection" | jq -e '
    ([.in_flight[] | select(.id == "exact-worker")] | length) == 1
      and (.in_flight[] | select(.id == "exact-worker")
        | .work_identity == "linked"
          and (.initiative | contains("work-aligner:project:wa-project-42 [Roadmap Accuracy]"))
          and (.plan | contains("work-aligner:plan:wa-plan-2026-q3 [Identity Plan]"))
          and (.stage | contains("work-aligner:stage:implementation [Implementation]"))
          and (.work_units | contains("work-aligner:work-unit:wu-exact-intake [Exact Intake]"))
          and (.work_units | contains("work-aligner:work-unit:wu-fleet-projection [Fleet Projection]"))
          and (.sources | contains("dtm:issue:DTM-431 [Worker Relation Gap]")))
  ' >/dev/null || fail "Bearings lost exact ids paired with display labels: $projection"
  pass "exact multi-work-unit intake survives instructions, metadata, snapshot, and Bearings once per worker"
}

test_spawn_delivers_validated_brief_snapshot() {
  local home task manifest project wt fakebin out delivered snapshot delivered_body delivered_hash
  home=$(make_home immutable-delivery)
  task=immutable-delivery-worker
  manifest="$home/manifest.json"
  project="$home/project"
  wt="$home/worker-copy"
  delivered="$home/delivered.txt"
  make_manifest "$home" "$task" "$manifest" multi
  jq '.work_units[0].label = "Opaque & __WORKTREE__ __TURNEND__ __PIEXT__ __PITURNEND__ __PIWATCH__"' \
    "$manifest" > "$home/opaque-manifest.json"
  mv "$home/opaque-manifest.json" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  fm_git_worktree "$project" "$wt" immutable-delivery-copy
  fakebin=$(make_fakebin "$home/fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_TEST_MUTATE_BRIEF="$home/data/$task/brief.md" \
    FM_TEST_MUTATE_LAUNCH_BRIEF="$home/state/$task.launch-brief.md" \
    FM_TEST_LAUNCH_COMMAND="$home/launch.command" FM_TEST_DELIVERED_BRIEF="$delivered" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off --harness codex 2>&1)
  assert_contains "$out" "spawned $task" "spawn with a concurrently replaced source brief failed"
  assert_present "$home/launch.command" "spawn emitted no worker launch command"
  (cd "$wt" && FM_TEST_DELIVERED_BRIEF="$delivered" PATH="$fakebin:$PATH" \
    /bin/bash -c "$(cat "$home/launch.command")") \
    || fail "emitted worker launch command could not consume its brief snapshot"
  assert_grep 'MUTATED_SOURCE_BRIEF' "$home/data/$task/brief.md" \
    "delivery fixture did not replace the source brief after validation"
  assert_present "$delivered" "fake worker received no launch instructions"
  assert_grep 'Work identity contract: fm-work-identity.v1 sha256=' "$delivered" \
    "worker did not receive the identity contract from the validated snapshot"
  assert_grep '"id":"wu-fleet-projection"' "$delivered" \
    "worker received changed instructions instead of the validated identity payload"
  assert_no_grep 'MUTATED_SOURCE_BRIEF' "$delivered" \
    "worker reread the replaced source brief after validation"
  snapshot="$home/state/$task.launch-brief.md"
  assert_grep "launch_brief=$snapshot" "$home/state/$task.meta" \
    "task metadata did not bind the launch snapshot"
  assert_grep 'MUTATED_LAUNCH_BRIEF' "$snapshot" \
    "delivery fixture did not replace the validated launch snapshot"
  delivered_body="$home/delivered-body.md"
  "$ROOT/bin/fm-operational-input.sh" body < "$delivered" > "$delivered_body" \
    || fail "worker delivery was not a typed launch-brief input"
  delivered_hash=$(sha256_file_for_test "$delivered_body")
  assert_grep "launch_brief_sha256=$delivered_hash" "$home/state/$task.meta" \
    "task metadata did not bind the exact delivered instruction bytes"
  pass "spawn delivers validated bytes despite source and snapshot replacement"
}

sha256_file_for_test() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

test_sidecar_validation_hashes_captured_bytes() {
  local home task manifest sidecar replacement fakebin real_shasum projection observed observed_hash
  home=$(make_home captured-sidecar)
  task=captured-sidecar-worker
  manifest="$home/manifest.json"
  sidecar="$home/data/$task/work-identity.json"
  replacement="$home/replacement.json"
  make_manifest "$home" "$task" "$manifest"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  jq -S -c '.work_units[0].id = "wu-other-intake"' "$sidecar" > "$replacement"
  [ "$(LC_ALL=C wc -c < "$sidecar" | tr -d ' ')" = \
    "$(LC_ALL=C wc -c < "$replacement" | tr -d ' ')" ] \
    || fail "same-size sidecar rewrite fixture changed record size"
  fakebin=$(fm_fakebin "$home/hash-fake")
  real_shasum=$(command -v shasum || true)
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
set -eu
last=${!#}
if [ "$last" = "$FM_TEST_SIDECAR" ]; then
  /bin/cp "$FM_TEST_REPLACEMENT" "$FM_TEST_SIDECAR"
fi
if [ -n "$FM_TEST_REAL_SHASUM" ]; then
  exec "$FM_TEST_REAL_SHASUM" "$@"
fi
exec sha256sum "$last"
SH
  chmod +x "$fakebin/shasum"
  projection=$(PATH="$fakebin:$PATH" FM_TEST_SIDECAR="$sidecar" \
    FM_TEST_REPLACEMENT="$replacement" FM_TEST_REAL_SHASUM="$real_shasum" \
    FM_HOME="$home" "$WORK_IDENTITY" verify "$task") \
    || fail "captured sidecar validation failed"
  observed="$home/observed.json"
  printf '%s' "$projection" | jq -S -c \
    '{schema,binding,initiative,plan_id,stage,work_units,sources}' > "$observed"
  observed_hash=$(sha256_file_for_test "$observed")
  [ "$(printf '%s' "$projection" | jq -r '.sha256')" = "$observed_hash" ] \
    || fail "sidecar projection combined canonical bytes with another version digest"
  pass "sidecar validation hashes one captured byte sequence"
}

test_manifest_capture_rejects_same_size_rewrite() {
  local home task manifest replacement fakebin real_jq out rc=0
  home=$(make_home manifest-capture)
  task='manifest-capture-worker'
  manifest="$home/manifest.json"
  replacement="$home/replacement.json"
  make_manifest "$home" "$task" "$manifest"
  jq '.work_units[0].id = "wu-other-intake"' "$manifest" > "$replacement"
  [ "$(LC_ALL=C wc -c < "$manifest" | tr -d ' ')" = \
    "$(LC_ALL=C wc -c < "$replacement" | tr -d ' ')" ] \
    || fail "same-size manifest rewrite fixture changed input size"
  fakebin=$(fm_fakebin "$home/jq-fake")
  real_jq=$(command -v jq)
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -eu
if [ ! -e "$FM_TEST_REWRITE_MARKER" ]; then
  /bin/cp "$FM_TEST_REPLACEMENT" "$FM_TEST_MANIFEST"
  : > "$FM_TEST_REWRITE_MARKER"
fi
exec "$FM_TEST_REAL_JQ" "$@"
SH
  chmod +x "$fakebin/jq"
  out=$(PATH="$fakebin:$PATH" FM_TEST_MANIFEST="$manifest" \
    FM_TEST_REPLACEMENT="$replacement" FM_TEST_REWRITE_MARKER="$home/rewritten" \
    FM_TEST_REAL_JQ="$real_jq" FM_HOME="$home" \
    "$WORK_IDENTITY" record "$task" --file "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "record accepted a manifest rewritten during canonicalization"
  assert_contains "$out" "changed before publication" \
    "manifest rewrite refusal did not identify the unstable input"
  assert_absent "$home/data/$task/work-identity.json" \
    "manifest rewrite published a sidecar from unstable input"
  pass "manifest intake canonicalizes one capture and rejects source rewrites"
}

test_concurrent_idempotence_and_explicit_unlinked() {
  local home task manifest p1 p2 rc1 rc2 links out
  home=$(make_home idempotent)
  task=concurrent-worker
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" > "$home/record-1.out" 2>&1 &
  p1=$!
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" > "$home/record-2.out" 2>&1 &
  p2=$!
  wait "$p1"; rc1=$?
  wait "$p2"; rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] \
    || fail "concurrent byte-identical intake did not converge idempotently"
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f '%l' "$home/data/$task/work-identity.json")
  else
    links=$(stat -c '%h' "$home/data/$task/work-identity.json")
  fi
  [ "$links" = 1 ] || fail "concurrent intake left a hardlinked publication"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e '.status == "linked"' >/dev/null \
    || fail "concurrent intake did not leave one valid linked record"

  task=intentionally-unlinked
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null
  assert_grep 'Work identity contract: fm-work-identity.v1 unlinked' "$home/data/$task/brief.md" \
    "unlinked intake was not explicit in generated instructions"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task")
  printf '%s' "$out" | jq -e '
    .status == "unlinked" and .reason == "explicitly-unlinked"
      and .initiative == null and .plan_id == null and .work_units == [] and .sources == []
  ' >/dev/null || fail "intentional unlinked intake was not explicit: $out"
  pass "concurrent identical records converge and intentional unlinked intake stays explicit"
}

test_secondmate_unlinked_reservation_is_transactional() {
  local home task committed manifest out rc=0
  home=$(make_home secondmate-reservation)
  task=secondmate-reservation-abort
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"

  out=$(FM_HOME="$home" "$WORK_IDENTITY" unlinked-prepare "$task" \
    --reason persistent-secondmate --transaction secondmate-spawn:test) \
    || fail "could not prepare transactional secondmate reservation"
  printf '%s' "$out" | jq -e '.status == "unlinked" and .reason == "explicitly-unlinked"' >/dev/null \
    || fail "prepared secondmate reservation did not project explicitly unlinked"
  assert_present "$home/data/$task/work-identity-unlinked-reservation.json" \
    "prepared secondmate reservation was not durable"
  assert_absent "$home/data/$task/work-identity-unlinked-guard.json" \
    "pre-launch secondmate reservation was committed early"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "linked intake bypassed a prepared secondmate reservation"
  assert_contains "$out" "in-progress persistent secondmate reservation" \
    "prepared secondmate reservation refusal was not explicit"
  FM_HOME="$home" "$WORK_IDENTITY" unlinked-abort "$task" \
    --transaction secondmate-spawn:test >/dev/null \
    || fail "could not abort unapplied secondmate reservation"
  assert_absent "$home/data/$task/work-identity-unlinked-reservation.json" \
    "aborted secondmate reservation remained durable"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null \
    || fail "aborted secondmate reservation still blocked exact linked intake"

  committed=secondmate-reservation-commit
  FM_HOME="$home" "$WORK_IDENTITY" unlinked-prepare "$committed" \
    --reason persistent-secondmate --transaction secondmate-spawn:commit >/dev/null \
    || fail "could not prepare committed secondmate reservation"
  FM_HOME="$home" "$WORK_IDENTITY" unlinked-commit "$committed" \
    --transaction secondmate-spawn:commit >/dev/null \
    || fail "could not commit successful secondmate reservation"
  assert_absent "$home/data/$committed/work-identity-unlinked-reservation.json" \
    "committed secondmate reservation retained its prepared state"
  assert_present "$home/data/$committed/work-identity-unlinked-guard.json" \
    "successful secondmate reservation did not publish its explicit guard"
  pass "secondmate unlinked reservations prepare, abort, and commit transactionally"
}

test_no_clobber_publications_recover_after_interruption() {
  local home task manifest sidecar brief guard out links pin journal digest
  home=$(make_home publication-recovery)
  task=publication-recovery-linked
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null \
    || fail "could not record publication recovery fixture"
  sidecar="$home/data/$task/work-identity.json"
  ln "$sidecar" "$sidecar.publishing" || fail "could not simulate interrupted sidecar publication"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest") \
    || fail "record retry did not recover interrupted no-clobber publication"
  assert_contains "$out" "(unchanged)" \
    "sidecar publication recovery did not converge idempotently"
  assert_absent "$sidecar.publishing" "sidecar publication recovery retained its staging link"

  pin="$(dirname "$sidecar")/.work-identity.json.no-clobber-pin.recovery"
  journal="$(dirname "$sidecar")/.work-identity.json.no-clobber-journal"
  digest=$(sha256_file_for_test "$sidecar")
  ln "$sidecar" "$pin" || fail "could not simulate interrupted no-clobber pin retirement"
  printf 'v1\nwork-identity.json.publishing\n%s\n%s\n' \
    "${pin##*/}" "$digest" > "$journal"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" >/dev/null \
    || fail "ordinary preflight did not recover a retained no-clobber pin"
  assert_absent "$pin" "ordinary preflight retained a no-clobber pin"
  assert_absent "$journal" "ordinary preflight retained a no-clobber journal"

  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not publish brief recovery fixture"
  brief="$home/data/$task/brief.md"
  ln "$brief" "$brief.publishing" || fail "could not simulate interrupted brief publication"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" >/dev/null \
    || fail "verification did not recover interrupted brief publication"
  assert_absent "$brief.publishing" "brief publication recovery retained its staging link"

  task=publication-recovery-unlinked
  FM_HOME="$home" "$WORK_IDENTITY" reserve-unlinked "$task" \
    --reason persistent-secondmate >/dev/null \
    || fail "could not publish unlinked guard recovery fixture"
  guard="$home/data/$task/work-identity-unlinked-guard.json"
  ln "$guard" "$guard.publishing" || fail "could not simulate interrupted guard publication"
  FM_HOME="$home" "$WORK_IDENTITY" reserve-unlinked "$task" \
    --reason persistent-secondmate >/dev/null \
    || fail "reservation retry did not recover interrupted guard publication"
  assert_absent "$guard.publishing" "guard publication recovery retained its staging link"

  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f '%l' "$sidecar")
  else
    links=$(stat -c '%h' "$sidecar")
  fi
  [ "$links" = 1 ] || fail "recovered sidecar publication did not restore one link"
  pass "no-clobber identity publications recover interrupted staging links"
}

test_no_clobber_conflict_retires_owned_transaction() {
  local dir inode source staging target pin journal digest source_details source_state rc=0
  dir=$(make_home publication-conflict)
  inode=$(python3 - "$dir" <<'PY'
import os, sys
info = os.stat(sys.argv[1], follow_symlinks=False)
print(f"{info.st_dev}:{info.st_ino}")
PY
)
  source="$dir/source"
  staging=record.publishing
  target="$dir/record"
  pin="$dir/.record.no-clobber-pin.conflict"
  journal="$dir/.record.no-clobber-journal"
  printf 'candidate\n' > "$source"
  cp "$source" "$dir/$staging"
  ln "$dir/$staging" "$pin"
  source_details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-source "$source" 1024) \
    || fail "could not capture no-clobber source commitment"
  source_state=${source_details%%$'\t'*}
  digest=${source_details#*$'\t'}
  printf 'v1\n%s\n%s\n%s\n' "$staging" "${pin##*/}" "$digest" > "$journal"
  printf 'concurrent destination\n' > "$target"
  python3 "$ROOT/bin/fm-work-identity-fs.py" no-clobber \
    "$dir" "$inode" record "$source" "$staging" "$source_state" "$digest" \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "no-clobber conflict returned $rc instead of target-exists"
  [ "$(cat "$target")" = "concurrent destination" ] \
    || fail "no-clobber conflict changed the concurrent destination"
  assert_absent "$dir/$staging" "no-clobber conflict retained owned staging"
  assert_absent "$pin" "no-clobber conflict retained owned pin"
  assert_absent "$journal" "no-clobber conflict retained owned journal"

  printf 'v2\n%s\n%s\n%s\npublishing\n' \
    "$staging" "${pin##*/}" "$digest" > "$journal"
  rc=0
  python3 "$ROOT/bin/fm-work-identity-fs.py" no-clobber \
    "$dir" "$inode" record "$source" "$staging" "$source_state" "$digest" \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "completed conflict cleanup returned $rc instead of target-exists"
  assert_absent "$journal" "completed conflict cleanup retained its journal"
  [ "$(cat "$target")" = "concurrent destination" ] \
    || fail "completed conflict cleanup changed the concurrent destination"

  printf 'v2\n%s\n%s\n%s\nconflict\n' \
    "$staging" "${pin##*/}" "$digest" > "$journal"
  rc=0
  python3 "$ROOT/bin/fm-work-identity-fs.py" no-clobber \
    "$dir" "$inode" record "$source" "$staging" "$source_state" "$digest" \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "interrupted conflict cleanup returned $rc instead of target-exists"
  assert_absent "$journal" "interrupted conflict cleanup retained its journal"
  [ "$(cat "$target")" = "concurrent destination" ] \
    || fail "interrupted conflict cleanup changed the concurrent destination"
  pass "no-clobber conflicts retire their exact owned transaction"
}

test_no_clobber_journal_rejects_unrelated_staging() {
  local home task dir brief target pin journal digest out rc=0
  home=$(make_home publication-journal-binding)
  task=publication-journal-binding
  dir="$home/data/$task"
  mkdir -p "$dir"
  brief="$dir/brief.md"
  target="$dir/work-identity.json"
  pin="$dir/.work-identity.json.no-clobber-pin.forged"
  journal="$dir/.work-identity.json.no-clobber-journal"
  printf 'independent brief\n' > "$brief"
  ln "$brief" "$pin" || fail "could not create unrelated journal fixture"
  digest=$(sha256_file_for_test "$brief")
  printf 'v1\nbrief.md\n%s\n%s\n' "${pin##*/}" "$digest" > "$journal"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "forged no-clobber journal unexpectedly passed preflight"
  assert_contains "$out" "publication journal is malformed" \
    "forged no-clobber journal was not rejected at the filesystem owner"
  [ "$(cat "$brief")" = "independent brief" ] \
    || fail "forged no-clobber journal changed the unrelated brief"
  assert_absent "$target" "forged no-clobber journal published an identity sidecar"
  assert_present "$pin" "forged no-clobber journal removed an unrelated hardlink"
  pass "no-clobber journals cannot claim unrelated owned entries"
}

test_no_clobber_publication_does_not_follow_raced_target() {
  local home task manifest target staging sink fakebin real_python out rc=0
  home=$(make_home publication-target-race)
  task=publication-target-race
  manifest="$home/manifest.json"
  target="$home/data/$task/work-identity.json"
  staging="$target.publishing"
  sink="$home/publication-sink"
  real_python=$(command -v python3)
  fakebin=$(fm_fakebin "$home/publication-owner-fakes")
  make_manifest "$home" "$task" "$manifest"
  printf 'must remain unchanged\n' > "$sink"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${2:-}" = no-clobber ] && [ ! -e "$FM_TEST_PUBLICATION_RACED" ]; then
  ln -s "$FM_TEST_PUBLICATION_SINK" "${3}/${7}"
  : > "$FM_TEST_PUBLICATION_RACED"
fi
exec "$FM_TEST_REAL_PYTHON" "$@"
SH
  chmod +x "$fakebin/python3"
  out=$(PATH="$fakebin:$PATH" FM_TEST_PUBLICATION_SINK="$sink" \
    FM_TEST_PUBLICATION_RACED="$home/raced" FM_TEST_REAL_PYTHON="$real_python" \
    FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "identity publication followed a raced staging path"
  [ -L "$staging" ] || fail "publication race fixture did not replace the staging path"
  assert_absent "$target" "staging race partially published an authoritative identity"
  [ "$(cat "$sink")" = "must remain unchanged" ] \
    || fail "identity publication partially wrote through a raced staging symlink"
  assert_contains "$out" "cannot publish work identity record" \
    "identity publication did not report the raced staging refusal"
  pass "identity publication never follows raced staging paths"
}

test_owned_replace_refuses_changed_unsafe_destination() {
  local home parent inode source target sink details expected digest source_details source_state source_digest out rc=0
  home=$(make_home replace-destination-race)
  parent="$home/state"
  source="$home/replacement"
  target="$parent/authoritative"
  sink="$home/sink"
  printf 'replacement\n' > "$source"
  printf 'original\n' > "$target"
  printf 'unchanged\n' > "$sink"
  inode=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$parent")
  details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-replace \
    "$parent" "$inode" authoritative) \
    || fail "could not capture owned destination identity"
  expected=${details%%$'\t'*}
  digest=${details#*$'\t'}
  source_details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-source "$source" 1024) \
    || fail "could not capture replacement source commitment"
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  rm -f "$target"
  ln -s "$sink" "$target"
  out=$(python3 "$ROOT/bin/fm-work-identity-fs.py" replace \
    "$parent" "$inode" authoritative "$source" "$expected" "$digest" \
    "$source_state" "$source_digest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "changed symlink destination was replaced"
  [ "$(cat "$sink")" = unchanged ] || fail "replace wrote through a changed destination symlink"
  [ "$(cat "$source")" = replacement ] || fail "refused replace changed its publication source"
  assert_contains "$out" "destination entry is unsafe" \
    "replace refusal did not identify the changed unsafe destination"

  rm -f "$target"
  printf 'original\n' > "$target"
  expected=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe "$parent" "$inode" authoritative) \
    || fail "could not capture owned removal destination state"
  digest=$(sha256_file_for_test "$target")
  rm -f "$target"
  ln -s "$sink" "$target"
  rc=0
  out=$(python3 "$ROOT/bin/fm-work-identity-fs.py" remove \
    "$parent" "$inode" authoritative "$expected" "$digest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "changed symlink destination was removed"
  [ -L "$target" ] || fail "refused removal changed the raced destination"
  [ "$(cat "$sink")" = unchanged ] || fail "removal followed a changed destination symlink"
  assert_contains "$out" "destination entry is unsafe" \
    "remove refusal did not identify the changed unsafe destination"

  rm -f "$target"
  printf 'original\n' > "$target"
  expected=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe "$parent" "$inode" authoritative) \
    || fail "could not recapture owned removal destination state"
  digest=$(sha256_file_for_test "$target")
  rm -f "$target"
  printf 'concurrent replacement\n' > "$target"
  rc=0
  out=$(python3 "$ROOT/bin/fm-work-identity-fs.py" remove \
    "$parent" "$inode" authoritative "$expected" "$digest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "stale regular destination was removed"
  [ "$(cat "$target")" = "concurrent replacement" ] \
    || fail "refused removal changed the concurrent destination"
  assert_contains "$out" "changed before removal" \
    "remove refusal did not identify the stale destination"
  pass "owned replacement and removal refuse changed destinations"
}

test_owned_replace_refuses_a_changing_source() {
  local home parent inode source target details state digest source_details source_state source_digest hook out rc=0
  home=$(make_home owned-replace-source-race)
  parent="$home/state"
  source="$home/replacement"
  target="$parent/authoritative"
  hook="$home/python-hook"
  printf 'replacement\n' > "$source"
  printf 'original\n' > "$target"
  inode=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$parent")
  details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-replace \
    "$parent" "$inode" authoritative) || fail "could not capture replacement destination"
  state=${details%%$'\t'*}
  digest=${details#*$'\t'}
  source_details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-source "$source" 1024) \
    || fail "could not capture changing source commitment"
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  printf 'changed before open\n' > "$source"
  out=$(python3 "$ROOT/bin/fm-work-identity-fs.py" replace \
    "$parent" "$inode" authoritative "$source" "$state" "$digest" \
    "$source_state" "$source_digest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "owned replacement accepted a source changed before open"
  [ "$(cat "$target")" = original ] \
    || fail "pre-open source mutation partially replaced the authoritative destination"
  assert_contains "$out" "publication source changed before copying" \
    "owned replacement did not identify its pre-open source mutation"
  printf 'replacement\n' > "$source"
  source_details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-source "$source" 1024) \
    || fail "could not recapture changing source commitment"
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  rc=0
  mkdir -p "$hook"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

_source = os.environ["FM_TEST_CHANGE_SOURCE"]
_source_info = os.stat(_source, follow_symlinks=False)
_real_read = os.read
_changed = False


def raced_read(fd, count):
    global _changed
    info = os.fstat(fd)
    if not _changed and (info.st_dev, info.st_ino) == (_source_info.st_dev, _source_info.st_ino):
        _changed = True
        append_fd = os.open(_source, os.O_WRONLY | os.O_APPEND)
        try:
            os.write(append_fd, b"changed\n")
        finally:
            os.close(append_fd)
    return _real_read(fd, count)


os.read = raced_read
PY
  out=$(PYTHONPATH="$hook" FM_TEST_CHANGE_SOURCE="$source" \
    python3 "$ROOT/bin/fm-work-identity-fs.py" replace \
    "$parent" "$inode" authoritative "$source" "$state" "$digest" \
    "$source_state" "$source_digest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "owned replacement accepted a changing source"
  [ "$(cat "$target")" = original ] \
    || fail "changing source partially replaced the authoritative destination"
  assert_contains "$out" "publication source changed during copying" \
    "owned replacement did not identify its changing source"
  pass "owned replacement pins its source before and through copying"
}

test_no_clobber_refuses_a_preopen_source_mutation() {
  local home inode source target staging source_details source_state source_digest out rc=0
  home=$(make_home no-clobber-source-race)
  source="$home/source"
  target="$home/record"
  staging=record.publishing
  printf 'candidate\n' > "$source"
  inode=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$home")
  source_details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-source "$source" 1024) \
    || fail "could not capture no-clobber source commitment"
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  printf 'changed before publication\n' > "$source"
  out=$(python3 "$ROOT/bin/fm-work-identity-fs.py" no-clobber \
    "$home" "$inode" record "$source" "$staging" \
    "$source_state" "$source_digest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "no-clobber accepted a source changed before open"
  assert_absent "$target" "no-clobber published a source outside its caller commitment"
  assert_absent "$home/$staging" "no-clobber retained a candidate from a changed source"
  assert_contains "$out" "publication source changed before copying" \
    "no-clobber did not identify its pre-open source mutation"
  pass "no-clobber verifies its caller source commitment"
}

test_owned_removal_bounds_digest_after_concurrent_growth() {
  local home parent inode target details state digest hook out rc=0
  home=$(make_home owned-removal-growth)
  parent="$home/state"
  target="$parent/authoritative"
  hook="$home/python-hook"
  printf 'original\n' > "$target"
  inode=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$parent")
  details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-digest \
    "$parent" "$inode" authoritative) || fail "could not capture owned removal commitment"
  state=${details%%$'\t'*}
  digest=${details#*$'\t'}
  mkdir -p "$hook"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

_target = os.environ["FM_TEST_GROW_ON_READ"]
_target_info = os.stat(_target, follow_symlinks=False)
_real_read = os.read
_grew = False


def raced_read(fd, count):
    global _grew
    info = os.fstat(fd)
    if not _grew and (info.st_dev, info.st_ino) == (_target_info.st_dev, _target_info.st_ino):
        _grew = True
        append_fd = os.open(_target, os.O_WRONLY | os.O_APPEND)
        try:
            os.write(append_fd, b"growth\n")
        finally:
            os.close(append_fd)
    return _real_read(fd, count)


os.read = raced_read
PY
  out=$(PYTHONPATH="$hook" FM_TEST_GROW_ON_READ="$target" \
    python3 "$ROOT/bin/fm-work-identity-fs.py" remove \
    "$parent" "$inode" authoritative "$state" "$digest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "owned removal accepted a file that grew during digest"
  assert_contains "$out" "destination size does not match expected size" \
    "owned removal did not enforce its committed size during digest"
  [ "$(cat "$target")" = $'original\ngrowth' ] \
    || fail "bounded removal changed the concurrently grown destination"
  pass "owned removal bounds digest reads after concurrent growth"
}

test_owned_snapshot_binds_validated_entry() {
  local home parent inode target details state digest output out rc=0
  home=$(make_home owned-snapshot)
  parent="$home/state"
  target="$parent/authoritative"
  output="$home/snapshot"
  printf 'prepared payload\n' > "$target"
  inode=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$parent")
  details=$(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-digest \
    "$parent" "$inode" authoritative) || fail "could not capture owned snapshot state"
  state=${details%%$'\t'*}
  digest=${details#*$'\t'}
  python3 "$ROOT/bin/fm-work-identity-fs.py" snapshot \
    "$parent" "$inode" authoritative "$state" "$digest" > "$output" \
    || fail "could not snapshot the exact owned entry"
  [ "$(cat "$output")" = "prepared payload" ] || fail "owned snapshot changed the prepared payload"
  printf 'concurrent payload\n' > "$target"
  rc=0
  out=$(python3 "$ROOT/bin/fm-work-identity-fs.py" snapshot \
    "$parent" "$inode" authoritative "$state" "$digest" 2>&1 > "$output") || rc=$?
  [ "$rc" -ne 0 ] || fail "owned snapshot accepted a changed entry"
  [ ! -s "$output" ] || fail "owned snapshot emitted changed content before refusal"
  assert_contains "$out" "changed before snapshot" \
    "owned snapshot refusal did not identify the changed entry"
  pass "owned snapshots bind the validated directory entry and digest"
}

test_identity_lock_refuses_replaced_storage_parent() {
  local home sink fakebin real_python out rc=0
  home=$(make_home identity-lock-parent-race)
  sink="$home/outside"
  mkdir -p "$sink"
  fakebin=$(fm_fakebin "$home/fakebin")
  real_python=$(command -v python3)
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${2:-}" = lock-try ] && [ ! -e "$FM_TEST_LOCK_RACED" ]; then
  mv "$3" "$3.original"
  ln -s "$FM_TEST_LOCK_SINK" "$3"
  : > "$FM_TEST_LOCK_RACED"
fi
exec "$FM_TEST_REAL_PYTHON" "$@"
SH
  chmod +x "$fakebin/python3"
  out=$(PATH="$fakebin:$PATH" FM_TEST_REAL_PYTHON="$real_python" \
    FM_TEST_LOCK_RACED="$home/raced" FM_TEST_LOCK_SINK="$sink" \
    FM_HOME="$home" "$WORK_IDENTITY" verify lock-parent-race 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "identity lock followed a replaced storage parent"
  [ -e "$home/raced" ] || fail "identity lock race fixture did not replace the storage parent"
  [ -z "$(find "$sink" -mindepth 1 -print -quit)" ] \
    || fail "identity lock created an artifact through the replacement parent"
  assert_contains "$out" "lock path is unsafe or was replaced" \
    "identity lock refusal did not identify its replaced parent"
  pass "identity locks refuse replaced storage parents without publication"
}

test_identity_lock_refuses_unsafe_lock_entry_without_waiting() {
  local home task lock_key lock output pid rc=0 i
  home=$(make_home identity-lock-unsafe-entry)
  task=unsafe-lock-entry
  if command -v shasum >/dev/null 2>&1; then
    lock_key=$(printf '%s' "$task" | shasum -a 256 | awk '{print $1}')
  else
    lock_key=$(printf '%s' "$task" | sha256sum | awk '{print $1}')
  fi
  lock="$home/state/.work-identity-task-$lock_key.lock"
  mkdir -p "$home/unsafe-lock-target"
  ln -s "$home/unsafe-lock-target" "$lock"
  output="$home/unsafe-lock-output"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" > "$output" 2>&1 &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "unsafe identity lock entry caused an unbounded wait"
  fi
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe identity lock entry was accepted"
  assert_contains "$(cat "$output")" "lock path is unsafe or was replaced" \
    "unsafe identity lock entry was not refused explicitly"
  [ -z "$(find "$home/unsafe-lock-target" -mindepth 1 -print -quit)" ] \
    || fail "unsafe identity lock entry received partial publication"
  pass "unsafe identity lock entries refuse without waiting"
}

test_identity_lock_reclaims_reused_pid_owner() {
  local home parent inode lock owner token
  home=$(make_home identity-lock-pid-reuse)
  parent="$home/state"
  lock=.work-identity-reused-pid.lock
  mkdir "$parent/$lock"
  printf '%s\tstale-owner\told-process-start\n' "${BASHPID:-$$}" > "$parent/$lock/owner"
  inode=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$parent")
  token="replacement-${RANDOM}"
  python3 "$ROOT/bin/fm-work-identity-fs.py" lock-try "$parent" "$inode" "$lock" \
    "${BASHPID:-$$}" "$token" 0 \
    || fail "reused lock PID could not be reclaimed by process-start identity"
  owner=$(cat "$parent/$lock/owner")
  [ "$(printf '%s' "$owner" | cut -f2)" = "$token" ] \
    || fail "reused lock PID retained the stale owner token"
  [ "$(printf '%s' "$owner" | awk -F '\t' '{print NF}')" -eq 3 ] \
    || fail "replacement lock owner did not persist process-start identity"
  python3 "$ROOT/bin/fm-work-identity-fs.py" lock-release "$parent" "$inode" "$lock" \
    "${BASHPID:-$$}" "$token" \
    || fail "replacement lock owner could not release its lock"
  pass "identity locks distinguish reused PIDs by process-start identity"
}

test_projection_serializes_identity_ownership() {
  local home task lock lock_name lock_key state_inode entered release holder projection wait_count
  home=$(make_home projection-lock)
  task=serialized-projection
  if command -v shasum >/dev/null 2>&1; then
    lock_key=$(printf '%s' "$task" | shasum -a 256 | awk '{print $1}')
  else
    lock_key=$(printf '%s' "$task" | sha256sum | awk '{print $1}')
  fi
  lock="$home/state/.work-identity-task-$lock_key.lock"
  lock_name=${lock##*/}
  state_inode=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$home/state")
  entered="$home/lock.entered"
  release="$home/lock.release"
  /bin/bash -c '
    set -eu
    owner=${BASHPID:-$$}
    python3 "$1" lock-try "$2" "$3" "$4" "$owner" projection-owner 2
    : > "$5"
    while [ ! -e "$6" ]; do sleep 0.02; done
    python3 "$1" lock-release "$2" "$3" "$4" "$owner" projection-owner
  ' _ "$ROOT/bin/fm-work-identity-fs.py" "$home/state" "$state_inode" \
    "$lock_name" "$entered" "$release" &
  holder=$!
  wait_count=0
  while [ ! -e "$entered" ]; do
    kill -0 "$holder" 2>/dev/null || fail "identity lock holder exited before acquisition"
    wait_count=$((wait_count + 1))
    [ "$wait_count" -le 250 ] || fail "identity lock holder never acquired the contract lock"
    sleep 0.02
  done
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" > "$home/projection.json" 2>&1 &
  projection=$!
  sleep 0.2
  if ! kill -0 "$projection" 2>/dev/null; then
    touch "$release"
    wait "$holder" 2>/dev/null || true
    fail "work identity projection bypassed an in-flight ownership mutation"
  fi
  touch "$release"
  wait "$holder" || fail "identity lock holder failed to release"
  wait "$projection" || fail "serialized work identity projection failed"
  jq -e '.status == "unlinked" and .reason == "legacy-no-record"' \
    "$home/projection.json" >/dev/null \
    || fail "serialized projection did not return the coherent unlinked state"
  pass "identity projection serializes guard and sidecar state"
}

test_handoff_receipts_require_owning_task() {
  local source target target_real task_a task_b transfer out rc=0
  source=$(make_home receipt-source)
  target=$(make_home receipt-target)
  target_real=$(cd "$target" && pwd -P)
  task_a=receipt-a
  task_b=receipt-b
  transfer=$(FM_HOME="$source" "$WORK_IDENTITY" handoff-prepare "$task_b" \
    --to-home "$target_real" --to-home-id main) \
    || fail "could not prepare task-bound handoff receipt fixture"
  printf '%s\n' "$transfer" | FM_HOME="$target" "$WORK_IDENTITY" \
    handoff-stage "$task_b" --file - >/dev/null \
    || fail "could not stage task-bound handoff receipt fixture"
  printf '%s\n' "$transfer" | FM_HOME="$target" "$WORK_IDENTITY" \
    handoff-commit "$task_b" --file - >/dev/null \
    || fail "could not commit task-bound handoff receipt fixture"
  mkdir -p "$target/data/$task_a"
  cp "$target/data/$task_b/work-identity-handoff-target.json" \
    "$target/data/$task_a/work-identity-handoff-target.json"
  out=$(FM_HOME="$target" "$WORK_IDENTITY" verify "$task_a" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "copied receipt from another task was accepted"
  assert_contains "$out" "handoff transfer task binding is mismatched" \
    "copied receipt refusal did not identify the task mismatch"
  pass "handoff receipts remain bound to their owning task"
}

test_dispatch_transaction_excludes_backlog_handoff() {
  local home mate task launch transaction binding hash out rc meta
  home=$(make_home dispatch-transaction)
  mate="$TMP_ROOT/dispatch-transaction-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf 'dispatch-target\n' > "$mate/.fm-secondmate-home"
  task=dispatch-race-worker
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold dispatch transaction fixture"
  launch="$home/state/$task.launch-brief.md"
  transaction=dispatch-race-1
  binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$transaction") || fail "could not prepare work identity dispatch"
  rc=0
  out=$(FM_HOME="$home" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$mate" --to-home-id secondmate:dispatch-target 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "backlog handoff entered an in-progress dispatch transaction"
  assert_contains "$out" "in-progress work identity dispatch" \
    "handoff refusal did not identify the prepared dispatch"

  hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
    "harness=codex" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "work_identity_schema=fm-work-identity.v1" \
    "work_identity_status=unlinked"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
    --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
    || fail "could not commit work identity dispatch"
  rc=0
  out=$(FM_HOME="$home" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$mate" --to-home-id secondmate:dispatch-target 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "backlog handoff accepted a dispatched source worker"
  assert_contains "$out" "dispatch metadata" \
    "committed dispatch handoff refusal did not identify live source metadata"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e \
    '.status == "unlinked" and .reason == "explicitly-unlinked"' >/dev/null \
    || fail "committed dispatch did not remain authoritatively publishable"
  meta="$home/state/$task.meta"
  cp "$meta" "$meta.valid"
  awk -F= '$1 == "work_identity_dispatch_transaction" { print "work_identity_dispatch_transaction=other-transaction"; next } { print }' \
    "$meta.valid" > "$meta"
  rc=0
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "completed dispatch accepted a stale metadata transaction receipt"
  assert_contains "$out" "dispatch transaction is stale or mismatched" \
    "completed dispatch did not identify its stale metadata receipt"
  cp "$meta.valid" "$meta"
  printf 'work_identity_dispatch_transaction=%s\n' "$transaction" >> "$meta"
  rc=0
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "completed dispatch accepted duplicate metadata transaction receipts"
  assert_contains "$out" "duplicate work identity dispatch transactions" \
    "completed dispatch did not identify duplicate metadata receipts"
  mv "$meta.valid" "$meta"
  cp "$home/data/$task/work-identity-dispatch.json" "$home/dispatch.valid"
  rm "$home/data/$task/work-identity-dispatch.json"
  rc=0
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "metadata dispatch transaction published without its owner receipt"
  assert_contains "$out" "has no exact owner receipt" \
    "missing dispatch receipt refusal did not identify the orphan metadata transaction"
  mv "$home/dispatch.valid" "$home/data/$task/work-identity-dispatch.json"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run "$task" -- true \
    || fail "completed dispatch receipt could not authorize lifecycle cleanup"
  assert_absent "$home/data/$task/work-identity-dispatch.json" \
    "completed dispatch receipt remained after lifecycle cleanup"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e \
    '.status == "unlinked"' >/dev/null \
    || fail "retiring completed dispatch history changed the task identity projection"
  pass "dispatch prepare and committed metadata exclude backlog ownership handoff"
}

test_dispatch_retire_run_authorizes_task_set() {
  local home task launch transaction binding hash
  local -a cleanup_paths=()
  home=$(make_home dispatch-retire-set)
  for task in dispatch-retire-set-a dispatch-retire-set-b; do
    FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
      || fail "could not scaffold $task dispatch retirement fixture"
    launch="$home/state/$task.launch-brief.md"
    transaction="retire-$task"
    binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
      --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
      --transaction "$transaction") || fail "could not prepare $task dispatch"
    hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
    fm_write_meta "$home/state/$task.meta" \
      "window=firstmate:fm-$task" "endpoint_task_id=$task" \
      "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
      "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
      "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
      "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
    FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
      --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
      || fail "could not commit $task dispatch"
    cleanup_paths+=("$home/state/$task.meta" "$launch")
  done
  if FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run \
    dispatch-retire-set-a dispatch-retire-set-b -- false; then
    fail "failed task-set teardown unexpectedly committed retirement"
  fi
  for task in dispatch-retire-set-a dispatch-retire-set-b; do
    assert_present "$home/data/$task/work-identity-dispatch.json" \
      "$task dispatch receipt was not restored after failed task-set teardown"
    assert_present "$home/state/$task.meta" \
      "$task metadata was not restored after failed task-set teardown"
    assert_present "$home/state/$task.launch-brief.md" \
      "$task launch instructions were not restored after failed task-set teardown"
  done
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run \
    dispatch-retire-set-a dispatch-retire-set-b -- true \
    || fail "one owner could not retire a complete task set"
  for task in dispatch-retire-set-a dispatch-retire-set-b; do
    assert_absent "$home/data/$task/work-identity-dispatch.json" \
      "$task dispatch receipt remained after task-set retirement"
  done
  pass "dispatch retirement authorizes complete task sets without nested locks"
}

# Nested shell code intentionally expands only in the invoked shell.
# shellcheck disable=SC2016
test_dispatch_retire_run_refuses_invalid_set_without_quarantine() {
  local home task launch transaction binding hash marker out rc=0
  local -a cleanup_paths=()
  home=$(make_home dispatch-retire-invalid-set)
  marker="$home/command-ran"
  for task in dispatch-retire-valid dispatch-retire-invalid; do
    FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
      || fail "could not scaffold $task invalid-set retirement fixture"
    launch="$home/state/$task.launch-brief.md"
    transaction="retire-$task"
    binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
      --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
      --transaction "$transaction") || fail "could not prepare $task dispatch"
    hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
    fm_write_meta "$home/state/$task.meta" \
      "window=firstmate:fm-$task" "endpoint_task_id=$task" \
      "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
      "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
      "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
      "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
    FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
      --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
      || fail "could not commit $task dispatch"
    cleanup_paths+=("$home/state/$task.meta" "$launch")
  done
  rm -- "$home/data/dispatch-retire-invalid/work-identity-dispatch.json"
  ln -s "$home/outside-receipt" \
    "$home/data/dispatch-retire-invalid/work-identity-dispatch.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run \
    dispatch-retire-valid dispatch-retire-invalid -- \
    sh -c 'marker=$1; shift; touch "$marker"; rm -- "$@"' sh \
      "$marker" "${cleanup_paths[@]}" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid dispatch set was authorized"
  assert_absent "$marker" "invalid dispatch set ran its destructive command"
  assert_present "$home/data/dispatch-retire-valid/work-identity-dispatch.json" \
    "invalid dispatch set moved an earlier valid receipt"
  assert_absent "$home/data/dispatch-retire-valid/.work-identity-dispatch.json.teardown-quarantine" \
    "invalid dispatch set retained an earlier valid quarantine"
  assert_absent "$home/data/dispatch-retire-valid/.work-identity-dispatch.json.teardown-journal" \
    "invalid dispatch set retained an earlier valid teardown journal"
  assert_contains "$out" "unsafe" \
    "invalid dispatch set refusal did not identify its unsafe receipt"
  pass "dispatch retirement validates a complete set before quarantine"
}

# Nested shell code intentionally expands only in the invoked shell.
# shellcheck disable=SC2016
test_dispatch_retire_run_accepts_whole_home_removal() {
  local home task launch transaction binding hash marker rc=0
  home=$(make_home dispatch-retire-whole-home)
  task=dispatch-retire-whole-home
  marker="$TMP_ROOT/whole-home-command-ran"
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold whole-home dispatch retirement fixture"
  launch="$home/state/$task.launch-brief.md"
  transaction=retire-whole-home
  binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$transaction") || fail "could not prepare whole-home dispatch"
  hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
    --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
    || fail "could not commit whole-home dispatch"
  set +e
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run "$task" --whole-home -- \
    sh -c 'kill -KILL "$PPID"; sleep 1'
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "interrupted whole-home retirement unexpectedly succeeded"
  assert_absent "$home/data/$task/work-identity-dispatch.json" \
    "interrupted whole-home retirement left its receipt at the mutable live path"
  assert_present "$home/data/$task/.work-identity-dispatch.json.teardown-quarantine" \
    "interrupted whole-home retirement lost its exact quarantined receipt"
  assert_present "$home/data/$task/.work-identity-dispatch.json.teardown-journal" \
    "interrupted whole-home retirement lost its recovery journal"
  assert_present "$home/state/.$task.meta.teardown-quarantine" \
    "interrupted whole-home retirement lost its metadata quarantine"
  assert_present "$home/state/.$task.launch-brief.md.teardown-quarantine" \
    "interrupted whole-home retirement lost its launch quarantine"
  rm -- "$home/data/$task/.work-identity-dispatch.json.teardown-quarantine"
  rc=0
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run "$task" --whole-home -- \
    sh -c 'touch "$1"' sh "$marker" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "journal-only retirement bypassed exact receipt proof"
  assert_absent "$marker" "journal-only retirement ran its destructive command"
  assert_present "$home/data/$task/.work-identity-dispatch.json.teardown-journal" \
    "journal-only retirement discarded its only recovery evidence"
  pass "dispatch retirement refuses journal-only state without finalization proof"
}

# Nested shell code intentionally expands only in the invoked shell.
# shellcheck disable=SC2016
test_dispatch_retire_run_recovers_completed_command() {
  local home task launch transaction binding hash owner owner_id journal marker command rc=0
  local quarantine quarantine_name retired remove_journal quarantine_state quarantine_digest
  home=$(make_home dispatch-retire-completed-command)
  task=dispatch-retire-completed-command
  marker="$home/command-runs"
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold completed-command retirement fixture"
  launch="$home/state/$task.launch-brief.md"
  transaction=retire-completed-command
  binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$transaction") || fail "could not prepare completed-command dispatch"
  hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
    --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
    || fail "could not commit completed-command dispatch"
  owner="$home/data/$task"
  journal="$owner/.work-identity-dispatch.json.teardown-journal"
  owner_id=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$owner")
  command='token=$(sed -n "4p" "$3"); python3 "$4" teardown-command-complete "$5" "$6" work-identity-dispatch.json "$token"; [ -e "$1" ] && [ -e "$2" ] || exit 8; printf "run\n" >> "$7"; kill -KILL "$PPID"'
  set +e
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run "$task" -- \
    sh -c "$command" sh "$home/state/.$task.meta.teardown-quarantine" \
      "$home/state/.$task.launch-brief.md.teardown-quarantine" "$journal" \
      "$ROOT/bin/fm-work-identity-fs.py" "$owner" "$owner_id" "$marker"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed-command interruption unexpectedly returned success"
  python3 - "$journal" <<'PY' || fail "could not record interrupted teardown finalization phase"
import os
import sys
with open(sys.argv[1], "r+b", buffering=0) as stream:
    stream.seek(3)
    stream.write(b"F")
    os.fsync(stream.fileno())
PY
  quarantine="$home/state/.$task.meta.teardown-quarantine"
  quarantine_name=${quarantine##*/}
  IFS=$'\t' read -r quarantine_state quarantine_digest \
    < <(python3 "$ROOT/bin/fm-work-identity-fs.py" describe-digest \
      "$home/state" "$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$home/state")" \
      "$quarantine_name") \
    || fail "could not inspect completed teardown metadata quarantine"
  retired=".$quarantine_name.remove-retired.0123456789abcdef0123456789abcdef"
  remove_journal="$home/state/.$quarantine_name.remove-journal"
  mv -- "$quarantine" "$home/state/$retired"
  printf 'v1\n%s\n%s\t%s\n' "$retired" "$quarantine_state" "$quarantine_digest" \
    > "$remove_journal"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run "$task" -- \
    sh -c "$command" sh "$home/state/.$task.meta.teardown-quarantine" \
      "$home/state/.$task.launch-brief.md.teardown-quarantine" "$journal" \
      "$ROOT/bin/fm-work-identity-fs.py" "$owner" "$owner_id" "$marker" \
    || fail "completed teardown command was not recovered"
  [ "$(wc -l < "$marker" | tr -d ' ')" -eq 1 ] \
    || fail "completed teardown command ran more than once"
  assert_absent "$owner/work-identity-dispatch.json" \
    "completed teardown recovery retained the dispatch receipt"
  assert_absent "$journal" "completed teardown recovery retained its journal"
  assert_absent "$home/state/$retired" \
    "completed teardown recovery retained a hidden metadata record"
  assert_absent "$remove_journal" \
    "completed teardown recovery retained a metadata removal journal"
  pass "dispatch retirement finalizes a durably completed command once"
}

# Nested shell code intentionally expands only in the invoked shell.
# shellcheck disable=SC2016
test_dispatch_retire_run_refuses_changed_record_without_partial_retirement() {
  local home task launch transaction binding hash marker out rc=0
  home=$(make_home dispatch-retire-record-change)
  task=dispatch-retire-record-change
  marker="$home/command-ran"
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold changed-record retirement fixture"
  launch="$home/state/$task.launch-brief.md"
  transaction=retire-record-change
  binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$transaction") || fail "could not prepare changed-record dispatch"
  hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
    --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
    || fail "could not commit changed-record dispatch"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run "$task" -- \
    sh -c 'cp "$1" "$1.changed"; chmod u+w "$1.changed"; printf "changed\n" >> "$1.changed"; mv "$1.changed" "$1"; touch "$2"' \
      sh "$launch" "$marker" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "changed launch record was retired"
  assert_present "$marker" "changed-record retirement did not run its wrapped command"
  assert_absent "$home/state/$task.meta" \
    "changed launch record escaped the authorized metadata quarantine"
  assert_present "$home/state/.$task.meta.teardown-quarantine" \
    "changed launch record caused partial metadata finalization"
  assert_present "$launch" "changed launch record was removed"
  assert_present "$home/state/.$task.launch-brief.md.teardown-quarantine" \
    "changed launch record caused partial launch finalization"
  assert_contains "$out" "changed before retirement" \
    "changed record refusal did not identify the retirement conflict"
  pass "dispatch retirement validates all final records before retiring any"
}

# Nested shell code intentionally expands only in the invoked shell.
# shellcheck disable=SC2016
test_dispatch_retire_run_preserves_failed_siblings() {
  local home task launch transaction binding hash owner owner_id journal command rc=0
  home=$(make_home dispatch-retire-partial-set)
  for task in dispatch-retire-partial-a dispatch-retire-partial-b; do
    FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
      || fail "could not scaffold $task partial retirement fixture"
    launch="$home/state/$task.launch-brief.md"
    transaction="retire-$task"
    binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
      --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
      --transaction "$transaction") || fail "could not prepare $task dispatch"
    hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
    fm_write_meta "$home/state/$task.meta" \
      "window=firstmate:fm-$task" "endpoint_task_id=$task" \
      "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
      "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
      "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
      "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
    FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
      --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
      || fail "could not commit $task dispatch"
  done
  owner="$home/data/dispatch-retire-partial-a"
  owner_id=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$owner")
  journal="$owner/.work-identity-dispatch.json.teardown-journal"
  command='token=$(sed -n "4p" "$1"); python3 "$2" teardown-command-complete "$3" "$4" work-identity-dispatch.json "$token"; exit 9'
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run \
    dispatch-retire-partial-a dispatch-retire-partial-b -- \
    sh -c "$command" sh "$journal" "$ROOT/bin/fm-work-identity-fs.py" \
      "$owner" "$owner_id" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 9 ] || fail "partial retirement returned $rc instead of the wrapped failure"
  assert_absent "$home/data/dispatch-retire-partial-a/work-identity-dispatch.json" \
    "completed child dispatch receipt was not finalized"
  assert_absent "$home/state/dispatch-retire-partial-a.meta" \
    "completed child metadata was not finalized"
  assert_absent "$home/state/dispatch-retire-partial-a.launch-brief.md" \
    "completed child launch instructions were not finalized"
  assert_present "$home/data/dispatch-retire-partial-b/work-identity-dispatch.json" \
    "failed sibling dispatch receipt was finalized"
  assert_present "$home/state/dispatch-retire-partial-b.meta" \
    "failed sibling metadata was finalized"
  assert_present "$home/state/dispatch-retire-partial-b.launch-brief.md" \
    "failed sibling launch instructions were finalized"
  pass "partial dispatch retirement finalizes only completed children"
}

# Nested shell code intentionally expands only in the invoked shell.
# shellcheck disable=SC2016
test_dispatch_retire_run_rejects_duplicate_tasks() {
  local home marker out rc=0
  home=$(make_home dispatch-retire-duplicate)
  marker="$home/duplicate-command-ran"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-retire-run \
    duplicate-retirement duplicate-retirement -- sh -c 'touch "$1"' sh "$marker" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate dispatch retirement tasks were accepted"
  assert_absent "$marker" "duplicate dispatch retirement tasks ran their command"
  assert_contains "$out" "duplicate dispatch retirement task id" \
    "duplicate dispatch retirement refusal was not explicit"
  pass "dispatch retirement rejects duplicate task IDs before mutation"
}

test_spawn_recovers_exact_created_endpoint() {
  local home task project wt fakebin manifest original_origin out rc=0 creates
  home=$(make_home endpoint-recovery)
  task=endpoint-recovery-worker
  project="$home/project"
  wt="$home/worker-copy"
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  fm_git_worktree "$project" "$wt" endpoint-recovery-copy
  original_origin=$(git -C "$wt" remote get-url origin)
  git -C "$wt" remote set-url origin "$home/unavailable-origin.git"
  fakebin=$(make_fakebin "$home/endpoint-fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=bash \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "endpoint recovery fixture unexpectedly completed its first spawn"
  jq -e '.schema == "fm-spawn-endpoint.v1" and .phase == "worktree-ready"
      and .endpoint.target == "firstmate:fm-endpoint-recovery-worker"
      and .worktree == $worktree' --arg worktree "$wt" \
    "$home/state/$task.spawn-endpoint.json" >/dev/null \
    || fail "failed spawn did not persist its exact endpoint creation receipt: $out"
  jq -e '.state == "prepared"' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "failed spawn did not preserve its matching identity dispatch"
  assert_absent "$home/state/$task.meta" \
    "endpoint recovery fixture published metadata before its injected failure"

  git -C "$wt" remote set-url origin "$original_origin"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=bash \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) \
    || fail "spawn could not adopt its exact interrupted endpoint: $out"
  creates=$(wc -l < "$home/endpoint-creates" | tr -d ' ')
  [ "$creates" = 1 ] || fail "endpoint recovery created a duplicate endpoint"
  assert_absent "$home/state/$task.spawn-endpoint.json" \
    "successful endpoint recovery did not retire its receipt"
  jq -e '.state == "completed"' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "endpoint recovery did not complete its original identity dispatch"
  pass "spawn retries adopt one exact endpoint creation receipt"
}

test_spawn_recovers_creation_intent_after_endpoint_side_effect() {
  local home task project wt fakebin manifest out rc=0 creates
  home=$(make_home endpoint-intent-recovery)
  task=endpoint-intent-recovery
  project="$home/project"
  wt="$home/worker-copy"
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  fm_git_worktree "$project" "$wt" endpoint-intent-copy
  fakebin=$(make_fakebin "$home/endpoint-intent-fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=bash \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    FM_TEST_ENDPOINT_KILL_MARKER="$home/endpoint-killed" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "endpoint intent fixture unexpectedly survived its injected kill"
  jq -e '.schema == "fm-spawn-endpoint.v1" and .phase == "endpoint-creating"
      and .endpoint.label == "fm-endpoint-intent-recovery"' \
    "$home/state/$task.spawn-endpoint.json" >/dev/null \
    || fail "endpoint creation side effect had no durable prior intent: $out"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=bash \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    FM_TEST_ENDPOINT_KILL_MARKER="$home/endpoint-killed" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) \
    || fail "spawn could not recover the endpoint created after durable intent: $out"
  creates=$(wc -l < "$home/endpoint-creates" | tr -d ' ')
  [ "$creates" = 1 ] || fail "creation-intent recovery created a duplicate endpoint"
  assert_absent "$home/state/$task.spawn-endpoint.json" \
    "successful creation-intent recovery retained its receipt"
  pass "spawn adopts an endpoint created after durable creation intent"
}

test_spawn_resumes_unsent_worktree_request() {
  local home task project wt fakebin manifest out rc=0 creates
  home=$(make_home worktree-request-recovery)
  task='worktree-request-recovery'
  project="$home/project"
  wt="$home/worker-copy"
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  fm_git_worktree "$project" "$wt" worktree-request-copy
  fakebin=$(make_fakebin "$home/worktree-request-fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=bash FM_TEST_PROJECT_PATH="$project" \
    FM_TEST_TREEHOUSE_FAIL_MARKER="$home/treehouse-failed" \
    FM_TEST_TREEHOUSE_SUCCESS_MARKER="$home/treehouse-succeeded" \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "worktree request fixture unexpectedly completed its failed send"
  jq -e '.phase == "worktree-requesting" and .worktree == null' \
    "$home/state/$task.spawn-endpoint.json" >/dev/null \
    || fail "failed worktree send did not retain its resumable request phase: $out"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=bash FM_TEST_PROJECT_PATH="$project" \
    FM_TEST_TREEHOUSE_FAIL_MARKER="$home/treehouse-failed" \
    FM_TEST_TREEHOUSE_SUCCESS_MARKER="$home/treehouse-succeeded" \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    FM_SPAWN_WORKTREE_POLLS=2 FM_SPAWN_WORKTREE_INTERVAL=0 \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) \
    || fail "spawn did not resend an interrupted worktree request: $out"
  assert_present "$home/treehouse-succeeded" "retry did not send the pending treehouse request"
  creates=$(wc -l < "$home/endpoint-creates" | tr -d ' ')
  [ "$creates" = 1 ] || fail "worktree request recovery created a duplicate endpoint"
  pass "spawn resumes a worktree request interrupted before send"
}

test_spawn_does_not_resend_inflight_worktree_request() {
  local home task project wt fakebin manifest out rc=0 sends
  home=$(make_home worktree-request-inflight)
  task='worktree-request-inflight'
  project="$home/project"
  wt="$home/worker-copy"
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  fm_git_worktree "$project" "$wt" worktree-inflight-copy
  fakebin=$(make_fakebin "$home/worktree-inflight-fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=bash FM_TEST_PROJECT_PATH="$project" \
    FM_TEST_TREEHOUSE_SUCCESS_MARKER="$home/treehouse-started" \
    FM_TEST_TREEHOUSE_SEND_LOG="$home/treehouse-sends" \
    FM_TEST_TREEHOUSE_KILL_MARKER="$home/treehouse-killed" \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "in-flight worktree request fixture unexpectedly survived its injected kill"
  jq -e '.phase == "worktree-requesting" and .worktree == null' \
    "$home/state/$task.spawn-endpoint.json" >/dev/null \
    || fail "interrupted worktree request did not retain its pre-send receipt: $out"

  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_FAKE_PANE_COMMAND=treehouse FM_TEST_PROJECT_PATH="$project" \
    FM_TEST_TREEHOUSE_SUCCESS_MARKER="$home/treehouse-started" \
    FM_TEST_TREEHOUSE_INFLIGHT=1 FM_TEST_TREEHOUSE_SEND_LOG="$home/treehouse-sends" \
    FM_TEST_TREEHOUSE_KILL_MARKER="$home/treehouse-killed" \
    FM_TEST_ENDPOINT_LABEL="fm-$task" FM_TEST_ENDPOINT_CREATE_LOG="$home/endpoint-creates" \
    FM_SPAWN_WORKTREE_POLLS=2 FM_SPAWN_WORKTREE_INTERVAL=0 \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "retry should keep waiting for the in-flight acquisition"
  sends=$(wc -l < "$home/treehouse-sends" | tr -d ' ')
  [ "$sends" = 1 ] || fail "retry sent $sends worktree requests while the first acquisition was still active: $out"
  pass "spawn retries do not duplicate in-flight worktree acquisition"
}

test_zellij_resumes_unsent_worktree_request_once() {
  local home task project wt fakebin manifest out rc=0 sends gets
  home=$(make_home zellij-worktree-request)
  task=zellij-worktree-request
  project="$home/project"
  wt="$home/worker-copy"
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  fm_git_worktree "$project" "$wt" zellij-worktree-copy
  fakebin=$(make_fakebin "$home/zellij-worktree-fakes")
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf 'zellij 0.44.0\n'; exit 0 ;;
  list-sessions) printf 'firstmate\n'; exit 0 ;;
esac
case "$*" in
  *' action list-tabs --json'*)
    if [ -f "$FM_TEST_ZELLIJ_TITLE" ]; then
      printf '[{"tab_id":3,"name":"%s","active":true}]\n' "$(cat "$FM_TEST_ZELLIJ_TITLE")"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *' action list-panes --json'*)
    if [ -f "$FM_TEST_ZELLIJ_TITLE" ]; then
      path=$FM_TEST_ZELLIJ_PROJECT
      [ ! -e "$FM_TEST_ZELLIJ_WORKTREE" ] || path=$FM_TEST_ZELLIJ_WT
      printf '[{"id":7,"tab_id":3,"is_plugin":false,"pane_cwd":"%s"}]\n' "$path"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *' action new-tab '*)
    previous=
    for arg in "$@"; do
      if [ "$previous" = --name ]; then printf '%s' "$arg" > "$FM_TEST_ZELLIJ_TITLE"; fi
      previous=$arg
    done
    printf '3\n'
    exit 0
    ;;
  *' action paste '*)
    text=${!#}
    printf '%s' "$text" > "$FM_TEST_ZELLIJ_INPUT"
    exit 0
    ;;
  *' action send-keys '*)
    if [ "${!#}" = Enter ] && [ -f "$FM_TEST_ZELLIJ_INPUT" ]; then
      text=$(cat "$FM_TEST_ZELLIJ_INPUT")
      case "$text" in
        "cd -- "*)
          printf 'sent\n' >> "$FM_TEST_ZELLIJ_SENDS"
          [ "${FM_TEST_ZELLIJ_DELAY_WORKTREE:-0}" = 1 ] || : > "$FM_TEST_ZELLIJ_WORKTREE"
          ;;
      esac
    fi
    exit 0
    ;;
  *' action dump-screen '*)
    [ -z "${FM_TEST_ZELLIJ_PROBES:-}" ] || printf 'probe\n' >> "$FM_TEST_ZELLIJ_PROBES"
    path=$FM_TEST_ZELLIJ_PROJECT
    [ ! -e "$FM_TEST_ZELLIJ_WORKTREE" ] || path=$FM_TEST_ZELLIJ_WT
    printf '__FM_ZELLIJ_CWD_BEGIN__\n%s\n__FM_ZELLIJ_CWD_END__\n' "$path"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
case "$last" in
  */result)
    if [ ! -e "$FM_TEST_RESULT_PUBLISH_KILLED" ]; then
      : > "$FM_TEST_RESULT_PUBLISH_KILLED"
      kill -KILL "$PPID"
      sleep 1
      exit 99
    fi
    ;;
esac
exec "$REAL_MV_FOR_TEST" "$@"
SH
  chmod +x "$fakebin/zellij" "$fakebin/mv"
  export FM_TEST_ZELLIJ_PROBES="$home/zellij-probes"

  out=$(REAL_MV_FOR_TEST="$(command -v mv)" \
    FM_TEST_RESULT_PUBLISH_KILLED="$home/result-publish-killed" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_TEST_ZELLIJ_TITLE="$home/zellij-title" \
    FM_TEST_ZELLIJ_INPUT="$home/zellij-input" \
    FM_TEST_ZELLIJ_SENDS="$home/zellij-sends" \
    FM_TEST_ZELLIJ_WORKTREE="$home/zellij-worktree" \
    FM_TEST_ZELLIJ_PROJECT="$project" FM_TEST_ZELLIJ_WT="$wt" \
    FM_TEST_ZELLIJ_DELAY_WORKTREE=1 FM_TEST_TREEHOUSE_GET_LOG="$home/treehouse-gets" \
    FM_SPAWN_WORKTREE_POLLS=100 FM_SPAWN_WORKTREE_INTERVAL=0.01 PATH="$fakebin:$PATH" \
    "$SPAWN" "$task" "$project" --mode no-mistakes --yolo off \
      --harness codex --backend zellij 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "delayed zellij worktree transition unexpectedly completed"
  assert_present "$home/result-publish-killed" \
    "treehouse result publication interruption was not exercised"
  jq -e --arg path "$wt" '.phase == "worktree-acquired" and .worktree == $path' \
    "$home/state/$task.spawn-endpoint.json" >/dev/null \
    || fail "zellij did not preserve its exact locally acquired worktree: $out"
  assert_absent "$home/zellij-probes" \
    "zellij worktree recovery injected an active cwd probe"

  rc=0
  out=$(REAL_MV_FOR_TEST="$(command -v mv)" \
    FM_TEST_RESULT_PUBLISH_KILLED="$home/result-publish-killed" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_TEST_ZELLIJ_TITLE="$home/zellij-title" \
    FM_TEST_ZELLIJ_INPUT="$home/zellij-input" \
    FM_TEST_ZELLIJ_SENDS="$home/zellij-sends" \
    FM_TEST_ZELLIJ_WORKTREE="$home/zellij-worktree" \
    FM_TEST_ZELLIJ_PROJECT="$project" FM_TEST_ZELLIJ_WT="$wt" \
    FM_TEST_TREEHOUSE_GET_LOG="$home/treehouse-gets" \
    FM_SPAWN_WORKTREE_POLLS=20 FM_SPAWN_WORKTREE_INTERVAL=0.01 PATH="$fakebin:$PATH" \
    "$SPAWN" "$task" "$project" --mode no-mistakes --yolo off \
      --harness codex --backend zellij 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "zellij did not resume its exact acquired worktree: $out"
  sends=$(wc -l < "$home/zellij-sends" | tr -d ' ')
  gets=$(wc -l < "$home/treehouse-gets" | tr -d ' ')
  [ "$sends" = 2 ] || fail "zellij worktree transition was not idempotently retried: $out"
  [ "$gets" = 1 ] || fail "zellij recovery allocated $gets worktrees instead of one: $out"
  assert_contains "$out" "spawned $task" \
    "zellij exact worktree recovery did not complete spawn"
  unset FM_TEST_ZELLIJ_PROBES
  pass "zellij recovers exact local worktree acquisition without duplicate allocation"
}

test_treehouse_request_reconciles_exact_failed_lease() {
  local home wt marker holder fakebin out status_json
  home=$(make_home treehouse-lease-reconcile)
  wt="$home/exact-lease"
  marker="$home/state/.treehouse-request"
  holder=firstmate-exact-lease
  fakebin=$(fm_fakebin "$home/treehouse-lease-fakes")
  mkdir -p "$wt"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) exit 23 ;;
  status) printf '%s\n' "$FM_TEST_TREEHOUSE_STATUS_JSON" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  status_json=$(jq -n -c --arg path "$wt" --arg holder "$holder" \
    '[{leased:true,path:$path,lease_holder:$holder,lease_id:"lease-exact-1"}]')
  out=$(cd "$home" && PATH="$fakebin:$PATH" \
    FM_TEST_TREEHOUSE_STATUS_JSON="$status_json" \
    bash -c '. "$1" "$2" "$3"; pwd -P' _ \
      "$ROOT/bin/fm-treehouse-worktree-request.sh" "$marker" "$holder") \
    || fail "failed treehouse command did not reconcile its exact lease"
  [ "$out" = "$wt" ] || fail "reconciled treehouse command did not enter its exact lease: $out"
  jq -e --arg path "$wt" --arg holder "$holder" '
    .status == "ok" and .path == $path and .lease_holder == $holder
      and .leases == [{path:$path,lease_id:"lease-exact-1"}]
  ' "$marker/result" >/dev/null \
    || fail "reconciled treehouse command lost its exact lease evidence"
  pass "failed treehouse commands reconcile one exact durable lease"
}

test_pre_metadata_dispatch_reuses_exact_prepared_receipt() {
  local home task launch first second transaction hash links
  home=$(make_home prepared-dispatch-retry)
  task=prepared-dispatch-retry
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold pre-metadata dispatch retry fixture"
  launch="$home/state/$task.launch-brief.md"
  first=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction retry-original) || fail "could not prepare original dispatch receipt"
  second=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction retry-new-process) || fail "exact pre-metadata dispatch retry was wedged"
  transaction=$(printf '%s' "$second" | jq -r '.transaction_id')
  [ "$transaction" = retry-original ] \
    || fail "pre-metadata retry replaced rather than resumed the exact owner receipt"
  [ "$(printf '%s' "$first" | jq -r '.instructions_sha256')" = \
    "$(printf '%s' "$second" | jq -r '.instructions_sha256')" ] \
    || fail "pre-metadata retry changed the prepared instruction binding"
  cmp -s "$home/data/$task/brief.md" "$launch" \
    || fail "dispatch owner did not publish the exact validated instructions"
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f '%l' "$launch")
  else
    links=$(stat -c '%h' "$launch")
  fi
  [ "$links" = 1 ] || fail "dispatch owner published hardlinked instructions"
  hash=$(printf '%s' "$second" | jq -r '.instructions_sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-commit "$task" \
    --brief "$launch" --meta "$home/state/$task.meta" --transaction "$transaction" \
    || fail "resumed pre-metadata dispatch receipt did not commit"
  pass "pre-metadata dispatch retries resume one exact owner receipt"
}

test_dispatch_publish_refuses_unstable_metadata_without_publication() {
  local home task launch transaction binding hash candidate replacement fakebin real_grep out rc=0
  home=$(make_home dispatch-publish-capture)
  task=dispatch-publish-capture
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold atomic dispatch publication fixture"
  launch="$home/state/$task.launch-brief.md"
  transaction=dispatch-publish-capture-1
  binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$transaction") || fail "could not prepare atomic dispatch publication"
  hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
  candidate="$home/state/.$task.meta.candidate"
  fm_write_meta "$candidate" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$hash" "work_identity_dispatch_transaction=$transaction" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked" \
    "operator_note=aaaaaaaa"
  replacement="$home/meta-replacement"
  awk -F= '$1 == "operator_note" { print "operator_note=bbbbbbbb"; next } { print }' \
    "$candidate" > "$replacement"
  fakebin=$(fm_fakebin "$home/dispatch-publish-fakes")
  real_grep=$(command -v grep)
  cat > "$fakebin/grep" <<'SH'
#!/usr/bin/env bash
set -eu
if [ ! -e "$FM_TEST_REWRITE_MARKER" ]; then
  /bin/cp "$FM_TEST_META_REPLACEMENT" "$FM_TEST_META_CANDIDATE"
  : > "$FM_TEST_REWRITE_MARKER"
fi
exec "$FM_TEST_REAL_GREP" "$@"
SH
  chmod +x "$fakebin/grep"
  out=$(PATH="$fakebin:$PATH" FM_TEST_META_CANDIDATE="$candidate" \
    FM_TEST_META_REPLACEMENT="$replacement" FM_TEST_REWRITE_MARKER="$home/meta-rewritten" \
    FM_TEST_REAL_GREP="$real_grep" FM_HOME="$home" "$WORK_IDENTITY" \
    dispatch-publish "$task" --brief "$launch" --meta "$candidate" \
      --transaction "$transaction" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "dispatch publication accepted metadata rewritten during validation"
  assert_contains "$out" "task metadata changed while it was validated" \
    "dispatch publication did not identify its unstable metadata candidate"
  assert_absent "$home/state/$task.meta" \
    "unstable metadata candidate was partially published"
  jq -e '.state == "prepared"' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "unstable metadata candidate advanced the dispatch receipt"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-publish "$task" \
    --brief "$launch" --meta "$candidate" --transaction "$transaction" \
    || fail "stable metadata candidate did not publish atomically"
  jq -e '.state == "completed"' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "atomic metadata publication did not complete its dispatch receipt"
  assert_present "$home/state/$task.meta" "atomic dispatch publication omitted metadata"
  pass "dispatch publication validates, publishes, and completes under one owner lock"
}

test_replacement_dispatch_recovers_prior_retirement() {
  local home task launch old_transaction old_binding old_hash old_candidate draft transaction binding hash candidate fakebin real_python out rc=0
  home=$(make_home replacement-prior-recovery)
  task='replacement-prior-recovery'
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold replacement dispatch recovery fixture"
  launch="$home/state/$task.launch-brief.md"
  old_transaction='replacement-prior-original'
  old_binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$old_transaction") || fail "could not prepare original dispatch"
  old_hash=$(printf '%s' "$old_binding" | jq -r '.instructions_sha256')
  old_candidate="$home/state/.$task.meta.original"
  fm_write_meta "$old_candidate" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$old_hash" "work_identity_dispatch_transaction=$old_transaction" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-publish "$task" \
    --brief "$launch" --meta "$old_candidate" --transaction "$old_transaction" \
    || fail "could not publish original dispatch"

  draft="$home/state/.$task.launch-replacement"
  cp "$launch" "$draft"
  chmod 600 "$draft"
  printf '\nContinue the replacement.\n' >> "$draft"
  transaction='replacement-prior-next'
  binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$draft" --instructions-path "$launch" --transaction "$transaction" \
    --meta "$home/state/$task.meta" --prior-brief "$launch") \
    || fail "could not prepare replacement dispatch"
  mv -f "$draft" "$launch"
  chmod 400 "$launch"
  hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
  candidate="$home/state/.$task.meta.replacement"
  awk -F= -v hash="$hash" -v transaction="$transaction" '
    $1 == "launch_brief_sha256" { print "launch_brief_sha256=" hash; next }
    $1 == "work_identity_dispatch_transaction" { print "work_identity_dispatch_transaction=" transaction; next }
    { print }
  ' "$home/state/$task.meta" > "$candidate"
  fakebin=$(fm_fakebin "$home/prior-retirement-fakes")
  real_python=$(command -v python3)
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = remove ] && [ "${3:-}/${5:-}" = "$FM_TEST_PRIOR" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_PYTHON" "$@"
SH
  chmod +x "$fakebin/python3"
  out=$(PATH="$fakebin:$PATH" FM_TEST_PRIOR="$home/data/$task/work-identity-dispatch-prior.md" \
    FM_TEST_REAL_PYTHON="$real_python" FM_HOME="$home" "$WORK_IDENTITY" dispatch-publish "$task" \
    --brief "$launch" --meta "$candidate" --transaction "$transaction" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "injected retained-prior retirement failure unexpectedly completed"
  assert_contains "$out" "cannot remove retained prior dispatch instructions" \
    "retained-prior failure did not identify the recoverable transition"
  jq -e '.state == "prepared"' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "replacement was marked completed before retained prior retirement"
  assert_present "$home/data/$task/work-identity-dispatch-prior.md" \
    "failed retained-prior retirement lost its recovery material"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-publish "$task" \
    --brief "$launch" --meta "$candidate" --transaction "$transaction" \
    || fail "replacement dispatch did not recover retained-prior retirement"
  jq -e '.state == "completed"' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "recovered replacement dispatch did not complete"
  assert_absent "$home/data/$task/work-identity-dispatch-prior.md" \
    "recovered replacement dispatch retained prior instructions"
  pass "replacement dispatch retires prior instructions before completion"
}

test_replacement_dispatch_resumes_before_metadata_publication() {
  local home task launch original_tx original_binding original_hash original_candidate draft replacement_tx replacement_binding replacement_hash retry candidate
  home=$(make_home replacement-pre-metadata-recovery)
  task='replacement-pre-metadata-recovery'
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold interrupted replacement fixture"
  launch="$home/state/$task.launch-brief.md"
  original_tx='replacement-pre-metadata-original'
  original_binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$original_tx") || fail "could not prepare original dispatch"
  original_hash=$(printf '%s' "$original_binding" | jq -r '.instructions_sha256')
  original_candidate="$home/state/.$task.meta.original"
  fm_write_meta "$original_candidate" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/worktree" "project=firstmate" "launch_brief=$launch" \
    "launch_brief_sha256=$original_hash" "work_identity_dispatch_transaction=$original_tx" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-publish "$task" \
    --brief "$launch" --meta "$original_candidate" --transaction "$original_tx" \
    || fail "could not publish original dispatch"

  draft="$home/state/.$task.launch-replacement"
  cp "$launch" "$draft"
  chmod 600 "$draft"
  printf '\nResume this replacement exactly.\n' >> "$draft"
  replacement_tx='replacement-pre-metadata-next'
  replacement_binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$draft" --instructions-path "$launch" --transaction "$replacement_tx" \
    --meta "$home/state/$task.meta" --prior-brief "$launch") \
    || fail "could not prepare replacement before interruption"
  replacement_hash=$(printf '%s' "$replacement_binding" | jq -r '.instructions_sha256')
  [ "$(sha256_file_for_test "$launch")" = "$replacement_hash" ] \
    || fail "replacement prepare did not atomically publish its validated instructions"
  jq -e --arg previous "$original_tx" '
    .state == "prepared" and .replacement == true
      and .previous_transaction_id == $previous
  ' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "replacement receipt did not preserve the exact prior metadata transaction"

  retry=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$draft" --instructions-path "$launch" --transaction replacement-retry-process \
    --meta "$home/state/$task.meta" --prior-brief "$launch") \
    || fail "replacement retry mistook prior metadata for new publication"
  [ "$(printf '%s' "$retry" | jq -r '.transaction_id')" = "$replacement_tx" ] \
    || fail "replacement retry did not resume the prepared transaction"
  candidate="$home/state/.$task.meta.replacement"
  awk -F= -v hash="$replacement_hash" -v transaction="$replacement_tx" '
    $1 == "launch_brief_sha256" { print "launch_brief_sha256=" hash; next }
    $1 == "work_identity_dispatch_transaction" { print "work_identity_dispatch_transaction=" transaction; next }
    { print }
  ' "$home/state/$task.meta" > "$candidate"
  FM_HOME="$home" "$WORK_IDENTITY" dispatch-publish "$task" \
    --brief "$launch" --meta "$candidate" --transaction "$replacement_tx" \
    || fail "resumed replacement did not publish metadata"
  jq -e '.state == "completed"' "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "resumed replacement remained incomplete"
  pass "replacement dispatch resumes across pre-metadata interruption"
}

test_unlinked_reservation_blocks_late_intake() {
  local home task manifest first second out rc=0
  home=$(make_home persistent-secondmate-reservation)
  task=persistent-secondmate-reservation
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  first=$(FM_HOME="$home" "$WORK_IDENTITY" reserve-unlinked "$task" \
    --reason persistent-secondmate) || fail "could not reserve persistent secondmate identity"
  second=$(FM_HOME="$home" "$WORK_IDENTITY" reserve-unlinked "$task" \
    --reason persistent-secondmate) || fail "unlinked reservation was not idempotent"
  [ "$first" = "$second" ] || fail "idempotent unlinked reservation changed its projection"
  printf '%s' "$first" | jq -e '
    .status == "unlinked" and .reason == "explicitly-unlinked"
  ' >/dev/null || fail "unlinked reservation was not explicit"
  rc=0
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "late intake linked a reserved persistent secondmate"
  assert_contains "$out" "permanently reserved as an unlinked persistent secondmate" \
    "late intake refusal did not identify the durable applicability boundary"
  assert_absent "$home/data/$task/work-identity.json" \
    "late intake partially published a linked identity"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e '.status == "unlinked"' >/dev/null \
    || fail "reserved persistent secondmate did not remain explicitly unlinked"
  pass "persistent secondmate reservation excludes concurrent linked intake"
}

test_metadata_validation_uses_one_stable_capture() {
  local home task manifest meta fakebin real_grep out rc=0
  home=$(make_home metadata-capture)
  task=metadata-capture-worker
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  write_bound_meta "$home" "$task" "$home/worktree"
  meta="$home/state/$task.meta"
  printf 'operator_note=aaaaaaaa\n' >> "$meta"
  cp "$meta" "$home/meta-replacement"
  awk -F= '$1 == "operator_note" { print "operator_note=bbbbbbbb"; next } { print }' \
    "$home/meta-replacement" > "$home/meta-replacement.tmp"
  mv "$home/meta-replacement.tmp" "$home/meta-replacement"
  [ "$(LC_ALL=C wc -c < "$meta" | tr -d ' ')" = \
    "$(LC_ALL=C wc -c < "$home/meta-replacement" | tr -d ' ')" ] \
    || fail "same-size metadata rewrite fixture changed file size"
  fakebin=$(fm_fakebin "$home/grep-fake")
  real_grep=$(command -v grep)
  cat > "$fakebin/grep" <<'SH'
#!/usr/bin/env bash
set -eu
if [ ! -e "$FM_TEST_REWRITE_MARKER" ]; then
  /bin/cp "$FM_TEST_META_REPLACEMENT" "$FM_TEST_META"
  : > "$FM_TEST_REWRITE_MARKER"
fi
exec "$FM_TEST_REAL_GREP" "$@"
SH
  chmod +x "$fakebin/grep"
  out=$(PATH="$fakebin:$PATH" FM_TEST_META="$meta" \
    FM_TEST_META_REPLACEMENT="$home/meta-replacement" \
    FM_TEST_REWRITE_MARKER="$home/meta-rewritten" FM_TEST_REAL_GREP="$real_grep" \
    FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "projection accepted metadata rewritten during validation"
  assert_contains "$out" "task metadata changed while it was validated" \
    "metadata rewrite refusal did not identify the unstable source"
  pass "metadata projection validates one stable captured byte sequence"
}

test_snapshot_preflight_and_dispatch_recovery() {
  local home mate task transfer out rc=0 launch transaction binding hash fakebin
  home=$(make_home publication-preflight)
  mate="$TMP_ROOT/publication-preflight-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf 'preflight\n' > "$mate/.fm-secondmate-home"
  task=omitted-prepared-handoff
  transfer=$(FM_HOME="$home" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$mate" --to-home-id secondmate:preflight) \
    || fail "could not prepare omitted handoff fixture"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json 2>&1) || rc=$?
  [ "$rc" -eq 42 ] || fail "main snapshot did not reject omitted prepared ownership (rc=$rc): $out"
  assert_contains "$out" "ownership handoff is incomplete" \
    "main snapshot preflight did not name prepared ownership"
  rc=0
  out=$(FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary 2>&1) || rc=$?
  [ "$rc" -eq 42 ] || fail "child summary did not reject omitted prepared ownership (rc=$rc): $out"
  rc=0
  out=$(FM_HOME="$home" "$SNAPSHOT" --secondmate-home-identities "$task" 2>&1) || rc=$?
  [ "$rc" -eq 42 ] || fail "identity batch did not reject omitted prepared ownership (rc=$rc): $out"
  printf '%s\n' "$transfer" | FM_HOME="$home" "$WORK_IDENTITY" \
    handoff-cancel "$task" --file - >/dev/null \
    || fail "could not cancel omitted prepared handoff fixture"

  FM_HOME="$home" "$WORK_IDENTITY" reserve-unlinked publication-guard-a \
    --reason persistent-secondmate >/dev/null
  FM_HOME="$home" "$WORK_IDENTITY" reserve-unlinked publication-guard-b \
    --reason persistent-secondmate >/dev/null
  out=$(FM_HOME="$home" "$WORK_IDENTITY" publication-run -- printf 'published\n') \
    || fail "publication preflight rejected distinct guarded task directories"
  [ "$out" = published ] \
    || fail "publication preflight did not run after validating multiple guarded tasks"

  task=secondmate-dispatch-recovery
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "could not scaffold dispatch recovery instructions"
  launch="$home/state/$task.launch-brief.md"
  transaction=dispatch-recovery-1
  binding=$(FM_HOME="$home" "$WORK_IDENTITY" dispatch-prepare "$task" \
    --brief "$home/data/$task/brief.md" --instructions-path "$launch" \
    --transaction "$transaction") || fail "could not prepare recoverable dispatch"
  hash=$(printf '%s' "$binding" | jq -r '.instructions_sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$home/secondmate-home" "project=$home/secondmate-home" \
    "launch_brief=$launch" "launch_brief_sha256=$hash" \
    "work_identity_dispatch_transaction=$transaction" \
    "harness=codex" "kind=secondmate" "mode=secondmate" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=unlinked"
  fakebin=$(make_fakebin "$home/preflight-fakes")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$SNAPSHOT" --secondmate-home-identities "$task") \
    || fail "snapshot did not reconcile exact prepared dispatch metadata"
  printf '%s' "$out" | jq -e --arg task "$task" '
    .records[] | select(.task_id == $task)
    | .work_identity.status == "unlinked"
      and .work_identity.reason == "explicitly-unlinked"
  ' >/dev/null || fail "reconciled dispatch projection was malformed: $out"
  jq -e '.state == "completed" and .transaction_id == "dispatch-recovery-1"' \
    "$home/data/$task/work-identity-dispatch.json" >/dev/null \
    || fail "snapshot preflight did not complete the exact metadata transaction"

  printf '\nUpdated parent-side charter scaffold.\n' >> "$home/data/$task/brief.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$SNAPSHOT" --secondmate-home-identities "$task") \
    || fail "metadata-bound secondmate launch snapshot was not authoritative"
  printf '%s' "$out" | jq -e --arg task "$task" '
    .records[] | select(.task_id == $task)
    | .work_identity.status == "unlinked"
      and .work_identity.provenance.instructions == "generated-instructions"
      and .work_identity.provenance.metadata == "metadata"
  ' >/dev/null || fail "secondmate identity projection reread the changed parent scaffold: $out"
  pass "snapshot preflight blocks prepared ownership and recovers exact dispatch metadata"
}

# Namespace is part of identity: identical opaque ids in separate systems stay
# distinct, while duplicate exact tuples and invalid namespace-role pairs refuse.
test_namespace_separation_and_contract_rejections() {
  local home task manifest out rc case_name
  home=$(make_home namespaces)
  task=namespace-worker
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  jq '.sources = [
        {namespace:"dtm",kind:"issue",id:"shared-7",label:"DTM Seven"},
        {namespace:"data-team-ticket",kind:"ticket",id:"shared-7",label:"Ticket Seven"}
      ]
      | .plan_id.id = "shared-7"
      | .work_units[0].id = "shared-7"' "$manifest" > "$home/separate.json"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/separate.json" >/dev/null \
    || fail "separate namespaces/kinds with the same opaque id were conflated"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task")
  printf '%s' "$out" | jq -e '
    .plan_id == {namespace:"work-aligner",kind:"plan",id:"shared-7",label:"Identity Plan"}
      and .work_units[0] == {namespace:"work-aligner",kind:"work-unit",id:"shared-7",label:"Exact Intake"}
      and (.sources | map([.namespace,.kind,.id])) == [
        ["dtm","issue","shared-7"],["data-team-ticket","ticket","shared-7"]]
  ' >/dev/null || fail "namespace-separated exact identities did not survive"

  task=local-plan-worker
  make_manifest "$home" "$task" "$manifest"
  jq '.initiative={namespace:"firstmate",kind:"initiative",id:"local-initiative",label:"Local Initiative"}
      | .plan_id={namespace:"firstmate",kind:"plan",id:"local-plan",label:"Local Plan"}
      | .stage={namespace:"firstmate",kind:"stage",id:"local-stage",label:"Local Stage"}
      | .work_units=[{namespace:"firstmate",kind:"work-unit",id:"local-unit",label:"Local Unit"}]
      | .sources=[{namespace:"dtm",kind:"issue",id:"DTM-LOCAL-1",label:"Local Source"}]' \
    "$manifest" > "$home/local.json"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/local.json" >/dev/null \
    || fail "local Firstmate plan identity was refused"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e '
    .initiative.namespace == "firstmate" and .plan_id.id == "local-plan"
      and .stage.id == "local-stage" and .work_units[0].id == "local-unit"
  ' >/dev/null || fail "local Firstmate plan identity did not survive"

  for case_name in version bad-role duplicate unsafe-id no-source contradictory; do
    task="reject-$case_name"
    make_manifest "$home" "$task" "$manifest" multi
    case "$case_name" in
      version) jq '.schema="fm-work-identity.v2"' "$manifest" > "$home/bad.json" ;;
      bad-role) jq '.plan_id.namespace="dtm"' "$manifest" > "$home/bad.json" ;;
      duplicate) jq '.work_units[1]=.work_units[0]' "$manifest" > "$home/bad.json" ;;
      unsafe-id) jq '.work_units[0].id="../fuzzy"' "$manifest" > "$home/bad.json" ;;
      no-source) jq '.sources=[]' "$manifest" > "$home/bad.json" ;;
      contradictory) jq '.sources[0]=.work_units[0]' "$manifest" > "$home/bad.json" ;;
    esac
    out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad.json" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$case_name malformed contract was accepted"
    assert_absent "$home/data/$task/work-identity.json" "$case_name refusal partially published a sidecar"
  done
  pass "namespaces remain distinct and version, role, duplicate, contradiction, and id syntax are closed"
}

# Unsafe inputs and stored records refuse. Labels are display-only but still must
# be safe to embed in generated instructions.
test_unsafe_files_labels_and_exact_binding() {
  local home home_real other other_real task manifest out rc sidecar transfer projection projection_set
  home=$(make_home safety-a)
  home_real=$(cd "$home" && pwd -P)
  other=$(make_home safety-b)
  other_real=$(cd "$other" && pwd -P)
  task=safe-worker
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"

  ln -s "$manifest" "$home/manifest-link.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/manifest-link.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked manifest was accepted"
  ln "$manifest" "$home/manifest-hard.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/manifest-hard.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked manifest was accepted"
  rm "$home/manifest-hard.json"

  jq '.work_units[0].label=" Unsafe label"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "leading-space label was accepted"
  jq '.work_units[0].label="Unsafe ` label"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "instruction-breaking label was accepted"
  jq '.work_units[0].label="unsafe\u009b2Kcontrol"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "C1 terminal-control label was accepted"
  jq '.work_units[0].label="safe-id\u202Edi-efas"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "Unicode bidi-format label was accepted"
  assert_absent "$home/data/$task/work-identity.json" "unsafe label refusal partially published a record"

  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  sidecar="$home/data/$task/work-identity.json"
  mkdir -p "$other/data/$task"
  cp "$sidecar" "$other/data/$task/work-identity.json"
  out=$(FM_HOME="$other" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "cross-home copied relation was accepted"
  printf 'other\n' > "$other/.fm-secondmate-home"
  jq -S -c --arg home "$other_real" '.binding.home=$home' "$sidecar" \
    > "$other/data/$task/work-identity.json"
  out=$(FM_HOME="$other" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "path-rebound record with another stable home identity was accepted"
  transfer=$(FM_HOME="$home" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$home_real" --to-home-id secondmate:same-path)
  printf '%s' "$transfer" | jq -e '
    .source.home == .target.home and .source.home_id == "main"
      and .target.home_id == "secondmate:same-path"
  ' >/dev/null || fail "same-path remote handoff did not bind distinct stable home identities"
  printf '%s\n' "$transfer" | FM_HOME="$home" "$WORK_IDENTITY" \
    handoff-cancel "$task" --file - >/dev/null || fail "same-path handoff preparation did not cancel"
  projection=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task")
  projection_set=$(jq -n -c --arg task "$task" --argjson identity "$projection" \
    '[{task_id:$task,work_identity:$identity}]')
  out=$(printf '%s\n' "$projection_set" | FM_HOME="$home" "$WORK_IDENTITY" \
    validate-projections --home "$home_real" --home-id secondmate:same-path --file - 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "cross-home projection with the same absolute path was accepted"
  mkdir -p "$home/data/other-task"
  cp "$sidecar" "$home/data/other-task/work-identity.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify other-task 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "task-mismatched relation was accepted"

  ln "$sidecar" "$home/data/$task/work-identity-hard.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked stored relation was accepted"
  rm "$home/data/$task/work-identity-hard.json"
  mv "$sidecar" "$home/data/$task/work-identity-real.json"
  ln -s work-identity-real.json "$sidecar"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked stored relation was accepted"
  pass "unsafe manifests, labels, stored files, cross-home copies, and task mismatches refuse"
}

# Linked records are frozen by both generated instructions and metadata. Manual
# post-dispatch edits become stale and cannot publish through any read surface.
test_stale_and_changed_relations_refuse() {
  local home task manifest wt sidecar out rc canonical
  home=$(make_home stale)
  task=stale-worker
  manifest="$home/manifest.json"
  wt="$home/worktree"
  mkdir -p "$wt"
  make_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  write_bound_meta "$home" "$task" "$wt"
  jq '.work_units[0].id="wu-manually-changed"' "$manifest" > "$home/changed.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/changed.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "public intake changed a frozen relation"
  sidecar="$home/data/$task/work-identity.json"
  canonical=$(jq -S -c '.work_units[0].id="wu-manually-changed"' "$sidecar")
  printf '%s\n' "$canonical" > "$sidecar"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "stale sidecar digest was accepted against brief/meta bindings"
  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "authoritative snapshot partially published a stale linked relation"
  pass "generated instructions and metadata freeze the exact relation against stale edits"
}

# Legacy tasks are explicitly unlinked. Every tempting fuzzy signal remains
# ignored, including title, repository, branch/worktree, pane, worker, time, and
# status prose.
test_legacy_and_fuzzy_fallbacks_are_unlinked() {
  local home task long_task component_task before_read after_read wt fakebin json bearings
  home=$(make_home fuzzy)
  task=wa-plan-2026-q3
  long_task=legacy-task-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-0123456789
  component_task="legacy-$(printf 'x%.0s' {1..300})"
  wt="$home/projects/dtm-project-17/wu-exact-intake"
  mkdir -p "$wt" "$home/data/$task"
  printf 'legacy brief names Work Aligner wu-fleet-projection\n' > "$home/data/$task/brief.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $task - Work Aligner wu-exact-intake (repo: wa-project-42) (kind: ship) (since 2026-08-14)

## Queued
- [ ] $long_task - path-safe overlong legacy task (repo: legacy)
- [ ] $component_task - filesystem-component-overlong legacy task (repo: legacy)

## Done
EOF
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-wu-fleet-projection" \
    "worktree=$wt" \
    "project=wa-project-42" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf 'working: DTM-431 implements Work Aligner plan wa-plan-2026-q3\n' > "$home/state/$task.status"
  fakebin=$(make_fakebin "$home/fakes")
  FM_HOME="$home" "$WORK_IDENTITY" verify "$long_task" | jq -e '
    .status == "unlinked" and .reason == "legacy-no-record"
  ' >/dev/null || fail "path-safe overlong legacy task did not verify as unlinked"
  before_read=$(find "$home/data" -mindepth 1 -maxdepth 1 -type d -print | sort)
  FM_HOME="$home" "$WORK_IDENTITY" verify "$component_task" | jq -e \
    --arg task "$component_task" '
    .status == "unlinked" and .reason == "legacy-no-record"
      and .binding.task_id == $task
  ' >/dev/null || fail "filesystem-component-overlong legacy task did not verify as unlinked"
  after_read=$(find "$home/data" -mindepth 1 -maxdepth 1 -type d -print | sort)
  [ "$before_read" = "$after_read" ] \
    || fail "legacy verification created a durable task data directory"
  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$json" | jq -e --arg long "$long_task" --arg component "$component_task" '
    (.tasks[] | select(.id == "wa-plan-2026-q3")
      | .work_identity.status == "unlinked"
        and .work_identity.reason == "legacy-no-record"
        and .work_identity.initiative == null
        and .work_identity.work_units == []
        and .work_identity.sources == [])
      and (.backlog.records[] | select(.id == "wa-plan-2026-q3")
        | .work_identity.status == "unlinked")
      and (.backlog.records[] | select(.id == $long)
        | .work_identity.status == "unlinked" and .work_identity.reason == "legacy-no-record")
      and (.backlog.records[] | select(.id == $component)
        | .work_identity.status == "unlinked" and .work_identity.reason == "legacy-no-record")
  ' >/dev/null || fail "a fuzzy title/repo/branch/pane/status relation leaked into snapshot: $json"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    .in_flight[] | select(.id == "wa-plan-2026-q3")
    | .work_identity == "unlinked" and .initiative == "-" and .plan == "-"
      and .stage == "-" and .work_units == "-" and .sources == "-"
  ' >/dev/null || fail "Bearings invented a fuzzy relation: $bearings"
  pass "legacy tasks stay explicitly unlinked despite every fuzzy fallback signal"
}

# A secondmate home projects its own linked child through the bounded structured
# summary. The parent consumes that projection and never scans or rebuilds the
# child tree itself; Bearings exposes one delegated child row with all exact ids.
test_delegated_secondmate_projection() {
  local parent mate task long_task manifest wt fakebin hash canonical bearings gen out rc
  parent=$(make_home delegated-parent)
  mate="$TMP_ROOT/delegated-mate"
  task=delegated-child
  long_task=legacy-delegated-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz
  wt="$mate/projects/$task"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin" "$wt"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'roadmap\n' > "$mate/.fm-secondmate-home"
  printf -- '- roadmap - roadmap domain (home: %s; scope: roadmap work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/roadmap.meta" "$mate" "firstmate:fm-roadmap" firstmate codex
  printf 'working [key=delegated]: delegated child active\n' > "$parent/state/roadmap.status"

  manifest="$mate/manifest.json"
  make_manifest "$mate" "$task" "$manifest" multi
  record_and_brief "$mate" "$task" "$manifest"
  hash=$(FM_HOME="$mate" "$WORK_IDENTITY" verify "$task" | jq -r '.sha256')
  fm_write_meta "$mate/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" "worktree=$wt" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=linked" "work_identity_sha256=$hash"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$task" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'working: exact delegated work\n' > "$mate/state/$task.status"
  cat > "$mate/data/backlog.md" <<EOF
## In flight
- [ ] $task - Exact delegated child (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued
- [ ] $long_task - Exact long legacy delegated id (repo: firstmate) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$parent/fakes")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$canonical" | jq -e --arg long "$long_task" '
    .secondmate_current.records[] | select(.id == "roadmap")
    | . as $mate
    | .provenance.selected == "structured-home"
      and ([.active_children[] | select(.id == "delegated-child" and .work_identity_ref == "delegated-child")] | length) == 1
      and ([.endpoints[] | select(.id == "delegated-child" and .work_identity_ref == "delegated-child")] | length) == 1
      and ([.work_identities[] | select(.task_id == "delegated-child")] | length) == 1
      and ([.queued[] | select(.id == $long and .work_identity_ref == $long)] | length) == 1
      and ([.work_identities[] | select(.task_id == $long)
        | .work_identity | select(.status == "unlinked" and .reason == "legacy-no-record")] | length) == 1
      and (.work_identities[] | select(.task_id == "delegated-child") | .work_identity
        | .status == "linked" and .binding.home_id == "secondmate:roadmap"
          and (.work_units | map(.id)) == ["wu-exact-intake","wu-fleet-projection"]
          and (.sources | any(.namespace == "dtm" and .kind == "issue" and .id == "DTM-431")))
      and (all(.active_children[]; has("work_identity") | not))
      and (all(.endpoints[]; has("work_identity") | not))
  ' >/dev/null || fail "authoritative delegated-child projection lost exact identity: $canonical"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e --arg long "$long_task" '
    ([.delegated_work[] | select(.owner == "roadmap" and .id == "delegated-child")] | length) == 1
      and (.delegated_work[] | select(.owner == "roadmap" and .id == "delegated-child")
        | .work_identity == "linked"
          and (.work_units | contains("wu-exact-intake"))
          and (.work_units | contains("wu-fleet-projection"))
          and (.sources | contains("dtm:issue:DTM-431")))
      and ([.gates[] | select(.owner == "roadmap" and .id == $long
        and .work_identity == "unlinked")] | length) == 1
  ' >/dev/null || fail "Bearings delegated-work projection lost exact identities: $bearings"
  "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$task" idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'paused [key=external-review]: waiting for exact external review\n' > "$mate/state/$task.status"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    .delegated_work[] | select(.owner == "roadmap" and .id == "delegated-child")
    | .state == "held" and .work_identity == "linked"
      and (.work_units | contains("wu-exact-intake"))
      and (.sources | contains("dtm:issue:DTM-431"))
  ' >/dev/null || fail "Bearings dropped the exact identity of a held delegated child: $bearings"
  mv "$mate/data" "$TMP_ROOT/delegated-escaped-data"
  ln -s "$TMP_ROOT/delegated-escaped-data" "$mate/data"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --json 2>&1) || rc=$?
  [ "$rc" -eq 42 ] || fail "parent published through an escaping delegated data directory (rc=$rc)"
  assert_contains "$out" "work identity home binding mismatch in secondmate roadmap" \
    "unsafe delegated home path degraded to an untrusted fallback"
  rm "$mate/data"
  mv "$TMP_ROOT/delegated-escaped-data" "$mate/data"
  rm "$mate/.fm-secondmate-home"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --json 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "parent published after a readable delegated home lost its identity marker"
  assert_contains "$out" "work identity home binding mismatch in secondmate roadmap" \
    "missing delegated home identity marker degraded to an untrusted fallback"
  pass "delegated summaries preserve ids and reject unsafe home identity paths"
}

test_handoff_rebinds_identity_and_decision_surfaces() {
  local parent mate mate_real task manifest decision main_decision decision_manifest wt fakebin canonical bearings hash gen out rc child_out
  bash -c '. "$1"; fm_tasks_axi_handoff_compatible' \
    _ "$ROOT/bin/fm-tasks-axi-lib.sh" >/dev/null 2>&1 \
    || { pass "linked handoff coverage skipped without handoff-compatible tasks-axi"; return; }
  parent=$(make_home handoff-parent)
  mate="$TMP_ROOT/handoff-mate"
  task=linked-captain-hold
  decision=linked-status-decision
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'planning\n' > "$mate/.fm-secondmate-home"
  printf -- '- planning - planning domain (home: %s; scope: planning work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  cat > "$parent/state/planning.meta" <<EOF
window=firstmate:fm-planning
kind=secondmate
harness=claude
backend=tmux
home=$mate
worktree=$mate
EOF
  fakebin=$(make_fakebin "$parent/fakes")
  cat > "$parent/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $task - Choose linked release (repo: firstmate) (kind: captain) (hold: exact release choice pending) (hold-kind: captain)

## Done
EOF
  manifest="$parent/$task.json"
  make_manifest "$parent" "$task" "$manifest" multi
  FM_HOME="$parent" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  PATH="$fakebin:$PATH" FM_SEND_SETTLE=0 FM_HOME="$parent" \
    "$ROOT/bin/fm-backlog-handoff.sh" planning "$task" >/dev/null \
    || fail "linked local backlog handoff failed"
  mate_real=$(cd "$mate" && pwd -P)
  FM_HOME="$mate" "$WORK_IDENTITY" verify "$task" | jq -e \
    --arg home "$mate_real" '.status == "linked" and .binding.home == $home
      and .binding.home_id == "secondmate:planning" and .binding.task_id == "linked-captain-hold"' >/dev/null \
    || fail "linked handoff did not atomically stage a destination-bound identity"
  jq -e '.role == "source" and .state == "completed"
      and .transfer.target.home_id == "secondmate:planning"' \
    "$parent/data/$task/work-identity-handoff-source.json" >/dev/null \
    || fail "successful handoff did not retain an exact source ownership tombstone"
  jq -e '.role == "target" and .state == "completed"
      and .transfer.source.home_id == "main"' \
    "$mate/data/$task/work-identity-handoff-target.json" >/dev/null \
    || fail "successful handoff did not retain an exact destination commit receipt"
  out=$(FM_HOME="$parent" "$WORK_IDENTITY" record "$task" --file "$manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "source intake published again after completed ownership transfer"

  decision_manifest="$mate/$decision.json"
  wt="$mate/projects/$decision"
  mkdir -p "$wt"
  make_manifest "$mate" "$decision" "$decision_manifest"
  record_and_brief "$mate" "$decision" "$decision_manifest"
  hash=$(FM_HOME="$mate" "$WORK_IDENTITY" verify "$decision" | jq -r '.sha256')
  fm_write_meta "$mate/state/$decision.meta" \
    "window=firstmate:fm-$decision" "endpoint_task_id=$decision" "worktree=$wt" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=linked" "work_identity_sha256=$hash"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$decision")
  "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$decision" idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'needs-decision [key=exact-choice]: choose the exact linked option\n' > "$mate/state/$decision.status"

  main_decision=linked-main-status-decision
  decision_manifest="$parent/$main_decision.json"
  wt="$parent/projects/$main_decision"
  mkdir -p "$wt"
  make_manifest "$parent" "$main_decision" "$decision_manifest"
  record_and_brief "$parent" "$main_decision" "$decision_manifest"
  write_bound_meta "$parent" "$main_decision" "$wt"
  sed 's/^harness=codex$/harness=claude/' "$parent/state/$main_decision.meta" \
    > "$parent/state/$main_decision.meta.tmp"
  mv "$parent/state/$main_decision.meta.tmp" "$parent/state/$main_decision.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$parent/state" "$main_decision")
  "$ROOT/bin/fm-busy-event.sh" apply "$parent/state" "$main_decision" idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'needs-decision [key=main-exact-choice]: choose the main linked option\n' \
    > "$parent/state/$main_decision.status"
  cat > "$parent/data/backlog.md" <<EOF
## In flight
- [ ] $main_decision - Main linked worker awaiting a decision (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued

## Done
EOF
  cat > "$mate/data/backlog.md" <<EOF
## In flight
- [ ] $decision - Linked worker awaiting a decision (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued
- [ ] $task - Choose linked release (repo: firstmate) (kind: captain) (hold: exact release choice pending) (hold-kind: captain)

## Done
EOF
  child_out=$(PATH="$fakebin:$PATH" FM_FAKE_PANE_COMMAND=claude FM_HOME="$mate" \
    FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --secondmate-home-summary 2>&1) \
    || fail "delegated handoff home could not publish its structured summary: $child_out"
  canonical=$(PATH="$fakebin:$PATH" FM_FAKE_PANE_COMMAND=claude FM_HOME="$parent" \
    FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "planning")
    | . as $mate
    | ([.decisions_open[] | select(.id == "linked-captain-hold" and .source == "backlog"
        and .work_identity_ref == "linked-captain-hold")] | length) == 1
      and ([.decisions_open[] | select(.id == "linked-status-decision" and .source == "status"
        and .work_identity_ref == "linked-status-decision")] | length) == 1
      and ([.work_identities[] | select(.task_id == "linked-captain-hold" and .work_identity.status == "linked")] | length) == 1
      and ([.work_identities[] | select(.task_id == "linked-status-decision" and .work_identity.status == "linked")] | length) == 1
  ' >/dev/null || fail "delegated decision surfaces lost their source work identities: $canonical"
  bearings=$(PATH="$fakebin:$PATH" FM_FAKE_PANE_COMMAND=claude FM_HOME="$parent" \
    FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    ([.secondmates[] | select(.id == "planning" and .state == "captain_decision"
        and (.doing | contains("choose the exact linked option")))] | length) == 1
      and ([.decisions_open[] | select(.id == "planning/linked-captain-hold"
        and .work_identity == "linked" and (.work_units | contains("wu-exact-intake"))
        and (.sources | contains("dtm:issue:DTM-431")))] | length) == 1
      and ([.decisions_open[] | select(.id == "planning/linked-status-decision"
        and .verb == "needs-decision" and .work_identity == "linked"
        and (.work_units | contains("wu-exact-intake")))] | length) == 1
      and ([.decisions_open[] | select(.id == "linked-main-status-decision"
        and .owner == "(main)" and .verb == "needs-decision"
        and .work_identity == "linked" and (.sources | contains("DTM-431")))] | length) == 1
  ' >/dev/null || fail "Bearings decision projection lost a canonical linked decision: $bearings"
  hash=$(sha256_file_for_test "$parent/data/$task/work-identity.json")
  [ -n "$hash" ] || fail "source handoff identity was not retained as immutable provenance"
  pass "linked handoff rebinds identity for delegated decision summaries and Bearings"
}

test_completed_unlinked_handoff_accepts_exact_intake() {
  local source target task transfer manifest out
  source=$(make_home post-handoff-intake-source)
  target="$TMP_ROOT/post-handoff-intake-target"
  task=post-handoff-intake
  mkdir -p "$target/data" "$target/state" "$target/config" "$target/projects"
  printf 'intake-target\n' > "$target/.fm-secondmate-home"
  transfer=$(FM_HOME="$source" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$target" --to-home-id secondmate:intake-target)
  printf '%s\n' "$transfer" | FM_HOME="$target" "$WORK_IDENTITY" \
    handoff-stage "$task" --file - >/dev/null
  printf '%s\n' "$transfer" | FM_HOME="$target" "$WORK_IDENTITY" \
    handoff-commit "$task" --file - >/dev/null
  printf '%s\n' "$transfer" | FM_HOME="$source" "$WORK_IDENTITY" \
    handoff-complete "$task" --file - >/dev/null
  manifest="$target/manifest.json"
  make_manifest "$target" "$task" "$manifest"
  FM_HOME="$target" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null \
    || fail "completed unlinked handoff refused destination intake"
  jq -e '.role == "target" and .state == "intake-completed"
      and .transfer.identity.status == "unlinked"' \
    "$target/data/$task/work-identity-handoff-target.json" >/dev/null \
    || fail "post-handoff intake did not record its explicit ownership transition"
  FM_HOME="$target" "$WORK_IDENTITY" verify "$task" | jq -e \
    '.status == "linked" and .binding.home_id == "secondmate:intake-target"' >/dev/null \
    || fail "post-handoff intake left the destination identity unverifiable"
  out=$(FM_HOME="$target" "$WORK_IDENTITY" record "$task" --file "$manifest") \
    || fail "post-handoff intake was not idempotent"
  assert_contains "$out" "(unchanged)" "post-handoff intake retry did not converge"
  printf '%s\n' "$transfer" | FM_HOME="$target" "$WORK_IDENTITY" \
    handoff-target-state "$task" --file - | grep -qx completed \
    || fail "post-handoff intake changed the completed transfer receipt"
  pass "completed unlinked handoff records one explicit intake transition"
}

test_missing_state_directory_is_created_before_locking() {
  local home task manifest
  home="$TMP_ROOT/missing-state-home"
  task=missing-state-intake
  mkdir -p "$home/data" "$home/config" "$home/projects"
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null \
    || fail "identity intake did not create its missing lock directory"
  [ -d "$home/state" ] || fail "identity intake did not create the state directory"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e '.status == "linked"' >/dev/null \
    || fail "identity intake with a newly created state directory was not verifiable"
  pass "identity locking creates and validates its missing state directory"
}

test_handoff_receiver_reads_chunked_transfer_to_eof() {
  local parent mate task manifest block backlog_hash transfer bytes
  parent=$(make_home chunked-handoff-parent)
  mate="$TMP_ROOT/chunked-handoff-mate"
  task=chunked-handoff
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'chunked\n' > "$mate/.fm-secondmate-home"
  manifest="$parent/$task.json"
  make_max_manifest "$parent" "$task" "$manifest"
  FM_HOME="$parent" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  block="$parent/$task.block"
  printf '%s\n' "- [ ] $task - chunked transfer identity (repo: firstmate)" > "$block"
  backlog_hash=$(sha256_file_for_test "$block")
  transfer=$(FM_HOME="$parent" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$mate" --to-home-id secondmate:chunked --backlog-sha256 "$backlog_hash")
  bytes=$(LC_ALL=C printf '%s' "$transfer" | wc -c | tr -d ' ')
  [ "$bytes" -gt 4096 ] || fail "chunked handoff fixture was too small to exercise a short transport read"
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" \
    handoff-stage "$task" --file - >/dev/null \
    || fail "could not stage the chunked handoff fixture"
  {
    printf '%s' "${transfer:0:64}"
    sleep 0.1
    printf '%s\n' "${transfer:64}"
  } | FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-receive.sh" --prepare-handoff "$task" >/dev/null \
    || fail "handoff receiver truncated a valid chunked transfer"
  jq -e '.state == "prepared"' \
    "$mate/data/$task/work-identity-handoff-target.json" >/dev/null \
    || fail "chunked handoff preflight changed the target receipt"
  pass "handoff receiver reads chunked transfers through EOF"
}

test_handoff_preparation_is_durable_and_rollback_safe() {
  local parent mate task_a task_b task_c race manifest transfer out rc backlog_hash
  command -v tasks-axi >/dev/null 2>&1 || { pass "handoff transaction coverage skipped without tasks-axi"; return; }
  parent=$(make_home handoff-transaction-parent)
  mate="$TMP_ROOT/handoff-transaction-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'transaction\n' > "$mate/.fm-secondmate-home"
  printf -- '- transaction - transaction domain (home: %s; scope: exact work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  task_a='transaction-a'
  task_b='transaction-b'
  task_c='transaction-c'
  for task in "$task_a" "$task_b" "$task_c"; do
    manifest="$parent/$task.json"
    make_manifest "$parent" "$task" "$manifest"
    FM_HOME="$parent" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  done
  mkdir -p "$mate/data/$task_b"
  printf 'pre-existing destination instructions\n' > "$mate/data/$task_b/brief.md"
  cat > "$parent/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $task_a - first transactional identity (repo: firstmate)
- [ ] $task_b - second transactional identity (repo: firstmate)
- [ ] $task_c - recovered prepared identity (repo: firstmate)

## Done
EOF
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-backlog-handoff.sh" transaction "$task_a" "$task_b" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "multi-item handoff ignored a later destination identity conflict"
  assert_grep "$task_a" "$parent/data/backlog.md" "failed handoff moved the first backlog item"
  assert_grep "$task_b" "$parent/data/backlog.md" "failed handoff moved the second backlog item"
  assert_absent "$mate/data/$task_a/work-identity.json" "failed staging published an immutable first sidecar"
  assert_absent "$mate/data/$task_a/work-identity-handoff-target.json" "failed staging retained the first target prepare"
  assert_absent "$parent/data/$task_a/work-identity-handoff-source.json" "failed staging retained the first source prepare"
  assert_absent "$parent/data/$task_b/work-identity-handoff-source.json" "failed staging retained the second source prepare"
  FM_HOME="$parent" "$WORK_IDENTITY" verify "$task_a" | jq -e '.status == "linked"' >/dev/null \
    || fail "failed multi-item staging damaged the source identity"

  printf '%s\n' "- [ ] $task_a - first transactional identity (repo: firstmate)" > "$parent/$task_a.block"
  backlog_hash=$(sha256_file_for_test "$parent/$task_a.block")
  transfer=$(FM_HOME="$parent" "$WORK_IDENTITY" handoff-prepare "$task_a" \
    --to-home "$mate" --to-home-id secondmate:transaction --backlog-sha256 "$backlog_hash")
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-stage "$task_a" --file - >/dev/null \
    || fail "could not stage the interrupted committed-target fixture"
  printf '%s\n' "$transfer" | FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-receive.sh" --prepare-handoff "$task_a" >/dev/null \
    || fail "could not prepare the committed target backlog receipt"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  tasks-axi mv "$task_a" --file "$parent/data/backlog.md" --to "$mate/data/backlog.md" >/dev/null \
    || fail "could not move the interrupted target backlog fixture"
  printf '%s\n' "$transfer" | FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-receive.sh" --complete-handoff "$task_a" >/dev/null \
    || fail "could not complete the committed target backlog receipt"
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-commit "$task_a" --file - >/dev/null \
    || fail "could not commit the interrupted target fixture"
  jq -e '.state == "prepared"' "$parent/data/$task_a/work-identity-handoff-source.json" >/dev/null \
    || fail "interrupted target fixture unexpectedly completed source ownership"
  rc=0
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-backlog-handoff.sh" transaction "$task_a" "$task_b" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "mixed retry ignored the later destination conflict"
  assert_grep "$task_b" "$parent/data/backlog.md" "mixed retry moved the conflicting backlog item"
  jq -e '.role == "target" and .state == "completed"' \
    "$mate/data/$task_a/work-identity-handoff-target.json" >/dev/null \
    || fail "mixed retry lost the committed destination receipt"
  jq -e '.role == "source" and .state == "completed"' \
    "$parent/data/$task_a/work-identity-handoff-source.json" >/dev/null \
    || fail "mixed retry resurrected source ownership after a proven target commit"
  assert_absent "$parent/data/$task_b/work-identity-handoff-source.json" \
    "mixed retry left the conflicting source identity prepared"
  assert_absent "$mate/data/$task_b/work-identity-handoff-target.json" \
    "mixed retry left the conflicting destination identity prepared"
  FM_HOME="$mate" "$WORK_IDENTITY" verify "$task_a" | jq -e '.status == "linked"' >/dev/null \
    || fail "mixed retry blocked the already committed destination identity"
  rc=0
  out=$(FM_HOME="$parent" "$WORK_IDENTITY" verify "$task_a" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "mixed retry made the completed source identity publishable again"

  printf '%s\n' "- [ ] $task_c - recovered prepared identity (repo: firstmate)" > "$parent/$task_c.block"
  backlog_hash=$(sha256_file_for_test "$parent/$task_c.block")
  transfer=$(FM_HOME="$parent" "$WORK_IDENTITY" handoff-prepare "$task_c" \
    --to-home "$mate" --to-home-id secondmate:transaction --backlog-sha256 "$backlog_hash")
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" \
    handoff-stage "$task_c" --file - >/dev/null \
    || fail "could not stage the interrupted prepared-target fixture"
  printf '%s\n' "$transfer" | FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-backlog-receive.sh" --prepare-handoff "$task_c" >/dev/null \
    || fail "could not prepare the interrupted target backlog receipt"
  tasks-axi mv "$task_c" --file "$parent/data/backlog.md" --to "$mate/data/backlog.md" >/dev/null \
    || fail "could not move the interrupted prepared-target backlog fixture"
  jq -e '.state == "prepared"' \
    "$mate/data/$task_c/work-identity-handoff-target.json" >/dev/null \
    || fail "interrupted prepared-target fixture changed during preflight"
  rc=0
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-backlog-handoff.sh" \
    transaction "$task_c" "$task_b" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "mixed retry ignored the later conflict after a recovered prepare"
  jq -e '.role == "target" and .state == "completed"' \
    "$mate/data/$task_c/work-identity-handoff-target.json" >/dev/null \
    || fail "mixed retry aborted recovered target ownership despite destination backlog"
  jq -e '.role == "source" and .state == "completed"' \
    "$parent/data/$task_c/work-identity-handoff-source.json" >/dev/null \
    || fail "mixed retry resurrected source ownership from a recovered prepare"
  FM_HOME="$mate" "$WORK_IDENTITY" verify "$task_c" | jq -e '.status == "linked"' >/dev/null \
    || fail "mixed retry did not publish recovered destination ownership"

  race=record-during-handoff
  manifest="$parent/$race.json"
  make_manifest "$parent" "$race" "$manifest"
  transfer=$(FM_HOME="$parent" "$WORK_IDENTITY" handoff-prepare "$race" \
    --to-home "$mate" --to-home-id secondmate:transaction)
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-stage "$race" --file - >/dev/null \
    || fail "unlinked handoff preparation did not reach the target"
  out=$(FM_HOME="$parent" "$WORK_IDENTITY" record "$race" --file "$manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "concurrent intake published after handoff preparation froze ownership"
  out=$(FM_HOME="$mate" "$WORK_IDENTITY" verify "$race" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "target projection published while identity handoff was only prepared"
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-abort "$race" --file - >/dev/null \
    || fail "prepared target identity could not abort"
  printf '%s\n' "$transfer" | FM_HOME="$parent" "$WORK_IDENTITY" handoff-cancel "$race" --file - >/dev/null \
    || fail "prepared source identity could not cancel"
  FM_HOME="$parent" "$WORK_IDENTITY" record "$race" --file "$manifest" >/dev/null \
    || fail "intake did not resume after an exact handoff cancellation"
  pass "handoff preparation freezes intake and failed batches leave no immutable target sidecars"
}

test_unsafe_publication_setup_uses_integrity_exit() {
  local home out rc=0
  home=$(make_home unsafe-publication-setup)
  mv "$home/data" "$home/data-real"
  ln -s "$home/data-real" "$home/data"
  out=$(FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary 2>&1) || rc=$?
  [ "$rc" -eq 42 ] || fail "unsafe child publication setup returned $rc instead of integrity status: $out"
  pass "unsafe child publication setup returns typed integrity status"
}

test_delegated_integrity_failure_stops_parent_publication() {
  local parent mate task guarded manifest transfer out rc=0 sidecar
  parent=$(make_home integrity-parent)
  mate="$TMP_ROOT/integrity-mate"
  task=stale-delegated
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'integrity\n' > "$mate/.fm-secondmate-home"
  printf -- '- integrity - integrity domain (home: %s; scope: integrity work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  manifest="$mate/manifest.json"
  make_manifest "$mate" "$task" "$manifest"
  record_and_brief "$mate" "$task" "$manifest"
  cat > "$mate/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $task - Stale delegated relation (repo: firstmate) (kind: ship)

## Done
EOF
  guarded=omitted-delegated-prepare
  transfer=$(FM_HOME="$mate" "$WORK_IDENTITY" handoff-prepare "$guarded" \
    --to-home "$parent" --to-home-id main) \
    || fail "could not prepare omitted delegated ownership fixture"
  out=$(FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json 2>&1) || rc=$?
  [ "$rc" -eq 42 ] || fail "parent publication bypassed the delegated home's ownership preflight (rc=$rc): $out"
  assert_contains "$out" "work identity integrity failure in secondmate integrity" \
    "parent did not propagate the delegated ownership preflight failure"
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" \
    handoff-cancel "$guarded" --file - >/dev/null \
    || fail "could not cancel omitted delegated ownership fixture"

  sidecar="$mate/data/$task/work-identity.json"
  jq -S -c '.work_units[0].id="stale-delegated-unit"' "$sidecar" > "$mate/changed.json"
  mv "$mate/changed.json" "$sidecar"
  rc=0
  out=$(FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "parent published a fallback snapshot for stale delegated identity state"
  assert_contains "$out" "work identity integrity failure in secondmate integrity" \
    "parent did not propagate the delegated identity integrity failure"
  pass "delegated linked integrity failures stop parent publication"
}

test_schema_maximum_delegated_identities_are_streamed_once() {
  local parent mate fakebin canonical task manifest i stream fake_ssh remote_calls
  local -a identity_tasks
  parent=$(make_home maximum-parent)
  mate="$TMP_ROOT/maximum-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'maximum\n' > "$mate/.fm-secondmate-home"
  printf -- '- maximum - maximum identity domain (home: %s; scope: maximum work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  printf '## In flight\n\n## Queued\n' > "$mate/data/backlog.md"
  identity_tasks=()
  i=1
  while [ "$i" -le 20 ]; do
    task=$(printf 'maximum-child-%02d' "$i")
    identity_tasks+=("$task")
    manifest="$mate/$task.json"
    make_max_manifest "$mate" "$task" "$manifest"
    FM_HOME="$mate" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
    printf -- '- [ ] %s - Maximum identity decision (repo: firstmate) (kind: captain) (hold: maximum exact choice pending) (hold-kind: captain)\n' "$task" \
      >> "$mate/data/backlog.md"
    i=$((i + 1))
  done
  printf '\n## Done\n' >> "$mate/data/backlog.md"
  stream=$(FM_HOME="$mate" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --secondmate-home-identity-stream "${identity_tasks[@]}") \
    || fail "schema-maximum identity stream failed"
  printf '%s\n' "$stream" | jq -s -e '
    length == 21
      and .[0].schema == "fm-secondmate-home-identity-stream.v1"
      and .[1].task_id == "maximum-child-01"
      and .[-1].task_id == "maximum-child-20"
      and (.[1:] | map(.task_id) | unique | length) == 20
      and all(.[1:][].work_identity; .status == "linked")
  ' >/dev/null || fail "schema-maximum identity stream envelope or order was malformed"
  fakebin=$(make_fakebin "$parent/fakes")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SNAPSHOT_SECONDMATE_TIMEOUT=120 \
    FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "maximum")
    | .provenance.selected == "structured-home"
      and (.decisions_open | length) == 20
      and (.holds | length) == 20
      and (.queued | length) == 20
      and (.work_identities | length) == 20
      and ([.work_identities[].task_id] | unique | length) == 20
      and all(.decisions_open[]; has("work_identity") | not)
      and all(.holds[]; has("work_identity") | not)
      and all(.queued[]; has("work_identity") | not)
      and (.work_identities[] | select(.task_id == "maximum-child-20") | .work_identity
        | (.work_units | length) == 20 and (.sources | length) == 20
          and (.work_units[-1].label | length) == 160
          and (.sources[-1].id | length) == 240)
  ' >/dev/null || fail "schema-maximum delegated identities were repeated, truncated, or suppressed: $(printf '%s' "$canonical" | jq -c '.secondmate_current.records[] | select(.id == "maximum") | {current,provenance,decisions:(.decisions_open|length),holds:(.holds|length),queued:(.queued|length),identities:(.work_identities|length),counts,omitted}')"

  printf -- '- maximum - maximum identity domain (host: maximum-remote; root: %s; home: %s; scope: maximum work; projects: firstmate; added 2026-08-14)\n' \
    "$ROOT" "$mate" > "$parent/data/secondmates.md"
  fake_ssh="$parent/fakes/fake-ssh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
n=${#args[@]}
home_b64=${args[$((n - 2))]}
argv_b64=${args[$((n - 1))]}
decode() {
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    printf '%s' "$1" | base64 -D
  else
    printf '%s' "$1" | base64 --decode
  fi
}
remote_home=$(decode "$home_b64") || exit 64
argv_file="$FM_TEST_REMOTE_TMP/argv.$$"
out_file="$FM_TEST_REMOTE_TMP/out.$$"
decode "$argv_b64" > "$argv_file" || exit 64
argv=()
while IFS= read -r -d '' value; do argv+=("$value"); done < "$argv_file"
rm -f "$argv_file"
[ "${#argv[@]}" -gt 0 ] || exit 64
if [ "${argv[1]:-}" = --secondmate-home-identity-stream ]; then
  printf 'page\n' >> "$FM_TEST_REMOTE_CALLS"
fi
rc=0
env -i PATH="$PATH" HOME="${HOME:-}" FM_HOME="$remote_home" \
  FM_ROOT_OVERRIDE="$FM_TEST_ROOT" \
  "$FM_TEST_ROOT/bin/${argv[0]}" "${argv[@]:1}" > "$out_file" || rc=$?
head -c 1048576 "$out_file"
rm -f "$out_file"
exit "$rc"
SH
  chmod +x "$fake_ssh"
  : > "$parent/remote-calls"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SSH_BIN="$fake_ssh" \
    FM_TEST_ROOT="$ROOT" FM_TEST_REMOTE_TMP="$parent" \
    FM_TEST_REMOTE_CALLS="$parent/remote-calls" \
    FM_SNAPSHOT_SECONDMATE_IDENTITY_MAX_BYTES=300000 \
    FM_SNAPSHOT_SECONDMATE_TIMEOUT=120 \
    FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json) \
    || fail "paged remote identity projection failed"
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "maximum")
    | .provenance.selected == "structured-home"
      and (.work_identities | length) == 20
      and all(.work_identities[].work_identity; .status == "linked")
  ' >/dev/null || fail "paged remote projection lost schema-maximum identities: $canonical"
  remote_calls=$(wc -l < "$parent/remote-calls" | tr -d ' ')
  [ "$remote_calls" -gt 1 ] || fail "remote projection did not page below its bounded transport"
  pass "schema-maximum delegated identities use bounded remote pages"
}

test_secondmate_deadlines_are_isolated_per_home() {
  local parent slow healthy task fakebin fake_ssh deadline_marker canonical
  parent=$(make_home isolated-deadline-parent)
  slow="$TMP_ROOT/isolated-deadline-slow"
  healthy="$TMP_ROOT/isolated-deadline-healthy"
  task='healthy-delegated-child'
  mkdir -p "$slow/data" "$slow/state" "$slow/config" "$slow/projects" \
    "$healthy/data" "$healthy/state" "$healthy/config" "$healthy/projects"
  printf 'a-slow\n' > "$slow/.fm-secondmate-home"
  printf 'z-healthy\n' > "$healthy/.fm-secondmate-home"
  printf '# Firstmate fixture\n' > "$slow/AGENTS.md"
  printf '# Firstmate fixture\n' > "$healthy/AGENTS.md"
  cat > "$slow/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  cat > "$healthy/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $task - Healthy exact projection (repo: firstmate) (kind: ship)

## Done
EOF
  cat > "$parent/data/secondmates.md" <<EOF
- a-slow - slow domain (host: slow-remote; root: $ROOT; home: $slow; scope: slow work; projects: firstmate; added 2026-08-14)
- z-healthy - healthy domain (host: healthy-remote; root: $ROOT; home: $healthy; scope: healthy work; projects: firstmate; added 2026-08-14)
EOF
  fakebin=$(make_fakebin "$parent/fakes")
  deadline_marker="$parent/first-home-failed"
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = +%s ]; then
  if [ -e "${FM_TEST_DEADLINE_MARKER:?}" ]; then printf '2000\n'; else printf '1000\n'; fi
  exit 0
fi
exec /bin/date "$@"
SH
  fake_ssh="$fakebin/fake-ssh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
n=${#args[@]}
home_b64=${args[$((n - 2))]}
argv_b64=${args[$((n - 1))]}
decode() {
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    printf '%s' "$1" | base64 -D
  else
    printf '%s' "$1" | base64 --decode
  fi
}
remote_home=$(decode "$home_b64") || exit 64
argv_file="${FM_TEST_DEADLINE_TMP:?}/deadline-argv.$$"
decode "$argv_b64" > "$argv_file" || exit 64
argv=()
while IFS= read -r -d '' value; do argv+=("$value"); done < "$argv_file"
rm -f "$argv_file"
[ "${#argv[@]}" -gt 0 ] || exit 64
if [ "$remote_home" = "${FM_TEST_SLOW_HOME:?}" ] \
  && [ "${argv[1]:-}" = --secondmate-home-summary ]; then
  : > "${FM_TEST_DEADLINE_MARKER:?}"
  exit 124
fi
env -i PATH="$PATH" HOME="${HOME:-}" FM_HOME="$remote_home" \
  FM_ROOT_OVERRIDE="${FM_TEST_ROOT:?}" \
  FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1786708800 \
  "$FM_TEST_ROOT/bin/${argv[0]}" "${argv[@]:1}"
SH
  chmod +x "$fakebin/date" "$fake_ssh"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SSH_BIN="$fake_ssh" \
    FM_TEST_ROOT="$ROOT" FM_TEST_SLOW_HOME="$slow" FM_TEST_DEADLINE_TMP="$parent" \
    FM_TEST_DEADLINE_MARKER="$deadline_marker" FM_SNAPSHOT_SECONDMATE_TIMEOUT=15 \
    FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1786708800 \
    "$SNAPSHOT" --json) || fail "isolated secondmate deadline snapshot failed"
  printf '%s' "$canonical" | jq -e --arg task "$task" '
    (.secondmate_current.records[] | select(.id == "a-slow")
      | .current.state == "unknown")
    and (.secondmate_current.records[] | select(.id == "z-healthy")
      | .provenance.selected == "structured-home"
        and ([.queued[] | select(.id == $task and .work_identity_ref == $task)] | length) == 1
        and ([.work_identities[] | select(.task_id == $task)
          | .work_identity.status == "unlinked"] | length) == 1)
  ' >/dev/null || fail "an earlier failed route suppressed a healthy later identity projection: $canonical"
  pass "secondmate summary and identity deadlines are isolated per home"
}

test_bearings_preserves_complete_identity_references() {
  local home task manifest wt fakebin bearings hash gen last_unit last_source
  home=$(make_home complete-refs)
  task=complete-reference-worker
  manifest="$home/manifest.json"
  wt="$home/worktree"
  mkdir -p "$wt"
  make_max_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  write_bound_meta "$home" "$task" "$wt"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$task" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $task - Complete reference worker (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home/fakes")
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  last_unit=$(jq -r '.work_units[-1].id' "$manifest")
  last_source=$(jq -r '.sources[-1].id' "$manifest")
  printf '%s' "$bearings" | jq -e --arg unit "$last_unit" --arg source "$last_source" '
    .in_flight[] | select(.id == "complete-reference-worker")
    | .work_identity == "linked"
      and (.work_units | contains($unit))
      and (.sources | contains($source))
      and (.work_units | length) > 600
      and (.sources | length) > 600
  ' >/dev/null || fail "Bearings truncated later exact work-unit or source references: $bearings"
  hash=$(sha256_file_for_test "$home/data/$task/work-identity.json")
  [ -n "$hash" ] || fail "complete reference fixture lost its canonical sidecar"
  pass "Bearings preserves complete IDs and labels for every bounded worker row"
}

test_display_labels_cannot_spoof_exact_references() {
  local home task manifest wt fakebin bearings view expected gen
  home=$(make_home escaped-labels)
  task=escaped-label-worker
  manifest="$home/manifest.json"
  wt="$home/worktree"
  mkdir -p "$wt"
  make_manifest "$home" "$task" "$manifest"
  jq '.work_units[0].label="Friendly]; work-aligner:work-unit:fake [Fake"' \
    "$manifest" > "$home/escaped.json"
  record_and_brief "$home" "$task" "$home/escaped.json"
  write_bound_meta "$home" "$task" "$wt"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$task" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'working: escaped label projection\n' > "$home/state/$task.status"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $task - Escaped label worker (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home/fakes")
  expected='work-aligner:work-unit:wu-exact-intake [Friendly\]\; work-aligner:work-unit:fake \[Fake]'
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z \
    "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e --arg expected "$expected" '
    .in_flight[] | select(.id == "escaped-label-worker") | .work_units == $expected
  ' >/dev/null || fail "Bearings did not escape identity-reference delimiters in display labels: $bearings"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$FLEET_VIEW")
  assert_contains "$view" "$expected" \
    "fleet view did not escape identity-reference delimiters in display labels"
  pass "display labels cannot masquerade as additional exact identities"
}

test_handoff_rejects_unowned_identical_target_sidecar() {
  local source target task manifest transfer target_record out rc=0
  source=$(make_home unowned-sidecar-source)
  target=$(make_home unowned-sidecar-target)
  printf 'unowned-target\n' > "$target/.fm-secondmate-home"
  task=unowned-identical-target
  manifest="$source/manifest.json"
  make_manifest "$source" "$task" "$manifest"
  FM_HOME="$source" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  transfer=$(FM_HOME="$source" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$target" --to-home-id secondmate:unowned-target)
  target_record=$(printf '%s' "$transfer" | jq -S -c '.identity.record')
  mkdir -p "$target/data/$task"
  printf '%s\n' "$target_record" > "$target/data/$task/work-identity.json"
  out=$(printf '%s\n' "$transfer" | FM_HOME="$target" "$WORK_IDENTITY" \
    handoff-stage "$task" --file - 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unowned identical target sidecar was accepted as a staged transfer"
  assert_contains "$out" "unowned linked record" \
    "identical target sidecar refusal did not identify missing transfer ownership"
  printf '%s\n' "$transfer" | FM_HOME="$target" "$WORK_IDENTITY" \
    handoff-abort "$task" --file - >/dev/null \
    || fail "unowned target sidecar was mistaken for a committed transfer during abort"
  printf '%s\n' "$transfer" | FM_HOME="$source" "$WORK_IDENTITY" \
    handoff-cancel "$task" --file - >/dev/null \
    || fail "source ownership could not cancel after unowned target refusal"
  assert_absent "$target/data/$task/work-identity-handoff-target.json" \
    "unowned target refusal published a transfer receipt"
  FM_HOME="$source" "$WORK_IDENTITY" verify "$task" | jq -e '.status == "linked"' >/dev/null \
    || fail "unowned target refusal damaged source ownership"
  pass "identical target sidecars require a pre-existing exact transfer receipt"
}

test_secondmate_parent_decisions_and_nested_caps_are_disclosed() {
  local parent mate fakebin child gen bearings
  parent=$(make_home capped-parent)
  mate="$TMP_ROOT/capped-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'capped\n' > "$mate/.fm-secondmate-home"
  printf -- '- capped - capped domain (home: %s; scope: capped work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/capped.meta" "$mate" "firstmate:fm-capped" firstmate codex
  printf 'needs-decision [key=stale-parent]: stale parent-only choice\n' > "$parent/state/capped.status"
  printf '## In flight\n' > "$mate/data/backlog.md"
  for child in capped-child-a capped-child-b; do
    mkdir -p "$mate/projects/$child"
    fm_write_meta "$mate/state/$child.meta" \
      "window=firstmate:fm-$child" "worktree=$mate/projects/$child" "project=firstmate" \
      "harness=claude" "kind=ship" "mode=no-mistakes"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$child")
    "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$child" busy --gen "$gen" \
      --source claude-hook --event user-prompt-submit
    printf 'working: %s\n' "$child" > "$mate/state/$child.status"
    printf -- '- [ ] %s - Capped delegated child (repo: firstmate) (kind: ship) (since 2026-08-14)\n' \
      "$child" >> "$mate/data/backlog.md"
  done
  for child in capped-decision-a capped-decision-b; do
    mkdir -p "$mate/projects/$child"
    fm_write_meta "$mate/state/$child.meta" \
      "window=firstmate:fm-$child" "worktree=$mate/projects/$child" "project=firstmate" \
      "harness=claude" "kind=ship" "mode=no-mistakes"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$child")
    "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$child" idle --gen "$gen" \
      --source claude-hook --event stop
    printf 'needs-decision [key=%s]: choose capped option\n' "$child" > "$mate/state/$child.status"
    printf -- '- [ ] %s - Capped delegated decision (repo: firstmate) (kind: ship) (since 2026-08-14)\n' \
      "$child" >> "$mate/data/backlog.md"
  done
  cat >> "$mate/data/backlog.md" <<'EOF'

## Queued
- [ ] capped-gate-a - Capped gate A blocked-by: external-a - external dependency A (repo: firstmate) (kind: ship)
- [ ] capped-gate-b - Capped gate B blocked-by: external-b - external dependency B (repo: firstmate) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$parent/fakes")
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_BEARINGS_NOW=2026-08-14T12:00:00Z \
    FM_SNAPSHOT_SECONDMATE_CHILDREN=1 FM_SNAPSHOT_SECONDMATE_DECISIONS=1 \
    FM_SNAPSHOT_SECONDMATE_QUEUED=1 "$BEARINGS" --json --all-in-flight \
      --all-decisions --all-queued)
  printf '%s' "$bearings" | jq -e '
    ([.decisions_open[] | select(.id == "capped" and .owner == "(main)")] | length) == 0
      and ([.delegated_work[] | select(.owner == "capped")] | length) == 1
      and ([.decisions_open[] | select(.owner == "capped")] | length) == 1
      and ([.gates[] | select(.owner == "capped")] | length) == 1
      and ([.omitted[] | select(
        .surface == "delegated_work omitted by structured-home cap for capped: 1"
        and .reveal == "raise FM_SNAPSHOT_SECONDMATE_CHILDREN")] | length) == 1
      and ([.omitted[] | select(
        .surface == "decisions_open omitted by structured-home cap for capped: 1"
        and .reveal == "raise FM_SNAPSHOT_SECONDMATE_DECISIONS")] | length) == 1
      and ([.omitted[] | select(
        (.surface | startswith("delegated holds omitted by structured-home cap for capped: "))
        and .reveal == "raise FM_SNAPSHOT_SECONDMATE_QUEUED")] | length) == 1
      and ([.omitted[] | select(
        .surface == "gates omitted by structured-home cap for capped: 1"
        and .reveal == "raise FM_SNAPSHOT_SECONDMATE_QUEUED")] | length) == 1
  ' >/dev/null || fail "Bearings trusted a parent decision or hid a nested cap: $bearings"
  pass "Bearings excludes parent decisions and discloses nested surface caps"
}

case "${FM_TEST_ONLY:-}" in
  intake-through-fleet)
    test_intake_through_fleet_projection
    test_spawn_delivers_validated_brief_snapshot
    exit 0
    ;;
  owned-removal)
    test_owned_replace_refuses_changed_unsafe_destination
    test_owned_removal_bounds_digest_after_concurrent_growth
    exit 0
    ;;
  owned-snapshot)
    test_owned_snapshot_binds_validated_entry
    exit 0
    ;;
  replacement-publication)
    test_replacement_dispatch_recovers_prior_retirement
    test_replacement_dispatch_resumes_before_metadata_publication
    exit 0
    ;;
  dispatch-retirement)
    test_dispatch_transaction_excludes_backlog_handoff
    test_dispatch_retire_run_authorizes_task_set
    test_dispatch_retire_run_refuses_invalid_set_without_quarantine
    test_dispatch_retire_run_accepts_whole_home_removal
    test_dispatch_retire_run_recovers_completed_command
    test_dispatch_retire_run_refuses_changed_record_without_partial_retirement
    test_dispatch_retire_run_preserves_failed_siblings
    test_dispatch_retire_run_rejects_duplicate_tasks
    exit 0
    ;;
  no-clobber-recovery)
    test_no_clobber_publications_recover_after_interruption
    test_no_clobber_conflict_retires_owned_transaction
    test_no_clobber_journal_rejects_unrelated_staging
    test_no_clobber_publication_does_not_follow_raced_target
    exit 0
    ;;
  secondmate-deadlines)
    test_secondmate_deadlines_are_isolated_per_home
    exit 0
    ;;
  handoff-short-read)
    test_handoff_receiver_reads_chunked_transfer_to_eof
    exit 0
    ;;
  handoff-rebinding)
    test_handoff_rebinds_identity_and_decision_surfaces
    exit 0
    ;;
  contract-validation)
    test_namespace_separation_and_contract_rejections
    test_unsafe_files_labels_and_exact_binding
    test_stale_and_changed_relations_refuse
    test_legacy_and_fuzzy_fallbacks_are_unlinked
    exit 0
    ;;
  delegated-projections)
    test_delegated_secondmate_projection
    test_handoff_rebinds_identity_and_decision_surfaces
    test_delegated_integrity_failure_stops_parent_publication
    test_schema_maximum_delegated_identities_are_streamed_once
    test_secondmate_deadlines_are_isolated_per_home
    test_bearings_preserves_complete_identity_references
    test_display_labels_cannot_spoof_exact_references
    test_secondmate_parent_decisions_and_nested_caps_are_disclosed
    exit 0
    ;;
  owned-replace-source)
    test_owned_replace_refuses_a_changing_source
    test_no_clobber_refuses_a_preopen_source_mutation
    exit 0
    ;;
esac

test_intake_through_fleet_projection
test_spawn_delivers_validated_brief_snapshot
test_sidecar_validation_hashes_captured_bytes
test_manifest_capture_rejects_same_size_rewrite
test_concurrent_idempotence_and_explicit_unlinked
test_secondmate_unlinked_reservation_is_transactional
test_no_clobber_publications_recover_after_interruption
test_no_clobber_conflict_retires_owned_transaction
test_no_clobber_journal_rejects_unrelated_staging
test_no_clobber_publication_does_not_follow_raced_target
test_owned_replace_refuses_changed_unsafe_destination
test_owned_replace_refuses_a_changing_source
test_no_clobber_refuses_a_preopen_source_mutation
test_owned_removal_bounds_digest_after_concurrent_growth
test_owned_snapshot_binds_validated_entry
test_identity_lock_refuses_replaced_storage_parent
test_identity_lock_refuses_unsafe_lock_entry_without_waiting
test_identity_lock_reclaims_reused_pid_owner
test_projection_serializes_identity_ownership
test_handoff_receipts_require_owning_task
test_dispatch_transaction_excludes_backlog_handoff
test_dispatch_retire_run_authorizes_task_set
test_dispatch_retire_run_refuses_invalid_set_without_quarantine
test_dispatch_retire_run_accepts_whole_home_removal
test_dispatch_retire_run_recovers_completed_command
test_dispatch_retire_run_refuses_changed_record_without_partial_retirement
test_dispatch_retire_run_preserves_failed_siblings
test_dispatch_retire_run_rejects_duplicate_tasks
test_spawn_recovers_exact_created_endpoint
test_spawn_recovers_creation_intent_after_endpoint_side_effect
test_spawn_resumes_unsent_worktree_request
test_spawn_does_not_resend_inflight_worktree_request
test_zellij_resumes_unsent_worktree_request_once
test_treehouse_request_reconciles_exact_failed_lease
test_pre_metadata_dispatch_reuses_exact_prepared_receipt
test_dispatch_publish_refuses_unstable_metadata_without_publication
test_replacement_dispatch_recovers_prior_retirement
test_replacement_dispatch_resumes_before_metadata_publication
test_unlinked_reservation_blocks_late_intake
test_metadata_validation_uses_one_stable_capture
test_snapshot_preflight_and_dispatch_recovery
test_namespace_separation_and_contract_rejections
test_unsafe_files_labels_and_exact_binding
test_stale_and_changed_relations_refuse
test_legacy_and_fuzzy_fallbacks_are_unlinked
test_delegated_secondmate_projection
test_handoff_rebinds_identity_and_decision_surfaces
test_completed_unlinked_handoff_accepts_exact_intake
test_missing_state_directory_is_created_before_locking
test_handoff_receiver_reads_chunked_transfer_to_eof
test_handoff_preparation_is_durable_and_rollback_safe
test_handoff_rejects_unowned_identical_target_sidecar
test_unsafe_publication_setup_uses_integrity_exit
test_delegated_integrity_failure_stops_parent_publication
test_schema_maximum_delegated_identities_are_streamed_once
test_secondmate_deadlines_are_isolated_per_home
test_bearings_preserves_complete_identity_references
test_display_labels_cannot_spoof_exact_references
test_secondmate_parent_decisions_and_nested_caps_are_disclosed
