#!/usr/bin/env bash
# Browser custody integration points: brief scaffold, config inheritance, bootstrap validation, and teardown guard helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=${TMPDIR:-/tmp}/fm-browser-integration-$$
mkdir -p "$TMP_ROOT"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_grep() { grep -Fq "$1" "$2" || fail "$3"; }

# shellcheck source=bin/fm-browser-lib.sh
. "$ROOT/bin/fm-browser-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

test_brief_browser_scaffold() {
  local home="$TMP_ROOT/brief-home" brief
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" browser-task firstmate --scout --browser >/dev/null \
    || fail "browser scout brief failed"
  brief="$home/data/browser-task/brief.md"
  assert_grep "Load \`browser-capability\` before any browser intake" "$brief" "browser skill load missing from brief"
  assert_grep 'bin/fm-browser.sh' "$brief" "browser owner missing from brief"
  assert_grep 'do not launch a browser directly' "$brief" "raw browser refusal missing from brief"
  pass "--browser scaffold adds browser-capability safety contract"
}

test_config_inheritance_includes_browser_policy() {
  local src="$TMP_ROOT/inherit-src" dest="$TMP_ROOT/inherit-dest"
  mkdir -p "$src" "$dest"
  printf '%s\n' '{"schema":"fm-browser-policy.v1","enabled":false}' > "$src/browser-policy.json"
  propagate_inheritable_config "$src" "$dest" || fail "inheritance failed"
  cmp -s "$src/browser-policy.json" "$dest/browser-policy.json" \
    || fail "browser-policy.json was not inherited"
  pass "browser policy is inherited through the declared config list"
}

test_bootstrap_reports_invalid_browser_policy() {
  local home="$TMP_ROOT/bootstrap-home" out
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' '{"schema":"wrong","enabled":false}' > "$home/config/browser-policy.json"
  out=$(FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null) \
    || fail "bootstrap failed"
  printf '%s\n' "$out" | grep -Fq 'BROWSER: invalid config/browser-policy.json' \
    || fail "bootstrap did not report invalid browser policy"
  pass "bootstrap validates browser policy without launching a browser"
}

test_teardown_guard_helper_refuses_unclean_binding() {
  local home="$TMP_ROOT/teardown-home" binding
  mkdir -p "$home/state/browser/v1/task-bindings"
  binding="$home/state/browser/v1/task-bindings/t1.json"
  printf '%s\n' '{"schema":"fm-browser-task-binding.v1","task":"t1","handle":"br-test","state":"active","cleaned":false}' > "$binding"
  if fm_browser_refuse_unclean_task "$home" t1 2>/dev/null; then
    fail "unclean browser binding was not refused"
  fi
  printf '%s\n' '{"schema":"fm-browser-task-binding.v1","task":"t1","handle":"br-test","state":"cleaned","cleaned":true}' > "$binding"
  fm_browser_refuse_unclean_task "$home" t1 2>/dev/null \
    || fail "cleaned browser binding was refused"
  pass "teardown helper refuses only unclean browser bindings"
}

trap 'rm -rf "$TMP_ROOT"' EXIT

test_brief_browser_scaffold
test_config_inheritance_includes_browser_policy
test_bootstrap_reports_invalid_browser_policy
test_teardown_guard_helper_refuses_unclean_binding
