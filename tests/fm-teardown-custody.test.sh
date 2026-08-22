#!/usr/bin/env bash
# Distinguishing tests for bin/fm-teardown.sh's open-PR watch and worktree
# occupancy custody guards.
#
# The open-PR guard refuses to retire metadata or PR-poll artifacts while the
# canonical recorded pr= is OPEN, unreadable, or otherwise unproven, unless an
# identity-bound replacement watch already covers that same repository and PR,
# or a narrowly named acknowledgement carries a nonempty reason that is staged
# during preflight and written only after later refusal gates pass.
# A random check.sh is not replacement proof.
#
# The occupancy guard refuses to inspect, close, reap, reset, or return a
# pooled path whose current treehouse lease or slot identity belongs to a
# different task. Path equality is not ownership. Available occupancy or a
# missing path with a live endpoint preserves custody records. Pre-schema
# writer metadata can complete through live occupancy without rewriting the
# old record.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-custody)
PR_URL='https://github.com/example/repo/pull/7'

write_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  count=0
  [ ! -f "${FM_FAKE_TREEHOUSE_STATUS_COUNT:-}" ] \
    || count=$(cat "$FM_FAKE_TREEHOUSE_STATUS_COUNT")
  count=$((count + 1))
  [ -z "${FM_FAKE_TREEHOUSE_STATUS_COUNT:-}" ] \
    || printf '%s\n' "$count" > "$FM_FAKE_TREEHOUSE_STATUS_COUNT"
  rc=${FM_FAKE_TREEHOUSE_STATUS_RC:-0}
  if [ -n "${FM_FAKE_TREEHOUSE_STATUS_FILE:-}" ] \
     && [ -f "$FM_FAKE_TREEHOUSE_STATUS_FILE" ]; then
    cat "$FM_FAKE_TREEHOUSE_STATUS_FILE"
  elif [ -n "${FM_FAKE_TREEHOUSE_REBOUND_JSON:-}" ] \
     && [ "$count" -ge "${FM_FAKE_TREEHOUSE_REBOUND_AT:-999999}" ]; then
    printf '%s\n' "$FM_FAKE_TREEHOUSE_REBOUND_JSON"
  elif [ -n "${FM_FAKE_TREEHOUSE_STATUS_JSON:-}" ]; then
    printf '%s\n' "$FM_FAKE_TREEHOUSE_STATUS_JSON"
  fi
  exit "$rc"
fi
if [ "${1:-}" = return ]; then
  printf 'treehouse' >> "${FM_FAKE_TREEHOUSE_LOG:?}"
  printf ' <%s>' "$@" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
  printf '\n' >> "${FM_FAKE_TREEHOUSE_LOG:?}"
  shift
  wt=""
  lease_id=""
  lease_holder=""
  while [ "$#" -gt 0 ]; do
    a=$1
    shift
    case "$a" in
      --force) ;;
      --if-lease-id) lease_id=${1:-}; shift ;;
      --if-lease-holder) lease_holder=${1:-}; shift ;;
      *) wt=$a ;;
    esac
  done
  current=$(jq -r --arg path "$wt" '.[] | select(.path==$path) | [.lease_id,.lease_holder] | @tsv' \
    "${FM_FAKE_TREEHOUSE_STATUS_FILE:?}")
  [ "$current" = "$lease_id"$'\t'"$lease_holder" ] || exit 1
  git -C "$wt" checkout --detach -q main
  git -C "$wt" reset --hard -q main
  git -C "$wt" clean -fdq
  jq --arg path "$wt" '. |= map(if .path==$path then
    .status="available" | .lease_id="" | .lease_holder=""
  else . end)' "$FM_FAKE_TREEHOUSE_STATUS_FILE" > "$FM_FAKE_TREEHOUSE_STATUS_FILE.tmp"
  mv "$FM_FAKE_TREEHOUSE_STATUS_FILE.tmp" "$FM_FAKE_TREEHOUSE_STATUS_FILE"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

write_runtime_stubs() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_FAKE_TMUX_LOG:?}"
printf ' <%s>' "$@" >> "${FM_FAKE_TMUX_LOG:?}"
printf '\n' >> "${FM_FAKE_TMUX_LOG:?}"
if [ "${FM_FAKE_TMUX_ENDPOINT_GONE:-0}" = 1 ]; then
  case "${1:-}" in
    list-windows|has-session)
      echo "can't find session: firstmate" >&2
      exit 1
      ;;
  esac
fi
if [ "${FM_FAKE_TMUX_LIVE:-0}" = 1 ]; then
  case "$*" in
    *"#{pane_current_command}"*)
      printf 'claude\n'
      exit 0
      ;;
  esac
  case "${1:-}" in
    list-windows)
      printf '%s\n' "${FM_FAKE_TMUX_WINDOW_NAME:-fm-task-x1}"
      exit 0
      ;;
  esac
fi
[ -z "${FM_FAKE_TMUX_SIGNAL:-}" ] || : > "$FM_FAKE_TMUX_SIGNAL"
[ -z "${FM_FAKE_WORKTREE:-}" ] || rm -f "$FM_FAKE_WORKTREE/live-agent"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --json state "*)
    [ "${FM_FAKE_GH_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_FAKE_GH_STATE:-OPEN}"
    exit 0
    ;;
esac
echo "error: unsupported gh fixture call" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/gh" \
    "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/no-mistakes"
}

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/project"
  write_treehouse "$case_dir"
  write_runtime_stubs "$case_dir"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  : > "$case_dir/wt/sentinel"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/tmux.log"
  : > "$case_dir/treehouse-status-count"
  touch "$case_dir/home/state/.last-watcher-beat"
  FM_FAKE_TMUX_LIVE=0
  FM_FAKE_TMUX_ENDPOINT_GONE=0
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_GH_FAIL=0
  FM_FAKE_TREEHOUSE_STATUS_RC=0
  FM_FAKE_TREEHOUSE_REBOUND_JSON=
  FM_FAKE_TREEHOUSE_REBOUND_AT=999999
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1 id=$2 wt=$3
  shift 3
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "$@"
  chmod 0600 "$case_dir/home/state/$id.meta"
}

status_json_for() {
  local path=$1 status=$2 lease_id=$3 holder=$4 name=${5:-slot-1}
  python3 - "$path" "$status" "$lease_id" "$holder" "$name" <<'PY'
import json, sys
path, status, lease_id, holder, name = sys.argv[1:6]
print(json.dumps([{
    "name": name,
    "path": path,
    "status": status,
    "lease_id": lease_id,
    "lease_holder": holder,
    "leased_at": None,
    "processes": [],
}]))
PY
}

run_teardown() {
  local case_dir=$1 id=$2
  shift 2
  printf '%s\n' "${FM_FAKE_TREEHOUSE_STATUS_JSON:-[]}" > "$case_dir/treehouse-status.json"
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    FM_FAKE_TMUX_LOG="$case_dir/tmux.log" \
    FM_FAKE_GH_STATE="${FM_FAKE_GH_STATE:-OPEN}" \
    FM_FAKE_GH_FAIL="${FM_FAKE_GH_FAIL:-0}" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="${FM_FAKE_TREEHOUSE_STATUS_JSON:-}" \
    FM_FAKE_TREEHOUSE_STATUS_FILE="$case_dir/treehouse-status.json" \
    FM_FAKE_TREEHOUSE_STATUS_RC="${FM_FAKE_TREEHOUSE_STATUS_RC:-0}" \
    FM_FAKE_TREEHOUSE_STATUS_COUNT="$case_dir/treehouse-status-count" \
    FM_FAKE_TREEHOUSE_REBOUND_JSON="${FM_FAKE_TREEHOUSE_REBOUND_JSON:-}" \
    FM_FAKE_TREEHOUSE_REBOUND_AT="${FM_FAKE_TREEHOUSE_REBOUND_AT:-999999}" \
    FM_FAKE_TMUX_SIGNAL="${FM_FAKE_TMUX_SIGNAL:-}" \
    FM_FAKE_TMUX_LIVE="${FM_FAKE_TMUX_LIVE:-0}" \
    FM_FAKE_TMUX_ENDPOINT_GONE="${FM_FAKE_TMUX_ENDPOINT_GONE:-0}" \
    FM_FAKE_TMUX_WINDOW_NAME="${FM_FAKE_TMUX_WINDOW_NAME:-fm-task-x1}" \
    FM_FAKE_WORKTREE="$case_dir/wt" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

seed_canonical_poll() {
  local case_dir=$1 id=$2 url=$3 state
  state="$case_dir/home/state"
  fm_pr_url_parse "$url" || fail "poll fixture URL was invalid"
  fm_pr_poll_prepare "$state" "$id" "$FM_PR_PROVIDER" "$url" "$FM_PR_HOST" \
    "$FM_PR_PATH" "$FM_PR_NUMBER" "$POLL" \
    || fail "could not prepare poll fixture"
  fm_pr_poll_publish_prepared || fail "could not publish poll fixture"
}

assert_untouched_watch() {
  local case_dir=$1 id=$2
  assert_present "$case_dir/home/state/$id.meta" "metadata was retired"
  assert_present "$case_dir/home/state/$id.check.sh" "watch check was retired"
  assert_present "$case_dir/home/state/$id.pr-poll" "watch sidecar was retired"
  assert_present "$case_dir/home/state/$id.pr-poll-registration" "watch registration was retired"
}

assert_no_treehouse_return() {
  local case_dir=$1
  if grep -F 'treehouse <return>' "$case_dir/treehouse.log" >/dev/null 2>&1; then
    fail "treehouse return ran: $(cat "$case_dir/treehouse.log")"
  fi
}

assert_no_tmux_kill() {
  local case_dir=$1
  if grep -F 'kill-window' "$case_dir/tmux.log" >/dev/null 2>&1; then
    fail "endpoint kill ran: $(cat "$case_dir/tmux.log")"
  fi
}

make_mutant() {
  local variant=$1 variant_root script
  variant_root="$TMP_ROOT/mutants/$variant"
  mkdir -p "$variant_root"
  cp -R "$ROOT/bin" "$variant_root/"
  script="$variant_root/bin/fm-teardown.sh"
  python3 - "$script" "$variant" <<'PY' || return 1
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
variant = sys.argv[2]
mutations = {
    "omit-open-pr-guard": [(
        "teardown_refuse_open_pr_without_watch || exit 1\n",
        "",
    )],
    "omit-occupancy": [
        (
            "teardown_prove_worktree_occupancy || exit 1\n",
            "TEARDOWN_WORKTREE_OWNED=1\nTEARDOWN_WORKTREE_STALE=0\n",
        ),
        (
            "  teardown_prove_worktree_occupancy || return 1\n",
            "  return 0\n",
        ),
    ],
    "path-only-occupancy": [
        (
            '    if teardown_occupancy_identity_mismatch \\\n',
            '    if false && teardown_occupancy_identity_mismatch \\\n',
        ),
        (
            '    if ! teardown_occupancy_identity_matches \\\n',
            '    if false && ! teardown_occupancy_identity_matches \\\n',
        ),
        (
            '  if teardown_other_task_claims_worktree "$abs"; then\n',
            '  if false && teardown_other_task_claims_worktree "$abs"; then\n',
        ),
    ],
    "presence-only-watch": [(
        "    fm_pr_poll_artifacts_valid \"$STATE\" \"$other_id\" \"$SCRIPT_DIR/fm-pr-poll.sh\" || continue\n",
        "    [ -e \"$STATE/$other_id.check.sh\" ] || continue\n    return 0\n",
    )],
    "wrong-pr-watch": [(
        '    [ "$FM_PR_REG_NUMBER" = "$want_number" ] || continue\n',
        '    true\n',
    )],
}

if variant not in mutations:
    raise SystemExit(f"unknown custody mutant: {variant}")
text = path.read_text()
for old, new in mutations[variant]:
    if text.count(old) != 1:
        raise SystemExit(f"custody mutant {variant} matched {text.count(old)} times for {old!r}")
    text = text.replace(old, new)
path.write_text(text)
PY
  printf '%s\n' "$script"
}

land_task_worktree() {
  local case_dir=$1
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "landed"
  git -C "$case_dir/project" update-ref refs/heads/main \
    "$(git -C "$case_dir/wt" rev-parse HEAD)"
  rm -f "$case_dir/wt/sentinel"
}

test_open_pr_refuses_and_preserves_watch() {
  local case_dir wt_abs rc
  case_dir=$(make_case open-pr-refuse)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    "pr=$PR_URL"
  land_task_worktree "$case_dir"
  seed_canonical_poll "$case_dir" task-x1 "$PR_URL"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "open PR teardown unexpectedly succeeded"
  assert_contains "$(cat "$case_dir/stderr")" "open PR" "open PR refusal was not actionable"
  assert_untouched_watch "$case_dir" task-x1
  assert_no_treehouse_return "$case_dir"
  pass "open PR teardown refuses and preserves metadata and watch"
}

test_merged_and_closed_pr_progress() {
  local case_dir state wt_abs rc
  for state in MERGED CLOSED; do
    case_dir=$(make_case "pr-state-$(printf '%s\n' "$state" | tr '[:upper:]' '[:lower:]')")
    write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
      kind=ship mode=local-only \
      treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
      "pr=$PR_URL"
    land_task_worktree "$case_dir"
    seed_canonical_poll "$case_dir" task-x1 "$PR_URL"
    wt_abs=$(cd "$case_dir/wt" && pwd -P)
    FM_FAKE_GH_STATE=$state
    FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
    rc=0
    run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$state PR teardown failed: $(cat "$case_dir/stderr")"
    assert_absent "$case_dir/home/state/task-x1.meta" "$state PR left metadata"
    assert_absent "$case_dir/home/state/task-x1.check.sh" "$state PR left watch check"
    assert_absent "$case_dir/home/state/task-x1.pr-poll" "$state PR left watch sidecar"
  done
  pass "MERGED and CLOSED recorded PRs allow watch and metadata retirement"
}

test_identity_bound_replacement_watch_progress() {
  local case_dir missing rc
  case_dir=$(make_case replacement-watch)
  missing="$case_dir/missing-wt"
  write_task_meta "$case_dir" task-x1 "$missing" \
    kind=ship mode=local-only \
    treehouse_slot=slot-stale treehouse_lease=lease-stale \
    "pr=$PR_URL"
  write_task_meta "$case_dir" review-pr79-v1 "$case_dir/wt" \
    kind=ship mode=local-only "pr=$PR_URL"
  seed_canonical_poll "$case_dir" review-pr79-v1 "$PR_URL"
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TMUX_ENDPOINT_GONE=1
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$missing" available "" "" slot-stale)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "replacement-watch teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/home/state/task-x1.meta" "stale task metadata remained"
  assert_present "$case_dir/home/state/review-pr79-v1.pr-poll-registration" \
    "replacement watch was retired"
  assert_present "$case_dir/wt/sentinel" "replacement worktree was disturbed"
  pass "identity-bound replacement watch for the same PR lets stale cleanup proceed"
}

test_presence_only_and_wrong_pr_are_not_replacement() {
  local case_dir rc
  case_dir=$(make_case presence-only-check)
  write_task_meta "$case_dir" task-x1 "$case_dir/missing-wt" \
    kind=ship mode=local-only "pr=$PR_URL"
  write_task_meta "$case_dir" other-task "$case_dir/wt" kind=ship mode=local-only
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/home/state/other-task.check.sh"
  chmod 0700 "$case_dir/home/state/other-task.check.sh"
  printf 'not-an-identity-bound-poll\n' > "$case_dir/home/state/other-task.pr-poll-registration"
  chmod 0600 "$case_dir/home/state/other-task.pr-poll-registration"
  FM_FAKE_GH_STATE=OPEN
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "a random check.sh was treated as replacement watch"
  assert_present "$case_dir/home/state/task-x1.meta" "presence-only teardown retired metadata"

  case_dir=$(make_case wrong-pr-registration)
  write_task_meta "$case_dir" task-x1 "$case_dir/missing-wt" \
    kind=ship mode=local-only "pr=$PR_URL"
  write_task_meta "$case_dir" other-task "$case_dir/wt" \
    kind=ship mode=local-only 'pr=https://github.com/example/repo/pull/99'
  seed_canonical_poll "$case_dir" other-task 'https://github.com/example/repo/pull/99'
  FM_FAKE_GH_STATE=OPEN
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "a different PR registration was treated as replacement watch"
  assert_present "$case_dir/home/state/task-x1.meta" "wrong-PR teardown retired metadata"
  pass "presence-only checks and wrong-PR registrations are not replacement proof"
}

test_acknowledgement_reason_success_and_empty_refusal() {
  local case_dir wt_abs rc log
  case_dir=$(make_case ack-reason)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    "pr=$PR_URL"
  land_task_worktree "$case_dir"
  seed_canonical_poll "$case_dir" task-x1 "$PR_URL"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 \
    --acknowledge-open-pr-without-watch "captain discarded the abandoned PR watch" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "acknowledged open PR teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/home/state/task-x1.meta" "acknowledged teardown left metadata"
  log="$case_dir/home/data/teardown-open-pr-without-watch.jsonl"
  assert_present "$log" "acknowledgement was not durably recorded"
  grep -F 'captain discarded the abandoned PR watch' "$log" >/dev/null \
    || fail "acknowledgement record omitted the reason"

  case_dir=$(make_case ack-empty)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    "pr=$PR_URL"
  land_task_worktree "$case_dir"
  seed_canonical_poll "$case_dir" task-x1 "$PR_URL"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 --acknowledge-open-pr-without-watch "" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "empty acknowledgement reason was accepted"
  assert_present "$case_dir/home/state/task-x1.meta" "empty-reason teardown retired metadata"
  [ ! -e "$case_dir/home/data/teardown-open-pr-without-watch.jsonl" ] \
    || fail "empty-reason acknowledgement still wrote a durable record"
  pass "nonempty acknowledgement records and proceeds; empty reason refuses"
}

test_unreadable_pr_acknowledgement_progress() {
  local case_dir wt_abs rc log
  case_dir=$(make_case ack-unreadable-pr)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    'pr=not-a-canonical-pr'
  land_task_worktree "$case_dir"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 \
    --acknowledge-open-pr-without-watch "captain accepted unreadable recorded PR custody" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unreadable PR acknowledgement failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/home/state/task-x1.meta" \
    "unreadable acknowledged PR left metadata"
  log="$case_dir/home/data/teardown-open-pr-without-watch.jsonl"
  assert_present "$log" "unreadable PR acknowledgement was not recorded"
  jq -e 'select(.pr == "not-a-canonical-pr" and .reason == "captain accepted unreadable recorded PR custody")' \
    "$log" >/dev/null || fail "unreadable PR acknowledgement record lost its evidence"
  pass "unreadable recorded PR can proceed with a durable acknowledgement"
}

test_matching_lease_progress() {
  local case_dir wt_abs rc
  case_dir=$(make_case matching-lease)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "landed"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  rm -f "$case_dir/wt/sentinel"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "matching-lease teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/home/state/task-x1.meta" "matching-lease left metadata"
  grep -F 'treehouse <return>' "$case_dir/treehouse.log" >/dev/null \
    || fail "matching lease did not return its own worktree"
  pass "matching treehouse lease identity lets teardown return its own slot"
}

test_path_only_occupancy_cannot_replace_spawn_identity() {
  local case_dir wt_abs rc
  case_dir=$(make_case path-only-without-producer-identity)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" kind=ship mode=local-only
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use "" "" slot-1)
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "path equality replaced missing producer occupancy identity"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "path-only occupancy retired metadata without producer identity"
  assert_present "$case_dir/wt/sentinel" \
    "path-only occupancy mutated the worktree without producer identity"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"
  pass "path equality cannot replace writer acquisition identity"
}

test_already_cleaned_stale_metadata_is_noop() {
  local case_dir wt_abs rc task_tmp branch_before
  case_dir=$(make_case already-cleaned)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-old
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  branch_before=$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)
  : > "$case_dir/wt/live-agent"
  task_tmp="$case_dir/task-tmp"
  mkdir -p "$task_tmp"
  : > "$task_tmp/reused-endpoint-sentinel"
  printf 'tasktmp=%s\n' "$task_tmp" >> "$case_dir/home/state/task-x1.meta"
  FM_FAKE_TMUX_LIVE=1
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" available "" "")
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "available occupancy with a live endpoint retired custody"
  assert_present "$case_dir/home/state/task-x1.meta" "stale metadata was retired"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"
  assert_present "$case_dir/wt/sentinel" \
    "stale cleanup mutated the replacement worktree"
  assert_present "$case_dir/wt/live-agent" \
    "stale cleanup inspected or killed the replacement endpoint"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = "$branch_before" ] \
    || fail "stale cleanup changed the replacement branch"
  [ "$(jq -r '.[0] | [.status, .lease_id, .lease_holder] | @tsv' "$case_dir/treehouse-status.json")" = $'available\t\t' ] \
    || fail "stale cleanup changed the replacement occupancy record"
  assert_present "$task_tmp/reused-endpoint-sentinel" \
    "stale cleanup removed a task-temp root without live ownership"
  pass "available occupancy with a live endpoint preserves custody records"
}

test_missing_path_available_occupancy_with_live_endpoint_refuses() {
  local case_dir missing rc
  case_dir=$(make_case missing-path-live-endpoint)
  missing="$case_dir/missing-wt"
  write_task_meta "$case_dir" task-x1 "$missing" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-old
  : > "$case_dir/wt/live-agent"
  FM_FAKE_TMUX_LIVE=1
  FM_FAKE_TMUX_ENDPOINT_GONE=0
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$missing" available "" "" slot-1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "missing path plus available occupancy retired a live endpoint: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "missing-path available occupancy retired metadata while the endpoint was live"
  assert_no_tmux_kill "$case_dir"
  pass "missing path or available occupancy with a live endpoint refuses"
}

test_base_format_live_writer_teardown_completes() {
  local case_dir wt_abs rc
  case_dir=$(make_case base-format-live-writer)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" kind=ship mode=local-only
  land_task_worktree "$case_dir"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-live task-x1 slot-1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "base-format live writer teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/home/state/task-x1.meta" \
    "base-format live writer left metadata"
  grep -F 'treehouse <return>' "$case_dir/treehouse.log" >/dev/null \
    || fail "base-format live writer did not return its occupied slot"
  pass "base-format live writer metadata completes teardown without schema mutation"
}

test_post_ack_landed_work_refusal_writes_no_row() {
  local case_dir wt_abs rc log rows
  case_dir=$(make_case post-ack-unlanded)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    "pr=$PR_URL"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "unlanded"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 \
    --acknowledge-open-pr-without-watch "captain accepted open PR without watch" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "unlanded acknowledged teardown unexpectedly succeeded"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "post-ack landed-work refusal retired metadata"
  log="$case_dir/home/data/teardown-open-pr-without-watch.jsonl"
  [ ! -e "$log" ] || fail "post-ack landed-work refusal wrote an acknowledgement row"
  git -C "$case_dir/project" update-ref refs/heads/main \
    "$(git -C "$case_dir/wt" rev-parse HEAD)"
  rm -f "$case_dir/wt/sentinel"
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 \
    --acknowledge-open-pr-without-watch "captain accepted open PR without watch" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "retry after landing failed: $(cat "$case_dir/stderr")"
  assert_present "$log" "successful retry did not write the acknowledgement"
  rows=$(grep -c . "$log" || true)
  [ "$rows" = 1 ] || fail "acknowledgement retry wrote $rows rows instead of one"
  pass "post-ack refusal writes no row and retry remains exact-once"
}

test_missing_occupancy_entry_refuses() {
  local case_dir rc
  case_dir=$(make_case missing-occupancy-entry)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-task-x1
  FM_FAKE_TREEHOUSE_STATUS_JSON='[]'
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "missing occupancy entry was treated as ownership"
  assert_contains "$(cat "$case_dir/stderr")" "no matching identity entry" \
    "missing occupancy entry refusal omitted its recovery condition"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "missing occupancy entry retired metadata"
  assert_present "$case_dir/wt/sentinel" \
    "missing occupancy entry mutated the worktree"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"
  pass "missing treehouse occupancy entry refuses without mutation"
}

test_duplicate_occupancy_entries_refuse() {
  local case_dir wt_abs rc
  case_dir=$(make_case duplicate-occupancy-entries)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-task-x1
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(python3 - "$wt_abs" <<'PY'
import json
import sys

path = sys.argv[1]
print(json.dumps([
    {
        "name": "slot-1",
        "path": path,
        "status": "in-use",
        "lease_id": "lease-task-x1",
        "lease_holder": "task-x1",
    },
    {
        "name": "slot-1",
        "path": path,
        "status": "in-use",
        "lease_id": "lease-rebound",
        "lease_holder": "replacement-task",
    },
]))
PY
)
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "contradictory duplicate occupancy entries authorized teardown"
  assert_contains "$(cat "$case_dir/stderr")" "contradictory duplicate entries" \
    "duplicate occupancy refusal omitted its recovery condition"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "duplicate occupancy entries retired metadata"
  assert_present "$case_dir/wt/sentinel" \
    "duplicate occupancy entries mutated the worktree"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"
  pass "contradictory duplicate occupancy entries refuse without mutation"
}

test_rebound_path_preserves_new_identity() {
  local case_dir wt_abs rc
  case_dir=$(make_case rebound-path)
  git -C "$case_dir/project" branch fm/review-pr79-v1 main >/dev/null
  git -C "$case_dir/wt" checkout -q fm/review-pr79-v1
  write_task_meta "$case_dir" entity-fairness-audit "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-old
  write_task_meta "$case_dir" review-pr79-v1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-new
  : > "$case_dir/wt/live-agent"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-new review-pr79-v1)
  rc=0
  run_teardown "$case_dir" entity-fairness-audit \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "rebound teardown unexpectedly succeeded"
  assert_present "$case_dir/home/state/entity-fairness-audit.meta" \
    "old metadata was retired through the rebound path"
  assert_present "$case_dir/home/state/review-pr79-v1.meta" \
    "replacement metadata was disturbed"
  assert_present "$case_dir/wt/live-agent" "replacement worktree was reset"
  assert_present "$case_dir/wt/sentinel" "replacement worktree was returned"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = fm/review-pr79-v1 ] \
    || fail "replacement branch was deleted"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"
  pass "a path rebound to a new identity keeps its agent, worktree, branch, and lease"
}

test_same_slot_rebound_requires_new_lease() {
  local case_dir wt_abs rc
  case_dir=$(make_case same-slot-new-lease)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-old
  : > "$case_dir/wt/live-agent"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for \
    "$wt_abs" leased lease-new replacement-task slot-1)
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "same static slot accepted a different acquisition lease"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "same-slot rebound retired the stale task metadata"
  assert_present "$case_dir/wt/live-agent" \
    "same-slot rebound disturbed the replacement endpoint"
  assert_present "$case_dir/wt/sentinel" \
    "same-slot rebound returned the replacement worktree"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"
  pass "same pooled slot requires the original acquisition lease"
}

test_rebound_occupancy_precedes_endpoint_validation() {
  local case_dir wt_abs rc
  case_dir=$(make_case occupancy-before-endpoint)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-old
  printf '%s\n' 'window=malformed-replacement-endpoint' >> "$case_dir/home/state/task-x1.meta"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for \
    "$wt_abs" leased lease-new replacement-task slot-1)
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "rebound occupancy with stale endpoint metadata succeeded"
  assert_contains "$(cat "$case_dir/stderr")" "leased to replacement-task" \
    "endpoint validation ran before rebound occupancy refusal"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "rebound occupancy retired stale task metadata"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"
  pass "rebound occupancy refuses before endpoint validation"
}

test_concurrent_rebind_waits_for_mutation_lock() {
  local case_dir wt_abs rc contender signal
  case_dir=$(make_case concurrent-rebind)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-old
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for \
    "$wt_abs" leased lease-old task-x1 slot-1)
  signal="$case_dir/endpoint-killed"
  FM_FAKE_TMUX_SIGNAL=$signal
  (
    while [ ! -f "$signal" ]; do sleep 0.01; done
    FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
      FM_ROOT_OVERRIDE="$ROOT" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$case_dir/home/state/.treehouse-acquisition.lock"
    jq --arg path "$wt_abs" '
      . |= map(if .path==$path then
        .lease_id="lease-new" | .lease_holder="replacement-task" | .status="leased"
      else . end)' "$case_dir/treehouse-status.json" > "$case_dir/rebound-state"
    mv "$case_dir/rebound-state" "$case_dir/treehouse-status.json"
    git -C "$case_dir/wt" checkout -q -B fm/replacement main
    : > "$case_dir/wt/sentinel"
    : > "$case_dir/wt/live-agent"
    : > "$case_dir/rebound-complete"
    fm_lock_release "$case_dir/home/state/.treehouse-acquisition.lock"
  ) &
  contender=$!
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  wait "$contender"
  expect_code 0 "$rc" "locked teardown failed before the replacement acquisition"
  assert_absent "$case_dir/home/state/task-x1.meta" \
    "completed locked teardown retained old task metadata"
  assert_present "$case_dir/wt/sentinel" \
    "concurrent rebound returned the replacement worktree"
  assert_present "$case_dir/wt/live-agent" \
    "concurrent rebound killed the replacement endpoint"
  assert_present "$case_dir/rebound-complete" \
    "concurrent replacement never acquired the released mutation lock"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = fm/replacement ] \
    || fail "concurrent rebound mutated the replacement branch"
  pass "portable acquisition exclusion spans conditional return and rebind"
}

test_unreadable_and_contradictory_occupancy_fail_closed() {
  local case_dir wt_abs rc
  case_dir=$(make_case unreadable-status)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-task-x1
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_RC=1
  FM_FAKE_TREEHOUSE_STATUS_JSON='not-json'
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable occupancy teardown succeeded"
  assert_contains "$(cat "$case_dir/stderr")" "occupancy for task-x1 is unreadable" \
    "unreadable occupancy refusal omitted its recovery condition"
  assert_present "$case_dir/home/state/task-x1.meta" "unreadable occupancy retired metadata"
  assert_present "$case_dir/wt/sentinel" "unreadable occupancy mutated the worktree"
  assert_no_treehouse_return "$case_dir"
  assert_no_tmux_kill "$case_dir"

  case_dir=$(make_case contradictory-lease)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-task-x1
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-other other-task)
  FM_FAKE_TREEHOUSE_STATUS_RC=0
  rc=0
  run_teardown "$case_dir" task-x1 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "contradictory occupancy teardown succeeded"
  assert_present "$case_dir/home/state/task-x1.meta" "contradictory occupancy retired metadata"
  assert_present "$case_dir/wt/sentinel" "contradictory occupancy mutated the worktree"
  assert_no_treehouse_return "$case_dir"
  pass "unreadable and contradictory occupancy proofs fail closed without mutation"
}

test_ship_without_pr_and_scout_retain_current_behavior() {
  local case_dir wt_abs rc
  case_dir=$(make_case ship-no-pr)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1
  land_task_worktree "$case_dir"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "ship without PR failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/home/state/task-x1.meta" "ship without PR left metadata"

  case_dir=$(make_case scout-no-pr)
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=scout treehouse_slot=slot-1 treehouse_lease=lease-task-x1
  mkdir -p "$case_dir/home/data/task-x1"
  printf 'report\n' > "$case_dir/home/data/task-x1/report.md"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "scout teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/home/state/task-x1.meta" "scout left metadata"
  pass "ships without a PR and scouts retain current teardown behavior"
}

probe_open_pr_refusal() {
  local teardown=$1 name=$2 case_dir wt_abs rc
  TEARDOWN=$teardown
  case_dir=$(make_case "mut-open-$name") || return 1
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    "pr=$PR_URL"
  land_task_worktree "$case_dir" || return 1
  seed_canonical_poll "$case_dir" task-x1 "$PR_URL" || return 1
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || return 1
  [ -e "$case_dir/home/state/task-x1.meta" ] || return 1
  [ -e "$case_dir/home/state/task-x1.pr-poll-registration" ] || return 1
}

probe_rebound_refusal() {
  local teardown=$1 name=$2 case_dir wt_abs rc
  TEARDOWN=$teardown
  case_dir=$(make_case "mut-rebound-$name") || return 1
  write_task_meta "$case_dir" entity-fairness-audit "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-old
  write_task_meta "$case_dir" review-pr79-v1 "$case_dir/wt" \
    kind=ship mode=local-only treehouse_slot=slot-1 treehouse_lease=lease-new
  : > "$case_dir/wt/live-agent"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-new review-pr79-v1)
  rc=0
  run_teardown "$case_dir" entity-fairness-audit \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || return 1
  [ -e "$case_dir/wt/live-agent" ] || return 1
  [ -e "$case_dir/home/state/review-pr79-v1.meta" ] || return 1
  grep -F 'treehouse <return>' "$case_dir/treehouse.log" >/dev/null 2>&1 && return 1
  return 0
}

probe_presence_only_refusal() {
  local teardown=$1 name=$2 case_dir wt_abs rc
  TEARDOWN=$teardown
  case_dir=$(make_case "mut-presence-$name") || return 1
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    "pr=$PR_URL"
  land_task_worktree "$case_dir" || return 1
  write_task_meta "$case_dir" other-task "$case_dir/other-wt" kind=ship mode=local-only
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/home/state/other-task.check.sh"
  chmod 0700 "$case_dir/home/state/other-task.check.sh"
  printf 'not-an-identity-bound-poll\n' > "$case_dir/home/state/other-task.pr-poll-registration"
  chmod 0600 "$case_dir/home/state/other-task.pr-poll-registration"
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || return 1
  [ -e "$case_dir/home/state/task-x1.meta" ] || return 1
}

probe_wrong_pr_refusal() {
  local teardown=$1 name=$2 case_dir wt_abs rc
  TEARDOWN=$teardown
  case_dir=$(make_case "mut-wrongpr-$name") || return 1
  write_task_meta "$case_dir" task-x1 "$case_dir/wt" \
    kind=ship mode=local-only \
    treehouse_slot=slot-1 treehouse_lease=lease-task-x1 \
    "pr=$PR_URL"
  land_task_worktree "$case_dir" || return 1
  write_task_meta "$case_dir" other-task "$case_dir/other-wt" \
    kind=ship mode=local-only 'pr=https://github.com/example/repo/pull/99'
  seed_canonical_poll "$case_dir" other-task 'https://github.com/example/repo/pull/99' || return 1
  wt_abs=$(cd "$case_dir/wt" && pwd -P)
  FM_FAKE_GH_STATE=OPEN
  FM_FAKE_TREEHOUSE_STATUS_JSON=$(status_json_for "$wt_abs" in-use lease-task-x1 task-x1)
  rc=0
  run_teardown "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || return 1
  [ -e "$case_dir/home/state/task-x1.meta" ] || return 1
}

test_custody_mutations_are_killed() {
  local control omit_pr omit_occ path_only presence wrong
  local control_open omit_pr_rc presence_rc wrong_rc
  local control_rebound omit_occ_rc path_only_rc
  control="$TEARDOWN"
  omit_pr=$(make_mutant omit-open-pr-guard) || fail "could not build omit-open-pr mutant"
  omit_occ=$(make_mutant omit-occupancy) || fail "could not build omit-occupancy mutant"
  path_only=$(make_mutant path-only-occupancy) || fail "could not build path-only mutant"
  presence=$(make_mutant presence-only-watch) || fail "could not build presence-only mutant"
  wrong=$(make_mutant wrong-pr-watch) || fail "could not build wrong-PR mutant"

  control_open=0
  probe_open_pr_refusal "$control" control || control_open=$?
  omit_pr_rc=0
  probe_open_pr_refusal "$omit_pr" omit-pr || omit_pr_rc=$?
  presence_rc=0
  probe_presence_only_refusal "$presence" presence || presence_rc=$?
  wrong_rc=0
  probe_wrong_pr_refusal "$wrong" wrongpr || wrong_rc=$?
  control_rebound=0
  probe_rebound_refusal "$control" control || control_rebound=$?
  omit_occ_rc=0
  probe_rebound_refusal "$omit_occ" omit-occ || omit_occ_rc=$?
  path_only_rc=0
  probe_rebound_refusal "$path_only" path-only || path_only_rc=$?

  printf 'custody mutation exit codes: open-control=%s omit-pr=%s presence=%s wrong-pr=%s rebound-control=%s omit-occ=%s path-only=%s\n' \
    "$control_open" "$omit_pr_rc" "$presence_rc" "$wrong_rc" \
    "$control_rebound" "$omit_occ_rc" "$path_only_rc"
  expect_code 0 "$control_open" "open-PR control should refuse"
  expect_code 1 "$omit_pr_rc" "omitting the open-PR guard should be killed"
  expect_code 1 "$presence_rc" "presence-only replacement mutant should be killed"
  expect_code 1 "$wrong_rc" "wrong-PR replacement mutant should be killed"
  expect_code 0 "$control_rebound" "rebound control should refuse"
  expect_code 1 "$omit_occ_rc" "omitting occupancy should be killed"
  expect_code 1 "$path_only_rc" "path-only occupancy mutant should be killed"
  pass "custody mutations for omitted guards, presence-only watches, wrong-PR registrations, and path-only ownership are killed"
}

test_open_pr_refuses_and_preserves_watch
test_merged_and_closed_pr_progress
test_identity_bound_replacement_watch_progress
test_presence_only_and_wrong_pr_are_not_replacement
test_acknowledgement_reason_success_and_empty_refusal
test_unreadable_pr_acknowledgement_progress
test_matching_lease_progress
test_path_only_occupancy_cannot_replace_spawn_identity
test_already_cleaned_stale_metadata_is_noop
test_missing_path_available_occupancy_with_live_endpoint_refuses
test_base_format_live_writer_teardown_completes
test_post_ack_landed_work_refusal_writes_no_row
test_missing_occupancy_entry_refuses
test_duplicate_occupancy_entries_refuse
test_rebound_path_preserves_new_identity
test_same_slot_rebound_requires_new_lease
test_rebound_occupancy_precedes_endpoint_validation
test_concurrent_rebind_waits_for_mutation_lock
test_unreadable_and_contradictory_occupancy_fail_closed
test_ship_without_pr_and_scout_retain_current_behavior
test_custody_mutations_are_killed
