#!/usr/bin/env bash
# Portable checks for Cursor Calm: the shared config/calm helper, the /calm
# skill wiring Cursor discovers, and sessionStart additional_context policy
# injection. Needs no cursor-agent binary.
#
# Pi TUI adapters and the Claude Code mod stay in tests/fm-calm-pi-extension.test.sh
# and tests/fm-calm-claude-mod.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFERENCE="$ROOT/bin/fm-calm-preference.sh"
SESSIONSTART="$ROOT/bin/fm-sessionstart-cursor.sh"
TMP_ROOT=$(fm_test_tmproot fm-calm-cursor)
command -v jq >/dev/null 2>&1 || fail "jq is required for Cursor sessionStart JSON"

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/config" "$dir/state" "$dir/bin"
  printf '%s\n' "$dir"
}

pref() {
  FM_HOME="$1" "$PREFERENCE" "${@:2}"
}

test_read_absent_unrecognized_max_on_off() {
  local home out
  home=$(make_home "$TMP_ROOT/values")
  out=$(pref "$home" read)
  assert_equals off "$out" "absent preference must read off"
  printf 'on\n' >"$home/config/calm"
  out=$(pref "$home" read)
  assert_equals on "$out" "on must read on"
  printf 'off\n' >"$home/config/calm"
  out=$(pref "$home" read)
  assert_equals off "$out" "off must read off"
  printf 'max\n' >"$home/config/calm"
  out=$(pref "$home" read)
  assert_equals on "$out" "legacy max must read as on"
  printf 'max' >"$home/config/calm"
  out=$(pref "$home" read)
  assert_equals on "$out" "max without a trailing newline must still read as on"
  printf ' ON \n' >"$home/config/calm"
  out=$(pref "$home" read)
  assert_equals off "$out" "unrecognized ON must read off"
  printf 'yes\n' >"$home/config/calm"
  out=$(pref "$home" read)
  assert_equals off "$out" "unrecognized yes must read off"
  : >"$home/config/calm"
  out=$(pref "$home" read)
  assert_equals off "$out" "an empty file must read off"
  pass "Calm preference reads absent, max, on, off, and unrecognized values"
}

test_write_is_atomic_and_mode_0600() {
  local home leftovers contents
  home=$(make_home "$TMP_ROOT/write")
  pref "$home" write on
  contents=$(cat "$home/config/calm"; printf .)
  assert_equals $'on\n.' "$contents" "write on must persist on plus a newline"
  [ "$(file_mode "$home/config/calm")" = 600 ] || fail "write on must create the file at mode 0600"
  pref "$home" write off
  contents=$(cat "$home/config/calm"; printf .)
  assert_equals $'off\n.' "$contents" "write off must persist off plus a newline"
  leftovers=$(find "$home/config" -name 'calm.tmp.*' -print)
  [ -z "$leftovers" ] || fail "a successful write left temp files: $leftovers"
  pass "Calm preference writes on/off atomically at mode 0600"
}

test_toggle_flips_and_failed_write_leaves_choice() {
  local home out status contents
  home=$(make_home "$TMP_ROOT/toggle")
  out=$(pref "$home" toggle)
  assert_equals on "$out" "toggle from absent must persist on"
  contents=$(cat "$home/config/calm"; printf .)
  assert_equals $'on\n.' "$contents" "first toggle must write on"
  out=$(pref "$home" toggle)
  assert_equals off "$out" "toggle from on must persist off"
  printf 'max\n' >"$home/config/calm"
  out=$(pref "$home" toggle)
  assert_equals off "$out" "toggle from legacy max must persist off"
  printf 'on\n' >"$home/config/calm"
  chmod a-w "$home/config"
  set +e
  out=$(pref "$home" toggle 2>/dev/null)
  status=$?
  set -e
  chmod u+w "$home/config"
  expect_code 1 "$status" "a failed toggle must not claim persistence"
  [ -z "$out" ] || fail "a failed toggle printed a new state: $out"
  contents=$(cat "$home/config/calm"; printf .)
  assert_equals $'on\n.' "$contents" "a failed toggle must leave the current file unchanged"
  pass "Calm preference toggles, treats max as on, and leaves the file on a failed write"
}

test_home_resolution_matches_pi() {
  local home override root out
  home=$(make_home "$TMP_ROOT/home")
  override=$(make_home "$TMP_ROOT/override")
  root="$TMP_ROOT/root"
  mkdir -p "$root/bin" "$root/config"
  printf 'on\n' >"$home/config/calm"
  printf 'off\n' >"$override/config/calm"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_CONFIG_OVERRIDE="$override/config" "$PREFERENCE" read)
  assert_equals off "$out" "FM_CONFIG_OVERRIDE must win"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$PREFERENCE" read)
  assert_equals on "$out" "FM_HOME must beat FM_ROOT_OVERRIDE"
  out=$(env -u FM_HOME -u FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE="$home" "$PREFERENCE" read)
  assert_equals on "$out" "FM_ROOT_OVERRIDE must apply when FM_HOME is unset"
  out=$(FM_HOME='' FM_ROOT_OVERRIDE="$home" "$PREFERENCE" read)
  assert_equals on "$out" "an empty FM_HOME must read as unset"
  pass "Calm preference resolves FM_HOME, FM_ROOT_OVERRIDE, and FM_CONFIG_OVERRIDE like Pi"
}

test_context_only_when_on() {
  local home out
  home=$(make_home "$TMP_ROOT/context")
  out=$(pref "$home" context)
  [ -z "$out" ] || fail "context must be empty while Calm is off: $out"
  printf 'max\n' >"$home/config/calm"
  out=$(pref "$home" context)
  assert_contains "$out" "FIRSTMATE CALM is on" "legacy max must inject the Cursor policy"
  assert_contains "$out" "no transcript-row filter" "the policy must name the Cursor gap"
  assert_contains "$out" "Keep using tools normally" "the policy must preserve tool execution"
  assert_not_contains "$out" "sailboat" "the policy must not claim a Cursor boat"
  printf 'off\n' >"$home/config/calm"
  out=$(pref "$home" context)
  [ -z "$out" ] || fail "context must be empty while Calm is off after a toggle: $out"
  pass "Calm context prints the Cursor policy only while the preference is on"
}

test_skill_wiring() {
  local link resolved skill name invocable
  link="$ROOT/.cursor/skills/calm"
  [ -L "$link" ] || fail "Cursor /calm is not linked at .cursor/skills/calm"
  [ "$(readlink "$link")" = "../../.agents/skills/calm" ] \
    || fail "the Cursor calm link must be ../../.agents/skills/calm, got $(readlink "$link")"
  resolved=$(cd "$link" && pwd -P) || fail "the Cursor calm link does not resolve"
  [ "$resolved" = "$(cd "$ROOT/.agents/skills/calm" && pwd -P)" ] \
    || fail "the Cursor calm link resolves to $resolved, not .agents/skills/calm"
  skill="$ROOT/.agents/skills/calm/SKILL.md"
  [ -f "$skill" ] || fail "the Calm skill is missing"
  name=$(sed -n '/^---$/,/^---$/p' "$skill" | awk -F': *' '$1=="name"{print $2; exit}')
  invocable=$(sed -n '/^---$/,/^---$/p' "$skill" | awk -F': *' '$1=="user-invocable"{print $2; exit}')
  [ "$name" = calm ] || fail "the skill name must be calm, got $name"
  [ "$invocable" = true ] || fail "the skill must be user-invocable, got $invocable"
  pass "Cursor /calm is wired as a user-invocable skill through .cursor/skills/calm"
}

install_session_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/config" "$dir/state"
  cp "$PREFERENCE" "$dir/bin/fm-calm-preference.sh"
  cp "$SESSIONSTART" "$dir/bin/fm-sessionstart-cursor.sh"
  chmod +x "$dir/bin/"*.sh
}

test_sessionstart_injects_policy_when_on() {
  local dir out ctx
  dir="$TMP_ROOT/session-on"
  install_session_fixture "$dir"
  cat >"$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'FIRSTMATE DIGEST "quoted" line\nsecond line\n'
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh"
  printf 'on\n' >"$dir/config/calm"
  out=$(FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-cursor.sh" --source startup)
  ctx=$(printf '%s' "$out" | jq -r '.additional_context // empty')
  assert_contains "$ctx" 'FIRSTMATE DIGEST "quoted" line' "the digest must still reach model context"
  assert_contains "$ctx" 'second line' "the digest must not truncate at the first line"
  assert_contains "$ctx" 'FIRSTMATE CALM is on' "Calm on must append the Cursor policy"
  printf 'off\n' >"$dir/config/calm"
  out=$(FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-cursor.sh" --source startup)
  ctx=$(printf '%s' "$out" | jq -r '.additional_context // empty')
  assert_contains "$ctx" 'FIRSTMATE DIGEST "quoted" line' "Calm off must still inject the digest"
  assert_not_contains "$ctx" 'FIRSTMATE CALM is on' "Calm off must not inject the Cursor policy"
  pass "Cursor sessionStart appends Calm policy only while config/calm is on"
}

test_sessionstart_policy_without_digest() {
  local dir out ctx
  dir="$TMP_ROOT/session-child"
  install_session_fixture "$dir"
  cat >"$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh"
  out=$(FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-cursor.sh" --source startup)
  [ -z "$out" ] || fail "Calm off with no digest must stay silent, got: $out"
  printf 'on\n' >"$dir/config/calm"
  out=$(FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-cursor.sh" --source startup)
  ctx=$(printf '%s' "$out" | jq -r '.additional_context // empty')
  assert_contains "$ctx" 'FIRSTMATE CALM is on' "a helm-silent open must still inject Calm policy when on"
  assert_not_contains "$ctx" 'FIRSTMATE DIGEST' "a helm-silent open must not invent a digest"
  pass "Cursor sessionStart injects Calm policy without taking the helm"
}

test_read_absent_unrecognized_max_on_off
test_write_is_atomic_and_mode_0600
test_toggle_flips_and_failed_write_leaves_choice
test_home_resolution_matches_pi
test_context_only_when_on
test_skill_wiring
test_sessionstart_injects_policy_when_on
test_sessionstart_policy_without_digest
