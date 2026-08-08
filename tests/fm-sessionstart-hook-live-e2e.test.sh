#!/usr/bin/env bash
# Opt-in live guard for the RUN-tier session-open adapters (Claude, Codex exec, Pi).
#
# Three facts in this area come from the vendor, not from Firstmate, so a stub
# can only confirm the assumption already written into the stub:
#
#   (a) the harness tells the hook WHICH session open this is, well enough that
#       a context-preserving reopen is never mistaken for a context reset,
#   (b) hook stdout actually reaches model context on a context-RESET open
#       (clear/compact), not only on a cold startup, and
#   (c) a worker the hook detaches SURVIVES the hook returning. Session start
#       moved every external-network call into such a worker
#       (bin/fm-startup-network.sh), so a harness that reaps the hook's process
#       tree would silently stop running the sweeps entirely. Whether it does is
#       a vendor behavior no portable test can see.
#
# docs/sessionstart-nudge.md owns the routing facts (a) and (b) feed, and
# tests/fm-sessionstart-nudge.test.sh pins that routing portably with real
# processes and no harness. This guard covers only what CI cannot see.
#
# It swaps a RECORDER in for bin/fm-sessionstart-run.sh inside a throwaway lab
# checkout, so nothing here touches a real home, lock, or fleet. The recorder
# logs the source the harness supplied and prints a source-stamped token; the
# model is then asked to quote that token back, which is the only way to prove
# the stdout genuinely landed in context rather than merely being produced.
# The token index advances on every open, so a stale earlier token can never
# satisfy a later assertion and no case can go quietly vacuous.
#
# Run it after every harness upgrade and before trusting refreshed evidence in
# docs/verification/supervision.md:
#
#   FM_SESSIONSTART_HOOK_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
#
# It costs real model turns on every installed run-tier harness.
set -u

if [ "${FM_SESSIONSTART_HOOK_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SESSIONSTART_HOOK_LIVE_E2E=1 to run the live session-open hook regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found; the context-reset checks drive real interactive harnesses"

# Outside the repo on purpose: each lab is its own git repo, and nesting one
# inside the checkout would show up as an embedded repository in a working tree
# a maintainer may be committing from while this guard runs.
LAB="${TMPDIR:-/tmp}/fm-sessionstart-hook-live-e2e.$$"
SOCKET="fm-ss-hook-$$"
CHECKED=0
ABSENT=

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

capture() { tmux -L "$SOCKET" capture-pane -p -t "$1" -S -400 2>/dev/null || true; }

wait_for_text() {  # <session> <text> [attempts]
  local session=$1 expected=$2 attempts=${3:-90} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture "$session" | grep -Fq "$expected" && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}

send_line() {  # <session> <text>
  tmux -L "$SOCKET" send-keys -t "$1" -l "$2"
  sleep 2
  tmux -L "$SOCKET" send-keys -t "$1" Enter
}

ASK='Reply with exactly the FMHOOKTOKEN value from your session-start context and nothing else.'
LIVE_NONCE=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')

# --- lab ---------------------------------------------------------------------
#
# A Firstmate-shaped checkout carrying the harness's own TRACKED registration,
# with the wrapper replaced by a recorder, so a registration that stops firing
# fails this guard. The other hook scripts the tracked configs reference get
# no-op stubs: only the session-open registration is under test here, and a
# missing turn-end guard would otherwise spray unrelated errors into the pane.
make_lab() {  # <harness> -> echoes lab dir
  local harness=$1
  local lab="$LAB/$harness" stub
  mkdir -p "$lab/bin" "$lab/state"
  git init -q -b main "$lab"
  git -C "$lab" config user.email fmtest@example.invalid
  git -C "$lab" config user.name fmtest
  printf '# Firstmate lab\n' > "$lab/AGENTS.md"
  git -C "$lab" add -A >/dev/null 2>&1 || true
  git -C "$lab" commit -q -m init >/dev/null 2>&1 || true

  for stub in fm-turnend-guard.sh fm-claude-stop-autoarm.sh fm-arm-pretool-check.sh \
    fm-cd-pretool-check.sh fm-subagent-pretool-check.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/bin/$stub"
    chmod +x "$lab/bin/$stub"
  done

  # The REAL deferred-network stage plus the two libraries it sources, so fact
  # (c) is proven against the actual detach this ship relies on rather than a
  # re-creation of it. Its bootstrap child is a stub: what is under test here is
  # survival across the hook boundary, not the sweeps, which
  # tests/fm-bootstrap.test.sh already owns.
  ln -sf "$ROOT/bin/fm-startup-network.sh" "$lab/bin/fm-startup-network.sh"
  ln -sf "$ROOT/bin/fm-timeout-lib.sh" "$lab/bin/fm-timeout-lib.sh"
  ln -sf "$ROOT/bin/fm-wake-lib.sh" "$lab/bin/fm-wake-lib.sh"
  ln -sf "$ROOT/bin/fm-session-lock-lib.sh" "$lab/bin/fm-session-lock-lib.sh"
  cat > "$lab/bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
# Outlives the hook on purpose: the marker can only appear if the worker was
# still running well after the harness finished with its session-open hook.
set -u
sleep 6
printf 'detached worker survived the hook\n' > "${FM_LIVE_DETACH_MARKER:?}"
exit 0
SH
  chmod +x "$lab/bin/fm-bootstrap.sh"

  cat > "$lab/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
# Recorder standing in for the real wrapper: logs the source the harness
# supplied and prints a source-stamped token for the model to quote back.
set -u
record=${FM_LIVE_RECORD:?}
source=
while [ $# -gt 0 ]; do
  case "$1" in
    --source) source=${2:-}; shift 2 || exit 0 ;;
    *) shift ;;
  esac
done
if [ -z "$source" ]; then
  source=$(cat 2>/dev/null | awk '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == "source" { seen = 1 }
  ')
fi
[ -n "$source" ] || source=none
printf '%s\n' "$source" >> "$record"
# Exactly what bin/fm-session-start.sh does after taking the lock.
if [ -n "${FM_LIVE_DETACH_MARKER:-}" ]; then
  "$(dirname "$0")/fm-startup-network.sh" start --locked 0 --harvest-pid $$ >/dev/null 2>&1 || true
fi
printf 'FMHOOKTOKEN-%s-%s-%s\n' "$source" "$(grep -c . "$record" | tr -d ' ')" "${FM_LIVE_NONCE:?}"
exit 0
SH
  chmod +x "$lab/bin/fm-sessionstart-run.sh"

  case "$harness" in
    claude) mkdir -p "$lab/.claude"; cp "$ROOT/.claude/settings.json" "$lab/.claude/settings.json" ;;
    codex) mkdir -p "$lab/.codex"; cp "$ROOT/.codex/hooks.json" "$lab/.codex/hooks.json" ;;
    pi)
      mkdir -p "$lab/.pi/extensions/lib"
      cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$lab/.pi/extensions/"
      cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$lab/.pi/extensions/lib/"
      cp "$ROOT/bin/fm-operational-input.sh" "$lab/bin/"
      printf '%s\n' '{"compaction":{"keepRecentTokens":200}}' > "$lab/.pi/settings.json"
      ;;
  esac
  printf '%s\n' "$lab"
}

# --- (a) cold open and context-preserving reopen ------------------------------
#
# Both run headless, because a cold open and a resume are whole processes and
# need no TUI driving. The expected resume source is passed per harness rather
# than assumed uniform: the harnesses genuinely disagree, and what matters is
# only that a reopen is never reported as a context RESET, which would make the
# run tier skip sweeps it never ran.
probe_process_opens() {  # <harness> <version> <lab> <expect-resume> <cold-argv...> -- <resume-argv...>
  local harness=$1 version=$2 lab=$3 expect_resume=$4
  shift 4
  local record="$lab/record" cold=() resume=() seen_sep=0 arg out source
  local marker="$lab/detach-marker" waited
  for arg in "$@"; do
    if [ "$arg" = -- ] && [ "$seen_sep" -eq 0 ]; then seen_sep=1; continue; fi
    if [ "$seen_sep" -eq 0 ]; then cold+=("$arg"); else resume+=("$arg"); fi
  done

  : > "$record"
  rm -f "$marker" "$lab/state/.startup-network."*
  out=$( cd "$lab" && FM_LIVE_RECORD="$record" FM_LIVE_NONCE="$LIVE_NONCE" FM_ROOT_OVERRIDE="$lab" FM_HOME="$lab" \
    FM_LIVE_DETACH_MARKER="$marker" \
    "${cold[@]}" "$ASK" < /dev/null 2>&1 )
  source=$(head -n 1 "$record")
  [ -n "$source" ] \
    || fail "$harness $version: the tracked session-open registration never invoked the wrapper on a cold open"
  case "$source" in
    startup|new) : ;;
    *) fail "$harness $version: a cold open reported source '$source', which the run tier cannot classify as a startup" ;;
  esac
  printf '%s' "$out" | grep -Fq "FMHOOKTOKEN-$source-1-$LIVE_NONCE" \
    || { printf '# cold-open model reply: %s\n' "$out" >&2; fail "$harness $version: hook stdout did not reach model context on a cold open"; }
  pass "$harness $version: a cold open reports source '$source' and its hook stdout reaches model context"

  # (c) The harness process is gone; the worker it detached must not be. The
  # marker is written 6s after the hook returned, so it can only exist if the
  # worker outlived the whole session-open boundary.
  waited=0
  while [ ! -s "$marker" ] && [ "$waited" -lt 30 ]; do sleep 1; waited=$((waited + 1)); done
  [ -s "$marker" ] \
    || fail "$harness $version: the session-open hook's detached worker did not survive the hook, so session start's deferred network checks would never run on this harness"
  pass "$harness $version: a worker detached by the session-open hook outlives it, so the deferred network checks still run"

  : > "$record"
  ( cd "$lab" && FM_LIVE_RECORD="$record" FM_LIVE_NONCE="$LIVE_NONCE" FM_ROOT_OVERRIDE="$lab" FM_HOME="$lab" \
    "${resume[@]}" 'Say only OK.' < /dev/null >/dev/null 2>&1 ) || true
  source=$(head -n 1 "$record")
  [ -n "$source" ] \
    || fail "$harness $version: a context-preserving reopen invoked no session-open hook at all"
  case "$source" in
    clear|compact)
      fail "$harness $version: a context-preserving reopen reported source '$source', so the run tier would skip sweeps that never ran"
      ;;
  esac
  [ "$source" = "$expect_resume" ] \
    || fail "$harness $version: a context-preserving reopen reported source '$source', not the recorded '$expect_resume'; refresh docs/verification/supervision.md before trusting the routing"
  pass "$harness $version: a context-preserving reopen reports source '$source', which the run tier routes without a re-emit"
}

# --- (b) context-reset opens --------------------------------------------------
#
# Only reachable through the TUI, so this one drives a real pane.
probe_context_reset() {  # <harness> <version> <lab> <clear-command> <launch-argv...>
  local harness=$1 version=$2 lab=$3 clear_cmd=$4
  shift 4
  local record="$lab/record" session="fmss-$harness" reset n compact_seed compact_reply
  : > "$record"
  tmux -L "$SOCKET" new-session -d -s "$session" -c "$lab" -x 200 -y 50 \
    -e FM_LIVE_RECORD="$record" -e FM_ROOT_OVERRIDE="$lab" -e FM_HOME="$lab" \
    -e FM_LIVE_NONCE="$LIVE_NONCE" \
    "$*" \
    || fail "$harness $version: could not start an interactive lab session"

  # Every run-tier TUI asks whether it trusts a folder it has not seen, and the
  # session-open hook only fires once that is answered. Each harness's default
  # selection IS the trusting one, so a bare Enter clears it; the loop keeps
  # waiting for the recorded open either way, so a harness that stops prompting
  # costs nothing. harness-adapters owns trust handling outside tests.
  n=0
  while [ "$n" -lt 60 ] && ! grep -q . "$record" 2>/dev/null; do
    if capture "$session" | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
      tmux -L "$SOCKET" send-keys -t "$session" Enter
      sleep 5
    fi
    sleep 2
    n=$((n + 1))
  done
  grep -q . "$record" 2>/dev/null \
    || { capture "$session" >&2; fail "$harness $version: the interactive session fired no session-open hook"; }
  sleep 10

  send_line "$session" "$ASK"
  wait_for_text "$session" "FMHOOKTOKEN-$(head -n 1 "$record")-1-$LIVE_NONCE" \
    || { capture "$session" >&2; fail "$harness $version: hook stdout did not reach interactive model context"; }

  send_line "$session" "$clear_cmd"
  n=0
  while [ "$n" -lt 20 ] && [ -z "$(sed -n '2p' "$record")" ]; do sleep 2; n=$((n + 1)); done
  reset=$(sed -n '2p' "$record")
  [ -n "$reset" ] \
    || { capture "$session" >&2; fail "$harness $version: '$clear_cmd' fired no session-open event, so a context reset leaves the session blind"; }
  case "$reset" in
    clear|compact|new) : ;;
    *) fail "$harness $version: '$clear_cmd' reported source '$reset', which the run tier would treat as a cold startup" ;;
  esac
  send_line "$session" "$ASK"
  wait_for_text "$session" "FMHOOKTOKEN-$reset-2-$LIVE_NONCE" \
    || { capture "$session" >&2; fail "$harness $version: hook stdout did not reach model context after '$clear_cmd'"; }
  pass "$harness $version: '$clear_cmd' reports source '$reset' and re-injects hook stdout into model context"

  if [ "$harness" = pi ]; then
    compact_seed="seed-$session-$$"
    compact_reply="FMCOMPACTDONE-$compact_seed"
    printf '%s\n' "$compact_seed" > "$lab/compact-seed.txt"
    send_line "$session" "Read compact-seed.txt, then write at least 1800 words of substantial varied prose. End the final assistant response with FMCOMPACTDONE- immediately followed by the seed, with no space."
    wait_for_text "$session" "$compact_reply" 300 \
      || { capture "$session" >&2; fail "$harness $version: the substantial pre-compaction assistant turn did not complete"; }
    sleep 5
  else
    for n in 1 2 3 4 5; do
      send_line "$session" "Say only ping$n."
      wait_for_text "$session" "ping$n" 30 >/dev/null 2>&1 || true
    done
  fi
  send_line "$session" /compact
  n=0
  while [ "$n" -lt 40 ] && ! grep -qx compact "$record"; do sleep 3; n=$((n + 1)); done
  if grep -qx compact "$record"; then
    send_line "$session" "$ASK"
    wait_for_text "$session" "FMHOOKTOKEN-compact-$(grep -c . "$record" | tr -d ' ')-$LIVE_NONCE" \
      || { capture "$session" >&2; fail "$harness $version: hook stdout did not reach model context after a compaction"; }
    pass "$harness $version: a compaction reports source 'compact' and re-injects hook stdout into model context"
  elif [ "$harness" = pi ]; then
    capture "$session" >&2
    fail "$harness $version: /compact did not raise session_compact after a completed substantial turn with keepRecentTokens=200"
  else
    note "$harness $version: compaction was NOT reached in this lab (recorded: $(tr '\n' ' ' < "$record")); its compact evidence was not refreshed"
  fi

  tmux -L "$SOCKET" kill-session -t "$session" >/dev/null 2>&1 || true
}

# --- per-harness drivers ------------------------------------------------------

for harness in claude codex pi; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    ABSENT="$ABSENT $harness"
    note "$harness: not installed on this host, so its run-tier evidence was NOT refreshed"
    continue
  fi
  version=$("$harness" --version 2>/dev/null | head -n 1)
  [ -n "$version" ] || version=unknown
  lab=$(make_lab "$harness")

  case "$harness" in
    claude)
      probe_process_opens claude "$version" "$lab" resume \
        claude -p --permission-mode bypassPermissions \
        -- claude --continue -p --permission-mode bypassPermissions
      probe_context_reset claude "$version" "$lab" /clear \
        claude --permission-mode bypassPermissions
      ;;
    codex)
      probe_process_opens codex "$version" "$lab" resume \
        codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
        -- codex exec resume --last --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
      note "codex $version: codex exec run-tier evidence refreshed; the interactive TUI is a documented nudge-tier surface because tracked project hooks do not fire there"
      ;;
    pi)
      probe_process_opens pi "$version" "$lab" startup \
        pi -p -e "$lab/.pi/extensions/fm-primary-turnend-guard.ts" --no-context-files --no-tools --no-session \
        -- pi -p -c -e "$lab/.pi/extensions/fm-primary-turnend-guard.ts" --no-context-files --no-tools
      probe_context_reset pi "$version" "$lab" /new \
        pi -e "$lab/.pi/extensions/fm-primary-turnend-guard.ts" --no-context-files
      ;;
  esac
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] \
  || fail "no run-tier harness was installed, so this guard verified nothing; install claude, codex, or pi before trusting its evidence"
[ -z "$ABSENT" ] \
  || note "run-tier evidence was refreshed for $CHECKED harness(es); still missing:$ABSENT"
echo "# fm-sessionstart-hook-live-e2e.test.sh: all live assertions passed"
