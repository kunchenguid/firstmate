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
    [ -n "${FM_TB_LIST_EXIT:-}" ] && { echo "database is locked" >&2; exit "$FM_TB_LIST_EXIT"; }
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
      '#{pane_tty}') printf '%s\n' "${FM_TB_PANE_TTY:-}" ;;
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

  # A third stub, for the ONE non-tmux, non-thurbox primitive the adapter
  # reaches: the process table behind a pane's tty, which is how Cursor's
  # foreground identity is established (bin/fm-cursor-lib.sh). Stubbing `ps`
  # rather than the identity function keeps the real pgid/tpgid foreground
  # scoping and the real name/install-tree matching under test.
  #
  # $FM_TB_PS is a table, one process per line:
  #   <tty>\t<pid>\t<pgid>\t<tpgid>\t<comm>\t<args>
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
table="${FM_TB_PS:-}"
# Anything outside a case that set up a fake process table gets the real ps,
# so this stub cannot change the behaviour of unrelated code on this PATH.
[ -n "$table" ] && [ -f "$table" ] || exec "${FM_TB_REAL_PS:?}" "$@"
case "${1:-}" in
  -t)
    want=$2
    while IFS=$'\t' read -r tty pid pgid tpgid comm args; do
      [ "${tty:-}" = "$want" ] || continue
      printf '%s %s %s %s\n' "$pid" "$pgid" "$tpgid" "$comm"
    done < "$table"
    ;;
  -p)
    want=$2
    while IFS=$'\t' read -r tty pid pgid tpgid comm args; do
      [ "${pid:-}" = "$want" ] || continue
      printf '%s\n' "$args"
    done < "$table"
    ;;
  *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/ps"
  printf '%s\n' "$fb"
}

FM_TB_REAL_PS=$(command -v ps) || fail "ps not found"
export FM_TB_REAL_PS
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
        FM_TB_SENDKEYS_EXIT FM_TB_FAKE_VERSION_EXIT FM_TB_PS FM_TB_PANE_TTY \
        FM_TB_LIST_EXIT 2>/dev/null || true
  FM_BACKEND_THURBOX_SOCKET_CACHE=''
  # The adapter's own RESOLUTION output, not fixture state: target_ready and
  # resolve_row set these in whatever shell calls them, so a case run directly
  # in the suite shell leaves them behind. Clearing them is what stops a later
  # case from passing on an earlier case's resolution instead of its own - a
  # green that would survive the adapter never resolving anything at all.
  unset FM_BACKEND_THURBOX_PANE FM_BACKEND_THURBOX_SESSION \
        FM_BACKEND_THURBOX_ROW FM_BACKEND_THURBOX_ROW_UUID 2>/dev/null || true
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
# The away-mode captain-pane resolver. Its thurbox arm is what makes the
# daemon's and fm-afk-launch.sh's existing refusals reachable at all, and it
# needs the same THURBOX_SESSION-plus-socket detection this file already stubs.
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$ROOT/bin/fm-supervisor-target-lib.sh"

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

test_container_ensure_refuses_a_name_outside_an_agents_table() {
  reset_world
  # agents.toml also carries hook, profile, and sharing tables with their own
  # `name` keys. Reading one of those as an agent would report the missing
  # entry as defined and push the failure back out to `session create --agent`,
  # which is the exact late failure this gate exists to prevent.
  printf 'config_version = 1\n[[hooks]]\nname = "shell"\ncommand = "true"\n' > "$TMP_ROOT/agents.toml"
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  local rc
  fm_backend_thurbox_container_ensure >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "container_ensure with 'shell' named only in an unrelated table"
  pass "container_ensure only accepts a name inside an [[agents]] table"
}

test_container_ensure_matches_the_agent_name_literally() {
  reset_world
  # A configured name carrying a regex metacharacter must not match a
  # different entry: '.' is not a wildcard here.
  printf 'fm.shell\n' > "$FM_CONFIG_OVERRIDE/thurbox-agent"
  printf 'config_version = 1\n[[agents]]\nname = "fmXshell"\ncommand = "bash"\n' > "$TMP_ROOT/agents.toml"
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  local rc
  fm_backend_thurbox_container_ensure >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "container_ensure matched 'fm.shell' against the entry 'fmXshell'"
  printf 'config_version = 1\n[[agents]]\nname = "fm.shell"\ncommand = "bash"\n' > "$TMP_ROOT/agents.toml"
  fm_backend_thurbox_container_ensure \
    || fail "container_ensure rejected the agent entry that is literally named 'fm.shell'"
  rm -f "$FM_CONFIG_OVERRIDE/thurbox-agent"
  pass "the configured agent name is matched literally, never as a regex"
}

test_container_ensure_accepts_a_commented_agents_toml() {
  reset_world
  # An ordinary operator agents.toml: a trailing comment on the entry, and one
  # on the table header. thurbox's own `config validate` accepts both, so a
  # gate that reads them as undefined refuses every spawn while telling the
  # operator to add an entry that is already there.
  printf 'config_version = 1\n[[agents]] # firstmate\nname = "shell" # firstmate'"'"'s interactive shell\ncommand = "bash"\nargs = ["-i"]\n' > "$TMP_ROOT/agents.toml"
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  fm_backend_thurbox_container_ensure \
    || fail "container_ensure refused a commented agents.toml entry that thurbox itself accepts"
  pass "container_ensure accepts an agents.toml carrying ordinary trailing comments"
}

test_container_ensure_reads_toml_shape_variants() {
  reset_world
  export FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
  # TOML permits whitespace inside a table header and around the key/value
  # separator; a header this scan fails to recognize silently skips its whole
  # table, which is the same false refusal by another route.
  printf 'config_version = 1\n[[ agents ]]\n  name="shell"\n  command = "bash"\n' > "$TMP_ROOT/agents.toml"
  fm_backend_thurbox_container_ensure \
    || fail "container_ensure refused a spaced [[ agents ]] header with an unspaced name assignment"

  # A '#' INSIDE the quoted value is a literal, not a comment start.
  printf 'fm#shell\n' > "$FM_CONFIG_OVERRIDE/thurbox-agent"
  printf 'config_version = 1\n[[agents]]\nname = "fm#shell"\ncommand = "bash"\n' > "$TMP_ROOT/agents.toml"
  fm_backend_thurbox_container_ensure \
    || fail "container_ensure treated a '#' inside the quoted agent name as a comment"

  # ...and a comment must still not smuggle in a name that is not defined.
  printf 'shell\n' > "$FM_CONFIG_OVERRIDE/thurbox-agent"
  printf 'config_version = 1\n[[agents]]\nname = "other" # shell\ncommand = "bash"\n' > "$TMP_ROOT/agents.toml"
  local rc
  fm_backend_thurbox_container_ensure >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "container_ensure matched an agent named only inside a comment"
  rm -f "$FM_CONFIG_OVERRIDE/thurbox-agent"
  pass "the agents.toml scan handles TOML whitespace, quoting, and comment boundaries"
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

test_create_task_refuses_when_the_duplicate_check_cannot_run() {
  reset_world
  # thurbox is reachable enough to be invoked but cannot answer - a locked
  # database, a mid-upgrade daemon. An empty list is then absence of EVIDENCE,
  # never evidence of absence: thurbox enforces no name uniqueness itself
  # (finding 2), so creating anyway is what puts two live sessions behind one
  # scoped title and makes first-match lookup pick an arbitrary one.
  export FM_TB_LIST_EXIT=1
  local out rc
  out=$(fm_backend_thurbox_create_task fm-t1 /w 2>&1); rc=$?
  expect_code 1 "$rc" "create_task when the duplicate check itself failed"
  case "$out" in
    *"could not list thurbox sessions"*) : ;;
    *) fail "create_task did not explain the unprovable duplicate check: $out" ;;
  esac
  grep -q $'session\x1fcreate' "$FM_TB_LOG" \
    && fail "create_task created a session despite an unprovable duplicate check"
  pass "create_task refuses when the duplicate check could not be answered"
}

test_create_task_rolls_back_a_session_that_never_gets_a_pane() {
  reset_world
  # thurbox creates the row but never publishes a backend_id, so the bounded
  # poll times out. The row still holds the scoped title, so leaving it behind
  # would trip create_task's OWN duplicate refusal on every later spawn of this
  # task id - a permanent, operator-only-recoverable wedge for one timeout.
  export FM_TB_CREATE_UUID=$UUID FM_TB_CREATE_PANE=-
  local out rc
  out=$(fm_backend_thurbox_create_task fm-t1 /w 2>&1); rc=$?
  expect_code 1 "$rc" "create_task when no pane is ever reported"
  assert_grep $'session\x1fdelete\x1f'"$UUID" "$FM_TB_LOG" \
    "create_task did not roll back the session it created"
  grep -q "	$TITLE	" "$FM_TB_ROWS" \
    && fail "create_task left '$TITLE' behind, reserving the name against every retry"
  # The name being free again is the whole point of the rollback.
  export FM_TB_CREATE_PANE=%31
  export FM_TB_PANES="%20 %31"
  out=$(fm_backend_thurbox_create_task fm-t1 /w) || fail "retry after rollback failed"
  [ "$out" = "$UUID %31" ] || fail "retry returned '$out', expected '$UUID %31'"
  pass "create_task rolls back a paneless session so the task id stays spawnable"
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

# Cursor Agent CLI's real screen shape: a bare composer row carrying its U+2192
# glyph, two footer rows below it, and the terminal cursor parked on a blank
# row PAST the footer - so the cursor row is not a composer locator and the
# cursor-anchored read can only ever answer unknown. An idle composer draws its
# placeholder de-emphasised (SGR 2), which is what separates it from real typed
# text once the capture preserves styling.
tb_cursor_screen() {  # <composer-text> <ghost 0|1>
  local text=$1 ghost=$2 open='' close=''
  if [ "$ghost" = 1 ]; then open=$(printf '\033[2m'); close=$(printf '\033[0m'); fi
  printf '\n  \xe2\x86\x92 %s%s%s\n\n  Cursor Grok 4.5 High                    Run Everything\n  /w \xc2\xb7 main\n\n' \
    "$open" "$text" "$close" > "$FM_TB_SCREEN"
  export FM_TB_CURSOR_Y=6
  export FM_TB_PANE_TTY=/dev/pts/9
}

tb_pane_process() {  # <comm> <args>
  printf 'pts/9\t4242\t4242\t4242\t%s\t%s\n' "$1" "$2" > "$TMP_ROOT/ps.tsv"
  export FM_TB_PS="$TMP_ROOT/ps.tsv"
}

test_composer_state_reclassifies_a_cursor_pane() {
  reset_world
  # A pane id no other case uses, and one the recorded target deliberately
  # disagrees with: the reclassification must act on the pane the adapter
  # RE-RESOLVES from the session row in this very call, never on one left in
  # the shell by an earlier case or by the caller.
  add_row "$UUID" "$TITLE" "%40" local-tmux -
  export FM_TB_PANES="%40"
  tb_cursor_screen 'Plan, search, build anything' 1
  tb_pane_process cursor-agent /opt/cursor/cursor-agent
  [ "$(fm_backend_thurbox_composer_state "$UUID:%20" fm-t1)" = empty ] \
    || fail "an idle Cursor composer on thurbox must read empty; otherwise every steer to a Cursor task reports unverified forever"
  # The pane tty MUST be read off thurbox's own socket, never the ambient
  # default server, or the probe would answer about an unrelated pane.
  grep -q $'tmux\x1f-L\x1fthurbox\x1fdisplay-message\x1f-p\x1f-t\x1f%40\x1f#{pane_tty}' "$FM_TB_TMUXLOG" \
    || fail "the Cursor probe did not read #{pane_tty} for the re-resolved pane through thurbox's socket"

  tb_cursor_screen 'half typed captain text' 0
  [ "$(fm_backend_thurbox_composer_state "$UUID:%20" fm-t1)" = pending ] \
    || fail "real unsubmitted text in a Cursor composer must still read pending, never empty"
  pass "composer_state reclassifies a Cursor pane cursorlessly, on thurbox's own socket"
}

test_composer_state_does_not_reclassify_a_non_cursor_pane() {
  reset_world
  add_row "$UUID" "$TITLE" "%40" local-tmux -
  export FM_TB_PANES="%40"
  # The SAME rendered screen, with only the foreground process identity
  # changed: the reclassification is gated on Cursor's own structural process
  # identity, so the strict blank-row posture stays in force everywhere else.
  tb_cursor_screen 'Plan, search, build anything' 1
  tb_pane_process notcursor /opt/other/notcursor
  [ "$(fm_backend_thurbox_composer_state "$UUID:%20" fm-t1)" = unknown ] \
    || fail "a non-Cursor pane must keep the strict cursor-anchored verdict"

  # A Cursor agent that exited leaves its rendered composer on screen while the
  # foreground process becomes a plain shell. Typing there would run the text
  # as a shell command, so it must never read empty.
  tb_pane_process bash /bin/bash
  [ "$(fm_backend_thurbox_composer_state "$UUID:%20" fm-t1)" != empty ] \
    || fail "a dead-shell pane still showing Cursor's composer must never read empty"
  pass "composer_state leaves a non-Cursor pane's verdict untouched"
}

# A composer that keeps the typed text on the row the cursor is on: the
# cursor-anchored read proves PENDING, which is the only verdict the shared
# queued-Enter policy will convert. The text never clears, so every retry
# re-reads pending and the budget is spent - the mid-turn queued-Enter shape.
tb_pending_composer() {  # <composer-text>
  printf '\n  \xe2\x86\x92 %s\n\n  Claude Sonnet 4.5                       Run Everything\n  /w \xc2\xb7 main\n\n' "$1" > "$FM_TB_SCREEN"
  export FM_TB_CURSOR_Y=1
}

test_send_text_submit_converts_a_queued_enter_on_native_busy() {
  reset_world
  add_row "$UUID" "$TITLE" "%40" local-tmux working
  export FM_TB_PANES="%40"
  # The composer keeps the text on every read - a mid-turn harness QUEUES the
  # Enter rather than consuming it - so the retry budget is spent on a proven
  # pending. thurbox's native hook_state says the agent is working, which is
  # what converts that to a delivered verdict instead of reporting an unproven
  # submit for a steer that will land when the turn ends.
  tb_pending_composer 'hello captain'
  [ "$(fm_backend_thurbox_send_text_submit "$UUID:%20" 'hello captain' 2 0.01 0.01 fm-t1)" = empty ] \
    || fail "a proven pending composer plus hook_state=working must report delivered"
  pass "send_text_submit converts a queued Enter when thurbox's native state says working"
}

test_send_text_submit_never_converts_without_affirmative_busy() {
  local hook
  # Only an affirmative busy may convert. A null hook_state (no agent has
  # signalled yet) reads unknown, and idle/done/blocked read idle; none of
  # them is proof that the Enter was queued rather than swallowed.
  for hook in - idle 'done' blocked; do
    reset_world
    add_row "$UUID" "$TITLE" "%40" local-tmux "$hook"
    export FM_TB_PANES="%40"
    tb_pending_composer 'hello captain'
    [ "$(fm_backend_thurbox_send_text_submit "$UUID:%20" 'hello captain' 2 0.01 0.01 fm-t1)" = pending ] \
      || fail "hook_state '$hook' must not convert a pending composer to delivered"
  done
  pass "send_text_submit refuses to convert a pending composer without an affirmative native busy"
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

test_kill_reclaims_the_row_when_the_window_is_already_gone() {
  reset_world
  add_row "$UUID" "$TITLE" "%20" local-tmux -
  # The window is gone but the database row survives - what an operator
  # exiting the shell, or thurbox's tmux server restarting, leaves behind, and
  # also what the non-forced delete's soft-delete produces. The row and its
  # NAME stay reserved until something deletes them, so a kill that no-ops
  # here makes the next spawn of this task id fail forever on create's
  # duplicate refusal.
  export FM_TB_PANES=""
  fm_backend_thurbox_kill "$UUID:%20" '' fm-t1
  assert_grep $'session\x1fdelete' "$FM_TB_LOG" \
    "kill left the session row behind because its pane was already gone"
  [ -z "$(fm_backend_thurbox_session_id_for_label "$TITLE")" ] \
    || fail "the session name is still reserved after teardown"
  # And the reclaimed name is immediately reusable.
  export FM_TB_CREATE_PANE="%30"
  export FM_TB_PANES="%30"
  fm_backend_thurbox_create_task fm-t1 /w >/dev/null \
    || fail "respawning the same task id after teardown was refused as a duplicate"
  pass "kill reclaims a session row whose window is already gone"
}

test_kill_still_refuses_a_recycled_uuid_with_no_pane() {
  reset_world
  add_row "$UUID" "fm-$HOMETAG-other" "%20" local-tmux -
  export FM_TB_PANES=""
  fm_backend_thurbox_kill "$UUID:%20" '' fm-t1
  assert_no_grep $'session\x1fdelete' "$FM_TB_LOG" \
    "kill deleted another task's session once pane liveness stopped gating it"
  pass "kill verifies identity from the session row, so a recycled uuid is still refused"
}

test_forced_secondmate_teardown_kills_thurbox_child_with_child_home_tag() {
  reset_world
  # thurbox session names are home-scoped, and kill refuses a row whose name is
  # not the expected task's scoped title. Forced secondmate cleanup runs in the
  # PARENT's process, so without re-scoping to the child home every child name
  # mismatches, kill returns success without acting, and the child's session row
  # and its live window both survive the teardown with nothing printed.
  local dir state data config home project child_uuid child_title out status
  dir="$TMP_ROOT/teardown-secondmate-child-$RANDOM"
  state="$dir/state"; data="$dir/data"; config="$dir/config"
  home="$dir/secondmate-home"; project="$dir/project"
  mkdir -p "$state" "$data" "$config" "$home/state" "$home/data" "$home/config" "$project"
  printf 'smt\n' > "$home/.fm-secondmate-home"
  child_uuid=99999999-9999-9999-9999-999999999999
  child_title=$(FM_HOME=$home FM_ROOT=$home fm_backend_thurbox_scoped_title fm-childt)

  fm_write_meta "$state/smt.meta" \
    "window=$UUID:%50" \
    "endpoint_task_id=smt" \
    "backend=thurbox" \
    "thurbox_session_id=$UUID" \
    "thurbox_pane_id=%50" \
    "worktree=$home" \
    "project=$home" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home"
  fm_write_meta "$home/state/childt.meta" \
    "window=$child_uuid:%51" \
    "endpoint_task_id=childt" \
    "backend=thurbox" \
    "thurbox_session_id=$child_uuid" \
    "thurbox_pane_id=%51" \
    "worktree=$dir/missing-child-worktree" \
    "project=$project" \
    "kind=scout"

  add_row "$UUID" "$(FM_HOME=$ROOT FM_ROOT=$ROOT fm_backend_thurbox_scoped_title fm-smt)" "%50" local-tmux -
  add_row "$child_uuid" "$child_title" "%51" local-tmux -
  export FM_TB_PANES="%50 %51"

  out=$( FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-teardown.sh" smt --force 2>&1 ); status=$?
  expect_code 0 "$status" "fm-teardown should force-retire a secondmate with a thurbox child: $out"
  assert_grep $'session\x1fdelete\x1f'"$child_uuid" "$FM_TB_LOG" \
    "forced secondmate teardown left the child thurbox session row behind"
  [ -z "$(fm_backend_thurbox_session_id_for_label "$child_title")" ] \
    || fail "the child home's session name is still reserved after forced teardown"
  pass "forced secondmate teardown reclaims a thurbox child session under the child home tag"
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

test_safety_guard_refuses_a_real_tmux() {
  # The adapter is a two-CLI adapter: every destructive pane primitive runs the
  # ambient tmux from PATH against thurbox's REAL socket. A case that narrowed
  # or reset PATH would send keys to a live pane on the operator's own thurbox
  # server, so the guard must fail closed over that CLI too.
  local out rc bare="$TMP_ROOT/no-tmux"
  mkdir -p "$bare"
  out=$(PATH="$bare" thurbox_refuse_if_unsafe "$TMP_ROOT" 2>&1); rc=$?
  expect_code 1 "$rc" "safety guard with no tmux resolvable at all"
  out=$(PATH="/usr/bin:/bin" thurbox_refuse_if_unsafe "$TMP_ROOT" 2>&1); rc=$?
  expect_code 1 "$rc" "safety guard against the tmux a reset PATH would resolve"
  assert_contains "$out" "tmux" "guard must name which CLI it refused"
  thurbox_refuse_if_unsafe "$TMP_ROOT" \
    || fail "the guard refused the suite's own fixture tmux"
  pass "safety guard fails closed over the tmux the adapter would actually run"
}

# ============================================================================
# away-mode captain-pane resolution
# ============================================================================

test_supervisor_backend_names_thurbox_for_a_thurbox_hosted_captain() {
  reset_world
  local got
  # A thurbox pane IS a tmux pane, so $TMUX_PANE is set here too. Answering
  # tmux would make both away-mode callers run BARE tmux primitives on the
  # DEFAULT server against a pane id that only exists on thurbox's - either a
  # confusing failure or, worse, injections typed into an unrelated pane of
  # the operator's own server. Naming thurbox is what makes the daemon's
  # unsupported-backend refusal and fm-afk-launch.sh's create refusal fire.
  got=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='%31' TMUX="/tmp/tmux-1000/thurbox,123,0" \
    THURBOX_SESSION="$UUID" discover_supervisor_backend)
  [ "$got" = thurbox ] || fail "a thurbox-hosted captain resolved to '$got', so the refusal never fires"
  pass "discover_supervisor_backend names thurbox for a thurbox-hosted captain"
}

test_supervisor_backend_yields_to_tmux_for_a_nested_server() {
  reset_world
  local got
  got=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='%31' TMUX="/tmp/tmux-1000/default,123,0" \
    THURBOX_SESSION="$UUID" discover_supervisor_backend)
  [ "$got" = tmux ] || fail "a nested tmux inside a thurbox pane resolved to '$got', expected tmux"
  got=$(FM_SUPERVISOR_BACKEND=herdr TMUX_PANE='%31' TMUX="/tmp/tmux-1000/thurbox,123,0" \
    THURBOX_SESSION="$UUID" discover_supervisor_backend)
  [ "$got" = herdr ] || fail "the explicit FM_SUPERVISOR_BACKEND override lost to thurbox detection"
  pass "supervisor discovery keeps tmux for a nested server and honors the explicit override"
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
test_container_ensure_refuses_a_name_outside_an_agents_table
test_container_ensure_matches_the_agent_name_literally
test_container_ensure_accepts_a_commented_agents_toml
test_container_ensure_reads_toml_shape_variants
test_configured_agent_name_is_honored
test_create_task_returns_uuid_and_polled_pane
test_create_task_refuses_duplicate_name
test_create_task_passes_configured_agent
test_create_task_refuses_when_the_duplicate_check_cannot_run
test_create_task_rolls_back_a_session_that_never_gets_a_pane
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
test_composer_state_reclassifies_a_cursor_pane
test_composer_state_does_not_reclassify_a_non_cursor_pane
test_send_text_submit_converts_a_queued_enter_on_native_busy
test_send_text_submit_never_converts_without_affirmative_busy
test_busy_state_maps_thurbox_hook_state
test_busy_state_unknown_before_first_signal
test_kill_forces_window_reclaim
test_kill_refuses_recycled_uuid
test_kill_reclaims_the_row_when_the_window_is_already_gone
test_kill_still_refuses_a_recycled_uuid_with_no_pane
test_forced_secondmate_teardown_kills_thurbox_child_with_child_home_tag
test_list_live_filters_and_skips_unaddressable
test_backend_is_known_and_spawn_capable
test_endpoint_validation_accepts_consistent_meta
test_endpoint_validation_refuses_inconsistent_meta
test_detect_prefers_thurbox_over_its_own_tmux_socket
test_detect_prefers_tmux_for_nested_server
test_safety_guard_refuses_a_real_cli
test_safety_guard_refuses_a_real_tmux
test_supervisor_backend_names_thurbox_for_a_thurbox_hosted_captain
test_supervisor_backend_yields_to_tmux_for_a_nested_server
