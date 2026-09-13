#!/usr/bin/env bash
# Live Codex guard for the Stop-hook-owned supervision path.
#
# bin/fm-codex-stop-autoarm.sh rests on three facts about the installed Codex
# that no stub can confirm, because each is something the vendor emits:
#
#   1. `codex queue --thread <id> --message <text>` exists and is how an external
#      process reaches a running session. This is the delivery channel; if the
#      flag shape changes, every wake stops arriving.
#   2. A Codex `Stop` hook fires in an interactive session and hands the hook its
#      own `session_id`, which is the thread id delivery needs.
#   3. `"async": true` is honored on that Stop hook - the turn completes while the
#      hook still runs - AND the async hook's exit status and stderr are
#      DISCARDED. The second half is why the auto-arm queues a message instead of
#      copying Claude's exit-2 rewake; if Codex ever started honoring exit 2 here,
#      that would be worth knowing rather than silently unused.
#
# Tier 1 (token-free, runs wherever codex is installed) proves fact 1.
# Tier 2 (opt-in, spends tokens) drives a real interactive Codex under tmux and
# proves facts 2 and 3 end to end.
#
# Both tiers fail naming the codex version rather than degrading quietly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CODEX_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_VERSION=$(codex --version 2>/dev/null || printf 'unknown')
TMP_ROOT=$(fm_test_tmproot fm-codex-continuity-live)

die() {
  printf 'not ok - codex %s: %s\n' "$CODEX_VERSION" "$1" >&2
  exit 1
}

# --- tier 1: the delivery channel --------------------------------------------

test_queue_surface_exists() {
  local help out rc=0
  help=$(codex queue --help 2>&1) || die "codex queue is missing, so no wake can reach a running session"
  case "$help" in
    *--thread*) ;;
    *) die "codex queue no longer accepts --thread, which bin/fm-codex-stop-autoarm.sh uses to address the session" ;;
  esac
  case "$help" in
    *--message*) ;;
    *) die "codex queue no longer accepts --message" ;;
  esac

  # A thread that cannot exist must fail loudly, so a wake aimed at a dead
  # session is a bounded actionable error rather than a silent success.
  out=$(codex queue --thread fm-live-guard-not-a-thread --message probe 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || die "codex queue reported success for an impossible thread id"
  case "$out" in
    *[Ee]rror*|*not\ found*|*No\ active\ session*) ;;
    *) die "codex queue failed for an impossible thread without an identifiable error: $out" ;;
  esac
  printf 'ok - codex %s: queue --thread/--message is the live delivery channel and refuses an impossible thread\n' "$CODEX_VERSION"
}

# --- tier 2: the Stop hook contract, end to end -------------------------------

test_async_stop_hook_contract() {
  case "${FM_CODEX_LIVE_STOP_E2E:-${FM_LIVE:-}}" in
    1) ;;
    *)
      printf 'skip: live: interactive Stop-hook proof is opt-in; set FM_CODEX_LIVE_STOP_E2E=1 to run\n'
      return 0
      ;;
  esac
  command -v tmux >/dev/null 2>&1 || die "FM_CODEX_LIVE_STOP_E2E was requested but tmux is not installed"

  local lab project codex_home session marker i
  lab="$TMP_ROOT/stop-e2e"
  project="$lab/project"
  codex_home="$lab/codex-home"
  mkdir -p "$project/.codex" "$codex_home"
  printf 'Answer in one short word. Do not run any tools.\n' > "$project/AGENTS.md"
  [ -e "$HOME/.codex/auth.json" ] || die "no Codex credentials at ~/.codex/auth.json"
  ln -s "$HOME/.codex/auth.json" "$codex_home/auth.json"
  printf '[features]\nhooks = true\n\n[projects."%s"]\ntrust_level = "trusted"\n' \
    "$project" > "$codex_home/config.toml"

  # The hook records its payload, keeps running well past the turn end, and then
  # exits 2 with a banner on stderr. If Codex ever delivered that banner, the
  # transcript would show it.
  cat > "$lab/stop-hook.sh" <<HOOK
#!/usr/bin/env bash
LAB=$(printf '%q' "$lab")
cat > "\$LAB/payload.json" 2>/dev/null || true
date +%s > "\$LAB/hook-started"
sleep 6
date +%s > "\$LAB/hook-finished"
printf 'FM-LIVE-GUARD-EXIT2-BANNER\n' >&2
exit 2
HOOK
  chmod +x "$lab/stop-hook.sh"
  printf '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": %s, "timeout": 120, "async": true } ] } ] } }\n' \
    "\"$lab/stop-hook.sh\"" > "$project/.codex/hooks.json"

  session="fm-codex-live-$$"
  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" -x 200 -y 50 \
    "cd '$project' && CODEX_HOME='$codex_home' codex --dangerously-bypass-hook-trust --sandbox read-only"
  # shellcheck disable=SC2064 # The session name is fixed at trap time on purpose.
  trap "tmux kill-session -t '$session' 2>/dev/null || true" EXIT

  for i in $(seq 1 60); do
    tmux capture-pane -p -t "$session" 2>/dev/null | grep -q 'Ask Codex' && break
    sleep 1
  done
  tmux capture-pane -p -t "$session" 2>/dev/null | grep -q 'Ask Codex' \
    || die "the interactive Codex session never became ready"

  # Text and Enter go in separate writes on purpose: sent in one burst, the
  # Codex composer swallows the Enter and the turn never starts.
  tmux send-keys -t "$session" 'Say OK'
  sleep 2
  tmux send-keys -t "$session" Enter
  for i in $(seq 1 90); do
    [ -e "$lab/hook-started" ] && break
    sleep 1
  done
  [ -e "$lab/hook-started" ] || die "the Stop hook never fired in an interactive session"

  # Fact 2: the payload carries the thread id delivery needs.
  command -v jq >/dev/null 2>&1 || die "jq is required to read the Stop payload"
  local sid
  sid=$(jq -r '.session_id // empty' "$lab/payload.json" 2>/dev/null)
  [ -n "$sid" ] || die "the Stop payload carried no session_id, so a wake has no thread to address"

  # Fact 3a: async is honored - the turn ends while the hook still runs. The
  # composer coming back before the hook finishes is what proves it.
  for i in $(seq 1 30); do
    tmux capture-pane -p -t "$session" 2>/dev/null | grep -q 'Ask Codex' && break
    sleep 1
  done
  [ ! -e "$lab/hook-finished" ] \
    || die "the Stop hook finished before the turn ended, so async was not honored and a long arm would hold the turn open"

  # Fact 1 again, but against the live session this time: queueing into the
  # recorded thread is accepted while that session is running. The thread store
  # is per-CODEX_HOME, so the queue call has to use the session's own home - in
  # production the hook inherits it from the primary, which is what makes this
  # work without any configuration.
  CODEX_HOME="$codex_home" codex queue --thread "$sid" --message 'FM-LIVE-GUARD-QUEUE-PROBE' >/dev/null 2>&1 \
    || die "codex queue was refused for the live session it just reported"

  # Fact 3b: the async hook's exit-2 stderr is discarded. If this ever starts
  # arriving, the auto-arm could use the cheaper exit-2 path.
  for i in $(seq 1 30); do
    [ -e "$lab/hook-finished" ] && break
    sleep 1
  done
  sleep 5
  if tmux capture-pane -p -S -200 -t "$session" 2>/dev/null | grep -q 'FM-LIVE-GUARD-EXIT2-BANNER'; then
    die "an async Stop hook's exit-2 banner was delivered; bin/fm-codex-stop-autoarm.sh assumes it is discarded and could use it instead"
  fi
  printf 'ok - codex %s: async Stop hook fires with a session_id, does not hold the turn, and its exit-2 stderr stays discarded\n' "$CODEX_VERSION"
}

test_queue_surface_exists
test_async_stop_hook_contract
