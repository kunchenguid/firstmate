#!/usr/bin/env bash
# tests/fm-backend-thurbox.test.sh - stubbed-CLI unit tests for the thurbox
# session-provider adapter (bin/backends/thurbox.sh), written against the
# behaviour verified on the real thurbox 2.9.2 (docs/thurbox-backend.md).
#
# Two stubs, because thurbox is a TWO-CLI backend: a fake `thurbox-cli` for
# session identity and lifecycle, and a fake `tmux` for the pane primitives
# the adapter runs against thurbox's own socket. Both are state-driven rather
# than an ordered response queue (the convention
# tests/fm-backend-{cmux,zellij}.test.sh use): the adapter re-resolves the pane
# from the session row before EVERY operation, so a positional queue would make
# each case a call-counting exercise instead of a behavioural one. A small
# mutable "world" - session rows plus live pane ids - says what is true, and
# the assertions read like the findings they encode.
#
# There is deliberately NO real-binary smoke test alongside this file, unlike
# cmux's and zellij's. tests/thurbox-test-safety.sh's header records why: a
# real thurbox test cannot be isolated from the operator's live sessions,
# because the tmux socket is shared even when the database is not, and a real
# `session create` also leaks thurbox's own automation-heartbeat window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/thurbox-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/thurbox-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the thurbox adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-thurbox-tests)

# --- the fake world ---------------------------------------------------------
#
# $FM_TB_ROWS   one session per line, tab-separated:
#                 <uuid>\t<name>\t<backend_id>\t<backend_type>\t<hook_state>
#               An empty field is written as "-" so read/awk stay simple; the
#               stub maps "-" back to JSON null/"" as thurbox itself would.
# $FM_TB_PANES  whitespace-separated live pane ids on thurbox's tmux socket.
# $FM_TB_SCREEN file whose contents the fake tmux returns for capture-pane.
# $FM_TB_LOG    every thurbox-cli invocation, one unit-separated line.
# $FM_TB_TMUXLOG  every tmux invocation, same shape.

make_thurbox_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"

  cat > "$fb/thurbox-cli" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_TB_LOG:?}"
ROWS="${FM_TB_ROWS:?}"
{ printf 'thurbox-cli'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"

emit_row() {  # <uuid> <name> <pane> <btype> <hook>
  local pane=$3 hook=$5
  [ "$pane" = - ] && pane='' || :
  if [ "$hook" = - ]; then hook=null; else hook="\"$hook\""; fi
  printf '{"id":"%s","name":"%s","backend_id":"%s","backend_type":"%s","hook_state":%s,"cwd":"/w","agent":"shell","worktrees":[]}' \
    "$1" "$2" "$pane" "$4" "$hook"
}

case "${1:-}" in
  version)
    printf '{"version":"%s","schema_version":40,"tmux_socket":"%s","data_dir":"/d"}\n' \
      "${FM_TB_FAKE_VERSION:-2.9.2}" "${FM_TB_FAKE_SOCKET:-thurbox}"
    exit "${FM_TB_FAKE_VERSION_EXIT:-0}"
    ;;
  config)
    printf '{"valid":true,"agents_toml":{"exists":true,"valid":true,"path":"%s","problems":[]}}\n' \
      "${FM_TB_AGENTS_TOML:-/nonexistent}"
    exit 0
    ;;
  session) : ;;
  *) exit 0 ;;
esac

case "${2:-}" in
  list)
    printf '['
    first=1
    while IFS=$'\t' read -r uuid name pane btype hook; do
      [ -n "${uuid:-}" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      emit_row "$uuid" "$name" "$pane" "$btype" "$hook"
    done < "$ROWS"
    printf ']\n'
    ;;
  get)
    want=${3:-}
    while IFS=$'\t' read -r uuid name pane btype hook; do
      if [ "${uuid:-}" = "$want" ]; then
        emit_row "$uuid" "$name" "$pane" "$btype" "$hook"
        printf '\n'
        exit 0
      fi
    done < "$ROWS"
    echo "session not found" >&2
    exit 1
    ;;
  create)
    # Parse the flags the adapter actually passes.
    name=''; pane="${FM_TB_CREATE_PANE:--}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_TB_CREATE_EXIT:-}" ] && { echo "create failed" >&2; exit "$FM_TB_CREATE_EXIT"; }
    uuid="${FM_TB_CREATE_UUID:-11111111-1111-1111-1111-111111111111}"
    printf '%s\t%s\t%s\tlocal-tmux\t-\n' "$uuid" "$name" "$pane" >> "$ROWS"
    # VERIFIED: create's own response carries no backend_id.
    printf '{"id":"%s","name":"%s","cwd":"/w","agent":"shell","agent_session_id":"x","hook_failures":[],"parent_session_id":null,"sharing":null}\n' "$uuid" "$name"
    ;;
  delete)
    want=${3:-}
    tmpf=$(mktemp)
    while IFS=$'\t' read -r uuid name pane btype hook; do
      [ "${uuid:-}" = "$want" ] && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$uuid" "$name" "$pane" "$btype" "$hook" >> "$tmpf"
    done < "$ROWS"
    mv "$tmpf" "$ROWS"
    printf '{"deleted":true,"forced":true,"killed_window":true,"id":"%s"}\n' "$want"
    ;;
  capture)
    want=${3:-}
    grep -q "^$want	" "$ROWS" || { echo "session not found" >&2; exit 1; }
    jq -Rs '{output: .}' < "${FM_TB_CAPTURE:-/dev/null}"
    ;;
  send)
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/thurbox-cli"

  # The fake tmux answers ONLY for thurbox's socket (-L <sock>), which is also
  # how a case proves the adapter never addressed the ambient default server.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_TB_TMUXLOG:?}"
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"

sock=''
if [ "${1:-}" = -L ]; then sock=$2; shift 2; fi
[ "$sock" = "${FM_TB_FAKE_SOCKET:-thurbox}" ] || { echo "no server on socket '$sock'" >&2; exit 1; }

pane_live() {  # <pane-id>
  case " ${FM_TB_PANES:-} " in *" $1 "*) return 0 ;; esac
  return 1
}

case "${1:-}" in
  display-message)
    target=''; fmt=''
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -p) shift ;;
        display-message) shift ;;
        *) fmt=$1; shift ;;
      esac
    done
    pane_live "$target" || { echo "can't find pane" >&2; exit 1; }
    case "$fmt" in
      '#{pane_id}') printf '%s\n' "$target" ;;
      '#{pane_current_path}') printf '%s\n' "${FM_TB_PANE_PATH:-/w}" ;;
      '#{cursor_y}') printf '%s\n' "${FM_TB_CURSOR_Y:-0}" ;;
      *) printf '\n' ;;
    esac
    ;;
  capture-pane)
    target=''
    while [ $# -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    pane_live "$target" || { echo "can't find pane" >&2; exit 1; }
    cat "${FM_TB_SCREEN:-/dev/null}"
    ;;
  send-keys)
    target=''
    for a in "$@"; do :; done
    while [ $# -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    pane_live "$target" || { echo "can't find pane" >&2; exit 1; }
    exit "${FM_TB_SENDKEYS_EXIT:-0}"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

FAKEBIN=$(make_thurbox_fakebin "$TMP_ROOT")

# --- per-case world reset ---------------------------------------------------
#
# Every case starts from a clean world and re-sources nothing: the adapter is
# sourced once below, and the only per-case state is the world plus the
# memoized socket, which MUST be cleared or a case that changes the socket
# would silently reuse the previous one.
reset_world() {
  : > "$TMP_ROOT/rows.tsv"
  : > "$TMP_ROOT/log"
  : > "$TMP_ROOT/tmuxlog"
  : > "$TMP_ROOT/screen"
  : > "$TMP_ROOT/capture"
  export FM_TB_ROWS="$TMP_ROOT/rows.tsv"
  export FM_TB_LOG="$TMP_ROOT/log"
  export FM_TB_TMUXLOG="$TMP_ROOT/tmuxlog"
  export FM_TB_SCREEN="$TMP_ROOT/screen"
  export FM_TB_CAPTURE="$TMP_ROOT/capture"
  export FM_TB_PANES="%20"
  unset FM_TB_FAKE_VERSION FM_TB_FAKE_SOCKET FM_TB_CREATE_UUID FM_TB_CREATE_PANE \
        FM_TB_CREATE_EXIT FM_TB_AGENTS_TOML FM_TB_CURSOR_Y FM_TB_PANE_PATH \
        FM_TB_SENDKEYS_EXIT FM_TB_FAKE_VERSION_EXIT 2>/dev/null || true
  FM_BACKEND_THURBOX_SOCKET_CACHE=''
}

add_row() {  # <uuid> <name> <pane> <btype> <hook>
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$FM_TB_ROWS"
}

# The adapter resolves its CLI through FM_THURBOX_BIN and its tmux through
# PATH, so both point into the fixture and never at a real installation.
export FM_THURBOX_BIN="$FAKEBIN/thurbox-cli"
PATH="$FAKEBIN:$PATH"
export PATH

# The safety guard runs BEFORE the adapter is ever sourced: if the stub is not
# the binary that would be used, nothing below is allowed to run.
thurbox_refuse_if_unsafe "$TMP_ROOT" || fail "thurbox safety guard refused the test's own stub"

FM_ROOT_OVERRIDE="$TMP_ROOT/home"
mkdir -p "$FM_ROOT_OVERRIDE/config"
export FM_ROOT_OVERRIDE
FM_ROOT=$FM_ROOT_OVERRIDE
FM_HOME=$FM_ROOT_OVERRIDE
FM_CONFIG_OVERRIDE="$FM_ROOT_OVERRIDE/config"
export FM_CONFIG_OVERRIDE

# shellcheck source=bin/backends/thurbox.sh
. "$ROOT/bin/backends/thurbox.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

HOMETAG=$(fm_backend_thurbox_home_label)
TITLE="fm-$HOMETAG-t1"
UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

# ============================================================================
# version + socket
# ============================================================================

test_version_check_accepts_verified_build() {
  reset_world
  fm_backend_thurbox_version_check || fail "version check rejected the verified 2.9.2 build"
  pass "version_check accepts the verified build"
}

test_version_check_refuses_older_than_minimum() {
  reset_world
  export FM_TB_FAKE_VERSION=2.8.9
  local out rc
  out=$(fm_backend_thurbox_version_check 2>&1); rc=$?
  expect_code 1 "$rc" "version_check on 2.8.9"
  assert_contains "$out" "older than the verified minimum" "version_check names the floor"
  pass "version_check refuses a build below the verified minimum"
}

test_socket_comes_from_thurbox_not_a_hardcoded_name() {
  reset_world
  export FM_TB_FAKE_SOCKET=tb-alt
  [ "$(fm_backend_thurbox_socket)" = tb-alt ] \
    || fail "socket was not read from thurbox's own version output"
  pass "socket name comes from thurbox's version --json, never hardcoded"
}

test_pane_ops_address_thurbox_socket_only() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  fm_backend_thurbox_current_path "$UUID:%20" >/dev/null
  grep -q $'tmux\x1f-L\x1fthurbox' "$FM_TB_TMUXLOG" \
    || fail "pane primitive did not pass -L thurbox"
  pass "every pane primitive addresses thurbox's own tmux socket"
}

# ============================================================================
# naming
# ============================================================================

test_scoped_title_is_home_tagged() {
  reset_world
  [ "$(fm_backend_thurbox_scoped_title fm-t1)" = "$TITLE" ] \
    || fail "scoped title is not home-tagged"
  pass "scoped title carries this home's tag"
}

test_scoped_title_refuses_over_length_name() {
  reset_world
  local long out rc
  long=$(printf 'fm-%0.sx' $(seq 1 70))
  out=$(fm_backend_thurbox_scoped_title "$long" 2>&1); rc=$?
  expect_code 1 "$rc" "scoped_title on an over-length label"
  assert_contains "$out" "over thurbox's 64-char limit" "over-length refusal names the limit"
  pass "scoped title refuses a name over thurbox's 64-char limit"
}

# ============================================================================
# container ensure / agent config
# ============================================================================

test_container_ensure_refuses_missing_shell_agent() {
  reset_world
  printf 'config_version = 1\n' > "$TMP_ROOT/agents.toml"
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  local out rc
  out=$(fm_backend_thurbox_container_ensure 2>&1); rc=$?
  expect_code 1 "$rc" "container_ensure with no shell agent defined"
  assert_contains "$out" "INTERACTIVE SHELL" "refusal explains why firstmate needs a shell agent"
  pass "container_ensure refuses when the interactive-shell agent is undefined"
}

test_container_ensure_accepts_defined_agent() {
  reset_world
  printf 'config_version = 1\n[[agents]]\nname = "shell"\ncommand = "bash"\n' > "$TMP_ROOT/agents.toml"
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  fm_backend_thurbox_container_ensure || fail "container_ensure rejected a correctly configured thurbox"
  pass "container_ensure accepts a defined interactive-shell agent"
}

test_container_ensure_accepts_single_quoted_toml() {
  reset_world
  # TOML accepts both quote styles for a basic string; an agents.toml written
  # with single quotes is just as valid and must not read as undefined.
  printf "config_version = 1\n[[agents]]\nname = 'shell'\ncommand = 'bash'\n" > "$TMP_ROOT/agents.toml"
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  fm_backend_thurbox_container_ensure || fail "container_ensure rejected a single-quoted agents.toml entry"
  pass "container_ensure accepts either TOML quote style for the agent name"
}

test_configured_agent_name_is_honored() {
  reset_world
  printf 'fmshell\n' > "$FM_CONFIG_OVERRIDE/thurbox-agent"
  [ "$(fm_backend_thurbox_agent)" = fmshell ] || fail "config/thurbox-agent was not read"
  rm -f "$FM_CONFIG_OVERRIDE/thurbox-agent"
  [ "$(fm_backend_thurbox_agent)" = shell ] || fail "default agent is not 'shell'"
  pass "config/thurbox-agent selects the agent, defaulting to shell"
}

# ============================================================================
# create
# ============================================================================

test_create_task_returns_uuid_and_polled_pane() {
  reset_world
  printf 'config_version = 1\n[[agents]]\nname = "shell"\ncommand = "bash"\n' > "$TMP_ROOT/agents.toml"
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  export FM_TB_CREATE_UUID=$UUID FM_TB_CREATE_PANE='%31'
  export FM_TB_PANES='%31'
  local out
  out=$(fm_backend_thurbox_create_task fm-t1 /w) || fail "create_task failed"
  [ "$out" = "$UUID %31" ] || fail "create_task returned '$out', expected '$UUID %31'"
  # VERIFIED finding 1: create's response has no backend_id, so the pane can
  # only have come from a follow-up session get.
  grep -q $'session\x1fget' "$FM_TB_LOG" \
    || fail "create_task did not resolve the pane id through session get"
  pass "create_task returns the session uuid plus a pane resolved by a later get"
}

test_create_task_refuses_duplicate_name() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  local out rc
  out=$(fm_backend_thurbox_create_task fm-t1 /w 2>&1); rc=$?
  expect_code 1 "$rc" "create_task against an existing name"
  assert_contains "$out" "already exists" "duplicate refusal names the collision"
  assert_no_grep $'session\x1fcreate' "$FM_TB_LOG" "duplicate check must run BEFORE create"
  pass "create_task refuses a duplicate name thurbox itself would have allowed"
}

test_create_task_passes_configured_agent() {
  reset_world
  printf 'fmshell\n' > "$FM_CONFIG_OVERRIDE/thurbox-agent"
  export FM_TB_CREATE_UUID=$UUID FM_TB_CREATE_PANE='%31' FM_TB_PANES='%31'
  fm_backend_thurbox_create_task fm-t1 /w >/dev/null || fail "create_task failed"
  assert_grep $'--agent\x1ffmshell' "$FM_TB_LOG" "create_task did not pass the configured agent"
  rm -f "$FM_CONFIG_OVERRIDE/thurbox-agent"
  pass "create_task launches the configured thurbox agent"
}

# ============================================================================
# target resolution - the identity model
# ============================================================================

test_parse_target_splits_on_first_colon() {
  reset_world
  fm_backend_thurbox_parse_target "$UUID:%20" || fail "parse_target rejected a valid target"
  [ "$FM_BACKEND_THURBOX_SESSION" = "$UUID" ] || fail "session uuid mis-parsed"
  [ "$FM_BACKEND_THURBOX_PANE" = '%20' ] || fail "pane id mis-parsed"
  fm_backend_thurbox_parse_target "nocolon" && fail "parse_target accepted a target with no colon"
  pass "parse_target splits <uuid>:<pane> on the first colon"
}

test_target_ready_reresolves_pane_after_restart() {
  reset_world
  # The headline finding: `session restart` moved the pane %23 -> %24 while the
  # session uuid stayed put. A target recorded before the restart must still
  # resolve, and must resolve to the NEW pane.
  add_row "$UUID" "$TITLE" "%24" local-tmux -
  export FM_TB_PANES='%24'
  fm_backend_thurbox_target_ready "$UUID:%23" fm-t1 \
    || fail "target_ready failed against a stale-but-recoverable pane id"
  [ "$FM_BACKEND_THURBOX_PANE" = '%24' ] \
    || fail "target_ready kept the stale pane '%23' instead of re-resolving to '%24'"
  pass "target_ready re-resolves the pane id from the durable session uuid"
}

test_target_ready_refuses_name_mismatch() {
  reset_world
  add_row "$UUID" "fm-$HOMETAG-someone-else" "%20" local-tmux -
  fm_backend_thurbox_target_ready "$UUID:%20" fm-t1 \
    && fail "target_ready accepted a session belonging to a different task"
  pass "target_ready refuses a uuid whose session name is another task's"
}

test_target_ready_refuses_remote_session() {
  reset_world
  # `session create --host` runs the window on another machine; no pane of it
  # exists on this machine's thurbox socket, so every pane primitive would
  # silently address nothing.
  add_row "$UUID" "$TITLE" "%20" remote-ssh -
  fm_backend_thurbox_target_ready "$UUID:%20" fm-t1 \
    && fail "target_ready accepted a non-local-tmux (remote) session"
  pass "target_ready refuses a remote session it cannot address"
}

test_target_ready_recovers_by_label_when_uuid_is_gone() {
  reset_world
  local newuuid=99999999-9999-9999-9999-999999999999
  add_row "$newuuid" "$TITLE" "%40" local-tmux -
  export FM_TB_PANES='%40'
  fm_backend_thurbox_target_ready "$UUID:%20" fm-t1 \
    || fail "target_ready did not recover a recreated session by label"
  [ "$FM_BACKEND_THURBOX_SESSION" = "$newuuid" ] || fail "recovered the wrong session"
  pass "target_ready recovers by scoped name when the recorded uuid is gone"
}

test_target_ready_without_label_cannot_guess() {
  reset_world
  fm_backend_thurbox_target_ready "$UUID:%20" \
    && fail "target_ready invented a target with no row and no label to recover by"
  pass "target_ready fails closed when the uuid is gone and no label was given"
}

test_target_ready_refuses_when_pane_is_dead() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  export FM_TB_PANES=''
  fm_backend_thurbox_target_ready "$UUID:%20" fm-t1 \
    && fail "target_ready accepted a session whose pane no longer exists"
  pass "target_ready refuses when thurbox's tmux server has no such pane"
}

# ============================================================================
# input
# ============================================================================

test_send_literal_never_uses_thurbox_session_send() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  fm_backend_thurbox_send_literal "$UUID:%20" 'hello world' fm-t1 \
    || fail "send_literal failed"
  # The trap this guards: `thurbox-cli session send` ALWAYS appends Enter, so
  # routing unsubmitted input through it would submit every steer on arrival.
  assert_no_grep $'session\x1fsend' "$FM_TB_LOG" \
    "send_literal used thurbox-cli session send, which auto-submits"
  assert_grep $'send-keys' "$FM_TB_TMUXLOG" "send_literal did not use tmux send-keys"
  assert_grep $'\x1f-l\x1f' "$FM_TB_TMUXLOG" "send_literal did not send literally"
  pass "send_literal sends unsubmitted input via tmux, never session send"
}

test_send_key_normalizes_to_tmux_names() {
  reset_world
  [ "$(fm_backend_thurbox_normalize_key Escape)" = Escape ] || fail "Escape mis-normalized"
  [ "$(fm_backend_thurbox_normalize_key ctrl-c)" = C-c ] || fail "ctrl-c mis-normalized"
  [ "$(fm_backend_thurbox_normalize_key Ctrl+U)" = C-u ] || fail "Ctrl+U mis-normalized"
  [ "$(fm_backend_thurbox_normalize_key enter)" = Enter ] || fail "enter mis-normalized"
  pass "send_key normalizes firstmate's key vocabulary to tmux key names"
}

test_send_key_refuses_dead_target() {
  reset_world
  export FM_TB_PANES=''
  fm_backend_thurbox_send_key "$UUID:%20" Enter fm-t1 \
    && fail "send_key succeeded against a target that does not resolve"
  pass "send_key refuses a target that no longer resolves"
}

# ============================================================================
# capture + composer
# ============================================================================

test_capture_reads_output_field_and_trims_locally() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  printf 'l1\nl2\nl3\nl4\nl5\n' > "$FM_TB_CAPTURE"
  local out
  out=$(fm_backend_thurbox_capture "$UUID:%20" 2 fm-t1) || fail "capture failed"
  # VERIFIED: --lines bounds thurbox's fetch but the response is not trimmed to
  # it, so the adapter trims locally.
  [ "$out" = $'l4\nl5' ] || fail "capture did not trim to the requested line count: '$out'"
  pass "capture reads .output and trims to the requested lines locally"
}

test_capture_is_plain_text_composer_is_styled() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  printf 'plain\n' > "$FM_TB_CAPTURE"
  printf 'styled\n' > "$FM_TB_SCREEN"
  [ "$(fm_backend_thurbox_capture "$UUID:%20" 5 fm-t1)" = plain ] \
    || fail "human-facing capture did not come from thurbox-cli"
  [ "$(fm_backend_thurbox_composer_capture "$UUID:%20" fm-t1)" = styled ] \
    || fail "composer capture did not come from tmux capture-pane"
  assert_grep $'-e' "$FM_TB_TMUXLOG" "composer capture did not request ANSI styling"
  pass "plain capture goes through thurbox-cli, styled capture through tmux -e"
}

test_composer_caps_claim_styled_and_cursor() {
  reset_world
  local caps
  caps=$(fm_backend_thurbox_composer_caps)
  assert_contains "$caps" 'styled=1' "thurbox must declare styled=1"
  assert_contains "$caps" 'cursor=1' "thurbox must declare cursor=1"
  # identity=0 is deliberate: no thurbox-socket identity probe is verified yet.
  assert_contains "$caps" 'identity=0' "thurbox must not claim an unverified identity probe"
  pass "composer caps claim tmux-grade styled+cursor and no unproven identity"
}

test_composer_state_unknown_when_pane_unreadable() {
  reset_world
  export FM_TB_PANES=''
  [ "$(fm_backend_thurbox_composer_state "$UUID:%20" fm-t1)" = unknown ] \
    || fail "composer_state did not fail safe to unknown"
  pass "composer_state degrades to unknown when the pane cannot be read"
}

# ============================================================================
# native busy state
# ============================================================================

test_busy_state_maps_thurbox_hook_state() {
  local state expected
  for pair in 'working busy' 'idle idle' 'done idle' 'blocked idle'; do
    state=${pair%% *}; expected=${pair##* }
    reset_world
    add_row "$UUID" "$TITLE" "%20" local-tmux "$state"
    [ "$(fm_backend_thurbox_busy_state "$UUID:%20" fm-t1)" = "$expected" ] \
      || fail "hook_state '$state' did not map to '$expected'"
  done
  pass "busy_state maps thurbox's hook_state with herdr's exact vocabulary"
}

test_busy_state_unknown_before_first_signal() {
  reset_world
  # hook_state is null until an agent first signals; null must never read idle.
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  [ "$(fm_backend_thurbox_busy_state "$UUID:%20" fm-t1)" = unknown ] \
    || fail "a null hook_state was not reported as unknown"
  pass "busy_state reports unknown, never idle, before the first signal"
}

# ============================================================================
# teardown + discovery
# ============================================================================

test_kill_forces_window_reclaim() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  fm_backend_thurbox_kill "$UUID:%20" '' fm-t1
  # Without --force thurbox only soft-deletes the row and defers window
  # cleanup to a TUI sync that a headless teardown never gets.
  assert_grep $'--force' "$FM_TB_LOG" "kill did not pass --force"
  pass "kill passes --force so the window is actually reclaimed headlessly"
}

test_kill_refuses_recycled_uuid() {
  reset_world
  add_row "$UUID" "fm-$HOMETAG-other" "%20" local-tmux -
  fm_backend_thurbox_kill "$UUID:%20" '' fm-t1
  assert_no_grep $'session\x1fdelete' "$FM_TB_LOG" \
    "kill deleted a session whose name belongs to another task"
  pass "kill refuses a uuid that now names a different task"
}

test_list_live_filters_and_skips_unaddressable() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  add_row 22222222-2222-2222-2222-222222222222 "someone-elses-session" "%21" local-tmux -
  add_row 33333333-3333-3333-3333-333333333333 "fm-$HOMETAG-remote" "%22" remote-ssh -
  add_row 44444444-4444-4444-4444-444444444444 "fm-$HOMETAG-nopane" "-" local-tmux -
  local out
  out=$(fm_backend_thurbox_list_live)
  [ "$out" = "$UUID:%20	fm-t1" ] || fail "list_live returned unexpected rows: '$out'"
  pass "list_live scopes to this home and skips remote/pane-less rows"
}

# ============================================================================
# integration with the shared dispatcher
# ============================================================================

test_backend_is_known_and_spawn_capable() {
  fm_backend_is_known thurbox || fail "thurbox is not in the known backend set"
  fm_backend_validate_spawn thurbox || fail "thurbox is not spawn-capable"
  assert_contains "$(fm_backend_required_tools thurbox)" "thurbox-cli" "required tools omit thurbox-cli"
  assert_contains "$(fm_backend_required_tools thurbox)" "tmux" "required tools omit tmux"
  pass "thurbox is a known, spawn-capable backend with a declared toolchain"
}

test_endpoint_validation_accepts_consistent_meta() {
  reset_world
  local meta="$TMP_ROOT/t1.meta"
  cat > "$meta" <<EOF
window=$UUID:%20
endpoint_task_id=t1
worktree=/w
project=/p
backend=thurbox
thurbox_session_id=$UUID
thurbox_pane_id=%20
EOF
  fm_backend_validate_task_endpoint "$meta" t1 \
    || fail "endpoint validation refused a well-formed thurbox record"
  [ "$FM_BACKEND_VALIDATED_BACKEND" = thurbox ] || fail "validated backend not reported"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$UUID:%20" ] || fail "validated target not reported"
  pass "endpoint validation accepts a consistent thurbox record"
}

test_endpoint_validation_refuses_inconsistent_meta() {
  reset_world
  local meta="$TMP_ROOT/t2.meta" out rc
  cat > "$meta" <<EOF
window=$UUID:%20
endpoint_task_id=t2
worktree=/w
project=/p
backend=thurbox
thurbox_session_id=$UUID
thurbox_pane_id=%99
EOF
  out=$(fm_backend_validate_task_endpoint "$meta" t2 2>&1); rc=$?
  expect_code 1 "$rc" "endpoint validation on a window/pane mismatch"
  assert_contains "$out" "REFUSED" "inconsistent record must refuse loudly"
  pass "endpoint validation refuses a record whose window and pane disagree"
}

test_detect_prefers_thurbox_over_its_own_tmux_socket() {
  reset_world
  local got
  got=$(TMUX="/tmp/tmux-1000/thurbox,123,0" THURBOX_SESSION="$UUID" fm_backend_detect)
  [ "$got" = thurbox ] || fail "detect chose '$got' inside a thurbox pane, expected thurbox"
  pass "detect prefers thurbox when \$TMUX names thurbox's own socket"
}

test_detect_prefers_tmux_for_nested_server() {
  reset_world
  local got
  # A nested tmux started INSIDE a thurbox pane inherits THURBOX_SESSION but
  # runs on a different socket - there, tmux really is the innermost layer.
  got=$(TMUX="/tmp/tmux-1000/default,123,0" THURBOX_SESSION="$UUID" fm_backend_detect)
  [ "$got" = tmux ] || fail "detect chose '$got' in a nested tmux, expected tmux"
  pass "detect yields to tmux for a nested server on a different socket"
}

# ============================================================================
# safety guard
# ============================================================================

test_safety_guard_refuses_a_real_cli() {
  local out rc
  out=$(FM_THURBOX_BIN=/bin/sh thurbox_refuse_if_unsafe "$TMP_ROOT" 2>&1); rc=$?
  expect_code 1 "$rc" "safety guard against a binary outside the fixture"
  assert_contains "$out" "outside the test fixture" "guard must name the containment rule"
  out=$(FM_THURBOX_BIN='' thurbox_refuse_if_unsafe "$TMP_ROOT" 2>&1); rc=$?
  expect_code 1 "$rc" "safety guard against an unset binary"
  pass "safety guard refuses any thurbox-cli outside the test fixture"
}

test_version_check_accepts_verified_build
test_version_check_refuses_older_than_minimum
test_socket_comes_from_thurbox_not_a_hardcoded_name
test_pane_ops_address_thurbox_socket_only
test_scoped_title_is_home_tagged
test_scoped_title_refuses_over_length_name
test_container_ensure_refuses_missing_shell_agent
test_container_ensure_accepts_defined_agent
test_container_ensure_accepts_single_quoted_toml
test_configured_agent_name_is_honored
test_create_task_returns_uuid_and_polled_pane
test_create_task_refuses_duplicate_name
test_create_task_passes_configured_agent
test_parse_target_splits_on_first_colon
test_target_ready_reresolves_pane_after_restart
test_target_ready_refuses_name_mismatch
test_target_ready_refuses_remote_session
test_target_ready_recovers_by_label_when_uuid_is_gone
test_target_ready_without_label_cannot_guess
test_target_ready_refuses_when_pane_is_dead
test_send_literal_never_uses_thurbox_session_send
test_send_key_normalizes_to_tmux_names
test_send_key_refuses_dead_target
test_capture_reads_output_field_and_trims_locally
test_capture_is_plain_text_composer_is_styled
test_composer_caps_claim_styled_and_cursor
test_composer_state_unknown_when_pane_unreadable
test_busy_state_maps_thurbox_hook_state
test_busy_state_unknown_before_first_signal
test_kill_forces_window_reclaim
test_kill_refuses_recycled_uuid
test_list_live_filters_and_skips_unaddressable
test_backend_is_known_and_spawn_capable
test_endpoint_validation_accepts_consistent_meta
test_endpoint_validation_refuses_inconsistent_meta
test_detect_prefers_thurbox_over_its_own_tmux_socket
test_detect_prefers_tmux_for_nested_server
test_safety_guard_refuses_a_real_cli
