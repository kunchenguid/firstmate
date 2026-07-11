#!/usr/bin/env bash
# tests/fm-backend-zellij.test.sh - fake-zellij-CLI unit tests for the zellij
# session-provider adapter (bin/backends/zellij.sh), P3 of
# data/fm-backend-design-d7 (report.md "Zellij Backend"). Mirrors
# tests/fm-backend-herdr.test.sh's fakebin/command-log convention: a small,
# LOG-based, canned-response fake `zellij` + real `jq` (jq is a real required
# tool for this backend, not faked). The real-binary smoke test lives in
# tests/fm-backend-zellij-smoke.test.sh, gated on the zellij binary actually
# being installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the zellij adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-zellij-tests)

# make_zellij_fakebin: a `zellij` stub that logs every invocation (one line,
# unit-separated args, to $FM_ZELLIJ_LOG) and returns the canned response for
# that call read from $FM_ZELLIJ_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...), mirroring
# tests/fm-backend-herdr.test.sh's make_herdr_fakebin. A missing response file
# means "succeed with empty stdout" (paste/send-keys/close-* are silent on
# success on the real CLI). `--version` and `list-sessions` are handled
# specially (not call-counted) since fm_backend_zellij_session_exists calls
# list-sessions on every op as a passive liveness probe and must not consume
# the ordered response queue - its canned membership is controlled by
# FM_ZELLIJ_SESSION_LIST instead.
make_zellij_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ZELLIJ_LOG:?}"
RESP="${FM_ZELLIJ_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'ZELLIJ_SESSION_NAME=%s' "${ZELLIJ_SESSION_NAME:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = --version ]; then
  printf 'zellij %s\n' "${FM_ZELLIJ_FAKE_VERSION:-0.44.0}"
  exit 0
fi
if [ "${1:-}" = list-sessions ]; then
  printf '%s\n' "${FM_ZELLIJ_SESSION_LIST:-}"
  exit 0
fi
if [ "${1:-}" = attach ]; then
  exit "${FM_ZELLIJ_ATTACH_EXIT:-0}"
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/zellij"
  printf '%s\n' "$fb"
}

zellij_pane_response() {
  local dir=$1 n=$2 pane=${3:-7} tab=${4:-3}
  printf '[{"id":%s,"tab_id":%s,"is_plugin":false}]\n' "$pane" "$tab" > "$dir/responses/$n.out"
}

zellij_tab_response() {
  local dir=$1 n=$2 tab=${3:-3} name=${4:-fm-task}
  printf '[{"tab_id":%s,"name":"%s"}]\n' "$tab" "$name" > "$dir/responses/$n.out"
}

zellij_assert_call_order() {
  local log=$1 before=$2 after=$3 msg=$4 before_line after_line
  before_line=$(grep -anF -- "$before" "$log" | head -1 | cut -d: -f1)
  after_line=$(grep -anF -- "$after" "$log" | head -1 | cut -d: -f1)
  [ -n "$before_line" ] || fail "$msg (missing before call: '$before')"
  [ -n "$after_line" ] || fail "$msg (missing after call: '$after')"
  [ "$before_line" -lt "$after_line" ] || fail "$msg"
}

# zellij_multi_tab_response: a list-tabs --json canned response holding
# several tabs at once (tab_id/name pairs), for ambiguity/foreign-tag tests.
zellij_multi_tab_response() {  # <dir> <n> <tab1> <name1> [<tab2> <name2> ...]
  local dir=$1 n=$2 json first=1
  shift 2
  json='['
  while [ $# -ge 2 ]; do
    [ "$first" -eq 1 ] || json="$json,"
    json="$json{\"tab_id\":$1,\"name\":\"$2\"}"
    first=0
    shift 2
  done
  json="$json]"
  printf '%s' "$json" > "$dir/responses/$n.out"
}

# zellij_expected_home_label / zellij_expected_scoped_title: bash-only
# reimplementations of fm_backend_zellij_home_label/scoped_title (mirroring
# tests/fm-backend-cmux.test.sh's identical cmux_expected_* helpers), used to
# build canned fixtures for the home-scoped tab titles this adapter now
# creates and matches.
zellij_expected_root_hash() {  # <root>
  local root real
  root=$1
  real=$(cd "$root" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

zellij_expected_home_label() {  # [home] [root]
  local home=${1:-$ROOT} root=${2:-$ROOT} marker id prefix
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  printf '%s-%s' "$prefix" "$(zellij_expected_root_hash "$root")"
}

zellij_expected_scoped_title() {  # <fm-task-label> [home] [root]
  local label=$1 home=${2:-$ROOT} root=${3:-$ROOT} rest
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(zellij_expected_home_label "$home" "$root")" "$rest"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_version() {
  local dir fb status
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_FAKE_VERSION=0.44.0 \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept 0.44.0 (the verified minimum)"
  pass "fm_backend_zellij_version_check: accepts the verified minimum (0.44.0)"
}

test_version_check_accepts_newer_version() {
  local dir fb status
  dir="$TMP_ROOT/version-newer"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_FAKE_VERSION=0.45.2 \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept a newer minor (0.45.2)"
  pass "fm_backend_zellij_version_check: accepts a newer version (0.45.2)"
}

test_version_check_refuses_old_version() {
  local dir fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_FAKE_VERSION=0.38.1 \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse 0.38.1 (below the 0.44 minimum)"
  assert_contains "$out" "0.38.1" "version_check error did not name the rejected version"
  pass "fm_backend_zellij_version_check: refuses an old version loudly"
}

test_version_check_refuses_missing_zellij() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  out=$( PATH="$dir/empty-fakebin:/usr/bin:/bin" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when zellij is not installed"
  assert_contains "$out" "not installed" "version_check did not report zellij as missing"
  pass "fm_backend_zellij_version_check: refuses loudly when zellij is not installed"
}

# --- session name resolution --------------------------------------------------

test_session_defaults_to_firstmate() {
  local out
  out=$( bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_session' "$ROOT" )
  [ "$out" = firstmate ] || fail "default session should be 'firstmate', got '$out'"
  pass "fm_backend_zellij_session: defaults to 'firstmate' when FM_ZELLIJ_SESSION is unset"
}

test_session_honors_override() {
  local out
  out=$( FM_ZELLIJ_SESSION=fm-test-iso bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_session' "$ROOT" )
  [ "$out" = fm-test-iso ] || fail "FM_ZELLIJ_SESSION override was not honored, got '$out'"
  pass "fm_backend_zellij_session: honors the FM_ZELLIJ_SESSION test-isolation override"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/zellij.sh"
    fm_backend_zellij_parse_target "firstmate:5" || exit 1
    [ "$FM_BACKEND_ZELLIJ_SESSION" = firstmate ] || { echo "session mismatch: $FM_BACKEND_ZELLIJ_SESSION" >&2; exit 1; }
    [ "$FM_BACKEND_ZELLIJ_PANE" = "5" ] || { echo "pane mismatch: $FM_BACKEND_ZELLIJ_PANE" >&2; exit 1; }
  ) || fail "fm_backend_zellij_parse_target did not split session:pane correctly"
  pass "fm_backend_zellij_parse_target: splits '<session>:<pane_id>' on the first colon"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/zellij.sh"
    [ "$(fm_backend_zellij_normalize_key Enter)" = Enter ] || { echo "Enter failed" >&2; exit 1; }
    [ "$(fm_backend_zellij_normalize_key Escape)" = Esc ] || { echo "Escape failed" >&2; exit 1; }
    [ "$(fm_backend_zellij_normalize_key Esc)" = Esc ] || { echo "Esc failed" >&2; exit 1; }
    [ "$(fm_backend_zellij_normalize_key C-c)" = "Ctrl c" ] || { echo "C-c failed" >&2; exit 1; }
    [ "$(fm_backend_zellij_normalize_key ctrl+c)" = "Ctrl c" ] || { echo "ctrl+c failed" >&2; exit 1; }
  ) || fail "fm_backend_zellij_normalize_key did not map firstmate's key vocabulary to zellij's verified names"
  pass "fm_backend_zellij_normalize_key: Enter/Escape/C-c map to zellij's verified Enter/Esc/'Ctrl c'"
}

# --- home-scoped tab titles (cross-home collision fix) ------------------------

test_scoped_title_uses_primary_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-title-primary"; mkdir -p "$dir"
  expected=$(zellij_expected_scoped_title fm-task1 "$dir")
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_scoped_title fm-task1' "$ROOT" )
  [ "$out" = "$expected" ] || fail "primary scoped title should be $expected, got '$out'"
  pass "fm_backend_zellij_scoped_title: scopes a primary task title with firstmate plus root hash"
}

test_scoped_title_uses_secondmate_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-title-secondmate"; mkdir -p "$dir"
  printf 'sm-one\n' > "$dir/.fm-secondmate-home"
  expected=$(zellij_expected_scoped_title fm-task1 "$dir")
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_scoped_title fm-task1' "$ROOT" )
  [ "$out" = "$expected" ] || fail "secondmate scoped title should be $expected, got '$out'"
  pass "fm_backend_zellij_scoped_title: scopes a secondmate task title with the home marker plus root hash"
}

test_scoped_title_changes_with_root_path() {
  local dir home root_one root_two out_one out_two expected_one expected_two
  dir="$TMP_ROOT/scoped-title-root-hash"; home="$dir/home"; root_one="$dir/root-one"; root_two="$dir/root-two"
  mkdir -p "$home" "$root_one" "$root_two"
  expected_one=$(zellij_expected_scoped_title fm-task1 "$home" "$root_one")
  expected_two=$(zellij_expected_scoped_title fm-task1 "$home" "$root_two")
  out_one=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_one" bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_scoped_title fm-task1' "$ROOT" )
  out_two=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_two" bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_scoped_title fm-task1' "$ROOT" )
  [ "$out_one" = "$expected_one" ] || fail "scoped title should include root-one hash as $expected_one, got '$out_one'"
  [ "$out_two" = "$expected_two" ] || fail "scoped title should include root-two hash as $expected_two, got '$out_two'"
  [ "$out_one" != "$out_two" ] || fail "scoped titles should differ for distinct FM_ROOT paths"
  pass "fm_backend_zellij_scoped_title: includes the resolved FM_ROOT hash in the home label"
}

test_expected_label_accepts_unambiguous_untagged_legacy_tab() {
  local dir fb
  dir="$TMP_ROOT/label-legacy-unambiguous"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  # 2: list-tabs --json -> exactly ONE live tab, still carrying its
  # pre-migration untagged bare title (never re-tagged) - unambiguous, so
  # the legacy fallback in fm_backend_zellij_tab_matches_label trusts it.
  zellij_tab_response "$dir" 2 3 fm-legacy
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_key firstmate:7 Escape fm-legacy' "$ROOT"
  expect_code 0 $? "send_key should still reach a task tab spawned before home-scoping shipped, when its untagged title is unambiguous"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-keys'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''Esc' \
    "send_key did not send after accepting the unambiguous legacy label"
  pass "fm_backend_zellij_tab_matches_label: accepts an untagged legacy fm-<id> title when it is the only live tab carrying it"
}

test_expected_label_refuses_ambiguous_untagged_tab() {
  local dir fb status
  dir="$TMP_ROOT/label-ambiguous-untagged"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  # 2: list-tabs --json -> TWO different tabs sharing the exact same bare,
  # untagged legacy title "fm-shared" (our pane's owning tab_id=3 is one of
  # them, but so is an unrelated tab_id=9) - the migration posture requires
  # an untagged bare match to be UNIQUE across the whole session before it
  # is trusted; ambiguity here must refuse loudly rather than assume ours.
  zellij_multi_tab_response "$dir" 2 3 fm-shared 9 fm-shared
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_key firstmate:7 Escape fm-shared' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse an ambiguous untagged legacy label shared by 2+ live tabs"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send-keys' \
    "send_key should not send after an ambiguous untagged-label match refuses"
  pass "fm_backend_zellij_tab_matches_label: refuses an untagged legacy label match when 2+ live tabs share it (migration ambiguity guard)"
}

test_list_live_scopes_to_own_home_tag() {
  local dir fb out own_title foreign_title other_root
  dir="$TMP_ROOT/list-live-scope"; mkdir -p "$dir/responses"
  other_root="$dir/other-root"; mkdir -p "$other_root"
  own_title=$(zellij_expected_scoped_title fm-task1)
  foreign_title=$(zellij_expected_scoped_title fm-task2 "$ROOT" "$other_root")
  # 1: list-tabs --json -> our own home-scoped tab, a DIFFERENT installation's
  # home-scoped tab (same prefix shape, different FM_ROOT hash), and an
  # unrelated non-firstmate tab.
  zellij_multi_tab_response "$dir" 1 \
    3 "$own_title" \
    4 "$foreign_title" \
    5 "zsh"
  # 2: list-panes for our own home's task1 tab only
  zellij_pane_response "$dir" 2 7 3
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_list_live firstmate' "$ROOT" )
  [ "$out" = $'firstmate:7\tfm-task1' ] \
    || fail "list_live should list only this home's own tagged tab with its plain fm-<id> label, got '$out'"
  pass "fm_backend_zellij_list_live: scopes to this home's own tag - excludes a different installation's tagged tab and unrelated tabs"
}

test_resolve_bare_selector_prefers_scoped_title() {
  local dir fb out title
  dir="$TMP_ROOT/resolve-scoped"; mkdir -p "$dir/responses"
  title=$(zellij_expected_scoped_title fm-resolve1)
  # 1: list-tabs --json -> the home-scoped tagged tab
  printf '[{"tab_id":6,"name":"%s"}]\n' "$title" > "$dir/responses/1.out"
  # 2: list-panes for tab 6
  zellij_pane_response "$dir" 2 12 6
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_resolve_bare_selector fm-resolve1' "$ROOT" )
  [ "$out" = "firstmate:12" ] || fail "resolve_bare_selector should resolve the home-scoped tagged tab, got '$out'"
  pass "fm_backend_zellij_resolve_bare_selector: matches the home-scoped tagged title first"
}

test_resolve_bare_selector_refuses_ambiguous_untagged() {
  local dir fb out status
  dir="$TMP_ROOT/resolve-ambiguous"; mkdir -p "$dir/responses"
  # 1: list-tabs --json -> two DIFFERENT tabs sharing the same untagged bare name
  zellij_multi_tab_response "$dir" 1 3 fm-resolve2 9 fm-resolve2
  zellij_multi_tab_response "$dir" 2 3 fm-resolve2 9 fm-resolve2
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_resolve_bare_selector fm-resolve2' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "resolve_bare_selector should refuse an ambiguous untagged label shared by 2+ live tabs"
  assert_contains "$out" "no zellij tab named" "resolve_bare_selector's refusal did not report the expected not-found error"
  pass "fm_backend_zellij_resolve_bare_selector: refuses an ambiguous untagged legacy label shared by 2+ live tabs"
}

test_resolve_bare_selector_prefers_later_session_scoped_title_over_legacy() {
  local dir fb out title
  dir="$TMP_ROOT/resolve-later-scoped"; mkdir -p "$dir/responses"
  title=$(zellij_expected_scoped_title fm-resolve3)
  zellij_tab_response "$dir" 1 3 fm-resolve3
  zellij_tab_response "$dir" 2 6 "$title"
  zellij_pane_response "$dir" 3 12 6
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST=$'legacy-session\nscoped-session' \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_resolve_bare_selector fm-resolve3' "$ROOT" )
  [ "$out" = "scoped-session:12" ] || fail "resolve_bare_selector should prefer a later session's scoped title over an earlier legacy title, got '$out'"
  pass "fm_backend_zellij_resolve_bare_selector: checks every session for the scoped title before legacy fallback"
}

test_resolve_bare_selector_refuses_cross_session_ambiguous_untagged() {
  local dir fb out status
  dir="$TMP_ROOT/resolve-cross-session-ambiguous"; mkdir -p "$dir/responses"
  zellij_tab_response "$dir" 1 3 fm-resolve4
  zellij_tab_response "$dir" 2 9 fm-resolve4
  zellij_tab_response "$dir" 3 3 fm-resolve4
  zellij_tab_response "$dir" 4 9 fm-resolve4
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST=$'one-session\ntwo-session' \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_resolve_bare_selector fm-resolve4' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "resolve_bare_selector should refuse an untagged legacy label that appears once in each of two sessions"
  assert_contains "$out" "no zellij tab named" "resolve_bare_selector's cross-session ambiguity refusal did not report the expected not-found error"
  pass "fm_backend_zellij_resolve_bare_selector: requires untagged legacy labels to be globally unique across sessions"
}

# --- session_exists / server_ensure -------------------------------------------

test_session_exists_true_when_listed() {
  local dir fb out
  dir="$TMP_ROOT/exists-true"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST=$'firstmate\nother-session' \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_session_exists firstmate' "$ROOT"
  expect_code 0 $? "session_exists should report true when the session is in the list"
  pass "fm_backend_zellij_session_exists: true when the session name is listed"
}

test_session_exists_false_when_absent() {
  local dir fb
  dir="$TMP_ROOT/exists-false"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST=$'other-session' \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_session_exists firstmate' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "session_exists should report false when the session is absent"
  pass "fm_backend_zellij_session_exists: false when the session name is not listed"
}

test_server_ensure_skips_attach_when_already_exists() {
  local dir fb
  dir="$TMP_ROOT/server-reuse"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_server_ensure firstmate' "$ROOT"
  expect_code 0 $? "server_ensure should succeed immediately when the session already exists"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''attach' "server_ensure should not call attach when the session already exists"
  pass "fm_backend_zellij_server_ensure: reuses an existing session without calling attach"
}

# --- dispatch wiring (fm-backend.sh) ------------------------------------------

test_dispatch_routes_zellij_backend() {
  fm_backend_validate zellij 2>/dev/null || fail "fm_backend_validate should accept zellij (P3 adds it to FM_BACKEND_KNOWN)"
  pass "fm_backend_validate: zellij is a known backend (P3)"
}

test_dispatch_busy_state_unknown_for_zellij() {
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state zellij 'firstmate:5')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for zellij (no native agent-state primitive; D5: watcher falls back to regex, same as tmux)"
  pass "fm_backend_busy_state: zellij (no native primitive) always reports unknown, same as tmux"
}

# --- create_task: duplicate refusal, id parsing, focus-restore mitigation ----

test_create_task_refuses_duplicate_label() {
  local dir fb out status title
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"
  title=$(zellij_expected_scoped_title fm-dup1)
  # 1: list-tabs --json -> existing tab already carrying the home-scoped title
  printf '[{"tab_id":2,"name":"%s","active":false}]\n' "$title" > "$dir/responses/1.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_create_task firstmate fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing tab name (zellij itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate name"
  assert_contains "$out" "$title" "create_task's duplicate error did not name the home-scoped title"
  pass "fm_backend_zellij_create_task: refuses a duplicate home-scoped tab title (zellij's own new-tab has no uniqueness check)"
}

test_create_task_creates_and_parses_ids() {
  local dir fb out title
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"
  title=$(zellij_expected_scoped_title fm-newtask)
  # 1: list-tabs --json -> no existing tabs, none active
  printf '[]\n' > "$dir/responses/1.out"
  # 2: new-tab --cwd --name -> bare tab id on stdout
  printf '3\n' > "$dir/responses/2.out"
  # 3: list-panes --json -> the new tab's terminal pane
  printf '[{"id":7,"tab_id":3,"is_plugin":false}]\n' > "$dir/responses/3.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_create_task firstmate fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "3 7" ] || fail "create_task should echo '<tab_id> <pane_id>', got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-tab'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--name'$'\x1f'"$title" \
    "create_task did not call new-tab with the right cwd/home-scoped name"
  pass "fm_backend_zellij_create_task: creates a home-scoped tab and parses tab_id/pane_id from the response"
}

test_create_task_restores_previously_active_tab() {
  local dir fb out
  dir="$TMP_ROOT/focus-restore"; mkdir -p "$dir/responses"
  # 1: list-tabs --json -> tab 0 is currently active
  printf '[{"tab_id":0,"name":"Tab #1","active":true}]\n' > "$dir/responses/1.out"
  # 2: new-tab -> id 4 (this steals focus on the real CLI)
  printf '4\n' > "$dir/responses/2.out"
  # 3: list-panes --json -> tab 4's terminal pane
  printf '[{"id":9,"tab_id":4,"is_plugin":false}]\n' > "$dir/responses/3.out"
  # 4: go-to-tab-by-id 0 (the restore call) - silent on success
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_create_task firstmate fm-focustest /tmp/proj' "$ROOT" )
  [ "$out" = "4 9" ] || fail "create_task should still echo '<tab_id> <pane_id>', got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''go-to-tab-by-id'$'\x1f''0' \
    "create_task did not restore focus to the previously-active tab (verified real-zellij focus-steal mitigation)"
  pass "fm_backend_zellij_create_task: restores focus to the previously-active tab after the steal-focus new-tab call"
}

test_create_task_no_restore_when_new_tab_was_already_active() {
  local dir fb out
  dir="$TMP_ROOT/focus-noop"; mkdir -p "$dir/responses"
  # No active tab at all (no client attached - the common unattended case)
  printf '[]\n' > "$dir/responses/1.out"
  printf '5\n' > "$dir/responses/2.out"
  printf '[{"id":11,"tab_id":5,"is_plugin":false}]\n' > "$dir/responses/3.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_create_task firstmate fm-noclient /tmp/proj' "$ROOT" )
  [ "$out" = "5 11" ] || fail "create_task should still echo '<tab_id> <pane_id>', got '$out'"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''go-to-tab-by-id' \
    "create_task should not call go-to-tab-by-id when there was no previously-active tab (no attached client)"
  pass "fm_backend_zellij_create_task: skips the restore call when there was no previously-active tab"
}

# --- capture / send_key / send_literal / current_path / kill -----------------

test_capture_small_reads_use_viewport_and_trim() {
  local dir fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  printf 'line one\nline two\nline three\nline four\n' > "$dir/responses/2.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_capture firstmate:7 2' "$ROOT" )
  [ "$out" = $'line three\nline four' ] || fail "capture should trim to the last N lines locally, got '$out'"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''dump-screen' \
    "capture did not verify the pane before dump-screen"
  assert_contains "$(cat "$dir/log")" $'\x1f''dump-screen'$'\x1f''--pane-id'$'\x1f''7' \
    "capture did not call dump-screen --pane-id <pane>"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''--full' \
    "small capture should use zellij's viewport-only dump-screen path"
  pass "fm_backend_zellij_capture: small reads use viewport-only dump-screen and trim to N lines locally"
}

test_capture_large_reads_use_full_scrollback_and_trim() {
  local dir fb out
  dir="$TMP_ROOT/capture-full"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  printf 'line one\nline two\nline three\nline four\n' > "$dir/responses/2.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_capture firstmate:7 80' "$ROOT" )
  [ "$out" = $'line one\nline two\nline three\nline four' ] || fail "large capture should keep available output when fewer than N lines exist, got '$out'"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''dump-screen' \
    "large capture did not verify the pane before dump-screen"
  assert_contains "$(cat "$dir/log")" $'\x1f''dump-screen'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''--full' \
    "large capture did not request --full scrollback"
  pass "fm_backend_zellij_capture: reads above the watcher-size threshold request --full scrollback"
}

test_capture_fails_when_pane_absent() {
  local dir fb out status
  dir="$TMP_ROOT/capture-no-pane"; mkdir -p "$dir/responses"
  printf '[]\n' > "$dir/responses/1.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_capture firstmate:7 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the session exists but the pane does not"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''dump-screen' \
    "capture should not call dump-screen after pane readiness fails"
  pass "fm_backend_zellij_capture: fails when the specific pane is absent"
}

test_capture_fails_when_session_absent() {
  local dir fb out status
  dir="$TMP_ROOT/capture-no-session"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_capture firstmate:7 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the session does not exist (never trust the CLI's unconditional exit 0)"
  pass "fm_backend_zellij_capture: fails when the target session is not listed as active (session_exists pre-check)"
}

test_send_key_normalizes_and_targets_pane() {
  local dir fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_key firstmate:7 Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''send-keys' \
    "send_key did not verify the pane before send-keys"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-keys'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''Esc' "send_key did not normalize Escape to Esc"
  pass "fm_backend_zellij_send_key: normalizes the key (Escape -> Esc) and targets the explicit pane id"
}

test_send_literal_uses_paste_separator_for_option_shaped_text() {
  local dir fb
  dir="$TMP_ROOT/sendliteral"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_literal firstmate:7 "--help"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''paste' \
    "send_literal did not verify the pane before paste"
  assert_contains "$(cat "$dir/log")" $'\x1f''paste'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''--'$'\x1f''--help' \
    "send_literal did not call paste with a -- separator before the literal payload"
  pass "fm_backend_zellij_send_literal: calls paste with an explicit pane id and a -- separator"
}

test_expected_label_allows_matching_task_tab() {
  local dir fb
  dir="$TMP_ROOT/label-match"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  zellij_tab_response "$dir" 2 3 fm-label
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_key firstmate:7 Escape fm-label' "$ROOT"
  expect_code 0 $? "send_key should succeed when the pane belongs to the expected fm-id tab"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''list-tabs'$'\x1f''--json' \
    "expected-label readiness did not resolve the pane's owning tab before label verification"
  zellij_assert_call_order "$dir/log" $'\x1f''list-tabs'$'\x1f''--json' $'\x1f''send-keys' \
    "send_key ran before verifying the owning tab label"
  pass "fm_backend_zellij_target_ready: expected labels allow matching fm-<id> tabs"
}

test_expected_label_rejects_reused_pane_id() {
  local dir fb status
  dir="$TMP_ROOT/label-mismatch"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  zellij_tab_response "$dir" 2 3 not-the-task
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_key firstmate:7 Escape fm-label' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should reject a pane whose tab name does not match the expected fm-id label"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''list-tabs'$'\x1f''--json' \
    "expected-label readiness did not check the pane's owning tab"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send-keys' \
    "send_key should not run after expected-label readiness fails"
  pass "fm_backend_zellij_target_ready: expected labels reject stale pane ids reused by another tab"
}

test_current_path_probes_with_marker_and_ignores_prompt_paths() {
  local dir fb out
  # Verified real-zellij pitfall (docs/zellij-backend.md "Worktree-path
  # discovery: pane_cwd does not track a subshell"): pane_cwd never updates
  # once a subshell (e.g. treehouse get) takes over, so current_path actively
  # prints a marked cwd line and reads only that marker from the capture,
  # rather than reading a JSON field.
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  zellij_pane_response "$dir" 2 7 3
  zellij_pane_response "$dir" 4 7 3
  zellij_pane_response "$dir" 6 7 3
  printf '%s\n' 'scratch-e2e-project HEAD' \
    '/Users/kunchen/src/project ❯ printf marker' \
    '__FM_ZELLIJ_CWD_BEGIN__' \
    '/Users/kunchen/.treehouse/fake-' \
    'worktree' \
    '__FM_ZELLIJ_CWD_END__' \
    '/Users/kunchen/.treehouse/fake-worktree ❯' \
    > "$dir/responses/7.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_current_path firstmate:7' "$ROOT" )
  [ "$out" = "/Users/kunchen/.treehouse/fake-worktree" ] || fail "current_path should read only the marked cwd line, got '$out'"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''paste' \
    "current_path did not verify the pane before the cwd probe paste"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''dump-screen' \
    "current_path did not verify the pane before capture"
  assert_contains "$(cat "$dir/log")" "__FM_ZELLIJ_CWD_BEGIN__" "current_path did not send the cwd begin marker via paste"
  assert_contains "$(cat "$dir/log")" "pwd;" "current_path did not send the pwd probe via paste"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-keys'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''Enter' "current_path did not submit the cwd probe with Enter"
  assert_contains "$(cat "$dir/log")" $'\x1f''dump-screen'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''--full' "current_path did not capture the pane after probing"
  pass "fm_backend_zellij_current_path: actively probes with marked begin/end lines and reconstructs wrapped cwd output"
}

test_current_path_ignores_tilde_prefixed_banner_lines() {
  local dir fb out
  dir="$TMP_ROOT/cwd-tilde"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  zellij_pane_response "$dir" 2 7 3
  zellij_pane_response "$dir" 4 7 3
  zellij_pane_response "$dir" 6 7 3
  printf '%s\n' "🌳 Entered worktree at ~/.treehouse/scratch-e2e-project/1. Type 'exit' to return." \
    'scratch-e2e-project HEAD' '__FM_ZELLIJ_CWD_BEGIN__' '/Users/kunchen/.treehouse/real-worktree' '__FM_ZELLIJ_CWD_END__' '❯' \
    > "$dir/responses/7.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_current_path firstmate:7' "$ROOT" )
  [ "$out" = "/Users/kunchen/.treehouse/real-worktree" ] || fail "current_path should skip the ~-prefixed banner line and read the marked cwd output, got '$out'"
  pass "fm_backend_zellij_current_path: never picks up a ~-prefixed banner line as the answer"
}

test_kill_resolves_tab_and_closes_by_id() {
  local dir fb
  dir="$TMP_ROOT/kill"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  printf '[{"id":7,"tab_id":3,"is_plugin":false}]\n' > "$dir/responses/2.out"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_kill firstmate:7' "$ROOT"
  expect_code 0 $? "kill should succeed (best-effort)"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''close-tab-by-id' \
    "kill did not verify the pane before close-tab-by-id"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-tab-by-id'$'\x1f''3' \
    "kill did not resolve the owning tab id and call close-tab-by-id (verified: close-pane alone leaves an empty ghost tab)"
  pass "fm_backend_zellij_kill: resolves the owning tab id fresh and calls close-tab-by-id (never a bare close-pane)"
}

test_kill_falls_back_to_close_pane_when_tab_lookup_empty() {
  local dir fb
  dir="$TMP_ROOT/kill-fallback"; mkdir -p "$dir/responses"
  printf '[]\n' > "$dir/responses/1.out"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_kill firstmate:7' "$ROOT"
  expect_code 0 $? "kill must stay best-effort even when the tab lookup comes up empty"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''close-pane' \
    "kill did not verify the pane before close-pane fallback"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-pane'$'\x1f''--pane-id'$'\x1f''7' \
    "kill did not fall back to a direct close-pane when no owning tab could be resolved"
  pass "fm_backend_zellij_kill: falls back to close-pane when the owning tab cannot be resolved"
}

test_kill_closes_recorded_tab_when_pane_already_gone() {
  local dir fb
  dir="$TMP_ROOT/kill-recorded-tab"; mkdir -p "$dir/responses"
  printf '[]\n' > "$dir/responses/1.out"
  printf '[{"tab_id":3,"name":"fm-zghost"}]\n' > "$dir/responses/2.out"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_kill firstmate:7 3 fm-zghost' "$ROOT"
  expect_code 0 $? "kill must stay best-effort even when only the recorded tab id is usable"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''list-tabs'$'\x1f''--json' \
    "kill did not verify the recorded tab id by label before closing it"
  zellij_assert_call_order "$dir/log" $'\x1f''list-tabs'$'\x1f''--json' $'\x1f''close-tab-by-id' \
    "kill closed the recorded tab id before verifying its label"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-tab-by-id'$'\x1f''3' \
    "kill did not close the verified recorded tab id when the pane was already gone"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-pane' \
    "kill should close the verified recorded tab id instead of leaving an empty ghost tab"
  pass "fm_backend_zellij_kill: closes the recorded tab id only after label verification"
}

test_kill_skips_recorded_tab_when_label_mismatches() {
  local dir fb
  dir="$TMP_ROOT/kill-recorded-tab-mismatch"; mkdir -p "$dir/responses"
  printf '[]\n' > "$dir/responses/1.out"
  printf '[{"tab_id":3,"name":"not-the-task"}]\n' > "$dir/responses/2.out"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_kill firstmate:7 3 fm-zghost' "$ROOT"
  expect_code 0 $? "kill must stay best-effort when the recorded tab id no longer belongs to the task"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''list-tabs'$'\x1f''--json' \
    "kill did not verify the recorded tab id by label"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-tab-by-id' \
    "kill should not close a recorded tab id whose name does not match the task"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-pane' \
    "kill should not fall back to closing a pane once an expected task label is available"
  pass "fm_backend_zellij_kill: skips a stale recorded tab id whose label does not match"
}

test_kill_is_noop_when_session_absent() {
  local dir fb
  dir="$TMP_ROOT/kill-no-session"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_kill firstmate:7' "$ROOT"
  expect_code 0 $? "kill must stay best-effort (never fail) even when the session is already gone"
  pass "fm_backend_zellij_kill: never fails when the target session no longer exists"
}

test_teardown_passes_recorded_tab_id_to_zellij_kill() {
  local dir state data config project fb out status
  dir="$TMP_ROOT/teardown-zellij-ghost"; state="$dir/state"; data="$dir/data"; config="$dir/config"; project="$dir/project"
  mkdir -p "$state" "$data/zghost" "$config" "$project" "$dir/responses"
  printf 'report\n' > "$data/zghost/report.md"
  fm_write_meta "$state/zghost.meta" \
    "window=firstmate:7" \
    "backend=zellij" \
    "zellij_tab_id=3" \
    "worktree=$dir/missing-worktree" \
    "project=$project" \
    "kind=scout"
  printf '[]\n' > "$dir/responses/1.out"
  printf '[{"tab_id":3,"name":"fm-zghost"}]\n' > "$dir/responses/2.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-teardown.sh" zghost 2>&1 )
  status=$?
  expect_code 0 "$status" "fm-teardown should succeed for a zellij scout whose worktree is already gone: $out"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''list-tabs'$'\x1f''--json' \
    "fm-teardown did not verify the recorded zellij_tab_id against the task label"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-tab-by-id'$'\x1f''3' \
    "fm-teardown did not pass a verified recorded zellij_tab_id through to kill"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-pane' \
    "fm-teardown should close the recorded tab id instead of falling back to close-pane"
  pass "fm-teardown.sh: passes recorded zellij_tab_id with the expected task label"
}

test_forced_secondmate_teardown_kills_zellij_children_with_child_home_tag() {
  local dir state data config home project fb out status child_title
  dir="$TMP_ROOT/teardown-zellij-secondmate-child"; state="$dir/state"; data="$dir/data"; config="$dir/config"; home="$dir/secondmate-home"; project="$dir/project"
  mkdir -p "$state" "$data" "$config" "$home/state" "$home/data" "$home/config" "$home/projects" "$project" "$dir/responses"
  printf 'smz\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$state/smz.meta" \
    "window=firstmate:99" \
    "backend=zellij" \
    "worktree=$home" \
    "project=$home" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home"
  fm_write_meta "$home/state/childz.meta" \
    "window=firstmate:7" \
    "backend=zellij" \
    "zellij_tab_id=4" \
    "worktree=$dir/missing-child-worktree" \
    "project=$project" \
    "kind=scout"
  child_title=$(zellij_expected_scoped_title fm-childz "$home" "$home")
  zellij_pane_response "$dir" 1 7 4
  zellij_tab_response "$dir" 2 4 "$child_title"
  printf '[]\n' > "$dir/responses/3.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-teardown.sh" smz --force 2>&1 )
  status=$?
  expect_code 0 "$status" "fm-teardown should force-retire a secondmate with a zellij child: $out"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-tab-by-id'$'\x1f''4' \
    "forced secondmate teardown did not close a child zellij tab scoped to the child home"
  pass "fm-teardown.sh: force cleanup kills zellij children using the child home tag"
}

# --- send_text_submit: delta-based verify-and-retry --------------------------

test_send_text_submit_detects_landed_send() {
  local dir fb out
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  zellij_pane_response "$dir" 3 7 3
  zellij_pane_response "$dir" 5 7 3
  zellij_pane_response "$dir" 7 7 3
  printf '%s' $'❯ hello captain' > "$dir/responses/4.out"
  printf '%s' $'hello captain\n❯' > "$dir/responses/8.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_text_submit firstmate:7 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once the pane visibly changes, got '$out'"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''paste' \
    "send_text_submit did not verify the pane before paste"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''dump-screen' \
    "send_text_submit did not verify the pane before capture"
  assert_contains "$(cat "$dir/log")" $'\x1f''paste'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''--'$'\x1f''hello captain' "send_text_submit did not type the literal text first"
  pass "fm_backend_zellij_send_text_submit: reports 'empty' once the pane content changes after Enter (submitted)"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"
  zellij_pane_response "$dir" 1 7 3
  zellij_pane_response "$dir" 3 7 3
  zellij_pane_response "$dir" 5 7 3
  zellij_pane_response "$dir" 7 7 3
  zellij_pane_response "$dir" 9 7 3
  zellij_pane_response "$dir" 11 7 3
  printf '%s' $'❯ hello captain' > "$dir/responses/4.out"
  printf '%s' $'❯ hello captain' > "$dir/responses/8.out"
  printf '%s' $'❯ hello captain' > "$dir/responses/12.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_text_submit firstmate:7 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with no visible change, got '$out'"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''send-keys' \
    "send_text_submit did not verify the pane before send-keys"
  pass "fm_backend_zellij_send_text_submit: reports 'pending' when the pane never changes after retried Enters (swallowed)"
}

test_send_text_submit_send_failed_when_session_absent() {
  local dir fb out
  dir="$TMP_ROOT/submit-no-session"; mkdir -p "$dir/responses"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_text_submit firstmate:7 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the session does not exist, got '$out'"
  pass "fm_backend_zellij_send_text_submit: reports 'send-failed' when the target session is not active"
}

test_send_text_submit_send_failed_when_pane_absent() {
  local dir fb out
  dir="$TMP_ROOT/submit-no-pane"; mkdir -p "$dir/responses"
  printf '[]\n' > "$dir/responses/1.out"
  fb=$(make_zellij_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" \
    FM_ZELLIJ_SESSION_LIST="firstmate" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_text_submit firstmate:7 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the pane does not exist, got '$out'"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''paste' \
    "send_text_submit should not paste text after pane readiness fails"
  pass "fm_backend_zellij_send_text_submit: reports 'send-failed' when the target pane is absent"
}

# --- fm-*.sh script routing via explicit backend-tagged meta ------------------

test_scripts_route_explicit_target_through_meta_backend() {
  local dir state fb neutral out
  dir="$TMP_ROOT/script-explicit-target"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/zellij-stale.meta" "window=firstmate:7" "backend=zellij"
  touch "$state/.last-watcher-beat"
  zellij_pane_response "$dir" 1 7 3
  printf 'captured zellij pane\n' > "$dir/responses/2.out"
  zellij_pane_response "$dir" 3 7 3
  fb=$(make_zellij_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux should not be used for a metadata-matched zellij target\n' >&2
exit 42
SH
  chmod +x "$fb/tmux"

  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-peek.sh" firstmate:7 5 2>/dev/null )
  [ "$out" = "captured zellij pane" ] || fail "fm-peek did not capture through zellij for an explicit metadata-matched target, got '$out'"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''dump-screen' \
    "fm-peek did not verify the pane before capture"
  assert_contains "$(cat "$dir/log")" $'\x1f''dump-screen'$'\x1f''--pane-id'$'\x1f''7' \
    "fm-peek did not route the explicit metadata-matched target through zellij capture"

  : > "$dir/log"
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-send.sh" firstmate:7 --key Escape >/dev/null 2>&1
  expect_code 0 $? "fm-send --key should route an explicit metadata-matched target through zellij"
  zellij_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--json' $'\x1f''send-keys' \
    "fm-send did not verify the pane before send-key"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-keys'$'\x1f''--pane-id'$'\x1f''7'$'\x1f''Esc' \
    "fm-send did not route the explicit metadata-matched target through zellij send-key"

  pass "fm-peek/fm-send: explicit metadata-matched targets use the recorded zellij backend"
}

test_scripts_verify_label_for_fm_targets() {
  local dir state fb neutral out
  dir="$TMP_ROOT/script-fm-target-label"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/zlabel.meta" "window=firstmate:7" "backend=zellij"
  touch "$state/.last-watcher-beat"
  zellij_pane_response "$dir" 1 7 3
  zellij_tab_response "$dir" 2 3 fm-zlabel
  printf 'captured through fm-id\n' > "$dir/responses/3.out"
  fb=$(make_zellij_fakebin "$dir")

  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-peek.sh" fm-zlabel 5 2>/dev/null )
  [ "$out" = "captured through fm-id" ] || fail "fm-peek did not capture through zellij for an fm-id target with a matching tab label, got '$out'"
  zellij_assert_call_order "$dir/log" $'\x1f''list-tabs'$'\x1f''--json' $'\x1f''dump-screen' \
    "fm-peek did not verify the fm-id tab label before capture"

  pass "fm-peek: fm-id zellij targets verify the owning tab label before capture"
}

test_scripts_reject_fm_target_label_mismatch() {
  local dir state fb neutral status
  dir="$TMP_ROOT/script-fm-target-label-mismatch"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/zreuse.meta" "window=firstmate:7" "backend=zellij"
  touch "$state/.last-watcher-beat"
  zellij_pane_response "$dir" 1 7 3
  zellij_tab_response "$dir" 2 3 not-the-task
  fb=$(make_zellij_fakebin "$dir")

  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_ZELLIJ_LOG="$dir/log" FM_ZELLIJ_RESPONSES="$dir/responses" FM_ZELLIJ_SESSION_LIST="firstmate" \
    "$ROOT/bin/fm-send.sh" fm-zreuse --key Escape >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "fm-send --key should reject an fm-id zellij target whose pane belongs to a differently named tab"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send-keys' \
    "fm-send should not send a key after fm-id label verification fails"
  pass "fm-send: fm-id zellij targets reject pane ids whose tab label no longer matches"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

test_version_check_accepts_current_version
test_version_check_accepts_newer_version
test_version_check_refuses_old_version
test_version_check_refuses_missing_zellij
test_session_defaults_to_firstmate
test_session_honors_override
test_parse_target
test_normalize_key
test_scoped_title_uses_primary_home_label
test_scoped_title_uses_secondmate_home_label
test_scoped_title_changes_with_root_path
test_expected_label_accepts_unambiguous_untagged_legacy_tab
test_expected_label_refuses_ambiguous_untagged_tab
test_list_live_scopes_to_own_home_tag
test_resolve_bare_selector_prefers_scoped_title
test_resolve_bare_selector_refuses_ambiguous_untagged
test_resolve_bare_selector_prefers_later_session_scoped_title_over_legacy
test_resolve_bare_selector_refuses_cross_session_ambiguous_untagged
test_session_exists_true_when_listed
test_session_exists_false_when_absent
test_server_ensure_skips_attach_when_already_exists
test_dispatch_routes_zellij_backend
test_dispatch_busy_state_unknown_for_zellij
test_create_task_refuses_duplicate_label
test_create_task_creates_and_parses_ids
test_create_task_restores_previously_active_tab
test_create_task_no_restore_when_new_tab_was_already_active
test_capture_small_reads_use_viewport_and_trim
test_capture_large_reads_use_full_scrollback_and_trim
test_capture_fails_when_pane_absent
test_capture_fails_when_session_absent
test_send_key_normalizes_and_targets_pane
test_send_literal_uses_paste_separator_for_option_shaped_text
test_expected_label_allows_matching_task_tab
test_expected_label_rejects_reused_pane_id
test_current_path_probes_with_marker_and_ignores_prompt_paths
test_current_path_ignores_tilde_prefixed_banner_lines
test_kill_resolves_tab_and_closes_by_id
test_kill_falls_back_to_close_pane_when_tab_lookup_empty
test_kill_closes_recorded_tab_when_pane_already_gone
test_kill_skips_recorded_tab_when_label_mismatches
test_kill_is_noop_when_session_absent
test_teardown_passes_recorded_tab_id_to_zellij_kill
test_forced_secondmate_teardown_kills_zellij_children_with_child_home_tag
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_send_failed_when_session_absent
test_send_text_submit_send_failed_when_pane_absent
test_scripts_route_explicit_target_through_meta_backend
test_scripts_verify_label_for_fm_targets
test_scripts_reject_fm_target_label_mismatch
