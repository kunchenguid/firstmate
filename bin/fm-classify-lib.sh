#!/usr/bin/env bash
# Shared wake classifier: the single source of truth for deciding whether a
# watcher wake is captain-relevant (must reach firstmate's LLM) or benign
# (absorbed in bash). Sourced by BOTH the always-on watcher (bin/fm-watch.sh)
# and the away-mode daemon (bin/fm-supervise-daemon.sh) so the triage policy
# lives in one place instead of two copies that can drift apart.
#
# Every function is a pure, side-effect-free read of status files: it takes what
# it needs as arguments and touches no globals beyond the optional FM_CAPTAIN_RE
# override. Consumers layer their own dedup/marker state on top (the daemon keeps
# its escalation-digest seen-markers; the watcher keeps its .seen-* signatures).

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see; everything else (working: notes, bare turn-ended) is
# benign. FM_CAPTAIN_RE overrides the whole set when a home needs a custom verb
# vocabulary; absent, this default applies.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
status_is_captain_relevant() {
  local line=$1
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# task id from a tmux window name "<session>:fm-<id>" -> "<id>"
window_to_task() {
  local w=$1 t
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 (benign) otherwise. Pass the space-separated file
# list that follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended
# markers, which never carry a verb) are skipped, so a bare turn-end wake is
# benign.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 (non-terminal/benign) otherwise, including the no-status
# case. A non-terminal stale is a crew gone quiet mid-work: benign on first sight,
# but the caller bounds it with an idle-time escalation threshold.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
