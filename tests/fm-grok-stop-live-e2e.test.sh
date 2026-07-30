#!/usr/bin/env bash
# Opt-in real-process Grok Stop compatibility matrix.
#
# Requires exact official binary paths for one native-capable build and one
# genuine pre-native build. Each cell gets a unique scratch repo/home, dedicated
# tmux socket, socket-bound wrapper, target window, and independent control
# window. Cleanup uses only creation-time pane/process identities.
set -u

if [ "${FM_GROK_STOP_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GROK_STOP_LIVE_E2E=1 with FM_GROK_NATIVE_BIN and FM_GROK_LEGACY_BIN"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NATIVE_BIN=${FM_GROK_NATIVE_BIN:-}
LEGACY_BIN=${FM_GROK_LEGACY_BIN:-}
AUTH=${FM_GROK_AUTH_FILE:-$HOME/.grok/auth.json}
REAL_TMUX=$(command -v tmux || true)
ACTIVE_LAB=

[ -x "$NATIVE_BIN" ] || fail "FM_GROK_NATIVE_BIN must be an exact executable path"
[ -x "$LEGACY_BIN" ] || fail "FM_GROK_LEGACY_BIN must be an exact executable path"
[ -f "$AUTH" ] || fail "FM_GROK_AUTH_FILE must name the already-managed auth artifact"
[ -n "$REAL_TMUX" ] || fail "tmux not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

NATIVE_VERSION=$($NATIVE_BIN --version)
LEGACY_VERSION=$($LEGACY_BIN --version)

cleanup_exact_cell() {
  local lab=$1 session=$2 target=$3 pane_expected pid_expected pane_live pid_live windows
  pane_expected=$(sed -n 's/^target-pane=//p' "$lab/target.identity")
  pid_expected=$(sed -n 's/^target-pid=//p' "$lab/target.identity")
  [ -n "$pane_expected" ] && [ -n "$pid_expected" ] || {
    echo "blocked: missing recorded target identity; preserving $lab" >&2
    return 1
  }
  pane_live=$(cd "$lab" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock \
    display-message -p -t "$session:$target" '#{pane_id}' 2>/dev/null) || {
      echo "blocked: cannot verify target pane identity; preserving $lab" >&2
      return 1
    }
  pid_live=$(cd "$lab" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock \
    display-message -p -t "$session:$target" '#{pane_pid}' 2>/dev/null) || {
      echo "blocked: cannot verify target process identity; preserving $lab" >&2
      return 1
    }
  [ "$pane_live" = "$pane_expected" ] && [ "$pid_live" = "$pid_expected" ] || {
    echo "blocked: live target identity differs from creation record; preserving $lab" >&2
    return 1
  }
  FM_E2E_TMUX_SOCKET_ID="$lab/dedicated.sock" PATH="$lab/bin:$PATH" \
    env -u TMUX -u TMUX_PANE "$lab/bin/tmux" kill-window -t "$session:$target" || return 1
  windows=$(cd "$lab" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock \
    list-windows -t "$session" -F '#{window_name}') || return 1
  printf '%s\n' "$windows" | grep -Fqx control || {
    echo "blocked: control window did not survive exact target cleanup; preserving $lab" >&2
    return 1
  }
  printf '%s\n' "$windows" | grep -Fqx "$target" && {
    echo "blocked: exact target survived cleanup; preserving $lab" >&2
    return 1
  }
  FM_E2E_TMUX_SOCKET_ID="$lab/dedicated.sock" PATH="$lab/bin:$PATH" \
    env -u TMUX -u TMUX_PANE "$lab/bin/tmux" kill-server || return 1
  rm -rf -- "$lab"
  ACTIVE_LAB=
}

preserve_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$ACTIVE_LAB" ]; then
    echo "blocked: preserving failed isolated Grok cell at $ACTIVE_LAB" >&2
  fi
  exit "$rc"
}
trap preserve_on_failure EXIT

run_cell() {  # <native|legacy> <exact-binary>
  local kind=$1 binary=$2 lab tmp_base session target prompt i child_count payload_count unique_sessions
  local stop_values outer_turns outer_text
  tmp_base=${TMPDIR:-/tmp}
  tmp_base=${tmp_base%/}
  lab=$(mktemp -d "$tmp_base/fm-grok-stop-$kind.XXXXXX") || return 1
  session="$kind-e2e"
  target="fm-$kind"
  ACTIVE_LAB=$lab
  umask 077
  mkdir -p "$lab"/{home,grok-home,bin,fmhome/state,fmhome/config}
  git clone -q --no-hardlinks "$ROOT" "$lab/project" || return 1
  # Before the candidate is committed, clone sees HEAD only. Apply the current
  # tracked diff so this opt-in gate always exercises the code under review.
  git -C "$ROOT" diff --binary HEAD -- > "$lab/candidate.patch" || return 1
  [ ! -s "$lab/candidate.patch" ] \
    || git -C "$lab/project" apply --whitespace=nowarn "$lab/candidate.patch" || return 1
  ln -s "$AUTH" "$lab/grok-home/auth.json"
  printf '%s\n' "$lab/dedicated.sock" > "$lab/tmux.socket-identity"

  cat > "$lab/bin/tmux" <<EOF
#!/usr/bin/env bash
set -eu
expected='$lab/dedicated.sock'
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_E2E_TMUX_SOCKET_ID:-}" = "\$expected" ] || exit 92
[ "\$(cat '$lab/tmux.socket-identity')" = "\$expected" ] || exit 93
for arg in "\$@"; do case "\$arg" in -S|-L) exit 94 ;; esac; done
printf 'tmux' >> '$lab/tmux-wrapper.log'
printf ' <%s>' "\$@" >> '$lab/tmux-wrapper.log'
printf '\n' >> '$lab/tmux-wrapper.log'
cd '$lab'
exec '$REAL_TMUX' -S dedicated.sock "\$@"
EOF
  cat > "$lab/bin/grok" <<'EOF'
#!/usr/bin/env bash
printf 'active=%s' "${GROK_TURNEND_GUARD_ACTIVE:-}" >> "${FM_GROK_E2E_ROOT:?}/resume-invocations.log"
printf ' <%s>' "$@" >> "${FM_GROK_E2E_ROOT:?}/resume-invocations.log"
printf '\n' >> "${FM_GROK_E2E_ROOT:?}/resume-invocations.log"
exec "${FM_GROK_E2E_BIN:?}" "$@"
EOF
  chmod +x "$lab/bin/tmux" "$lab/bin/grok"
  : > "$lab/tmux-wrapper.log"
  : > "$lab/resume-invocations.log"

  if [ "$kind" = native ]; then
    cat > "$lab/project/.grok/hooks/00-fm-stop-live-e2e.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash -lc 'cat >> \"$lab/payloads.jsonl\"'","timeout":30}]}]}}
EOF
    prompt='This is an isolated regression test. Reply exactly NATIVE_BASE. If Stop-hook feedback arrives, do not use tools; acknowledge it by replying exactly NATIVE_CONTINUED, then stop.'
  else
    mkdir -p "$lab/grok-home/hooks"
    cp "$ROOT/.grok/hooks/fm-primary-turnend-guard.json" "$lab/grok-home/hooks/fm-primary-turnend-guard.json"
    rm -f "$lab/project/.grok/hooks/fm-primary-turnend-guard.json"
    cat > "$lab/grok-home/hooks/00-fm-stop-live-e2e.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash -lc 'cat >> \"$lab/payloads.jsonl\"'","timeout":30}]}]}}
EOF
    prompt='This is an isolated regression test. Reply exactly LEGACY_BASE. If a resumed turn receives guard feedback, do not use tools; acknowledge it by replying exactly LEGACY_RESUMED, then stop.'
  fi

  cat > "$lab/fmhome/state/$kind.meta" <<EOF
window=$session:$target
endpoint_task_id=$kind
worktree=$lab/project
project=$lab/project
harness=grok
kind=scout
mode=no-mistakes
EOF
  cat > "$lab/run.sh" <<EOF
#!/usr/bin/env bash
set -u
cd '$lab/project' || exit 70
env -u TMUX -u TMUX_PANE HOME='$lab/home' GROK_HOME='$lab/grok-home' GROK_AGENT=1 \
  FM_HOME='$lab/fmhome' FM_ROOT_OVERRIDE='$lab/project' FM_GROK_E2E_ROOT='$lab' \
  FM_GROK_E2E_BIN='$binary' FM_E2E_TMUX_SOCKET_ID='$lab/dedicated.sock' PATH='$lab/bin':"\$PATH" \
  '$binary' $([ "$kind" = native ] && printf '%s' '--trust ')--always-approve --reasoning-effort low \
    --output-format json --leader-socket '$lab/leader.sock' -p $(printf '%q' "$prompt") \
    > '$lab/outer.json' 2> '$lab/outer.err' &
child=\$!
printf 'child_pid=%s\n' "\$child" > '$lab/process.identity'
pgid=\$(ps -o pgid= -p "\$child" 2>/dev/null | tr -d ' ')
printf 'child_pgid=%s\n' "\$pgid" >> '$lab/process.identity'
wait "\$child"; rc=\$?
printf 'rc=%s\n' "\$rc" > '$lab/done'
sleep 1800
EOF
  chmod +x "$lab/run.sh"

  ( cd "$lab" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock \
      new-session -d -s "$session" -n control 'sleep 1800' ) || return 1
  ( cd "$lab" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock \
      new-window -d -t "$session:" -n "$target" "$lab/run.sh" ) || return 1
  printf 'target-pane=%s\ntarget-pid=%s\n' \
    "$(cd "$lab" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock display-message -p -t "$session:$target" '#{pane_id}')" \
    "$(cd "$lab" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock display-message -p -t "$session:$target" '#{pane_pid}')" \
    > "$lab/target.identity"

  i=0
  while [ "$i" -lt "${FM_GROK_STOP_LIVE_TIMEOUT:-600}" ] && [ ! -f "$lab/done" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -f "$lab/done" ] || fail "$kind Grok cell timed out"
  grep -qx 'rc=0' "$lab/done" || fail "$kind Grok process returned nonzero"
  [ ! -s "$lab/tmux-wrapper.log" ] || fail "$kind model path invoked tmux unexpectedly"
  payload_count=$(jq -s 'length' "$lab/payloads.jsonl")
  unique_sessions=$(jq -s '[.[].sessionId] | unique | length' "$lab/payloads.jsonl")
  [ "$unique_sessions" -eq 1 ] || fail "$kind Stop payloads changed session identity"
  child_count=$(grep -c '^active=' "$lab/resume-invocations.log" || true)
  outer_text=$(jq -r '.text // empty' "$lab/outer.json")

  if [ "$kind" = native ]; then
    [ "$payload_count" -eq 2 ] || fail "native path expected two Stop payloads, got $payload_count"
    stop_values=$(jq -sc '[.[].stopHookActive]' "$lab/payloads.jsonl")
    [ "$stop_values" = '[false,true]' ] || fail "native capability sequence was $stop_values"
    outer_turns=$(jq -r '.num_turns // 0' "$lab/outer.json")
    [ "$outer_turns" -eq 2 ] || fail "native path expected two model turns, got $outer_turns"
    [ "$child_count" -eq 0 ] || fail "native path started grok --resume"
    case "$outer_text" in *NATIVE_BASE*NATIVE_CONTINUED*) ;; *) fail "native model did not receive guard feedback" ;; esac
    printf 'ok - %s native Stop kept one session across false->true, two model turns, and zero resume processes\n' "$NATIVE_VERSION"
  else
    [ "$payload_count" -eq 2 ] || fail "legacy path expected two Stop payloads, got $payload_count"
    jq -se 'all(.[]; (has("stopHookActive") | not) and (has("stop_hook_active") | not))' "$lab/payloads.jsonl" >/dev/null \
      || fail "legacy payload unexpectedly exposed native capability"
    [ "$child_count" -eq 1 ] || fail "legacy path expected exactly one grok --resume, got $child_count"
    grep -q '^active=1 ' "$lab/resume-invocations.log" || fail "legacy resume lacked the recursion guard"
    case "$outer_text" in *LEGACY_BASE*) ;; *) fail "legacy outer turn did not finish normally" ;; esac
    printf 'ok - %s legacy Stop omitted capability, resumed exactly once, and stopped normally\n' "$LEGACY_VERSION"
  fi

  cleanup_exact_cell "$lab" "$session" "$target" || return 1
}

run_cell native "$NATIVE_BIN"
run_cell legacy "$LEGACY_BIN"
trap - EXIT
echo "ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival"
