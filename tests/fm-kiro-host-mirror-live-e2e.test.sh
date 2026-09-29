#!/usr/bin/env bash
# Opt-in live proof of the supervision host's Kiro dialog-mirror writer
# (bin/fm-host-mirror.sh "WRITERS", called by bin/fm-kiro-turnend-hook.sh).
#
# Builds a Firstmate-shaped clone of the current working files with
# config/supervision-host present, launches a real kiro-cli 2.24.1 primary
# through bin/fm-kiro-primary.sh in a private tmux server, and submits two
# small prompts. The mirror must then hold, in order and under one main-session
# key, the FIRST captain prompt (Kiro activates SessionStart lazily with it, so
# this is the property most at risk), main's reply to it, the second prompt,
# and main's reply to that, with no doorbell text mirrored as the captain's.
# The home registers no task or source, so no supervision is needed and no
# watcher or engine runs; with the flag present the doorbell owner would run
# the host only when supervision is needed. Submits two small prompts:
#
#   FM_KIRO_MIRROR_LIVE_E2E=1 FM_KIRO_LIVE_MODEL=claude-sonnet-5 tests/fm-kiro-host-mirror-live-e2e.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIRO_MIRROR_LIVE_E2E tmux kiro-cli git tar jq

REAL_TMUX=$(command -v tmux) || fail "tmux not found"
KIRO_BIN=$(command -v kiro-cli) || fail "kiro-cli not found"
case "$("$KIRO_BIN" --version 2>/dev/null)" in
  'kiro-cli 2.24.1') ;;
  *) fail "Kiro mirror proof requires the recorded 2.24.1 surface" ;;
esac

LAB=$(fm_test_tmproot fm-kiro-host-mirror-live)
PRIMARY="$LAB/firstmate"
mkdir -p "$PRIMARY"
# The current working files, tracked or new, so an uncommitted branch is what
# runs; a tracked file deleted in the working tree is left out.
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard \
  | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done) \
  | tar -C "$ROOT" --null -T - -cf - | tar -C "$PRIMARY" -xf -
rm -rf "$PRIMARY/.git"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" symbolic-ref HEAD refs/heads/main
mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects"
printf 'claude\n' > "$PRIMARY/config/supervision-host"

SOCK="$LAB/tmux.sock"
SESSION=kiro-mirror-live
LOGIN_HOME=${FM_KIRO_LIVE_LOGIN_HOME:-$HOME}
MIRROR_FILE="$PRIMARY/state/.host-mirror.jsonl"
IDLE='ask a question or describe a task'
PROMPT1='Reply with exactly MIRRORONE.'
PROMPT2='Reply with exactly MIRRORTWO.'

tm() { env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" "$@"; }
pane_history() { tm capture-pane -p -S - -t "$SESSION" 2>/dev/null || true; }
visible() { tm capture-pane -p -t "$SESSION" 2>/dev/null || true; }

cleanup() {
  local owner
  tm kill-server 2>/dev/null || true
  owner=$(cat "$PRIMARY/state/.primary-doorbell.lock/pid" 2>/dev/null || true)
  [ -z "$owner" ] || kill "$owner" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

diagnose() {  # <message>
  pane_history | tail -80 >&2
  printf '# mirror:\n' >&2
  cat "$MIRROR_FILE" >&2 2>/dev/null || printf '# mirror absent\n' >&2
  printf '# pre-logic hook probe:\n' >&2
  cat "$PRIMARY/state/.kiro-hook-probe" >&2 2>/dev/null || printf '# probe absent\n' >&2
  fail "$1"
}

mirrored_main() {  # <fixed text>
  jq -r 'select(.tag == "main") | .text' "$MIRROR_FILE" 2>/dev/null | grep -Fq -- "$1"
}

submit_and_wait() {  # <prompt> <expected reply>
  local i=0
  tm set-buffer -- "$1"
  tm paste-buffer -d -t "$SESSION"
  tm send-keys -t "$SESSION" Enter
  while [ "$i" -lt "${FM_KIRO_MIRROR_TURN_TIMEOUT:-240}" ]; do
    mirrored_main "$2" && visible | grep -Fq "$IDLE" && return 0
    sleep 1
    i=$((i + 1))
  done
  diagnose "the mirror never recorded main's $2 reply with the primary back at idle"
}

tm new-session -d -s "$SESSION" -x 200 -y 55 -c "$PRIMARY" -- \
  env HOME="$LOGIN_HOME" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" \
  FM_KIRO_HOOK_PROBE_FILE="$PRIMARY/state/.kiro-hook-probe" \
  "$PRIMARY/bin/fm-kiro-primary.sh" ${FM_KIRO_LIVE_MODEL:+--model "$FM_KIRO_LIVE_MODEL"}

i=0
while [ "$i" -lt "${FM_KIRO_MIRROR_READY_TIMEOUT:-180}" ]; do
  visible | grep -Fq "$IDLE" && break
  sleep 1
  i=$((i + 1))
done
visible | grep -Fq "$IDLE" || diagnose "real Kiro primary never reached its initial composer"

submit_and_wait "$PROMPT1" MIRRORONE
submit_and_wait "$PROMPT2" MIRRORTWO

# The four dialog entries, in order, under one key.
got=$(jq -r '"\(.tag)|\(.text)"' "$MIRROR_FILE")
first_captain=$(jq -r 'select(.tag == "captain") | .text' "$MIRROR_FILE" | head -n 1)
[ "$first_captain" = "$PROMPT1" ] || diagnose "the first captain entry is not the first prompt (got: $first_captain)"
order=$(printf '%s\n' "$got" | awk -F '|' -v p1="$PROMPT1" -v p2="$PROMPT2" '
  $0 == "captain|" p1 && step == 0 { step = 1; next }
  $1 == "main" && index($0, "MIRRORONE") && step == 1 { step = 2; next }
  $0 == "captain|" p2 && step == 2 { step = 3; next }
  $1 == "main" && index($0, "MIRRORTWO") && step == 3 { step = 4; next }
  END { print step + 0 }')
[ "$order" = 4 ] || diagnose "the mirror does not hold both prompts and replies in order (matched $order of 4)"
[ "$(jq -r '.key' "$MIRROR_FILE" | sort -u | wc -l | tr -d ' ')" = 1 ] \
  || diagnose "the mirror's entries do not share one main-session key"
! jq -r '.text' "$MIRROR_FILE" | grep -q '^: Firstmate ' || diagnose "a doorbell prompt was mirrored"
pass "live Kiro: the mirror holds the first prompt, its reply, the second prompt, and its reply, in order under one main-session key"
pass "live Kiro: no doorbell prompt was mirrored as captain dialog"
printf '%s\n' "$got" | sed 's/^/# mirrored: /'

trap - EXIT
cleanup
printf '%s\n' 'ok - Kiro 2.24.1 dialog mirror live proof passed'
