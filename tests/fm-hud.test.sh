#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the Captain HUD (bin/fm-hud.sh / bin/fm-hud.py).
#
# The HUD's whole point is to be project-agnostic, so most of this suite
# exercises it against a completely fake, non-BinBuddy project fixture built
# fresh in a temp root - proving discovery, checkpoint tracking, and worker
# liveness all come from generic conventions (backlog.md shape, "<label>_run"/
# "<label>_banked" meta keys, "tmux <session>" mentions) rather than any
# hardcoded project/task/branch name. It also proves the zero-model-cost and
# read-only contracts by construction: fake claude/codex/gnhf binaries that
# would leave a marker file if invoked, and before/after content hashes of
# every durable file the HUD reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

HUD="$ROOT/bin/fm-hud.sh"

# fake_quota_axi <fakebin> <json-body>
fake_quota_axi() {
  local fakebin=$1 body=$2
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
cat <<'JSON'
$body
JSON
SH
  chmod +x "$fakebin/quota-axi"
}

# marker_binary <fakebin> <name> <marker-file>
marker_binary() {
  local fakebin=$1 name=$2 marker=$3
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
touch "$marker"
exit 0
SH
  chmod +x "$fakebin/$name"
}

# make_home <dir>: an empty but structurally valid firstmate home.
make_home() {
  local dir=$1
  mkdir -p "$dir/data" "$dir/state" "$dir/config"
}

# make_task <home> <task_id> <title> <section> [extra meta lines...]
# Appends one backlog item and writes state/<id>.meta with a real git
# worktree, so git/branch/dirty-count collection is exercised for real.
make_task() {
  local home=$1 id=$2 title=$3 section=$4
  shift 4
  local wt="$home/worktrees/$id"
  mkdir -p "$wt"
  git init -q "$wt"
  git -C "$wt" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b "gnhf/$id-branch"

  {
    echo "## $section"
    echo "- [ ] $id - $title (kind: ship) (since 2026-09-16)"
    echo "  fixture task, never a real project."
  } >> "$home/data/backlog.md"

  {
    echo "worktree=$wt"
    echo "project=$wt"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$home/state/$id.meta"

  printf '%s\n' "$wt"
}

QUOTA_TWO_PROVIDER='{
  "generatedAt": "2026-09-16T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "plan": "pro",
      "windows": [
        {"id": "five_hour", "label": "session", "kind": "session", "resetsAt": "2099-01-01T00:00:00Z", "percentRemaining": 71},
        {"id": "seven_day", "label": "week", "kind": "weekly", "resetsAt": "2099-01-08T00:00:00Z", "percentRemaining": 55}
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 55,
           "limitingWindowIds": ["five_hour"],
           "runway": {"usableRunwaySeconds": 1980}}
        ]
      }
    }
  ]
}'

# A hostile fixture for the known all_models regression: the composite scope
# reports 99% while the only real named window (weekly) is nearly exhausted.
# The HUD must show weekly at its own 4%, never silently substitute 99%.
QUOTA_ALL_MODELS_TRAP='{
  "generatedAt": "2026-09-16T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "plan": "pro",
      "windows": [
        {"id": "seven_day", "label": "week", "kind": "weekly", "resetsAt": "2099-01-08T00:00:00Z", "percentRemaining": 4}
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 99,
           "limitingWindowIds": ["seven_day"],
           "runway": {"usableRunwaySeconds": 60}}
        ]
      }
    }
  ]
}'

test_fake_project_discovered_and_active() {
  local tmp home fakebin wt out marker
  tmp=$(fm_test_tmproot fm-hud-fake-active)
  home="$tmp/home"; fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
  make_home "$home"
  wt=$(make_task "$home" "future-project-alpha" "Totally Fake Future Project Alpha" "In flight" \
    "gnhf_enabled=true" \
    "gnhf_run_id=fp-run-1" \
    "auth_run=fp-run-1 (launched, tmux fm-hud-test-session)" \
    "auth_banked=YES. Commit abc1234 on gnhf/future-project-alpha-branch.")

  fake_quota_axi "$fakebin" "$QUOTA_TWO_PROVIDER"
  marker="$tmp/model-call-marker"
  marker_binary "$fakebin" claude "$marker"
  marker_binary "$fakebin" codex "$marker"
  marker_binary "$fakebin" gnhf "$marker"

  tmux new-session -d -s fm-hud-test-session 'sleep 30' 2>/dev/null || true

  out=$(PATH="$fakebin:$PATH" "$HUD" --home "$home" --once) || fail "fm-hud exited non-zero: $out"

  tmux kill-session -t fm-hud-test-session 2>/dev/null || true

  assert_contains "$out" "future-project-alpha" "selects the sole in-flight fake task"
  assert_contains "$out" "ACTIVE" "reports ACTIVE with a live tmux session recorded"
  assert_contains "$out" "1 / 1 checkpoints" "counts exactly the one declared checkpoint"
  assert_contains "$out" "abc1234" "surfaces the banked commit sha from meta"
  case "$out" in
    *[Bb]in[Bb]uddy*) fail "HUD output mentions BinBuddy against a fixture that never does" ;;
  esac
  [ -e "$marker" ] && fail "HUD invoked a model/agent binary (claude/codex/gnhf) - it must be zero model cost"
  pass "fake non-BinBuddy project is discovered, classified, and checkpointed generically"
}

test_no_tasks_is_idle() {
  local tmp home out
  tmp=$(fm_test_tmproot fm-hud-idle)
  home="$tmp/home"
  make_home "$home"
  : > "$home/data/backlog.md"
  out=$("$HUD" --home "$home" --once) || fail "fm-hud exited non-zero on empty backlog: $out"
  assert_contains "$out" "IDLE" "an empty backlog reports IDLE rather than crashing or fabricating a task"
  pass "empty backlog renders IDLE"
}

test_ambiguous_multiple_in_flight() {
  local tmp home out
  tmp=$(fm_test_tmproot fm-hud-ambiguous)
  home="$tmp/home"
  make_home "$home"
  make_task "$home" "proj-one" "Project One" "In flight" >/dev/null
  make_task "$home" "proj-two" "Project Two" "In flight" >/dev/null
  out=$("$HUD" --home "$home" --once) || fail "fm-hud exited non-zero on ambiguous tasks: $out"
  assert_contains "$out" "AMBIGUOUS" "two equally-idle in-flight tasks must not be silently guessed between"
  assert_contains "$out" "proj-one" "ambiguous listing names the first candidate"
  assert_contains "$out" "proj-two" "ambiguous listing names the second candidate"
  pass "multiple in-flight tasks with no clear winner render as AMBIGUOUS"
}

test_explicit_task_selection() {
  local tmp home out
  tmp=$(fm_test_tmproot fm-hud-explicit)
  home="$tmp/home"
  make_home "$home"
  make_task "$home" "proj-one" "Project One" "In flight" >/dev/null
  make_task "$home" "proj-two" "Project Two" "In flight" >/dev/null
  out=$("$HUD" --home "$home" --once --task proj-two) || fail "fm-hud exited non-zero with --task: $out"
  assert_contains "$out" "proj-two" "--task selects the named task"
  assert_not_contains "$out" "AMBIGUOUS" "an explicit --task selection is never reported ambiguous"
  pass "--task overrides auto-discovery deterministically"
}

test_quota_all_models_not_authoritative() {
  local tmp home fakebin out
  tmp=$(fm_test_tmproot fm-hud-all-models-trap)
  home="$tmp/home"; fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
  make_home "$home"
  : > "$home/data/backlog.md"
  fake_quota_axi "$fakebin" "$QUOTA_ALL_MODELS_TRAP"
  out=$(PATH="$fakebin:$PATH" "$HUD" --home "$home" --once) || fail "fm-hud exited non-zero: $out"
  assert_contains "$out" "4% remaining" "the real named weekly window (4%) is shown"
  case "$out" in
    *"99% remaining"*) fail "the composite all_models percentage (99%) leaked into a named window display" ;;
  esac
  assert_contains "$out" "SESSION  UNAVAILABLE" "a provider with no session window reports UNAVAILABLE, not a fabricated value"
  pass "the composite all_models row never substitutes for a missing/lower specific window"
}

test_quota_unavailable_does_not_crash() {
  local tmp home fakebin out
  tmp=$(fm_test_tmproot fm-hud-quota-missing)
  home="$tmp/home"; fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
  make_home "$home"
  : > "$home/data/backlog.md"
  # Shadow the real quota-axi with one that fails outright (simulates it being
  # absent/broken) while keeping the rest of PATH (bash, env, python3) intact.
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$PATH" "$HUD" --home "$home" --once) || fail "fm-hud crashed with quota-axi failing: $out"
  assert_contains "$out" "TELEMETRY UNAVAILABLE" "missing quota-axi is reported honestly, not as 0%"
  pass "missing/failing quota-axi telemetry degrades gracefully"
}

test_malformed_meta_does_not_crash() {
  local tmp home out
  tmp=$(fm_test_tmproot fm-hud-malformed-meta)
  home="$tmp/home"
  make_home "$home"
  {
    echo "## In flight"
    echo "- [ ] broken-task - Broken Task (kind: ship) (since 2026-09-16)"
  } >> "$home/data/backlog.md"
  printf 'not a key value file\n===garbage===\x00\x01\x02\n' > "$home/state/broken-task.meta"
  out=$("$HUD" --home "$home" --once) || fail "fm-hud crashed on a malformed meta file: $out"
  assert_contains "$out" "broken-task" "a malformed meta file still lets the task render"
  pass "a malformed state/<id>.meta degrades gracefully instead of crashing the HUD"
}

test_json_output_is_valid() {
  local tmp home out
  tmp=$(fm_test_tmproot fm-hud-json)
  home="$tmp/home"
  make_home "$home"
  make_task "$home" "proj-one" "Project One" "In flight" >/dev/null
  out=$("$HUD" --home "$home" --json) || fail "fm-hud --json exited non-zero: $out"
  printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" \
    || fail "--json output did not parse as JSON"
  pass "--json emits parseable, ANSI-free normalized state"
}

test_read_only_no_mutation() {
  local tmp home wt before_backlog before_meta before_git after_backlog after_meta after_git
  tmp=$(fm_test_tmproot fm-hud-readonly)
  home="$tmp/home"
  make_home "$home"
  wt=$(make_task "$home" "proj-one" "Project One" "In flight" \
    "gnhf_enabled=true" "gnhf_run_id=r1")

  before_backlog=$(md5sum "$home/data/backlog.md")
  before_meta=$(md5sum "$home/state/proj-one.meta")
  before_git=$(git -C "$wt" rev-parse HEAD)

  "$HUD" --home "$home" --once >/dev/null || fail "fm-hud exited non-zero"
  "$HUD" --home "$home" --json >/dev/null || fail "fm-hud --json exited non-zero"

  after_backlog=$(md5sum "$home/data/backlog.md")
  after_meta=$(md5sum "$home/state/proj-one.meta")
  after_git=$(git -C "$wt" rev-parse HEAD)

  assert_equals "$before_backlog" "$after_backlog" "backlog.md is byte-identical after viewing the HUD"
  assert_equals "$before_meta" "$after_meta" "state/<id>.meta is byte-identical after viewing the HUD"
  assert_equals "$before_git" "$after_git" "the task worktree's HEAD is unchanged after viewing the HUD"
  pass "viewing the HUD mutates neither backlog, task metadata, nor git state"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  local out
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-hud.sh" 2>&1) \
    || fail "bin/fm-hud.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-hud.sh is clean under bin/fm-lint.sh"
}

test_fake_project_discovered_and_active
test_no_tasks_is_idle
test_ambiguous_multiple_in_flight
test_explicit_task_selection
test_quota_all_models_not_authoritative
test_quota_unavailable_does_not_crash
test_malformed_meta_does_not_crash
test_json_output_is_valid
test_read_only_no_mutation
test_scripts_are_shellcheck_clean
