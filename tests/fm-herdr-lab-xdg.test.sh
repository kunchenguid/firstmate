#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh --isolated-xdg using a stateful fake
# Herdr client that links plugins through XDG_CONFIG_HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAL_HOME="$HOME"
TMP_ROOT=$(fm_test_tmproot fm-herdr-lab-xdg)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_HOME="$TMP_ROOT/fake-home"
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
mkdir -p "$FAKE_STATE" "$FAKE_HOME"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
# Herdr reads --session only as an option, so it must end the arguments or
# sit immediately before the first -- delimiter.
last=
for arg in "$@"; do
  [ "$arg" != -- ] || break
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing --session before any -- delimiter" >&2; exit 90; }
session=$last
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc '{sessions:[{default:true,name:"default",running:true,socket_path:"/tmp/fake-default.sock"}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:"/tmp/fake-default.sock"},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server --session")
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "plugin link")
    plugdir="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins"
    mkdir -p "$plugdir"
    printf '%s\n' "$3" > "$plugdir/$(basename "$3").link"
    printf 'XDG_CONFIG_HOME=%s\n' "${XDG_CONFIG_HOME:-<unset>}" >> "$FM_FAKE_HERDR_LOG"
    printf 'XDG_DATA_HOME=%s\n' "${XDG_DATA_HOME:-<unset>}" >> "$FM_FAKE_HERDR_LOG"
    printf 'XDG_STATE_HOME=%s\n' "${XDG_STATE_HOME:-<unset>}" >> "$FM_FAKE_HERDR_LOG"
    printf '%s\n' '{"ok":true}'
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

lab_cli() {
  PATH="$FAKEBIN:$PATH" HOME="$FAKE_HOME" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    bash "$ROOT/bin/fm-herdr-lab.sh" "$@"
}

test_isolated_lab_links_inside_lab_only() {
  local name="fm-lab-xdg-$$" base token="fm-xdg-proof-$$"
  local plugin_src="$TMP_ROOT/fake-plugin-$token"
  mkdir -p "$plugin_src"

  (unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
    lab_cli --isolated-xdg provision "$name") || fail "isolated provision failed"
  base="$TRIPWIRES/$name.xdg"
  for sub in config data state; do
    [ -d "$base/$sub" ] || fail "isolated provision did not create $base/$sub"
  done

  (unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
    lab_cli --isolated-xdg run "$name" plugin link "$plugin_src" >/dev/null) \
    || fail "isolated plugin link failed"
  assert_present "$base/config/herdr/plugins/fake-plugin-$token.link" \
    "isolated plugin link did not land under the lab XDG tree"
  [ "$(cat "$base/config/herdr/plugins/fake-plugin-$token.link")" = "$plugin_src" ] \
    || fail "isolated plugin link recorded the wrong source"
  assert_contains "$(grep -m1 '^XDG_CONFIG_HOME=' "$FAKE_LOG")" "$base/config" \
    "fake Herdr did not see the lab XDG_CONFIG_HOME"
  assert_contains "$(grep -m1 '^XDG_DATA_HOME=' "$FAKE_LOG")" "$base/data" \
    "fake Herdr did not see the lab XDG_DATA_HOME"
  assert_contains "$(grep -m1 '^XDG_STATE_HOME=' "$FAKE_LOG")" "$base/state" \
    "fake Herdr did not see the lab XDG_STATE_HOME"

  # The live tree is constantly rewritten by the running Herdr session, so a
  # whole-tree byte comparison would chase live activity. The targeted proof
  # instead: nothing linked in the lab exists anywhere under the live tree.
  [ -z "$(find "$REAL_HOME/.config/herdr" -name "*${token}*" 2>/dev/null)" ] \
    || fail "a lab-linked plugin name leaked into the live Herdr tree"
  grep -rF -q --exclude-dir=sessions "$token" "$REAL_HOME/.config/herdr" 2>/dev/null \
    && fail "lab plugin content leaked into the live Herdr registry"

  (unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
    lab_cli --isolated-xdg teardown "$name") || fail "isolated teardown failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "isolated teardown left its tripwire behind"
  assert_absent "$base" "isolated teardown left its XDG tree behind"
  pass "fm-herdr-lab: --isolated-xdg links plugins inside the lab and leaves the live Herdr registry untouched"
}

test_default_behavior_still_inherits_caller_xdg() {
  local name="fm-lab-xdg-default-$$" plugin_src="$TMP_ROOT/fake-plugin-default"
  local sentinel="$FAKE_HOME/sentinel"
  mkdir -p "$plugin_src" "$sentinel/config" "$sentinel/data" "$sentinel/state"
  : > "$FAKE_LOG"
  XDG_CONFIG_HOME="$sentinel/config" XDG_DATA_HOME="$sentinel/data" XDG_STATE_HOME="$sentinel/state" \
    lab_cli provision "$name" || fail "default provision failed"
  assert_absent "$TRIPWIRES/$name.xdg" "default provision created an isolated XDG tree unasked"

  XDG_CONFIG_HOME="$sentinel/config" XDG_DATA_HOME="$sentinel/data" XDG_STATE_HOME="$sentinel/state" \
    lab_cli run "$name" plugin link "$plugin_src" >/dev/null || fail "default plugin link failed"
  assert_present "$sentinel/config/herdr/plugins/fake-plugin-default.link" \
    "default plugin link did not follow the caller's XDG_CONFIG_HOME"
  assert_contains "$(grep -m1 '^XDG_CONFIG_HOME=' "$FAKE_LOG")" "$sentinel/config" \
    "default run did not inherit the caller's XDG environment unchanged"

  XDG_CONFIG_HOME="$sentinel/config" XDG_DATA_HOME="$sentinel/data" XDG_STATE_HOME="$sentinel/state" \
    lab_cli teardown "$name" || fail "default teardown failed"
  pass "fm-herdr-lab: without the flag every Herdr call inherits the caller XDG environment unchanged"
}

test_help_names_the_flag() {
  local help
  help=$(lab_cli --help) || fail "--help failed"
  assert_contains "$help" "--isolated-xdg" "--help does not document the isolated-XDG flag"
  pass "fm-herdr-lab: --help documents --isolated-xdg"
}

test_isolated_lab_links_inside_lab_only
test_default_behavior_still_inherits_caller_xdg
test_help_names_the_flag
