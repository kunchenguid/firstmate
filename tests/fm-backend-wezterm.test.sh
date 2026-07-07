#!/usr/bin/env bash
# fake-WezTerm CLI unit tests for bin/backends/wezterm.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the wezterm adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-wezterm-tests)

make_wezterm_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1
  local fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/wezterm" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'wezterm'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_WEZTERM_LOG:?}"
[ "${1:-}" = cli ] || exit 2
shift
if [ "${2:-}" = --help ] && [ "${FM_WEZTERM_FEATURES:-}" = 1 ]; then
  case "${1:-}" in
    list) printf '%s\n' '--format' ;;
    get-text) printf '%s\n' '--start-line' ;;
    send-text) printf '%s\n' '--no-paste' ;;
    split-pane) printf '%s\n' '--percent' ;;
    kill-pane) printf '%s\n' '--pane-id' ;;
  esac
  exit 0
fi
case "${1:-}" in
  list)
    if [ -n "${FM_WEZTERM_LIST_AFTER:-}" ] && [ -f "${FM_WEZTERM_LIST_SWITCH:-}" ]; then
      cat "$FM_WEZTERM_LIST_AFTER"
    else
      cat "${FM_WEZTERM_LIST:?}"
    fi
    ;;
  spawn)
    printf '%s\n' "${FM_WEZTERM_SPAWN_PANE:-10}"
    [ -z "${FM_WEZTERM_LIST_SWITCH:-}" ] || : > "$FM_WEZTERM_LIST_SWITCH"
    ;;
  split-pane)
    printf '%s\n' "${FM_WEZTERM_SPLIT_PANE:-12}"
    [ -z "${FM_WEZTERM_LIST_SWITCH:-}" ] || : > "$FM_WEZTERM_LIST_SWITCH"
    ;;
  get-text) printf '%s\n' "${FM_WEZTERM_TEXT:-Type a message...}" ;;
  send-text) cat >> "${FM_WEZTERM_LOG:?}" ;;
  set-tab-title|kill-pane) : ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fb/wezterm"
  printf '%s\n' "$fb"
}

write_list() {  # <file> <pane1> <tab1> <win1> <cwd1> [<pane2> <tab2> <win2> <cwd2>]
  local file=$1
  shift
  jq -n '$ARGS.positional
    | [range(0; length; 4) as $i
      | {pane_id: (.[ $i ] | tonumber),
         tab_id: (.[ $i + 1 ] | tonumber),
         window_id: (.[ $i + 2 ] | tonumber),
         title: "old",
         cwd: ("file://" + .[ $i + 3 ]),
         size: {cols: 80, rows: 24}}]' --args "$@" > "$file"
}

write_list_sized() {  # <file> <pane> <tab> <win> <cwd> <cols> <rows> ...
  local file=$1
  shift
  jq -n '$ARGS.positional
    | [range(0; length; 6) as $i
      | {pane_id: (.[ $i ] | tonumber),
         tab_id: (.[ $i + 1 ] | tonumber),
         window_id: (.[ $i + 2 ] | tonumber),
         title: "old",
         cwd: ("file://" + .[ $i + 3 ]),
         size: {cols: (.[ $i + 4 ] | tonumber), rows: (.[ $i + 5 ] | tonumber)}}]' --args "$@" > "$file"
}

test_create_task_spawns_new_tab_and_records_registry() {
  local dir fb out reg
  dir="$TMP_ROOT/create"; mkdir -p "$dir/state" "$dir/project"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 10 2 1 "$dir/project"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-one "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 10" ] \
    || fail "create_task returned unexpected ids/title: $out"
  case "$out" in
    *" FM - firstmate-"*" - project") ;;
    *) fail "create_task returned unexpected tab title: $out" ;;
  esac
  assert_contains "$(cat "$dir/log")" $'wezterm\x1fcli\x1fspawn\x1f--new-window\x1f--cwd\x1f'"$dir/project" \
    "create_task did not spawn the first wezterm task in an explicit new window"
  assert_contains "$(cat "$dir/log")" $'wezterm\x1fcli\x1fset-tab-title\x1f--tab-id\x1f2' \
    "create_task did not set the tab title"
  reg="$dir/state/wezterm-tabs.tsv"
  [ -f "$reg" ] || fail "create_task did not write wezterm tab registry"
  pass "wezterm create_task: first project task spawns a tab, titles it, and records registry"
}

test_create_task_uses_current_pane_context_when_available() {
  local dir fb out
  dir="$TMP_ROOT/create-current"; mkdir -p "$dir/state" "$dir/project"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 9 1 1 "$dir" 10 2 1 "$dir/project"
  out=$( PATH="$fb:$PATH" WEZTERM_PANE=9 FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-one "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 10" ] \
    || fail "create_task returned unexpected ids/title with current pane context: $out"
  assert_contains "$(cat "$dir/log")" $'wezterm\x1fcli\x1fspawn\x1f--pane-id\x1f9\x1f--cwd\x1f'"$dir/project" \
    "create_task did not pass the explicit current pane context"
  assert_not_contains "$(cat "$dir/log")" $'spawn\x1f--new-window' \
    "create_task should not force a new window when WEZTERM_PANE is usable"
  pass "wezterm create_task: first task uses explicit current pane context when available"
}

test_create_task_reuses_project_tab_and_splits_pane() {
  local dir fb out key title
  dir="$TMP_ROOT/reuse"; mkdir -p "$dir/state" "$dir/project" "$dir/worktree"
  fb=$(make_wezterm_fakebin "$dir")
  key=$(cd "$dir/project" && pwd -P)
  title="FM - test-home - project"
  printf '%s\t%s\t2\t10\n' "$key" "$title" > "$dir/state/wezterm-tabs.tsv"
  {
    printf 'backend=wezterm\n'
    printf 'project=%s\n' "$dir/project"
    printf 'worktree=%s\n' "$dir/worktree"
    printf 'window=wezterm:10\n'
    printf 'wezterm_window_id=1\n'
    printf 'wezterm_tab_id=2\n'
    printf 'wezterm_pane_id=10\n'
  } > "$dir/state/one.meta"
  write_list "$dir/list.json" 10 2 1 "$dir/worktree" 12 2 1 "$dir/project"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-two "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 12" ] \
    || fail "reused create_task returned wrong ids: $out"
  assert_contains "$(cat "$dir/log")" $'wezterm\x1fcli\x1fsplit-pane\x1f--pane-id\x1f' \
    "create_task did not split an existing pane"
  ! grep -q $'wezterm\x1fcli\x1fspawn' "$dir/log" \
    || fail "create_task spawned a new tab instead of reusing the registry tab"
  pass "wezterm create_task: same project reuses the tab and splits a pane"
}

test_create_task_layout_grows_to_balanced_grid() {
  local dir fb out key title log switch
  dir="$TMP_ROOT/layout-grid"; mkdir -p "$dir/state" "$dir/project" "$dir/worktree"
  fb=$(make_wezterm_fakebin "$dir")
  log="$dir/log"
  switch="$dir/list.switch"
  key=$(cd "$dir/project" && pwd -P)
  title="FM - test-home - project"
  printf '%s\t%s\t2\t10\n' "$key" "$title" > "$dir/state/wezterm-tabs.tsv"
  {
    printf 'backend=wezterm\n'
    printf 'project=%s\n' "$dir/project"
    printf 'worktree=%s\n' "$dir/worktree"
    printf 'window=wezterm:10\n'
    printf 'wezterm_window_id=1\n'
    printf 'wezterm_tab_id=2\n'
    printf 'wezterm_pane_id=10\n'
  } > "$dir/state/one.meta"

  rm -f "$switch"
  write_list_sized "$dir/list.json" 10 2 1 "$dir/worktree" 80 24
  write_list_sized "$dir/list-after.json" 10 2 1 "$dir/worktree" 80 12 12 2 1 "$dir/worktree" 80 12
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_LIST_AFTER="$dir/list-after.json" FM_WEZTERM_LIST_SWITCH="$switch" FM_WEZTERM_SPLIT_PANE=12 \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-two "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 12" ] \
    || fail "layout second task returned wrong ids: $out"
  assert_contains "$(cat "$log")" $'split-pane\x1f--pane-id\x1f10\x1f--bottom\x1f--percent\x1f50' \
    "second pane should split the only pane downward"

  : > "$log"
  rm -f "$switch"
  write_list_sized "$dir/list.json" 10 2 1 "$dir/worktree" 80 12 12 2 1 "$dir/worktree" 80 12
  write_list_sized "$dir/list-after.json" 10 2 1 "$dir/worktree" 80 12 12 2 1 "$dir/worktree" 40 12 14 2 1 "$dir/worktree" 40 12
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_LIST_AFTER="$dir/list-after.json" FM_WEZTERM_LIST_SWITCH="$switch" FM_WEZTERM_SPLIT_PANE=14 \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-three "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 14" ] \
    || fail "layout third task returned wrong ids: $out"
  assert_contains "$(cat "$log")" $'split-pane\x1f--pane-id\x1f12\x1f--right\x1f--percent\x1f50' \
    "third pane should split a largest half rightward toward a grid"

  : > "$log"
  rm -f "$switch"
  write_list_sized "$dir/list.json" 10 2 1 "$dir/worktree" 80 12 12 2 1 "$dir/worktree" 40 12 14 2 1 "$dir/worktree" 40 12
  write_list_sized "$dir/list-after.json" 10 2 1 "$dir/worktree" 40 12 12 2 1 "$dir/worktree" 40 12 14 2 1 "$dir/worktree" 40 12 16 2 1 "$dir/worktree" 40 12
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_LIST_AFTER="$dir/list-after.json" FM_WEZTERM_LIST_SWITCH="$switch" FM_WEZTERM_SPLIT_PANE=16 \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-four "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 16" ] \
    || fail "layout fourth task returned wrong ids: $out"
  assert_contains "$(cat "$log")" $'split-pane\x1f--pane-id\x1f10\x1f--right\x1f--percent\x1f50' \
    "fourth pane should split the remaining largest half rightward to complete a 2x2 grid"
  pass "wezterm create_task: repeated project tasks grow bottom split into a 2x2 grid"
}

test_create_task_after_grid_splits_largest_pane() {
  local dir fb out key title log switch
  dir="$TMP_ROOT/layout-largest"; mkdir -p "$dir/state" "$dir/project" "$dir/worktree"
  fb=$(make_wezterm_fakebin "$dir")
  log="$dir/log"
  switch="$dir/list.switch"
  key=$(cd "$dir/project" && pwd -P)
  title="FM - test-home - project"
  printf '%s\t%s\t2\t10\n' "$key" "$title" > "$dir/state/wezterm-tabs.tsv"
  {
    printf 'backend=wezterm\n'
    printf 'project=%s\n' "$dir/project"
    printf 'worktree=%s\n' "$dir/worktree"
    printf 'window=wezterm:10\n'
    printf 'wezterm_window_id=1\n'
    printf 'wezterm_tab_id=2\n'
    printf 'wezterm_pane_id=10\n'
  } > "$dir/state/one.meta"
  write_list_sized "$dir/list.json" \
    10 2 1 "$dir/worktree" 40 12 \
    12 2 1 "$dir/worktree" 40 12 \
    14 2 1 "$dir/worktree" 40 12 \
    18 2 1 "$dir/worktree" 120 30
  write_list_sized "$dir/list-after.json" \
    10 2 1 "$dir/worktree" 40 12 \
    12 2 1 "$dir/worktree" 40 12 \
    14 2 1 "$dir/worktree" 40 12 \
    18 2 1 "$dir/worktree" 120 15 \
    20 2 1 "$dir/worktree" 120 15
  rm -f "$switch"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_LIST_AFTER="$dir/list-after.json" FM_WEZTERM_LIST_SWITCH="$switch" FM_WEZTERM_SPLIT_PANE=20 \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-five "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 20" ] \
    || fail "layout fifth task returned wrong ids: $out"
  assert_contains "$(cat "$log")" $'split-pane\x1f--pane-id\x1f18' \
    "post-grid pane growth should target the largest known pane"
  pass "wezterm create_task: post-grid growth splits the largest pane"
}

test_create_task_reuses_project_tab_after_seed_pane_exits() {
  local dir fb out key title
  dir="$TMP_ROOT/reuse-after-seed-exit"; mkdir -p "$dir/state" "$dir/project" "$dir/worktree"
  fb=$(make_wezterm_fakebin "$dir")
  key=$(cd "$dir/project" && pwd -P)
  title="FM - test-home - project"
  printf '%s\t%s\t2\t10\n' "$key" "$title" > "$dir/state/wezterm-tabs.tsv"
  {
    printf 'backend=wezterm\n'
    printf 'project=%s\n' "$dir/project"
    printf 'worktree=%s\n' "$dir/worktree"
    printf 'window=wezterm:12\n'
    printf 'wezterm_window_id=1\n'
    printf 'wezterm_tab_id=2\n'
    printf 'wezterm_pane_id=12\n'
  } > "$dir/state/one.meta"
  write_list "$dir/list.json" 12 2 1 "$dir/worktree"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-two "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "1 2 12" ] \
    || fail "seed-exit create_task returned wrong ids: $out"
  assert_contains "$(cat "$dir/log")" $'wezterm\x1fcli\x1fsplit-pane\x1f--pane-id\x1f12' \
    "create_task did not reuse the tab proven by a non-seed live task"
  ! grep -q $'wezterm\x1fcli\x1fspawn' "$dir/log" \
    || fail "create_task spawned a new tab when a non-seed task proved the registry tab"
  pass "wezterm create_task: live task panes keep a registry tab reusable after seed pane exit"
}

test_create_task_ignores_unproven_stale_registry_tab() {
  local dir fb out key title reg
  dir="$TMP_ROOT/stale-registry"; mkdir -p "$dir/state" "$dir/project" "$dir/other"
  fb=$(make_wezterm_fakebin "$dir")
  key=$(cd "$dir/project" && pwd -P)
  title="FM - test-home - project"
  reg="$dir/state/wezterm-tabs.tsv"
  printf '%s\t%s\t2\t10\n' "$key" "$title" > "$reg"
  write_list "$dir/list.json" 10 2 1 "$dir/other" 14 4 3 "$dir/project"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_SPAWN_PANE=14 \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_create_task fm-two "$1"' "$ROOT" "$dir/project" )
  [ "$(printf '%s\n' "$out" | awk '{print $1, $2, $3}')" = "3 4 14" ] \
    || fail "stale-registry create_task returned wrong ids: $out"
  assert_contains "$(cat "$dir/log")" $'wezterm\x1fcli\x1fspawn\x1f--new-window\x1f--cwd\x1f'"$dir/project" \
    "create_task should spawn a new tab when the registry tab has no live task proof"
  assert_not_contains "$(cat "$dir/log")" $'wezterm\x1fcli\x1fsplit-pane' \
    "create_task should not split an unproven stale registry tab"
  grep -F "$key" "$reg" | grep -F $'\t''4'$'\t''14' >/dev/null \
    || fail "create_task did not replace stale registry entry with the new tab"
  pass "wezterm create_task: stale registry entries without live task proof are ignored"
}

test_cwd_path_decodes_file_uris() {
  local out
  out=$(bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_cwd_path "$1"' "$ROOT" "file:///tmp/project%20one")
  [ "$out" = "/tmp/project one" ] || fail "file URI path decode failed: $out"
  out=$(bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_cwd_path "$1"' "$ROOT" "file:///C:/Users/Tomas/project%20one")
  [ "$out" = "/c/Users/Tomas/project one" ] || fail "Windows file URI path decode failed: $out"
  out=$(bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_cwd_path "$1"' "$ROOT" "file://C:/Users/Tomas/project%20one")
  [ "$out" = "/c/Users/Tomas/project one" ] || fail "Windows hostless file URI path decode failed: $out"
  out=$(bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_cwd_path "$1"' "$ROOT" "file://host.example/tmp/project")
  [ "$out" = "/tmp/project" ] || fail "host file URI path decode failed: $out"
  out=$(bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_cwd_path "$1"' "$ROOT" "file://wsl.localhost/Ubuntu/home/me/project%20one")
  [ "$out" = "/home/me/project one" ] || fail "WSL file URI path decode failed: $out"
  pass "wezterm cwd_path decodes local, Windows, host, and WSL file URIs"
}

test_current_path_uses_active_pwd_probe() {
  local dir fb target out
  dir="$TMP_ROOT/current-path"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 44 7 3 "$dir"
  target=wezterm:44
  out=$(PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    FM_WEZTERM_TEXT=$'prompt\n__FM_WEZTERM_CWD_BEGIN__\n/tmp/fm-worktree\n__FM_WEZTERM_CWD_END__\n/tmp/fm-worktree $' \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_current_path "$1"' "$ROOT" "$target") \
    || fail "wezterm current_path failed"
  [ "$out" = "/tmp/fm-worktree" ] || fail "current_path should read the marked pwd output, got '$out'"
  assert_contains "$(cat "$dir/log")" "__FM_WEZTERM_CWD_BEGIN__" "current_path did not send the cwd begin marker"
  assert_contains "$(cat "$dir/log")" "pwd;" "current_path did not send the pwd probe"
  pass "wezterm current_path: active pwd marker probe drives worktree discovery"
}

test_send_capture_kill_primitives() {
  local dir fb target
  dir="$TMP_ROOT/primitives"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 44 7 3 "$dir"
  target=wezterm:44
  PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_TEXT="Type a message..." \
    bash -c '. "$0/bin/backends/wezterm.sh";
      fm_backend_wezterm_send_literal "$1" hello;
      fm_backend_wezterm_send_key "$1" Enter;
      fm_backend_wezterm_capture "$1" 20 >/dev/null;
      [ "$(fm_backend_wezterm_composer_state "$1")" = empty ];
      fm_backend_wezterm_kill "$1"' "$ROOT" "$target" \
    || fail "wezterm send/capture/kill primitives failed"
  assert_contains "$(cat "$dir/log")" $'send-text\x1f--pane-id\x1f44\x1f--no-paste' \
    "send primitives did not target pane 44 with direct text"
  assert_contains "$(cat "$dir/log")" $'get-text\x1f--pane-id\x1f44\x1f--start-line\x1f-20' \
    "capture primitive did not use get-text with bounded tail"
  assert_contains "$(cat "$dir/log")" $'kill-pane\x1f--pane-id\x1f44' \
    "kill primitive did not kill pane 44"
  pass "wezterm primitives: send, Enter, capture, composer state, kill"
}

test_composer_state_treats_bordered_idle_as_empty() {
  local dir fb target line state
  dir="$TMP_ROOT/bordered-idle"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 44 7 3 "$dir"
  target=wezterm:44
  for line in \
    "│ >                                            │" \
    "│ ❯                                            │" \
    "│ >  │" \
    "│                                              │"; do
    state=$(PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_TEXT="$line" \
      bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_composer_state "$1"' "$ROOT" "$target") \
      || fail "wezterm bordered idle composer_state failed"
    [ "$state" = empty ] || fail "bordered idle composer should be empty for <$line>, got '$state'"
  done
  pass "wezterm composer state treats bordered idle prompts as empty"
}

test_composer_state_treats_bordered_text_as_pending() {
  local dir fb target state
  dir="$TMP_ROOT/bordered-text"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 44 7 3 "$dir"
  target=wezterm:44
  state=$(PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    FM_WEZTERM_TEXT="│ > fix findings 1 and 3, skip 2               │" \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_composer_state "$1"' "$ROOT" "$target") \
    || fail "wezterm bordered text composer_state failed"
  [ "$state" = pending ] || fail "bordered composer text should be pending, got '$state'"
  pass "wezterm composer state preserves real bordered text as pending"
}

test_composer_state_uses_bordered_composer_row_before_footers() {
  local dir fb target state
  dir="$TMP_ROOT/composer-footer"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 44 7 3 "$dir"
  target=wezterm:44
  state=$(PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    FM_WEZTERM_TEXT=$'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ─────╯\n\n  Enter:send' \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_composer_state "$1"' "$ROOT" "$target") \
    || fail "wezterm bordered composer row before footer failed"
  [ "$state" = empty ] || fail "empty composer before bottom border/footer should be empty, got '$state'"
  pass "wezterm composer state reads the bordered composer row before footers"
}

test_composer_state_treats_busy_footer_as_empty() {
  local dir fb target state
  dir="$TMP_ROOT/busy-footer"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 44 7 3 "$dir"
  target=wezterm:44
  state=$(PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    FM_WEZTERM_TEXT="esc to interrupt" \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_composer_state "$1"' "$ROOT" "$target") \
    || fail "wezterm busy footer composer_state failed"
  [ "$state" = empty ] || fail "busy footer should not be pending input, got '$state'"
  pass "wezterm composer state treats busy footer rows as empty"
}

test_tool_check_requires_wezterm_cli_features() {
  local dir fb out
  dir="$TMP_ROOT/tool-check"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/backends/wezterm.sh"; fm_backend_wezterm_tool_check' "$ROOT" 2>&1)
  expect_code 1 $? "tool_check should reject fake wezterm without required help output"
  assert_contains "$out" "missing required mux features" "tool_check should name missing WezTerm CLI feature support"
  pass "wezterm tool_check: required CLI mux features are probed"
}

test_send_text_submit_retries_pending_composer() {
  local dir fb target state send_count
  dir="$TMP_ROOT/submit"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 44 7 3 "$dir"
  target=wezterm:44
  state=$(PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" FM_WEZTERM_TEXT="not submitted yet" \
    bash -c '. "$0/bin/backends/wezterm.sh";
      fm_backend_wezterm_send_text_submit "$1" "hello" 3 0 0' "$ROOT" "$target") \
    || fail "wezterm send_text_submit failed"
  [ "$state" = pending ] || fail "wezterm pending composer should return pending after retries, got '$state'"
  send_count=$(grep -c $'wezterm\x1fcli\x1fsend-text' "$dir/log" || true)
  [ "$send_count" -eq 4 ] || fail "send_text_submit should send literal once plus 3 Enter retries, saw $send_count send-text calls"
  pass "wezterm send_text_submit: pending composer triggers Enter retries and reports pending"
}

test_target_exists_dispatch_accepts_wezterm() {
  local dir fb out
  dir="$TMP_ROOT/dispatch"; mkdir -p "$dir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 55 8 4 "$dir"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate_spawn wezterm; fm_backend_target_exists wezterm wezterm:55 && printf ok' "$ROOT" )
  [ "$out" = ok ] || fail "backend dispatch did not accept live wezterm target, got '$out'"
  pass "fm-backend dispatch: wezterm is spawn-capable and supports target liveness"
}

test_expected_label_rejects_reused_pane_id() {
  local dir fb state out status
  dir="$TMP_ROOT/label-mismatch"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 55 8 4 "$dir"
  {
    printf 'backend=wezterm\n'
    printf 'window=wezterm:55\n'
    printf 'wezterm_window_id=4\n'
    printf 'wezterm_tab_id=99\n'
    printf 'wezterm_pane_id=55\n'
  } > "$state/taskx.meta"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_key wezterm wezterm:55 Escape fm-taskx' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "expected-label send_key should reject reused pane id whose live tab does not match metadata"
  assert_not_contains "$(cat "$dir/log")" $'send-text\x1f--pane-id\x1f55' \
    "send_key should not send after metadata/live pane mismatch"
  pass "wezterm target_ready: expected labels reject stale pane ids reused by another tab"
}

test_expected_label_rejects_identity_match_outside_worktree() {
  local dir fb state worktree other out status
  dir="$TMP_ROOT/worktree-mismatch"; state="$dir/state"; worktree="$dir/worktree"; other="$dir/other"
  mkdir -p "$state" "$worktree" "$other"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 55 8 4 "$other"
  {
    printf 'backend=wezterm\n'
    printf 'window=wezterm:55\n'
    printf 'worktree=%s\n' "$worktree"
    printf 'wezterm_window_id=4\n'
    printf 'wezterm_tab_id=8\n'
    printf 'wezterm_pane_id=55\n'
  } > "$state/taskx.meta"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_key wezterm wezterm:55 Escape fm-taskx' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "expected-label send_key should reject an identity-matched pane outside the recorded worktree"
  assert_not_contains "$(cat "$dir/log")" $'send-text\x1f--pane-id\x1f55' \
    "send_key should not send when live cwd is outside the recorded worktree"
  pass "wezterm target_ready: expected labels reject identity-matched panes outside the recorded worktree"
}

test_expected_label_accepts_identity_match_inside_worktree() {
  local dir fb state worktree subdir out
  dir="$TMP_ROOT/worktree-match"; state="$dir/state"; worktree="$dir/worktree"; subdir="$worktree/subdir"
  mkdir -p "$state" "$subdir"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 55 8 4 "$subdir"
  {
    printf 'backend=wezterm\n'
    printf 'window=wezterm:55\n'
    printf 'worktree=%s\n' "$worktree"
    printf 'wezterm_window_id=4\n'
    printf 'wezterm_tab_id=8\n'
    printf 'wezterm_pane_id=55\n'
  } > "$state/taskx.meta"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_key wezterm wezterm:55 Escape fm-taskx && printf ok' "$ROOT" )
  [ "$out" = ok ] || fail "expected-label send_key should accept an identity-matched pane inside the recorded worktree, got '$out'"
  assert_contains "$(cat "$dir/log")" $'send-text\x1f--pane-id\x1f55' \
    "send_key should send when live cwd is inside the recorded worktree"
  pass "wezterm target_ready: expected labels accept identity-matched panes inside the recorded worktree"
}

test_expected_label_rejects_missing_identity_fields() {
  local dir fb state worktree out status
  dir="$TMP_ROOT/missing-identity"; state="$dir/state"; worktree="$dir/worktree"
  mkdir -p "$state" "$worktree"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 55 8 4 "$worktree"
  {
    printf 'backend=wezterm\n'
    printf 'window=wezterm:55\n'
    printf 'worktree=%s\n' "$worktree"
  } > "$state/taskx.meta"
  out=$( PATH="$fb:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_key wezterm wezterm:55 Escape fm-taskx' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "expected-label send_key should reject metadata without WezTerm identity fields"
  assert_not_contains "$(cat "$dir/log")" $'send-text\x1f--pane-id\x1f55' \
    "send_key should not send when metadata lacks WezTerm identity fields"
  pass "wezterm target_ready: expected labels require recorded WezTerm identity fields"
}

test_fm_spawn_records_wezterm_metadata() {
  local dir fb proj wt data state config id out meta
  dir="$TMP_ROOT/fm-spawn"; mkdir -p "$dir"
  proj="$dir/project"; wt="$dir/worktree"; data="$dir/data"; state="$dir/state"; config="$dir/config"
  id=wezspawnz1
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 10 2 1 "$wt"
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$dir/unused-projects" FM_SPAWN_NO_GUARD=1 FM_WEZTERM_FEATURES=1 FM_WEZTERM_LOG="$dir/log" FM_WEZTERM_LIST="$dir/list.json" \
    FM_WEZTERM_TEXT=$'prompt\n__FM_WEZTERM_CWD_BEGIN__\n'"$wt"$'\n__FM_WEZTERM_CWD_END__\n'"$wt"$' $' \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend wezterm 2>&1)
  expect_code 0 $? "fm-spawn --backend wezterm should succeed"$'\n'"$out"
  meta="$state/$id.meta"
  assert_contains "$(cat "$meta")" "backend=wezterm" "wezterm spawn did not record backend=wezterm"
  assert_contains "$(cat "$meta")" "window=wezterm:10" "wezterm spawn did not record opaque pane target"
  assert_contains "$(cat "$meta")" "wezterm_window_id=1" "wezterm spawn did not record window id"
  assert_contains "$(cat "$meta")" "wezterm_tab_id=2" "wezterm spawn did not record tab id"
  assert_contains "$(cat "$meta")" "wezterm_pane_id=10" "wezterm spawn did not record pane id"
  assert_contains "$out" "window=wezterm:10 worktree=$wt" "wezterm spawn summary did not include target/worktree"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: backend=wezterm records explicit backend and WezTerm pane metadata"
}

test_secondmate_launch_clears_env_selected_wezterm_backend() {
  local dir primary sm fb data state config id out log
  dir="$TMP_ROOT/fm-spawn-secondmate"; primary="$dir/primary"; sm="$dir/secondmate"
  data="$primary/data"; state="$primary/state"; config="$primary/config"
  id=wezsmz1
  mkdir -p "$data/$id" "$state" "$config" "$primary/projects" "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  fb=$(make_wezterm_fakebin "$dir")
  write_list "$dir/list.json" 10 2 1 "$sm"
  log="$dir/log"
  out=$(PATH="$fb:$PATH" FM_BACKEND=wezterm FM_HOME="$primary" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$primary/projects" FM_SPAWN_NO_GUARD=1 FM_WEZTERM_FEATURES=1 FM_WEZTERM_LOG="$log" FM_WEZTERM_LIST="$dir/list.json" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$sm" "sh -c 'echo secondmate'" --secondmate 2>&1)
  expect_code 0 $? "FM_BACKEND=wezterm fm-spawn --secondmate should succeed"$'\n'"$out"
  assert_contains "$(cat "$log")" "FM_HOME='$sm'" "secondmate launch did not scope the agent to the secondmate home"
  assert_contains "$(cat "$log")" "FM_BACKEND= FM_HOME='$sm'" "secondmate launch did not clear ambient FM_BACKEND before setting FM_HOME"
  assert_contains "$(cat "$state/$id.meta")" "backend=wezterm" "secondmate meta did not record backend=wezterm"
  pass "fm-spawn.sh: env-selected WezTerm secondmate launches clear FM_BACKEND in the agent"
}

test_create_task_spawns_new_tab_and_records_registry
test_create_task_uses_current_pane_context_when_available
test_create_task_reuses_project_tab_and_splits_pane
test_create_task_layout_grows_to_balanced_grid
test_create_task_after_grid_splits_largest_pane
test_create_task_reuses_project_tab_after_seed_pane_exits
test_create_task_ignores_unproven_stale_registry_tab
test_cwd_path_decodes_file_uris
test_current_path_uses_active_pwd_probe
test_send_capture_kill_primitives
test_composer_state_treats_bordered_idle_as_empty
test_composer_state_treats_bordered_text_as_pending
test_composer_state_uses_bordered_composer_row_before_footers
test_composer_state_treats_busy_footer_as_empty
test_tool_check_requires_wezterm_cli_features
test_send_text_submit_retries_pending_composer
test_target_exists_dispatch_accepts_wezterm
test_expected_label_rejects_reused_pane_id
test_expected_label_rejects_identity_match_outside_worktree
test_expected_label_accepts_identity_match_inside_worktree
test_expected_label_rejects_missing_identity_fields
test_fm_spawn_records_wezterm_metadata
test_secondmate_launch_clears_env_selected_wezterm_backend
