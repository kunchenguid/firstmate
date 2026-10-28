#!/usr/bin/env bash
# tests/fm-backend-rex.test.sh - fake-rex-CLI unit tests for the Rex
# session-provider adapter (bin/backends/rex.sh), whose real-CLI behavior is
# recorded in docs/verification/runtime-backends.md#rex. The fake `rex` is
# STATEFUL rather than a canned response queue: it keeps a small server model
# (sessions > windows > blocks) in a JSON file, so placement, cleanup, and
# absence proofs are asserted against the resulting server state, not against
# call counts. It mirrors the real CLI's verified exit codes (2 bad command
# line, 3 not found, 4 unreachable) and its "a stopped server forgets every
# session" behavior. Real `jq` is used (a required tool for this backend). The
# real-server smoke test lives in tests/fm-backend-rex-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the rex adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-rex-tests)

# A pid that no live process carries, so the shared agent classifier's live
# pid probe never reads a real process.
DEAD_PID=99999999

# make_rex_fake: a stateful fake `rex` at <dir>/bin/rex. Every invocation is
# logged as one space-joined line to <dir>/fake/log. Marker files under
# <dir>/fake steer failure modes: `unreachable` (every call exits 4), `down`
# (a stopped server: --autostart=false reads exit 4, any other call starts a
# fresh server with no sessions), `ls-fail`, `close-noop` (a close that leaves
# the block alive). Per-block canned reads live in fake/process/<uuid>.json,
# fake/status/<uuid>.json, fake/capture/<uuid>.txt and fake/capture/<uuid>.vt.
# `do` stands in for the bounded event reader: it prints "@subscribed", then
# replays fake/events (a `sleep N` line pauses), and exits 0; `do-fail` makes
# it exit 3 before subscribing.
make_rex_fake() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/fake/process" "$dir/fake/status" "$dir/fake/capture" "$dir/fake/cursor" "$dir/home/state"
  cat >"$dir/bin/rex" <<'SH'
#!/usr/bin/env bash
D="${FM_REX_FAKE_DIR:?}"
S="$D/state.json"
[ -f "$S" ] || printf '{"sessions":[]}' >"$S"
{ printf 'rex'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$D/log"
autostart=1
while [ $# -gt 0 ]; do
  case "$1" in
    --autostart=false) autostart=0; shift ;;
    --*) shift ;;
    *) break ;;
  esac
done
if [ -f "$D/unreachable" ]; then echo "error: could not connect to the rex server" >&2; exit 4; fi
if [ -f "$D/down" ]; then
  if [ "$autostart" = 0 ]; then echo "error: could not connect to the rex server" >&2; exit 4; fi
  rm -f "$D/down"
  printf '{"sessions":[]}' >"$S"
fi
newid() {
  local n
  n=$(( $(cat "$D/.n" 2>/dev/null || echo 0) + 1 ))
  echo "$n" >"$D/.n"
  printf '%s:%08x-0000-7000-8000-%012x' "$1" "$n" "$n"
}
save() { jq "$@" "$S" >"$S.tmp" && mv "$S.tmp" "$S"; }
notfound() { echo "error: $1 not found" >&2; exit 3; }
has_session() { jq -e --arg s "$1" 'any(.sessions[]; .session_id == $s)' "$S" >/dev/null; }
has_block() {
  jq -e --arg s "$1" --arg b "$2" \
    'any(.sessions[] | select(.session_id == $s) | .windows[].blocks[]; .block_id == $b)' "$S" >/dev/null
}
cmd=${1:-}; shift
sub=
case "$cmd" in window|block|api) sub=${1:-}; shift ;; esac
sid=; bid=; fmt=text; wlabel=; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s) sid=$2; shift 2 ;;
    -b) bid=$2; shift 2 ;;
    --format=*) fmt=${1#--format=}; shift ;;
    --window) wlabel=$2; shift 2 ;;
    --cwd) shift 2 ;;
    --) shift; pos+=("$@"); break ;;
    --*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
p0=${pos[0]:-}; p1=${pos[1]:-}
case "$cmd:$sub" in
  version:)
    printf 'rex 0.0.1-fake\napi: revision %s\n' "${FM_REX_FAKE_API:-5}" ;;
  whoami:)
    printf '{"endpoint":"%s"}\n' "${FM_REX_FAKE_ENDPOINT:-unix:///fake/rex.sock}" ;;
  ls:)
    [ ! -f "$D/ls-fail" ] || exit 1
    jq -c '{sessions: [.sessions[] | {session_id, label}]}' "$S" ;;
  api:call)
    case "$p0" in
      server.status) printf '{"api_revision":%s}\n' "${FM_REX_FAKE_SERVER_API:-5}" ;;
      session.view)
        has_session "$sid" || notfound "session"
        jq -c --arg s "$sid" '.sessions[] | select(.session_id == $s)
          | if ((.windows // []) | length) == 0 then {session_id, label}
            else {session_id, label, windows: [.windows[] | {window_id, label,
              layers: [{blocks: [.blocks[] | {block_id, label}]}]}]} end' "$S" ;;
      *) exit 2 ;;
    esac ;;
  new:)
    s=$(newid session); w=$(newid window); b=$(newid block)
    save --arg s "$s" --arg w "$w" --arg b "$b" --arg l "$p0" --arg wl "$wlabel" \
      '.sessions += [{session_id: $s, label: $l, windows: [{window_id: $w, label: $wl,
        blocks: [{block_id: $b, label: "shell", columns: 80, rows: 24}]}]}]'
    printf '{"session_id":"%s","initial_windows":[{"window_id":"%s","block_ids":["%s"]}]}\n' "$s" "$w" "$b" ;;
  window:new)
    has_session "$sid" || notfound "session"
    w=$(newid window); b=$(newid block)
    save --arg s "$sid" --arg w "$w" --arg b "$b" --arg l "$p0" \
      '(.sessions[] | select(.session_id == $s) | .windows) += [{window_id: $w, label: $l,
        blocks: [{block_id: $b, label: "shell", columns: 80, rows: 24}]}]'
    printf '{"window_id":"%s","block_ids":["%s"]}\n' "$w" "$b" ;;
  block:rename)
    has_block "$sid" "$p0" || notfound "block"
    save --arg s "$sid" --arg b "$p0" --arg l "$p1" \
      '(.sessions[] | select(.session_id == $s) | .windows[].blocks[] | select(.block_id == $b) | .label) = $l' ;;
  block:close)
    has_block "$sid" "$p0" || notfound "block"
    [ ! -f "$D/close-noop" ] || exit 0
    save --arg s "$sid" --arg b "$p0" \
      '(.sessions[] | select(.session_id == $s) | .windows) |= ([.[] | .blocks |= map(select(.block_id != $b))]
        | map(select(.blocks | length > 0)))' ;;
  block:call)
    has_block "$sid" "$bid" || notfound "block"
    u=${bid#block:}
    case "$p0" in
      size)
        jq -c --arg s "$sid" --arg b "$bid" '.sessions[] | select(.session_id == $s) | .windows[].blocks[]
          | select(.block_id == $b) | {columns, rows, owner: null}' "$S" ;;
      resize)
        save --arg s "$sid" --arg b "$bid" --argjson r "$p1" \
          '(.sessions[] | select(.session_id == $s) | .windows[].blocks[] | select(.block_id == $b))
            |= (.columns = $r.columns | .rows = $r.rows)' ;;
      process)
        if [ -f "$D/process/$u.json" ]; then cat "$D/process/$u.json"; else
          printf '{"foreground":{"pid":%s,"name":"zsh","path":"/bin/zsh","argv0":"-zsh","cwd":"/tmp"},"ancestors":[],"last_exit":null}\n' "${FM_REX_FAKE_DEAD_PID:-99999999}"
        fi ;;
      program_status)
        if [ -f "$D/status/$u.json" ]; then cat "$D/status/$u.json"; else printf '{"records":[]}\n'; fi ;;
      format)
        # The styled grid without the newline `capture` adds when the grid
        # does not already end in one, then the cursor from fake/cursor/<uuid>
        # ("<row>;<col>") when extra_cursor is asked for.
        content=$(cat "$D/capture/$u.vt" 2>/dev/null && printf x); content=${content%x}
        case "$content" in *$'\r\n') ;; *$'\n') content=${content%$'\n'} ;; esac
        case "$p1" in
          *extra_cursor*) [ ! -f "$D/cursor/$u" ] || content="$content"$'\033['"$(cat "$D/cursor/$u")H" ;;
        esac
        printf '%s' "$content" | jq -Rs '{content: .}' ;;
      *) exit 2 ;;
    esac ;;
  capture:)
    has_block "$sid" "$bid" || notfound "block"
    u=${bid#block:}
    if [ "$fmt" = vt ]; then cat "$D/capture/$u.vt" 2>/dev/null; else cat "$D/capture/$u.txt" 2>/dev/null; fi ;;
  send:)
    has_block "$sid" "$bid" || notfound "block"
    [ -n "$p0" ] || exit 2
    printf '%s\n' "$p0" >>"$D/sent" ;;
  send-key:)
    has_block "$sid" "$bid" || notfound "block"
    case "$p0" in enter|escape|tab|ctrl+c|ctrl+u) ;; *) exit 2 ;; esac
    printf '%s\n' "$p0" >>"$D/keys" ;;
  do:)
    has_session "$sid" || notfound "session"
    [ ! -f "$D/do-fail" ] || exit 3
    echo "@subscribed"
    if [ -f "$D/events" ]; then
      while IFS= read -r line; do
        case "$line" in
          "sleep "*) sleep "${line#sleep }" ;;
          *) printf '%s\n' "$line" ;;
        esac
      done <"$D/events"
    fi ;;
  kill:)
    has_session "$p0" || notfound "session"
    save --arg s "$p0" '.sessions |= map(select(.session_id != $s))' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/bin/rex"
}

# rex_env: run a bash snippet with the adapter loaded through the dispatcher,
# the fake CLI on REX_BIN_DIR, and an isolated home. Extra VAR=value words
# before the snippet are exported first.
rex_env() {  # <dir> [VAR=value...] <snippet>
  local dir=$1
  shift
  (
    unset TERM_PROGRAM REX_SESSION REX_BLOCK REX_SERVER
    export FM_REX_FAKE_DIR="$dir/fake" REX_BIN_DIR="$dir/bin" FM_HOME="$dir/home" \
      STATE="$dir/home/state" FM_REX_FAKE_DEAD_PID="$DEAD_PID" \
      FM_BACKEND_REX_BUNDLE_BIN="$dir/no-bundle/rex"
    while [ $# -gt 1 ]; do
      export "${1?}"
      shift
    done
    bash -c '. "$0/bin/fm-backend.sh" && fm_backend_source rex && eval "$1"' "$ROOT" "$1"
  )
}

# fake_rex: drive the fake directly (test setup and server-state reads).
fake_rex() {  # <dir> <rex-args...>
  local dir=$1
  shift
  FM_REX_FAKE_DIR="$dir/fake" "$dir/bin/rex" "$@"
}

new_case() {  # <name> -> echoes a fresh case dir with the fake installed
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  make_rex_fake "$dir"
  printf '%s' "$dir"
}

state_json() {  # <dir> <jq-filter>
  jq -r "$2" "$1/fake/state.json"
}

home_label() {  # <dir>
  rex_env "$1" 'fm_backend_rex_home_label'
}

# Every call that names a session-scoped object must carry an explicit -s.
assert_scoped_calls() {  # <dir> <msg>
  local bad
  bad=$(grep -E '^rex( --autostart=false)? (window new|block |capture|send|send-key)' "$1/fake/log" | grep -v -- ' -s ' || true)
  [ -z "$bad" ] || fail "$2: unscoped call(s):"$'\n'"$bad"
}

# --- tool resolution and version gate ----------------------------------------

test_bin_prefers_rex_bin_dir() {
  local dir out
  dir=$(new_case bin-order)
  mkdir -p "$dir/path-bin"
  printf '#!/bin/sh\nexit 0\n' >"$dir/path-bin/rex"; chmod +x "$dir/path-bin/rex"
  out=$(rex_env "$dir" "PATH=$dir/path-bin:$PATH" 'fm_backend_rex_bin')
  assert_equals "$dir/bin/rex" "$out" "REX_BIN_DIR/rex must win over a rex on PATH"
  out=$(rex_env "$dir" "PATH=$dir/path-bin:$PATH" 'unset REX_BIN_DIR; fm_backend_rex_bin')
  assert_equals "$dir/path-bin/rex" "$out" "PATH is the fallback when REX_BIN_DIR is unset"
  out=$(rex_env "$dir" "FM_BACKEND_REX_BUNDLE_BIN=$dir/bin/rex" 'unset REX_BIN_DIR; PATH=/usr/bin:/bin; fm_backend_rex_bin')
  assert_equals "$dir/bin/rex" "$out" "the server bundle path is the last fallback"
  pass "fm_backend_rex_bin: REX_BIN_DIR, then PATH, then the server bundle path"
}

test_rex_spawn_refuses_unproven_remote_endpoint() {
  local dir out
  dir=$(new_case remote-endpoint)
  out=$(rex_env "$dir" FM_REX_FAKE_ENDPOINT=tcp://rex-linux.example:8723 \
    'fm_backend_rex_local_server_ensure' 2>&1) && fail "a non-locality-proving Rex endpoint must be refused"
  assert_contains "$out" "tcp://rex-linux.example:8723" "the refusal must name the endpoint"
  assert_contains "$out" "Rex workers need a Rex server on this machine" "the refusal must explain the same-machine requirement"
  assert_contains "$out" "remote second mates" "the refusal must point to remote second mates"
  assert_no_grep 'rex (new|window new)' "$dir/fake/log" "the locality refusal must happen before any tab or session is created"
  rex_env "$dir" 'fm_backend_rex_local_server_ensure' || fail "a local Unix-socket server must pass the locality check"
  pass "Rex spawn refuses an endpoint whose server locality is unproven before creating sessions or tabs"
}

test_version_check_gates_api_revision() {
  local dir out
  dir=$(new_case version)
  rex_env "$dir" 'fm_backend_rex_version_check' || fail "version_check must accept API revision 5"
  out=$(rex_env "$dir" FM_REX_FAKE_API=4 'fm_backend_rex_version_check' 2>&1) \
    && fail "version_check must refuse a CLI at API revision 4"
  assert_contains "$out" "revision 4" "the CLI refusal must name the revision"
  out=$(rex_env "$dir" FM_REX_FAKE_SERVER_API=4 'fm_backend_rex_version_check' 2>&1) \
    && fail "version_check must refuse a server at API revision 4"
  assert_contains "$out" "server speaks API revision 4" "the server refusal must name the server revision"
  out=$(rex_env "$dir" 'unset REX_BIN_DIR; PATH=/usr/bin:/bin; fm_backend_rex_version_check' 2>&1) \
    && fail "version_check must refuse when no rex CLI exists"
  assert_contains "$out" "was not found" "a missing CLI must be reported"
  pass "fm_backend_rex_version_check: accepts API revision 5 and refuses an older CLI, older server, or missing CLI"
}

# shellcheck disable=SC2016 # the snippet expands inside the adapter's shell
test_parse_target_restores_prefixes() {
  local dir out
  dir=$(new_case parse)
  out=$(rex_env "$dir" 'fm_backend_rex_parse_target "01a1-aa:02b2-bb" && printf "%s %s" "$FM_BACKEND_REX_SESSION" "$FM_BACKEND_REX_BLOCK"')
  assert_equals "session:01a1-aa block:02b2-bb" "$out" "parse_target must restore both prefixes"
  rex_env "$dir" 'fm_backend_rex_parse_target "session:01a1-aa:02b2-bb"' && fail "a prefixed target must be refused"
  rex_env "$dir" 'fm_backend_rex_parse_target "01a1"' && fail "a target without a block must be refused"
  rex_env "$dir" 'fm_backend_rex_parse_target "01A1-ZZ:02b2"' && fail "a non-uuid session must be refused"
  pass "fm_backend_rex_parse_target: <session-uuid>:<block-uuid> only, prefixes restored"
}

# --- placement ---------------------------------------------------------------

test_create_task_per_home_session_create_then_adopt() {
  local dir label out1 out2 sid1 sid2 bid1 bid2
  dir=$(new_case per-home)
  label=$(home_label "$dir")
  out1=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp') || fail "first create_task failed"
  out2=$(rex_env "$dir" 'fm_backend_rex_create_task fm-beta /tmp') || fail "second create_task failed"
  read -r sid1 _ bid1 <<<"$out1"
  read -r sid2 _ bid2 <<<"$out2"
  assert_equals "$sid1" "$sid2" "both tasks must share the one per-home session"
  assert_equals 1 "$(state_json "$dir" "[.sessions[] | select(.label == \"$label\")] | length")" \
    "exactly one per-home session must exist"
  assert_equals 2 "$(state_json "$dir" ".sessions[0].windows | length")" "each task must get its own tab"
  assert_equals "fm-alpha fm-beta" "$(state_json "$dir" '[.sessions[0].windows[].label] | join(" ")')" \
    "tabs must carry the task labels"
  assert_equals "fm-$label-alpha" "$(state_json "$dir" ".sessions[0].windows[0].blocks[] | select(.block_id == \"$bid1\") | .label")" \
    "the block must carry the home-scoped label"
  assert_equals "200x50" "$(state_json "$dir" ".sessions[0].windows[1].blocks[] | select(.block_id == \"$bid2\") | \"\(.columns)x\(.rows)\"")" \
    "a new block must be resized to 200x50"
  assert_grep "window new -s $sid1 fm-beta --focus=false" "$dir/fake/log" "a tab must be opened focus-safe in the exact session"
  assert_scoped_calls "$dir" "create_task"
  pass "fm_backend_rex_create_task: one per-home session created once then adopted, one tab per task, scoped block label, 200x50"
}

test_create_task_uses_confirmed_launcher_session() {
  local dir cap capsid capbid out sid
  dir=$(new_case launcher)
  cap=$(fake_rex "$dir" new captain --window main --cwd /tmp --json)
  capsid=$(printf '%s' "$cap" | jq -r .session_id)
  capbid=$(printf '%s' "$cap" | jq -r '.initial_windows[0].block_ids[0]')
  out=$(rex_env "$dir" TERM_PROGRAM=rex "REX_SESSION=$capsid" "REX_BLOCK=$capbid" \
    'fm_backend_rex_create_task fm-alpha /tmp') || fail "create_task in the launcher session failed"
  read -r sid _ _ <<<"$out"
  assert_equals "$capsid" "$sid" "a Rex-hosted launcher must place the tab in its own session"
  assert_equals 1 "$(state_json "$dir" '.sessions | length')" "no per-home session may be created"
  assert_equals main "$(state_json "$dir" '.sessions[0].windows[0].label')" "the captain's tab must be untouched"
  assert_grep "--focus=false" "$dir/fake/log" "the tab must not steal focus"

  rex_env "$dir" TERM_PROGRAM=rex "REX_SESSION=$capsid" "REX_BLOCK=block:00000000-0000-7000-8000-0000000000ff" \
    'fm_backend_rex_create_task fm-beta /tmp' 2>/dev/null && fail "a launcher claim the server cannot confirm must be refused"
  assert_equals 2 "$(state_json "$dir" '.sessions[0].windows | length')" "a refused claim must open no tab"

  out=$(rex_env "$dir" TERM_PROGRAM=tmux "REX_SESSION=$capsid" "REX_BLOCK=$capbid" \
    'fm_backend_rex_create_task fm-gamma /tmp') || fail "create_task from tmux nested in Rex failed"
  read -r sid _ _ <<<"$out"
  assert_not_equals "$capsid" "$sid" "tmux nested in a Rex block must use the per-home session"

  out=$(rex_env "$dir" TERM_PROGRAM=rex "REX_SESSION=$capsid" "REX_BLOCK=$capbid" \
    'fm_backend_rex_create_task fm-delta /tmp other-home') || fail "other-home create_task failed"
  read -r sid _ _ <<<"$out"
  assert_not_equals "$capsid" "$sid" "a secondmate home must use its own per-home session"
  assert_equals 2 "$(state_json "$dir" "[.sessions[] | select(.session_id == \"$capsid\") | .windows[]] | length")" \
    "the captain's session must hold only its own tab and the launcher-home task tab"
  pass "fm_backend_rex_create_task: confirmed launcher session gets the tab focus-safe; unconfirmed claims refuse; nested tmux and other-home use the per-home session"
}

test_create_task_refusals() {
  local dir label sid
  dir=$(new_case refusals)
  label=$(home_label "$dir")
  touch "$dir/fake/ls-fail"
  rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp' 2>/dev/null && fail "an unreadable inventory must refuse"
  assert_no_grep "rex new" "$dir/fake/log" "an unreadable inventory must never create a session"
  rm -f "$dir/fake/ls-fail"

  fake_rex "$dir" new "$label" --window x --cwd /tmp --json >/dev/null
  fake_rex "$dir" new "$label" --window y --cwd /tmp --json >/dev/null
  rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp' 2>/dev/null && fail "two per-home sessions must refuse"
  sid=$(state_json "$dir" '.sessions[1].session_id')
  fake_rex "$dir" kill "$sid"

  rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp' >/dev/null || fail "first create must succeed"
  rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp' 2>/dev/null && fail "a duplicate scoped block label must refuse"
  assert_equals 2 "$(state_json "$dir" '.sessions[0].windows | length')" "a refused duplicate must open no tab"

  rex_env "$dir" 'fm_backend_rex_create_task_in_session session:00000000-0000-7000-8000-0000000000ff fm-x /tmp' 2>/dev/null
  expect_code 2 "$?" "create_task_in_session on a gone session"
  pass "fm_backend_rex_create_task: refuses an unreadable inventory, ambiguous per-home sessions, and duplicates; a gone session returns 2"
}

test_reclaim_replaces_a_husk_and_refuses_a_live_one() {
  local dir out sid bid husk new
  dir=$(new_case reclaim-husk)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp'); read -r sid _ bid <<<"$out"
  out=$(rex_env "$dir" "fm_backend_rex_create_task_in_session '$sid' fm-beta /tmp") || fail "reclaim tab failed"
  read -r _ _ husk <<<"$out"
  out=$(rex_env "$dir" "fm_backend_rex_create_task_in_session '$sid' fm-beta /tmp") || fail "a reclaim over a bare-shell husk must succeed"
  read -r _ _ new <<<"$out"
  assert_equals 0 "$(state_json "$dir" "[.sessions[0].windows[].blocks[] | select(.block_id == \"$husk\")] | length")" \
    "the bare-shell husk must be closed"
  assert_equals 1 "$(state_json "$dir" "[.sessions[0].windows[].blocks[] | select(.label | endswith(\"-beta\"))] | length")" \
    "exactly one block may carry the reclaimed task's label"
  write_process "$dir" "$new" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"claude\"},\"ancestors\":[],\"last_exit\":null}"
  rex_env "$dir" "fm_backend_rex_create_task_in_session '$sid' fm-beta /tmp" 2>/dev/null \
    && fail "a reclaim over a block running a harness must refuse"
  assert_equals 2 "$(state_json "$dir" '.sessions[0].windows | length')" "a refused reclaim must open no tab"
  pass "fm_backend_rex_create_task_in_session: closes a bare-shell husk carrying the task label, refuses over a live one"
}

test_reclaim_fallback_placement_replaces_a_husk() {
  local dir out sid husk new label
  dir=$(new_case reclaim-fallback-husk)
  label=$(home_label "$dir")
  # The recorded session is gone (a server restart), so the reclaim falls back
  # to the ordinary placement; its launch then refuses before republishing,
  # leaving a bare-shell husk there that the retry meets again.
  rex_env "$dir" 'fm_backend_rex_create_task_in_session session:00000000-0000-7000-8000-0000000000ff fm-beta /tmp' 2>/dev/null
  expect_code 2 "$?" "a reclaim into a gone session must fall back"
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-beta /tmp launcher-home reclaim') || fail "first fallback reclaim failed"
  read -r sid _ husk <<<"$out"
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-beta /tmp launcher-home reclaim') \
    || fail "a fallback reclaim over a bare-shell husk must succeed"
  read -r _ _ new <<<"$out"
  assert_not_equals "$husk" "$new" "the retry must open a fresh block"
  assert_equals 0 "$(state_json "$dir" "[.sessions[].windows[].blocks[] | select(.block_id == \"$husk\")] | length")" \
    "the bare-shell husk must be closed"
  assert_equals 1 "$(state_json "$dir" "[.sessions[].windows[].blocks[] | select(.label == \"fm-$label-beta\")] | length")" \
    "exactly one block may carry the reclaimed task's label"
  rex_env "$dir" 'fm_backend_rex_create_task fm-beta /tmp' 2>/dev/null \
    && fail "an ordinary spawn must still refuse a block carrying the task's label"
  write_process "$dir" "$new" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"claude\"},\"ancestors\":[],\"last_exit\":null}"
  rex_env "$dir" 'fm_backend_rex_create_task fm-beta /tmp launcher-home reclaim' 2>/dev/null \
    && fail "a fallback reclaim over a block running a harness must refuse"
  assert_equals 1 "$(state_json "$dir" "[.sessions[] | select(.session_id == \"$sid\") | .windows[]] | length")" \
    "a refused reclaim must open no tab"
  pass "fm_backend_rex_create_task reclaim: the fallback placement closes a bare-shell husk, refuses a live one, and spawn still refuses duplicates"
}

# --- reads -------------------------------------------------------------------

test_capture_and_derived_viewport() {
  local dir out sid bid t u
  dir=$(new_case capture)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"; u=${bid#block:}
  fake_rex "$dir" block call -s "$sid" -b "$bid" resize '{"columns":200,"rows":3}'
  printf 'hist1\r\nhist2\r\nrow1\r\nrow2\r\n' >"$dir/fake/capture/$u.vt"
  out=$(rex_env "$dir" "fm_backend_visible_capture rex '$t' && printf x")
  assert_equals $'row1\nrow2\n\nx' "$out" "a trailing CRLF must restore the implicit empty bottom row"
  printf 'hist1\r\nrow1\r\n\033[2mrow2\033[0m\r\nrow3\n' >"$dir/fake/capture/$u.vt"
  out=$(rex_env "$dir" "fm_backend_visible_capture rex '$t' && printf x")
  assert_equals $'row1\nrow2\nrow3\nx' "$out" "the viewport is the last size.rows rows with styling stripped"
  out=$(rex_env "$dir" "fm_backend_rex_visible_capture_vt '$t'")
  assert_contains "$out" $'\033[2mrow2' "the styled viewport must keep SGR styling"
  printf 'a\r\nb\r\nc\r\n' >"$dir/fake/capture/$u.txt"
  out=$(rex_env "$dir" "fm_backend_capture rex '$t' 2")
  assert_equals $'b\nc' "$out" "capture must strip CR and keep the last N lines"
  rex_env "$dir" "fm_backend_capture rex '${sid#session:}:00000000-0000-7000-8000-0000000000ff' 5" >/dev/null \
    && fail "capture of a missing block must fail"
  pass "rex capture: CR stripped and tailed; viewport derived from the last size.rows styled rows, implicit empty bottom row restored"
}

# The real OpenCode 1.19.3 idle screen read through Rex's `format` method,
# ending in the cursor position Rex appended (row 45 of 50, the composer's
# input row); below the composer OpenCode draws its status line.
REX_OPENCODE_FIXTURE="$ROOT/tests/fixtures/rex-opencode-1.19.3/opencode-1.19.3-idle-format.vt"

test_composer_reads_the_cursor_row() {
  local dir out sid bid t u
  dir=$(new_case composer-cursor)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"; u=${bid#block:}
  python3 - "$REX_OPENCODE_FIXTURE" "$dir/fake/capture/$u.vt" <<'PYFIX'
import re, sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(re.sub(rb'\x1b\[\d+;\d+H$', b'', data))
PYFIX
  printf '45;6' >"$dir/fake/cursor/$u"
  assert_equals empty "$(rex_env "$dir" "fm_backend_composer_state rex '$t'")" \
    "an idle OpenCode 1.19.3 composer under the cursor must read empty despite the status line below it"
  assert_equals 44 "$(rex_env "$dir" "fm_backend_rex_screen_read '$t' && printf %s \"\$FM_BACKEND_REX_CURSOR_Y\"")" \
    "the cursor row must be 0-based within the derived viewport"
  rm -f "$dir/fake/cursor/$u"
  out=$(rex_env "$dir" "fm_backend_composer_state rex '$t'")
  [ "$out" != empty ] && [ "$out" != pending ] \
    || fail "the same screen read cursorless must not claim a definite verdict, got $out"
  printf '99;1' >"$dir/fake/cursor/$u"
  assert_equals "$out" "$(rex_env "$dir" "fm_backend_composer_state rex '$t'")" \
    "a cursor outside the viewport must be ignored, falling back to the cursorless read"
  printf '1;1' >"$dir/fake/cursor/$u"
  assert_equals "$out" "$(rex_env "$dir" "fm_backend_composer_state rex '$t'")" \
    "a cursor parked outside any composer must fall back to the cursorless read"
  pass "fm_backend_composer_state rex: the composer holding the cursor decides; a cursor outside any composer falls back to the cursorless read"
}

write_process() {  # <dir> <block-id> <json>
  printf '%s\n' "$3" >"$1/fake/process/${2#block:}.json"
}

test_agent_state_from_process_view() {
  local dir out sid bid t
  dir=$(new_case agent-state)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"
  assert_equals dead "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "a bare shell foreground is dead"
  write_process "$dir" "$bid" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"claude\",\"path\":\"/opt/claude\",\"argv0\":\"claude\",\"cwd\":\"/w\"},\"ancestors\":[],\"last_exit\":null}"
  assert_equals alive "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "a harness foreground is alive"
  write_process "$dir" "$bid" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"less\",\"path\":\"/usr/bin/less\",\"argv0\":\"less\"},\"ancestors\":[{\"pid\":$DEAD_PID,\"name\":\"node\",\"path\":\"/opt/codex/bin/codex\",\"argv0\":\"codex\"}],\"last_exit\":null}"
  assert_equals alive "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "a harness ancestor of a pager is alive"
  write_process "$dir" "$bid" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"vim\",\"path\":\"/usr/bin/vim\",\"argv0\":\"vim\"},\"ancestors\":[],\"last_exit\":null}"
  assert_equals ambiguous "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "a non-shell non-harness foreground is ambiguous"
  write_process "$dir" "$bid" '{"foreground":null,"ancestors":[],"last_exit":{"code":0}}'
  assert_equals dead "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "an exited terminal child is dead"
  write_process "$dir" "$bid" '{"foreground":null,"ancestors":[],"last_exit":null}'
  assert_equals ambiguous "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "a block still starting is ambiguous"
  assert_equals missing "$(rex_env "$dir" "fm_backend_agent_state rex '${sid#session:}:00000000-0000-7000-8000-0000000000ff'")" \
    "a structured not-found is missing"
  touch "$dir/fake/down"
  assert_equals unreadable "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "a stopped server is unreadable"
  assert_present "$dir/fake/down" "a passive read must never start a stopped server"
  rm -f "$dir/fake/down"; touch "$dir/fake/unreachable"
  assert_equals unreadable "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "an unreachable server is unreadable"
  pass "fm_backend_agent_state rex: alive/dead/ambiguous from the process view, missing on not-found, unreadable without starting a server"
}

# start_shell_tree: a real process tree shaped like a pane whose login shell
# launched <leaf> through a wrapper script in its own process group: a root
# shell (TREE_ROOT), a wrapper shell below it, and <leaf> (a stand-in under that
# name, TREE_LEAF) below the wrapper. Its args name <dir>/tree, so the suite's
# fixture reaping also covers it.
start_shell_tree() {  # <dir> <leaf-name>
  local dir=$1 leaf=$2 i=0 standin
  standin=$(fm_agent_standin "$dir/standin") || {
    echo "skip: no long-running stand-in survives a rename, so the shell descendant case cannot run"
    return 1
  }
  mkdir -p "$dir/tree"
  ln -sf "$standin" "$dir/tree/$leaf"
  cat >"$dir/tree/wrapper" <<'SH'
#!/usr/bin/env bash
"$1" "$2"
exit $?
SH
  chmod +x "$dir/tree/wrapper"
  bash -c '"$1" "$2" "$3" & wait' root "$dir/tree/wrapper" "$dir/tree/$leaf" "$FM_TEST_STUB_MAX_BLOCK_SECONDS" >/dev/null 2>&1 &
  TREE_ROOT=$!
  TREE_LEAF=
  while [ -z "$TREE_LEAF" ] && [ "$i" -lt 50 ]; do
    TREE_LEAF=$(ps -axo pid=,args= | awk -v p="$dir/tree/$leaf" '$2 == p { print $1; exit }')
    [ -n "$TREE_LEAF" ] || sleep 0.1
    i=$((i + 1))
  done
  [ -n "$TREE_LEAF" ] || fail "the $leaf fixture process never started"
}

stop_shell_tree() {  # <dir>
  fm_test_reap_root_processes "$1/tree"
}

# shell_foreground_payload: the process view Rex reports for a pane whose
# login shell (fish here, as captured live) is the foreground process with
# treehouse, fish, and login above it.
shell_foreground_payload() {  # <foreground-pid>
  printf '{"foreground":{"pid":%s,"name":"fish","path":"/opt/homebrew/Cellar/fish/4.7.1/bin/fish","argv0":"/opt/homebrew/bin/fish","cwd":"/w"},"ancestors":[{"pid":%s,"name":"treehouse","argv0":"treehouse"},{"pid":%s,"name":"fish","argv0":"-fish"},{"pid":%s,"name":"login","argv0":null}],"last_exit":null}' \
    "$1" "$DEAD_PID" "$DEAD_PID" "$DEAD_PID"
}

test_agent_state_sees_a_harness_below_a_shell_foreground() {
  local dir out sid bid t fakebin real_sleep PATH=$PATH
  dir=$(new_case agent-state-below-shell)
  # Model a multicall sleep on every host, including macOS and GNU coreutils.
  # The real process tree must still start when sleep refuses a foreign name.
  real_sleep=$(command -v sleep) || fail "sleep not found"
  fakebin=$(fm_fakebin "$dir/multicall")
  cat >"$fakebin/sleep" <<SH
#!/usr/bin/env bash
case "\${0##*/}" in
  sleep) exec "$real_sleep" "\$@" ;;
  *) echo "Requested utility \${0##*/} does not match executable name" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/sleep"
  ln -s "$fakebin/sleep" "$dir/multicall/claude"
  "$fakebin/sleep" 0 || fail "the fake multicall sleep must run under its own name"
  if "$dir/multicall/claude" 0 2>/dev/null; then
    fail "the fake multicall sleep must refuse a harness name, or this case proves nothing"
  fi
  export PATH="$fakebin:$PATH"
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"

  start_shell_tree "$dir" claude || return 0
  write_process "$dir" "$bid" "$(shell_foreground_payload "$DEAD_PID")"
  assert_equals dead "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" \
    "the reported chain alone holds no harness, so a foreground shell with no live process below it is dead"
  write_process "$dir" "$bid" "$(shell_foreground_payload "$TREE_ROOT")"
  assert_equals alive "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" \
    "a harness running below the shell foreground, through a wrapper, is alive"
  printf '{"records":[{"state":"working","kind":"agent","owner":{"pid":%s}}]}\n' "$TREE_LEAF" >"$dir/fake/status/${bid#block:}.json"
  assert_equals busy "$(rex_env "$dir" "fm_backend_busy_state rex '$t'")" \
    "an OSC 7501 record from the harness below the shell foreground is trusted"
  stop_shell_tree "$dir"
  rm -f "$dir/fake/status/${bid#block:}.json"

  start_shell_tree "$dir" worker || return 0
  write_process "$dir" "$bid" "$(shell_foreground_payload "$TREE_ROOT")"
  assert_equals dead "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" \
    "a shell foreground with only non-harness processes below it is dead"
  printf '{"records":[{"state":"working","owner":{"pid":%s}}]}\n' "$TREE_LEAF" >"$dir/fake/status/${bid#block:}.json"
  assert_equals unknown "$(rex_env "$dir" "fm_backend_busy_state rex '$t'")" \
    "a record from a non-harness process below the shell foreground is ignored"
  stop_shell_tree "$dir"

  write_process "$dir" "$bid" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"2.1.310\",\"path\":\"/Users/u/.cac/versions/2.1.310/claude\",\"argv0\":\"claude\"},\"ancestors\":[{\"pid\":$DEAD_PID,\"name\":\"zsh\",\"argv0\":\"-zsh\"}],\"last_exit\":null}"
  assert_equals alive "$(rex_env "$dir" "fm_backend_agent_state rex '$t'")" "a harness foreground is still alive"
  pass "fm_backend_agent_state rex: a harness below a shell foreground is alive and its records are trusted; a bare shell stays dead"
}

test_native_busy_trusts_live_owner_only() {
  local dir out sid bid t
  dir=$(new_case busy)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"
  assert_equals unknown "$(rex_env "$dir" "fm_backend_busy_state rex '$t'")" "no record reads unknown"
  write_process "$dir" "$bid" '{"foreground":{"pid":4242,"name":"claude"},"ancestors":[{"pid":4000,"name":"zsh"}],"last_exit":null}'
  printf '{"records":[{"state":"working","kind":"agent","owner":{"pid":4242}}]}\n' >"$dir/fake/status/${bid#block:}.json"
  assert_equals busy "$(rex_env "$dir" "fm_backend_busy_state rex '$t'")" "a working record from the foreground owner reads busy"
  printf '{"records":[{"state":"idle","owner":{"pid":4000}}]}\n' >"$dir/fake/status/${bid#block:}.json"
  assert_equals idle "$(rex_env "$dir" "fm_backend_busy_state rex '$t'")" "an idle record from an ancestor owner reads idle"
  printf '{"records":[{"state":"working","owner":{"pid":777}}]}\n' >"$dir/fake/status/${bid#block:}.json"
  assert_equals unknown "$(rex_env "$dir" "fm_backend_busy_state rex '$t'")" "a record whose owner left the foreground is ignored"
  pass "fm_backend_busy_state rex: OSC 7501 records count only while their owner is the foreground process or an ancestor"
}

test_current_path_follows_foreground() {
  local dir out sid bid
  dir=$(new_case cwd)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  write_process "$dir" "$bid" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"zsh\",\"cwd\":\"/work/tree\"},\"ancestors\":[],\"last_exit\":null}"
  out=$(rex_env "$dir" "fm_backend_rex_current_path '${sid#session:}:${bid#block:}'")
  assert_equals /work/tree "$out" "current_path must read the foreground cwd"
  pass "fm_backend_rex_current_path: the foreground process cwd"
}

# --- input -------------------------------------------------------------------

test_send_literal_and_keys() {
  local dir out sid bid t
  dir=$(new_case input)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"
  rex_env "$dir" "fm_backend_rex_send_literal '$t' '-n dashed'" || fail "an option-shaped literal must send"
  assert_equals "-n dashed" "$(cat "$dir/fake/sent")" "the literal must arrive verbatim"
  : >"$dir/fake/log"
  rex_env "$dir" "fm_backend_rex_send_literal '$t' ''" || fail "empty input must succeed"
  assert_no_grep "send" "$dir/fake/log" "empty input must make no call"
  for k in Enter Escape Tab C-c C-u; do
    rex_env "$dir" "fm_backend_send_key rex '$t' $k" || fail "key $k must send"
  done
  assert_equals "enter escape tab ctrl+c ctrl+u" "$(tr '\n' ' ' <"$dir/fake/keys" | sed 's/ $//')" "keys must map to Rex names"
  : >"$dir/fake/log"
  rex_env "$dir" "fm_backend_send_key rex '$t' F5" 2>/dev/null && fail "an unmapped key must be refused"
  assert_no_grep "send-key" "$dir/fake/log" "an unmapped key must make no call"
  : >"$dir/fake/keys"
  rex_env "$dir" "fm_backend_rex_send_text_line '$t' 'echo hi'" || fail "send_text_line must succeed"
  assert_equals enter "$(cat "$dir/fake/keys")" "send_text_line must submit with Enter"
  assert_scoped_calls "$dir" "input"
  pass "rex input: literal text after --, no call for empty input, verified key names only, line submit"
}

# --- push events -------------------------------------------------------------

# rex_event: one reader line for a status edge on <block-id>.
rex_event() {  # <block-id> <state> <kind> <app> <owner-pid> <msg>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

# push_case: a task tab whose foreground is a harness at pid 4242 under a shell
# at 4000; sets PUSH_DIR, PUSH_SID (bare), PUSH_BID (prefixed), and PUSH_T.
push_case() {  # <name>
  local out sid
  PUSH_DIR=$(new_case "$1")
  out=$(rex_env "$PUSH_DIR" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ PUSH_BID <<<"$out"
  PUSH_SID=${sid#session:}
  PUSH_T="$PUSH_SID:${PUSH_BID#block:}"
  write_process "$PUSH_DIR" "$PUSH_BID" '{"foreground":{"pid":4242,"name":"claude"},"ancestors":[{"pid":4000,"name":"zsh"}],"last_exit":null}'
}

# push_wait: run the dispatcher's wait with <timeout>; prints "<rc>|<record>".
push_wait() {  # <timeout> [VAR=value...]
  local timeout=$1
  shift
  rex_env "$PUSH_DIR" "$@" "out=\$(fm_backend_wait_transition rex '$PUSH_SID' $timeout \"\$STATE\" '$PUSH_T'); printf '%s|%s' \"\$?\" \"\$out\""
}

test_push_capability_gate() {
  local dir
  dir=$(new_case push-cap)
  rex_env "$dir" 'fm_backend_has_push rex' || fail "rex must report a push stream"
  rex_env "$dir" 'fm_backend_events_capable rex abc' || fail "API revision 5 must be events-capable"
  rex_env "$dir" FM_REX_FAKE_SERVER_API=4 'fm_backend_events_capable rex abc' && fail "a server below revision 5 must not be events-capable"
  touch "$dir/fake/down"
  rex_env "$dir" 'fm_backend_events_capable rex abc' && fail "a stopped server must not be events-capable"
  [ -f "$dir/fake/down" ] || fail "the capability probe must never start a server"
  pass "fm_backend_events_capable rex: API revision 5 on both ends, read without starting a server"
}

test_push_blocked_edge_carries_kind_and_message() {
  local res rec
  push_case push-edge
  rex_event "$PUSH_BID" working "" claude-code 4242 "" >"$PUSH_DIR/fake/events"
  rex_event "$PUSH_BID" blocked permission claude-code 4242 "Allow Bash: rm -rf build" >>"$PUSH_DIR/fake/events"
  res=$(push_wait 5)
  [ "${res%%|*}" = 0 ] || fail "a trusted blocked edge must return 0, got $res"
  rec=${res#*|}
  assert_equals "${PUSH_BID#block:}" "$(rex_env "$PUSH_DIR" "fm_transition_pane_id '$rec'")" "pane_id must be the block uuid"
  assert_equals blocked "$(rex_env "$PUSH_DIR" "fm_transition_to_status '$rec'")" "to_status must be blocked"
  assert_equals claude-code "$(rex_env "$PUSH_DIR" "fm_transition_agent '$rec'")" "agent must be Rex's app"
  assert_equals "permission: Allow Bash: rm -rf build" "$(rex_env "$PUSH_DIR" "fm_transition_detail '$rec'")" "detail must carry the kind and message"
  grep -qE "^rex --autostart=false do -s session:$PUSH_SID .*rex-eventwait.lua --args \{\"blocks\":\[\"$PUSH_BID\"\]\}$" "$PUSH_DIR/fake/log" \
    || fail "the reader must run scoped to the recorded session with the watched block, never starting a server:"$'\n'"$(grep ' do ' "$PUSH_DIR/fake/log")"
  pass "fm_backend_wait_transition rex: a trusted blocked edge returns its record with Rex's app, kind, and message"
}

test_push_untrusted_owner_is_ignored() {
  local res
  push_case push-untrusted
  rex_event "$PUSH_BID" blocked question claude-code 777 "stale" >"$PUSH_DIR/fake/events"
  res=$(push_wait 1)
  assert_equals "1|" "$res" "a blocked edge whose owner is not in the foreground chain must be ignored"
  rex_event "$PUSH_BID" blocked question claude-code 4000 "Continue?" >"$PUSH_DIR/fake/events"
  res=$(push_wait 1)
  [ "${res%%|*}" = 0 ] || fail "a blocked edge from an ancestor owner must count, got $res"
  pass "fm_backend_wait_transition rex: a blocked edge counts only while its owner is the foreground process or an ancestor"
}

test_push_level_reconcile_and_dedupe() {
  local res rec
  push_case push-level
  printf '{"records":[{"state":"blocked","kind":"auth","app":"grok-build","msg":"Sign in","owner":{"pid":4242}}]}\n' \
    >"$PUSH_DIR/fake/status/${PUSH_BID#block:}.json"
  res=$(push_wait 1)
  [ "${res%%|*}" = 0 ] || fail "a block already blocked must be returned by the level reconcile, got $res"
  rec=${res#*|}
  assert_equals "auth: Sign in" "$(rex_env "$PUSH_DIR" "fm_transition_detail '$rec'")" "the reconciled record must carry the kind and message"
  rex_env "$PUSH_DIR" "fm_backend_commit_transition rex \"\$STATE\" '$PUSH_SID' '$rec'" || fail "commit failed"
  res=$(push_wait 1)
  assert_equals "1|" "$res" "a committed blocked block must not be re-delivered"
  rex_event "$PUSH_BID" working "" grok-build 4242 "" >"$PUSH_DIR/fake/events"
  rex_event "$PUSH_BID" blocked question grok-build 4242 "Pick one" >>"$PUSH_DIR/fake/events"
  res=$(push_wait 5)
  [ "${res%%|*}" = 0 ] || fail "a working edge must clear the marker so the next blocked edge escalates, got $res"
  rex_env "$PUSH_DIR" "fm_backend_commit_transition rex \"\$STATE\" '$PUSH_SID' '${res#*|}'"
  rex_env "$PUSH_DIR" "fm_backend_clear_transition rex \"\$STATE\" '$PUSH_T'"
  : >"$PUSH_DIR/fake/events"
  res=$(push_wait 1)
  [ "${res%%|*}" = 0 ] || fail "cleanup's clear must let a still-blocked block escalate again, got $res"
  pass "fm_backend_wait_transition rex: level reconcile returns a blocked block once; working and cleanup clear the marker"
}

test_push_gone_edge_ends_the_wait() {
  local res start
  push_case push-gone
  { rex_event "$PUSH_BID" gone "" "" "" "block closed"; echo "sleep 4"; } >"$PUSH_DIR/fake/events"
  start=$SECONDS
  res=$(push_wait 6)
  assert_equals "1|" "$res" "an endpoint-gone edge must end the wait with 1 and no record"
  [ $((SECONDS - start)) -lt 4 ] || fail "an endpoint-gone edge must end the wait at once"
  rex_event "block:00000000-0000-7000-8000-00000000ffff" gone "" "" "" "block closed" >"$PUSH_DIR/fake/events"
  res=$(push_wait 1)
  assert_equals "1|" "$res" "a gone edge for an unwatched block is a plain clean wait"
  pass "fm_backend_wait_transition rex: a watched block's exit or close ends the wait at once for an immediate poll"
}

test_push_reader_failures_fall_back() {
  local res
  push_case push-fail
  touch "$PUSH_DIR/fake/do-fail"
  res=$(push_wait 1)
  assert_equals "2|" "$res" "a reader that cannot subscribe must return 2"
  rm -f "$PUSH_DIR/fake/do-fail"
  res=$(push_wait 5)
  assert_equals "2|" "$res" "a reader that ends well before the deadline must return 2, not a clean wait"
  res=$(rex_env "$PUSH_DIR" "fm_backend_wait_transition rex '$PUSH_SID' 1 \"\$STATE\" 'not-a-target'; echo \$?")
  assert_equals 2 "$res" "no watchable window must return 2"
  res=$(rex_env "$PUSH_DIR" "fm_backend_wait_transition rex '$PUSH_SID' 1 \"\$STATE\" '00000000-0000-7000-8000-00000000aaaa:${PUSH_BID#block:}'; echo \$?")
  assert_equals 2 "$res" "a window in another session must not be watched by this reader"
  pass "fm_backend_wait_transition rex: a reader that cannot start or ends early falls back to polling"
}

# --- cleanup and absence proof ----------------------------------------------

test_kill_closes_and_retires_per_home_session() {
  local dir out sid bid1 bid2
  dir=$(new_case kill)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp'); read -r sid _ bid1 <<<"$out"
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-beta /tmp'); read -r _ _ bid2 <<<"$out"
  rex_env "$dir" "fm_backend_kill rex '${sid#session:}:${bid1#block:}'" || fail "kill of a live block must succeed"
  assert_equals 1 "$(state_json "$dir" '.sessions[0].windows | length')" "kill must close only its own tab"
  rex_env "$dir" "fm_backend_kill rex '${sid#session:}:${bid1#block:}'" || fail "kill of an already-gone block must succeed"
  rex_env "$dir" "fm_backend_kill rex '${sid#session:}:${bid2#block:}'" || fail "kill of the last block must succeed"
  assert_equals 0 "$(state_json "$dir" '.sessions | length')" "the emptied per-home session must be retired"
  pass "fm_backend_kill rex: closes exactly its tab, treats a gone block as done, retires the emptied per-home session"
}

test_kill_never_retires_a_foreign_session() {
  local dir cap capsid capbid out sid bid
  dir=$(new_case kill-foreign)
  cap=$(fake_rex "$dir" new captain --window main --cwd /tmp --json)
  capsid=$(printf '%s' "$cap" | jq -r .session_id)
  capbid=$(printf '%s' "$cap" | jq -r '.initial_windows[0].block_ids[0]')
  out=$(rex_env "$dir" TERM_PROGRAM=rex "REX_SESSION=$capsid" "REX_BLOCK=$capbid" 'fm_backend_rex_create_task fm-alpha /tmp')
  read -r sid _ bid <<<"$out"
  fake_rex "$dir" block close -s "$capsid" "$capbid"
  rex_env "$dir" "fm_backend_kill rex '${sid#session:}:${bid#block:}'" || fail "kill in a foreign session must succeed"
  assert_equals 1 "$(state_json "$dir" '.sessions | length')" "a session not labeled for this home must never be killed, even empty"
  pass "fm_backend_kill rex: never kills a session this home does not own, even when it is empty"
}

test_kill_refuses_without_proof() {
  local dir out sid bid
  dir=$(new_case kill-noop)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp'); read -r sid _ bid <<<"$out"
  touch "$dir/fake/close-noop"
  rex_env "$dir" "fm_backend_kill rex '${sid#session:}:${bid#block:}'" 2>/dev/null && fail "a close that leaves the block alive must fail"
  rm -f "$dir/fake/close-noop"; touch "$dir/fake/unreachable"
  rex_env "$dir" "fm_backend_kill rex '${sid#session:}:${bid#block:}'" 2>/dev/null && fail "an unreachable server must fail the kill"
  pass "fm_backend_kill rex: refuses success unless the block is proven gone"
}

# rex_teardown_meta: record <id> of <kind> on the fake's block in <state-dir>.
rex_teardown_meta() {  # <state-dir> <id> <kind> <home> <session-id> <window-id> <block-id>
  local state=$1 id=$2 kind=$3 home=$4 sid=$5 wid=$6 bid=$7
  {
    echo "window=${sid#session:}:${bid#block:}"
    echo "endpoint_task_id=$id"
    echo "worktree=$home"
    echo "project=$home"
    [ "$kind" != secondmate ] || { echo "home=$home"; echo "mode=secondmate"; echo "projects=alpha"; }
    echo "harness=echo"
    echo "yolo=off"
    echo "kind=$kind"
    echo "backend=rex"
    echo "rex_server=unix:///fake/rex.sock"
    echo "rex_session_id=$sid"
    echo "rex_window_id=$wid"
    echo "rex_block_id=$bid"
  } >"$state/$id.meta"
}

test_teardown_retires_the_secondmate_session() {
  local dir mate out sid wid bid crew_sid crew_wid crew_bid rc
  dir=$(new_case teardown-secondmate)
  mate="$dir/mate"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$dir/home/data" "$dir/home/config"
  printf 'sm' >"$mate/.fm-secondmate-home"
  out=$(rex_env "$dir" "FM_HOME=$mate" "FM_ROOT=$mate" "STATE=$mate/state" \
    'fm_backend_rex_create_task fm-sm /tmp other-home') || fail "secondmate create_task failed"
  read -r sid wid bid <<<"$out"
  out=$(rex_env "$dir" "FM_HOME=$mate" "FM_ROOT=$mate" "STATE=$mate/state" \
    'fm_backend_rex_create_task fm-crew /tmp') || fail "crew create_task failed"
  read -r crew_sid crew_wid crew_bid <<<"$out"
  assert_equals "$sid" "$crew_sid" "the secondmate's crew must share its per-home session"
  rex_teardown_meta "$dir/home/state" sm secondmate "$mate" "$sid" "$wid" "$bid"
  rex_teardown_meta "$mate/state" crew ship "$dir/nonexistent-crew" "$crew_sid" "$crew_wid" "$crew_bid"
  fake_rex "$dir" new other --window keep --cwd /tmp --json >/dev/null

  out=$(env -u TERM_PROGRAM -u REX_SESSION -u REX_BLOCK -u REX_SERVER \
    FM_REX_FAKE_DIR="$dir/fake" REX_BIN_DIR="$dir/bin" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REX_FAKE_DEAD_PID="$DEAD_PID" FM_BACKEND_REX_BUNDLE_BIN="$dir/no-bundle/rex" \
    "$ROOT/bin/fm-teardown.sh" sm --force 2>&1); rc=$?
  expect_code 0 "$rc" "teardown of a rex secondmate must succeed: $out"
  assert_equals 0 "$(state_json "$dir" "[.sessions[] | select(.session_id == \"$sid\")] | length")" \
    "retiring the secondmate must retire its emptied per-home session"
  assert_equals 1 "$(state_json "$dir" '.sessions | length')" "an unrelated session must survive the retirement"
  pass "fm-teardown rex: retiring a secondmate closes its crew and its own tab and retires its per-home session"
}

test_absence_recheck() {
  local dir out sid bid t ep=unix:///fake/rex.sock
  dir=$(new_case absence)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp'); read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"
  assert_equals dead "$(rex_env "$dir" "fm_backend_rex_endpoint_absence_recheck '$t' '$ep'")" "a live shell block is dead"
  assert_equals unproven "$(rex_env "$dir" "fm_backend_rex_endpoint_absence_recheck '$t' ''")" "no recorded server is unproven"
  assert_equals unproven "$(rex_env "$dir" "fm_backend_rex_endpoint_absence_recheck '$t' unix:///other.sock")" \
    "a different server can prove nothing"
  write_process "$dir" "$bid" "{\"foreground\":{\"pid\":$DEAD_PID,\"name\":\"vim\"},\"ancestors\":[],\"last_exit\":null}"
  assert_equals unproven "$(rex_env "$dir" "fm_backend_rex_endpoint_absence_recheck '$t' '$ep'")" "an ambiguous block is unproven"
  fake_rex "$dir" block close -s "$sid" "$bid"
  assert_equals missing "$(rex_env "$dir" "fm_backend_rex_endpoint_absence_recheck '$t' '$ep'")" "a closed block is missing"
  touch "$dir/fake/unreachable"
  assert_equals unproven "$(rex_env "$dir" "fm_backend_rex_endpoint_absence_recheck '$t' '$ep'")" "an unreachable server is unproven"
  rm -f "$dir/fake/unreachable"
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-beta /tmp'); read -r sid _ bid <<<"$out"
  touch "$dir/fake/down"
  assert_equals missing "$(rex_env "$dir" "fm_backend_rex_endpoint_absence_recheck '${sid#session:}:${bid#block:}' '$ep'")" \
    "a stopped server, restarted, proves the block gone"
  pass "fm_backend_rex_endpoint_absence_recheck: proof only from the recorded server; missing/dead/unproven"
}

test_control_absence_verdict_reads_rex_meta() {
  local dir out sid bid t meta
  dir=$(new_case control-absence)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp'); read -r sid _ bid <<<"$out"
  t="${sid#session:}:${bid#block:}"
  meta="$dir/home/state/t.meta"
  printf 'backend=rex\nwindow=%s\nrex_server=unix:///fake/rex.sock\n' "$t" >"$meta"
  fake_rex "$dir" block close -s "$sid" "$bid"
  out=$(rex_env "$dir" ". '$ROOT/bin/fm-control-lib.sh'; fm_control_endpoint_absence_verdict rex '$t' '$meta'")
  assert_equals gone "${out%%$'\t'*}" "a proven-missing block must read gone to the control plane"
  printf 'backend=rex\nwindow=%s\nrex_server=unix:///other.sock\n' "$t" >"$meta"
  out=$(rex_env "$dir" ". '$ROOT/bin/fm-control-lib.sh'; fm_control_endpoint_absence_verdict rex '$t' '$meta'")
  assert_not_equals gone "${out%%$'\t'*}" "a different recorded server must never read gone"
  pass "fm_control_endpoint_absence_verdict rex: gone only on a not-found from the recorded server"
}

# rex_control_task: record task <id> on the fake's block <session-uuid>:<block-uuid>
# with <server> as its rex_server, for driving bin/fm-control.sh.
rex_control_task() {  # <dir> <id> <session-id> <window-id> <block-id> <server>
  local dir=$1 id=$2 sid=$3 wid=$4 bid=$5 server=$6
  mkdir -p "$dir/wt-$id" "$dir/home/data/$id"
  printf '# brief for %s\n' "$id" >"$dir/home/data/$id/brief.md"
  {
    echo "window=${sid#session:}:${bid#block:}"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/wt-$id"
    echo "project=$dir/wt-$id"
    echo "harness=claude"
    echo "kind=ship"
    echo "backend=rex"
    echo "rex_server=$server"
    echo "rex_session_id=$sid"
    echo "rex_window_id=$wid"
    echo "rex_block_id=$bid"
  } >"$dir/home/state/$id.meta"
}

run_rex_control() {  # <dir> <args...>
  local dir=$1
  shift
  env -u TERM_PROGRAM -u REX_SESSION -u REX_BLOCK -u REX_SERVER \
    FM_REX_FAKE_DIR="$dir/fake" REX_BIN_DIR="$dir/bin" FM_HOME="$dir/home" \
    FM_REX_FAKE_DEAD_PID="$DEAD_PID" FM_BACKEND_REX_BUNDLE_BIN="$dir/no-bundle/rex" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.05 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

test_control_exit_after_a_server_stop() {
  local dir out rc sid wid bid ep=unix:///fake/rex.sock
  dir=$(new_case control-exit-stopped)
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-t1 /tmp'); read -r sid wid bid <<<"$out"
  rex_control_task "$dir" t1 "$sid" "$wid" "$bid" "$ep"
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-t2 /tmp'); read -r sid wid bid <<<"$out"
  rex_control_task "$dir" t2 "$sid" "$wid" "$bid" unix:///other.sock

  touch "$dir/fake/unreachable"
  out=$(run_rex_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "a server that cannot be reached or started proves nothing"
  assert_not_contains "$out" "endpoint-gone" "exit must not claim a stop it could not prove"
  rm -f "$dir/fake/unreachable"

  touch "$dir/fake/down"
  out=$(run_rex_control "$dir" t2 exit); rc=$?
  expect_code 1 "$rc" "a stopped server answering for a different recorded server must refuse"
  assert_not_contains "$out" "endpoint-gone" "a different server's not-found proves nothing"

  touch "$dir/fake/down"
  out=$(run_rex_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit after a server stop must reach the absence proof"
  assert_contains "$out" "endpoint-gone t1" "a stopped server's restarted not-found proves the block gone"
  pass "fm-control exit on rex: a stopped server goes through the recorded-server absence proof, and refuses when it cannot prove absence"
}

test_list_live_scopes_to_this_home() {
  local dir out sid bid label
  dir=$(new_case list-live)
  label=$(home_label "$dir")
  out=$(rex_env "$dir" 'fm_backend_rex_create_task fm-alpha /tmp'); read -r sid _ bid <<<"$out"
  fake_rex "$dir" new "other" --window fm-zeta --cwd /tmp --json >/dev/null
  out=$(rex_env "$dir" 'fm_backend_rex_list_live')
  assert_equals "${sid#session:}:${bid#block:}"$'\t'"fm-alpha" "$out" "list_live must list only this home's blocks"
  touch "$dir/fake/unreachable"
  out=$(rex_env "$dir" 'fm_backend_rex_list_live')
  assert_equals "" "$out" "an unreachable server lists nothing"
  [ -n "$label" ] || fail "home label must not be empty"
  pass "fm_backend_rex_list_live: home-scoped blocks only, nothing when unreachable"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

# --- attention marks (opt-in) ---------------------------------------------------

# mark_case: a task tab whose foreground is a harness at pid 4242 under a shell
# at 4000, with `ps -o tty=` faked so the pane's terminal device is the
# regular file $MARK_DIR/dev/ttys999 and every write to it can be read back.
mark_case() {  # <name>
  local out sid
  MARK_DIR=$(new_case "$1")
  out=$(rex_env "$MARK_DIR" 'fm_backend_rex_create_task fm-t1 /tmp')
  read -r sid _ MARK_BID <<<"$out"
  MARK_T="${sid#session:}:${MARK_BID#block:}"
  write_process "$MARK_DIR" "$MARK_BID" '{"foreground":{"pid":4242,"name":"claude"},"ancestors":[{"pid":4000,"name":"zsh"}],"last_exit":null}'
  mkdir -p "$MARK_DIR/psbin" "$MARK_DIR/dev" "$MARK_DIR/home/config"
  cat >"$MARK_DIR/psbin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -o tty= "*) echo ttys999; exit 0 ;; esac
exec /bin/ps "$@"
SH
  chmod +x "$MARK_DIR/psbin/ps"
  : >"$MARK_DIR/dev/ttys999"
  MARK_TTY="$MARK_DIR/dev/ttys999"
}

mark_env() {  # <snippet>
  rex_env "$MARK_DIR" PATH="$MARK_DIR/psbin:$PATH" FM_BACKEND_REX_DEV_DIR="$MARK_DIR/dev" "$1"
}

mark_status() {  # <records-json-array>
  printf '{"records":%s}\n' "$1" >"$MARK_DIR/fake/status/${MARK_BID#block:}.json"
}

# marks_run: run bin/fm-rex-marks.sh against the case's home and fake Rex.
marks_run() {  # <args...>
  env -u TERM_PROGRAM -u REX_SESSION -u REX_BLOCK -u REX_SERVER \
    FM_REX_FAKE_DIR="$MARK_DIR/fake" REX_BIN_DIR="$MARK_DIR/bin" FM_HOME="$MARK_DIR/home" \
    FM_STATE_OVERRIDE="$MARK_DIR/home/state" FM_CONFIG_OVERRIDE="$MARK_DIR/home/config" \
    FM_REX_FAKE_DEAD_PID="$DEAD_PID" FM_BACKEND_REX_BUNDLE_BIN="$MARK_DIR/no-bundle/rex" \
    PATH="$MARK_DIR/psbin:$PATH" FM_BACKEND_REX_DEV_DIR="$MARK_DIR/dev" \
    "$ROOT/bin/fm-rex-marks.sh" "$@"
}

mark_task_status() {  # <line>
  printf '%s\n' "$1" >"$MARK_DIR/home/state/t1.status"
}

test_mark_progress_tint_and_alert_sequences() {
  local want
  mark_case mark-seq
  mark_env "fm_backend_rex_mark '$MARK_T' blocked question 'Needs your decision'" || fail "mark failed"
  want=$(printf '\033]7501;state=blocked:kind=question:app=firstmate:id=fm:msg=%s\033\134' "$(printf 'Needs your decision' | base64)")
  assert_equals "$want" "$(cat "$MARK_TTY")" "a mark must be exactly one OSC 7501 id=fm record"
  : >"$MARK_TTY"
  mark_env "fm_backend_rex_mark '$MARK_T' blocked question 'Pick a db' '' fm-t1 fm-t1" || fail "notifying mark failed"
  grep -qF $'\033]777;notify;fm-t1;Pick a db\a' "$MARK_TTY" || fail "a notifying mark must carry one OSC 777 notification"
  grep -qF "title=$(printf 'fm-t1' | base64)" "$MARK_TTY" || fail "a titled mark must carry its title"
  : >"$MARK_TTY"
  mark_env "fm_backend_rex_mark '$MARK_T' clear" || fail "clear failed"
  assert_equals $'\033]7501;state=clear:app=firstmate:id=fm\033\\' "$(cat "$MARK_TTY")" "clear must remove only Firstmate's record"
  : >"$MARK_TTY"
  mark_env "fm_backend_rex_progress '$MARK_T' 44 \$'Validating: review\\t4/9' '' fm-t1" || fail "progress failed"
  want=$(printf '\033]7501;state=working:app=firstmate:id=fm/validate:progress=44:title=%s:msg=%s\033\134' \
    "$(printf 'fm-t1' | base64)" "$(printf 'Validating: review 4/9' | base64)")
  assert_equals "$want" "$(cat "$MARK_TTY")" "progress must be one working id=fm/validate record with its percentage"
  : >"$MARK_TTY"
  mark_env "fm_backend_rex_tint '$MARK_T' '#2b2614'" || fail "tint failed"
  assert_equals $'\033]11;#2b2614\033\\' "$(cat "$MARK_TTY")" "a tint must be one OSC 11 set"
  : >"$MARK_TTY"
  mark_env "fm_backend_rex_tint '$MARK_T' reset" || fail "tint reset failed"
  assert_equals $'\033]111\033\\' "$(cat "$MARK_TTY")" "a reset must be one OSC 111"
  : >"$MARK_TTY"
  mark_env "fm_backend_rex_tint '$MARK_T' '?'" && fail "a query or any value other than #rrggbb must be refused"
  [ ! -s "$MARK_TTY" ] || fail "a refused tint must write nothing"
  mark_env "fm_backend_rex_alert '$MARK_T' 'firstmate: WEDGED' 'see marker'" || fail "alert failed"
  grep -qF 'state=blocked:kind=permission:app=firstmate:id=fm-wedge' "$MARK_TTY" || fail "the wedge alert must be a blocked id=fm-wedge record"
  grep -qF $'\033]777;notify;firstmate: WEDGED;see marker\a' "$MARK_TTY" || fail "the wedge alert must carry one notification"
  pass "rex: a mark, progress record, tint, and wedge alert are each one small terminal write of Firstmate's own app=firstmate record"
}

test_mark_read_reports_only_firstmate_records() {
  mark_case mark-read
  mark_status '[{"state":"working","app":"claude-code"},{"id":"fm","state":"blocked","kind":"question","app":"firstmate","msg":"Needs it"}]'
  assert_equals $'blocked\tquestion\tNeeds it\t\t' "$(mark_env "fm_backend_rex_mark_read '$MARK_T'")" "mark_read must report only Firstmate's record"
  mark_status '[{"state":"working","app":"claude-code"}]'
  assert_equals $'clear\t\t\t\t' "$(mark_env "fm_backend_rex_mark_read '$MARK_T'")" "no Firstmate record reads as clear"
  rm -f "$MARK_DIR/fake/status/${MARK_BID#block:}.json"
  printf 'not json' >"$MARK_DIR/fake/status/${MARK_BID#block:}.json"
  mark_env "fm_backend_rex_mark_read '$MARK_T'" >/dev/null && fail "an unreadable pane must fail, never read as clear"
  pass "rex: mark_read reports only Firstmate's record and fails on an unreadable pane"
}

# Rex attributes a record written to the pane's terminal to its foreground
# process, so without this rule a Firstmate mark would read as the harness's
# own blocked state and wake the supervisor.
test_firstmate_records_never_count_as_worker_state() {
  local res
  push_case push-own-records
  printf '{"records":[{"id":"fm","state":"blocked","kind":"question","app":"firstmate","owner":{"pid":4242}}]}\n' \
    >"$PUSH_DIR/fake/status/${PUSH_BID#block:}.json"
  assert_equals unknown "$(rex_env "$PUSH_DIR" "fm_backend_busy_state rex '$PUSH_T'")" "a Firstmate record must not decide busy state"
  res=$(push_wait 1)
  assert_equals "1|" "$res" "the level reconcile must ignore a Firstmate record"
  rm -f "$PUSH_DIR/fake/status/${PUSH_BID#block:}.json"
  rex_event "$PUSH_BID" blocked question firstmate 4242 "Needs your decision" >"$PUSH_DIR/fake/events"
  res=$(push_wait 1)
  assert_equals "1|" "$res" "a streamed Firstmate record must never escalate"
  rex_event "$PUSH_BID" blocked question claude-code 4242 "Continue?" >"$PUSH_DIR/fake/events"
  res=$(push_wait 1)
  [ "${res%%|*}" = 0 ] || fail "the harness's own blocked edge must still escalate, got $res"
  pass "rex: Firstmate's own program-status records never count as the worker's busy state or blocked edge"
}

test_marks_are_off_by_default() {
  mark_case marks-off
  printf '%s\n' "window=$MARK_T" "backend=rex" "kind=ship" >"$MARK_DIR/home/state/t1.meta"
  mark_task_status "needs-decision [at=1700000000] [key=pick-db]: pick a database"
  : >"$MARK_DIR/fake/log"
  marks_run sync || fail "sync failed"
  [ ! -s "$MARK_TTY" ] || fail "with no config file the marks must write nothing"
  grep -q 'program_status' "$MARK_DIR/fake/log" && fail "with no config file the marks must cost no Rex call"
  compgen -G "$MARK_DIR/home/state/.rex-*" >/dev/null && fail "with no config file the marks must cache nothing"
  pass "rex: attention marks are off unless config/rex-status-marks turns them on"
}

test_marks_producer_converges_and_notifies_once() {
  local out
  mark_case marks-on
  printf 'on\n' >"$MARK_DIR/home/config/rex-status-marks"
  printf '%s\n' "window=$MARK_T" "backend=rex" "kind=ship" >"$MARK_DIR/home/state/t1.meta"
  mark_task_status "needs-decision [at=1700000000] [key=pick-db]: pick a database"
  out=$(marks_run plan)
  assert_equals $'t1\tblocked\tquestion\tNeeds your decision: pick a database' "$out" "needs-decision must plan a blocked question mark"
  mark_status '[]'
  marks_run sync || fail "sync failed"
  grep -qF "id=fm:title=$(printf 'fm-t1' | base64):msg=" "$MARK_TTY" || fail "sync must write the mark titled with the tab label"
  grep -qF '777;notify;fm-t1;Needs your decision: pick a database' "$MARK_TTY" || fail "a new mark must notify once"
  : >"$MARK_TTY"
  mark_status '[{"id":"fm","state":"blocked","kind":"question","app":"firstmate","title":"fm-t1","msg":"Needs your decision: pick a database"}]'
  marks_run sync || fail "sync failed"
  [ ! -s "$MARK_TTY" ] || fail "an unchanged live mark must not be rewritten"
  mark_status '[]'
  marks_run sync || fail "sync failed"
  grep -qF 'id=fm:title=' "$MARK_TTY" || fail "a dropped record must be repaired"
  grep -qF '777;notify' "$MARK_TTY" && fail "a repair must not notify again"
  : >"$MARK_TTY"
  mark_task_status "working [at=1700000100]: back on it"
  mark_status '[{"id":"fm","state":"blocked","kind":"question","app":"firstmate","msg":"Needs your decision: pick a database"}]'
  marks_run sync || fail "sync failed"
  grep -qF 'state=clear:app=firstmate:id=fm' "$MARK_TTY" || fail "a working task must clear its mark"
  [ ! -e "$MARK_DIR/home/state/.rex-mark-t1" ] || fail "a cleared mark must drop its cache"
  mark_task_status "blocked [at=1700000200]: needs a GitHub login"
  assert_equals auth "$(marks_run plan t1 | cut -f3)" "a credential blocker must be kind auth"
  mark_task_status "done [at=1700000300]: PR https://github.com/o/r/pull/9 checks green"
  assert_contains "$(marks_run plan t1)" $'done\t\tPR ready: PR https://' "a done line with a URL plans a PR-ready done mark"
  mark_task_status "failed [at=1700000400]: build broke"
  assert_contains "$(marks_run plan t1)" $'error\t\tFailed: build broke' "failed plans an error mark"
  mark_task_status "needs-decision [at=1700000500] [key=k2]: second call"
  mark_status '[]'
  : >"$MARK_TTY"
  marks_run sync || fail "sync failed"
  [ -e "$MARK_DIR/home/state/.rex-mark-t1" ] || fail "a written mark must be cached"
  printf 'off\n' >"$MARK_DIR/home/config/rex-status-marks"
  : >"$MARK_TTY"
  marks_run sync || fail "off sync failed"
  grep -qF 'state=clear:app=firstmate:id=fm' "$MARK_TTY" || fail "turning marks off must clear the shown mark"
  [ ! -e "$MARK_DIR/home/state/.rex-mark-t1" ] || fail "off must drop the cache"
  printf 'loud\n' >"$MARK_DIR/home/config/rex-status-marks"
  : >"$MARK_TTY"
  out=$(marks_run sync 2>&1) || fail "sync with an unknown value failed"
  assert_contains "$out" "unknown value; using off" "a value other than on or off must warn and read as off"
  [ ! -s "$MARK_TTY" ] || fail "an unknown value must read as off"
  pass "rex: the marks producer plans from status, writes once, repairs without re-notifying, clears on resolve, and honors off"
}

test_marks_clear_removes_records_and_caches() {
  mark_case marks-clear
  printf 'on\n' >"$MARK_DIR/home/config/rex-status-marks"
  printf 'subtle\n' >"$MARK_DIR/home/config/rex-tint"
  printf '%s\n' "window=$MARK_T" "backend=rex" "kind=ship" >"$MARK_DIR/home/state/t1.meta"
  mark_task_status "blocked [at=1700000000]: stuck"
  mark_status '[]'
  marks_run sync || fail "sync failed"
  [ -e "$MARK_DIR/home/state/.rex-mark-t1" ] && [ -e "$MARK_DIR/home/state/.rex-tint-t1" ] || fail "sync must cache the mark and tint"
  assert_contains "$(cat "$MARK_TTY")" $'\033]11;#2b2614' "a waiting task must get the subtle waiting tint"
  : >"$MARK_TTY"
  marks_run clear t1 || fail "clear failed"
  grep -qF 'state=clear:app=firstmate:id=fm' "$MARK_TTY" || fail "clear must remove the mark"
  grep -qF $'\033]111\033\\' "$MARK_TTY" || fail "clear must reset the tint"
  compgen -G "$MARK_DIR/home/state/.rex-*-t1" >/dev/null && fail "clear must drop every cache"
  pass "rex: clearing a task removes its mark, tint, and caches"
}

test_nm_run_progress_reads_captured_status() {
  local out caps="$ROOT/tests/captures/no-mistakes-v1.70.1"
  out=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_progress "$(cat "$2")"' _ "$ROOT" "$caps/replacement.toon")
  [ "$out" = $'88\t9\t9\tci\tstarting' ] || fail "a run at its ci step must read 8 of 9 steps done with ci active, got '$out'"
  out=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_progress "$(cat "$2")"' _ "$ROOT" "$caps/parked.toon")
  [ "$(printf '%s' "$out" | cut -f2-4)" = $'4\t9\ttest' ] || fail "a parked run must name its first unfinished step, got '$out'"
  bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_progress "$(cat "$2")"' _ "$ROOT" "$caps/overview.toon" >/dev/null \
    && fail "output with no steps table must fail"
  pass "rex: validation progress reads captured no-mistakes status by column name"
}

test_bin_prefers_rex_bin_dir
test_rex_spawn_refuses_unproven_remote_endpoint
test_version_check_gates_api_revision
test_parse_target_restores_prefixes
test_create_task_per_home_session_create_then_adopt
test_create_task_uses_confirmed_launcher_session
test_create_task_refusals
test_reclaim_replaces_a_husk_and_refuses_a_live_one
test_reclaim_fallback_placement_replaces_a_husk
test_capture_and_derived_viewport
test_composer_reads_the_cursor_row
test_agent_state_from_process_view
test_agent_state_sees_a_harness_below_a_shell_foreground
test_native_busy_trusts_live_owner_only
test_current_path_follows_foreground
test_send_literal_and_keys
test_kill_closes_and_retires_per_home_session
test_kill_never_retires_a_foreign_session
test_kill_refuses_without_proof
test_teardown_retires_the_secondmate_session
test_absence_recheck
test_control_absence_verdict_reads_rex_meta
test_control_exit_after_a_server_stop
test_list_live_scopes_to_this_home
test_push_capability_gate
test_push_blocked_edge_carries_kind_and_message
test_push_untrusted_owner_is_ignored
test_push_level_reconcile_and_dedupe
test_push_gone_edge_ends_the_wait
test_push_reader_failures_fall_back
test_mark_progress_tint_and_alert_sequences
test_mark_read_reports_only_firstmate_records
test_firstmate_records_never_count_as_worker_state
test_marks_are_off_by_default
test_marks_producer_converges_and_notifies_once
test_marks_clear_removes_records_and_caches
test_nm_run_progress_reads_captured_status
