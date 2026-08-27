#!/usr/bin/env bash
# fm-mux-lib.sh — the multiplexer seam.
#
# firstmate drives panes through ~100 direct `tmux` calls across 15 scripts.
# That couples the fleet to one multiplexer and, worse, to one multiplexer's
# weakest property: `tmux send-keys` is blind keystroke injection with no
# acknowledgment channel. Every supervision primitive built on it is therefore
# a heuristic — busy/idle is a regex over pane text, readiness is a cwd poll,
# and delivery is a fixed sleep between the text and the Enter.
#
# This file is the seam that lets a driver with real acknowledgment replace it.
# Selected by FM_MUX: `tmux` (default, byte-identical to today's behaviour) or
# `herdr`. Every verb has one contract across drivers:
#
#   fm_mux_driver                          -> prints the active driver name
#   fm_mux_new_window <ses> <name> <cwd>   -> prints an OPAQUE target, 1 on failure
#   fm_mux_send <target> <text>            -> delivers text AND submits it
#   fm_mux_read <target> [lines]           -> prints pane text
#   fm_mux_is_busy <target>                -> 0 when the agent is working
#   fm_mux_wait_ready <target> [timeout]   -> 0 when it can accept input
#   fm_mux_close <target>                  -> tears the window down
#
# THE TARGET IS OPAQUE. Under tmux it is `session:window`; under herdr it is a
# pane or agent id. Callers must pass it back verbatim and never parse it —
# that rule is what keeps the drivers swappable.
#
# Spec: docs/plans/cmux-herdr-surface-split.md (W1).

# Resolve the driver once. An explicit FM_MUX always wins; otherwise prefer
# herdr when this process is genuinely running inside it AND the binary is
# present, so an unconfigured machine keeps today's behaviour.
fm_mux_driver() {
  if [ -n "${FM_MUX:-}" ]; then printf '%s' "$FM_MUX"; return 0; fi
  if [ "${HERDR_ENV:-}" = 1 ] && command -v herdr >/dev/null 2>&1; then
    printf 'herdr'; return 0
  fi
  printf 'tmux'
}

fm_mux_dispatch() {  # <verb> [args...]
  local verb=$1; shift
  local drv; drv=$(fm_mux_driver)
  case "$drv" in
    tmux|herdr) ;;
    *) echo "fm-mux: unknown FM_MUX driver '$drv' (want tmux|herdr)" >&2; return 2 ;;
  esac
  "fm_mux_${drv}_${verb}" "$@"
}

fm_mux_new_window()  { fm_mux_dispatch new_window  "$@"; }
fm_mux_send()        { fm_mux_dispatch send        "$@"; }
fm_mux_read()        { fm_mux_dispatch read        "$@"; }
fm_mux_is_busy()     { fm_mux_dispatch is_busy     "$@"; }
fm_mux_wait_ready()  { fm_mux_dispatch wait_ready  "$@"; }
fm_mux_close()       { fm_mux_dispatch close       "$@"; }

# --- tmux driver ------------------------------------------------------------
#
# Preserves today's behaviour exactly, including its known weaknesses, so
# switching FM_MUX back is a true rollback rather than a different code path.

fm_mux_tmux_new_window() {  # <session> <name> <cwd>
  local ses=$1 name=$2 cwd=$3
  tmux new-window -d -t "$ses:" -n "$name" -c "$cwd" 2>/dev/null || return 1
  printf '%s:%s' "$ses" "$name"
}

fm_mux_tmux_send() {  # <target> <text>
  local target=$1 text=$2
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || return 1
  sleep "${FM_MUX_ENTER_SLEEP:-0.3}"
  tmux send-keys -t "$target" Enter 2>/dev/null || return 1
}

fm_mux_tmux_read() {  # <target> [lines]
  local target=$1 lines=${2:-40}
  tmux capture-pane -p -t "$target" -S "-$lines" 2>/dev/null
}

# Busy is inferred from the harness's own footer text. This is the heuristic
# the herdr driver replaces with a real state read.
fm_mux_tmux_is_busy() {  # <target>
  fm_mux_tmux_read "$1" 6 | grep -qiE "${FM_BUSY_RE:-esc (to )?interrupt|Working\.\.\.}"
}

fm_mux_tmux_wait_ready() {  # <target> [timeout]
  if command -v fm_tmux_wait_shell_ready >/dev/null 2>&1; then
    fm_tmux_wait_shell_ready "$1" "${2:-20}"
  else
    sleep "${FM_MUX_ENTER_SLEEP:-0.3}"
  fi
}

fm_mux_tmux_close() {  # <target>
  tmux kill-window -t "$1" 2>/dev/null
}

# --- herdr driver -----------------------------------------------------------
#
# herdr classifies agent lifecycle natively (idle|working|blocked|done) and
# `agent prompt --wait` delivers text and submission as one acknowledged
# operation. That removes the two guesses the tmux driver is forced into.

fm_mux_herdr_new_window() {  # <session> <name> <cwd>  (session is ignored; herdr scopes by workspace)
  local name=$2 cwd=$3 out
  out=$(herdr tab create --cwd "$cwd" --label "$name" --no-focus 2>&1) || {
    echo "fm-mux(herdr): tab create failed: $out" >&2; return 1; }
  # Print the id herdr reports, whatever shape it takes; callers treat it as opaque.
  printf '%s' "$out" | grep -oE '[A-Za-z0-9]+:t[0-9]+|[A-Za-z0-9]+:p[0-9]+' | head -1
}

# Atomic delivery. --wait makes herdr confirm the agent actually consumed the
# prompt, which is the acknowledgment tmux cannot provide. A blocked agent is
# refused rather than written over (herdr >= 0.8.2 returns agent_blocked).
fm_mux_herdr_send() {  # <target> <text>
  local target=$1 text=$2 out
  out=$(herdr agent prompt "$target" "$text" --wait --timeout "${FM_MUX_SEND_TIMEOUT_MS:-15000}" 2>&1) && return 0
  case "$out" in
    *agent_blocked*) echo "fm-mux(herdr): $target is at an approval dialog; not overwriting it" >&2; return 3 ;;
    *) echo "fm-mux(herdr): prompt failed: $out" >&2; return 1 ;;
  esac
}

fm_mux_herdr_read() {  # <target> [lines]
  herdr agent read "$1" --source visible --lines "${2:-40}" --format text 2>/dev/null \
    || herdr pane read "$1" --source visible --lines "${2:-40}" --format text 2>/dev/null
}

# A real state read, not a regex over rendered text.
fm_mux_herdr_is_busy() {  # <target>
  herdr agent get "$1" 2>/dev/null | grep -qiE '(^|[^a-z])(working|busy)([^a-z]|$)'
}

fm_mux_herdr_wait_ready() {  # <target> [timeout-seconds]
  local target=$1 secs=${2:-20}
  herdr agent wait "$target" --until idle --timeout "$(( secs * 1000 ))" >/dev/null 2>&1
}

fm_mux_herdr_close() {  # <target>
  herdr tab close "$1" 2>/dev/null || herdr pane close "$1" 2>/dev/null
}
