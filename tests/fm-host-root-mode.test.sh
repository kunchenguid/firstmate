#!/usr/bin/env bash
# Focused behavior tests for the opt-in FM_HOST_ROOT four-root contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-host-root-mode)
LIB="$ROOT/bin/fm-host-root-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

make_host() {
  local path=$1
  fm_git_init_commit "$path"
  : > "$path/AGENTS.md"
  git -C "$path" add AGENTS.md
  git -C "$path" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm instructions
}

make_project_with_origin() {
  local path=$1
  fm_git_init_commit "$path"
  git clone -q --bare "$path" "$path.origin.git"
  git -C "$path" remote add origin "$path.origin.git"
}

node_path() {
  case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) cygpath -w "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

resolve_host() {
  FM_HOST_ROOT=$1 bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT"
}

paths_overlap() {
  bash -c '. "$1"; fm_host_root_paths_overlap "$2" "$3"' _ "$LIB" "$1" "$2"
}

test_resolution_and_validation() {
  local host="$TMP/host with spaces and apostrophe's" link="$TMP/host-link" root="$TMP/firstmate-root" unsafe_target out status=0
  make_host "$host"
  mkdir -p "$root" "$host/private-home"
  ln -s "$host" "$link"
  out=$(resolve_host "$link") || status=$?
  expect_code 0 "$status" "symlinked host root should resolve"
  [ "$out" = "$(cd "$host" && pwd -P)" ] || fail "host root did not resolve physically: $out"

  status=0
  FM_HOST_ROOT="$TMP/missing" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "missing host root must fail"
  status=0
  FM_HOST_ROOT="$ROOT" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "host root equal to FM_ROOT must fail"
  status=0
  FM_HOST_ROOT=$'bad\nroot' bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "newline-unsafe host root must fail"
  status=0
  FM_HOST_ROOT=$'bad\aroot' bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "all metadata-unsafe control characters must fail"
  unsafe_target="$TMP/resolved"$'\n'"host"
  make_host "$unsafe_target"
  ln -s "$unsafe_target" "$TMP/clean-host-link"
  status=0
  FM_HOST_ROOT="$TMP/clean-host-link" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "control characters introduced by physical resolution must fail"
  mkdir -p "$TMP/claude-only-host"
  : > "$TMP/claude-only-host/CLAUDE.md"
  status=0
  FM_HOST_ROOT="$TMP/claude-only-host" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a Claude-only instruction surface must not admit non-Claude workers"
  paths_overlap "$host" "$host" || fail "equal host and target roots were not classified as overlapping"
  paths_overlap "$host" "$host/nested-target" || fail "target nested under host was not classified as overlapping"
  paths_overlap "$host/nested-host" "$host" || fail "host nested under target was not classified as overlapping"
  if paths_overlap "$host" "$TMP/host-with-similar-prefix"; then
    fail "sibling paths with a shared prefix were classified as overlapping"
  fi
  paths_overlap / "$host" || fail "filesystem root was not classified as an ancestor"
  paths_overlap "$host" / || fail "filesystem root was not classified as an enclosing target"
  status=0
  out=$(bash -c '. "$1"; fm_host_root_assert_operational_roots "$2" "$3" "$4"' \
    _ "$LIB" "$host" "$root" "$host/private-home" 2>&1) || status=$?
  expect_code 2 "$status" "host root overlapping FirstMate home must fail"
  assert_contains "$out" 'must not overlap FM_HOME' "operational-root overlap refusal was unclear"
  pass "host-root library resolves physical paths and rejects unsafe, harness-specific, or overlapping roots"
}

test_ambiguous_host_owner_is_rejected() {
  local host="$TMP/ambiguous-owner-host" other="$TMP/ambiguous-owner-other" meta="$TMP/ambiguous-owner.meta" owner="$TMP/ambiguous-owner" out status=0
  make_host "$host"
  make_host "$other"
  printf 'host_root=%s\nhost_root=%s\nkind=ship\n' "$host" "$other" > "$meta"

  out=$(cd "$other" && FM_HOST_ROOT="$other" bash -c \
    '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$meta" 2>&1) || status=$?
  expect_code 2 "$status" "duplicate host_root metadata must not grant task authority"
  assert_contains "$out" 'ambiguous host_root ownership' "duplicate task authority refusal was unclear"

  status=0
  out=$(bash -c '. "$1"; fm_host_root_persist_task_owner "$2" "$3"' \
    _ "$LIB" "$meta" "$owner" 2>&1) || status=$?
  expect_code 2 "$status" "duplicate host_root metadata must not persist owner authority"
  assert_contains "$out" 'ambiguous host_root ownership' "duplicate owner persistence refusal was unclear"
  assert_absent "$owner" "duplicate host_root metadata created an owner record"
  pass "host-root authority rejects duplicate metadata before use or persistence"
}

test_host_owner_publication_is_atomic() {
  local dir="$TMP/owner-publication" meta owner out status=0 mode
  mkdir -p "$dir/fakebin"
  meta="$dir/task.meta"
  owner="$dir/host-root"
  printf 'host_root=%s\n' "$dir/host" > "$meta"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/mv"

  out=$(PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1"; fm_host_root_persist_task_owner "$2" "$3"' _ "$LIB" "$meta" "$owner" 2>&1) || status=$?
  expect_code 2 "$status" "failed host-owner publication must be reported"
  assert_contains "$out" 'could not persist host owner' "failed host-owner publication was not explicit"
  assert_absent "$owner" "failed host-owner publication left a partial durable record"
  [ -z "$(find "$dir" -name 'host-root.tmp.*' -print -quit)" ] \
    || fail "failed host-owner publication left its temporary file"

  bash -c '. "$1"; fm_host_root_persist_task_owner "$2" "$3"' _ "$LIB" "$meta" "$owner" \
    || fail "atomic host-owner publication failed"
  assert_grep "host_root=$dir/host" "$owner" "atomic host-owner publication lost its value"
  if [ "$(uname -s)" = Darwin ]; then
    mode=$(stat -f '%Lp' "$owner")
  else
    mode=$(stat -c '%a' "$owner")
  fi
  [ "$mode" = 600 ] || fail "host-owner publication used mode $mode instead of 600"
  pass "host-owner publication is atomic and leaves no partial durable record"
}

test_session_cwd_mismatch_precedes_mutation() {
  local host="$TMP/session-host" home="$TMP/session-home" overlap_home="$TMP/session-home-link" other="$TMP/session-other" fake_root before after out status=0
  make_host "$host"; mkdir -p "$home/state" "$home/data" "$home/config" "$other"
  ln -s "$host" "$overlap_home"
  before=$(find "$host" -mindepth 1 -maxdepth 3 -print | sort)
  out=$(cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$overlap_home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-session-start.sh" 2>&1) || status=$?
  expect_code 2 "$status" "session-start must reject a physical host and home overlap"
  assert_contains "$out" 'must not overlap FM_HOME' "session-start host/home overlap refusal was unclear"
  after=$(find "$host" -mindepth 1 -maxdepth 3 -print | sort)
  [ "$before" = "$after" ] || fail "session-start mutated the host before rejecting overlapping FM_HOME"

  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-session-start.sh" 2>&1) || status=$?
  expect_code 2 "$status" "session-start host cwd mismatch must fail"
  assert_contains "$out" 'requires the supervisor cwd' "session-start mismatch did not explain the host cwd"
  [ -z "$(find "$home/state" -mindepth 1 -print -quit)" ] || fail "session-start mismatch mutated state before refusal"

  fake_root="$TMP/guard-root"
  mkdir -p "$fake_root/bin"
  : > "$fake_root/AGENTS.md"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_GUARD_MUTATION"
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  status=0
  (cd "$other" && FM_GUARD_MUTATION="$TMP/guard-ran" FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-spawn.sh" guarded "$TMP/missing-project" codex --mode no-mistakes --yolo off >/dev/null 2>&1) || status=$?
  expect_code 2 "$status" "spawn host cwd mismatch must fail"
  assert_absent "$TMP/guard-ran" "spawn ran the supervision guard before host validation"

  status=0
  (cd "$other" && FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" guarded-mate --secondmate --no-projects >/dev/null 2>&1) || status=$?
  expect_code 2 "$status" "secondmate brief host cwd mismatch must fail"
  assert_absent "$home/data/guarded-mate" "secondmate brief mutated task data before host validation"

  status=0
  (cd "$other" && FM_GUARD_MUTATION="$TMP/guard-ran" FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-spawn.sh" guarded-mate "$TMP/missing-home" codex --secondmate >/dev/null 2>&1) || status=$?
  expect_code 2 "$status" "secondmate spawn host cwd mismatch must fail"
  assert_absent "$TMP/guard-ran" "secondmate spawn ran the supervision guard before host validation"
  pass "host cwd mismatch is rejected before session, brief, or spawn mutation"
}

test_unset_session_cannot_take_over_host_owned_home() {
  local host="$TMP/unset-session-host" other="$TMP/other-session-host" home="$TMP/unset-session-home" meta out status=0 before after
  make_host "$host"
  mkdir -p "$home/state" "$home/data" "$home/config"
  meta="$home/state/host-owned.meta"
  fm_write_meta "$meta" \
    "window=@1" "endpoint_task_id=host-owned" "worktree=$TMP/host-owned-worktree" \
    "project=$TMP/host-owned-project" "kind=ship" "host_root=$host" \
    "tmux_window_marker=host-owned-marker" "tmux_socket_path=/tmp/host-owned.sock"
  before=$(find "$home" -mindepth 1 -print | sort)

  out=$(cd "$host" && FM_HOME="$home" FM_HOST_ROOT="$host" bash -c \
    '. "$1"; fm_host_root_assert_session_authority "$2" "$3"' _ "$LIB" "$ROOT" "$home/state" 2>&1) || status=$?
  expect_code 0 "$status" "the recorded host owner should retain session authority"
  [ -z "$out" ] || fail "matching host session authority emitted unexpected output: $out"

  out=$(cd "$ROOT" && env -u FM_HOST_ROOT FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-session-start.sh" 2>&1) || status=$?
  expect_code 2 "$status" "unset session must not take over a host-owned home"
  assert_contains "$out" 'FM_HOST_ROOT is unset' "unset takeover refusal did not identify missing host authority"
  assert_contains "$out" "$host" "unset takeover refusal omitted the recorded host root"
  after=$(find "$home" -mindepth 1 -print | sort)
  [ "$before" = "$after" ] || fail "unset session mutated a host-owned home before refusal"
  assert_absent "$home/state/.lock" "unset session acquired the host-owned session lock"

  make_host "$other"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$other" \
    "$ROOT/bin/fm-session-start.sh" 2>&1) || status=$?
  expect_code 2 "$status" "another host root must not take over a host-owned home"
  assert_contains "$out" 'does not match task metadata' \
    "cross-host takeover refusal did not identify the recorded ownership mismatch"
  after=$(find "$home" -mindepth 1 -print | sort)
  [ "$before" = "$after" ] || fail "another host root mutated the host-owned home before refusal"
  assert_absent "$home/state/.lock" "another host root acquired the host-owned session lock"
  pass "unset or mismatched FM_HOST_ROOT cannot take over a home with host-owned tasks"
}

test_host_command_rendering() {
  local host="$TMP/render & host" home="$TMP/render-home" fake_root="$TMP/FirstMate & root's copy" rendered supervision command argv harness
  make_host "$host"; mkdir -p "$home/state" "$home/config" "$fake_root/bin"
  argv="$TMP/rendered-argv"
  cat > "$fake_root/bin/argv-probe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_ARGV_LOG"
SH
  cp "$fake_root/bin/argv-probe" "$fake_root/bin/fm-watch-checkpoint.sh"
  chmod +x "$fake_root/bin/argv-probe" "$fake_root/bin/fm-watch-checkpoint.sh"
  rendered=$(FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_command "$2" bin/argv-probe' _ "$LIB" "$fake_root")
  FM_ARGV_LOG="$argv" bash -c "$rendered one 'two words' \"apostrophe's\""
  [ "$(cat "$argv")" = $'one\ntwo words\napostrophe\x27s' ] || fail "quoted host command did not preserve argv"

  supervision=$(FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex --repair-line)
  assert_contains "$supervision" "FirstMate & root'\\''s copy/bin'/fm-watch-checkpoint.sh" \
    "host supervision did not shell-quote its absolute command"
  command=$(printf '%s\n' "$supervision" | sed -n 's/.*checkpoint: \(.*\) --seconds.*/\1/p')
  FM_ARGV_LOG="$argv" bash -c "$command --seconds 7"
  [ "$(cat "$argv")" = $'--seconds\n7' ] || fail "rendered supervision command did not preserve argv"
  for harness in claude codex grok; do
    supervision=$(FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
      "$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness")
    assert_contains "$supervision" "FirstMate & root'\\''s copy/bin'/fm-" \
      "$harness ordinary-wake command did not use the absolute FirstMate path"
  done
  pass "host mode shell-quotes absolute commands and preserves argv"
}

test_brief_variants() {
  local host="$TMP/brief & host" home="$TMP/brief-home" brief scout normal_home="$TMP/normal-home"
  make_host "$host"
  mkdir -p "$home/data" "$normal_home/data"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" lane-host alpha --mode no-mistakes >/dev/null 2>&1)
  brief="$home/data/lane-host/brief.md"
  assert_grep '<!-- firstmate-execution-mode: host-root -->' "$brief" "host brief marker missing"
  assert_contains "$(cat "$brief")" "$host" "host brief corrupted the literal supervisor path"
  assert_grep 'process starts inside the isolated target worktree' "$brief" "host brief does not preserve the target cwd"
  assert_grep "target repository's root instructions" "$brief" "host brief does not require target instructions"
  # shellcheck disable=SC2016  # Assertions intentionally match literal worker variables and Markdown code spans.
  assert_contains "$(cat "$brief")" 'Do not read or modify `$FM_HOST_ROOT`' "host brief does not keep unrelated host context out"
  # shellcheck disable=SC2016
  assert_grep 'Run `no-mistakes doctor`' "$brief" "host brief does not use target-native no-mistakes setup"
  # shellcheck disable=SC2016
  assert_contains "$(cat "$brief")" '`no-mistakes axi run --help`' "host brief does not use target-native no-mistakes help"
  # shellcheck disable=SC2016
  assert_contains "$(cat "$brief")" '`no-mistakes axi respond`' "host brief does not use target-native no-mistakes responses"
  # shellcheck disable=SC2016
  assert_not_contains "$(cat "$brief")" '(cd "$FM_TARGET_WORKTREE"' "host brief still wraps target commands from the supervisor cwd"

  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" lane-host-scout alpha --scout >/dev/null 2>&1)
  scout="$home/data/lane-host-scout/brief.md"
  assert_contains "$(cat "$scout")" "(cd '$host' && '$ROOT/bin/fm-decision-hold.sh' complete 'lane-host-scout' --none)" \
    "host scout brief does not invoke the decision lifecycle through a host-scoped FirstMate command"
  assert_grep 'subshell leaves your worker in the isolated target cwd' "$scout" \
    "host scout lifecycle guidance does not preserve the worker target cwd"

  FM_HOME="$normal_home" "$ROOT/bin/fm-brief.sh" lane-normal 'alpha & beta' --mode no-mistakes >/dev/null 2>&1
  assert_no_grep 'firstmate-execution-mode: host-root' "$normal_home/data/lane-normal/brief.md" "default brief changed execution mode"
  assert_contains "$(cat "$normal_home/data/lane-normal/brief.md")" 'alpha & beta' "default brief corrupted the literal repository name"
  assert_grep 'git checkout -b fm/lane-normal' "$normal_home/data/lane-normal/brief.md" "default brief lost its normal branch command"
  pass "brief scaffolding has an explicit host variant and unchanged default variant"
}

test_host_local_only_rejected_before_mutation() {
  local host="$TMP/local-only-host" home="$TMP/local-only-home" project="$TMP/local-only-physical" alias="$TMP/local-only-alias" fake_root="$TMP/local-only-root" guard_marker="$TMP/local-only-guard" out status=0
  make_host "$host"
  make_project_with_origin "$project"
  ln -s "$project" "$alias"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fake_root/bin"
  printf '%s\n%s\n' \
    "- $(basename "$alias") [local-only] - local target (added 2026-07-26)" \
    "- $(basename "$project") [no-mistakes] - physical target (added 2026-07-26)" > "$home/data/projects.md"

  out=$(cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" local-brief "$(basename "$alias")" --mode local-only 2>&1) || status=$?
  expect_code 1 "$status" "host-root brief must reject local-only delivery"
  assert_contains "$out" "host-root mode does not support local-only project" "host-root brief refusal was not explicit"
  assert_absent "$home/data/local-brief" "host-root brief created task data before rejecting local-only delivery"

  cp "$ROOT/bin/fm-project-mode.sh" "$fake_root/bin/fm-project-mode.sh"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_GUARD_MUTATION"
SH
  chmod +x "$fake_root/bin/fm-project-mode.sh" "$fake_root/bin/fm-guard.sh"
  : > "$fake_root/AGENTS.md"
  mkdir -p "$home/data/local-spawn"
  printf '<!-- firstmate-execution-mode: host-root -->\n' > "$home/data/local-spawn/brief.md"
  status=0
  out=$(cd "$host" && FM_GUARD_MUTATION="$guard_marker" FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-spawn.sh" local-spawn "$alias" codex --mode local-only --yolo off 2>&1) || status=$?
  expect_code 1 "$status" "host-root spawn must reject local-only delivery"
  assert_contains "$out" "host-root mode does not support local-only project" "host-root spawn refusal was not explicit"
  assert_absent "$guard_marker" "host-root spawn ran the fleet guard before rejecting local-only delivery"
  assert_absent "$home/state/.spawn-local-spawn.lock" "host-root spawn acquired task state before rejecting local-only delivery"
  assert_absent "$home/state/local-spawn.meta" "host-root spawn wrote task metadata before rejecting local-only delivery"
  pass "host-root local-only tasks are rejected before brief or fleet mutation"
}

make_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\037' "$@" >> "$FM_TMUX_LOG"; printf '\n' >> "$FM_TMUX_LOG"
endpoint=${FM_ENDPOINT_ALIVE:-$FM_CURRENT_PATH.endpoint}
marker_file=${FM_TMUX_MARKER_FILE:-$endpoint.marker}
marker=$(cat "$marker_file" 2>/dev/null || true)
socket_path=${FM_TMUX_SOCKET_PATH:-$FM_CURRENT_PATH.tmux-socket}
if [ "${1:-}" = -S ]; then
  shift 2
fi
if [ "${1:-}" = send-keys ] && printf '%s\n' "$*" | grep -q -- ' -l '; then
  case "${*: -1}" in
    'Read the brief at '*' and follow it exactly.') : ;;
    *) printf '%s' "${*: -1}" > "$FM_LAUNCH_FILE" ;;
  esac
  : > "$FM_LAUNCH_FILE.literal"
  [ "${FM_FAIL_LAUNCH_SEND:-0}" != 1 ] || exit 91
fi
if [ "${1:-}" = send-keys ] && [ "${*: -1}" = Enter ] && [ -f "$FM_LAUNCH_FILE.literal" ]; then
  [ "${FM_FAIL_LAUNCH_ENTER:-0}" != 1 ] || exit 92
fi
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{socket_path}'*) printf '%s\n' "$socket_path" ;;
      *'#{pane_current_path}'*) [ -f "$endpoint" ] && cat "$FM_CURRENT_PATH" ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#{window_id}'*) [ -f "$endpoint" ] && printf '@1\n' ;;
      *'#{pane_id}'*) [ -f "$endpoint" ] && printf '%%1\n' ;;
      *) printf 'test-session\n' ;;
    esac
    ;;
  capture-pane)
    if [ "${FM_FAKE_KIMI:-0}" = 1 ]; then
      printf 'Welcome to Kimi Code!\n│ > │\ncontext: 1%%\n'
    fi
    ;;
  list-windows) [ -z "${FM_EXISTING_WINDOW:-}" ] || printf '%s\n' "$FM_EXISTING_WINDOW" ;;
  list-panes)
    if [[ "$*" == *'#{window_id}|#{@firstmate_task_marker}'* ]] && [[ "$*" != *'#{pane_id}'* ]]; then
      [ -f "$endpoint" ] && printf '@1|%s\n' "$marker"
    elif [ "${FM_TMUX_NUMERIC_NAME_COLLISION:-0}" = 1 ]; then
      printf '%%9|@9|test-session:1|test-session:1.0|test-session:0|test-session:0.0|other\n'
      printf '%%1|@1|%s|%s|%s|%s|%s\n' \
        "${FM_ENDPOINT_TARGET:-test-session:fm-rollback-stuck}" \
        "${FM_ENDPOINT_ALIAS:-test-session:fm-rollback-stuck.0}" \
        "${FM_ENDPOINT_INDEX_ALIAS:-test-session:1}" \
        "${FM_ENDPOINT_INDEX_PANE_ALIAS:-test-session:1.0}" "$marker"
    elif [ "${FM_TMUX_RENUMBER_ON_STOP:-0}" = 1 ]; then
      case "$*" in
        *'#{window_name}.#{pane_index}'*)
          if [ -f "$endpoint" ]; then
            printf '%%1|@1|%s|%s|test-session:1|test-session:1.0|%s\n' \
              "${FM_ENDPOINT_TARGET:-test-session:fm-rollback-stuck}" \
              "${FM_ENDPOINT_ALIAS:-test-session:fm-rollback-stuck.0}" "$marker"
            printf '%%2|@2|test-session:survivor|test-session:survivor.0|test-session:2|test-session:2.0|other\n'
          else
            printf '%%2|@2|test-session:survivor|test-session:survivor.0|test-session:1|test-session:1.0|other\n'
          fi
          ;;
        *)
          if [ -f "$endpoint" ]; then
            printf '%%1|@1|%s|test-session:1|test-session:1.0|%s\n' \
              "${FM_ENDPOINT_TARGET:-test-session:fm-rollback-stuck}" "$marker"
            printf '%%2|@2|test-session:survivor|test-session:2|test-session:2.0|other\n'
          else
            printf '%%2|@2|test-session:survivor|test-session:1|test-session:1.0|other\n'
          fi
          ;;
      esac
    elif [ -f "$endpoint" ]; then
      case "$*" in
        *'#{window_name}.#{pane_index}'*)
          printf '%%1|@1|%s|%s|%s|%s|%s\n' \
            "${FM_ENDPOINT_TARGET:-test-session:fm-rollback-stuck}" \
            "${FM_ENDPOINT_ALIAS:-test-session:fm-rollback-stuck.0}" \
            "${FM_ENDPOINT_INDEX_ALIAS:-test-session:1}" \
            "${FM_ENDPOINT_INDEX_PANE_ALIAS:-test-session:1.0}" "$marker"
          ;;
        *)
          printf '%%1|@1|%s|%s|%s|%s\n' \
            "${FM_ENDPOINT_TARGET:-test-session:fm-rollback-stuck}" \
            "${FM_ENDPOINT_INDEX_ALIAS:-test-session:1}" \
            "${FM_ENDPOINT_INDEX_PANE_ALIAS:-test-session:1.0}" "$marker"
          ;;
      esac
    fi
    ;;
  set-window-option)
    if [ "${*: -2:1}" = @firstmate_task_marker ]; then
      [ "${FM_FAIL_MARKER_SET:-0}" != 1 ] || exit 94
      printf '%s' "${*: -1}" > "$marker_file"
    fi
    ;;
  has-session|new-session) ;;
  new-window) : > "$endpoint"; printf '@1\n' ;;
  kill-window)
    [ -z "${FM_TMUX_KILL_MUTATION:-}" ] || printf 'late worker edit\n' > "$FM_TMUX_KILL_MUTATION"
    [ "${FM_REFUSE_STOP:-0}" = 1 ] || rm -f "$endpoint"
    ;;
  send-keys)
    case "$*" in
      *'treehouse get'*) printf '%s\n' "$FM_TARGET_PATH" > "$FM_CURRENT_PATH" ;;
      *'cd -- '* ) [ "${FM_REFUSE_HOST_MOVE:-0}" = 1 ] || printf '%s\n' "$FM_HOST_PATH" > "$FM_CURRENT_PATH" ;;
    esac
    ;;
esac
SH
  chmod +x "$fb/tmux"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TREEHOUSE_LOG"
[ "${FM_REFUSE_RETURN:-0}" != 1 ] || exit 93
exit 0
SH
  chmod +x "$fb/treehouse"
  cat > "$fb/codex" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_CODEX_ARGV:-}" ] || printf '%s\0' "$@" > "$FM_CODEX_ARGV"
printf 'cwd=%s\nhost=%s\ntarget=%s\n' "$(pwd -P)" "${FM_HOST_ROOT:-}" "${FM_TARGET_WORKTREE:-}" > "$FM_WORKER_OBS"
printf 'target edit\n' > "$FM_TARGET_WORKTREE/worker-edit.txt"
SH
  chmod +x "$fb/codex"
  cat > "$fb/kimi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/kimi"
  printf '%s\n' "$fb"
}

test_spawn_separates_roots() {
  local host="$TMP/spawn & host" home="$TMP/spawn home's \"quoted\" \\ & #%?" project="$TMP/target & repo" wt="$TMP/target & worktree" fb log current launch obs argv turnend meta marker marker_file socket out status=0 before after tree_line launch_line
  make_host "$host"
  mkdir -p "$home/data/lane" "$home/state" "$home/config"
  make_project_with_origin "$project"
  git -C "$project" worktree add -q --detach "$wt"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" lane "$(basename "$project")" --mode no-mistakes >/dev/null 2>&1)
  fb=$(make_fakebin "$TMP/fake")
  log="$TMP/tmux.log"; current="$TMP/current"; launch="$TMP/launch"; obs="$TMP/worker-observation"; argv="$TMP/codex.argv"
  printf '%s\n' "$project" > "$current"
  before=$(git -C "$host" status --porcelain)
  (cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" lane "$project" codex --mode no-mistakes --yolo off > "$TMP/spawn.out" 2>&1) \
    || fail "host-root spawn failed: $(cat "$TMP/spawn.out")"
  meta="$home/state/lane.meta"
  assert_grep "worktree=$wt" "$meta" "spawn meta lost target worktree"
  assert_grep "host_root=$host" "$meta" "spawn meta lost host root"
  assert_grep 'window=@1' "$meta" "host-root spawn did not persist the immutable tmux window id"
  marker=$(sed -n 's/^tmux_window_marker=//p' "$meta")
  socket=$(sed -n 's/^tmux_socket_path=//p' "$meta")
  marker_file="$current.endpoint.marker"
  [ -n "$marker" ] || fail "host-root spawn did not persist a task-owned tmux marker"
  [ "$socket" = "$current.tmux-socket" ] || fail "host-root spawn did not persist its creating tmux socket"
  [ "$(cat "$marker_file")" = "$marker" ] || fail "host-root spawn did not bind the live tmux window to its recorded marker"
  assert_grep $'-S\037'"$socket" "$log" "host-root spawn did not keep task operations on the creating tmux socket"
  assert_contains "$(cat "$log")" "FM_TARGET_WORKTREE='$wt'" "child launch did not export exact target worktree"
  assert_contains "$(cat "$log")" "FM_HOST_ROOT='$host'" "child launch did not export exact host root"
  assert_contains "$(cat "$log")" 'notify=[' "Codex FirstMate turn-end safeguard was not retained"
  [ "$(cat "$current")" = "$wt" ] || fail "endpoint did not remain at the isolated target worktree"
  tree_line=$(grep -nF 'treehouse get' "$log" | head -1 | cut -d: -f1)
  launch_line=$(grep -nF 'FM_TARGET_WORKTREE=' "$log" | head -1 | cut -d: -f1)
  [ "$tree_line" -lt "$launch_line" ] || fail "spawn order was not worktree then harness"
  assert_no_grep 'cd --' "$log" "spawn returned the worker endpoint to the supervisor host"
  (cd "$wt" && PATH="$fb:$PATH" FM_WORKER_OBS="$obs" FM_CODEX_ARGV="$argv" bash -c "$(cat "$launch")")
  assert_grep "cwd=$wt" "$obs" "worker harness did not start from the isolated target worktree"
  assert_grep "host=$host" "$obs" "worker did not receive the exact host root"
  assert_grep "target=$wt" "$obs" "worker did not receive the exact target worktree"
  turnend="$(cd "$home/state" && pwd -P)/lane.turn-ended"
python3 - "$argv" "$turnend" <<'PY' || fail "Codex notify argv did not preserve the hostile turn-end path"
import pathlib, subprocess, sys, tomllib
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
args = [a.decode() for a in args if a]
assert args.count("-c") == 1, args
i = args.index("-c")
config = args[i + 1]
notify = tomllib.loads(config)["notify"]
assert pathlib.Path(notify[0]).is_absolute(), notify
assert pathlib.Path(notify[0]).name.lower() in {"bash", "bash.exe"}, notify
assert notify[1] == "-c", notify
subprocess.run(notify, check=True)
PY
  assert_present "$turnend" "Codex notify command did not touch the exact hostile path"
  assert_present "$wt/worker-edit.txt" "disposable worker probe did not edit the target worktree"
  assert_absent "$host/worker-edit.txt" "disposable worker probe edited the host root"
  after=$(git -C "$host" status --porcelain)
  [ "$before" = "$after" ] || fail "host working tree changed during spawn or worker probe"
  printf 'another-task' > "$marker_file"
  : > "$log"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-send.sh" lane hello 2>&1) || status=$?
  expect_code 2 "$status" "host-root send trusted a reused tmux window id"
  assert_contains "$out" 'recorded tmux window identity does not match' "reused tmux window refusal was not explicit"
  assert_no_grep 'send-keys' "$log" "host-root send targeted a tmux window owned by another task"
  pass "spawn binds host-root tmux actions to a task-owned window marker"
}

test_duplicate_spawn_preserves_existing_task() {
  local host="$TMP/duplicate-host" home="$TMP/duplicate-home" project="$TMP/duplicate-target" fb log current launch out status=0
  make_host "$host"
  make_project_with_origin "$project"
  mkdir -p "$home/data/lane" "$home/state" "$home/config"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" lane target --mode no-mistakes >/dev/null 2>&1)
  printf 'window=test-session:fm-lane\nworktree=/tmp/existing-worktree\nhost_root=%s\nproject=%s\nkind=ship\n' \
    "$host" "$project" > "$home/state/lane.meta"
  printf 'working: existing task\n' > "$home/state/lane.status"
  cp "$home/state/lane.meta" "$TMP/existing.meta"
  cp "$home/state/lane.status" "$TMP/existing.status"
  fb=$(make_fakebin "$TMP/fake-duplicate")
  log="$TMP/duplicate.log"; current="$TMP/duplicate.current"; launch="$TMP/duplicate.launch"
  printf '%s\n' "$project" > "$current"
  : > "$current.endpoint"

  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_EXISTING_WINDOW=fm-lane FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH=/tmp/unused FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" lane "$project" codex --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "duplicate spawn unexpectedly succeeded"
  assert_contains "$out" 'task metadata already exists for lane' "duplicate spawn refusal was not explicit"
  assert_no_grep 'kill-window' "$log" "duplicate spawn killed the existing task endpoint"
  cmp -s "$TMP/existing.meta" "$home/state/lane.meta" || fail "duplicate spawn changed existing metadata"
  cmp -s "$TMP/existing.status" "$home/state/lane.status" || fail "duplicate spawn changed existing status"
  assert_present "$current.endpoint" "duplicate spawn removed the existing endpoint"
  rm -f "$current.endpoint"
  : > "$log"
  status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH=/tmp/unused FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" lane "$project" codex --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "retained metadata admitted a same-id spawn after its endpoint disappeared"
  assert_contains "$out" 'task metadata already exists for lane' "retained metadata refusal was not explicit"
  [ ! -s "$log" ] || fail "retained metadata retry inspected or created a backend endpoint"
  cmp -s "$TMP/existing.meta" "$home/state/lane.meta" || fail "retained metadata retry changed the recovery record"
  cmp -s "$TMP/existing.status" "$home/state/lane.status" || fail "retained metadata retry changed existing status"
  pass "duplicate spawn preserves live and endpoint-free retained task records"
}

test_unset_herdr_retry_reaches_existing_identity_checks() {
  local home="$TMP/unset-herdr-home" project="$TMP/unset-herdr-project" fb out status=0
  make_project_with_origin "$project"
  mkdir -p "$home/data/herdr-retry" "$home/state" "$home/config"
  printf 'Retry existing Herdr task.\n' > "$home/data/herdr-retry/brief.md"
  : > "$home/config/herdr-presentation-spaces"
  {
    printf 'window=default:old-pane\n'
    printf 'worktree=/tmp/old-herdr-worktree\n'
    printf 'project=%s\n' "$project"
    printf 'harness=codex\n'
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'backend=herdr\n'
    printf 'herdr_session=default\n'
    printf 'herdr_workspace_id=old-workspace\n'
    printf 'herdr_tab_id=old-tab\n'
    printf 'herdr_pane_id=old-pane\n'
  } > "$home/state/herdr-retry.meta"
  printf 'journal\n' > "$home/state/herdr-retry.herdr-presentation"
  cp "$home/state/herdr-retry.meta" "$TMP/unset-herdr.meta"
  fb=$(fm_fakebin "$TMP/fake-unset-herdr")
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' status --json '*) printf '%s\n' '{"server":{"running":true}}' ;;
  *' session list --json '*) printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fake-herdr.sock"}]}' ;;
  *' pane get old-pane '*) printf '%s\n' '{"result":{"pane":{"pane_id":"old-pane"}}}' ;;
  *' agent get old-pane '*) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/herdr"

  out=$(env -u FM_HOST_ROOT PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-spawn.sh" herdr-retry "$project" codex --backend herdr --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unset-mode Herdr retry bypassed its live-endpoint refusal"
  assert_contains "$out" 'existing herdr endpoint for herdr-retry is live' \
    "unset-mode retry did not reach the established Herdr identity classifier"
  assert_not_contains "$out" 'task metadata already exists for herdr-retry' \
    "host-root metadata protection leaked into unset-mode Herdr recovery"
  cmp -s "$TMP/unset-herdr.meta" "$home/state/herdr-retry.meta" \
    || fail "unset-mode Herdr identity refusal changed existing metadata"
  pass "unset-mode Herdr retries retain their established same-identity recovery checks"
}

test_spawn_rejects_host_as_target() {
  local host="$TMP/refusal-host" home="$TMP/refusal-home" project="$TMP/refusal-target" fb log current tree_log out status=0
  make_host "$host"
  mkdir -p "$home/data/host-target" "$home/state" "$home/config"
  make_project_with_origin "$project"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" host-target target --mode no-mistakes >/dev/null 2>&1)
  fb=$(make_fakebin "$TMP/fake-refusals")
  log="$TMP/refusals.log"; current="$TMP/refusals.current"; tree_log="$TMP/treehouse.log"

  printf '%s\n' "$project" > "$current"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_ENDPOINT_TARGET=test-session:fm-host-target \
    FM_LAUNCH_FILE="$TMP/refusal.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$host" \
    FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" host-target "$project" codex --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted FM_HOST_ROOT as the target worktree"
  assert_contains "$out" 'overlapping host and target roots' "host-as-target refusal was not explicit"
  assert_contains "$(cat "$log")" 'kill-window' "host-as-target refusal leaked its tmux endpoint"
  assert_no_grep 'return --force' "$tree_log" "host-as-target refusal tried to recycle the authoritative host path"
  assert_present "$home/state/host-target.meta" "host-as-target refusal lost recovery metadata for the preserved path"
  pass "host overlap preserves the authoritative host path"
}

test_orca_active_cwd_probe() {
  local out
  out=$(bash -c '
    . "$1/bin/backends/orca.sh"
    fm_backend_orca_send_text_line() {
      markers=$(printf "%s\n" "$2" | grep -o "__FM_ORCA_CWD_[A-Z]*_[A-Za-z0-9_]*__")
      begin=$(printf "%s\n" "$markers" | head -1)
      end=$(printf "%s\n" "$markers" | tail -1)
    }
    fm_backend_orca_read_text_paged() {
      printf "%s\n" "$begin" "/tmp/orca host" "$end"
    }
    fm_backend_orca_current_path terminal-1
  ' _ "$ROOT")
  [ "$out" = "/tmp/orca host" ] || fail "Orca active cwd probe returned '$out'"
  pass "Orca backend reads the live shell cwd through a bounded marker probe"
}

test_all_harnesses_add_one_task_safeguard() {
  local host="$TMP/adapters-host" home="$TMP/adapter home's #%?" project="$TMP/adapters-target" before after harness id wt fb log current launch text count out status=0
  make_host "$host"
  make_project_with_origin "$project"
  mkdir -p "$home/data" "$home/state" "$home/config"
  mkdir -p "$TMP/harness-home/.kimi-code"
  printf 'default_model = "test"\n' > "$TMP/harness-home/.kimi-code/config.toml"
  before=$(git -C "$host" status --porcelain)
  for harness in claude codex opencode pi grok kimi; do
    id="adapter-$harness"
    wt="$TMP/$id-wt"
    git -C "$project" worktree add -q --detach "$wt"
    (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" "$id" "$(basename "$project")" --mode no-mistakes >/dev/null 2>&1)
    fb=$(make_fakebin "$TMP/fake-$harness")
    log="$TMP/$id.log"; current="$TMP/$id.current"; launch="$TMP/$id.launch"
    printf '%s\n' "$project" > "$current"
    (cd "$host" && HOME="$TMP/harness-home" PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
      FM_FAKE_KIMI=1 FM_KIMI_READY_POLLS=1 FM_KIMI_DELIVERY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 \
      FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" TMUX=fake \
      "$ROOT/bin/fm-spawn.sh" "$id" "$project" "$harness" --mode no-mistakes --yolo off >/dev/null)
    text=$(cat "$launch")
    bash -n -c "$text" || fail "$harness host-root launch is not valid shell"
    case "$harness" in
      claude)
        count=$(printf '%s' "$text" | grep -o -- '--settings' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Claude task settings appeared $count times"
        assert_present "$home/state/$id.claude-settings.json" "Claude task settings file missing"
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$(node_path "$home/state/$id.claude-settings.json")" \
          || fail "Claude task settings are invalid JSON"
        ;;
      codex)
        count=$(printf '%s' "$text" | grep -oF 'notify=[' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Codex notify safeguard appeared $count times"
        ;;
      opencode)
        count=$(printf '%s' "$text" | grep -oF 'opencode-turn-end.js' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "OpenCode task plugin appeared $count times"
        assert_present "$home/state/$id.opencode-turn-end.js" "OpenCode task plugin missing"
        case $(uname -s) in
          MINGW*|MSYS*) assert_contains "$text" '%23%25%EF%80%BF' "OpenCode task plugin file URL did not encode MSYS path metacharacters" ;;
          *) assert_contains "$text" '%23%25%3F' "OpenCode task plugin file URL did not encode path metacharacters" ;;
        esac
        node --check "$(node_path "$home/state/$id.opencode-turn-end.js")" >/dev/null \
          || fail "OpenCode task plugin is invalid JavaScript"
        ;;
      pi)
        count=$(printf '%s' "$text" | grep -oF "$id.pi-ext.ts" | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Pi task extension appeared $count times"
        assert_present "$home/state/$id.pi-ext.ts" "Pi task extension missing"
        ;;
      grok)
        count=$(printf '%s' "$text" | grep -oF 'FM_GROK_TURNEND_TOKEN=' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Grok task token appeared $count times"
        assert_absent "$host/.fm-grok-turnend" "Grok host launch wrote a task pointer into the host"
        ;;
      kimi)
        count=$(printf '%s' "$text" | grep -oF 'FM_KIMI_TURNEND_TOKEN=' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Kimi task token appeared $count times"
        assert_present "$home/state/$id.kimi-turnend-token" "Kimi task token state is missing"
        assert_absent "$host/.fm-kimi-turnend" "Kimi host launch wrote a task pointer into the host"
        ;;
    esac
    rm -rf "/tmp/fm-$id"
  done

  id=adapter-raw
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" "$id" "$(basename "$project")" --mode no-mistakes >/dev/null 2>&1)
  out=$(cd "$host" && FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" 'claude --dangerously-skip-permissions' --mode no-mistakes --yolo off 2>&1) || status=$?
  expect_code 2 "$status" "host mode must reject a raw launch command without a verified task safeguard"
  assert_contains "$out" 'requires a named verified harness' "raw host launch refusal was not explicit"
  assert_absent "$home/state/$id.meta" "raw host launch mutated task state before refusal"

  after=$(git -C "$host" status --porcelain)
  [ "$before" = "$after" ] || fail "harness integration rewrote host configuration"
  pass "all six harnesses add one task safeguard without changing host hooks"
}

test_mutators_require_host_cwd() {
  local host="$TMP/mutator-host" other="$TMP/mutator-other" home="$TMP/mutator-home" fake_root="$TMP/mutator-root" guard_marker="$TMP/mutator-guard" fb log current out status=0
  make_host "$host"
  mkdir -p "$other" "$home/state" "$fake_root/bin"
  printf 'window=fake:fm-lane\nworktree=/tmp/target\nhost_root=%s\nproject=/tmp/project\nkind=ship\n' "$host" > "$home/state/lane.meta"
  printf 'window=fake:fm-scout\nworktree=/tmp/scout\nhost_root=%s\nproject=/tmp/project\nkind=scout\n' "$host" > "$home/state/scout.meta"
  fb=$(make_fakebin "$TMP/fake-mutator-read")
  log="$TMP/mutator-read.log"
  current="$TMP/mutator-read.current"
  : > "$log"
  printf '%s\n' "$host" > "$current"
  out=$(cd "$other" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_CURRENT_PATH="$current" "$ROOT/bin/fm-peek.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-peek must reject a host cwd mismatch"
  assert_contains "$out" 'requires the recorded host root cwd' "fm-peek host mismatch was not explicit"
  [ ! -s "$log" ] || fail "fm-peek inspected the endpoint before host validation"
  status=0
  out=$(cd "$other" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_CURRENT_PATH="$current" "$ROOT/bin/fm-crew-state.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-crew-state must reject a host cwd mismatch"
  assert_contains "$out" 'requires the recorded host root cwd' "fm-crew-state host mismatch was not explicit"
  [ ! -s "$log" ] || fail "fm-crew-state inspected the endpoint before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-send.sh" lane hello 2>&1) || status=$?
  expect_code 2 "$status" "fm-send must reject a host cwd mismatch"
  assert_contains "$out" 'requires the recorded host root cwd' "fm-send host mismatch was not explicit"
  status=0
  out=$(cd "$other" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_CURRENT_PATH="$current" "$ROOT/bin/fm-control.sh" lane interrupt 2>&1) || status=$?
  expect_code 2 "$status" "fm-control must reject a host cwd mismatch"
  assert_contains "$out" 'requires the recorded host root cwd' "fm-control host mismatch was not explicit"
  [ ! -s "$log" ] || fail "fm-control inspected or signaled an endpoint before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-teardown.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-teardown must reject a host cwd mismatch"
  assert_present "$home/state/lane.meta" "teardown mutated task state before host validation"
  printf 'mode=local-only\n' >> "$home/state/lane.meta"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-merge-local.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-merge-local must reject a host cwd mismatch"
  assert_present "$home/state/lane.meta" "local merge mutated task state before host validation"
  status=0
  out=$(cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-merge-local.sh" lane 2>&1) || status=$?
  expect_code 1 "$status" "fm-merge-local must refuse host-root local-only tasks"
  assert_contains "$out" 'local-only merge is unavailable for host-root task' "host-root local merge refusal was not explicit"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-pr-merge.sh" lane https://github.com/example/repo/pull/1 2>&1) || status=$?
  expect_code 2 "$status" "fm-pr-merge must reject a host cwd mismatch"
  assert_present "$home/state/lane.meta" "PR merge mutated task state before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-pr-check.sh" lane https://github.com/example/repo/pull/1 2>&1) || status=$?
  expect_code 2 "$status" "fm-pr-check must reject a host cwd mismatch"
  if grep -q '^pr=' "$home/state/lane.meta"; then
    fail "PR check mutated task metadata before host validation"
  fi
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-review-diff.sh" lane --stat 2>&1) || status=$?
  expect_code 2 "$status" "fm-review-diff must reject a host cwd mismatch"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-promote.sh" scout --mode no-mistakes --yolo off 2>&1) || status=$?
  expect_code 2 "$status" "fm-promote must reject a host cwd mismatch"
  grep -qx 'kind=scout' "$home/state/scout.meta" || fail "promote mutated task metadata before host validation"
  printf 'mode=local-only\n' >> "$home/state/scout.meta"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_GUARD_MUTATION"
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  status=0
  out=$(cd "$host" && FM_GUARD_MUTATION="$guard_marker" FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-promote.sh" scout --mode local-only --yolo off 2>&1) || status=$?
  expect_code 1 "$status" "fm-promote must reject a host-root local-only scout"
  assert_contains "$out" 'host-root mode does not support promoting local-only scout' "host-root local-only promotion refusal was not explicit"
  assert_absent "$guard_marker" "host-root promotion ran the fleet guard before rejecting local-only delivery"
  grep -qx 'kind=scout' "$home/state/scout.meta" || fail "local-only promotion mutated task metadata"
  sed -i '/^mode=local-only$/d' "$home/state/scout.meta"
  status=0
  out=$(cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-promote.sh" scout --mode no-mistakes --yolo off 2>&1) || status=$?
  expect_code 0 "$status" "fm-promote rejected a recorded host-root scout"
  assert_contains "$out" "'$ROOT/bin/fm-send.sh'" "host-root promotion did not print a quoted absolute fm-send path"
  # shellcheck disable=SC2016  # Assertions intentionally match literal worker variables.
  assert_contains "$out" 'git -C "$FM_TARGET_WORKTREE" status' "host-root promotion did not scope scratch status"
  # shellcheck disable=SC2016
  assert_contains "$out" 'git -C "$FM_TARGET_WORKTREE" log' "host-root promotion did not scope scratch history"
  # shellcheck disable=SC2016
  assert_contains "$out" 'git -C "$FM_TARGET_WORKTREE" checkout -b fm/scout' "host-root promotion did not scope branch creation"
  # shellcheck disable=SC2016
  assert_contains "$out" '(cd "$FM_TARGET_WORKTREE" && ...)' "host-root promotion did not scope validation commands"
  printf 'window=fake:fm-plain\nworktree=/tmp/plain\nproject=/tmp/project\nkind=scout\n' > "$home/state/plain.meta"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-promote.sh" plain --mode no-mistakes --yolo off 2>&1) || status=$?
  expect_code 0 "$status" "fm-promote changed default-mode promotion"
  assert_contains "$out" '<ship instructions for mode=no-mistakes: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/plain; implement; report done>' "default-mode promotion instructions changed"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-check-register.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-check-register must reject a host cwd mismatch"
  assert_absent "$home/state/lane.check-trust" "check registration mutated trust state before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-decision-hold.sh" complete lane --none 2>&1) || status=$?
  expect_code 2 "$status" "fm-decision-hold must reject a host cwd mismatch"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-x-followup.sh" --check lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-x-followup must reject a host cwd mismatch"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-x-link.sh" lane request-1 2>&1) || status=$?
  expect_code 2 "$status" "fm-x-link must reject a host cwd mismatch"
  pass "task lifecycle actions reject host cwd mismatch before mutation"
}

test_secondmate_actions_keep_supervisor_host_authority() {
  local host="$TMP/secondmate-action-host" other="$TMP/secondmate-action-other" meta="$TMP/secondmate-action.meta" ordinary="$TMP/ordinary-action.meta" out status=0
  make_host "$host"
  mkdir -p "$other"
  printf 'window=fm-mate\nworktree=/tmp/mate\nkind=secondmate\n' > "$meta"
  printf 'window=fm-task\nworktree=/tmp/task\nkind=ship\n' > "$ordinary"

  (cd "$host" && FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$meta") \
    || status=$?
  expect_code 0 "$status" "secondmate action should use the primary supervisor host cwd without host_root metadata"

  status=0
  out=$(cd "$other" && FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$meta" 2>&1) \
    || status=$?
  expect_code 2 "$status" "secondmate action must still reject a supervisor host cwd mismatch"
  assert_contains "$out" 'requires the supervisor cwd' "secondmate cwd mismatch did not preserve primary host authority"

  status=0
  (cd "$host" && FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$ordinary") \
    || status=$?
  expect_code 0 "$status" "legacy task should remain operable from the enabled supervisor host cwd"

  status=0
  out=$(cd "$other" && FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$ordinary" 2>&1) \
    || status=$?
  expect_code 2 "$status" "legacy task must still reject a supervisor host cwd mismatch"
  assert_contains "$out" 'requires the supervisor cwd' "legacy task cwd mismatch did not preserve primary host authority"
  pass "legacy and secondmate actions retain primary host cwd authority without host_root metadata"
}

test_spawn_rollback_is_transactional() {
  local host="$TMP/rollback-host" home="$TMP/rollback-home" project="$TMP/rollback-target" wt="$TMP/rollback-wt" stuck_wt="$TMP/rollback-stuck-wt" scout_wt="$TMP/rollback-scout-wt" uncertain_wt="$TMP/rollback-uncertain-wt" retained_wt="$TMP/rollback-retained-wt" unset_wt="$TMP/rollback-unset-wt" fb log current tree_log out status=0
  make_host "$host"; mkdir -p "$home/data" "$home/state" "$home/config"; make_project_with_origin "$project"
  git -C "$project" worktree add -q --detach "$wt"
  git -C "$project" worktree add -q --detach "$stuck_wt"
  git -C "$project" worktree add -q --detach "$scout_wt"
  git -C "$project" worktree add -q --detach "$uncertain_wt"
  git -C "$project" worktree add -q --detach "$retained_wt"
  git -C "$project" worktree add -q --detach "$unset_wt"
  for id in rollback-marker rollback-clean rollback-stuck rollback-uncertain rollback-retained; do
    (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
      "$ROOT/bin/fm-brief.sh" "$id" target --mode no-mistakes >/dev/null 2>&1)
  done
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" rollback-scout target --scout >/dev/null 2>&1)
  fb=$(make_fakebin "$TMP/fake-rollback")
  printf '#!/usr/bin/env bash\nexit 99\n' > "$fb/node"
  chmod +x "$fb/node"
  log="$TMP/rollback.log"; current="$TMP/rollback.current"; tree_log="$TMP/rollback-treehouse.log"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_MARKER_SET=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-rollback-marker FM_LAUNCH_FILE="$TMP/rollback-marker.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-marker "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected tmux marker failure unexpectedly succeeded"
  assert_no_grep 'kill-window' "$log" "marker failure bypassed ownership verification during rollback"
  assert_no_grep 'return --force' "$tree_log" "marker failure recycled a worktree before endpoint absence was confirmed"
  assert_present "$home/state/rollback-marker.meta" "marker failure lost recovery metadata"
  assert_grep 'window=@1' "$home/state/rollback-marker.meta" "marker failure did not record the created tmux window id"
  assert_grep 'tmux_window_marker=' "$home/state/rollback-marker.meta" "marker failure did not retain its intended ownership marker"
  assert_grep 'tmux_socket_path=' "$home/state/rollback-marker.meta" "marker failure did not retain its creating socket"
  assert_present "$current.endpoint" "marker failure lost the unconfirmed live endpoint"
  rm -f "$home/state/rollback-marker.meta" "$current.endpoint"

  printf '%s\n' "$project" > "$current"
  touch "$home/state/rollback-clean.busy"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_SEND=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-rollback-clean FM_LAUNCH_FILE="$TMP/rollback.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-clean "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected launch failure unexpectedly succeeded"
  assert_grep 'return --force' "$tree_log" "successful rollback did not return the isolated copy"
  assert_absent "$home/state/rollback-clean.meta" "successful rollback left metadata"
  assert_absent "$home/state/rollback-clean.pi-ext.ts" "successful rollback left its pre-record Pi artifact"
  assert_absent "$home/state/rollback-clean.busy" "successful rollback left legacy busy state"
  assert_absent "$home/state/rollback-clean.busy-state" "successful rollback left semantic busy state"
  assert_absent "$home/state/rollback-clean.busy-gen" "successful rollback left semantic busy generation"
  assert_absent "/tmp/fm-rollback-clean" "successful rollback left its task temp root"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_SEND=1 FM_REFUSE_STOP=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-rollback-stuck FM_LAUNCH_FILE="$TMP/rollback-stuck.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$stuck_wt" FM_HOST_PATH="$host" \
    FM_TREEHOUSE_LOG="$tree_log" TMUX=fake "$ROOT/bin/fm-spawn.sh" rollback-stuck "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected stop failure unexpectedly succeeded"
  assert_contains "$out" 'still exists after stop' "failed endpoint termination was not explicit (backend log: $(tr '\n' ';' < "$log"))"
  assert_no_grep 'return --force' "$tree_log" "rollback reused the isolated copy after unconfirmed termination"
  assert_present "$home/state/rollback-stuck.meta" "failed rollback lost recovery metadata"
  assert_grep 'endpoint_task_id=rollback-stuck' "$home/state/rollback-stuck.meta" \
    "failed rollback metadata lost its endpoint task binding"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" bash -c \
    '. "$1"; fm_backend_validate_task_endpoint "$2" "$3"' _ "$ROOT/bin/fm-backend.sh" \
    "$home/state/rollback-stuck.meta" rollback-stuck \
    || fail "failed rollback metadata could not pass endpoint recovery validation"
  assert_present "$home/state/rollback-stuck.pi-ext.ts" "failed rollback discarded a recoverable pre-record artifact"
  assert_present "/tmp/fm-rollback-stuck" "failed rollback discarded its recoverable task temp root"
  rm -rf "/tmp/fm-rollback-stuck"
  rm -f "$home/state/rollback-stuck.meta" "$home/state/rollback-stuck.pi-ext.ts" "$current.endpoint"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_SEND=1 FM_REFUSE_STOP=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-rollback-scout FM_LAUNCH_FILE="$TMP/rollback-scout.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$scout_wt" FM_HOST_PATH="$host" \
    FM_TREEHOUSE_LOG="$tree_log" TMUX=fake "$ROOT/bin/fm-spawn.sh" rollback-scout "$project" pi --scout 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected scout stop failure unexpectedly succeeded"
  assert_present "$home/state/rollback-scout.meta" "failed scout rollback lost recovery metadata"
  assert_no_grep 'mode=' "$home/state/rollback-scout.meta" "failed scout rollback fabricated a delivery mode"
  assert_no_grep 'yolo=' "$home/state/rollback-scout.meta" "failed scout rollback fabricated delivery authority"
  rm -rf "/tmp/fm-rollback-scout"
  rm -f "$home/state/rollback-scout.meta" "$home/state/rollback-scout.pi-ext.ts" "$current.endpoint"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_ENTER=1 FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/rollback-uncertain.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$uncertain_wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-uncertain "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "ambiguous Enter failure unexpectedly succeeded"
  assert_contains "$out" 'launch submission could not be confirmed' "ambiguous Enter failure did not explain the retained task"
  assert_no_grep 'kill-window' "$log" "ambiguous Enter failure killed a possibly running worker"
  assert_no_grep 'return --force' "$tree_log" "ambiguous Enter failure recycled a possibly active worktree"
  assert_present "$home/state/rollback-uncertain.meta" "ambiguous Enter failure lost task metadata"
  assert_present "$home/state/rollback-uncertain.pi-ext.ts" "ambiguous Enter failure lost its task safeguard"
  assert_present "/tmp/fm-rollback-uncertain" "ambiguous Enter failure removed its task temp root"
  rm -rf "/tmp/fm-rollback-uncertain"
  rm -f "$home/state/rollback-uncertain.meta" "$home/state/rollback-uncertain.pi-ext.ts" "$current.endpoint"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_SEND=1 FM_REFUSE_RETURN=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-rollback-retained FM_LAUNCH_FILE="$TMP/rollback-retained.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$retained_wt" FM_HOST_PATH="$host" \
    FM_TREEHOUSE_LOG="$tree_log" TMUX=fake "$ROOT/bin/fm-spawn.sh" rollback-retained "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected worktree return failure unexpectedly succeeded"
  assert_present "$home/state/rollback-retained.meta" "worktree return failure lost recovery metadata"
  assert_absent "$current.endpoint" "worktree return failure left the stopped endpoint alive"
  cp "$home/state/rollback-retained.meta" "$TMP/rollback-retained.meta"
  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/rollback-retained-retry.launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-retained "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "same-id retry overwrote retained cleanup metadata"
  assert_contains "$out" 'task metadata already exists for rollback-retained' "retained cleanup retry refusal was not explicit"
  [ ! -s "$log" ] || fail "retained cleanup retry inspected or created an endpoint"
  [ ! -s "$tree_log" ] || fail "retained cleanup retry allocated or returned a worktree"
  cmp -s "$TMP/rollback-retained.meta" "$home/state/rollback-retained.meta" || fail "retained cleanup retry changed the recovery record"

  : > "$log"; : > "$tree_log"; status=0
  out=$(cd "$host" && env -u FM_HOST_ROOT PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/rollback-retained-unset-retry.launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-retained "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unset retry overwrote retained host cleanup metadata"
  assert_contains "$out" 'task metadata already exists for rollback-retained' "unset retained-host retry refusal was not explicit"
  [ ! -s "$log" ] || fail "unset retained-host retry inspected or created an endpoint"
  [ ! -s "$tree_log" ] || fail "unset retained-host retry allocated or returned a worktree"
  cmp -s "$TMP/rollback-retained.meta" "$home/state/rollback-retained.meta" || fail "unset retry changed the retained host recovery record"
  rm -rf "/tmp/fm-rollback-retained"
  rm -f "$home/state/rollback-retained.meta" "$home/state/rollback-retained.pi-ext.ts"

  env -u FM_HOST_ROOT FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" rollback-unset target --mode no-mistakes >/dev/null 2>&1
  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && env -u FM_HOST_ROOT PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_FAIL_LAUNCH_SEND=1 FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/rollback-unset.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$unset_wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-unset "$project" pi --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unset-mode injected launch failure unexpectedly succeeded"
  assert_no_grep 'kill-window' "$log" "unset-mode launch failure changed upstream endpoint cleanup"
  assert_no_grep 'return --force' "$tree_log" "unset-mode launch failure changed upstream worktree cleanup"
  assert_present "$home/state/rollback-unset.meta" "unset-mode launch failure removed upstream task metadata"
  assert_present "$current.endpoint" "unset-mode launch failure stopped the endpoint"
  rm -rf "/tmp/fm-rollback-unset"
  rm -f "$home/state/rollback-unset.meta" "$home/state/rollback-unset.pi-ext.ts" "$current.endpoint"
  pass "spawn rollback stays host-scoped and preserves ambiguous launch submissions"
}

test_decision_actions_use_durable_host_owner() {
  local host="$TMP/decision-host" wrong="$TMP/decision-wrong" home="$TMP/decision-home" id=decision-scout action action_id fb owner out status=0 current log tree_log
  make_host "$host"
  make_host "$wrong"
  mkdir -p "$home/data/$id" "$home/state" "$home/config"
  printf '# Decision report\n' > "$home/data/$id/report.md"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf 'window=fake:fm-%s\nworktree=/tmp/decision-target\nhost_root=%s\nproject=/tmp/project\nkind=scout\n' \
    "$id" "$host" > "$home/state/$id.meta"
  fb=$(make_fakebin "$TMP/fake-decision-owner")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' 'tasks-axi 0.2.4' ;;
  "update --help") printf '%s\n' '--archive-body' ;;
  "mv --help") printf '%s\n' '[<id>...]' ;;
  "hold --help") printf '%s\n' '--kind captain' ;;
esac
SH
  chmod +x "$fb/tasks-axi"
  (cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none >/dev/null) \
    || fail "live host-root completion could not persist ownership"
  owner="$home/data/$id/host-root"
  assert_grep "host_root=$host" "$owner" "completion did not persist the recorded host owner"
  rm "$home/state/$id.meta"
  (cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none >/dev/null) \
    || fail "post-metadata completion rejected its durable host owner"
  rm "$owner"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none 2>&1) || status=$?
  expect_code 1 "$status" "post-metadata completion trusted ambient host authority"
  assert_contains "$out" 'has no durable recorded host owner' "missing durable host owner refusal was not explicit"

  current="$TMP/decision.current"
  log="$TMP/decision.log"
  tree_log="$TMP/decision-treehouse.log"
  for action in hold complete resolve decline repair; do
    action_id="decision-post-teardown-$action"
    mkdir -p "$home/data/$action_id"
printf 'window=test-session:fm-%s\nendpoint_task_id=%s\nworktree=/tmp/decision-target\nhost_root=%s\nproject=/tmp/project\nkind=ship\nmode=local-only\ntmux_window_marker=decision-marker\ntmux_socket_path=/tmp/fm-test.sock\n' \
"$action_id" "$action_id" "$host" > "$home/state/$action_id.meta"
    printf '%s\n' "$host" > "$current"
    : > "$current.endpoint"
    printf 'decision-marker' > "$current.endpoint.marker"
    : > "$log"
    : > "$tree_log"
    (cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
      FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
      FM_ENDPOINT_TARGET="test-session:fm-$action_id" FM_LAUNCH_FILE="$TMP/unused.launch" \
      FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/decision-target FM_HOST_PATH="$host" \
      FM_TREEHOUSE_LOG="$tree_log" TMUX=fake "$ROOT/bin/fm-teardown.sh" "$action_id" --force >/dev/null) \
      || fail "host-root teardown failed before the first post-teardown $action action"
    assert_absent "$home/state/$action_id.meta" "teardown retained metadata before the $action authority check"
    assert_grep "host_root=$host" "$home/data/$action_id/host-root" \
      "teardown did not persist ownership before the $action authority check"
    status=0
    case "$action" in
      hold)
        out=$(cd "$wrong" && env -u FM_HOST_ROOT PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
          "$ROOT/bin/fm-decision-hold.sh" hold "$action_id" choice --title Choice --reason required 2>&1) || status=$?
        ;;
      complete)
        out=$(cd "$wrong" && env -u FM_HOST_ROOT PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
          "$ROOT/bin/fm-decision-hold.sh" complete "$action_id" --none 2>&1) || status=$?
        ;;
      resolve)
        out=$(cd "$wrong" && env -u FM_HOST_ROOT PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
          "$ROOT/bin/fm-decision-hold.sh" resolve "$action_id" choice \
            --decision-file "$TMP/missing-decision" --routed-to routed-task 2>&1) || status=$?
        ;;
      decline|repair)
        out=$(cd "$wrong" && env -u FM_HOST_ROOT PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
          "$ROOT/bin/fm-decision-hold.sh" "$action" "$action_id" choice \
            --decision-file "$TMP/missing-decision" 2>&1) || status=$?
        ;;
    esac
    expect_code 2 "$status" "first post-teardown $action action trusted a non-host cwd"
    assert_contains "$out" 'requires the recorded host root cwd' \
      "first post-teardown $action action did not enforce durable host ownership"
  done
  pass "post-teardown decision actions require durable recorded host ownership"
}

test_host_teardown_requires_confirmed_stop() {
  local host="$TMP/teardown-host" home="$TMP/teardown-home" project="$TMP/teardown-project" wt="$TMP/teardown-wt" fb log current tree_log out status=0 kill_line verify_line return_line
  make_host "$host"; mkdir -p "$home/data/host-teardown" "$home/state" "$home/config"; make_project_with_origin "$project"
  git -C "$project" worktree add -q --detach "$wt"
printf 'window=test-session:fm-host-teardown\nendpoint_task_id=host-teardown\nworktree=%s\nhost_root=%s\nproject=%s\nkind=ship\nmode=local-only\ntmux_window_marker=teardown-marker\ntmux_socket_path=/tmp/fm-test.sock\n' \
"$wt" "$host" "$project" > "$home/state/host-teardown.meta"
  fb=$(make_fakebin "$TMP/fake-host-teardown")
  log="$TMP/host-teardown.log"; current="$TMP/host-teardown.current"; tree_log="$TMP/host-teardown-treehouse.log"
  printf '%s\n' "$host" > "$current"; : > "$current.endpoint"; printf 'teardown-marker' > "$current.endpoint.marker"; : > "$log"; : > "$tree_log"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_REFUSE_STOP=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-host-teardown FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-teardown.sh" host-teardown --force 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "host-root teardown accepted an unconfirmed endpoint stop"
  assert_no_grep 'return --force' "$tree_log" "host-root teardown recycled work before confirming endpoint absence"
  assert_present "$home/state/host-teardown.meta" "host-root teardown removed recovery metadata after stop refusal"

  : > "$log"; : > "$tree_log"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_KILL_MUTATION="$wt/late-edit.txt" FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-host-teardown FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-teardown.sh" host-teardown 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "host-root tmux teardown discarded an edit written during endpoint stop"
  assert_contains "$out" "uncommitted changes" "post-stop tmux safety refusal did not explain the late edit"
  assert_present "$wt/late-edit.txt" "post-stop tmux safety refusal lost the late worker edit"
  assert_present "$home/state/host-teardown.meta" "post-stop tmux safety refusal removed task metadata"
  assert_no_grep 'return --force' "$tree_log" "post-stop tmux safety refusal returned the worktree"
  rm -f "$wt/late-edit.txt"

  : > "$current.endpoint"; : > "$log"; : > "$tree_log"; status=0
  sed -i.bak 's/^window=.*/window=test-session:1/' "$home/state/host-teardown.meta"
  rm -f "$home/state/host-teardown.meta.bak"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" FM_TMUX_RENUMBER_ON_STOP=1 \
    FM_ENDPOINT_TARGET=test-session:fm-host-teardown FM_ENDPOINT_INDEX_ALIAS=test-session:1 \
    FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-teardown.sh" host-teardown --force 2>&1) || status=$?
  expect_code 0 "$status" "host-root teardown failed after confirmed endpoint stop: $out"
  assert_grep $'kill-window\037-t\037@1' "$log" \
    "host-root teardown did not stop the immutable tmux window id"
  kill_line=$(grep -n 'kill-window' "$log" | tail -1 | cut -d: -f1)
  verify_line=$(awk -v start="$kill_line" 'NR > start && /list-panes/ { print NR; exit }' "$log")
  return_line=$(grep -n 'return --force' "$tree_log" | head -1 | cut -d: -f1)
  [ -n "$kill_line" ] && [ -n "$verify_line" ] && [ -n "$return_line" ] \
    || fail "host-root teardown did not stop, verify, and return its isolated copy"
  pass "host-root teardown confirms endpoint absence before worktree cleanup"
}

test_host_teardown_refuses_recorded_overlap_before_mutation() {
  local host="$TMP/overlap-teardown-host" home="$TMP/overlap-teardown-home" project="$TMP/overlap-teardown-project" fb log current tree_log out status=0 branch
  make_host "$host"
  make_project_with_origin "$project"
  mkdir -p "$home/state" "$home/config"
printf 'window=test-session:fm-overlap-teardown\nendpoint_task_id=overlap-teardown\nworktree=%s\nhost_root=%s\nproject=%s\nkind=ship\nmode=local-only\ntmux_window_marker=overlap-marker\ntmux_socket_path=/tmp/fm-test.sock\n' \
"$host" "$host" "$project" > "$home/state/overlap-teardown.meta"
  cp "$home/state/overlap-teardown.meta" "$TMP/overlap-teardown.meta"
  touch "$home/state/.last-watcher-beat"
  fb=$(make_fakebin "$TMP/fake-overlap-teardown")
  log="$TMP/overlap-teardown.log"
  current="$TMP/overlap-teardown.current"
  tree_log="$TMP/overlap-teardown-treehouse.log"
  printf '%s\n' "$host" > "$current"
  : > "$current.endpoint"
  : > "$log"
  : > "$tree_log"
  branch=$(git -C "$host" symbolic-ref --short HEAD)

  out=$(cd "$host" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH="$host" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-teardown.sh" overlap-teardown --force 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "teardown accepted recorded overlapping host and target roots"
  assert_contains "$out" 'recorded host and target roots overlap' "overlap refusal was not explicit"
  assert_present "$current.endpoint" "overlap refusal stopped the recorded endpoint"
  [ ! -s "$log" ] || fail "overlap refusal touched the recorded endpoint"
  [ ! -s "$tree_log" ] || fail "overlap refusal invoked treehouse"
  [ "$(git -C "$host" symbolic-ref --short HEAD)" = "$branch" ] || fail "overlap refusal changed the host Git branch"
  cmp -s "$TMP/overlap-teardown.meta" "$home/state/overlap-teardown.meta" \
    || fail "overlap refusal changed recovery metadata"
  pass "host-root teardown preserves recorded overlaps before endpoint or Git mutation"
}

test_secondmate_force_teardown_preserves_host_children_during_recursive_cleanup() {
  local backend case_root home subhome childproj childwt host fb log current tree_log target endpoint_named out status
  for backend in tmux herdr; do
    case_root="$TMP/recursive-host-child-$backend"
    home="$case_root/home"
    subhome="$case_root/subhome"
    childproj="$subhome/projects/alpha"
    childwt="$case_root/child-worktree"
    host="$case_root/host"
    mkdir -p "$home/state" "$home/data" "$home/config" "$subhome/state" "$host"
    : > "$host/AGENTS.md"
    fm_git_worktree "$childproj" "$childwt" "recursive-$backend"
    printf 'domain\n' > "$subhome/.fm-secondmate-home"
    fm_write_meta "$home/state/domain.meta" \
      'window=test-session:fm-domain' "worktree=$subhome" "project=$subhome" \
      'harness=echo' 'kind=secondmate' 'mode=secondmate' "home=$subhome" 'projects=alpha'
    target=test-session:1
    endpoint_named=test-session:fm-child
    if [ "$backend" = herdr ]; then
      target=child-session:w1:p2
      endpoint_named=$target
    fi
fm_write_meta "$subhome/state/child.meta" \
"window=$target" 'endpoint_task_id=child' "worktree=$childwt" "project=$childproj" \
"backend=$backend" "host_root=$host" 'harness=echo' 'kind=ship' 'mode=no-mistakes'
    if [ "$backend" = tmux ]; then
      printf 'tmux_window_marker=child-marker\ntmux_socket_path=/tmp/fm-test.sock\n' >> "$subhome/state/child.meta"
    fi
    fb=$(make_fakebin "$case_root/fake")
    if [ "$backend" = herdr ]; then
      printf '%s\n' \
        'herdr_session=child-session' \
        'herdr_workspace_id=w1' \
        'herdr_tab_id=w1:t2' \
        'herdr_pane_id=w1:p2' >> "$subhome/state/child.meta"
      printf '%s\n' \
        'version=1' \
        'task_id=child' \
        'projection_id=AbCdEfGhIjKlMnOpQrStUv' > "$subhome/state/child.herdr-presentation"
      cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane close") exit 0 ;;
  "pane get") printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
  *) exit 0 ;;
esac
SH
      chmod +x "$fb/herdr"
    fi
    log="$case_root/backend.log"
    current="$case_root/current"
    tree_log="$case_root/treehouse.log"
    printf '%s\n' "$host" > "$current"
    : > "$current.endpoint"
    [ "$backend" != tmux ] || printf 'child-marker' > "$current.endpoint.marker"
    : > "$log"
    : > "$tree_log"
    status=0
    out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_REFUSE_STOP=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 \
      FM_TMUX_LOG="$log" FM_FAKE_HERDR_LOG="$log" FM_ENDPOINT_TARGET="$endpoint_named" \
      FM_ENDPOINT_INDEX_ALIAS="$target" FM_LAUNCH_FILE="$case_root/unused.launch" \
      FM_CURRENT_PATH="$current" FM_TARGET_PATH="$childwt" FM_HOST_PATH="$host" \
      FM_TREEHOUSE_LOG="$tree_log" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "forced secondmate teardown accepted unsafe $backend host-child cleanup"
    assert_present "$subhome/state/child.meta" "recursive $backend host-child cleanup removed child metadata"
    assert_present "$childwt" "recursive $backend host-child cleanup removed the child worktree"
    assert_present "$home/state/domain.meta" "recursive $backend host-child cleanup removed parent metadata"
    assert_contains "$out" 'refusing destructive cleanup' \
      "recursive $backend host-child cleanup did not explain the refusal"
    assert_no_grep 'return --force' "$tree_log" \
      "recursive $backend host-child cleanup recycled a worktree"
    if [ "$backend" = herdr ]; then
      assert_present "$subhome/state/child.herdr-presentation" \
        "recursive Herdr cleanup removed the presentation journal"
      assert_no_grep 'pane close' "$log" \
        "recursive Herdr cleanup bypassed direct focus-preserving teardown"
    fi
  done
  pass "forced secondmate teardown preserves tmux aliases and projected Herdr children during recursive cleanup"
}

test_secondmate_force_teardown_closes_host_root_herdr_child() {
  local case_root="$TMP/recursive-host-herdr-child" home subhome childproj childwt host fb log current tree_log closed status=0 out
  home="$case_root/home"
  subhome="$case_root/subhome"
  childproj="$subhome/projects/alpha"
  childwt="$case_root/child-worktree"
  host="$case_root/host"
  mkdir -p "$home/state" "$home/data" "$home/config" "$subhome/state" "$host"
  : > "$host/AGENTS.md"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    'window=test-session:fm-domain' "worktree=$subhome" "project=$subhome" \
    'harness=echo' 'kind=secondmate' 'mode=secondmate' "home=$subhome" 'projects=alpha'
  fm_write_meta "$subhome/state/child.meta" \
    'window=child-session:w1:p2' 'endpoint_task_id=child' "worktree=$childwt" "project=$childproj" \
    "host_root=$host" 'backend=herdr' 'herdr_session=child-session' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2' \
    'harness=echo' 'kind=ship' 'mode=no-mistakes'
  fb=$(make_fakebin "$case_root/fake")
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"child-session","running":true,"socket_path":"$case_root/child.sock"}]}' ;;
  "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1"}]}}' ;;
  "tab get") printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2","workspace_id":"w1","label":"fm-child"}}}' ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
esac
SH
  chmod +x "$fb/herdr"
  log="$case_root/backend.log"
  current="$case_root/current"
  tree_log="$case_root/treehouse.log"
  closed="$case_root/closed"
  printf '%s\n' "$subhome" > "$current"
  : > "$current.endpoint"
  : > "$log"
  : > "$tree_log"
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_ENDPOINT_TARGET=test-session:fm-domain FM_LAUNCH_FILE="$case_root/unused.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$childwt" FM_HOST_PATH="$host" \
    FM_TREEHOUSE_LOG="$tree_log" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1) || status=$?
  expect_code 0 "$status" "forced secondmate teardown failed to close a host-root Herdr child: $out"
  assert_present "$closed" "recursive host-root Herdr cleanup did not close the child pane"
  assert_grep 'pane close w1:p2' "$log" "recursive host-root Herdr cleanup did not use the serialized exact-pane close"
  assert_absent "$subhome" "recursive host-root Herdr cleanup retained the empty secondmate home"
  assert_absent "$home/state/domain.meta" "recursive host-root Herdr cleanup retained parent metadata"
  pass "forced secondmate teardown closes host-root Herdr children under the preflight lock"
}

test_secondmate_force_teardown_refuses_recursive_host_overlap_before_mutation() {
  local case_root="$TMP/recursive-host-overlap" home subhome childproj host fb log current tree_log out status=0
  home="$case_root/home"
  subhome="$case_root/subhome"
  childproj="$subhome/projects/alpha"
  host="$case_root/host"
  mkdir -p "$home/state" "$home/data" "$home/config" "$subhome/state"
  fm_git_worktree "$childproj" "$host" recursive-overlap
  : > "$host/AGENTS.md"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    'window=test-session:fm-domain' "worktree=$subhome" "project=$subhome" \
    'harness=echo' 'kind=secondmate' 'mode=secondmate' "home=$subhome" 'projects=alpha'
fm_write_meta "$subhome/state/child.meta" \
'window=@1' 'endpoint_task_id=child' "worktree=$host" "project=$childproj" \
"host_root=$host" 'tmux_window_marker=child-marker' 'tmux_socket_path=/tmp/fm-test.sock' \
'harness=echo' 'kind=ship' 'mode=no-mistakes'
  fb=$(make_fakebin "$case_root/fake")
  log="$case_root/backend.log"
  current="$case_root/current"
  tree_log="$case_root/treehouse.log"
  printf '%s\n' "$host" > "$current"
  : > "$current.endpoint"
  : > "$log"
  : > "$tree_log"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$case_root/unused.launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH="$host" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" \
    "$ROOT/bin/fm-teardown.sh" domain --force 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "recursive teardown accepted an overlapping child host and target"
  assert_contains "$out" 'child host and target roots overlap' \
    "recursive overlap refusal did not explain the unsafe child roots"
  assert_present "$current.endpoint" "recursive overlap refusal stopped the child endpoint"
  assert_present "$subhome/state/child.meta" "recursive overlap refusal removed child recovery metadata"
  assert_present "$home/state/domain.meta" "recursive overlap refusal removed parent recovery metadata"
  assert_present "$host" "recursive overlap refusal removed the authoritative host"
  [ ! -s "$log" ] || fail "recursive overlap refusal touched the child endpoint"
  [ ! -s "$tree_log" ] || fail "recursive overlap refusal invoked treehouse"
  pass "recursive teardown rejects overlapping child host and target before mutation"
}

test_task_actions_use_recorded_host_root() {
  local host="$TMP/recorded-host" wrong="$TMP/wrong-host" home="$TMP/recorded-home" fb log current out status=0
  make_host "$host"; make_host "$wrong"; mkdir -p "$home/state" "$home/config"
  printf 'window=test-session:fm-lane\nworktree=/tmp/target\nhost_root=%s\nproject=/tmp/project\nkind=ship\n' "$host" > "$home/state/lane.meta"
  fb=$(make_fakebin "$TMP/fake-recorded-host")
  log="$TMP/recorded-host.log"; current="$TMP/recorded-host.current"
  : > "$log"; printf '%s\n' "$host" > "$current"; : > "$current.endpoint"
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-send.sh" lane hello 2>&1) || status=$?
  expect_code 2 "$status" "send must reject an ambient host that differs from task ownership"
  assert_contains "$out" 'does not match task metadata host_root' "send did not identify recorded host ownership"
  assert_no_grep 'send-keys' "$log" "send touched the endpoint before recorded-host validation"

  : > "$log"; status=0
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_ENDPOINT_TARGET=test-session:fm-lane FM_ENDPOINT_ALIAS=test-session:fm-lane.0 \
    FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-peek.sh" test-session:fm-lane.0 2>&1) || status=$?
  expect_code 2 "$status" "peek must bind an equivalent tmux pane alias to recorded task ownership"
  assert_contains "$out" 'does not match task metadata host_root' "peek alias did not identify recorded host ownership"
  assert_no_grep 'capture-pane' "$log" "peek alias captured the endpoint before recorded-host validation"

  : > "$log"; status=0
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_ENDPOINT_TARGET=test-session:fm-lane FM_ENDPOINT_ALIAS=test-session:fm-lane.0 \
    FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-send.sh" test-session:fm-lane.0 hello 2>&1) || status=$?
  expect_code 2 "$status" "send must bind an equivalent tmux pane alias to recorded task ownership"
  assert_contains "$out" 'does not match task metadata host_root' "send alias did not identify recorded host ownership"
  assert_no_grep 'send-keys' "$log" "send alias touched the endpoint before recorded-host validation"

  : > "$log"; status=0
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_TMUX_NUMERIC_NAME_COLLISION=1 \
    FM_ENDPOINT_TARGET=test-session:fm-lane FM_ENDPOINT_INDEX_ALIAS=test-session:1 \
    FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-peek.sh" test-session:1 2>&1) || status=$?
  expect_code 2 "$status" "peek must prefer a tmux window index over a colliding numeric name"
  assert_contains "$out" 'does not match task metadata host_root' "peek numeric collision lost recorded host ownership"
  assert_no_grep 'capture-pane' "$log" "peek numeric collision captured the endpoint before recorded-host validation"

  : > "$log"; status=0
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_TMUX_NUMERIC_NAME_COLLISION=1 \
    FM_ENDPOINT_TARGET=test-session:fm-lane FM_ENDPOINT_INDEX_ALIAS=test-session:1 \
    FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-send.sh" test-session:1 hello 2>&1) || status=$?
  expect_code 2 "$status" "send must prefer a tmux window index over a colliding numeric name"
  assert_contains "$out" 'does not match task metadata host_root' "send numeric collision lost recorded host ownership"
  assert_no_grep 'send-keys' "$log" "send numeric collision touched the endpoint before recorded-host validation"

  status=0
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-teardown.sh" lane --force 2>&1) || status=$?
  expect_code 2 "$status" "teardown must reject an ambient host that differs from task ownership"
  assert_present "$home/state/lane.meta" "teardown changed task data before recorded-host validation"
  pass "task actions bind to recorded physical host ownership before endpoint or task mutation"
}

test_spawn_rejects_old_brief_and_secondmate_clears_roots() {
  local host="$TMP/reject-host" home="$TMP/reject-home" project="$TMP/reject-target" subhome="$TMP/secondmate-home" unsethome="$TMP/secondmate-unset-home" aborthome="$TMP/secondmate-abort-home" fb log current launch meta out status=0
  make_host "$host"; mkdir -p "$home/data/old" "$home/state" "$home/config"; printf 'old brief\n' > "$home/data/old/brief.md"; make_project_with_origin "$project"
  out=$(cd "$host" && FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-spawn.sh" old "$project" codex --mode no-mistakes --yolo off 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "host spawn accepted a cwd-relative old brief"
  assert_contains "$out" 'requires a host-root brief' "old-brief rejection was not explicit"

  mkdir -p "$subhome/bin" "$subhome/data"
  printf '# Secondmate\n' > "$subhome/AGENTS.md"
  printf 'mate\n' > "$subhome/.fm-secondmate-home"
  printf 'charter\n' > "$subhome/data/charter.md"
  mkdir -p "$unsethome/bin" "$unsethome/data" "$aborthome/bin" "$aborthome/data"
  printf '# Secondmate\n' > "$unsethome/AGENTS.md"
  printf 'mate-unset\n' > "$unsethome/.fm-secondmate-home"
  printf 'charter\n' > "$unsethome/data/charter.md"
  printf '# Secondmate\n' > "$aborthome/AGENTS.md"
  printf 'mate-abort\n' > "$aborthome/.fm-secondmate-home"
  printf 'charter\n' > "$aborthome/data/charter.md"
  fb=$(make_fakebin "$TMP/fake-secondmate")
  log="$TMP/secondmate.log"; current="$TMP/secondmate.current"; launch="$TMP/secondmate.launch"
  printf '%s\n' "$subhome" > "$current"
  (cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_HOST_ROOT="$host" FM_TARGET_WORKTREE=/should-not-leak FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$subhome" FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" mate "$subhome" codex --secondmate >/dev/null 2>&1)
  assert_contains "$(cat "$launch")" 'FM_HOST_ROOT= FM_TARGET_WORKTREE=' "secondmate launch did not clear both host variables"
  meta="$home/state/mate.meta"
  assert_no_grep 'host_root=' "$meta" "secondmate metadata inherited host_root"
  assert_grep "worktree=$subhome" "$meta" "secondmate lost its isolated-home worktree"

  current="$TMP/secondmate-unset.current"
  : > "$launch"; printf '%s\n' "$unsethome" > "$current"
  (cd "$host" && env -u FM_HOST_ROOT -u FM_TARGET_WORKTREE PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$unsethome" FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" mate-unset "$unsethome" codex --secondmate >/dev/null 2>&1)
  assert_not_contains "$(cat "$launch")" 'FM_HOST_ROOT=' "unset-mode secondmate launch changed its historical environment prefix"
  assert_not_contains "$(cat "$launch")" 'FM_TARGET_WORKTREE=' "unset-mode secondmate launch set a new empty target variable"

  current="$TMP/secondmate-abort.current"
  : > "$log"; printf '%s\n' "$aborthome" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_HOST_ROOT="$host" FM_FAIL_LAUNCH_SEND=1 FM_REFUSE_STOP=1 \
    FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_ENDPOINT_TARGET=test-session:fm-mate-abort FM_LAUNCH_FILE="$TMP/mate-abort.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$aborthome" FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" mate-abort "$aborthome" codex --secondmate 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected secondmate stop failure unexpectedly succeeded"
  meta="$home/state/mate-abort.meta"
  assert_grep 'mode=secondmate' "$meta" "failed secondmate rollback lost its fixed delivery mode"
  assert_grep 'yolo=off' "$meta" "failed secondmate rollback lost its fixed approval posture"
  rm -rf "/tmp/fm-mate-abort"
  rm -f "$meta" "$current.endpoint"
  pass "host spawn rejects old briefs, clears inherited secondmate roots, and preserves unset launches"
}

test_resolution_and_validation
test_ambiguous_host_owner_is_rejected
test_host_owner_publication_is_atomic
test_session_cwd_mismatch_precedes_mutation
test_unset_session_cannot_take_over_host_owned_home
test_host_command_rendering
test_brief_variants
test_host_local_only_rejected_before_mutation
test_spawn_separates_roots
test_duplicate_spawn_preserves_existing_task
test_unset_herdr_retry_reaches_existing_identity_checks
test_spawn_rejects_host_as_target
test_orca_active_cwd_probe
test_all_harnesses_add_one_task_safeguard
test_mutators_require_host_cwd
test_secondmate_actions_keep_supervisor_host_authority
test_spawn_rollback_is_transactional
test_decision_actions_use_durable_host_owner
test_host_teardown_requires_confirmed_stop
test_host_teardown_refuses_recorded_overlap_before_mutation
test_secondmate_force_teardown_preserves_host_children_during_recursive_cleanup
test_secondmate_force_teardown_closes_host_root_herdr_child
test_secondmate_force_teardown_refuses_recursive_host_overlap_before_mutation
test_task_actions_use_recorded_host_root
test_spawn_rejects_old_brief_and_secondmate_clears_roots
