#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# There are three documented exceptions. The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/fm-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor with folded open-decision and work-phase sets as a side effect, so a
# per-drain fleet-wide scan normally stays bounded by new appends instead of
# re-reading each task's whole lifetime log every time. Third, the decision fold
# appends to an anomaly sink when a caller wires one (see "status-line anomalies"
# below); with no sink it stays a pure transform.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
# Who WRITES the closing line is owned elsewhere: the answering firstmate closes
# at answer time through fm-send's --resolve-key (bin/fm-send.sh header), and a
# worker self-closes only a blocker that cleared without an answer (bin/fm-brief.sh
# rule 6), so closure never depends on a busy worker's discipline.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# _fm_status_parse below is the ONE place that grammar is decided.

# --- status line grammar ----------------------------------------------------
#
# The accepted grammar for one event in the append-only status log is
#
#   <verb>[ <token>]*: <note>
#
# The verb is a SINGLE word. Between it and the colon a writer may attach
# whitespace-free structured tokens: the "[key=<slug>]" decision key documented
# above, plus any other "<name>=<value>" or "[<name>=<value>]" attribute a
# writer needs - bin/fm-secondmate-report.sh emits "[corr=<16hex>]" on a
# correlated reply, and a hand-written reply may carry a bare "corr=<16hex>".
#
# Reading only the raw text before the colon cannot tell those two apart from
# prose, so a line that drifts off the grammar used to be classified anyway, in
# silence: an extra token before the key made the verb unrecognizable so a
# resolution never closed its key, and a key token written AFTER the colon was
# invisible so the opening event was filed under "default" while the line
# visibly named a key. Both failures are silent on a safety surface - the open
# set keeps crying wolf, and the one genuinely open decision stops being read.
#
# _fm_status_parse therefore classifies each line into exactly one class and
# never guesses. status_line_verb, status_line_note, _fm_decision_key, and the
# decision and activity folds all read its result instead of re-deriving the
# shape:
#
#   strict        - the prefix is a verb plus structured tokens only. Verb and
#                   key are read from it. An unknown verb still parses strictly:
#                   the grammar is about shape, not vocabulary.
#   misplaced-key - the prefix conforms and carries no key, and the note BEGINS
#                   with a "[key=<slug>]" token, i.e. the token landed on the
#                   wrong side of the colon. The key is HONORED, because filing
#                   the event under "default" while the line visibly names a key
#                   is exactly the silent mismatch this classification exists to
#                   prevent; the line is reported as an anomaly so the writer
#                   gets fixed. Only a LEADING token counts - a key mentioned
#                   inside prose ("docs still mention [key=q1]") stays prose.
#   malformed     - the first word IS a lifecycle verb but the line either has
#                   no colon or the rest of the prefix is prose, e.g. "resolved
#                   the conflict by hand: ...". Such a line is NEVER applied to
#                   the decision fold: reading the first word alone would let
#                   that sentence close a key it never claimed to close, and a
#                   wrongly CLOSED decision vanishes with no review, which is
#                   worse than an unclosed one that keeps surfacing. Reported as
#                   an anomaly instead.
#   freeform      - the prefix does not conform and its first word is not a
#                   lifecycle verb: an ordinary legacy line such as "merged" or
#                   "PR ready https://...". Not an anomaly, and status_line_verb
#                   keeps returning the whole trimmed prefix for it, so the
#                   free-text captain-relevance fallback keeps its verdicts.

# 0 if <word> is a lifecycle verb. Used ONLY to tell a malformed lifecycle line
# (an anomaly worth reporting) from ordinary free text (not an anomaly).
_fm_status_is_lifecycle_verb() {  # <word>
  case "$1" in
    working|needs-decision|blocked|done|failed) return 0 ;;
  esac
  case "$1" in
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") return 0 ;;
  esac
  case "$1" in
    "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}") return 0 ;;
  esac
  case "$1" in
    "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") return 0 ;;
  esac
  return 1
}

# 0 if <word> is a structured prefix token: "<name>=<value>", or its bracketed
# "[<name>=<value>]" form. A prose word ("the", "conflict", "by", "hand") never
# matches, which is what keeps a prose line out of the keyed decision fold.
_fm_status_is_token() {  # <word>
  local w=$1
  case "$w" in
    \[*\]) w=${w#\[}; w=${w%\]} ;;
  esac
  case "$w" in
    *\[*|*\]*) return 1 ;;
    [A-Za-z][A-Za-z0-9_-]*=?*) return 0 ;;
  esac
  return 1
}

# 0 if <slug> is a valid decision key slug.
_fm_status_valid_slug() {  # <slug>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Parse result of the last _fm_status_parse call. Globals rather than printed
# output so the per-line folds below stay fork-free over long status logs; every
# caller that must not leak them already runs inside a command substitution.
_FM_STATUS_CLASS=freeform
_FM_STATUS_VERB=
_FM_STATUS_KEY=default
_FM_STATUS_NOTE=

_fm_status_parse() {  # <status-line>
  local line=$1 prefix note rest word slug conforms=1 haskey=0 has_colon=0

  _FM_STATUS_CLASS=freeform
  _FM_STATUS_VERB=
  _FM_STATUS_KEY=default
  _FM_STATUS_NOTE=

  # A line with no colon has no note of its own; status_line_note has always
  # returned the whole line verbatim for it, so keep that exactly.
  case "$line" in
    *:*) has_colon=1; note=${line#*:}; note=${note#"${note%%[![:space:]]*}"}; prefix=${line%%:*} ;;
    *)   note=$line; prefix=$line ;;
  esac
  _FM_STATUS_NOTE=$note

  rest=${prefix#"${prefix%%[![:space:]]*}"}
  rest=${rest%"${rest##*[![:space:]]}"}
  _FM_STATUS_VERB=${rest%%[[:space:]]*}
  rest=${rest#"$_FM_STATUS_VERB"}

  if [ "$has_colon" != 1 ]; then
    if _fm_status_is_lifecycle_verb "$_FM_STATUS_VERB"; then
      _FM_STATUS_CLASS=malformed
    else
      _FM_STATUS_CLASS=freeform
    fi
    return 0
  fi

  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    word=${rest%%[[:space:]]*}
    rest=${rest#"$word"}
    _fm_status_is_token "$word" || { conforms=0; break; }
    case "$word" in
      \[key=*\]|key=*)
        slug=${word#\[}
        slug=${slug%\]}
        slug=${slug#key=}
        # A second key token makes the line genuinely ambiguous; refuse it
        # rather than silently picking one of the two.
        if [ "$haskey" = 1 ] || ! _fm_status_valid_slug "$slug"; then
          conforms=0
          break
        fi
        haskey=1
        _FM_STATUS_KEY=$slug
        ;;
    esac
  done

  if [ "$conforms" != 1 ]; then
    _FM_STATUS_KEY=default
    if _fm_status_is_lifecycle_verb "$_FM_STATUS_VERB"; then
      _FM_STATUS_CLASS=malformed
    else
      _FM_STATUS_CLASS=freeform
    fi
    return 0
  fi

  _FM_STATUS_CLASS=strict
  if [ "$haskey" = 0 ]; then
    case "$note" in
      \[key=*\]*)
        slug=${note#\[key=}
        slug=${slug%%\]*}
        if _fm_status_valid_slug "$slug"; then
          _FM_STATUS_CLASS=misplaced-key
          _FM_STATUS_KEY=$slug
          note=${note#*\]}
          _FM_STATUS_NOTE=${note#"${note%%[![:space:]]*}"}
        fi
        ;;
    esac
  fi
  return 0
}

# The pre-grammar verb read: everything before the first colon minus a key
# token, trimmed. Kept verbatim for lines the grammar does NOT accept, so
# status_is_captain_relevant's free-text fallback keeps its existing verdicts on
# prose and on legacy bare lines such as "PR ready https://x/pull/2".
_fm_status_line_verb_legacy() {  # <status-line>
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

status_line_verb() {  # <status-line> -> leading verb word
  _fm_status_parse "$1"
  case "$_FM_STATUS_CLASS" in
    strict|misplaced-key) printf '%s' "$_FM_STATUS_VERB" ;;
    *) _fm_status_line_verb_legacy "$1" ;;
  esac
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  # An honored misplaced key token is dropped from the note: leaving it in would
  # print the key twice on a surface that already names it, which is what made
  # a mismatched key look like a match.
  _fm_status_parse "$1"
  printf '%s' "$_FM_STATUS_NOTE"
}
_fm_decision_key() {  # <status-line> -> key slug; nonzero for malformed lifecycle lines
  _fm_status_parse "$1"
  [ "$_FM_STATUS_CLASS" != malformed ] || return 1
  printf '%s' "$_FM_STATUS_KEY"
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# --- status-line anomalies --------------------------------------------------
#
# A line the grammar refuses, and a resolution that closes a key neither a
# decision nor a work phase opened, are both direct symptoms of a writer bug.
# Neither may be classified in silence: an unreported refusal reads as "closed"
# to whoever wrote it while the open set keeps crying wolf, and an unreported
# unmatched close is the only on-disk trace that an OPENING line was misfiled
# under another key. So the fold reports them on an explicit side channel. Records are
# "<task>\t<kind>\t<key>\t<line>", one per offending line, with these kinds:
#
#   malformed       out of grammar; NOT applied to the open set.
#   misplaced-key   key token written after the colon; APPLIED to that key.
#   unmatched-close a resolution or captain-held transfer for a key that was not
#                   open in either fold; no effect on the open set.
#
# Wiring a sink is opt-in: callers that only need the open set (the fleet
# snapshot, the decision-hold verifier, the away-mode return digest) pass none
# and are unaffected. bin/fm-wake-drain.sh wires one and prints the records
# beside OPEN DECISIONS, so a bad writer surfaces on the next wake instead of
# after the second lost decision. Through the incremental fold each appended
# line is read exactly once, so each anomaly reports once rather than on every
# drain; the exceptions are the same ones that force a full re-fold there (no
# current-schema cursor yet, or a truncated/replaced status file), which
# re-report that file's history once under the drain's own byte cap.
# The task and key fields default to "-" rather than staying empty: tab is an
# IFS whitespace character, so a consumer splitting on tab would collapse an
# empty field and shift the status line into the wrong column.
_fm_decision_note_anomaly() {  # <sink> <task> <kind> <key> <status-line>
  [ -n "$1" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "${2:--}" "$3" "${4:--}" "$5" >> "$1" 2>/dev/null || true
}

# 0 if <key> currently has a record in the "<key>\t<verb>\t<note>\n"-per-line
# open set. Blank separator lines _fm_decision_drop can leave behind are why the
# second pattern matches a key after ANY newline, not only after a record.
_fm_decision_is_open() {  # <open-set> <key>
  case "$1" in
    "$2"$'\t'*|*$'\n'"$2"$'\t'*) return 0 ;;
  esac
  return 1
}

# Fold ONE status line into an existing open work-phase set.
_fm_activity_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb>
  local open=$1 line=$2 resolve=$3 held=$4 verb key note stripped pause
  stripped=${line//[[:space:]]/}
  [ -n "$stripped" ] || { printf '%s' "$open"; return 0; }
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  _fm_status_parse "$line"
  [ "$_FM_STATUS_CLASS" != malformed ] || { printf '%s' "$open"; return 0; }
  verb=$_FM_STATUS_VERB
  key=$_FM_STATUS_KEY
  case "$verb" in
    working|"$pause")
      note=$_FM_STATUS_NOTE
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    done|failed|needs-decision|blocked|"$resolve"|"$held")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      ;;
  esac
  printf '%s' "$open"
}

# Fold ONE status line into an existing "<key>\t<verb>\t<note>\n"-per-line open
# set, applying the same needs-decision/blocked-opens, resolved/captain-held-closes
# rule status_open_decisions documents above. The optional sink and task label
# carry the anomaly records described above; with no sink this is a pure text
# transform, no file I/O.
# This is the ONE place the per-line open/resolved rule is written; both the
# whole-file fold (status_open_decisions) and the incremental cursor-backed fold
# (status_open_decisions_incremental) below call this instead of re-deriving the
# rule, so the two consumption strategies can never drift apart on semantics.
# Reserved decision-key namespaces, and the rule that makes them mean something.
#
# A key like `pending-reply-<id>` names a decision that one library raises and is
# the only thing that ever closes it. Every writer reaches this same stream: a
# local mate appends straight into it, and a remote mate's lines are mirrored
# into it verbatim. So without a rule here, any writer could claim a reserved
# key with an unrelated note, take the key over in this fold, and permanently
# block the owner's close - leaving a decision nothing will ever resolve - or
# clear the owner's decision with a bare resolution.
#
# The rule is deliberately generic, so this fold needs no knowledge of any
# particular owner: a reserved key may only be opened or closed by a line whose
# note speaks that namespace's own vocabulary, which its owner states by
# beginning the note with a `<namespace>...:` token. A line failing that is not a
# decision transition at all here and is folded as ordinary status. This is a
# consumer-side rule on purpose - it protects local and remote writers
# identically, and it can never fail a whole delta or wedge a stream the way a
# writer-side rejection would.
FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT='pending-reply-'

# 0 when <key> is not reserved, or is reserved and <note> speaks its vocabulary.
_fm_decision_key_transition_allowed() {  # <key> <note>
  local key=$1 note=$2 prefix
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        case "$note" in
          "$prefix"*:*) return 0 ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done
  return 0
}

_fm_decision_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb> [<sink>] [<task>] [<open-activities>]
  local open=$1 line=$2 resolve=$3 held=$4 sink=${5-} task=${6-} activities=${7-}
  local verb key note stripped
  stripped=${line//[[:space:]]/}
  [ -n "$stripped" ] || { printf '%s' "$open"; return 0; }
  _fm_status_parse "$line"
  case "$_FM_STATUS_CLASS" in
    malformed)
      _fm_decision_note_anomaly "$sink" "$task" malformed '' "$line"
      printf '%s' "$open"
      return 0
      ;;
    misplaced-key)
      _fm_decision_note_anomaly "$sink" "$task" misplaced-key "$_FM_STATUS_KEY" "$line"
      ;;
  esac
  verb=$_FM_STATUS_VERB
  key=$_FM_STATUS_KEY
  note=$_FM_STATUS_NOTE
  _fm_decision_key_transition_allowed "$key" "$note" \
    || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    "$resolve"|"$held")
      _fm_decision_is_open "$open" "$key" \
        || _fm_decision_is_open "$activities" "$key" \
        || _fm_decision_note_anomaly "$sink" "$task" unmatched-close "$key" "$line"
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      ;;
  esac
  printf '%s' "$open"
}

# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
# The scan_open_decisions wrapper below enumerates a whole directory rather than
# a single caller-chosen path, so a status file that is itself a symlink (e.g.
# escaping the state directory) is rejected outright with a plain [ -L ] check
# before any read - a cheap builtin, unlike fm_wake_latest_event's O_NOFOLLOW
# subprocess read, which exists for that function's much narrower payload-driven
# path resolution rather than this directory-local glob.
status_open_decisions() {  # <status-file> [<anomaly-sink>]
  local f=$1 sink=${2-} line resolve held open='' activities='' task
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  task=${f##*/}; task=${task%.status}
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$sink" "$task" "$activities")
    activities=$(_fm_activity_fold_line "$activities" "$line" "$resolve" "$held")
  done < "$f"
  printf '%s' "$open"
}

# Fleet-wide wrapper around status_open_decisions: scans every task's status
# log under <state> and prefixes each still-open decision with its owning task
# id, so a per-wake or per-session surface can print the consolidated open set
# without re-walking the fold itself. A thin directory scan only - the fold
# above remains the ONE place the open/resolved semantics are decided. Prints
# one "<task>\t<key>\t<verb>\t<note>" line per open decision, in glob (task id)
# order; prints nothing when none are open.
scan_open_decisions() {  # <state> [<anomaly-sink>]
  local state=$1 sink=${2-} f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions "$f" "$sink") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

# --- incremental (cursor-backed) open-decisions fold ------------------------
#
# status_open_decisions above re-reads and re-folds a status file's ENTIRE
# lifetime on every call, so its cost grows with total log size. A per-drain
# fleet-wide scan using that whole-file function would pay that cost for every
# task on every wake, which grows unbounded as tasks run longer and accumulate
# status history. status_open_decisions_incremental and scan_open_decisions_incremental
# below are the bounded-cost siblings used for that per-drain path: each call
# reads only the bytes appended to a status file since its own last call (a
# persisted per-file byte cursor) and folds just those new lines into a
# persisted running decision and work-phase sets, via the exact same fold rules
# status_open_decisions uses - so the two strategies can never disagree on what
# is open or whether a closure belongs to an open phase. Cost is bounded by NEW
# appends since the last drain, not by the status file's total lifetime size.
#
# Correctness invariant (unchanged from the whole-file fold): an open decision
# is dropped ONLY by an explicit resolved/captain-held line for its exact key,
# never by cursor advancement, age, or being buried under later appends - the
# persisted open-set carries every still-open key forward across calls
# regardless of how much new unrelated log content has since been folded in.
#
# Cursor invalidation is deliberately minimal, matching how status files are
# ACTUALLY used in this repo: every one is created once (`>`) and only ever
# appended to (`>>`) - never replaced, renamed, or rewritten in place. A cursor
# goes stale when its schema version changes, the file shrinks, or the file at
# this path is replaced/rotated/recreated. A changed device+inode makes the last
# case an O(1) check via a single `stat` call - no content hashing, no re-reading
# the consumed prefix. Any signal falls back to a full re-fold of the whole
# current file from byte 0 - byte for byte what status_open_decisions itself
# would compute - and rewrites the cursor from that clean baseline. A same-inode,
# same-size, in-place byte edit is NOT detected; that is a deliberately accepted
# gap because no code path in this repo ever does that to a status file.
#
# The other real failure mode is OUR OWN read failing (a stat/wc/tail I/O
# error), not a malformed writer: every such read here is checked, and on
# failure this reports the already-trusted persisted set unchanged rather than
# risking a silent invalidation that would wipe it - never a bare "empty" as if
# nothing were open.
#
# Not a pure status-file read: this writes/rewrites the sibling cursor file as a
# side effect (state/.<task>.open-decisions-cursor), the library's second
# documented exception to the pure-read rule after crew_absorb_class. The write
# is atomic (temp file + rename), so a crash between calls leaves either the
# prior cursor or the new one, never a partial one. bin/fm-wake-drain.sh calls
# this only after releasing the wake-queue lock, so a hypothetical race between
# two overlapping drains can at worst redo a little folding work twice - never
# drop an open decision - because a losing writer's offset can only ever be
# equal to or behind an already-recorded byte position, and the next call
# re-derives from whatever offset actually landed on disk.
_FM_OPEN_DECISIONS_CURSOR_VERSION=2

_fm_open_decisions_cursor_path() {  # <status-file>
  local f=$1 dir base
  dir=$(dirname "$f")
  base=$(basename "$f")
  printf '%s/.%s.open-decisions-cursor' "$dir" "${base%.status}"
}

# Portable device:inode identity for the rotation/recreation check below.
_fm_open_decisions_file_ident() {  # <file> -> "dev:inode", empty on I/O failure
  local f=$1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null
  fi
}

status_open_decisions_incremental() {  # <status-file> [<anomaly-sink>]
  local f=$1 sink=${2-} cf offset ident open='' activities='' trusted_open='' cursor_data first rest
  local offset_line ident_line record payload cursor_valid=0 rewrite=0
  local size cur_ident resolve held chunk_file chunk_size expected_size line task
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  task=${f##*/}; task=${task%.status}
  cf=$(_fm_open_decisions_cursor_path "$f")
  offset=0
  ident=''
  if [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ]; then
    if cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null); then
      first=${cursor_data%%$'\n'*}
      if [ "$first" = "version=$_FM_OPEN_DECISIONS_CURSOR_VERSION" ]; then
        case "$cursor_data" in
          *$'\n'*) rest=${cursor_data#*$'\n'} ;;
          *) rest= ;;
        esac
        offset_line=${rest%%$'\n'*}
        case "$offset_line" in
          offset=*) offset=${offset_line#offset=} ;;
          *) offset= ;;
        esac
        case "$offset" in
          ''|*[!0-9]*) offset=0 ;;
          *)
            case "$rest" in
              *$'\n'*)
                rest=${rest#*$'\n'}
                ident_line=${rest%%$'\n'*}
                case "$ident_line" in
                  ident=*) ident=${ident_line#ident=}; cursor_valid=1 ;;
                  *) offset=0 ;;
                esac
                case "$rest" in
                  *$'\n'*) rest=${rest#*$'\n'} ;;
                  *) rest= ;;
                esac
                ;;
              *) offset=0 ;;
            esac
            ;;
        esac
        if [ "$cursor_valid" = 1 ] && [ -n "$rest" ]; then
          while IFS= read -r record || [ -n "$record" ]; do
            case "$record" in
              decision$'\t'*)
                payload=${record#*$'\t'}
                [ -n "$payload" ] || { cursor_valid=0; break; }
                [ -n "$open" ] && open="${open}"$'\n'
                open="${open}${payload}"
                ;;
              activity$'\t'*)
                payload=${record#*$'\t'}
                [ -n "$payload" ] || { cursor_valid=0; break; }
                [ -n "$activities" ] && activities="${activities}"$'\n'
                activities="${activities}${payload}"
                ;;
              *) cursor_valid=0; break ;;
            esac
          done <<EOF
$rest
EOF
        fi
        if [ "$cursor_valid" = 1 ]; then
          trusted_open=$open
        else
          offset=0
          ident=''
          open=''
          activities=''
        fi
      fi
    fi
  fi

  # A stat/size-read failure is a genuine I/O error, not "the file is empty" -
  # report the already-trusted persisted set unchanged rather than risking a
  # silent invalidation that would wipe it.
  cur_ident=$(_fm_open_decisions_file_ident "$f") || { printf '%s' "$trusted_open"; return 0; }
  [ -n "$cur_ident" ] || { printf '%s' "$trusted_open"; return 0; }
  size=$(LC_ALL=C wc -c < "$f" 2>/dev/null) \
    || { printf '%s' "$trusted_open"; return 0; }
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) printf '%s' "$trusted_open"; return 0 ;; esac

  if [ "$cursor_valid" != 1 ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=0
    open=''
    activities=''
    rewrite=1
  fi

  if [ "$offset" -lt "$size" ]; then
    chunk_file="$cf.read.$$"
    expected_size=$((size - offset))
    tail -c "+$((offset + 1))" "$f" 2>/dev/null \
      | head -c "$expected_size" > "$chunk_file" 2>/dev/null
    chunk_size=$(LC_ALL=C wc -c < "$chunk_file" 2>/dev/null) \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    chunk_size=${chunk_size//[[:space:]]/}
    case "$chunk_size" in
      ''|*[!0-9]*) rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0 ;;
    esac
    [ "$chunk_size" = "$expected_size" ] \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    # Test-only observability seam (off by default, no production behavior
    # change): when set, records exactly how many bytes THIS call folded, so a
    # test can assert the incremental path stays bounded by new appends rather
    # than re-reading the whole file, without relying on timing or source text.
    [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
      && printf '%s\t%s\n' "$f" "$chunk_size" >> "$FM_OPEN_DECISIONS_READ_PROBE"
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
    while IFS= read -r line || [ -n "$line" ]; do
      open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$sink" "$task" "$activities")
      activities=$(_fm_activity_fold_line "$activities" "$line" "$resolve" "$held")
    done < "$chunk_file"
    rm -f "$chunk_file"
    offset=$size
    rewrite=1
  fi
  if [ "$rewrite" = 1 ]; then
    {
      printf 'version=%s\n' "$_FM_OPEN_DECISIONS_CURSOR_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      while IFS= read -r record; do
        if [ -n "$record" ]; then printf 'decision\t%s\n' "$record"; fi
      done <<EOF
$open
EOF
      while IFS= read -r record; do
        if [ -n "$record" ]; then printf 'activity\t%s\n' "$record"; fi
      done <<EOF
$activities
EOF
      :
    } > "$cf.tmp.$$" && mv -f "$cf.tmp.$$" "$cf"
  fi
  printf '%s' "$open"
}

# Incremental sibling of scan_open_decisions: same fleet-wide directory walk and
# output shape ("<task>\t<key>\t<verb>\t<note>" per open decision), but folds
# each task's status log through status_open_decisions_incremental instead of
# the whole-file status_open_decisions, so a fleet-wide per-drain scan stays
# bounded by new appends rather than total lifetime log size across every task.
scan_open_decisions_incremental() {  # <state> [<anomaly-sink>]
  local state=$1 sink=${2-} f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions_incremental "$f" "$sink") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line resolve held open=''
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(_fm_activity_fold_line "$open" "$line" "$resolve" "$held")
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
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

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
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
