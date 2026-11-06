#!/usr/bin/env bash
# Live guard for the real, installed Bob (IBM Bob CLI) (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping. It drives the real
# TUI in a private tmux server and proves the harness-dependent facts the adapter
# encodes: the composer reads empty in English and in a translated locale, typed
# text reads pending, the cursor stays hidden while Bob owns the screen, the
# UserPromptSubmit hook fires in a trusted workspace, a tool subprocess carries
# BOB_SESSION and resolves bob by marker and by ancestry, the pane reads alive,
# and /exit returns to the shell.
#
# It spends no model tokens by default: without BOB_API_KEY in the environment it
# uses a placeholder key, which is enough for the TUI to render and for the
# prompt hook to fire before the provider refuses the request. HOME is private
# and carries bobShell.autoUpdate=false, because Bob otherwise runs
# `npm install -g --force` against the active node, outside any lab.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_BOB_SIGNALS_LIVE bob tmux

BOB_VERSION=$(bob --version 2>&1 | sed -n 1p)
echo "BOOTSTRAP_INFO: live bob version: $BOB_VERSION"

LAB=$(mktemp -d /tmp/fmbob.XXXXXX) || fail "could not create the isolated Bob lab"
unset TMUX
export TMUX_TMPDIR="$LAB"
lab_tmux() { tmux -f /dev/null "$@"; }
cleanup() {
  [ ! -S "$LAB/tmux-$(id -u)/default" ] || tmux -S "$LAB/tmux-$(id -u)/default" kill-server 2>/dev/null || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT

WORKSPACE=$(cd "$LAB" && pwd -P)/workspace
mkdir -p "$WORKSPACE/.bob" "$LAB/home/.bob/settings"
git -C "$WORKSPACE" init -q || fail "could not initialize the isolated Bob workspace"
printf '{"licenseConsent":true,"bobShell":{"autoUpdate":false}}\n' > "$LAB/home/.bob/settings/settings.json"
printf '{"version":1,"folders":{"%s":"TRUST_FOLDER"}}\n' "$WORKSPACE" > "$LAB/home/.bob/trustedFolders.json"
cat > "$LAB/hook.sh" <<SH
#!/usr/bin/env bash
{
  echo "marker=\${BOB_SESSION:-unset}"
  echo "own=\$('$ROOT/bin/fm-harness.sh')"
  echo "ancestry=\$('$ROOT/bin/fm-harness.sh' ancestry)"
} > '$LAB/hook.out' 2>&1
SH
chmod +x "$LAB/hook.sh"
printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
  "$LAB/hook.sh" > "$WORKSPACE/.bob/settings.json"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

composer_state() {  # <session>
  FM_COMPOSER_HARNESS=bob fm_backend_composer_state tmux "$1:bob"
}

wait_for_composer() {  # <session> <state>
  local i
  for ((i = 0; i < 80; i++)); do
    [ "$(composer_state "$1")" = "$2" ] && return 0
    sleep 0.5
  done
  return 1
}

check_locale() {  # <session> <LANG value> <expected placeholder fragment>
  local session=$1 lang=$2 fragment=$3 i
  lab_tmux new-session -d -s "$session" -x 120 -y 40 -n bob
  lab_tmux send-keys -t "$session:bob" -l \
    "env -u BOB_SESSION -u LC_ALL -u LC_MESSAGES LANG=$lang HOME='$LAB/home' BOB_API_KEY='${BOB_API_KEY:-placeholder-not-a-key}' bob chat --auto-approve --workspace '$WORKSPACE'"
  lab_tmux send-keys -t "$session:bob" Enter
  wait_for_composer "$session" empty \
    || fail "bob $BOB_VERSION under LANG=$lang: the composer never read empty: $(lab_tmux capture-pane -p -t "$session:bob" | tail -5)"
  lab_tmux capture-pane -p -t "$session:bob" | grep -Fq "$fragment" \
    || fail "bob $BOB_VERSION under LANG=$lang: expected placeholder '$fragment' is missing, so this case proved nothing"
  [ "$(lab_tmux display-message -p -t "$session:bob" '#{cursor_flag}')" = 0 ] \
    || fail "bob $BOB_VERSION: the cursor is visible while Bob owns the screen, which the ready gate reads as a stale frame"
  lab_tmux send-keys -t "$session:bob" -l 'fm guard typed text'
  wait_for_composer "$session" pending \
    || fail "bob $BOB_VERSION under LANG=$lang: typed text did not read pending"
  [ "$(lab_tmux display-message -p -t "$session:bob" '#{cursor_flag}')" = 0 ] \
    || fail "bob $BOB_VERSION: the cursor became visible with text in the composer"
  lab_tmux send-keys -t "$session:bob" Enter
  for ((i = 0; i < 40; i++)); do
    [ -s "$LAB/hook.out" ] && break
    sleep 0.5
  done
  [ -s "$LAB/hook.out" ] || fail "bob $BOB_VERSION under LANG=$lang: the UserPromptSubmit hook never fired"
  pass "bob $BOB_VERSION under LANG=$lang: composer, cursor and prompt hook"
}

check_locale fmbobde de_DE.UTF-8 'Baue Alles'

# The hook writes hook.out line by line, so wait for its last line before reading.
for ((i = 0; i < 60; i++)); do
  grep -q '^ancestry=' "$LAB/hook.out" 2>/dev/null && break
  sleep 0.5
done
out=$(cat "$LAB/hook.out")
assert_contains "$out" 'marker=1' "bob $BOB_VERSION: a hook subprocess did not inherit BOB_SESSION"
assert_contains "$out" 'own=bob' "bob $BOB_VERSION: fm-harness.sh did not name bob from a real subprocess"
assert_contains "$out" 'ancestry=comm bob' "bob $BOB_VERSION: the ancestry walk did not stop at Bob's own process"
pass "bob $BOB_VERSION: a real subprocess resolves bob by marker and by ancestry"

state=$(fm_backend_agent_state tmux fmbobde:bob)
[ "$state" = alive ] || fail "bob $BOB_VERSION: the pane reads '$state', not alive, so fm-control would refuse it"
pass "bob $BOB_VERSION: the pane reads alive"

wait_for_composer fmbobde empty || fail "bob $BOB_VERSION: the composer did not settle after the prompt"
lab_tmux send-keys -t fmbobde:bob -l '/exit'
sleep 1
lab_tmux send-keys -t fmbobde:bob Enter
for ((i = 0; i < 40; i++)); do
  case "$(lab_tmux display-message -p -t fmbobde:bob '#{pane_current_command}')" in
    bash|zsh|sh|fish) break ;;
  esac
  sleep 0.5
done
case "$(lab_tmux display-message -p -t fmbobde:bob '#{pane_current_command}')" in
  bash|zsh|sh|fish) pass "bob $BOB_VERSION: /exit returns to the shell" ;;
  *) fail "bob $BOB_VERSION: /exit did not stop the session" ;;
esac

rm -f "$LAB/hook.out"
check_locale fmboben en_US.UTF-8 'Build Anything'
