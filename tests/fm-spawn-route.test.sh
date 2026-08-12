#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh route evidence integration.
#
# The fake tmux reports a controlled pane cwd after durable `treehouse get`, so these
# tests exercise the real spawn success path without opening windows.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-slot-owner-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-route)
SPAWN="$ROOT/bin/fm-spawn.sh"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
uses_window_id() {
  local previous= expected_id="${FM_FAKE_NEW_WINDOW_ID-@42}"
  for argument in "$@"; do
    if [ "$previous" = -t ] && [ "$argument" = "$expected_id" ]; then
      return 0
    fi
    previous=$argument
  done
  return 1
}
fails_tmux_command() {
  [ "${FM_FAKE_TMUX_FAIL:-}" = "$1" ]
}

case "${1:-}" in
  display-message)
    case "$*" in
      *"#{pane_current_path}"*)
        uses_window_id "$@" || exit 64
        printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
        exit 0 ;;
      *"#{window_name}"*)
        uses_window_id "$@" || exit 64
        cat "${FM_FAKE_TMUX_STATE:?}"
        exit 0 ;;
    esac
    printf 'firstmate\n'
    exit 0 ;;
  list-windows)
    case "$*" in
      *"#{window_name}"*) exit 0 ;;
      *"#{window_id}"*)
        state=${FM_FAKE_TMUX_WINDOW_IDS_STATE:-}
        if [ -z "$state" ]; then
          exit 0
        fi
        count=0
        [ -f "$state" ] && count=$(cat "$state")
        printf '%s\n' "$((count + 1))" > "$state"
        if [ "$count" -eq 0 ]; then
          printf '%s\n' "${FM_FAKE_TMUX_WINDOW_IDS_BEFORE:-}" | tr ' ' '\n'
        else
          printf '%s\n' "${FM_FAKE_TMUX_WINDOW_IDS_AFTER:-}" | tr ' ' '\n'
        fi
        exit 0 ;;
    esac
    exit 64 ;;
  has-session|new-session) exit 0 ;;
  new-window)
    [ "${2:-}" = -dP ] && [ "${3:-}" = -F ] && [ "${4:-}" = '#{window_id}' ] || exit 64
    printf '%s\n' "${FM_FAKE_NEW_WINDOW_ID-@42}"
    exit 0 ;;
  set-window-option)
    uses_window_id "$@" || exit 64
    fails_tmux_command "${4:-}" && exit 1
    if [ "${4:-}" = automatic-rename ] && [ "${5:-}" = off ]; then
      : > "${FM_FAKE_AUTOMATIC_RENAME_LOCK:?}"
    fi
    if [ "${4:-}" = allow-rename ] && [ "${5:-}" = off ]; then
      : > "${FM_FAKE_ALLOW_RENAME_LOCK:?}"
    fi
    exit 0 ;;
  send-keys)
    uses_window_id "$@" || exit 64 ;;
  rename-window)
    uses_window_id "$@" && [ "${4:-}" = "${FM_FAKE_WINDOW_NAME:-}" ] || exit 64
    fails_tmux_command rename-window && exit 1
    if [ -f "${FM_FAKE_AUTOMATIC_RENAME_LOCK:?}" ] && [ -f "${FM_FAKE_ALLOW_RENAME_LOCK:?}" ]; then
      printf '%s\n' "${FM_FAKE_RETAINED_WINDOW_NAME:-$FM_FAKE_WINDOW_NAME}" > "$FM_FAKE_TMUX_STATE"
    else
      printf '%s\n' terminal-title > "$FM_FAKE_TMUX_STATE"
    fi
    exit 0 ;;
esac
if [ "${1:-}" = send-keys ]; then
  for arg in "$@"; do
    if [[ "$arg" == *"treehouse get --lease --lease-holder"* ]]; then
      bash -c "$arg"
      break
    fi
  done
fi
if [ "${1:-}" = send-keys ] && [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
  prev=
  for arg in "$@"; do
    if [ "$prev" = -l ]; then
      printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
      exit 0
    fi
    prev=$arg
  done
fi
case "${1:-}" in
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:?}" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_case() {
  local label=$1 project_basename home proj wt fakebin runtime
  project_basename=${2:-$label-alpha}
  home="$TMP_ROOT/$label-home"
  proj="$TMP_ROOT/$label-project/$project_basename"
  wt="$TMP_ROOT/$label-wt"
  runtime="$TMP_ROOT/$label-runtime"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/$label-fake")
  mkdir -p "$runtime"
  cp -a "$ROOT/bin" "$runtime/"
  mkdir -p "$home/data" "$home/state" "$home/projects" "$home/config"
  fm_git_init_commit "$home"
  printf '# agents\n' > "$home/AGENTS.md"
  git -C "$home" add AGENTS.md
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm agents
  ln -s "$runtime/bin" "$home/bin"
  printf 'root=%s\ntoken=route-%s\n' "$home" "$label" > "$home/state/.primary-attestation"
  chmod 600 "$home/state/.primary-attestation"
  printf '%s|codex:spawn-route|fallback\n' "$$" > "$home/state/.lock"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' "- $(basename "$proj") [direct-PR] - alpha fixture (added 2026-06-25)" > "$home/data/projects.md"
  fm_git_init_commit "$proj"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn_case() {
  local home=$1 id=$2 proj=$3 wt=$4 fakebin=$5 token
  shift 5
  token=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' "$home/state/.primary-attestation")
  : > "$home/launch.log"
  : > "$home/tmux.log"
  rm -f "$home/tmux-automatic-rename-lock"
  rm -f "$home/tmux-allow-rename-lock"
  rm -f "$home/tmux-window-ids-state"
  printf '%s\n' terminal-title > "$home/tmux-window-name"
  ( cd "$home" && env -u NO_MISTAKES_GATE \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" CODEX_THREAD_ID=spawn-route \
    FM_PRIMARY_ATTESTATION="$token" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_WINDOW_NAME="fm-$id" FM_FAKE_RETAINED_WINDOW_NAME="${FM_FAKE_RETAINED_WINDOW_NAME-}" FM_FAKE_TMUX_STATE="$home/tmux-window-name" FM_FAKE_AUTOMATIC_RENAME_LOCK="$home/tmux-automatic-rename-lock" FM_FAKE_ALLOW_RENAME_LOCK="$home/tmux-allow-rename-lock" FM_FAKE_TMUX_LOG="$home/tmux.log" FM_FAKE_TMUX_WINDOW_IDS_STATE="$home/tmux-window-ids-state" FM_FAKE_NEW_WINDOW_ID="${FM_FAKE_NEW_WINDOW_ID-@42}" FM_FAKE_LAUNCH_LOG="$home/launch.log" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$home/bin/fm-spawn.sh" "$id" "$proj" "$@" 2>&1 )
}

test_ordinary_spawn_records_route_fields() {
  local home proj wt fakebin id out status meta brief launch tmux_log window_name
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case ordinary)
EOF
  id=route-ordinary-aa1
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  printf '%s\n' 'Investigate production refresh on 4187 and keep state/meta truthful.' > "$brief"

  out=$(FM_FAKE_NEW_WINDOW_ID=@71 run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "ordinary routed spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "ordinary spawn should launch route harness"
  meta="$home/state/$id.meta"
  assert_grep "route_profile=critical" "$meta" "ordinary spawn did not record route profile"
  assert_grep "route_harness=codex" "$meta" "ordinary spawn did not record route harness"
  assert_grep "route_model=gpt-5.6-sol" "$meta" "ordinary spawn did not record route model"
  assert_grep "route_effort=medium" "$meta" "ordinary spawn did not record route effort"
  assert_grep "route_override=none" "$meta" "ordinary spawn did not record route override"
  assert_grep "route_risk_flags=production,firstmate-core" "$meta" "ordinary spawn did not record route risk flags"
  assert_present "$home/tmux-automatic-rename-lock" "ordinary spawn did not disable automatic terminal renames"
  assert_present "$home/tmux-allow-rename-lock" "ordinary spawn did not disable terminal renames"
  window_name=$(cat "$home/tmux-window-name")
  assert_contains "$window_name" "fm-$id" "ordinary spawn did not restore the canonical window name after locking renames"
  launch=$(cat "$home/launch.log")
  tmux_log=$(cat "$home/tmux.log")
  assert_contains "$tmux_log" "treehouse get --lease --lease-holder '$id'" \
    "ordinary spawn did not hold a durable Treehouse lease until teardown"
  assert_contains "$tmux_log" 'cd -- "$fm_wt"' \
    "ordinary spawn did not enter the durably leased worktree"
  assert_contains "$launch" "codex --model 'gpt-5.6-sol' -c 'model_reasoning_effort=\"medium\"' --dangerously-bypass-approvals-and-sandbox" \
    "ordinary route did not thread model and effort into launch"
  assert_grep "# Route" "$brief" "ordinary spawn did not add route block to brief"
  assert_grep "route: critical because" "$brief" "ordinary spawn brief route summary missing"
  pass "ordinary spawn records route evidence and appends a brief route block"
}

test_manual_harness_override_records_manual_route() {
  local home proj wt fakebin id out status meta
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case manual)
EOF
  id=route-manual-bb2
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Investigate production refresh on 4187.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin" claude); status=$?
  expect_code 0 "$status" "manual harness spawn should still succeed"
  assert_contains "$out" "spawned $id harness=claude" "manual harness override did not launch selected harness"
  meta="$home/state/$id.meta"
  assert_grep "harness=claude" "$meta" "manual spawn did not preserve operational harness"
  assert_grep "route_profile=manual" "$meta" "manual spawn did not record manual route profile"
  assert_grep "route_harness=claude" "$meta" "manual spawn did not record selected harness"
  assert_grep "route_override=manual-harness" "$meta" "manual spawn did not record manual override"
  assert_no_grep "route_profile=cheap" "$meta" "manual override must not silently record a cheap route"
  pass "manual harness override preserves behavior and records manual route evidence"
}

test_raw_launch_command_records_raw_route() {
  local home proj wt fakebin id out status meta
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case raw)
EOF
  id=route-raw-cc3
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Adapter verification.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin" 'CUSTOM=1 /bin/echo launch'); status=$?
  expect_code 0 "$status" "raw launch command should still succeed"
  assert_contains "$out" "spawned $id harness=echo" "raw launch did not preserve parsed harness"
  meta="$home/state/$id.meta"
  assert_grep "harness=echo" "$meta" "raw launch did not record operational harness"
  assert_grep "route_profile=manual" "$meta" "raw launch did not record manual route profile"
  assert_grep "route_harness=echo" "$meta" "raw launch did not record parsed route harness"
  assert_grep "route_override=raw-launch" "$meta" "raw launch did not record raw override"
  pass "raw launch command is not blocked and records raw route evidence"
}

test_jt_direct_pr_spawn_appends_pr_intake_governor() {
  local home proj wt fakebin id out status brief
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case jt-pr-intake jt-control-room)
EOF
  id=jt-replenishment-proof-loop-dd4
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  printf '%s\n' 'Fix the JT Control Room Replenishment proof loop before opening another PR.' > "$brief"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "JT direct-PR spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "JT direct-PR spawn did not launch"
  assert_grep "<!-- firstmate:jt-pr-intake-governor:start -->" "$brief" \
    "JT direct-PR brief missing intake-governor marker"
  assert_grep "# JT PR Intake Governor" "$brief" \
    "JT direct-PR brief missing intake-governor heading"
  assert_grep "- Problem category:" "$brief" "JT intake missing problem category field"
  assert_grep "- Priority (P0-P4):" "$brief" "JT intake missing priority field"
  assert_grep "- Verification gate:" "$brief" "JT intake missing verification gate field"
  assert_grep "Do not open a PR until this intake is answered." "$brief" \
    "JT intake missing direct PR stop rule"
  pass "JT direct-PR spawns receive the PR Intake Governor brief gate"
}

test_jt_keyword_id_in_unrelated_project_skips_pr_intake_governor() {
  local home proj wt fakebin id out status brief
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case unrelated-jt-id accounting-tools)
EOF
  id=jt-replenishment-proof-loop-ff6
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  printf '%s\n' 'Fix an unrelated project task with a JT-looking id.' > "$brief"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "unrelated JT-looking direct-PR spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "unrelated JT-looking spawn did not launch"
  assert_no_grep "<!-- firstmate:jt-pr-intake-governor:start -->" "$brief" \
    "unrelated project must not receive the JT intake-governor marker"
  pass "JT-looking task ids in unrelated projects skip the PR Intake Governor"
}

test_jt_project_without_jt_context_skips_pr_intake_governor() {
  local home proj wt fakebin id out status brief
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case jt-neutral-context .openclaw)
EOF
  id=copy-fix-gg7
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  printf '%s\n' 'Tidy the README wording before opening another PR.' > "$brief"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "neutral .openclaw direct-PR spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "neutral .openclaw spawn did not launch"
  assert_grep "# Route" "$brief" "neutral .openclaw spawn should still append route block"
  assert_no_grep "<!-- firstmate:jt-pr-intake-governor:start -->" "$brief" \
    "route block alone must not trigger the JT intake-governor marker"
  pass "neutral JT project briefs skip the PR Intake Governor"
}

test_jt_openclaw_operator_route_brief_appends_pr_intake_governor() {
  local home proj wt fakebin id out status brief
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case jt-operator-route .openclaw)
EOF
  id=copy-fix-ee5
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  printf '%s\n' 'Fix Control Room operator route copy before opening another PR.' > "$brief"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "JT operator-route direct-PR spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "JT operator-route spawn did not launch"
  assert_grep "<!-- firstmate:jt-pr-intake-governor:start -->" "$brief" \
    "plain operator-route JT brief missing intake-governor marker"
  pass "JT operator-route briefs receive the PR Intake Governor brief gate"
}

test_unsafe_task_ids_are_rejected_before_spawn() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case unsafe-id)
EOF

  id='bad;touch pwn'
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Unsafe id should not launch.' > "$home/data/$id/brief.md"
  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 2 "$status" "spawn unsafe metachar id should fail"
  assert_contains "$out" "invalid task id" "spawn did not explain metachar id rejection"
  assert_absent "$home/state/$id.meta" "unsafe metachar id must not record meta"

  id='../evil'
  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 2 "$status" "spawn path-traversal id should fail"
  assert_contains "$out" "invalid task id" "spawn did not explain path traversal id rejection"

  pass "unsafe task ids are rejected before spawn side effects"
}

test_empty_window_id_stops_before_post_create_commands() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case empty-window-id)
EOF
  id=empty-window-id-hh8
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Reject an empty tmux window id.' > "$home/data/$id/brief.md"

  out=$(FM_FAKE_NEW_WINDOW_ID='' FM_FAKE_TMUX_WINDOW_IDS_BEFORE=@1 FM_FAKE_TMUX_WINDOW_IDS_AFTER='@1 @57' run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "empty tmux window id should fail"
  assert_contains "$out" "tmux did not return a window id" "empty tmux window id should explain failure"
  assert_grep "new-window" "$home/tmux.log" "empty tmux window id should create the window once"
  assert_no_grep "kill-window" "$home/tmux.log" "empty tmux window id must not kill an unproven candidate"
  assert_present "$home/state/$id.meta" "empty tmux window id must preserve recovery metadata"
  assert_grep 'endpoint_recovery_pending=1' "$home/state/$id.meta" \
    "empty tmux window id must retain a pending endpoint reservation"
  assert_no_grep "kill-window -t firstmate:fm-$id" "$home/tmux.log" "empty tmux window id must not clean up by mutable title"
  assert_no_grep "set-window-option" "$home/tmux.log" "empty tmux window id must stop before option changes"
  assert_no_grep "send-keys" "$home/tmux.log" "empty tmux window id must stop before pane commands"
  pass "empty tmux window ids stop before post-create commands"
}

test_malformed_window_id_stops_before_post_create_commands() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case malformed-window-id)
EOF
  id=malformed-window-id-hh9
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Reject a malformed tmux window id.' > "$home/data/$id/brief.md"

  out=$(FM_FAKE_NEW_WINDOW_ID=@not-a-window-id FM_FAKE_TMUX_WINDOW_IDS_BEFORE=@1 FM_FAKE_TMUX_WINDOW_IDS_AFTER='@1 @58' run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "malformed tmux window id should fail"
  assert_contains "$out" "tmux did not return a window id" "malformed tmux window id should explain failure"
  assert_no_grep "kill-window" "$home/tmux.log" "malformed tmux window id must not kill an unproven candidate"
  assert_present "$home/state/$id.meta" "malformed tmux window id must preserve recovery metadata"
  assert_grep 'endpoint_recovery_pending=1' "$home/state/$id.meta" \
    "malformed tmux window id must retain a pending endpoint reservation"
  assert_no_grep "set-window-option" "$home/tmux.log" "malformed tmux window id must stop before option changes"
  assert_no_grep "send-keys" "$home/tmux.log" "malformed tmux window id must stop before pane commands"
  pass "malformed tmux window ids stop before post-create commands"
}

test_rejected_window_name_removes_new_window() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case rejected-window-name)
EOF
  id=rejected-window-name-ii9
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Reject a tmux window that changes title.' > "$home/data/$id/brief.md"

  out=$(FM_FAKE_NEW_WINDOW_ID=@71 FM_FAKE_RETAINED_WINDOW_NAME=terminal-title run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "rejected tmux window name should fail"
  assert_contains "$out" "tmux did not retain canonical window name" "rejected tmux window name should explain failure"
  assert_grep "kill-window -t @71" "$home/tmux.log" "rejected tmux window name should remove the new window by id"
  assert_no_grep "send-keys" "$home/tmux.log" "rejected tmux window name must stop before pane commands"
  pass "rejected tmux window names remove new windows"
}

test_window_setup_failures_remove_new_window() {
  local setup home proj wt fakebin id out status
  for setup in automatic-rename allow-rename rename-window; do
    IFS='|' read -r home proj wt fakebin <<EOF
$(make_case "setup-failure-$setup")
EOF
    id="setup-failure-$setup-jj0"
    mkdir -p "$home/data/$id"
    printf '%s\n' 'Reject a failed tmux window setup.' > "$home/data/$id/brief.md"

    out=$(FM_FAKE_NEW_WINDOW_ID=@71 FM_FAKE_TMUX_FAIL="$setup" run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
    expect_code 1 "$status" "failed $setup setup should fail"
    assert_contains "$out" "tmux failed" "failed $setup setup should explain failure"
    assert_grep "kill-window -t @71" "$home/tmux.log" "failed $setup setup should remove the new window"
    assert_no_grep "send-keys" "$home/tmux.log" "failed $setup setup must stop before pane commands"
  done
  pass "failed tmux window setup removes new windows"
}

test_opted_in_scope_fence_cannot_disappear_before_spawn() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case missing-scope-fence)
EOF
  id=missing-scope-fence-kk1
  mkdir -p "$home/data/$id"
  printf '%s\n' 'firstmate-scope-contract-v1' > "$home/data/$id/scope-contract-enabled"
  printf '%s\n' 'The scope fence was removed.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "missing opted-in scope fence should fail before spawn"
  assert_contains "$out" "brief has an invalid scope-contract fence" "missing scope fence diagnostic absent"
  assert_no_grep 'new-window' "$home/tmux.log" "invalid scope reached tmux window creation"
  assert_no_grep 'send-keys' "$home/tmux.log" "invalid scope reached agent launch"
  pass "durable scope opt-in fails closed when the embedded fence disappears"
}

test_dangling_scope_marker_cannot_restore_legacy_spawn() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case dangling-scope-marker)
EOF
  id=dangling-scope-marker-ll2
  mkdir -p "$home/data/$id"
  ln -s "$home/data/$id/missing-marker-target" "$home/data/$id/scope-contract-enabled"
  printf '%s\n' 'The scope fence was removed.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "dangling scope marker should fail before spawn"
  assert_contains "$out" "invalid scope-contract marker" "dangling marker diagnostic absent"
  assert_no_grep 'new-window' "$home/tmux.log" "dangling marker reached tmux window creation"
  pass "dangling scope markers cannot turn opted-in tasks back into legacy spawns"
}

test_legacy_scope_fence_text_does_not_opt_in() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case legacy-scope-fence)
EOF
  id=legacy-scope-fence-mm3
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Legacy prose.' '```firstmate-scope-contract-v1' 'not a contract' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "marker-free legacy fence text should not opt in"
  assert_grep 'new-window' "$home/tmux.log" "legacy brief did not reach spawn"
  pass "marker-free legacy fence text remains legacy"
}

test_scope_marker_with_extra_bytes_fails() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case invalid-scope-marker-bytes)
EOF
  id=invalid-scope-marker-mm4
  mkdir -p "$home/data/$id"
  printf '%s\n%s\n' firstmate-scope-contract-v1 extra > "$home/data/$id/scope-contract-enabled"
  printf '%s\n' 'Legacy prose.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "scope marker with extra bytes should fail"
  assert_contains "$out" "invalid scope-contract marker" "invalid marker diagnostic absent"
  assert_no_grep 'new-window' "$home/tmux.log" "invalid marker reached window creation"
  pass "scope marker validation rejects extra bytes"
}

test_foreign_slot_stamp_stops_spawn_before_publication_or_launch() {
  local home proj wt fakebin foreign_home id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case foreign-slot-stamp)
EOF
  id=foreign-slot-stamp-nn5
  foreign_home="$TMP_ROOT/foreign-slot-home"
  mkdir -p "$foreign_home/state"
  fm_slot_stamp_write "$wt" foreign-task "$foreign_home" \
    || fail "could not seed the foreign pooled-slot ownership stamp"
  mkdir -p "$home/data/$id"
  printf '%s\n' 'A foreign slot stamp must refuse this launch.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 1 "$status" "a foreign pooled-slot stamp must refuse spawn"
  assert_contains "$out" "already stamped" "foreign slot refusal did not identify the existing owner"
  if [ -e "$home/state/$id.meta" ]; then
    assert_grep 'spawn_state=aborted' "$home/state/$id.meta" \
      "foreign slot refusal did not leave only an aborted recovery record"
    assert_no_grep '^route_profile=' "$home/state/$id.meta" \
      "foreign slot refusal published normal task metadata"
  fi
  [ ! -s "$home/launch.log" ] || fail "foreign slot refusal reached harness launch"
  pass "foreign pooled-slot ownership is refused before metadata publication or launch"
}

test_ordinary_spawn_records_route_fields
test_manual_harness_override_records_manual_route
test_raw_launch_command_records_raw_route
test_jt_direct_pr_spawn_appends_pr_intake_governor
test_jt_keyword_id_in_unrelated_project_skips_pr_intake_governor
test_jt_project_without_jt_context_skips_pr_intake_governor
test_jt_openclaw_operator_route_brief_appends_pr_intake_governor
test_unsafe_task_ids_are_rejected_before_spawn
test_empty_window_id_stops_before_post_create_commands
test_malformed_window_id_stops_before_post_create_commands
test_rejected_window_name_removes_new_window
test_window_setup_failures_remove_new_window
test_opted_in_scope_fence_cannot_disappear_before_spawn
test_dangling_scope_marker_cannot_restore_legacy_spawn
test_legacy_scope_fence_text_does_not_opt_in
test_scope_marker_with_extra_bytes_fails
test_foreign_slot_stamp_stops_spawn_before_publication_or_launch
