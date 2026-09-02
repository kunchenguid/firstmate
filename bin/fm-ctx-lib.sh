#!/usr/bin/env bash
# fm-ctx-lib.sh — shared pure primitives for the firstmate context watchdog.
#
# ONE source of truth for: the per-pane window KEY (so the statusline writer, the
# watch daemon, and the rehydrate bootstrap all agree on the same ctx-<key>.json /
# handoff-<key>.md filenames), ROLE classification (captain vs crew/secondmate),
# the restart THRESHOLDS, and the inject-size CAP. Sourced by fm-ctx-statusline.sh,
# fm-ctx-stop-hook.sh, and fm-context-watch.sh; the rehydrate path in
# fm-captain-bootstrap.sh reimplements the key/cap logic in python but keys off the
# SAME conventions defined here.
#
# All functions are `set -u`/`set -e` safe and side-effect-free (pure reads), so the
# unit tests source this file directly. No tmux/IO at source time.

# --- thresholds (env-overridable) -------------------------------------------
# CAPTAIN fires BELOW the 200k floor: a safety margin so the firstmate restarts
# before it can ever enter the "dumb zone", never at/after 200k. CREW/SECONDMATE
# restart at half their window — a cheap, frequent, low-stakes recycle — OR at a
# hard ABSOLUTE token ceiling (FM_CTX_CREW_FLOOR), whichever comes first: on a
# huge window 50% can still be a dangerous absolute size, so the floor catches a
# crew that is over the token ceiling even while under 50% of its window.
FM_CTX_CAPTAIN_FLOOR="${FM_CTX_CAPTAIN_FLOOR:-185000}"   # total context tokens
FM_CTX_CREW_PCT="${FM_CTX_CREW_PCT:-50}"                 # used_percentage
FM_CTX_CREW_FLOOR="${FM_CTX_CREW_FLOOR:-200000}"         # absolute total-token ceiling
FM_CTX_INJECT_CAP="${FM_CTX_INJECT_CAP:-10000}"          # max chars injected inline

# --- managed-scope (env-overridable) ----------------------------------------
# The MEASURE statusLine is GLOBAL (~/.claude/settings.json), so EVERY Claude
# session on the machine — including Stone's ad-hoc/personal ones — writes a
# ctx-<window>.json sentinel into firstmate's state/. The watchdog must NEVER
# /clear a session it does not own, so ownership is opt-in by construction on
# each surface (fm_ctx_managed_target is the one place that decides):
#   * tmux  - the pane's SESSION. fm-spawn.sh launched every pre-cutover
#             crew/secondmate window (`fm-<id>`) AND the captain (Cortana) inside
#             the single firstmate tmux session, so a pane is managed iff its
#             session is FM_TMUX_SESSION. Ad-hoc panes live in other sessions.
#   * herdr - $FM_HERDR_PANE, injected by fm-spawn.sh into the launch string of a
#             pane it created. Nothing else sets it.
# (Override FM_TMUX_SESSION for nested/renamed deployments or tests.)
FM_TMUX_SESSION="${FM_TMUX_SESSION:-firstmate}"

# fm_ctx_sanitize_key: make a tmux target / arbitrary label safe as a filename
# fragment. Mirrors the daemon's _stale_key (':','/','.' -> '_'); also collapses
# whitespace so a stray field can never split a filename.
fm_ctx_sanitize_key() {  # <raw>
  local s=$1
  s=${s//:/_}; s=${s//\//_}; s=${s//./_}; s=${s// /_}
  printf '%s' "$s"
}

# fm_ctx_window_key: resolve a STABLE per-pane key that survives a /clear, so the
# statusline-before-clear and the bootstrap-after-clear compute the same key from
# the same pane and the handoff round-trips. Both surfaces have such an identity:
# a tmux window persists across the conversation reset, and so does a herdr PANE
# ID - which is also the address herdr itself steers by.
# Priority: FM_CTX_WINDOW override (tests) > tmux session:window via $TMUX_PANE >
# the herdr pane id pinned into the session by fm-spawn ($FM_HERDR_PANE) > the
# caller-supplied fallback (e.g. session_id) > "unknown".
fm_ctx_window_key() {  # [fallback]
  local fallback="${1:-}" w
  if [ -n "${FM_CTX_WINDOW:-}" ]; then
    fm_ctx_sanitize_key "$FM_CTX_WINDOW"; return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    w=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null) || w=""
    if [ -n "$w" ]; then fm_ctx_sanitize_key "$w"; return 0; fi
  fi
  if [ -n "${FM_HERDR_PANE:-}" ]; then
    fm_ctx_sanitize_key "$FM_HERDR_PANE"; return 0
  fi
  if [ -n "$fallback" ]; then fm_ctx_sanitize_key "$fallback"; return 0; fi
  printf 'unknown'
}

# fm_ctx_managed_target: the target a sentinel should steer, and whether
# firstmate may steer it at all - the MEASURE side of "the watchdog owns this
# pane". Prints the target; returns 0 when it is managed, 1 otherwise.
#
# The statusLine is GLOBAL, so EVERY Claude session on the machine writes a
# sentinel into some firstmate state dir. Ownership must therefore be OPT-IN BY
# CONSTRUCTION on both surfaces, and on both it is:
#   * tmux  - the pane is in firstmate's tmux session (FM_TMUX_SESSION), which is
#             where fm-spawn put every pre-cutover crewmate and the captain;
#   * herdr - $FM_HERDR_PANE is set, which ONLY bin/fm-spawn.sh injects, into the
#             launch string of a pane it created for the fleet. A captain's own
#             herdr pane inherits nothing and so is never managed.
# The daemon re-confirms the herdr half against this home's metas at fire time,
# so a stale or forged pin cannot by itself get a pane steered.
fm_ctx_managed_target() {
  local sess=""
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || sess=""
    fm_ctx_session_managed "$sess"
    return
  fi
  if [ -n "${FM_HERDR_PANE:-}" ]; then
    printf '%s' "$FM_HERDR_PANE"
    return 0
  fi
  printf ''
  return 1
}

# fm_ctx_role: captain iff the pane's cwd is $HOME or the firstmate home — the same
# heuristic fm-captain-bootstrap.sh already uses to decide "this pane is Cortana".
# Everything else (a crewmate/secondmate in a treehouse worktree) is "crew".
# Precedence (mirrors fm-captain-bootstrap.sh): FIRSTMATE_ROLE (validated, the
# deterministic captain/crew signal a Hermes-launched session sets) > FM_CTX_ROLE
# (legacy tests/explicit-tagging passthrough) > cwd default. Only the two valid
# FIRSTMATE_ROLE values force; anything else falls through unchanged.
fm_ctx_role() {  # <cwd>
  local fr; fr=$(printf '%s' "${FIRSTMATE_ROLE:-}" | tr '[:upper:]' '[:lower:]')
  case "$fr" in captain|crew) printf '%s' "$fr"; return 0 ;; esac
  if [ -n "${FM_CTX_ROLE:-}" ]; then printf '%s' "$FM_CTX_ROLE"; return 0; fi
  local cwd=$1 fm="${FM_HOME:-$HOME/firstmate}"
  if [ "$cwd" = "$HOME" ] || [ "$cwd" = "$fm" ]; then printf 'captain'; else printf 'crew'; fi
}

# fm_ctx_session_managed: 0 iff <session_name> is firstmate's managed tmux session
# (FM_TMUX_SESSION). The single source of truth for "the watchdog owns this pane".
# An empty/unknown session is NOT managed (fail-closed): we never fire on a pane we
# cannot positively attribute to firstmate.
fm_ctx_session_managed() {  # <session_name>
  [ -n "$1" ] && [ "$1" = "$FM_TMUX_SESSION" ]
}

# fm_ctx_should_restart: the core threshold decision. Returns 0 (restart due) when a
# CAPTAIN's total context >= CAPTAIN_FLOOR, or a CREW/SECONDMATE's used_pct >= PCT
# OR total context >= CREW_FLOOR (the absolute token ceiling — fires even when the
# window-relative percentage is still under PCT). Any non-numeric / missing
# measurement is clamped so it can never trip a threshold (never fire on garbage).
fm_ctx_should_restart() {  # <role> <total_tokens> <used_pct>
  local role=$1 total=$2 pct=$3
  case "$total" in ''|*[!0-9]*) total=-1 ;; esac
  case "$pct" in ''|*[!0-9]*) pct=-1 ;; esac
  if [ "$role" = captain ]; then
    [ "$total" -ge "$FM_CTX_CAPTAIN_FLOOR" ]
  else
    [ "$pct" -ge "$FM_CTX_CREW_PCT" ] || [ "$total" -ge "$FM_CTX_CREW_FLOOR" ]
  fi
}

# fm_ctx_inject_payload: emit the text to inject for a handoff file, respecting the
# 10k-char inject cap. <= cap -> the handoff verbatim; > cap -> a one-line POINTER
# to the file on disk (never the bloated body). Used by the rehydrate path's size
# guard and unit-tested directly (G5).
fm_ctx_inject_payload() {  # <handoff_file>
  local f=$1 n
  [ -r "$f" ] || { printf ''; return 1; }
  n=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || n=0
  if [ "${n:-0}" -le "$FM_CTX_INJECT_CAP" ]; then
    cat "$f"
  else
    printf '[handoff %s chars > %s cap — read it in full at: %s]' "$n" "$FM_CTX_INJECT_CAP" "$f"
  fi
}
