#!/usr/bin/env bash
# Regression test for bin/fm-spawn.sh's Herdr `treehouse get` send path
# (header "Treehouse get on Herdr") and the pre-launch endpoint close in
# spawn_abort_cleanup, driven through the executable against a scripted fake
# `herdr` and a fake `ps`, modelled on tests/fm-spawn-worktree-settle.test.sh.
#
# The live incident: three launches typed `treehouse get` into a fresh Herdr
# pane whose shell was still initializing, treehouse answered "all 16
# worktrees are in use or dirty" within a second, and spawn polled the pane's
# cwd for 60 seconds without reading that output, then left the tab behind.
# The fake scripts a pane whose process-info reports a busy foreground for the
# first N samples and then a lone idle shell, whose `pane wait-output` answers
# are env-controlled, and whose `pane get` walks a cwd sequence.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-readiness)

# A pane shell pid no real process on this host can hold: macOS caps pids at
# 99998 and Linux at 4194304, so nothing is ever signalled by mistake.
FAKE_SHELL_PID=4194305
FAKE_SHELL_PID_REPLACED=4194306

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

# make_herdr_fakebin <dir> builds the stateful fake `herdr` plus the fake `ps`
# its idle-shell proof reads. State lives under FM_FAKE_HERDR_DIR:
#   log           one line per invocation: args joined by '|'
#   tabs          "<tab>|<label>" per created tab (w1:t1 "1" is the seed)
#   closed        "<pane>" per closed pane
#   pid           the pane shell pid process-info reports
#   proc-calls    process-info sample counter
#   cwd-calls     `pane get` counter, walking FM_FAKE_HERDR_CWD_FILE line by
#                 line (the last line is sticky)
# Knobs: FM_FAKE_HERDR_READY_AFTER (busy process-info samples before the lone
# idle shell), FM_FAKE_HERDR_ECHO (1: `wait-output --match 'treehouse get'`
# matches, 0: it times out), FM_FAKE_HERDR_ERROR_TEXT (a non-empty value makes
# the --regex fail-fast read match that line), FM_FAKE_HERDR_PID_AFTER_RUN (the
# shell pid reported after the first `pane run`), FM_FAKE_HERDR_WAIT_UNSUPPORTED
# (1: wait-output is an unknown verb), FM_FAKE_HERDR_FOREGROUND_REASON and
# FM_FAKE_HERDR_ACTIVE_TAB (the viewer and its active tab; "task" names the
# task tab once created).
make_herdr_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D="${FM_FAKE_HERDR_DIR:?FM_FAKE_HERDR_DIR unset}"
mkdir -p "$D"
[ -e "$D/tabs" ] || printf 'w1:t1|1\n' > "$D/tabs"
[ -e "$D/pid" ] || printf '%s\n' "${FM_FAKE_HERDR_PID:-4194305}" > "$D/pid"
args="$*"
printf '%s\n' "${args// /|}" >> "$D/log"
bump() { local n; n=$(cat "$D/$1" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "$D/$1"; printf '%s' "$n"; }
pane_of_tab() { printf '%s' "${1/:t/:p}"; }
tab_of_pane() { printf '%s' "${1/:p/:t}"; }
is_closed() { grep -qx -- "$1" "$D/closed" 2>/dev/null; }
active_tab() {
  local want=${FM_FAKE_HERDR_ACTIVE_TAB:-w1:t1}
  if [ "$want" = task ]; then
    want=$(awk -F'|' '$2 != "1" { t=$1 } END { print (t == "" ? "w1:t1" : t) }' "$D/tabs")
  fi
  printf '%s' "$want"
}
current_cwd() {
  local n lines
  if [ -n "${FM_FAKE_HERDR_CWD_FILE:-}" ] && [ -s "$FM_FAKE_HERDR_CWD_FILE" ]; then
    n=$(bump cwd-calls)
    lines=$(wc -l < "$FM_FAKE_HERDR_CWD_FILE" | tr -d ' ')
    [ "$n" -le "$lines" ] || n=$lines
    sed -n "${n}p" "$FM_FAKE_HERDR_CWD_FILE"
  else
    printf '%s\n' "${FM_FAKE_HERDR_PROJECT:-/tmp}"
  fi
}
tab_json() { # <tab> <label>
  local focused=false
  [ "$1" != "$(active_tab)" ] || focused=true
  printf '{"tab_id":"%s","workspace_id":"w1","label":"%s","focused":%s,"pane_count":1}' "$1" "$2" "$focused"
}
pane_json() { # <pane> <cwd>
  printf '{"pane_id":"%s","tab_id":"%s","workspace_id":"w1","cwd":"%s","foreground_cwd":"%s","agent_status":"unknown"}' "$1" "$(tab_of_pane "$1")" "$2" "$2"
}
list_tabs() {
  local first=1 tab label
  printf '['
  while IFS='|' read -r tab label; do
    [ -n "$tab" ] || continue
    is_closed "$(pane_of_tab "$tab")" && continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    tab_json "$tab" "$label"
  done < "$D/tabs"
  printf ']'
}
list_panes() {
  local first=1 tab label cwd
  cwd=$(sed -n '$p' "$D/last-cwd" 2>/dev/null || true)
  [ -n "$cwd" ] || cwd=${FM_FAKE_HERDR_PROJECT:-/tmp}
  printf '['
  while IFS='|' read -r tab label; do
    [ -n "$tab" ] || continue
    is_closed "$(pane_of_tab "$tab")" && continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    pane_json "$(pane_of_tab "$tab")" "$cwd"
  done < "$D/tabs"
  printf ']'
}
tab_count() { list_tabs | tr -cd '{' | wc -c | tr -d ' '; }
case "${1:-} ${2:-} ${3:-}" in
  "status --json "*)
    printf '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true,"protocol":17,"compatible":true,"socket":"%s/herdr.sock"}}\n' "$D"
    ;;
  "session list --json")
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s/herdr.sock"}]}\n' "${HERDR_SESSION:-default}" "$D"
    ;;
  "terminal title clear")
    printf '{"result":{"reason":"%s"}}\n' "${FM_FAKE_HERDR_FOREGROUND_REASON:-no_foreground_client}"
    ;;
  "workspace list "*)
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}]}}\n' "$(active_tab)" "$(tab_count)" "$(tab_count)"
    ;;
  "workspace get "*)
    printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}}}\n' "$(active_tab)" "$(tab_count)" "$(tab_count)"
    ;;
  "tab list "*)
    printf '{"result":{"tabs":'; list_tabs; printf '}}\n'
    ;;
  "tab get "*)
    label=$(awk -F'|' -v t="$3" '$1 == t { print $2 }' "$D/tabs")
    printf '{"result":{"tab":'; tab_json "$3" "$label"; printf '}}\n'
    ;;
  "tab create "*)
    label=; cwd=; prev=
    for a in "$@"; do
      [ "$prev" = --label ] && label=$a
      [ "$prev" = --cwd ] && cwd=$a
      prev=$a
    done
    n=$(bump tab-count); n=$((n + 1))
    printf 'w1:t%s|%s\n' "$n" "$label" >> "$D/tabs"
    printf '{"result":{"tab":{"tab_id":"w1:t%s","label":"%s","workspace_id":"w1"},"root_pane":{"pane_id":"w1:p%s","tab_id":"w1:t%s","workspace_id":"w1","cwd":"%s","foreground_cwd":"%s"}}}\n' "$n" "$label" "$n" "$n" "$cwd" "$cwd"
    ;;
  "tab focus "*)
    : ;;
  "tab close "*)
    printf '%s\n' "$(pane_of_tab "$3")" >> "$D/closed"
    printf '{"result":{"type":"ok"}}\n'
    ;;
  "pane list "*)
    printf '{"result":{"panes":'; list_panes; printf '}}\n'
    ;;
  "pane get "*)
    if is_closed "$3"; then
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3"
      exit 1
    fi
    cwd=$(current_cwd)
    printf '%s\n' "$cwd" > "$D/last-cwd"
    printf '{"result":{"pane":'; pane_json "$3" "$cwd"; printf '}}\n'
    ;;
  "pane process-info "*)
    pane=$4
    pid=$(cat "$D/pid")
    n=$(bump proc-calls)
    if [ "$n" -le "${FM_FAKE_HERDR_READY_AFTER:-0}" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]},{"pid":%s,"name":"starship","argv0":"starship","argv":["starship","prompt"]}]}}}\n' "$pane" "$pid" "$pid" "$pid" "$((pid + 50))"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}\n' "$pane" "$pid" "$pid" "$pid"
    fi
    ;;
  "pane run "*)
    if [ "${4:-}" = "treehouse get" ]; then
      bump get-runs >/dev/null
      [ -z "${FM_FAKE_HERDR_PID_AFTER_RUN:-}" ] || printf '%s\n' "$FM_FAKE_HERDR_PID_AFTER_RUN" > "$D/pid"
    fi
    printf '{"result":{"type":"ok"}}\n'
    ;;
  "pane wait-output "*)
    if [ "${FM_FAKE_HERDR_WAIT_UNSUPPORTED:-0}" = 1 ]; then
      printf 'unknown option: --match\n' >&2
      exit 2
    fi
    mode=$4; pattern=$5
    hit=
    if [ "$mode" = --match ] && [ "$pattern" = "treehouse get" ] && [ "${FM_FAKE_HERDR_ECHO:-1}" = 1 ]; then
      hit="treehouse get"
    elif [ "$mode" = --regex ] && [ -n "${FM_FAKE_HERDR_ERROR_TEXT:-}" ]; then
      hit=$FM_FAKE_HERDR_ERROR_TEXT
    fi
    if [ -n "$hit" ]; then
      printf '{"result":{"type":"output_matched","pane_id":"%s","matched_line":"%s"}}\n' "$3" "$hit"
    else
      printf '{"error":{"code":"timeout","message":"timed out waiting for output match"}}\n'
      exit 1
    fi
    ;;
  "pane close "*)
    printf '%s\n' "$3" >> "$D/closed"
    printf '{"result":{"type":"ok"}}\n'
    ;;
  "pane send-text "*|"pane send-keys "*)
    printf '{"result":{"type":"ok"}}\n'
    ;;
  "pane read "*)
    printf '\n'
    ;;
  "agent get "*)
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$3"
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/fm-fake-ps" <<'SH'
#!/usr/bin/env bash
D="${FM_FAKE_HERDR_DIR:?}"
pid=$(cat "$D/pid" 2>/dev/null || echo 4194305)
case "$*" in
  "-axo pid=,ppid=") printf '1 0\n%s 1\n' "$pid" ;;
  "-p $pid -o stat=") printf 'S\n' ;;
  "-p $pid -o comm=") printf 'zsh\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/fm-fake-ps"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home on backend=herdr with projection off, a
# project with a real linked worktree (the settled path), and the fake state.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_herdr_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  printf 'herdr\n' > "$home/config/backend"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise the Herdr treehouse-get send path for $id."
  mkdir -p "$case_dir/fake-state"
  CASE_DIR=$case_dir
  HOME_DIR=$home
  PROJ_DIR=$proj
  WT_DIR=$wt
  FAKEBIN_DIR=$fakebin
  FAKE_STATE="$case_dir/fake-state"
  CWD_FILE="$case_dir/cwd-sequence"
  : > "$CWD_FILE"
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_DIR="$FAKE_STATE" FM_FAKE_HERDR_PROJECT="$PROJ_DIR" \
    FM_FAKE_HERDR_CWD_FILE="$CWD_FILE" FM_HERDR_PS_BIN="$FAKEBIN_DIR/fm-fake-ps" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

get_runs() { cat "$FAKE_STATE/get-runs" 2>/dev/null || echo 0; }
task_pane() { awk -F'|' '$2 != "1" { t=$1 } END { sub(":t", ":p", t); print t }' "$FAKE_STATE/tabs"; }

# (1) `pane run` is logged only after the readiness gate saw a lone idle shell.
test_run_waits_for_readiness() {
  local id out status first_run busy_samples
  id=herdr-ready-z1
  make_case ready "$id"
  printf '%s\n%s\n' "$PROJ_DIR" "$WT_DIR" > "$CWD_FILE"
  out=$(FM_FAKE_HERDR_READY_AFTER=3 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles and enters the worktree"$'\n'"$out"
  first_run=$(grep -n '^pane|run|' "$FAKE_STATE/log" | head -1 | cut -d: -f1)
  [ -n "$first_run" ] || fail "no pane run was logged"$'\n'"$out"
  busy_samples=$(head -n "$first_run" "$FAKE_STATE/log" | grep -c '^pane|process-info|')
  [ "$busy_samples" -ge 4 ] || fail "treehouse get was typed after only $busy_samples process-info samples; the gate must outwait the 3 busy samples"
  [ "$(get_runs)" -eq 1 ] || fail "expected exactly one treehouse get, got $(get_runs)"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "meta did not record the settled worktree"
  pass "treehouse get is typed only after the pane proves a lone idle shell"
}

# (2) treehouse's own pool-full text fails the spawn at once with that text.
test_exhausted_pool_fails_fast() {
  local id out status started elapsed
  id=herdr-pool-full-z2
  make_case pool-full "$id"
  started=$SECONDS
  out=$(FM_FAKE_HERDR_ERROR_TEXT='all 16 worktrees are in use or dirty (max_trees = 16)' run_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  [ "$status" -ne 0 ] || fail "spawn accepted an exhausted pool"$'\n'"$out"
  assert_contains "$out" "all 16 worktrees are in use or dirty" "the refusal did not carry treehouse's own message"
  assert_not_contains "$out" "did not enter an isolated worktree within 60s" "the refusal waited for the deadline instead of failing fast"
  [ "$elapsed" -lt 5 ] || fail "refusal took ${elapsed}s instead of failing within seconds"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an exhausted pool fails in seconds with treehouse's message"
  # (6) The pre-launch abort closed the fresh pane, and nothing else.
  local pane
  pane=$(task_pane)
  grep -qx -- "$pane" "$FAKE_STATE/closed" || fail "the fresh pane $pane was not closed after the refusal"
  [ "$(wc -l < "$FAKE_STATE/closed" | tr -d ' ')" -eq 1 ] || fail "more than the fresh pane was closed: $(cat "$FAKE_STATE/closed")"
  grep -q '^pane|close|' "$FAKE_STATE/log" || fail "no pane close was logged"
  ! grep -q '^tab|close|' "$FAKE_STATE/log" || fail "a tab close was issued instead of the exact pane close"
  ! grep -q '^workspace|close' "$FAKE_STATE/log" || fail "a workspace close was issued"
  pass "a pre-launch abort closes exactly the fresh pane through the exact pane close"
}

# (3) No echo while the same shell is still idle triggers exactly one resend.
test_no_echo_same_shell_resends_once() {
  local id out status
  id=herdr-resend-z3
  make_case resend "$id"
  printf '%s\n%s\n%s\n' "$PROJ_DIR" "$PROJ_DIR" "$WT_DIR" > "$CWD_FILE"
  out=$(FM_FAKE_HERDR_ECHO=0 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should still succeed once the resent command moves the pane"$'\n'"$out"
  [ "$(get_runs)" -eq 2 ] || fail "expected exactly one resend (2 runs), got $(get_runs)"
  assert_contains "$out" "resending once" "the resend was not reported"
  pass "no echo plus the same idle shell resends treehouse get exactly once"
}

# (4) An echo means no resend even when the cwd never moves.
test_echo_present_never_resends() {
  local id out status
  id=herdr-echo-z4
  make_case echo "$id"
  out=$(FM_FAKE_HERDR_ECHO=1 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although the pane never left the project"$'\n'"$out"
  [ "$(get_runs)" -eq 1 ] || fail "treehouse get was sent $(get_runs) times despite an echo"
  assert_contains "$out" "did not enter an isolated worktree within 60s" "the deadline refusal was not reported"
  assert_contains "$out" "the pane echoed the command" "the refusal did not note the receipt"
  pass "an echoed treehouse get is never resent"
}

# (5) A changed shell pid means no resend.
test_shell_pid_changed_never_resends() {
  local id out status
  id=herdr-newshell-z5
  make_case newshell "$id"
  out=$(FM_FAKE_HERDR_ECHO=0 FM_FAKE_HERDR_PID_AFTER_RUN="$FAKE_SHELL_PID_REPLACED" run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although the pane never left the project"$'\n'"$out"
  [ "$(get_runs)" -eq 1 ] || fail "treehouse get was sent $(get_runs) times although the shell changed"
  assert_contains "$out" "shell changed from pid $FAKE_SHELL_PID to pid $FAKE_SHELL_PID_REPLACED" "the refusal to resend did not name the pid change"
  pass "a replaced shell is never resent treehouse get"
}

# (7) A close refused for the captain's active tab leaves the pane and
# prints the inspect hint.
test_active_tab_refusal_keeps_pane() {
  local id out status pane
  id=herdr-active-z7
  make_case active "$id"
  out=$(FM_FAKE_HERDR_ERROR_TEXT='all 16 worktrees are in use or dirty (max_trees = 16)' \
    FM_FAKE_HERDR_FOREGROUND_REASON=cleared FM_FAKE_HERDR_ACTIVE_TAB=task run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an exhausted pool"$'\n'"$out"
  pane=$(task_pane)
  [ ! -s "$FAKE_STATE/closed" ] || fail "the captain's active tab pane was closed: $(cat "$FAKE_STATE/closed")"
  ! grep -q '^pane|close|' "$FAKE_STATE/log" || fail "a pane close was issued for the active tab"
  assert_contains "$out" "inspect window default:$pane" "the refusal did not print the inspect hint"
  pass "an active-tab refusal leaves the pane and prints the inspect hint"
}

# A readiness gate that never passes refuses before typing anything.
test_never_ready_refuses_without_typing() {
  local id out status
  id=herdr-stuck-z8
  make_case stuck "$id"
  out=$(FM_FAKE_HERDR_READY_AFTER=100000 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn proceeded although the pane never settled"$'\n'"$out"
  [ "$(get_runs)" -eq 0 ] || fail "treehouse get was typed into a pane that never settled"
  assert_contains "$out" "did not settle into an idle shell within 10s" "the refusal did not name the readiness gate"
  assert_contains "$out" "default:$(task_pane)" "the refusal did not name the pane"
  pass "a pane that never settles is refused before anything is typed"
}

# An unusable wait-output verb keeps the gate and the plain poll, never resends.
test_unsupported_wait_output_never_resends() {
  local id out status
  id=herdr-nowait-z9
  make_case nowait "$id"
  printf '%s\n%s\n' "$PROJ_DIR" "$WT_DIR" > "$CWD_FILE"
  out=$(FM_FAKE_HERDR_WAIT_UNSUPPORTED=1 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed on the plain poll without wait-output"$'\n'"$out"
  [ "$(get_runs)" -eq 1 ] || fail "treehouse get was sent $(get_runs) times without a readable receipt"
  assert_contains "$out" "no usable 'pane wait-output' receipt" "the fallback was not reported"
  pass "a client without wait-output keeps the plain poll and never resends"
}

test_run_waits_for_readiness
test_exhausted_pool_fails_fast
test_no_echo_same_shell_resends_once
test_echo_present_never_resends
test_shell_pid_changed_never_resends
test_active_tab_refusal_keeps_pane
test_never_ready_refuses_without_typing
test_unsupported_wait_output_never_resends

echo "# all fm-spawn-herdr-readiness tests passed"
