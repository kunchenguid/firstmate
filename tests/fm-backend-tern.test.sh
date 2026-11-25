#!/usr/bin/env bash
# tests/fm-backend-tern.test.sh - fake-tern-CLI unit tests for the tern
# session-provider adapter (bin/backends/tern.sh) and its dispatcher wiring
# (bin/fm-backend.sh, docs/tern-backend.md). Mirrors
# tests/fm-backend-cmux.test.sh's fakebin/command-log convention: a small,
# LOG-based, canned-response fake `tern` plus real `jq`. The real-binary smoke
# test lives in tests/fm-backend-tern-smoke.test.sh, gated on a reachable Tern
# window with a control endpoint.
#
# Fixture contract: every call is appended to $FM_TERN_LOG (one line, argv
# separated by the unit separator 0x1f) and answered from
# $FM_TERN_RESPONSES/<n>.out, consumed IN ORDER (call 1 reads 1.out, call 2
# reads 2.out, ...). A missing .out file means "succeed with empty stdout"; an
# <n>.exit file carries a non-zero exit status. `--version` is the one call that
# is neither counted nor consumes a response. The ids in these fixtures are
# deliberately above 2^53 so a path that round-trips them through a JSON
# number type (or a shell arithmetic cast) fails here.
#
# The `tern ctl state` fixtures (state_text and the helpers over it) model
# Carly's answer slot, which stores the text Carly DISPLAYS for a Lua program's
# result, "→ <answer>", not escaped JSON: the text goes in verbatim, so a case
# can hold a raw control character inside a JSON string exactly as a live window
# displays the free text of a whole `cx.agents:list()` entry. The fake never runs
# the Lua program it is handed; what the window would have answered is each
# case's fixture.
# shellcheck disable=SC2016 # File-wide: run_tern/safety_run and the dispatcher cases pass single-quoted snippets to `bash -c`, where the CHILD shell expands $1..$4 and $0 from the arguments that follow, exactly as tests/fm-backend.test.sh's child-Bash cases do.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the tern adapter)"; exit 0; }

# This suite may itself run inside a Tern block; the adapter and dispatcher
# cases pin the Tern markers they care about explicitly.
unset TMUX HERDR_ENV CMUX_WORKSPACE_ID TERM_PROGRAM TERN_PANE TERN_PANE_SOCKET TERN_WINDOW_KEY FM_TERN_SESSION

TMP_ROOT=$(fm_test_tmproot fm-backend-tern-tests)

SID=9007199254740993
SID2=9007199254740997
TAB=9007199254740995
BLK=9223372036854775807
BLK_NEIGHBOR=9223372036854775806
TARGET="$SID:$BLK"
SEL="$SID/$BLK"
US=$'\x1f'
NL=$'\n'

make_tern_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/responses"
  cat > "$fb/tern" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_TERN_LOG:?}"
RESP="${FM_TERN_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
if [ "${1:-}" = --version ] || [ "${1:-}" = version ]; then
  printf 'tern %s (b9ef74c)\n' "${FM_TERN_FAKE_VERSION:-0.9.4}"
  exit 0
fi
{
  printf 'tern'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNT_FILE"
# A hung control endpoint: the adapter must bound `tern ctl` itself.
if [ "${1:-}" = ctl ] && [ -n "${FM_TERN_FAKE_CTL_HANG:-}" ]; then
  exec sleep 30
fi
if [ -f "$RESP/$n.exit" ]; then
  [ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/tern"
  printf '%s\n' "$fb"
}

new_case() {  # <name> -> echoes dir with fakebin, responses, empty log
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/responses"
  : > "$dir/log"
  make_tern_fakebin "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# run_tern <dir> <bash-snippet> [args...]: run a snippet against the adapter
# with the fake tern first on PATH. $0 is the repo root, "$@" are the args.
# Extra environment goes through the caller's own `env` prefix or exports.
run_tern() {
  local dir=$1 snippet=$2
  shift 2
  PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c ". \"\$0/bin/backends/tern.sh\"; $snippet" "$ROOT" "$@"
}

# --- fixture builders: the shapes `tern ls --json`, `tern process --json` and
# `tern ctl state` print, with 64-bit ids as RAW integers like the real CLI.

block_json() {  # <id> [rows] [live: true|false]
  local id=$1 rows=${2:-40} live=${3:-true} exited=null
  [ "$live" = true ] || exited=0
  printf '{"id":%s,"title":"t","cwd":"/tmp","program":"/bin/bash","args":["-l"],"command":null,"cols":100,"rows":%s,"exited":%s,"keep_open":true,"focused":false,"live":%s}' \
    "$id" "$rows" "$exited" "$live"
}

tab_json() {  # <id> <name|null> <block-json>
  local name=null
  [ "$2" = null ] || name="\"$2\""
  printf '{"id":%s,"number":1,"name":%s,"shown":false,"zoomed":false,"blocks":[%s]}' "$1" "$name" "$3"
}

session_json() {  # <id> <name> <tab-json>...
  local id=$1 name=$2 tabs='' sep=''
  shift 2
  while [ $# -ge 1 ]; do
    tabs="$tabs$sep$1"
    sep=','
    shift
  done
  printf '{"id":%s,"name":"%s","shown":true,"tabs":[%s]}' "$id" "$name" "$tabs"
}

ls_write() {  # <dir> <n> <session-json>...
  local dir=$1 n=$2 sessions='' sep=''
  shift 2
  while [ $# -ge 1 ]; do
    sessions="$sessions$sep$1"
    sep=','
    shift
  done
  printf '{"sessions":[%s],"detached":[]}\n' "$sessions" > "$dir/responses/$n.out"
}

# ls_with_block <dir> <n> [rows] [live] [tab-name] [session-name]: the common
# case, one session holding the fixture block.
ls_with_block() {
  local dir=$1 n=$2 rows=${3:-40} live=${4:-true} tabname=${5:-null} sname=${6:-fm-test-unit}
  ls_write "$dir" "$n" "$(session_json "$SID" "$sname" "$(tab_json "$TAB" "$tabname" "$(block_json "$BLK" "$rows" "$live")")")"
}

ls_without_block() {  # <dir> <n>
  ls_write "$1" "$2" "$(session_json "$SID" fm-test-unit "$(tab_json "$TAB" null "$(block_json 4242)")")"
}

process_response() {  # <dir> <n> <foreground-name> [argv-json] [cwd]
  local dir=$1 n=$2 fg=$3 argv=${4:-} cwd=${5:-/tmp}
  [ -n "$argv" ] || argv="[\"$fg\"]"
  printf '{"pane":%s,"child":{"pid":101,"name":"bash","argv":["bash"],"cwd":"/tmp"},"group":101,"foreground":{"pid":202,"name":"%s","argv":%s,"cwd":"%s"}}\n' \
    "$BLK" "$fg" "$argv" "$cwd" > "$dir/responses/$n.out"
}

# ctl_ok <dir> <n>: the `tern ctl carly lua ...` acknowledgement.
ctl_ok() { printf '{"ok":true}\n' > "$1/responses/$2.out"; }

# ctl_down <dir> <n>: what a Tern with no reachable window prints, exit 1.
ctl_down() {
  printf '{"ok":false,"error":"no Tern window on this machine shows this pane"}\n' > "$1/responses/$2.out"
  printf '1\n' > "$1/responses/$2.exit"
}

# state_text <dir> <n> <text>: a `tern ctl state` body whose
# carly.last_tool.text is <text> verbatim (jq builds the JSON).
state_text() { jq -nc --arg t "$3" '{carly:{last_tool:{text:$t}}}' > "$1/responses/$2.out"; }

# agent_json <pane> <state> [alive]: one agent entry in the shape the adapter's Lua
# projection (FM_BACKEND_TERN_AGENTS_LUA) answers: the pane id as a RAW integer, the
# state word and the alive boolean, and no free text.
agent_json() {  # <pane> <state> [alive]
  printf '{"pane":%s,"state":"%s","alive":%s}' "$1" "$2" "${3:-true}"
}

# displayed_agent_json <pane> <state> <line-break>: the same agent as the window DISPLAYS it
# when the program returns the WHOLE `cx.agents:list()` entry, free-text fields included
# (title, last_message, running.line, last.line). <line-break> separates the two lines of
# last_message: "$NL" is the RAW newline a live window displays inside the string, which JSON
# forbids; the two characters \n are its escaped form, the control that shows the raw
# character, not the free text itself, is what the adapter cannot read.
displayed_agent_json() {  # <pane> <state> <line-break>
  local entry
  entry=$(agent_json "$1" "$2")
  printf '%s,"title":"Fix the build","last_message":"Captain, the build is green.%sNext: rerun the suite.","running":{"line":"go test ./..."},"last":{"line":"ok 0.2s"}}' \
    "${entry%?}" "$3"
}

# state_agents <dir> <n> <agent-json>...: the `tern ctl state` body whose
# carly.last_tool.text is the displayed answer "→ [..]" for those entries.
state_agents() {
  local dir=$1 n=$2 body='' sep=''
  shift 2
  while [ $# -ge 1 ]; do
    body="$body$sep$1"
    sep=','
    shift
  done
  state_text "$dir" "$n" "→ [$body]"
}

capture_ok() { printf '%s' "$3" > "$1/responses/$2.out"; }

screen_empty=$'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
screen_pending=$'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send'

# tern_expected_*: bash-only reimplementations of the home tag and scoped tab
# title, used to build fixtures for the home-scoped names the adapter creates
# and matches (mirrors tests/fm-backend-cmux.test.sh's cmux_expected_*).
tern_expected_root_hash() {  # <root>
  local real
  real=$(cd "$1" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

tern_expected_home_label() {  # [home] [root]
  local home=${1:-$ROOT} root=${2:-$ROOT} marker id prefix=firstmate
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    [ -z "$id" ] || prefix="2ndmate-$id"
  fi
  printf '%s-%s' "$prefix" "$(tern_expected_root_hash "$root")"
}

tern_expected_title() {  # <fm-task-label> [home] [root]
  local label=$1 home=${2:-$ROOT} root=${3:-$ROOT} rest
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(tern_expected_home_label "$home" "$root")" "$rest"
}

assert_call_order() {  # <log> <before> <after> <msg>
  local log=$1 before=$2 after=$3 msg=$4 b a
  b=$(grep -anF -- "$before" "$log" | head -1 | cut -d: -f1)
  a=$(grep -anF -- "$after" "$log" | head -1 | cut -d: -f1)
  [ -n "$b" ] || fail "$msg (missing before call: '$before')"
  [ -n "$a" ] || fail "$msg (missing after call: '$after')"
  [ "$b" -lt "$a" ] || fail "$msg"
}

count_calls() { grep -cF -- "$2" "$1/log" || true; }

# --- target parsing ------------------------------------------------------------

test_parse_target_keeps_full_64_bit_ids() {
  ( . "$ROOT/bin/backends/tern.sh"
    fm_backend_tern_parse_target "$TARGET" || exit 1
    [ "$FM_BACKEND_TERN_SESSION_ID" = "$SID" ] || { echo "session mismatch: $FM_BACKEND_TERN_SESSION_ID" >&2; exit 1; }
    [ "$FM_BACKEND_TERN_BLOCK_ID" = "$BLK" ] || { echo "block mismatch: $FM_BACKEND_TERN_BLOCK_ID" >&2; exit 1; }
  ) || fail "fm_backend_tern_parse_target did not split <session-id>:<block-id> without altering 64-bit ids"
  pass "fm_backend_tern_parse_target: splits '<session-id>:<block-id>' and keeps ids above 2^53 byte-exact"
}

test_parse_target_rejects_malformed_targets() {
  local bad
  for bad in '' 'nocolon' ':7' '7:' '7:8:9' 'a:7' '7:b' '-7:8' '7:+8' '7: 8' 'Default:4' '7:@focused'; do
    ( . "$ROOT/bin/backends/tern.sh"; fm_backend_tern_parse_target "$bad" ) 2>/dev/null \
      && fail "parse_target should refuse '$bad' (only digits:digits names a block; titles and selectors are never used)"
  done
  pass "fm_backend_tern_parse_target: refuses empty, non-numeric, signed, spaced, extra-colon and selector-shaped targets"
}

test_malformed_target_never_reaches_the_cli() {
  local dir
  dir=$(new_case malformed-target)
  run_tern "$dir" 'fm_backend_tern_send_key "$1" Enter; fm_backend_tern_send_literal "$1" x; fm_backend_tern_capture "$1" 5; fm_backend_tern_kill "$1"' '@focused' >/dev/null 2>&1
  [ ! -s "$dir/log" ] || fail "a malformed target must be refused before any tern call, got: $(cat "$dir/log")"
  pass "fm_backend_tern_*: a selector-shaped target (@focused) is refused without calling tern"
}

# --- container_ensure --------------------------------------------------------------

test_container_ensure_reuses_existing_session() {
  local dir out
  dir=$(new_case container-existing)
  ls_write "$dir" 1 "$(session_json 1 Default "$(tab_json 3 null "$(block_json 2)")")" \
    "$(session_json "$SID" fm-test-ctr "$(tab_json "$TAB" null "$(block_json "$BLK")")")"
  out=$( FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_container_ensure' )
  [ "$out" = "$SID" ] || fail "container_ensure should print the numeric session id '$SID', got '$out'"
  assert_not_contains "$(cat "$dir/log")" "${US}new${US}session" "container_ensure must not create a session that already exists"
  pass "fm_backend_tern_container_ensure: reuses an existing named session and prints its full 64-bit id"
}

test_container_ensure_creates_missing_session_by_name() {
  local dir out
  dir=$(new_case container-create)
  ls_write "$dir" 1 "$(session_json 1 Default "$(tab_json 3 null "$(block_json 2)")")"
  # 2: new session (silent), 3: ls again
  ls_write "$dir" 3 "$(session_json 1 Default "$(tab_json 3 null "$(block_json 2)")")" \
    "$(session_json "$SID2" fm-test-ctr "$(tab_json "$TAB" null "$(block_json "$BLK")")")"
  out=$( FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_container_ensure' )
  [ "$out" = "$SID2" ] || fail "container_ensure should print the CREATED session's id '$SID2' (not the unrelated Default session), got '$out'"
  assert_contains "$(cat "$dir/log")" "tern${US}new${US}session${US}fm-test-ctr" "container_ensure did not create the named session"
  assert_not_contains "$(cat "$dir/log")" "${US}kill${US}" "container_ensure must never kill a session"
  assert_not_contains "$(cat "$dir/log")" "${US}close${US}" "container_ensure must never close a block"
  pass "fm_backend_tern_container_ensure: creates a missing session by name and returns the new id, leaving other sessions alone"
}

test_container_ensure_default_name_is_home_scoped() {
  local dir out
  dir=$(new_case container-default-name)
  ls_write "$dir" 1 "$(session_json 1 Default "$(tab_json 3 null "$(block_json 2)")")"
  ls_write "$dir" 3 "$(session_json "$SID2" "fm-$(tern_expected_home_label)" "$(tab_json "$TAB" null "$(block_json "$BLK")")")"
  out=$( run_tern "$dir" 'fm_backend_tern_container_ensure' )
  [ "$out" = "$SID2" ] || fail "container_ensure should resolve the home-tag-named session, got '$out'"
  assert_contains "$(cat "$dir/log")" "tern${US}new${US}session${US}fm-$(tern_expected_home_label)" \
    "container_ensure's default session name must be fm-<home tag> (so two firstmate homes never share a session)"
  pass "fm_backend_tern_container_ensure: without an override the session is named fm-<home tag>"
}

test_container_ensure_refuses_old_version() {
  local dir out status
  dir=$(new_case container-old-version)
  out=$( FM_TERN_FAKE_VERSION=0.9.3 FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_container_ensure' 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "container_ensure should refuse tern 0.9.3 (below the verified 0.9.4 minimum)"
  assert_contains "$out" "0.9.3" "the version refusal did not name the rejected version"
  assert_not_contains "$(cat "$dir/log")" "${US}new${US}session" "an unsupported tern version must not create sessions"
  pass "fm_backend_tern_container_ensure: refuses a tern older than 0.9.4 loudly before touching any session"
}

test_container_ensure_accepts_double_digit_minor_version() {
  local dir out
  dir=$(new_case container-version-0-10)
  ls_with_block "$dir" 1 40 true null fm-test-ctr
  out=$( FM_TERN_FAKE_VERSION=0.10.0 FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_container_ensure' )
  [ "$out" = "$SID" ] || fail "tern 0.10.0 is newer than 0.9.4 and must be accepted (numeric, not lexical, comparison), got '$out'"
  pass "fm_backend_tern_container_ensure: compares versions numerically (0.10.0 passes the 0.9.4 floor)"
}

test_container_ensure_fails_when_inventory_unreadable() {
  local dir status
  dir=$(new_case container-ls-fails)
  printf '1\n' > "$dir/responses/1.exit"
  FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_container_ensure' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "container_ensure should fail when tern ls fails (no daemon)"
  assert_not_contains "$(cat "$dir/log")" "${US}new${US}session" "an unreadable inventory must not be treated as 'no such session'"
  pass "fm_backend_tern_container_ensure: an unreadable inventory fails instead of creating a duplicate session"
}

# --- create_task ----------------------------------------------------------------------

test_create_task_creates_keep_open_tab_and_renames_it() {
  local dir out title
  dir=$(new_case create-task)
  title=$(tern_expected_title fm-newtask)
  # 1: ls (find the session, duplicate check)  2: new tab  3: rename  4: ls (read the title back)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-ctr "$(tab_json 3 null "$(block_json 2)")")"
  printf '{"session":%s,"tab":%s,"block":%s}\n' "$SID" "$TAB" "$BLK" > "$dir/responses/2.out"
  ls_write "$dir" 4 "$(session_json "$SID" fm-test-ctr "$(tab_json 3 null "$(block_json 2)")" "$(tab_json "$TAB" "$title" "$(block_json "$BLK")")")"
  out=$( FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_create_task fm-newtask /tmp/proj' )
  [ "$out" = "$TAB $BLK" ] || fail "create_task should print '<tab-id> <block-id>' with exact 64-bit ids, got '$out'"
  assert_contains "$(cat "$dir/log")" "tern${US}new${US}tab${US}$SID${US}--cwd${US}/tmp/proj${US}--keep-open${US}--json" \
    "create_task did not open a keep-open tab in the numeric session with the project cwd"
  assert_contains "$(cat "$dir/log")" "tern${US}rename${US}$SEL${US}$title" \
    "create_task did not rename the tab to the home-scoped task title through the one-session block selector"
  assert_call_order "$dir/log" "${US}new${US}tab" "${US}rename${US}" "create_task must rename the tab after creating it"
  assert_equals "2" "$(grep -c "${US}ls${US}--json" "$dir/log")" "create_task should read the inventory once to find the session and once to read the title back"
  pass "fm_backend_tern_create_task: opens a keep-open tab in the session, renames it to the scoped title, reads it back, prints exact ids"
}

test_create_task_refuses_a_duplicate_tab_title() {
  local dir status title
  dir=$(new_case create-task-duplicate)
  title=$(tern_expected_title fm-dup1)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-ctr "$(tab_json "$TAB" "$title" "$(block_json "$BLK")")")"
  FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_create_task fm-dup1 /tmp/proj' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse a tab whose scoped title already exists (tern itself does not enforce uniqueness)"
  assert_not_contains "$(cat "$dir/log")" "${US}new${US}tab" "a duplicate title must be refused before any tab is created"
  pass "fm_backend_tern_create_task: refuses a duplicate scoped tab title before creating anything"
}

test_create_task_fails_without_session() {
  local dir status
  dir=$(new_case create-task-no-session)
  ls_write "$dir" 1 "$(session_json 1 Default "$(tab_json 3 null "$(block_json 2)")")"
  FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_create_task fm-newtask /tmp/proj' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should fail when its session does not exist"
  assert_not_contains "$(cat "$dir/log")" "${US}new${US}tab" "create_task must not open a tab in another session (e.g. the user's Default session)"
  pass "fm_backend_tern_create_task: refuses to place a task in any session other than its own"
}

test_create_task_fails_on_unparseable_new_tab_output() {
  local dir status
  dir=$(new_case create-task-bad-json)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-ctr "$(tab_json 3 null "$(block_json 2)")")"
  printf 'not json\n' > "$dir/responses/2.out"
  FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_create_task fm-newtask /tmp/proj' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should fail when new tab output has no tab/block ids"
  assert_not_contains "$(cat "$dir/log")" "${US}rename${US}" "create_task must not rename a block it could not identify"
  pass "fm_backend_tern_create_task: an unparseable 'new tab' answer fails without renaming anything"
}

test_create_task_closes_its_block_when_rename_fails() {
  local dir status
  dir=$(new_case create-task-rename-fails)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-ctr "$(tab_json 3 null "$(block_json 2)")")"
  printf '{"session":%s,"tab":%s,"block":%s}\n' "$SID" "$TAB" "$BLK" > "$dir/responses/2.out"
  printf '1\n' > "$dir/responses/3.exit"
  FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_create_task fm-newtask /tmp/proj' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should fail when the tab cannot be given its task title (an unnamed tab cannot be recovered by label)"
  assert_contains "$(cat "$dir/log")" "tern${US}close${US}$SEL" "create_task should close the block it just created when it cannot title it"
  pass "fm_backend_tern_create_task: a failed rename fails the create and closes only the block it made"
}

test_create_task_fails_when_the_title_does_not_read_back() {
  local dir status
  dir=$(new_case create-task-title-not-kept)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-ctr "$(tab_json 3 null "$(block_json 2)")")"
  printf '{"session":%s,"tab":%s,"block":%s}\n' "$SID" "$TAB" "$BLK" > "$dir/responses/2.out"
  # 3: rename succeeds, 4-6: the inventory never shows the new title, 7: close
  ls_write "$dir" 4 "$(session_json "$SID" fm-test-ctr "$(tab_json "$TAB" null "$(block_json "$BLK")")")"
  ls_write "$dir" 5 "$(session_json "$SID" fm-test-ctr "$(tab_json "$TAB" null "$(block_json "$BLK")")")"
  ls_write "$dir" 6 "$(session_json "$SID" fm-test-ctr "$(tab_json "$TAB" null "$(block_json "$BLK")")")"
  FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_create_task fm-newtask /tmp/proj' >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail loudly when tern did not keep the tab title (every later operation checks it)"
  assert_contains "$(cat "$dir/log")" "tern${US}close${US}$SEL" "create_task should close the block it created but could not title"
  pass "fm_backend_tern_create_task: a title that never reads back fails the create and closes the new block"
}

# --- target_ready --------------------------------------------------------------------

test_target_ready_requires_the_block_in_that_session() {
  local dir
  dir=$(new_case ready-ok)
  ls_with_block "$dir" 1
  run_tern "$dir" 'fm_backend_tern_target_ready "$1"' "$TARGET" || fail "target_ready should succeed when the block is listed in its session"
  assert_equals "1" "$(grep -c . "$dir/log")" "target_ready should cost exactly one tern call"

  dir=$(new_case ready-absent)
  ls_without_block "$dir" 1
  run_tern "$dir" 'fm_backend_tern_target_ready "$1"' "$TARGET" && fail "target_ready should fail when the block is not listed"

  dir=$(new_case ready-other-session)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-unit "$(tab_json "$TAB" null "$(block_json 4242)")")" \
    "$(session_json "$SID2" fm-test-other "$(tab_json 9007199254741001 null "$(block_json "$BLK")")")"
  run_tern "$dir" 'fm_backend_tern_target_ready "$1"' "$TARGET" \
    && fail "target_ready should fail when the block lives in a different session than the endpoint names"

  dir=$(new_case ready-neighbor-id)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-unit "$(tab_json "$TAB" null "$(block_json "$BLK_NEIGHBOR")")")"
  run_tern "$dir" 'fm_backend_tern_target_ready "$1"' "$TARGET" \
    && fail "target_ready must not confuse $BLK with its neighbor $BLK_NEIGHBOR (64-bit ids must not round to doubles)"

  dir=$(new_case ready-ls-fails)
  printf '1\n' > "$dir/responses/1.exit"
  run_tern "$dir" 'fm_backend_tern_target_ready "$1"' "$TARGET" && fail "target_ready should fail when the inventory is unreadable"
  pass "fm_backend_tern_target_ready: one ls, true only for the exact session:block pair, exact at 64 bits, false when unreadable"
}

test_target_ready_checks_expected_label() {
  local dir title
  title=$(tern_expected_title fm-label)

  dir=$(new_case ready-label-ok)
  ls_with_block "$dir" 1 40 true "$title"
  run_tern "$dir" 'fm_backend_tern_target_ready "$1" fm-label' "$TARGET" || fail "target_ready should accept a tab titled with the expected scoped label"

  dir=$(new_case ready-label-mismatch)
  ls_with_block "$dir" 1 40 true "not-the-task"
  run_tern "$dir" 'fm_backend_tern_target_ready "$1" fm-label' "$TARGET" \
    && fail "target_ready should reject a block id reused under a different tab title"

  dir=$(new_case ready-label-foreign-home)
  ls_with_block "$dir" 1 40 true "$(tern_expected_title fm-label "$ROOT" "$TMP_ROOT")"
  run_tern "$dir" 'fm_backend_tern_target_ready "$1" fm-label' "$TARGET" \
    && fail "target_ready should reject a same-label tab scoped to a different firstmate home"
  pass "fm_backend_tern_target_ready: the expected label must equal this home's scoped tab title"
}

# --- capture / visible_capture ---------------------------------------------------------

test_capture_passes_surfaces_and_scrollback_and_trims_locally() {
  local dir out
  dir=$(new_case capture)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 $'line one\nline two\nline three\nline four'
  out=$( run_tern "$dir" 'fm_backend_tern_capture "$1" 2' "$TARGET" )
  [ "$out" = $'line three\nline four' ] || fail "capture should trim to the last N lines locally, got '$out'"
  assert_contains "$(cat "$dir/log")" "tern${US}capture${US}$SEL${US}--scrollback${US}--surfaces" \
    "history capture must pass --scrollback and --surfaces (a natively drawn omp block prints only its shell prompt without --surfaces)"
  assert_not_contains "$(cat "$dir/log")" "--ansi" "tern capture must stay plain text (styled=0)"
  assert_not_contains "$(cat "$dir/log")" "--html" "tern capture must stay plain text"
  assert_call_order "$dir/log" "${US}ls${US}--json" "${US}capture${US}" "capture must verify the block before reading it"
  pass "fm_backend_tern_capture: 'tern capture <block-id> --scrollback --surfaces', trimmed to N lines locally"
}

test_capture_fails_when_capture_fails_or_target_absent() {
  local dir status
  dir=$(new_case capture-fails)
  ls_with_block "$dir" 1
  printf '1\n' > "$dir/responses/2.exit"
  run_tern "$dir" 'fm_backend_tern_capture "$1" 5' "$TARGET" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "capture should propagate a failing tern capture even with empty stdout"

  dir=$(new_case capture-absent)
  ls_without_block "$dir" 1
  run_tern "$dir" 'fm_backend_tern_capture "$1" 5' "$TARGET" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the block is gone"
  assert_not_contains "$(cat "$dir/log")" "${US}capture${US}" "capture must not read after readiness fails"
  pass "fm_backend_tern_capture: propagates a failing capture and never reads an absent block"
}

test_visible_capture_is_viewport_only() {
  local dir out
  dir=$(new_case visible-capture)
  ls_with_block "$dir" 1 2
  capture_ok "$dir" 2 $'old history\nrow one\nrow two'
  out=$( run_tern "$dir" 'fm_backend_tern_visible_capture "$1"' "$TARGET" )
  assert_contains "$(cat "$dir/log")" "tern${US}capture${US}$SEL${US}--surfaces" "visible_capture must pass --surfaces"
  assert_not_contains "$(cat "$dir/log")" "--scrollback" "visible_capture must never request scrollback"
  [ "$out" = $'row one\nrow two' ] || fail "visible_capture should keep only the block's visible rows (2 from ls), got '$out'"
  pass "fm_backend_tern_visible_capture: --surfaces without --scrollback, limited to the block's visible rows"
}

test_capture_reads_text_from_a_surface_json_object() {
  local dir out envelope
  envelope=$(jq -cn --arg t $'line one\nline two\nline three\nline four' '{block: 1, text: $t}')

  dir=$(new_case capture-json)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 "$envelope"
  out=$( run_tern "$dir" 'fm_backend_tern_capture "$1" 2' "$TARGET" )
  [ "$out" = $'line three\nline four' ] || fail "capture should trim the surface object's .text, not its JSON, got '$out'"

  dir=$(new_case visible-capture-json)
  ls_with_block "$dir" 1 2
  capture_ok "$dir" 2 "$envelope"
  out=$( run_tern "$dir" 'fm_backend_tern_visible_capture "$1"' "$TARGET" )
  [ "$out" = $'line three\nline four' ] || fail "visible_capture should keep the last rows of .text, got '$out'"

  dir=$(new_case capture-json-not-surface)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 '{"block":1,"text":7}'
  out=$( run_tern "$dir" 'fm_backend_tern_capture "$1" 5' "$TARGET" )
  [ "$out" = '{"block":1,"text":7}' ] || fail "output that is not a surface object must pass through unchanged, got '$out'"
  pass "fm_backend_tern_capture/visible_capture: a --surfaces JSON object yields its .text before the line trim; other output is kept raw"
}

# --- send_literal / send_key / send_text_line -------------------------------------------------

test_send_literal_types_without_enter() {
  local dir
  dir=$(new_case send-literal)
  ls_with_block "$dir" 1
  run_tern "$dir" 'fm_backend_tern_send_literal "$1" "--help"' "$TARGET" || fail "send_literal should succeed"
  assert_contains "$(cat "$dir/log")" "tern${US}send${US}$SEL${US}text${US}--help" \
    "send_literal should use 'tern send <block> text <TEXT>' so option-shaped text stays data"
  assert_not_contains "$(cat "$dir/log")" "${US}run${US}" "send_literal must not press Enter (tern run types Enter)"
  assert_not_contains "$(cat "$dir/log")" "${US}keys${US}" "send_literal must not send keys"
  pass "fm_backend_tern_send_literal: 'tern send <block> text TEXT' with no Enter, even for option-shaped text"
}

test_send_key_normalizes_firstmate_vocabulary() {
  local dir pair key want
  for pair in 'Enter:enter' 'Escape:escape' 'Esc:escape' 'C-c:ctrl+c' 'C-u:ctrl+u'; do
    key=${pair%%:*}; want=${pair#*:}
    dir=$(new_case "send-key-$key")
    ls_with_block "$dir" 1
    run_tern "$dir" 'fm_backend_tern_send_key "$1" "$2"' "$TARGET" "$key" || fail "send_key $key should succeed"
    assert_contains "$(cat "$dir/log")" "tern${US}send${US}$SEL${US}keys${US}$want" \
      "send_key did not map $key to tern's '$want' chord on the numeric block"
  done
  pass "fm_backend_tern_send_key: Enter/Escape/Esc/C-c/C-u map to tern's enter/escape/ctrl+c/ctrl+u chords"
}

test_send_key_rejects_label_mismatch() {
  local dir status
  dir=$(new_case send-key-label-mismatch)
  ls_with_block "$dir" 1 40 true "not-the-task"
  run_tern "$dir" 'fm_backend_tern_send_key "$1" Enter fm-label' "$TARGET" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse when the expected task label does not match the tab"
  assert_not_contains "$(cat "$dir/log")" "${US}keys${US}" "send_key must not deliver a key to a block it could not attribute"
  pass "fm_backend_tern_send_key: a mismatched expected task label sends nothing"
}

test_send_text_line_is_one_atomic_run() {
  local dir
  dir=$(new_case send-text-line)
  ls_with_block "$dir" 1
  run_tern "$dir" 'fm_backend_tern_send_text_line "$1" "export TRACEPARENT=carrier"' "$TARGET" || fail "send_text_line should succeed"
  assert_contains "$(cat "$dir/log")" "tern${US}run${US}$SEL${US}export TRACEPARENT=carrier" "send_text_line should use one 'tern run <session>/<block> TEXT'"
  assert_equals "1" "$(grep -c "${US}run${US}" "$dir/log")" "send_text_line should run exactly once"
  assert_not_contains "$(cat "$dir/log")" "${US}keys${US}" "send_text_line must not add a separate Enter key"
  pass "fm_backend_tern_send_text_line: one atomic 'tern run' (text plus Enter), no separate key"
}

# --- current_path -----------------------------------------------------------------------------

test_current_path_reads_foreground_cwd_passively() {
  local dir out
  dir=$(new_case current-path)
  ls_with_block "$dir" 1
  process_response "$dir" 2 bash '["bash"]' /tmp/fake-worktree
  out=$( run_tern "$dir" 'fm_backend_tern_current_path "$1"' "$TARGET" )
  [ "$out" = /tmp/fake-worktree ] || fail "current_path should read process foreground.cwd (the live process), got '$out'"
  assert_not_contains "$(cat "$dir/log")" "${US}send${US}" "current_path must be a passive read, never type a pwd probe into the block"
  assert_not_contains "$(cat "$dir/log")" "${US}run${US}" "current_path must be a passive read, never type a pwd probe into the block"
  pass "fm_backend_tern_current_path: reads 'tern process' foreground.cwd without typing into the block"
}

test_current_path_is_empty_when_process_read_fails() {
  local dir out
  dir=$(new_case current-path-fail)
  ls_with_block "$dir" 1
  printf '1\n' > "$dir/responses/2.exit"
  out=$( run_tern "$dir" 'fm_backend_tern_current_path "$1"' "$TARGET" 2>/dev/null )
  [ -z "$out" ] || fail "current_path should print nothing when the process read fails, got '$out'"
  pass "fm_backend_tern_current_path: prints nothing when the process cannot be read"
}

# --- composer_state ------------------------------------------------------------------------------

test_composer_state_verdicts_from_surface_capture() {
  local dir out
  dir=$(new_case composer-empty)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 "$screen_empty"
  out=$( run_tern "$dir" 'fm_backend_tern_composer_state "$1"' "$TARGET" )
  [ "$out" = empty ] || fail "a bare prompt glyph should read empty, got '$out'"
  assert_contains "$(cat "$dir/log")" "tern${US}capture${US}$SEL${US}--surfaces" "composer reads must use --surfaces"
  assert_not_contains "$(cat "$dir/log")" "--ansi" "tern declares styled=0, so composer reads must stay plain"

  dir=$(new_case composer-pending)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 "$screen_pending"
  out=$( run_tern "$dir" 'fm_backend_tern_composer_state "$1"' "$TARGET" )
  [ "$out" = pending ] || fail "real composer text should read pending, got '$out'"

  dir=$(new_case composer-json)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 "$(jq -cn --arg t "$screen_pending" '{block: 1, text: $t}')"
  out=$( run_tern "$dir" 'fm_backend_tern_composer_state "$1"' "$TARGET" )
  [ "$out" = pending ] || fail "a composer inside a --surfaces JSON object should read pending, got '$out'"

  dir=$(new_case composer-no-row)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 'plain-shell-prompt$ '
  out=$( run_tern "$dir" 'fm_backend_tern_composer_state "$1"' "$TARGET" )
  [ "$out" = unknown ] || fail "a capture with no composer row should read unknown, got '$out'"

  dir=$(new_case composer-capture-fails)
  ls_with_block "$dir" 1
  printf '1\n' > "$dir/responses/2.exit"
  out=$( run_tern "$dir" 'fm_backend_tern_composer_state "$1"' "$TARGET" ) || fail "composer_state must not fail its caller"
  [ "$out" = unknown ] || fail "an unreadable block should read unknown, got '$out'"
  pass "fm_backend_tern_composer_state: empty/pending/unknown from a plain --surfaces capture, never failing the caller"
}

test_dispatch_composer_state_routes_tern() {
  local dir out
  dir=$(new_case dispatch-composer)
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 "$screen_pending"
  out=$( PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state tern "$1"' "$ROOT" "$TARGET" )
  [ "$out" = pending ] || fail "fm_backend_composer_state should route tern to its classifier, got '$out'"
  pass "fm_backend_composer_state: routes tern to the tern composer classifier"
}

# --- native state (busy_state / native_state) ---------------------------------------------------------

test_busy_state_maps_native_agent_state() {
  local dir out state want lua_call
  for state in 'working:busy' 'idle:idle' 'waiting_input:blocked'; do
    want=${state#*:}; state=${state%%:*}
    dir=$(new_case "busy-$state")
    ls_with_block "$dir" 1
    ctl_ok "$dir" 2
    state_agents "$dir" 3 "$(agent_json "$BLK_NEIGHBOR" idle)" "$(agent_json "$BLK" "$state")"
    process_response "$dir" 4 omp
    out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" )
    [ "$out" = "$want" ] || fail "native state '$state' should map to '$want', got '$out'"
  done
  dir=$(new_case busy-call-shape)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(agent_json "$BLK" idle)"
  run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" >/dev/null
  # One `tern ctl carly lua <program>` per read, with the program as ONE non-empty
  # argument (it holds spaces, so a split would hand tern a truncated program).
  assert_equals "1" "$(count_calls "$dir" "${US}carly${US}lua${US}")" "busy_state should hand Carly its Lua program exactly once per read"
  lua_call=$(grep -aF -- "${US}carly${US}lua${US}" "$dir/log")
  assert_equals "5" "$(printf '%s\n' "$lua_call" | awk -F "$US" '{ print NF }')" "the Lua program must reach tern ctl carly lua as ONE argument"
  [ -n "${lua_call##*"$US"}" ] || fail "the Lua program handed to tern ctl carly lua must not be empty"
  assert_contains "$(cat "$dir/log")" "tern${US}ctl${US}state" "busy_state should read the stored answer with tern ctl state"
  assert_call_order "$dir/log" "${US}lua${US}" "${US}ctl${US}state" "the Lua call must run before the state read"
  pass "fm_backend_tern_busy_state: working->busy, idle->idle, waiting_input->blocked (herdr's vocabulary), picking the entry whose pane equals the block id at 64 bits"
}

test_busy_state_distrusts_busy_over_an_interactive_shell() {
  local dir out
  dir=$(new_case busy-shell-foreground)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(agent_json "$BLK" working)"
  process_response "$dir" 4 bash
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" )
  [ "$out" = unknown ] || fail "a native busy verdict over an interactive-shell foreground is a husk and must read unknown, got '$out'"
  pass "fm_backend_tern_busy_state: a stale 'working' registration over a shell-only block never reads busy"
}

test_busy_state_unknown_without_a_usable_entry() {
  local dir out
  dir=$(new_case busy-no-entry)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(agent_json "$BLK_NEIGHBOR" working)"
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" )
  [ "$out" = unknown ] || fail "no agent entry for the block (only its 64-bit neighbor) should read unknown, got '$out'"

  dir=$(new_case busy-dead-entry)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(agent_json "$BLK" working false)"
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" )
  [ "$out" = unknown ] || fail "an entry with alive:false should read unknown, got '$out'"

  dir=$(new_case busy-malformed)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_text "$dir" 3 '→ {not json'
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" )
  [ "$out" = unknown ] || fail "malformed ctl state text should read unknown, got '$out'"

  dir=$(new_case busy-no-arrow)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_text "$dir" 3 "$(agent_json "$BLK" idle)"
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" )
  [ "$out" = unknown ] || fail "ctl state text that is not an array answer should read unknown, got '$out'"
  pass "fm_backend_tern_busy_state: no entry, alive:false, malformed or non-array answers all read unknown"
}

test_busy_state_strips_fresh_lua_state_banner() {
  local dir out
  dir=$(new_case busy-banner)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_text "$dir" 3 $'(fresh Lua state - previous locals discarded)\n→ ['"$(agent_json "$BLK" idle)"']'
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" )
  [ "$out" = idle ] || fail "a leading fresh-Lua-state banner line must be tolerated, got '$out'"
  pass "fm_backend_tern_busy_state: tolerates the optional fresh-Lua-state banner above the arrow line"
}

test_busy_state_degrades_to_unknown_when_ctl_is_down() {
  local dir out status
  dir=$(new_case busy-ctl-down)
  ls_with_block "$dir" 1
  ctl_down "$dir" 2
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "a missing Tern window must never fail busy_state"
  [ "$out" = unknown ] || fail "busy_state should degrade to unknown when tern ctl has no window (and print nothing else), got '$out'"
  assert_not_contains "$(cat "$dir/log")" "tern${US}ctl${US}state" "after the first ctl failure the state read is pointless and must be skipped"

  dir=$(new_case busy-ctl-state-down)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  ctl_down "$dir" 3
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" 2>&1 )
  [ "$out" = unknown ] || fail "a failing ctl state read should degrade to unknown, got '$out'"
  pass "fm_backend_tern_busy_state: no Tern window / failing tern ctl degrades to unknown, never an error"
}

test_native_state_bounds_a_hung_ctl_endpoint() {
  local dir out started elapsed
  dir=$(new_case native-ctl-hang)
  ls_with_block "$dir" 1
  started=$SECONDS
  out=$( FM_TERN_FAKE_CTL_HANG=1 FM_BACKEND_TERN_CTL_TIMEOUT=1 run_tern "$dir" 'fm_backend_tern_native_state "$1"' "$TARGET" 2>&1 )
  elapsed=$((SECONDS - started))
  [ "$out" = unknown ] || fail "a hung tern ctl should degrade to unknown, got '$out'"
  [ "$elapsed" -lt 20 ] || fail "native_state must bound a hung tern ctl by FM_BACKEND_TERN_CTL_TIMEOUT, took ${elapsed}s"
  pass "fm_backend_tern_native_state: a hung control endpoint is bounded by FM_BACKEND_TERN_CTL_TIMEOUT and reads unknown"
}

test_native_state_reports_each_vocabulary_word() {
  local dir out state
  for state in working idle waiting_input; do
    dir=$(new_case "native-$state")
    ls_with_block "$dir" 1
    ctl_ok "$dir" 2
    state_agents "$dir" 3 "$(agent_json "$BLK" "$state")"
    out=$( run_tern "$dir" 'fm_backend_tern_native_state "$1"' "$TARGET" )
    [ "$out" = "$state" ] || fail "native_state should report '$state', got '$out'"
  done
  dir=$(new_case native-absent-block)
  ls_without_block "$dir" 1
  out=$( run_tern "$dir" 'fm_backend_tern_native_state "$1"' "$TARGET" )
  [ "$out" = unknown ] || fail "native_state for a block missing from the inventory should read unknown, got '$out'"
  assert_not_contains "$(cat "$dir/log")" "${US}ctl${US}" "native_state must not ask the window about a block it could not verify"
  pass "fm_backend_tern_native_state: working|idle|waiting_input from the projected agent list after one inventory check, unknown for an unverified block"
}

# The answer slot stores DISPLAY text, so a whole `cx.agents:list()` entry reaches it with
# its free text's raw newlines inside JSON strings, which no JSON parser accepts: on a live
# window that made every native read unknown. The adapter therefore asks for a projection
# with no free text (FM_BACKEND_TERN_AGENTS_LUA). Because the fake never runs that program,
# these two cases pin the adapter's side of the contract: what an unparseable displayed
# answer does to its callers, and what the projected answer of the same agents yields.

test_native_state_reads_unknown_for_a_displayed_answer_with_a_raw_control_character() {
  local dir out status
  dir=$(new_case displayed-free-text-agents-json)
  ctl_ok "$dir" 1
  state_agents "$dir" 2 "$(displayed_agent_json "$BLK" working "$NL")"
  out=$( run_tern "$dir" 'fm_backend_tern_agents_json' )
  status=$?
  [ "$status" -ne 0 ] || fail "an answer with a raw newline inside a string is not JSON and must fail agents_json, got: $out"
  [ -z "$out" ] || fail "a failed agents_json must print nothing, got: $out"

  dir=$(new_case displayed-free-text-native-state)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(displayed_agent_json "$BLK_NEIGHBOR" idle "$NL")" "$(displayed_agent_json "$BLK" working "$NL")"
  out=$( run_tern "$dir" 'fm_backend_tern_native_state "$1"' "$TARGET" 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "an unparseable displayed answer must never fail native_state"
  [ "$out" = unknown ] || fail "native_state should read unknown, and print nothing else, for an answer holding a raw newline inside a string, got '$out'"

  dir=$(new_case displayed-free-text-busy-state)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(displayed_agent_json "$BLK_NEIGHBOR" idle "$NL")" "$(displayed_agent_json "$BLK" working "$NL")"
  out=$( run_tern "$dir" 'fm_backend_tern_busy_state "$1"' "$TARGET" 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "an unparseable displayed answer must never fail busy_state"
  [ "$out" = unknown ] || fail "busy_state should read unknown, and print nothing else, for an answer holding a raw newline inside a string, got '$out'"

  # The same entries with the newline ESCAPED are valid JSON and read normally, so the raw
  # control character (not the free-text fields themselves) is what the adapter cannot read
  # and the cases above cannot pass for any other reason.
  dir=$(new_case displayed-escaped-free-text-native-state)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(displayed_agent_json "$BLK_NEIGHBOR" idle '\n')" "$(displayed_agent_json "$BLK" working '\n')"
  out=$( run_tern "$dir" 'fm_backend_tern_native_state "$1"' "$TARGET" )
  [ "$out" = working ] || fail "the same entries with the newline escaped are valid JSON and should read 'working', got '$out'"
  pass "fm_backend_tern_native_state/busy_state: a displayed answer with a raw newline inside a string fails agents_json and reads unknown without failing the caller, while the same entries with it escaped read normally"
}

test_native_state_parses_the_projected_answer_and_keeps_64_bit_ids() {
  local dir out rows
  dir=$(new_case projected-agents-json)
  ctl_ok "$dir" 1
  state_agents "$dir" 2 "$(agent_json "$BLK_NEIGHBOR" idle)" "$(agent_json "$BLK" working)"
  out=$( run_tern "$dir" 'fm_backend_tern_agents_json' ) || fail "the projected answer of pane ids, states and alive flags must read as an agent array"
  rows=$(printf '%s' "$out" | jq -r '.[] | [.state, .pane] | join(" ")') \
    || fail "agents_json must print a JSON agent array, got: $out"
  assert_equals "idle $BLK_NEIGHBOR"$'\n'"working $BLK" "$rows" \
    "every pane id of the projected entries must come back as its exact decimal string (a JSON double would round them)"

  dir=$(new_case projected-native-state)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(agent_json "$BLK_NEIGHBOR" idle)" "$(agent_json "$BLK" working)"
  out=$( run_tern "$dir" 'fm_backend_tern_native_state "$1"' "$TARGET" )
  [ "$out" = working ] || fail "the projected answer should read the block's own 'working' state, not its 64-bit neighbor's 'idle', got '$out'"

  # Newlines BETWEEN JSON tokens are valid; only one inside a string is unreadable.
  dir=$(new_case projected-multiline-native-state)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_text "$dir" 3 "→ [${NL}  $(agent_json "$BLK_NEIGHBOR" idle),${NL}  $(agent_json "$BLK" working)${NL}]"
  out=$( run_tern "$dir" 'fm_backend_tern_native_state "$1"' "$TARGET" )
  [ "$out" = working ] || fail "an answer laid out over several lines (newlines between tokens, none inside a string) is valid JSON and should read 'working', got '$out'"
  pass "fm_backend_tern_native_state: the projected answer parses (also laid out over several lines), every id survives as an exact decimal string, and the entry whose pane equals the block id supplies the state"
}

test_dispatch_busy_state_routes_tern() {
  local dir out
  dir=$(new_case dispatch-busy)
  ls_with_block "$dir" 1
  ctl_ok "$dir" 2
  state_agents "$dir" 3 "$(agent_json "$BLK" idle)"
  out=$( PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_busy_state tern "$1"' "$ROOT" "$TARGET" )
  [ "$out" = idle ] || fail "fm_backend_busy_state should route tern to its native reader, got '$out'"
  pass "fm_backend_busy_state: routes tern to the native agent-state reader"
}

# --- agent_state ------------------------------------------------------------------------------------

test_agent_state_classifies_the_foreground_process() {
  local dir out
  dir=$(new_case agent-alive)
  ls_with_block "$dir" 1
  process_response "$dir" 2 omp
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = alive ] || fail "an omp foreground should read alive, got '$out'"

  dir=$(new_case agent-dead-shell)
  ls_with_block "$dir" 1
  process_response "$dir" 2 bash '["bash"]'
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = dead ] || fail "an idle interactive shell foreground should read dead, got '$out'"

  dir=$(new_case agent-dead-shell-rcfile)
  ls_with_block "$dir" 1
  process_response "$dir" 2 bash '["/bin/bash","--rcfile","/home/u/.cache/stencil-term/shell-integration/bash/kitty.bash"]'
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = dead ] || fail "an interactive shell started with Tern's --rcfile shell integration should read dead, got '$out'"

  dir=$(new_case agent-ambiguous-shell-rcfile-script)
  ls_with_block "$dir" 1
  process_response "$dir" 2 bash '["bash","--init-file","/etc/rc","job.sh"]'
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = ambiguous ] || fail "a shell running a script after an --init-file value should read ambiguous, got '$out'"

  dir=$(new_case agent-ambiguous-shell-c)
  ls_with_block "$dir" 1
  process_response "$dir" 2 bash '["bash","-c","sleep 100"]'
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = ambiguous ] || fail "a shell running a -c command cannot be attributed and should read ambiguous, got '$out'"

  dir=$(new_case agent-ambiguous-other)
  ls_with_block "$dir" 1
  process_response "$dir" 2 python3 '["python3","job.py"]'
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = ambiguous ] || fail "an unrelated foreground process should read ambiguous, got '$out'"
  pass "fm_backend_tern_agent_state: agent foreground -> alive, idle shell (incl. --rcfile) -> dead, shell -c / unrelated process -> ambiguous"
}

test_agent_state_missing_dead_and_unreadable() {
  local dir out
  dir=$(new_case agent-missing)
  ls_without_block "$dir" 1
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = missing ] || fail "a block absent from a successful inventory should read missing, got '$out'"
  assert_not_contains "$(cat "$dir/log")" "${US}process${US}" "a missing block has no process to read"

  dir=$(new_case agent-moved)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-unit "$(tab_json "$TAB" null "$(block_json 4242)")")" \
    "$(session_json "$SID2" fm-test-other "$(tab_json 9007199254741001 null "$(block_json "$BLK")")")"
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = ambiguous ] || fail "a block that now lives in another session contradicts the endpoint and should read ambiguous, got '$out'"

  dir=$(new_case agent-exited)
  ls_with_block "$dir" 1 40 false
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = dead ] || fail "an exited keep-open block has no agent and should read dead, got '$out'"

  dir=$(new_case agent-ls-fails)
  printf '1\n' > "$dir/responses/1.exit"
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = unreadable ] || fail "an unreadable inventory must never read missing (that would license recovery), got '$out'"

  dir=$(new_case agent-process-fails)
  ls_with_block "$dir" 1
  printf '1\n' > "$dir/responses/2.exit"
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' "$TARGET" )
  [ "$out" = unreadable ] || fail "a failing tern process read should read unreadable, got '$out'"

  dir=$(new_case agent-bad-target)
  out=$( run_tern "$dir" 'fm_backend_tern_agent_state "$1"' 'Default:4' )
  [ "$out" = unreadable ] || fail "a malformed target should read unreadable, got '$out'"
  pass "fm_backend_tern_agent_state: missing only from a good inventory; exited -> dead; moved -> ambiguous; unreadable on any failed read"
}

test_dispatch_agent_state_routes_tern() {
  local dir out
  dir=$(new_case dispatch-agent-state)
  ls_with_block "$dir" 1
  process_response "$dir" 2 omp
  out=$( PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tern "$1"' "$ROOT" "$TARGET" )
  [ "$out" = alive ] || fail "fm_backend_agent_state should route tern to its process classifier, got '$out'"
  pass "fm_backend_agent_state: routes tern to the tern process classifier"
}

# --- kill -----------------------------------------------------------------------------------------------

test_kill_closes_the_block_by_numeric_id() {
  local dir
  dir=$(new_case kill-block)
  ls_with_block "$dir" 1
  run_tern "$dir" 'fm_backend_tern_kill "$1"' "$TARGET" || fail "kill should succeed"
  grep -qFx "tern${US}close${US}$SEL" "$dir/log" || fail "kill should close the block through the one-session selector '<session-id>/<block-id>', got: $(cat "$dir/log")"
  assert_equals "1" "$(grep -c "${US}close${US}" "$dir/log")" "kill should close exactly one block"
  assert_not_contains "$(cat "$dir/log")" "${US}kill${US}" "kill must never kill the whole session (it may hold other tasks)"
  pass "fm_backend_tern_kill: closes exactly the task block by numeric id, never the session"
}

test_kill_is_idempotent_when_block_is_gone() {
  local dir
  dir=$(new_case kill-gone)
  ls_without_block "$dir" 1
  run_tern "$dir" 'fm_backend_tern_kill "$1"' "$TARGET"
  expect_code 0 $? "kill on an already-gone block must succeed"
  assert_not_contains "$(cat "$dir/log")" "${US}close${US}" "kill must not close anything when the block is already absent"
  # A second kill after a successful close is the same absence.
  dir=$(new_case kill-twice)
  ls_with_block "$dir" 1
  ls_without_block "$dir" 3
  run_tern "$dir" 'fm_backend_tern_kill "$1" && fm_backend_tern_kill "$1"' "$TARGET"
  expect_code 0 $? "a second kill after a close must still succeed"
  assert_equals "1" "$(grep -c "${US}close${US}" "$dir/log")" "only the first kill should issue a close"
  pass "fm_backend_tern_kill: 0 when the block is already gone, and repeatable"
}

test_kill_refuses_to_guess_when_the_inventory_is_unreadable() {
  local dir status
  dir=$(new_case kill-ls-fails)
  printf '1\n' > "$dir/responses/1.exit"
  run_tern "$dir" 'fm_backend_tern_kill "$1"' "$TARGET" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "kill must not report success when it cannot tell whether the block still exists"
  assert_not_contains "$(cat "$dir/log")" "${US}close${US}" "kill must not close blind when the inventory is unreadable"
  pass "fm_backend_tern_kill: an unreadable inventory fails instead of claiming the block is gone"
}

test_kill_distinguishes_failed_close_from_gone() {
  local dir status
  dir=$(new_case kill-close-fails-still-there)
  ls_with_block "$dir" 1
  printf '1\n' > "$dir/responses/2.exit"
  ls_with_block "$dir" 3
  run_tern "$dir" 'fm_backend_tern_kill "$1"' "$TARGET" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "kill must fail when close failed and the block is still listed"

  dir=$(new_case kill-close-fails-but-gone)
  ls_with_block "$dir" 1
  printf '1\n' > "$dir/responses/2.exit"
  ls_without_block "$dir" 3
  run_tern "$dir" 'fm_backend_tern_kill "$1"' "$TARGET" >/dev/null 2>&1
  expect_code 0 $? "kill should succeed when close raced a user closing the block and it is now gone"
  pass "fm_backend_tern_kill: a failed close is success only when a fresh inventory shows the block gone"
}

test_kill_refuses_a_block_that_moved_to_another_session() {
  local dir status
  dir=$(new_case kill-moved)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-unit "$(tab_json "$TAB" null "$(block_json 4242)")")" \
    "$(session_json "$SID2" fm-test-other "$(tab_json 9007199254741001 null "$(block_json "$BLK")")")"
  run_tern "$dir" 'fm_backend_tern_kill "$1"' "$TARGET" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "kill must not claim success for a block that now lives in a different session"
  assert_not_contains "$(cat "$dir/log")" "${US}close${US}" "kill must not close a block that is no longer in the recorded session"
  pass "fm_backend_tern_kill: refuses (and closes nothing) when the block id now belongs to another session"
}

test_kill_refuses_a_block_whose_tab_was_renamed() {
  local dir status
  dir=$(new_case kill-label-mismatch)
  ls_with_block "$dir" 1 40 true "not-the-task"
  run_tern "$dir" 'fm_backend_tern_kill "$1" "" fm-label' "$TARGET" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "kill must not claim success for a still-listed block whose tab no longer carries the task's title"
  assert_not_contains "$(cat "$dir/log")" "${US}close${US}" "kill must not close a block whose tab is not the expected task's"
  pass "fm_backend_tern_kill: refuses (and closes nothing) when the block's tab no longer carries the task's title"
}

# --- list_live -----------------------------------------------------------------------------------------------

test_list_live_lists_only_this_homes_task_tabs() {
  local dir out title other_title
  dir=$(new_case list-live)
  title=$(tern_expected_title fm-task1)
  other_title=$(tern_expected_title fm-task2 "$ROOT" "$TMP_ROOT")
  ls_write "$dir" 1 \
    "$(session_json "$SID" fm-test-ctr "$(tab_json "$TAB" "$title" "$(block_json "$BLK")")" "$(tab_json 9007199254741001 "$other_title" "$(block_json 9007199254741003)")" "$(tab_json 9007199254741005 zsh "$(block_json 9007199254741007)")")" \
    "$(session_json "$SID2" Default "$(tab_json 9007199254741009 "$title" "$(block_json 9007199254741011)")")"
  out=$( FM_TERN_SESSION=fm-test-ctr run_tern "$dir" 'fm_backend_tern_list_live' )
  [ "$out" = "$SID:$BLK"$'\t'fm-task1 ] || fail "list_live should list only this home's task tab with its plain label, got '$out'"
  pass "fm_backend_tern_list_live: lists only this home's scoped task tabs in its own session, as plain fm-<id> labels"
}

# --- dispatcher wiring ------------------------------------------------------------------------------------------

test_dispatch_visible_capture_routes_tern() {
  local dir out
  dir=$(new_case dispatch-visible)
  ls_with_block "$dir" 1 1
  capture_ok "$dir" 2 $'a\nb'
  out=$( PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_visible_capture tern "$1"' "$ROOT" "$TARGET" )
  [ "$out" = b ] || fail "fm_backend_visible_capture should route tern to its viewport read, got '$out'"
  pass "fm_backend_visible_capture: routes tern to the viewport read"
}

test_dispatch_target_exists_routes_tern() {
  local dir
  dir=$(new_case dispatch-target-exists)
  ls_with_block "$dir" 1
  PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists tern "$1"' "$ROOT" "$TARGET" \
    || fail "fm_backend_target_exists should be true for a listed tern block"
  dir=$(new_case dispatch-target-gone)
  ls_without_block "$dir" 1
  PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists tern "$1"' "$ROOT" "$TARGET" \
    && fail "fm_backend_target_exists should be false for an unlisted tern block"
  assert_not_contains "$(cat "$dir/log")" "${US}new${US}" "target_exists is read-only and must never create anything"
  pass "fm_backend_target_exists: tern is a read-only inventory check"
}

test_dispatch_send_key_capture_and_kill_route_tern() {
  local dir
  dir=$(new_case dispatch-send-kill)
  ls_with_block "$dir" 1
  ls_with_block "$dir" 3
  ls_with_block "$dir" 5
  PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_key tern "$1" Escape; fm_backend_capture tern "$1" 3 >/dev/null; fm_backend_kill tern "$1"' "$ROOT" "$TARGET" \
    || fail "dispatcher send_key/capture/kill should succeed for tern"
  assert_contains "$(cat "$dir/log")" "${US}send${US}$SEL${US}keys${US}escape" "fm_backend_send_key did not route tern"
  assert_contains "$(cat "$dir/log")" "${US}capture${US}$SEL${US}--scrollback${US}--surfaces" "fm_backend_capture did not route tern"
  assert_contains "$(cat "$dir/log")" "${US}close${US}$SEL" "fm_backend_kill did not route tern"
  pass "fm_backend dispatcher: send_key, capture and kill route to the tern adapter"
}

# --- send_text_submit --------------------------------------------------------------------------
#
# Call order (see bin/backends/tern.sh): a native baseline read first (ctl lua,
# ctl state), then send_literal (ls, send text); with a readable baseline each
# Enter is send_key (ls, send keys enter) followed by native polls and, when
# those are inconclusive, a composer read (ls, capture --surfaces). With an
# unreadable baseline the whole attempt is the shared composer retry loop.
# FM_BACKEND_TERN_SUBMIT_POLLS=1 and FM_BACKEND_TERN_SUBMIT_MIN_SLEEP=0 keep
# every call count exact.

# ctl_pair <dir> <n> <state>: calls <n> (carly lua ack) and <n>+1 (ctl state)
# answering with one agent entry for the fixture block in <state>.
ctl_pair() {
  ctl_ok "$1" "$2"
  state_agents "$1" "$(($2 + 1))" "$(agent_json "$BLK" "$3")"
}

# run_submit <dir> <text> <retries> [label]: send_text_submit with exact, tiny sleeps.
run_submit() {
  local dir=$1 text=$2 retries=$3 label=${4:-}
  FM_BACKEND_TERN_SUBMIT_POLLS=1 FM_BACKEND_TERN_SUBMIT_MIN_SLEEP=0 \
    run_tern "$dir" 'fm_backend_tern_send_text_submit "$1" "$2" "$3" 0.01 0.01 "$4"' "$TARGET" "$text" "$retries" "$label"
}

test_send_text_submit_confirms_idle_to_working_transition() {
  local dir out
  dir=$(new_case submit-native-landed)
  ctl_pair "$dir" 1 idle            # 1-2: baseline idle
                                    # 3-4: literal (ls, send text)
                                    # 5-6: Enter (ls, send keys enter)
  ls_with_block "$dir" 3
  ls_with_block "$dir" 5
  ctl_pair "$dir" 7 working         # 7-8: poll sees the idle -> working transition
  out=$( run_submit "$dir" "hello captain" 3 )
  [ "$out" = empty ] || fail "an idle -> working transition after Enter should confirm the submit, got '$out'"
  assert_equals "1" "$(grep -c "${US}text${US}hello captain" "$dir/log")" "the text must be typed exactly once"
  assert_equals "1" "$(grep -c "${US}keys${US}enter" "$dir/log")" "one Enter is enough when the native state confirms it"
  assert_not_contains "$(cat "$dir/log")" "${US}capture${US}" "a native confirmation must not need a screen read"
  assert_call_order "$dir/log" "${US}text${US}hello captain" "${US}keys${US}enter" "the text must be typed before Enter"
  pass "fm_backend_tern_send_text_submit: a native idle -> working transition confirms delivery without reading the screen"
}

test_send_text_submit_counts_waiting_input_as_landed() {
  local dir out
  dir=$(new_case submit-native-waiting)
  ctl_pair "$dir" 1 idle
  ls_with_block "$dir" 3
  ls_with_block "$dir" 5
  ctl_pair "$dir" 7 waiting_input
  out=$( run_submit "$dir" "hello captain" 3 )
  [ "$out" = empty ] || fail "a turn that reached a human prompt (waiting_input) after Enter has been delivered, got '$out'"
  pass "fm_backend_tern_send_text_submit: waiting_input after Enter counts as a landed submit"
}

test_send_text_submit_idle_agent_falls_through_to_composer_and_retries_enter_only() {
  local dir out
  dir=$(new_case submit-native-idle-pending)
  ctl_pair "$dir" 1 idle
  ls_with_block "$dir" 3
  ls_with_block "$dir" 5            # Enter 1
  ctl_pair "$dir" 7 idle            # still idle: inconclusive
  ls_with_block "$dir" 9            # composer read
  capture_ok "$dir" 10 "$screen_pending"
  ls_with_block "$dir" 11           # Enter 2
  ctl_pair "$dir" 13 idle
  ls_with_block "$dir" 15
  capture_ok "$dir" 16 "$screen_pending"
  ctl_pair "$dir" 17 idle           # final queued-Enter check: idle -> the text is really still pending
  out=$( run_submit "$dir" "hello captain" 2 )
  [ "$out" = pending ] || fail "an idle agent whose composer still holds the text must report pending, got '$out'"
  assert_equals "1" "$(grep -c "${US}text${US}hello captain" "$dir/log")" "retries must never retype the text"
  assert_equals "2" "$(grep -c "${US}keys${US}enter" "$dir/log")" "retries press Enter only, once per attempt"
  pass "fm_backend_tern_send_text_submit: an inconclusive native read falls back to the composer; retries press Enter only and never retype"
}

test_send_text_submit_busy_agent_queued_enter_is_delivered() {
  local dir out
  dir=$(new_case submit-native-busy-queued)
  ctl_pair "$dir" 1 working         # the agent is mid-turn when the message arrives
  ls_with_block "$dir" 3
  ls_with_block "$dir" 5            # Enter
  ls_with_block "$dir" 7            # composer read: the text is queued in the composer
  capture_ok "$dir" 8 "$screen_pending"
  ctl_pair "$dir" 9 working         # still working: the Enter was queued by the busy agent
  out=$( run_submit "$dir" "hello captain" 1 )
  [ "$out" = empty ] || fail "a pending composer under a working agent is a queued (delivered) Enter, got '$out'"
  assert_equals "1" "$(grep -c "${US}keys${US}enter" "$dir/log")" "a queued Enter must not be pressed again"
  pass "fm_backend_tern_send_text_submit: a busy agent's queued Enter counts as delivered (shared queued-Enter policy)"
}

test_send_text_submit_without_native_state_uses_the_composer_loop() {
  local dir out
  dir=$(new_case submit-composer-landed)
  ctl_down "$dir" 1                 # 1: baseline lua fails; the state read is skipped
  ls_with_block "$dir" 2            # 2-3: literal
  ls_with_block "$dir" 4            # 4-5: Enter
  ls_with_block "$dir" 6            # 6-7: composer read
  capture_ok "$dir" 7 "$screen_empty"
  out=$( run_submit "$dir" "hello captain" 3 )
  [ "$out" = empty ] || fail "with no native state, an empty composer after Enter confirms the submit, got '$out'"
  assert_equals "1" "$(grep -c "${US}keys${US}enter" "$dir/log")" "a plain message needs a single Enter"
  assert_equals "1" "$(grep -c "${US}ctl${US}" "$dir/log")" "after the baseline failed there must be no further ctl calls"
  pass "fm_backend_tern_send_text_submit: no control endpoint degrades to the shared composer loop"
}

# The popup-placeholder class (mirrors tests/fm-backend-cmux.test.sh): Enter 1
# closes a popup and fills a placeholder (still pending), Enter 2 submits.
test_send_text_submit_without_native_state_retries_past_a_popup_enter() {
  local dir out
  dir=$(new_case submit-composer-popup)
  ctl_down "$dir" 1
  ls_with_block "$dir" 2            # literal
  ls_with_block "$dir" 4            # Enter 1
  ls_with_block "$dir" 6            # composer: pending
  capture_ok "$dir" 7 $'  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions   │\n  ╰──────────────── Composer ────────────╯\n\n  Enter:send'
  ls_with_block "$dir" 8            # Enter 2
  ls_with_block "$dir" 10           # composer: empty
  capture_ok "$dir" 11 "$screen_empty"
  out=$( run_submit "$dir" "/compact" 3 )
  [ "$out" = empty ] || fail "the SECOND Enter should clear the composer and report empty, got '$out'"
  assert_equals "2" "$(grep -c "${US}keys${US}enter" "$dir/log")" "exactly two Enters (popup-close, then the real submit)"
  assert_equals "1" "$(grep -c "${US}text${US}/compact" "$dir/log")" "the text is typed once"
  assert_not_contains "$(cat "$dir/log")" "compaction instructions" "the placeholder text must never be retyped"
  pass "fm_backend_tern_send_text_submit: retries past a popup-placeholder-fill Enter and lands the real second Enter"
}

test_send_text_submit_without_native_state_reports_a_swallowed_enter() {
  local dir out
  dir=$(new_case submit-composer-swallowed)
  ctl_down "$dir" 1
  ls_with_block "$dir" 2
  ls_with_block "$dir" 4
  ls_with_block "$dir" 6
  capture_ok "$dir" 7 "$screen_pending"
  ls_with_block "$dir" 8
  ls_with_block "$dir" 10
  capture_ok "$dir" 11 "$screen_pending"
  out=$( run_submit "$dir" "hello captain" 2 )
  [ "$out" = pending ] || fail "retries exhausted with the text still in the composer must report pending, got '$out'"
  assert_equals "1" "$(grep -c "${US}text${US}hello captain" "$dir/log")" "a swallowed Enter must never cause a retype"
  assert_equals "2" "$(grep -c "${US}keys${US}enter" "$dir/log")" "two Enter attempts for retries=2"
  pass "fm_backend_tern_send_text_submit: a swallowed Enter reports pending after the Enter-only retries"
}

test_send_text_submit_retries_a_failed_enter_without_retyping() {
  local dir out
  dir=$(new_case submit-enter-fails-once)
  ctl_pair "$dir" 1 idle
  ls_with_block "$dir" 3            # literal
  ls_with_block "$dir" 5            # Enter 1: ls ok ...
  printf '1\n' > "$dir/responses/6.exit"   # ... send keys fails
  ls_with_block "$dir" 7            # Enter 2
  ctl_pair "$dir" 9 working
  out=$( run_submit "$dir" "hello captain" 2 )
  [ "$out" = empty ] || fail "a failed first Enter followed by a good one should confirm, got '$out'"
  assert_equals "1" "$(grep -c "${US}text${US}hello captain" "$dir/log")" "a failed Enter must be retried as an Enter, never by retyping"
  assert_equals "2" "$(grep -c "${US}keys${US}enter" "$dir/log")" "the Enter is attempted twice"

  dir=$(new_case submit-enter-always-fails)
  ctl_pair "$dir" 1 idle
  ls_with_block "$dir" 3
  ls_with_block "$dir" 5
  printf '1\n' > "$dir/responses/6.exit"
  out=$( run_submit "$dir" "hello captain" 1 )
  [ "$out" = send-failed ] || fail "an Enter that never went out must report send-failed (not a confirmed or pending submit), got '$out'"
  pass "fm_backend_tern_send_text_submit: a failing Enter is retried as Enter only, and reported send-failed when it never lands"
}

test_send_text_submit_send_failed_when_target_absent() {
  local dir out
  dir=$(new_case submit-no-target)
  ctl_down "$dir" 1
  ls_without_block "$dir" 2
  out=$( run_submit "$dir" "x" 2 )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the block is absent, got '$out'"
  assert_not_contains "$(cat "$dir/log")" "${US}keys${US}" "no key may be sent to an absent block"
  pass "fm_backend_tern_send_text_submit: reports 'send-failed' when the block is absent"
}

test_dispatch_send_text_submit_routes_tern() {
  local dir out
  dir=$(new_case dispatch-submit)
  # The dispatcher reads the composer once BEFORE the adapter types (dialog guard):
  # 1-2: ls + capture (empty composer). Then the adapter: 3-4 baseline, 5-6 literal,
  # 7-8 Enter, 9-10 native poll.
  ls_with_block "$dir" 1
  capture_ok "$dir" 2 "$screen_empty"
  ctl_pair "$dir" 3 idle
  ls_with_block "$dir" 5
  ls_with_block "$dir" 7
  ctl_pair "$dir" 9 working
  out=$( FM_BACKEND_TERN_SUBMIT_POLLS=1 FM_BACKEND_TERN_SUBMIT_MIN_SLEEP=0 PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text_submit tern "$1" "hello captain" 3 0.01 0.01' "$ROOT" "$TARGET" )
  [ "$out" = empty ] || fail "fm_backend_send_text_submit should route tern to its submit confirmation, got '$out'"
  assert_equals "1" "$(grep -c "${US}text${US}hello captain" "$dir/log")" "the dispatcher must hand the text to the adapter exactly once"
  pass "fm_backend_send_text_submit: routes tern to the native-confirming submit"
}

# --- endpoint validation (fm_backend_validate_task_endpoint) ---------------------------------------------------------

write_tern_meta() {  # <dir> <id> [key=value ...]  - a complete valid record, then overrides appended by caller
  local dir=$1 id=$2
  shift 2
  mkdir -p "$dir/state"
  fm_write_meta "$dir/state/$id.meta" \
    "window=$SID:$BLK" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=tern" "tern_session_id=$SID" "tern_tab_id=$TAB" "tern_block_id=$BLK" "$@"
}

test_endpoint_validation_accepts_a_complete_tern_record() {
  local dir
  dir="$TMP_ROOT/endpoint-ok"
  write_tern_meta "$dir" t1
  fm_backend_validate_task_endpoint "$dir/state/t1.meta" t1 || fail "a complete tern endpoint record should validate"
  [ "$FM_BACKEND_VALIDATED_BACKEND" = tern ] || fail "validation should report backend tern, got '$FM_BACKEND_VALIDATED_BACKEND'"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$SID:$BLK" ] || fail "validation should report the exact <session-id>:<block-id>, got '$FM_BACKEND_VALIDATED_TARGET'"
  pass "fm_backend_validate_task_endpoint: a complete tern record validates and keeps 64-bit ids byte-exact"
}

test_endpoint_validation_refuses_unsafe_tern_records() {
  local dir case_name out status
  while IFS='|' read -r case_name transform; do
    dir="$TMP_ROOT/endpoint-$case_name"
    write_tern_meta "$dir" t1
    case "$transform" in
      drop-binding) grep -v '^endpoint_task_id=' "$dir/state/t1.meta" > "$dir/state/new" ;;
      other-binding) sed 's/^endpoint_task_id=.*/endpoint_task_id=someone-else/' "$dir/state/t1.meta" > "$dir/state/new" ;;
      window-mismatch) sed "s/^window=.*/window=$SID2:$BLK/" "$dir/state/t1.meta" > "$dir/state/new" ;;
      window-reversed) sed "s/^window=.*/window=$BLK:$SID/" "$dir/state/t1.meta" > "$dir/state/new" ;;
      drop-session) grep -v '^tern_session_id=' "$dir/state/t1.meta" > "$dir/state/new" ;;
      drop-tab) grep -v '^tern_tab_id=' "$dir/state/t1.meta" > "$dir/state/new" ;;
      drop-block) grep -v '^tern_block_id=' "$dir/state/t1.meta" > "$dir/state/new" ;;
      title-block) sed 's/^tern_block_id=.*/tern_block_id=Default/;s/^window=.*/window='"$SID"':Default/' "$dir/state/t1.meta" > "$dir/state/new" ;;
      signed-session) sed 's/^tern_session_id=.*/tern_session_id=-5/;s/^window=.*/window=-5:'"$BLK"'/' "$dir/state/t1.meta" > "$dir/state/new" ;;
      overlong-block) sed 's/^tern_block_id=.*/tern_block_id=922337203685477580799/;s/^window=.*/window='"$SID"':922337203685477580799/' "$dir/state/t1.meta" > "$dir/state/new" ;;
      selector-window) sed 's/^window=.*/window=@focused/' "$dir/state/t1.meta" > "$dir/state/new" ;;
      duplicate-block) { cat "$dir/state/t1.meta"; echo "tern_block_id=$BLK_NEIGHBOR"; } > "$dir/state/new" ;;
    esac
    mv "$dir/state/new" "$dir/state/t1.meta"
    out=$(fm_backend_validate_task_endpoint "$dir/state/t1.meta" t1 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "tern endpoint case '$case_name' should be refused"
    assert_contains "$out" "REFUSED" "tern endpoint case '$case_name' did not refuse loudly"
  done <<'CASES'
no-binding|drop-binding
foreign-binding|other-binding
window-session-mismatch|window-mismatch
window-reversed|window-reversed
no-session-id|drop-session
no-tab-id|drop-tab
no-block-id|drop-block
title-as-block|title-block
signed-id|signed-session
overlong-id|overlong-block
selector-window|selector-window
duplicate-block-key|duplicate-block
CASES
  pass "fm_backend_validate_task_endpoint: tern records without an exact binding, with mismatched/non-numeric/overlong/duplicate ids or selector windows are refused"
}

test_secondmate_spawn_refuses_tern_backend() {
  local dir state data config projects out status
  dir="$TMP_ROOT/secondmate-refuse"; state="$dir/state"; data="$dir/data"; config="$dir/config"; projects="$dir/projects"
  mkdir -p "$state" "$data" "$config" "$projects"
  out=$( FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" FM_PROJECTS_OVERRIDE="$projects" \
    "$ROOT/bin/fm-spawn.sh" sm-tern-test --secondmate --backend tern 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh should refuse a --secondmate spawn with --backend tern"
  assert_contains "$out" "does not support --secondmate" "fm-spawn.sh did not report the tern secondmate refusal"
  pass "fm-spawn.sh: refuses backend=tern for --secondmate spawns (no per-home lifecycle design is verified)"
}

test_safety_guard_accepts_only_the_listed_fm_test_session() {
  local dir
  dir=$(new_case safety-accept)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-a "$(tab_json "$TAB" null "$(block_json 4242)")")"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-a' "$SID" || fail "the guard should accept a listed fm-test- session"

  dir=$(new_case safety-default-name)
  ls_write "$dir" 1 "$(session_json 1 Default "$(tab_json 3 null "$(block_json 2)")")"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" Default' 1 2>/dev/null && fail "the guard must refuse a session name without the fm-test- prefix"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-a' 1 2>/dev/null && fail "the guard must refuse a session whose live name is not the expected fm-test- name"

  dir=$(new_case safety-bad-input)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-a "$(tab_json "$TAB" null "$(block_json 4242)")")"
  safety_run "$dir" 'tern_refuse_if_unsafe "" fm-test-a' 2>/dev/null && fail "the guard must refuse an empty id"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-a' 'fm-test-a' 2>/dev/null && fail "the guard must refuse a non-numeric id (names are not ids)"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" ""' "$SID" 2>/dev/null && fail "the guard must refuse an empty name"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-a' "$SID2" 2>/dev/null && fail "the guard must refuse an id that is not listed"
  [ "$(count_calls "$dir" "${US}kill${US}")" -eq 0 ] || fail "the guard itself must never kill anything"

  dir=$(new_case safety-ls-fails)
  printf '1\n' > "$dir/responses/1.exit"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-a' "$SID" 2>/dev/null && fail "the guard must fail closed when tern ls fails"
  pass "tern_refuse_if_unsafe: accepts only a numeric id listed under exactly its fm-test- name; fails closed on empty, non-numeric, foreign, unlisted or unreadable"
}

test_safety_guard_compares_64_bit_ids_exactly() {
  local dir
  dir=$(new_case safety-64-bit)
  ls_write "$dir" 1 "$(session_json 9007199254740992 fm-test-a "$(tab_json "$TAB" null "$(block_json 4242)")")" \
    "$(session_json "$SID" fm-test-b "$(tab_json 9007199254741001 null "$(block_json 4243)")")"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-b' "$SID" || fail "the guard should accept $SID under its own name fm-test-b"
  safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-a' "$SID" 2>/dev/null \
    && fail "the guard must not confuse $SID with its 2^53 neighbor 9007199254740992 (ids must not round to doubles)"
  pass "tern_refuse_if_unsafe: session ids above 2^53 are compared as exact integers"
}

test_safety_guard_never_touches_the_callers_own_session() {
  local dir out
  dir=$(new_case safety-own-block)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-a "$(tab_json "$TAB" null "$(block_json "$BLK")")")"
  out=$( TERN_PANE=$BLK safety_run "$dir" 'tern_refuse_if_unsafe "$1" fm-test-a' "$SID" 2>&1 ) \
    && fail "the guard must refuse a session that hosts the caller's own block (TERN_PANE), even when it is named fm-test-*"
  assert_contains "$out" "own block" "the own-block refusal should say why"
  pass "tern_refuse_if_unsafe: a session hosting \$TERN_PANE is never torn down"
}

test_safe_kill_session_kills_exactly_one_guarded_session() {
  local dir
  dir=$(new_case safety-kill)
  ls_write "$dir" 1 "$(session_json "$SID" fm-test-a "$(tab_json "$TAB" null "$(block_json 4242)")")"
  safety_run "$dir" 'tern_safe_kill_session "$1" fm-test-a' "$SID" || fail "safe_kill_session should succeed for a guarded session"
  assert_contains "$(cat "$dir/log")" "tern${US}kill${US}session${US}$SID" "safe_kill_session should kill by the exact numeric session id"
  assert_equals "1" "$(grep -c "${US}kill${US}" "$dir/log")" "exactly one kill call is allowed"

  dir=$(new_case safety-kill-refused)
  ls_write "$dir" 1 "$(session_json 1 Default "$(tab_json 3 null "$(block_json 2)")")"
  safety_run "$dir" 'tern_safe_kill_session "$1" Default' 1 2>/dev/null && fail "safe_kill_session must refuse Default"
  assert_not_contains "$(cat "$dir/log")" "${US}kill${US}" "a refused guard must issue no kill"
  pass "tern_safe_kill_session: one 'tern kill session <id>' behind the guard, nothing at all when the guard refuses"
}

test_smoke_test_skips_cleanly_without_a_window() {
  # The smoke test's skip contract is exercised without a daemon: with no
  # tern on PATH it must report a skip and exit 0 rather than fail.
  local dir out status
  dir="$TMP_ROOT/smoke-skip-no-tern"; mkdir -p "$dir/empty-bin"
  out=$( PATH="$dir/empty-bin:/usr/bin:/bin" "$ROOT/tests/fm-backend-tern-smoke.test.sh" 2>&1 )
  status=$?
  case "$out" in
    skip:*) : ;;
    *) fail "the smoke test must skip cleanly when tern is not installed, got: $out" ;;
  esac
  expect_code 0 "$status" "the smoke test must exit 0 when it skips"

  # tern present and listing, but no window/control endpoint: still a skip, and
  # nothing is created.
  dir=$(new_case smoke-skip-no-window)
  # Probe order in the smoke test: 1 = tern ls --json (works), 2 = tern ctl state (no window).
  ls_with_block "$dir" 1
  ctl_down "$dir" 2
  out=$( PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" "$ROOT/tests/fm-backend-tern-smoke.test.sh" 2>&1 )
  status=$?
  case "$out" in
    skip:*"control endpoint"*) : ;;
    *) fail "the smoke test must skip when tern ls works but tern ctl has no window, got: $out" ;;
  esac
  expect_code 0 "$status" "the no-window skip must exit 0"
  assert_not_contains "$(cat "$dir/log")" "${US}new${US}" "a skipped smoke test must create nothing"
  assert_not_contains "$(cat "$dir/log")" "${US}kill${US}" "a skipped smoke test must kill nothing"
  assert_not_contains "$(cat "$dir/log")" "${US}close${US}" "a skipped smoke test must close nothing"
  pass "tern smoke test: skips cleanly with no tern, and with a listing daemon but no window control endpoint, touching nothing"
}

# safety_run <dir> <snippet> [args...]: run a snippet with tests/tern-test-safety.sh
# sourced and the fake tern first on PATH.
safety_run() {
  local dir=$1 snippet=$2
  shift 2
  PATH="$dir/fakebin:$PATH" FM_TERN_LOG="$dir/log" FM_TERN_RESPONSES="$dir/responses" \
    bash -c ". \"\$0/tests/tern-test-safety.sh\"; $snippet" "$ROOT" "$@"
}

# --- fm-spawn.sh end to end against a stateful fake tern ------------------------------------
#
# These drive the real bin/fm-spawn.sh with --backend tern against a small
# stateful fake `tern` (it remembers the session, the created tab and its
# title, so the adapter's own read-back and readiness checks run for real), then
# EXECUTE the launch command the block received under a synthetic block
# environment with a probe in place of the harness. What the probe prints is
# what a real agent would have been started with.

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

install_stateful_fake_tern() {  # <fakebin>
  cat > "$1/tern" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_TERN_STATE:?}"
mkdir -p "$S"
SID=9007199254740993
TAB=9007199254740995
BLK=9223372036854775807
if [ "${1:-}" = --version ]; then
  printf 'tern 0.9.4 (fake)\n'
  exit 0
fi
{ printf 'tern'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$S/calls"
cmd=${1:-}
shift
case "$cmd" in
  ls)
    sessions='{"id":1,"name":"Default","shown":true,"tabs":[]}'
    if [ -f "$S/session" ]; then
      tabs='{"id":9007199254740991,"number":1,"name":null,"blocks":[{"id":9007199254740999,"rows":40,"live":true,"exited":null}]}'
      if [ -f "$S/block" ]; then
        title=$(cat "$S/title" 2>/dev/null || true)
        if [ -n "$title" ]; then name="\"$title\""; else name=null; fi
        tabs="$tabs,{\"id\":$TAB,\"number\":2,\"name\":$name,\"blocks\":[{\"id\":$BLK,\"rows\":40,\"live\":true,\"exited\":null}]}"
      fi
      sessions="$sessions,{\"id\":$SID,\"name\":\"$(cat "$S/session")\",\"shown\":false,\"tabs\":[$tabs]}"
    fi
    printf '{"sessions":[%s],"detached":[]}\n' "$sessions"
    ;;
  new)
    case "${1:-}" in
      session) printf '%s' "$2" > "$S/session" ;;
      tab)
        : > "$S/block"
        : > "$S/title"
        printf '{"session":%s,"tab":%s,"block":%s}\n' "$SID" "$TAB" "$BLK"
        ;;
    esac
    ;;
  rename) printf '%s' "$2" > "$S/title" ;;
  run) printf '%s\n' "$2" >> "${FM_FAKE_PANE_LOG:-/dev/null}" ;;
  send)
    if [ "${2:-}" = text ]; then
      a=${3:-}
      case "$a" in
        ". '"*"'")
          staged=${a#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || a=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$a" >> "${FM_FAKE_LAUNCH_LOG:-/dev/null}"
    fi
    ;;
  process)
    printf '{"pane":%s,"child":{"pid":1,"name":"bash","argv":["bash"],"cwd":"/tmp"},"group":1,"foreground":{"pid":2,"name":"bash","argv":["bash"],"cwd":"%s"}}\n' \
      "$BLK" "${FM_FAKE_PANE_PATH:-/tmp}"
    ;;
  close) rm -f "$S/block" ;;
  ctl)
    printf '{"ok":false,"error":"no Tern window on this machine shows this pane"}\n'
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$1/tern"
}

# make_spawn_case <name> <id>: echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>".
make_spawn_case() {
  local name=$1 id=$2 dir home proj wt fakebin
  dir="$TMP_ROOT/spawn-$name"
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  install_stateful_fake_tern "$fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$dir|$home|$proj|$wt|$fakebin"
}

# run_spawn_case <record> <id> [fm-spawn args...]: runs the spawn; sets SPAWN_OUT,
# SPAWN_STATUS, LAUNCH_LOG, PANE_LOG and the case globals.
run_spawn_case() {
  local rec=$1 id=$2
  shift 2
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  SPAWN_OUT=$(FM_TERN_STATE="$CASE_DIR/tern-state" FM_TERN_SESSION=fm-test-spawn-env \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@")
  SPAWN_STATUS=$?
}

# launch_env_report <fakebin> <launch-log> <pane-log> [NAME=value...]: replays the
# emitted pane exports and launch in a synthetic block carrying the given
# environment, with a probe standing in for the harness that prints
# "<NAME>=<value|unset>" for every variable the tests care about.
launch_env_report() {
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  shift 3
  cat > "$fakebin/codex" <<'SH'
#!/bin/sh
for v in TERM_PROGRAM TERN_PANE TERN_PANE_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_IDENTITY SECRET_TOKEN; do
  eval "printf '%s=%s\n' $v \"\${$v-unset}\""
done
SH
  chmod +x "$fakebin/codex"
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm "$@" \
    /bin/sh -c "$preamble
$launch"
}

test_spawn_tern_records_endpoint_metadata() {
  local rec meta
  rec=$(make_spawn_case meta tern-meta-a1)
  run_spawn_case "$rec" tern-meta-a1 --backend tern
  expect_code 0 "$SPAWN_STATUS" "a tern spawn against a healthy fake tern should succeed: $SPAWN_OUT"
  meta="$HOME_DIR/state/tern-meta-a1.meta"
  assert_present "$meta" "a tern spawn must write its task record"
  assert_equals tern "$(fm_meta_get "$meta" backend)" "the record must name the tern backend"
  assert_equals "$SID:$BLK" "$(fm_meta_get "$meta" window)" "window must be the exact <session-id>:<block-id> endpoint"
  assert_equals "$SID" "$(fm_meta_get "$meta" tern_session_id)" "tern_session_id must keep the full 64-bit id"
  assert_equals "$TAB" "$(fm_meta_get "$meta" tern_tab_id)" "tern_tab_id must keep the full 64-bit id"
  assert_equals "$BLK" "$(fm_meta_get "$meta" tern_block_id)" "tern_block_id must keep the full 64-bit id"
  assert_equals tern-meta-a1 "$(fm_meta_get "$meta" endpoint_task_id)" "the endpoint must be bound to its task id"
  fm_backend_validate_task_endpoint "$meta" tern-meta-a1 \
    || fail "the record a tern spawn writes must pass the cleanup endpoint validation"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$SID:$BLK" ] || fail "validation should report the spawned endpoint, got '$FM_BACKEND_VALIDATED_TARGET'"
  assert_contains "$(cat "$CASE_DIR/tern-state/calls")" "new${US}tab${US}$SID${US}--cwd${US}$PROJ_DIR${US}--keep-open${US}--json" \
    "the spawn must open its task as a keep-open tab in the home's session"
  pass "fm-spawn.sh --backend tern: writes backend/window/tern_*_id/endpoint_task_id with exact ids that pass cleanup validation"
}

test_spawn_tern_launch_keeps_tern_environment_under_allowlist() {
  local rec seen
  rec=$(make_spawn_case env-keep tern-env-a1)
  IFS='|' read -r _ HOME_DIR _ _ _ <<EOF
$rec
EOF
  # An empty allowlist is the strictest opt-in: only the operational floor survives.
  : > "$HOME_DIR/config/launch-env-allowlist"
  run_spawn_case "$rec" tern-env-a1 --backend tern
  expect_code 0 "$SPAWN_STATUS" "a tern spawn under an allowlist should succeed: $SPAWN_OUT"
  assert_contains "$(cat "$LAUNCH_LOG")" '/usr/bin/env -i' "an enabled allowlist must launch under a cleared environment"
  seen=$(launch_env_report "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" \
    TERM_PROGRAM=tern TERN_PANE="$BLK" TERN_PANE_SOCKET=/run/tern/pane.sock TERN_WINDOW_KEY=win-key \
    TERN_WINDOW_SOCKET=/run/tern/window.sock TERN_IDENTITY=ident SECRET_TOKEN=leak) \
    || fail "the emitted tern launch failed to run"
  assert_contains "$seen" "TERM_PROGRAM=tern" "a tern task must keep TERM_PROGRAM=tern so the harness's own Tern integration survives"
  assert_contains "$seen" "TERN_PANE=$BLK" "a tern task must keep TERN_PANE byte-exact"
  assert_contains "$seen" "TERN_PANE_SOCKET=/run/tern/pane.sock" "a tern task must keep TERN_PANE_SOCKET"
  assert_contains "$seen" "TERN_WINDOW_KEY=win-key" "a tern task must keep TERN_WINDOW_KEY"
  assert_contains "$seen" "TERN_WINDOW_SOCKET=/run/tern/window.sock" "a tern task must keep TERN_WINDOW_SOCKET"
  assert_contains "$seen" "TERN_IDENTITY=ident" "a tern task must keep TERN_IDENTITY"
  assert_contains "$seen" "SECRET_TOKEN=unset" "an unrelated variable must still be dropped by the allowlist"
  # Unset names stay unset: the floor never invents TERM_PROGRAM.
  seen=$(launch_env_report "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") || fail "the emitted tern launch failed to run in a bare block"
  assert_contains "$seen" "TERM_PROGRAM=unset" "a block without TERM_PROGRAM must not gain one"
  pass "fm-spawn.sh --backend tern: a cleared allowlist launch keeps TERM_PROGRAM and the TERN_* identity, drops the rest, and invents nothing"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

test_parse_target_keeps_full_64_bit_ids
test_parse_target_rejects_malformed_targets
test_malformed_target_never_reaches_the_cli
test_container_ensure_reuses_existing_session
test_container_ensure_creates_missing_session_by_name
test_container_ensure_default_name_is_home_scoped
test_container_ensure_refuses_old_version
test_container_ensure_accepts_double_digit_minor_version
test_container_ensure_fails_when_inventory_unreadable
test_create_task_creates_keep_open_tab_and_renames_it
test_create_task_fails_without_session
test_create_task_fails_on_unparseable_new_tab_output
test_create_task_closes_its_block_when_rename_fails
test_create_task_refuses_a_duplicate_tab_title
test_create_task_fails_when_the_title_does_not_read_back
test_target_ready_requires_the_block_in_that_session
test_target_ready_checks_expected_label
test_capture_passes_surfaces_and_scrollback_and_trims_locally
test_capture_fails_when_capture_fails_or_target_absent
test_visible_capture_is_viewport_only
test_capture_reads_text_from_a_surface_json_object
test_send_literal_types_without_enter
test_send_key_normalizes_firstmate_vocabulary
test_send_key_rejects_label_mismatch
test_send_text_line_is_one_atomic_run
test_current_path_reads_foreground_cwd_passively
test_current_path_is_empty_when_process_read_fails
test_composer_state_verdicts_from_surface_capture
test_dispatch_composer_state_routes_tern
test_busy_state_maps_native_agent_state
test_busy_state_distrusts_busy_over_an_interactive_shell
test_busy_state_unknown_without_a_usable_entry
test_busy_state_strips_fresh_lua_state_banner
test_busy_state_degrades_to_unknown_when_ctl_is_down
test_native_state_bounds_a_hung_ctl_endpoint
test_native_state_reports_each_vocabulary_word
test_native_state_reads_unknown_for_a_displayed_answer_with_a_raw_control_character
test_native_state_parses_the_projected_answer_and_keeps_64_bit_ids
test_dispatch_busy_state_routes_tern
test_agent_state_classifies_the_foreground_process
test_agent_state_missing_dead_and_unreadable
test_dispatch_agent_state_routes_tern
test_kill_closes_the_block_by_numeric_id
test_kill_is_idempotent_when_block_is_gone
test_kill_refuses_to_guess_when_the_inventory_is_unreadable
test_kill_distinguishes_failed_close_from_gone
test_kill_refuses_a_block_that_moved_to_another_session
test_kill_refuses_a_block_whose_tab_was_renamed
test_list_live_lists_only_this_homes_task_tabs
test_dispatch_visible_capture_routes_tern
test_dispatch_target_exists_routes_tern
test_dispatch_send_key_capture_and_kill_route_tern
test_send_text_submit_confirms_idle_to_working_transition
test_send_text_submit_counts_waiting_input_as_landed
test_send_text_submit_idle_agent_falls_through_to_composer_and_retries_enter_only
test_send_text_submit_busy_agent_queued_enter_is_delivered
test_send_text_submit_without_native_state_uses_the_composer_loop
test_send_text_submit_without_native_state_retries_past_a_popup_enter
test_send_text_submit_without_native_state_reports_a_swallowed_enter
test_send_text_submit_retries_a_failed_enter_without_retyping
test_send_text_submit_send_failed_when_target_absent
test_dispatch_send_text_submit_routes_tern
test_endpoint_validation_accepts_a_complete_tern_record
test_endpoint_validation_refuses_unsafe_tern_records
test_secondmate_spawn_refuses_tern_backend
test_spawn_tern_records_endpoint_metadata
test_spawn_tern_launch_keeps_tern_environment_under_allowlist
test_safety_guard_accepts_only_the_listed_fm_test_session
test_safety_guard_compares_64_bit_ids_exactly
test_safety_guard_never_touches_the_callers_own_session
test_safe_kill_session_kills_exactly_one_guarded_session
test_smoke_test_skips_cleanly_without_a_window
