#!/usr/bin/env bash
# Live guard for the supervision host's dialog-mirror writers
# (bin/fm-host-mirror.sh, docs/supervision-host.md "The dialog mirror"): each
# INSTALLED primary harness with a mirror writer (Claude and Cursor)
# runs one real prompt in a fixture primary checkout that carries this repo's
# tracked mirror registrations, and the mirror must record the captain's prompt
# and main's reply. The writers read vendor hook payloads, so only the real
# harness can prove them. Opt-in because it submits prompts:
#
#   FM_HOST_MIRROR_LIVE_E2E=1 tests/fm-host-mirror-live-e2e.test.sh
#
# FM_HOST_MIRROR_LIVE_HARNESSES (default "claude cursor") narrows the set. An
# absent harness is reported, never passed over silently, and a run that
# checked no harness fails. Cursor fires project hooks only in an interactive
# session, and Claude must show that a turn it starts itself (its Stop-hook
# rewake, which it submits as a prompt) is not mirrored as the captain's
# words, so every harness runs in a private tmux server.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_HOST_MIRROR_LIVE_E2E jq tmux

HARNESSES=${FM_HOST_MIRROR_LIVE_HARNESSES:-claude cursor}
LAB=$(fm_test_tmproot fm-host-mirror-live)
SOCKET="fmhm-$$"
PROMPT='Reply with exactly the word mirror-ok and nothing else.'
CHECKED=0
ABSENT=

cleanup() {
  local harness
  # One private tmux server per harness, so a server that is shutting down
  # after one harness's session ends can never swallow the next session.
  for harness in claude cursor; do
    tmux -L "$SOCKET-$harness" kill-server >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TMUX TMUX_PANE

# A primary checkout carrying only the tracked mirror registrations, so no
# other hook of this repo runs in it.
make_primary() {  # <name>
  local root="$LAB/$1"
  mkdir -p "$root/state" "$root/config" "$root/.claude" "$root/.cursor"
  git init -q "$root"
  : > "$root/AGENTS.md"
  : > "$root/config/supervision-host"
  ln -s "$ROOT/bin" "$root/bin"
  jq '.hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command | contains("fm-host-mirror.sh")))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0))) | {hooks}' \
    "$ROOT/.claude/settings.json" > "$root/.claude/settings.json"
  jq '.hooks |= (with_entries(.value |= map(select(.command | contains("fm-host-mirror.sh")))) | with_entries(select(.value | length > 0)))' \
    "$ROOT/.cursor/hooks.json" > "$root/.cursor/hooks.json"
  printf '%s\n' "$root"
}

mirrored() {  # <root> <tag> <fixed text>
  jq -r --arg tag "$2" 'select(.tag == $tag) | .text' "$1/state/.host-mirror.jsonl" 2>/dev/null | grep -F -- "$3" >/dev/null
}

wait_mirrored() {  # <root> <seconds>
  local i=0
  while [ "$i" -lt "$(( $2 * 2 ))" ]; do
    mirrored "$1" captain "$PROMPT" && mirrored "$1" main mirror-ok && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

check() {  # <harness> <version> <root>
  if mirrored "$3" captain "$PROMPT" && mirrored "$3" main mirror-ok; then
    printf 'ok - %s %s: the tracked registrations mirrored the captain prompt and main reply\n' "$1" "$2"
    CHECKED=$((CHECKED + 1))
    return 0
  fi
  fail "$1 $2: the mirror did not record the captain prompt and main reply: $(cat "$3/state/.host-mirror.jsonl" 2>/dev/null)"
}

# The harness process records its own pid as the session lock, then execs the
# harness, so the lock holder is the harness that fires the hooks.
LOCKED_EXEC='printf "%s\n" "$$" > state/.lock; exec "$@"'

# Claude runs interactively with one extra Stop hook that rewakes the session
# once, as the supervision host's own handback does, so the guard also proves
# that a harness-started turn is never mirrored as the captain's words.
run_claude() {
  local root
  root=$(make_primary claude)
  cat > "$root/rewake-once.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
dir=$(cd "$(dirname "$0")" && pwd)
[ ! -e "$dir/rewake.done" ] || exit 0
: > "$dir/rewake.done"
sleep 2
echo "lab rewake: reply with exactly the word mirror-rewake-ok" >&2
exit 2
SH
  chmod +x "$root/rewake-once.sh"
  jq '.hooks.Stop += [{hooks: [{type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/rewake-once.sh", asyncRewake: true, timeout: 60}]}]' \
    "$root/.claude/settings.json" > "$root/.claude/settings.json.tmp" && mv "$root/.claude/settings.json.tmp" "$root/.claude/settings.json"
  REWAKE_WANTED=mirror-rewake-ok run_interactive claude claude --model haiku --dangerously-skip-permissions
}

# An interactive session in a private tmux server: answer a trust prompt when
# one appears, type the prompt, and wait for the mirror.
run_interactive() {  # <harness> <command> [arguments...]
  local harness=$1 command=$2 root version i screen
  shift 2
  version=$("$command" --version 2>/dev/null | head -n 1)
  root="$LAB/$harness"
  [ -d "$root" ] || root=$(make_primary "$harness")
  tmux -L "$SOCKET-$harness" new-session -d -s "$harness" -x 200 -y 50 -c "$root" \
    "sh -c '$LOCKED_EXEC' sh $command $*" || fail "$harness $version: the tmux session did not start"
  i=0
  while [ "$i" -lt 60 ]; do
    screen=$(tmux -L "$SOCKET-$harness" capture-pane -p -t "$harness" 2>/dev/null)
    # A key sent to a dialog is followed by a pause long enough for the
    # harness to redraw, so the same dialog is never answered twice.
    case "$screen" in
      *'[a] Trust this workspace'*) tmux -L "$SOCKET-$harness" send-keys -t "$harness" a; sleep 3 ;;
      *'Yes, I trust this folder'*|*'Trust all and continue'*)
        tmux -L "$SOCKET-$harness" send-keys -t "$harness" Down; sleep 0.5; tmux -L "$SOCKET-$harness" send-keys -t "$harness" Enter; sleep 3 ;;
      *'1. Yes, continue'*) tmux -L "$SOCKET-$harness" send-keys -t "$harness" Enter; sleep 3 ;;
      *'bypass permissions on'*) break ;;
      *'Do you trust the contents of this directory'*) tmux -L "$SOCKET-$harness" send-keys -t "$harness" y; sleep 3 ;;
      *'Plan, search, build'*) break ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  sleep 3
  tmux -L "$SOCKET-$harness" send-keys -t "$harness" -l "$PROMPT"
  sleep 1
  tmux -L "$SOCKET-$harness" send-keys -t "$harness" Enter
  if ! wait_mirrored "$root" 180; then
    tmux -L "$SOCKET-$harness" capture-pane -p -t "$harness" > "$LAB/$harness.screen" 2>/dev/null || true
  fi
  if [ -n "${REWAKE_WANTED:-}" ]; then
    i=0
    while [ "$i" -lt 240 ] && ! mirrored "$root" main "$REWAKE_WANTED"; do sleep 0.5; i=$((i + 1)); done
    mirrored "$root" main "$REWAKE_WANTED" || fail "$harness $version: the harness-started turn never ran, so the guard proved nothing about it"
    [ "$(jq -r 'select(.tag == "main") | .seq' "$root/state/.host-mirror.jsonl" | wc -l)" -ge 2 ] \
      || fail "$harness $version: no second turn was mirrored, so the guard proved nothing about a harness-started turn"
    if jq -r 'select(.tag == "captain") | .text' "$root/state/.host-mirror.jsonl" \
      | grep -E 'task-notification|lab rewake|Stop hook' >/dev/null; then
      fail "$harness $version: a turn the harness started itself was mirrored as the captain's words: $(cat "$root/state/.host-mirror.jsonl")"
    fi
    printf 'ok - %s %s: a turn the harness started itself was not mirrored as the captain'"'"'s words\n' "$harness" "$version"
  fi
  tmux -L "$SOCKET-$harness" kill-session -t "$harness" >/dev/null 2>&1 || true
  check "$harness" "$version" "$root"
}

for harness in $HARNESSES; do
  case "$harness" in
    claude) bin=$harness ;;
    cursor) bin=cursor-agent ;;
    *) fail "unknown harness in FM_HOST_MIRROR_LIVE_HARNESSES: $harness" ;;
  esac
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'absent - %s is not installed, so its mirror writer was not checked\n' "$harness"
    ABSENT="$ABSENT $harness"
    continue
  fi
  case "$harness" in
    claude) run_claude ;;
    cursor) run_interactive cursor cursor-agent ;;
  esac
done

[ "$CHECKED" -gt 0 ] || fail "no installed harness was checked (absent:${ABSENT:- none})"
pass "host mirror live: $CHECKED harness(es) proved their writers${ABSENT:+; absent:$ABSENT}"
