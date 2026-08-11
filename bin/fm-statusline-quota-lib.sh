#!/usr/bin/env bash
# fm-statusline-quota-lib.sh - best-effort parse of crewmate statusline quota signals.
#
# Sourced, never executed. Owns pure parsers for the pane-visible statusline
# shapes that empirically report remaining capacity when quota-axi cannot:
#   claude: "5HR 3% ... WK 5% ..." (and similar token fragments)
#   codex:  "... Context 100% left · weekly 21% left"
#
# Contract (safety-critical):
#   - Exactly one row is read: the bottom-most line of the statusline region
#     that carries a known shape. A pane capture is mostly transcript, and
#     transcript text (a diff, a test file, a pasted statusline) can carry these
#     exact shapes - but it can only ever sit ABOVE the statusline, which the
#     harness draws at the bottom of the pane.
#   - Unparseable input is "unknown", never "exhausted".
#   - Only the quota windows (five_hour_pct, weekly_pct) decide the status.
#     context_pct is reported but never votes: it measures the context window,
#     not remaining quota, and a compacting harness at 0% context is healthy.
#   - A false exhaustion reading would migrate a healthy worker for no reason.
#   - This library never decides to hand off; firstmate chooses when to act.
#   - quota-axi remains best-effort elsewhere; this path is independent of it.
#
# Public functions:
#   fm_statusline_quota_tail <text> [lines]
#     Prints the statusline region of <text>: its last <lines> non-empty lines
#     (default FM_STATUSLINE_QUOTA_TAIL_LINES, itself defaulting to 6, which
#     covers the multi-row statuslines of the verified adapters).
#   fm_statusline_quota_line <text> [lines]
#     Prints the single row that owns the reading: the bottom-most line of that
#     region carrying a known shape. Empty when the region carries none.
#   fm_statusline_quota_parse <text>
#     Prints one line of key=value fields for the parsed signal.
#     Always exits 0. Fields always present: status, source.
#     status is one of: ok | low | unknown
#     "exhausted" is never emitted from unparseable input; only when a parsed
#     remaining QUOTA percentage is exactly 0 (or the literal "0% left" shape).
#     A signal that carries only a context reading stays unknown.
#   fm_statusline_quota_verdict <text>
#     Prints only the status token (ok|low|unknown|exhausted).

# fm_statusline_quota_tail <text> [lines]
fm_statusline_quota_tail() {
  local lines=${2:-${FM_STATUSLINE_QUOTA_TAIL_LINES:-6}}
  case "$lines" in
    ''|*[!0-9]*|0) lines=6 ;;
  esac
  printf '%s\n' "${1-}" | grep -v '^[[:space:]]*$' | tail -n "$lines" || true
}

# Any shape this library knows how to read. Keep in step with the extractions
# below: a shape that is parsed but not listed here can never be selected.
FM_STATUSLINE_QUOTA_SHAPE='(5HR|WK)[[:space:]]+[0-9]+%|(context|weekly)[[:space:]]+[0-9]+%[[:space:]]+left'

# fm_statusline_quota_line <text> [lines]
fm_statusline_quota_line() {
  fm_statusline_quota_tail "${1-}" "${2-}" \
    | grep -Ei "$FM_STATUSLINE_QUOTA_SHAPE" \
    | tail -n1 || true
}

# fm_statusline_quota_parse <text>
fm_statusline_quota_parse() {
  local text status=unknown source=none five_hr='' weekly='' context=''
  local n

  text=$(fm_statusline_quota_line "${1-}")

  # Codex: "Context N% left" and/or "weekly N% left"
  if printf '%s' "$text" | grep -Eqi 'Context[[:space:]]+[0-9]+%[[:space:]]+left'; then
    context=$(printf '%s' "$text" | sed -nE 's/.*[Cc]ontext[[:space:]]+([0-9]+)%[[:space:]]+left.*/\1/p' | tail -n1)
    source=codex
  fi
  if printf '%s' "$text" | grep -Eqi 'weekly[[:space:]]+[0-9]+%[[:space:]]+left'; then
    weekly=$(printf '%s' "$text" | sed -nE 's/.*[Ww]eekly[[:space:]]+([0-9]+)%[[:space:]]+left.*/\1/p' | tail -n1)
    source=codex
  fi

  # Claude: "5HR N%" and/or "WK N%"
  if printf '%s' "$text" | grep -Eqi '5HR[[:space:]]+[0-9]+%'; then
    five_hr=$(printf '%s' "$text" | sed -nE 's/.*5HR[[:space:]]+([0-9]+)%.*/\1/p' | tail -n1)
    source=claude
  fi
  if printf '%s' "$text" | grep -Eqi 'WK[[:space:]]+[0-9]+%'; then
    # Only claim the weekly field when this is not already a codex reading:
    # a codex "weekly N% left" is the authoritative one for that source.
    if [ "$source" != codex ]; then
      weekly=$(printf '%s' "$text" | sed -nE 's/.*WK[[:space:]]+([0-9]+)%.*/\1/p' | tail -n1)
    fi
    if [ "$source" = none ]; then
      source=claude
    fi
  fi

  if [ "$source" = none ]; then
    printf 'status=unknown source=none\n'
    return 0
  fi

  # Only the quota windows decide status. context_pct is a context-window
  # reading, not remaining capacity: a compacting harness at 0% context is
  # healthy, and letting it vote would be exactly the false exhaustion this
  # library refuses to emit. It stays a reported field and nothing more.
  # A zero quota sample is exhausted and wins outright; otherwise any sample in
  # 1..20 is low; anything else leaves ok. Unparseable samples never downgrade,
  # and a signal carrying no quota window at all stays unknown.
  status=unknown
  for n in $five_hr $weekly; do
    case "$n" in
      ''|*[!0-9]*) continue ;;
      0) status=exhausted; break ;;
      [1-9]|1[0-9]|20) status=low ;;
      *) if [ "$status" = unknown ]; then status=ok; fi ;;
    esac
  done

  printf 'status=%s source=%s' "$status" "$source"
  [ -n "$five_hr" ] && printf ' five_hour_pct=%s' "$five_hr"
  [ -n "$weekly" ] && printf ' weekly_pct=%s' "$weekly"
  [ -n "$context" ] && printf ' context_pct=%s' "$context"
  printf '\n'
}

# fm_statusline_quota_verdict <text>
fm_statusline_quota_verdict() {
  local line
  line=$(fm_statusline_quota_parse "$1")
  case "$line" in
    status=exhausted*) printf 'exhausted\n' ;;
    status=low*) printf 'low\n' ;;
    status=ok*) printf 'ok\n' ;;
    *) printf 'unknown\n' ;;
  esac
}
