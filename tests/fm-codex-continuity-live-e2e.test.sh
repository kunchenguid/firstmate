#!/usr/bin/env bash
# Live Codex guard for the Stop-hook-owned supervision path.
#
# bin/fm-codex-stop-autoarm.sh rests on three facts about the installed Codex
# that no stub can confirm, because each is something the vendor emits:
#
#   1. `codex queue --thread <id> --message <text>` exists and is how an external
#      process reaches a running session. This is the delivery channel; if the
#      flag shape changes, every wake stops arriving. Tier 1 proves it by running
#      the command, never by reading vendor help or error text: it runs by
#      default wherever codex is installed, so a reworded message must not
#      redden the lane on a Codex that still works.
#   2. A Codex `Stop` hook fires in an interactive session and hands the hook its
#      own `session_id`, which is the thread id delivery needs.
#   3. `"async": true` is honored on that Stop hook - the turn completes while the
#      hook still runs - AND the async hook's exit status and stderr are
#      DISCARDED. The second half is why the auto-arm queues a message instead of
#      copying Claude's exit-2 rewake; if Codex ever started honoring exit 2 here,
#      that would be worth knowing rather than silently unused.
#   4. An async Stop hook does NOT wait for a synchronous one registered ahead of
#      it in the same group. The tracked .codex/hooks.json registers the turn-end
#      guard first (synchronous) and the auto-arm second (async), and the guard's
#      bounded cooperative wait can only ever see an auto-arm generation claim if
#      the auto-arm is already running while the guard waits. A Codex release that
#      serialized the group would turn every wake-handling turn back into a
#      blocked stop, so it has to fail here rather than silently.
#
# Tier 1 (token-free, runs wherever codex is installed) proves fact 1.
# Tier 2 (opt-in, spends tokens) drives a real interactive Codex under tmux and
# proves facts 2, 3, and 4 end to end.
# Tier 3 (opt-in, spends tokens) proves the FALLBACK still works: the hook is
# preferred, not exclusive, and a Codex home whose project hooks do not fire has
# only the foreground checkpoint left, so that path must keep working too.
#
# Every tier fails naming the codex version rather than degrading quietly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CODEX_LIVE_E2E,FM_CODEX_LIVE_STOP_E2E,FM_CODEX_LIVE_CHECKPOINT_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_VERSION=$(codex --version 2>/dev/null || printf 'unknown')
TMP_ROOT=$(fm_test_tmproot fm-codex-continuity-live)

die() {
  printf 'not ok - codex %s: %s\n' "$CODEX_VERSION" "$1" >&2
  exit 1
}

# --- tier 1: the delivery channel --------------------------------------------

# This tier runs by default wherever codex is installed, so it asserts only
# EXECUTED behaviour, never vendor message text. A Codex release that rewords an
# error or re-renders its help must not redden the default lane on a product that
# still works; the design depends on the exit status, not on the wording.
test_queue_surface_exists() {
  local rc=0
  codex queue --help >/dev/null 2>&1 \
    || die "codex queue is missing, so no wake can reach a running session"

  # A thread that cannot exist must fail loudly, so a wake aimed at a dead
  # session is a bounded actionable error rather than a silent success.
  codex queue --thread fm-live-guard-not-a-thread --message probe >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || die "codex queue reported success for an impossible thread id"
  printf 'ok - codex %s: queue is the live delivery channel and refuses an impossible thread\n' "$CODEX_VERSION"
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

  # Two hooks in ONE Stop group, in the tracked registration's order: a
  # SYNCHRONOUS stand-in for the turn-end guard first, then the async hook. The
  # sync hook runs for 3s and leaves sync-finished behind only when it is done,
  # so the async hook can record, from its own first line, whether it started
  # while the sync hook was still running. No sub-second clock is needed, and the
  # answer is the exact property the --codex cooperative wait depends on.
  cat > "$lab/sync-hook.sh" <<HOOK
#!/usr/bin/env bash
LAB=$(printf '%q' "$lab")
cat >/dev/null 2>&1 || true
sleep 3
date +%s > "\$LAB/sync-finished"
exit 0
HOOK
  chmod +x "$lab/sync-hook.sh"

  # The async hook records its payload and its start ordering, keeps running well
  # past the turn end, and then exits 2 with a banner on stderr. If Codex ever
  # delivered that banner, the transcript would show it.
  cat > "$lab/stop-hook.sh" <<HOOK
#!/usr/bin/env bash
LAB=$(printf '%q' "$lab")
if [ -e "\$LAB/sync-finished" ]; then
  printf 'serialized\n' > "\$LAB/async-order"
else
  printf 'concurrent\n' > "\$LAB/async-order"
fi
cat > "\$LAB/payload.json" 2>/dev/null || true
date +%s > "\$LAB/hook-started"
sleep 6
date +%s > "\$LAB/hook-finished"
printf 'FM-LIVE-GUARD-EXIT2-BANNER\n' >&2
exit 2
HOOK
  chmod +x "$lab/stop-hook.sh"
  printf '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": %s, "timeout": 60 }, { "type": "command", "command": %s, "timeout": 120, "async": true } ] } ] } }\n' \
    "\"$lab/sync-hook.sh\"" "\"$lab/stop-hook.sh\"" > "$project/.codex/hooks.json"

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

  # Fact 4: the async hook did not wait for the synchronous one ahead of it.
  # Without this, bin/fm-turnend-guard.sh --codex would wait out its whole
  # cooperative window before the auto-arm had even started, and every
  # wake-handling turn would end on a false blind-turn block.
  case "$(cat "$lab/async-order" 2>/dev/null || printf 'missing')" in
    concurrent) ;;
    serialized)
      die "the async Stop hook started only after the synchronous hook finished; bin/fm-turnend-guard.sh --codex can no longer observe an auto-arm claim within its cooperative window"
      ;;
    *) die "the async Stop hook did not record its start ordering against the synchronous hook" ;;
  esac

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
  printf 'ok - codex %s: async Stop hook fires with a session_id, starts beside a synchronous hook rather than after it, does not hold the turn, and its exit-2 stderr stays discarded\n' "$CODEX_VERSION"
}

# --- tier 3: the fallback path still works ------------------------------------
#
# The Stop hook is preferred, not exclusive. A Codex home whose project hooks do
# not fire - a spawned worktree, or a primary whose per-entry hook hashes are not
# approved yet - still has to be able to supervise itself, and the foreground
# checkpoint is the only thing left there. This tier is the pre-existing proof
# that a real Codex turn runs that checkpoint in the foreground and does not
# quietly substitute the background arm path; it is kept alongside the hook tiers
# rather than replaced by them.
test_foreground_checkpoint_fallback() {
  case "${FM_CODEX_LIVE_CHECKPOINT_E2E:-${FM_LIVE:-}}" in
    1) ;;
    *)
      printf 'skip: live: credentialed checkpoint fallback proof is opt-in; set FM_CODEX_LIVE_CHECKPOINT_E2E=1 to run\n'
      return 0
      ;;
  esac

  local lab project home_dir transcript
  lab="$TMP_ROOT/checkpoint-fallback"
  project="$lab/project"
  home_dir="$lab/fmhome"
  transcript="$lab/codex.jsonl"
  mkdir -p "$lab"
  git clone -q "$ROOT" "$project" || die "could not clone the checkout under test"
  mkdir -p "$home_dir/state" "$home_dir/config"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  local prompt='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After the checkpoint returns, reply briefly.'

  (
    cd "$project" || exit 1
    printf '%s\n' "$$" > "$home_dir/state/.lock"
    FM_HOME="$home_dir" FM_ROOT_OVERRIDE="$project" codex exec \
      --dangerously-bypass-hook-trust \
      --dangerously-bypass-approvals-and-sandbox \
      --skip-git-repo-check \
      -c 'model_reasoning_effort="low"' \
      --json \
      "$prompt"
  ) > "$transcript" 2>&1 \
    || die "credentialed checkpoint turn failed: $(tail -20 "$transcript")"

  grep -F 'checkpoint: no actionable wake within 1s' "$transcript" >/dev/null \
    || die "the transcript omitted the real foreground checkpoint result, so the fallback path no longer runs"
  if grep -F 'watcher: started pid=' "$transcript" >/dev/null; then
    die "the checkpoint fallback switched to the background arm path"
  fi
  printf 'ok - codex %s: the one-second foreground checkpoint fallback still runs without switching to the background arm\n' "$CODEX_VERSION"
}

test_queue_surface_exists
test_async_stop_hook_contract
test_foreground_checkpoint_fallback
