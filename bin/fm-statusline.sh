#!/usr/bin/env bash
# fm-statusline.sh - compact one-line fleet readout for a Claude Code status line.
#
# Renders one line summarizing this home's live tasks from durable state only:
# state/*.meta names the task set, a bounded read of each state/<id>.status
# supplies the newest event and the keyed open-decision fold, and state/.afk
# adds an away marker. Classification follows fm-classify-lib.sh: the
# status_open_decisions fold decides "needs the captain" so a later unrelated
# event can never mask a still-open decision, and last-event verbs decide the
# rest. Idle secondmates are omitted because a quiet persistent secondmate is
# healthy.
#
# The script is strictly read-only: no cache file, no lock, no network, no
# fm-crew-state.sh deep reads, and no writes anywhere. It is built to stay well
# under 200ms with a typical fleet so a status line can re-run it freely.
# Status files larger than FM_STATUSLINE_FOLD_MAX_BYTES skip the whole-file
# fold and classify from the newest event only, so one pathological log cannot
# stall the readout.
#
# See --help for the output format, color legend, and Claude Code wiring recipe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

FM_STATUSLINE_NOTE_CHARS=${FM_STATUSLINE_NOTE_CHARS:-40}
FM_STATUSLINE_FOLD_MAX_BYTES=${FM_STATUSLINE_FOLD_MAX_BYTES:-65536}
case "$FM_STATUSLINE_NOTE_CHARS" in ''|*[!0-9]*|0*) FM_STATUSLINE_NOTE_CHARS=40 ;; esac
case "$FM_STATUSLINE_FOLD_MAX_BYTES" in ''|*[!0-9]*|0*) FM_STATUSLINE_FOLD_MAX_BYTES=65536 ;; esac

usage() {
  cat <<'EOF'
usage: fm-statusline.sh [--help]

Render a compact, color-coded one-line summary of this firstmate home's live
tasks, for embedding in a Claude Code status line.

Reads durable state only (state/*.meta, a bounded read of each
state/<id>.status, state/.afk) and writes nothing. Honors FM_HOME like every
other bin/ script; FM_STATE_OVERRIDE narrows the state dir for tests.

Output: a leading summary ("⚓ 3 crew · 1 needs you", or "⚓ fleet idle" when
nothing is live), then one short segment per task: symbol, short id (fm-
prefix stripped), a state word, and a hard-truncated note from the newest
status event. Needs-attention segments sort first.

Colors (ANSI; suppressed when NO_COLOR is set):
  red bold   ! needs-decision / blocked / failed - needs the captain
  cyan       ✔ done - finished, awaiting cleanup
  yellow     ~ paused / held - deliberate external wait
  dim green  · working - healthy, kept quiet
Idle secondmates are omitted: a quiet persistent secondmate is healthy.

Claude Code wiring (~/.claude/settings.json). Claude Code pipes session JSON
to the command on stdin and re-runs it itself as the session updates; this
script drains and ignores stdin, so it works piped or run bare:

  {
    "statusLine": {
      "type": "command",
      "command": "FM_HOME=$HOME/firstmate $HOME/firstmate/bin/fm-statusline.sh"
    }
  }

To compose with an existing status line command, print its segment first and
this one second (a second line is supported by Claude Code):

  "command": "bash -c 'json=$(cat); printf \"%s\" \"$json\" | your-statusline; FM_HOME=$HOME/firstmate $HOME/firstmate/bin/fm-statusline.sh </dev/null'"

Environment:
  FM_STATUSLINE_NOTE_CHARS      max note length per task (default 40)
  FM_STATUSLINE_FOLD_MAX_BYTES  status files larger than this skip the keyed
                                open-decision fold and classify from the
                                newest event only (default 65536)
  NO_COLOR                      disable ANSI colors when non-empty
EOF
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# The Claude Code statusLine contract pipes session JSON on stdin. Drain a
# bounded amount so the writer never sees a broken pipe, and ignore it: the
# fleet segment needs nothing from the session payload. A bare terminal run
# has a tty on stdin and skips the read.
[ -t 0 ] || head -c 1048576 >/dev/null 2>&1 || true

if [ -n "${NO_COLOR:-}" ]; then
  C_RED='' C_CYA='' C_YEL='' C_GRN='' C_DIM='' C_RST=''
else
  C_RED=$'\033[1;31m' C_CYA=$'\033[36m' C_YEL=$'\033[33m'
  C_GRN=$'\033[2;32m' C_DIM=$'\033[2m' C_RST=$'\033[0m'
fi
SEP="${C_DIM} │ ${C_RST}"
TAB=$'\t'
ESC=$'\033'

# Neutralize terminal-unsafe status text: strip common ANSI escape sequences,
# flatten whitespace, then keep printable ASCII only so a hostile or garbled
# note can never inject control bytes into the status bar.
sanitize_note() {  # <text> -> printable single-line ASCII on stdout
  printf '%s' "$1" \
    | LC_ALL=C sed "s,${ESC}\\[[0-9;?]*[a-zA-Z],,g" \
    | LC_ALL=C tr '\011\012\015' '   ' \
    | LC_ALL=C tr -cd '\040-\176'
}

# Hard-truncate into TRUNCATED without a subshell (safe on ASCII input).
trunc_into() {  # <text> <max-chars>
  local s=$1 n=$2
  if [ "${#s}" -gt "$n" ]; then
    TRUNCATED="${s:0:$((n - 1))}…"
  else
    TRUNCATED=$s
  fi
}

segs_red='' segs_done='' segs_wait='' segs_work=''
n_total=0 n_red=0

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}

  kind=ship
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in kind=*) kind=${line#kind=} ;; esac
  done < "$meta"

  f="$STATE/$id.status"
  last=''
  open=''
  if [ -f "$f" ]; then
    size=$(( $(wc -c < "$f" 2>/dev/null || printf 0) ))
    if [ "$size" -le "$FM_STATUSLINE_FOLD_MAX_BYTES" ]; then
      last=$(last_status_line "$f")
      open=$(status_open_decisions "$f")
    else
      last=$(tail -n 50 "$f" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)
      # Fold skipped on an oversized log: classify from the newest event only.
      verb=$(status_line_verb "$last")
      case "$verb" in
        needs-decision|blocked)
          open="default${TAB}${verb}${TAB}$(status_line_note "$last")"
          ;;
      esac
    fi
  fi

  verb=''
  shownote=''
  if [ -n "$last" ]; then
    verb=$(status_line_verb "$last")
    shownote=$(status_line_note "$last")
  fi

  class=work
  word=''
  if [ -n "$open" ]; then
    # The newest still-open decision wins the display for this task.
    newest=''
    while IFS= read -r ln; do
      [ -n "$ln" ] && newest=$ln
    done <<EOF
$open
EOF
    rest=${newest#*"$TAB"}
    overb=${rest%%"$TAB"*}
    shownote=${rest#*"$TAB"}
    class=red
    case "$overb" in
      needs-decision) word='needs you' ;;
      *) word='blocked' ;;
    esac
  elif [ "$verb" = failed ]; then
    class=red word=failed
  elif [ "$verb" = needs-decision ]; then
    # Defensive backstop: the fold keeps every needs-decision open (malformed
    # [key=...] tokens fold under "default" in fm-classify-lib.sh), but if it
    # ever yields nothing while the newest event still asks for the captain,
    # never demote that event below red.
    class=red word='needs you'
  elif [ "$verb" = blocked ]; then
    class=red word=blocked
  elif [ "$verb" = 'done' ]; then
    class='done' word='done'
  elif status_is_paused "$last"; then
    class=wait word=waiting
  elif [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]; then
    class=wait word=held
  elif [ -n "$last" ] && status_is_captain_relevant "$last"; then
    # Legacy free-text terminal lines ("PR ready", "merged") without a verb.
    class='done' word=ready
  fi

  if [ "$kind" = secondmate ]; then
    case "$class" in work|wait) continue ;; esac
  fi

  n_total=$((n_total + 1))

  sid=${id#fm-}
  sid=${sid#fm/}
  sid=$(sanitize_note "$sid")
  trunc_into "$sid" 20
  sid=$TRUNCATED
  if [ -n "$shownote" ]; then
    shownote=$(sanitize_note "$shownote")
    trunc_into "$shownote" "$FM_STATUSLINE_NOTE_CHARS"
    shownote=$TRUNCATED
  fi

  case "$class" in
    red)
      n_red=$((n_red + 1))
      seg="${C_RED}! ${sid} ${word}${shownote:+: }${shownote}${C_RST}"
      segs_red="${segs_red}${segs_red:+$SEP}${seg}"
      ;;
    done)
      seg="${C_CYA}✔ ${sid} ${word}${shownote:+: }${shownote}${C_RST}"
      segs_done="${segs_done}${segs_done:+$SEP}${seg}"
      ;;
    wait)
      seg="${C_YEL}~ ${sid} ${word}${shownote:+: }${shownote}${C_RST}"
      segs_wait="${segs_wait}${segs_wait:+$SEP}${seg}"
      ;;
    *)
      seg="${C_GRN}· ${sid}${shownote:+ }${shownote}${C_RST}"
      segs_work="${segs_work}${segs_work:+$SEP}${seg}"
      ;;
  esac
done

afk=''
[ -e "$STATE/.afk" ] && afk=1

if [ "$n_total" -eq 0 ]; then
  printf '%s\n' "${C_DIM}⚓ fleet idle${afk:+ · afk}${C_RST}"
  exit 0
fi

sum="${C_DIM}⚓ ${n_total} crew${C_RST}"
[ "$n_red" -gt 0 ] && sum="$sum ${C_RED}· ${n_red} needs you${C_RST}"
[ -n "$afk" ] && sum="$sum ${C_DIM}· afk${C_RST}"

out=''
for s in "$segs_red" "$segs_done" "$segs_wait" "$segs_work"; do
  [ -n "$s" ] || continue
  out="${out}${out:+$SEP}${s}"
done

printf '%s\n' "${sum}${out:+$SEP}${out}"
