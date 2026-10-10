#!/usr/bin/env bash
# Token-free live Pi composer guard: the dollar-first subscription footer must
# not turn an empty composer into unknown, and real drafts must remain pending.
# Runs by default with Pi + tmux; FM_COMPOSER_PI_IDLE_LIVE=1 forces the guard
# and =0 disables it. No prompt, provider request, or real credential is used.
# Refresh docs/verification/runtime-backends.md after a Pi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pi_gate=pi
command -v pi >/dev/null 2>&1 || pi_gate=pi-signed
fm_live_gate default-on FM_COMPOSER_PI_IDLE_LIVE tmux "$pi_gate"

LAB=$(fm_test_tmproot fm-composer-pi-live)
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
LAB_HOME=$("$LAB_HOME_HELPER" create "$LAB/home") || fail "cannot create lab home"
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$LAB_HOME") || fail "cannot create private tmux socket directory"
REAL_TMUX=$(command -v tmux)
cleanup() {
  local rc=$?
  TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L composer kill-server 2>/dev/null || true
  "$LAB_HOME_HELPER" teardown "$LAB_HOME" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$LAB/shim" "$LAB/cwd" "$LAB/pi"
# Adapter calls share exactly this private server; no ambient fleet socket.
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec env TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L composer "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

# Only the credential TYPE is relevant: it selects Pi's real subscription
# footer. These deliberately unusable values are never sent anywhere.
printf '%s\n' '{"openai-codex":{"type":"oauth","access":"fixture-unused","refresh":"fixture-unused","expires":4102444800000}}' \
  > "$LAB/pi/auth.json"
CAPS=$'styled=1\ncursor=0\nidentity=1'
CHECKED=0

cursorless_verdict() {
  local screen=$1 identity=$2
  fm_composer_classify_screen "$CAPS" "$screen" '' "$identity"
}

check_drafts() {  # <executable> <version> <identity>
  local binary=$1 version=$2 identity=$3 draft screen anchored cursorless i
  # Even a prompt glyph or a footer-looking string INSIDE Pi's composer is
  # actual pending input. Never press Enter, and never append to that input.
  for draft in 'draft-not-submitted' '❯' "\$0.000 (sub)" 'Type a message...'; do
    tmux send-keys -t "$binary" -l "$draft"
    for ((i=0; i<100; i++)); do
      screen=$(tmux capture-pane -e -p -t "$binary")
      anchored=$(fm_tmux_composer_state "$binary")
      cursorless=$(cursorless_verdict "$screen" "$identity")
      [ "$anchored" = pending ] && [ "$cursorless" = pending ] && break
      sleep 0.1
    done
    [ "$i" -lt 100 ] || fail "$binary ($version): real draft '$draft' was not pending (tmux=$anchored, cursorless=$cursorless)"
    tmux send-keys -t "$binary" C-u
    for ((i=0; i<100; i++)); do
      screen=$(tmux capture-pane -e -p -t "$binary")
      [ "$(cursorless_verdict "$screen" "$identity")" = empty ] && break
      sleep 0.1
    done
    [ "$i" -lt 100 ] || fail "$binary ($version): Ctrl+U never restored empty composer"
  done
  pass "$binary ($version): real drafts including glyph-only and cost-like text remain pending until cleared"
}

check_pi() {  # <executable>
  local binary=$1 version help screen='' identity='' anchored='' cursorless='' i out
  local -a pi_command=(
    env -u HERDR_ENV -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SESSION
    HOME="$LAB_HOME" PI_CODING_AGENT_DIR="$LAB/pi"
    "$binary" --provider openai-codex --model gpt-6.1-sol --thinking xhigh
    --offline --no-session --no-extensions --no-skills --no-prompt-templates --no-themes
  )
  version=$(cd "$LAB/cwd" && "${pi_command[@]}" --version 2>/dev/null | head -1)
  [ -n "$version" ] || fail "$binary: could not read version"
  help=$(cd "$LAB/cwd" && "${pi_command[@]}" --help 2>&1)
  local -a display=() trust=()
  if printf '%s' "$help" | grep -q -- '--tui-mode'; then display=(--tui-mode regular); fi
  if printf '%s' "$help" | grep -q -- '--approve'; then trust=(--approve); fi
  tmux new-session -d -s "$binary" -x 160 -y 40 -c "$LAB/cwd" -- \
    "${pi_command[@]}" ${display[@]+"${display[@]}"} ${trust[@]+"${trust[@]}"} \
    || fail "$binary ($version): could not launch in private tmux server"
  for ((i=0; i<150; i++)); do
    screen=$(tmux capture-pane -e -p -t "$binary" 2>/dev/null) || screen=''
    identity=$(fm_tmux_composer_identity "$binary" 2>/dev/null) || identity=probe-absent
    anchored=$(fm_tmux_composer_state "$binary")
    cursorless=$(cursorless_verdict "$screen" "$identity")
    if [ "$anchored" = empty ] && [ "$cursorless" = empty ] \
       && printf '%s\n' "$screen" | fm_composer_strip_ansi | grep -q '^[$]0[.]000 [(]sub[)]'; then break; fi
    sleep 0.2
  done
  [ "$i" -lt 150 ] || fail "$binary ($version): no proven idle dollar-first footer (tmux=$anchored, cursorless=$cursorless):
$(printf '%s\n' "$screen" | fm_composer_strip_ansi)"
  # Separate the independent signals: without Pi identity a blank region is
  # not a composer. Without styling, identity + truly blank content still is.
  out=$(cursorless_verdict "$screen" probe-absent)
  [ "$out" = unknown ] || fail "$binary ($version): absent identity yielded $out"
  out=$(fm_composer_classify_screen $'styled=0\ncursor=0\nidentity=1' \
    "$(printf '%s\n' "$screen" | fm_composer_strip_ansi)" '' "$identity")
  [ "$out" = empty ] || fail "$binary ($version): blank plain capture yielded $out"
  pass "$binary ($version): real dollar-first idle footer is empty on tmux and cursorless reads; absent identity refuses"

  check_drafts "$binary" "$version" "$identity"
  tmux kill-session -t "$binary"
  CHECKED=$((CHECKED + 1))
}

for binary in pi pi-signed; do
  if command -v "$binary" >/dev/null 2>&1; then
    check_pi "$binary"
  else
    printf '# harness absent, not verified here: %s\n' "$binary"
  fi
done
[ "$CHECKED" -gt 0 ] || fail "no installed Pi harness verified"
pass "Pi composer live guard verified $CHECKED installed harness(es) without a provider request"
