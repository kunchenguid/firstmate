#!/usr/bin/env bash
# The real OpenCode composer must be provably empty through Herdr's ANSI
# capture, including when its bounded tail starts on the idle hint.
# Every Herdr operation is scoped by the guarded named lab session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_OPENCODE_HERDR_COMPOSER_LIVE herdr jq opencode

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-opencode-perm) || exit 1
cleanup() {
  local status=$?
  trap - EXIT
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision the guarded Herdr lab'
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
fm_backend_herdr_cli() {  # <session> <Herdr arguments...>
  shift
  lab "$@"
}

created=$(lab workspace create --cwd "$ROOT" --label fm-opencode-composer --no-focus) \
  || fail 'could not create the OpenCode lab workspace'
pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id') \
  || fail 'the OpenCode lab workspace returned no pane id'
lab pane run "$pane" opencode >/dev/null || fail 'could not launch OpenCode in the lab pane'

version=$(opencode --version 2>/dev/null || printf 'unknown')
herdr_version=$(lab status --json | jq -r '.client.version // "unknown"')
verdict=unknown
for _ in $(seq 1 45); do
  state=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  if [ "$state" = idle ] || [ "$state" = "done" ]; then
    verdict=$(fm_backend_herdr_composer_state "$HERDR_LAB_SESSION:$pane")
    [ "$verdict" = empty ] && break
  fi
  sleep 1
done
[ "$verdict" = empty ] \
  || fail "OpenCode $version on Herdr $herdr_version: idle composer classified $verdict, expected empty"
pass "OpenCode $version on Herdr $herdr_version: live idle composer is provably empty"

# fm-spawn always launches OpenCode with --prompt, so a real worker idles in
# the session view, whose footer below the composer is `<cwd> <tokens> ctrl+p
# commands`. That needs a working model, so it runs only when one is named.
model=${FM_OPENCODE_HERDR_COMPOSER_MODEL:-}
if [ -z "$model" ]; then
  printf 'skip - set FM_OPENCODE_HERDR_COMPOSER_MODEL to check the post---prompt session view\n'
  exit 0
fi
created=$(lab workspace create --cwd "$ROOT" --label fm-opencode-session --no-focus) \
  || fail 'could not create the OpenCode session lab workspace'
pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id') \
  || fail 'the OpenCode session lab workspace returned no pane id'
lab pane run "$pane" "opencode --model '$model' --prompt 'Reply with OK and nothing else.'" >/dev/null \
  || fail 'could not launch OpenCode with --prompt in the lab pane'
verdict=unknown worked=0
for _ in $(seq 1 120); do
  state=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  [ "$state" = working ] && worked=1
  if [ "$worked" = 1 ] && { [ "$state" = idle ] || [ "$state" = "done" ]; }; then
    verdict=$(fm_backend_herdr_composer_state "$HERDR_LAB_SESSION:$pane")
    [ "$verdict" = empty ] && break
  fi
  sleep 1
done
[ "$worked" = 1 ] || fail "OpenCode $version on Herdr $herdr_version: the --prompt turn never started"
[ "$verdict" = empty ] \
  || fail "OpenCode $version on Herdr $herdr_version: idle session-view composer after --prompt classified $verdict, expected empty"
pass "OpenCode $version on Herdr $herdr_version: idle session-view composer after a --prompt turn is provably empty"
