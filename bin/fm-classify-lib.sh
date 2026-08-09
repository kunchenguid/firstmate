#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, the captain-gated-versus-external pause
# kind, and the working/paused absorb classification that makes no-verb signal and
# stale-pane wakes safe to absorb.
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
# There are three documented exceptions. task_hold_kind reads the backlog
# through its own tool; see its own comment for the callers' cost contract.
# The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/fm-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, settled in a terminal state, or none of those. Callers run
# it ONLY on no-verb signal handling, first sighting of a stale hash, and
# immediately before escalating a possible wedge - never on every wake - so the
# per-wake triage stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor and folded open-set as a side effect, so a per-drain fleet-wide scan
# stays bounded by new appends instead of re-reading each task's whole lifetime
# log every time.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The typed status-event envelope (`fm-status-event.v1`). Sourced eagerly, unlike
# fm-wake-lib.sh below, because it is PURE: it observes nothing and creates
# nothing, so a strictly read-only consumer of this library keeps its read-only
# behavior. bin/fm-status-event-lib.sh owns the wire format; this library owns
# what the fields MEAN.
# shellcheck source=bin/fm-status-event-lib.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-status-event-lib.sh"

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification.
FM_CLASSIFY_CAPTAIN_TERMINAL_VERBS='done needs-decision blocked failed'

# Nonterminal verbs: a crew declaring one of these is reporting progress or
# closing its own bookkeeping, never work for firstmate to act on.
FM_CLASSIFY_NONTERMINAL_VERBS='working resolved captain-held'

# 0 if <verb> is one of them. The away-mode daemon keeps its own backstop against
# a nonterminal verb reaching a terminal stale path, and reads the set here so
# there is one vocabulary rather than two that can drift.
status_verb_is_nonterminal() {  # <verb>
  [ -n "${1:-}" ] || return 1
  case " $FM_CLASSIFY_NONTERMINAL_VERBS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# The default vocabulary as a regex, kept ONLY as the documented starting point a
# home edits into FM_CAPTAIN_RE. The default classification path no longer runs a
# regex at all, so this string is reachable only when a home has explicitly opted
# into custom matching (see status_is_captain_relevant).
#
# The free-text arm this constant used to carry - `PR ready|checks green|ready in
# branch|merged` - is RETIRED. Those tokens matched a crew's own prose, so a
# nonterminal line became captain-relevant purely by mentioning one, and
# "working: rebased onto merged #76" was escalated as a terminal event. That was
# defended by a rule excluding nonterminal verbs, which is a guard around a
# guess. Classification now reads the verb - a field on a typed event, the
# leading word on a prose line - and never the note, so the collision class
# cannot recur rather than being caught after the fact. The nonterminal-verb rule
# survives below as declared policy rather than as that defence, and still
# applies on the custom-regex path, where prose matching is what the home asked
# for.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:'

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
# avoids nagging a deliberate wait while ensuring a forgotten external wait cannot
# rot invisibly. One hour by default; both consumers read FM_PAUSE_RESURFACE_SECS
# with this default so the cadence has one owner, while away mode suppresses only
# captain-gated rechecks as owned by the /afk skill.
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
  case " $FM_CLASSIFY_CAPTAIN_TERMINAL_VERBS " in
    *" $verb "*) return 0 ;;
  esac
  return 1
}

# 0 if a status line is work firstmate must see.
#
# The decision is made on the VERB and nothing else: the field on a typed
# fm-status-event.v1 line, the leading word on a prose line. The crew's note is
# never consulted, so no wording a crew chooses can change how its event is
# classified - which is the whole point of the retirement recorded on
# FM_CLASSIFY_CAPTAIN_RE_DEFAULT above.
#
# A REFUSED typed event surfaces. A malformed event is a could-not-observe, and
# an unobserved result cannot be absorbed into "nothing to see": firstmate must
# be the one to look at it.
#
# FM_CAPTAIN_RE remains the escape hatch for a home whose crews use a custom verb
# vocabulary. Setting it replaces the whole set and reinstates prose matching,
# which is what that home asked for; the nonterminal-verb rule still applies
# there, and a typed event is matched through its canonical prose projection so a
# custom vocabulary keeps working across the migration.
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  if fm_status_event_is_typed "$line"; then
    [ -z "$(fm_status_event_invalid_reason "$line")" ] || return 0
  fi
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case " $FM_CLASSIFY_NONTERMINAL_VERBS " in
    *" $verb "*) return 1 ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case " $FM_CLASSIFY_CAPTAIN_TERMINAL_VERBS " in
      *" $verb "*) return 0 ;;
    esac
    return 1
  fi
  fm_status_event_prose "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
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

# --- backend-pushed blocked-on-human stale wakes ----------------------------
#
# A push-capable backend can report an agent-state edge to `blocked` - the
# harness stopped for a human prompt (a permission dialog, a trust prompt, an
# interactive menu). bin/fm-transition-lib.sh's policy table is the one owner of
# that classification, and the producer already applies EDGE-triggered dedupe on
# agent state: one wake per `->blocked` edge, cleared by the next `->working`
# edge. The wake therefore arrives pre-deduplicated, and the ordinary stale
# path's STATUS-LINE dedupe must not be layered on top of it. A task correctly
# parked on a captain decision has an unchanged terminal status line by
# definition, so keying on status text absorbs every block after the first and
# the worker waits on a prompt nobody sees. Keying a second time on agent state
# would duplicate the producer's dedupe in a second owner instead.
#
# The two functions below are the ONE owner of that wake's detail grammar: the
# producer builds the detail with stale_detail_blocked_on_human and every
# consumer recognizes it with stale_detail_is_blocked_on_human, so neither side
# spells the text itself and a reworded producer cannot silently stop being
# exempt. The invariant suffix carries the meaning; the backend and agent-state
# prefix is telemetry for the reader.
FM_CLASSIFY_BLOCKED_ON_HUMAN_DETAIL='waiting on human, escalated immediately, not via wedge timer'

# Build the stale-wake detail for a backend-pushed blocked-on-human edge.
stale_detail_blocked_on_human() {  # <backend> <agent-state>
  printf '%s: agent %s - %s' "$1" "$2" "$FM_CLASSIFY_BLOCKED_ON_HUMAN_DETAIL"
}

# 0 if a stale wake's parenthesized detail is a backend-pushed blocked-on-human
# edge. Suffix-anchored on the invariant above so an ordinary wedge detail, a
# window name, or an empty detail never matches.
stale_detail_is_blocked_on_human() {  # <stale-detail>
  local detail=$1
  [ -n "$detail" ] || return 1
  case "$detail" in
    *"$FM_CLASSIFY_BLOCKED_ON_HUMAN_DETAIL") return 0 ;;
  esac
  return 1
}

# The COMPLETE crew-state verdict vocabulary, in one place. bin/fm-crew-state.sh
# derives these and every consumer must handle all of them: a consumer that
# silently defaults an unlisted verdict is how a correct reader still produced a
# wrong supervision outcome (wedge aging tested one class and defaulted the
# rest). Adding a verdict means adding it here, which makes the conformance test
# in tests/fm-crew-state.test.sh fail until every consumer handles it - the
# whole point is that the next verdict cannot be added silently.
FM_CREW_STATE_VOCABULARY='working parked blocked paused done failed aborted interrupted idle stale unknown'

# 0 if <state> is a verdict this fleet knows about.
crew_state_is_known() {  # <state>
  [ -n "${1:-}" ] || return 1
  case " $FM_CREW_STATE_VOCABULARY " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# --- pause kind: can this wait change without the captain? -------------------
#
# status_is_paused answers "does this pane idle by design". It does NOT answer the
# question a re-surface cadence actually asks: can the thing being waited on change
# without the captain acting? An external wait can, so rechecking it is real work.
# A captain-gated wait cannot - it clears only when the captain acts, and the
# captain acting is already the away-mode exit signal, which runs the full return
# catch-up, so a timed recheck can never surface anything that exit does not.
#
# The backlog already records exactly this distinction per work item as hold_kind
# (captain|external|load|parked|future), so these read that existing vocabulary
# instead of parsing pause prose or inventing a parallel one.
#
# NOT a pure read: task_hold_kind shells out to the backlog reader in FM_HOME, the
# same tool and field bin/fm-decision-hold.sh verifies a captain hold with. Callers
# run it only once a pause has already aged past its window, never on every wake.
FM_CLASSIFY_CAPTAIN_HOLD_KIND_DEFAULT='captain'

_fm_show_field() {  # <tasks-axi-show-output> <field> -> value, or empty
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2: //p" | head -1
}

# Print the backlog hold kind recorded for <task-id>, or `unknown` when it cannot
# be established: no reader, an unreadable or absent item, or an item that carries
# no active hold at all. `unknown` is deliberately never a kind a caller may treat
# as captain-gated, so an indeterminate wait keeps its ordinary handling.
task_hold_kind() {  # <task-id> [home]
  local id=$1 home=${2:-${FM_HOME:-}} out kind
  case "$id" in ''|*[!A-Za-z0-9._-]*) printf 'unknown'; return ;; esac
  command -v tasks-axi >/dev/null 2>&1 || { printf 'unknown'; return; }
  if [ -n "$home" ] && [ -d "$home" ]; then
    out=$(cd "$home" && tasks-axi show "$id" --full 2>/dev/null) || out=''
  else
    out=$(tasks-axi show "$id" --full 2>/dev/null) || out=''
  fi
  [ -n "$out" ] || { printf 'unknown'; return; }
  [ "$(_fm_show_field "$out" held)" = yes ] || { printf 'unknown'; return; }
  kind=$(_fm_show_field "$out" hold_kind)
  case "$kind" in
    ''|*[!A-Za-z0-9._-]*) printf 'unknown' ;;
    *) printf '%s' "$kind" ;;
  esac
}

# 0 if <task-id>'s declared wait is gated on the captain rather than on something
# that can clear by itself. Consumers use it to decide CADENCE only: a captain-gated
# wait stays exactly as visible as before in the backlog digest, the fleet view, and
# the away-mode return catch-up - it simply stops being re-asked on a timer.
pause_is_captain_gated() {  # <task-id> [home]
  [ "$(task_hold_kind "$@")" = "${FM_CLASSIFY_CAPTAIN_HOLD_KIND:-$FM_CLASSIFY_CAPTAIN_HOLD_KIND_DEFAULT}" ]
}

# Does a crew's current verdict CLEAR a keyed open decision, or does the decision
# keep surfacing? Owned here, next to the vocabulary it must cover, because the
# rule is a statement about the verdict set rather than about any one consumer.
#
# Only POSITIVE evidence that the crew moved PAST the gate clears a decision:
#   - `working` read from an authoritative live source (run-step or pane), so a
#     crew that answered the gate and resumed is not still reported as parked; or
#   - a terminal `done`/`failed`, whose deliverable is the report or PR, so a
#     COMPLETED single-owner task surfaces as a pointer rather than a reopened
#     decision.
# Every other verdict keeps it. `parked` and `blocked` are the gate itself.
# `aborted` and `interrupted` are run-level, not task-level: the run stopped
# without judging the work and the deliverable that would justify clearing does
# not exist yet. `stale` and `unknown` are the absence of a reliable read, and an
# absent result is never a pass. `paused` is a declared wait, and `idle` means
# the crew declared nothing - neither is evidence it moved past the gate.
#
# Exit codes are THREE-valued on purpose: 0 clear, 1 keep, 2 the verdict matched
# no arm above. The previous form of this rule lived in bin/fm-fleet-snapshot.sh
# as a chain of negative conditions that named only parked and blocked as
# exceptions, so every verdict added afterwards fell into the CLEARING branch by
# omission - silently, and in the unsafe direction, since a dropped open decision
# loses a captain's question while a spurious one only costs a glance. A default
# branch that quietly picks either answer is exactly that defect, so an unhandled
# verdict is its own reportable outcome: callers treat 2 as keep, and the
# coverage gate in tests/fm-crew-state.test.sh fails when any member of
# FM_CREW_STATE_VOCABULARY reaches it.
crew_state_clears_open_decision() {  # <state> <source>
  case "${1:-}" in
    working)
      case "${2:-}" in
        run-step|pane) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    done|failed) return 0 ;;
    parked|blocked|paused|aborted|interrupted|idle|stale|unknown) return 1 ;;
  esac
  return 2
}

# May an idle-looking crew at this verdict be ABSORBED instead of surfaced to a
# supervisor? Owned here beside the vocabulary for the same reason as
# crew_state_clears_open_decision: it is a statement about the verdict set, and
# the watcher's absorb path (crew_absorb_class below) is the consumer that
# applies it. Prints exactly one token:
#   working - a running no-mistakes step or a busy pane, so the crew is
#             legitimately mid-work behind a static-looking pane;
#   paused  - a declared external wait, which is EXPECTED to idle;
#   none    - surface the wake.
# Only run-step and pane are POSITIVE evidence of work in flight; a `working`
# derived from the status log is the crew's own claim, and a claim is not a
# verdict.
#
# Exit codes carry what the printed token cannot, because `none` is both the
# right answer for most verdicts AND the safe fallback: 0 an explicit arm
# answered, 3 the verdict is one this fleet DECLARES but this consumer was never
# taught, 2 the verdict is outside FM_CREW_STATE_VOCABULARY entirely. Only 2 is
# a legitimate steady state - a reader newer than this consumer, or a stubbed
# verdict - and crew_state_is_known is what separates the two, so the claim that
# the fallback is unreachable for a declared verdict is executed rather than
# asserted in prose. The coverage gate in tests/fm-crew-state.test.sh walks the
# vocabulary and fails on any 3.
crew_state_absorb_class() {  # <state> <source>
  case "${1:-}" in
    paused) printf 'paused'; return 0 ;;
    working)
      case "${2:-}" in run-step|pane) printf 'working'; return 0 ;; esac
      printf 'none'; return 0
      ;;
    # Terminal, waiting, or unproven: all must reach a supervisor.
    #   parked/blocked        need a decision or help
    #   done/failed/aborted   are outcomes to act on
    #   interrupted           needs a re-run, and is NOT a rejection
    #   idle                  alive but doing nothing, so a wake still matters
    #   stale                 nothing has touched the crew's turn record since
    #                         its timestamp, so there is no evidence of activity
    #                         to absorb against and the crew must surface
    #   unknown               unproven, and unproven never absorbs
    parked|blocked|done|failed|aborted|interrupted|idle|stale|unknown)
      printf 'none'; return 0
      ;;
  esac
  printf 'none'
  crew_state_is_known "${1:-}" && return 3
  return 2
}

# Read one string field out of bin/fm-crew-state.sh's --json object. The object
# is flat and this reader owns its shape, so a bounded extraction is exact for
# the TOKEN fields (state, source, precedence_applied), whose values are
# constrained identifiers that never contain a quote or backslash. Free-text
# fields (detail, terminal_error) are deliberately NOT read through this:
# consumers branch on the typed fields, which is the entire point of retiring
# prose matching.
crew_state_json_token() {  # <json> <field>
  local json=$1 field=$2 frag
  frag=${json##*\""$field"\":\"}
  case "$frag" in
    "$json") printf ''; return 1 ;;
  esac
  printf '%s' "${frag%%\"*}"
}

# 0 if a verb CLOSES a keyed decision rather than declaring a state. These verbs
# are legitimate and sanctioned - bin/fm-brief.sh instructs every crew to write
# `resolved:` when a decision is answered - but they say "that decision is
# settled", not "here is what I am doing now". A reader must therefore not
# derive a current state from them, and must equally not mistake them for an
# UNRECOGNIZED verb: "the crew closed a decision and declared nothing since" is
# a known condition, while an unrecognized verb genuinely is not. This library
# owns the verb vocabulary, so the membership test lives here instead of being
# restated by each reader that needs it.
status_verb_is_decision_closing() {  # <verb>
  [ -n "${1:-}" ] || return 1
  case "$1" in
    "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}") return 0 ;;
    "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") return 0 ;;
  esac
  return 1
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
# A typed event carries the same key as its `key=` field.
#
# The three parsers below are pure reads of a single line; on a prose line the
# verb parser strips any key token before the colon so the leading word is
# recovered cleanly.
# All three accept BOTH forms, which is the whole migration mechanism:
# every consumer in bin/ already reads status lines through them, so teaching
# them the envelope taught the fleet at once, and a home part-way through the
# migration reads a mixed log correctly. A typed event answers from its fields; a
# prose line answers from its text, unchanged. A REFUSED typed event answers with
# the reserved invalid verb and an empty key/note rather than with prose salvaged
# out of a line that failed validation.
status_line_verb() {  # <status-line> -> leading verb word
  local rc=0
  fm_status_event_parse "${1-}" || rc=$?
  case "$rc" in
    0) printf '%s' "$FM_STATUS_EVENT_VERB"; return 0 ;;
    1) printf '%s' "$FM_STATUS_EVENT_INVALID_VERB"; return 0 ;;
  esac
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> the human note: a typed summary, or the
                      # text after a prose line's first colon, trimmed
  local rc=0
  fm_status_event_parse "${1-}" || rc=$?
  case "$rc" in
    0) printf '%s' "$FM_STATUS_EVENT_SUMMARY"; return 0 ;;
    1) printf '%s' "$FM_STATUS_EVENT_INVALID_REASON"; return 0 ;;
  esac
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix k rc=0
  fm_status_event_parse "${1-}" || rc=$?
  case "$rc" in
    0) printf '%s' "$FM_STATUS_EVENT_KEY"; return 0 ;;
    1) return 1 ;;
  esac
  prefix=${1%%:*}
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
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
# Fold ONE status line into an existing "<key>\t<verb>\t<note>\n"-per-line open
# set, applying the same needs-decision/blocked-opens, resolved/captain-held-closes
# rule status_open_decisions documents above. Pure text transform, no file I/O.
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

_fm_decision_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb>
  local open=$1 line=$2 resolve=$3 held=$4 verb key note stripped
  stripped=${line//[[:space:]]/}
  [ -n "$stripped" ] || { printf '%s' "$open"; return 0; }
  verb=$(status_line_verb "$line")
  key=$(_fm_decision_key "$line") || { printf '%s' "$open"; return 0; }
  _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" \
    || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      note=$(status_line_note "$line")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    "$resolve"|"$held")
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
status_open_decisions() {  # <status-file>
  local f=$1 line resolve held open=''
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
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
scan_open_decisions() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions "$f") || continue
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
# persisted running open-set, via the exact same _fm_decision_fold_line rule
# status_open_decisions uses - so the two strategies can never disagree on what
# is open. Cost is bounded by NEW appends since the last drain, not by the
# status file's total lifetime size.
#
# Correctness invariant (unchanged from the whole-file fold): an open decision
# is dropped ONLY by an explicit resolved/captain-held line for its exact key,
# never by cursor advancement, age, or being buried under later appends - the
# persisted open-set carries every still-open key forward across calls
# regardless of how much new unrelated log content has since been folded in.
#
# The cursor format is `version`, `offset`, `ident`, then the folded open set.
# FM_OPEN_DECISIONS_FOLD_VERSION must be bumped whenever
# _fm_decision_fold_line semantics change, so persisted state from an older
# interpretation is discarded and rebuilt from byte 0.
#
# Cursor invalidation is deliberately minimal, matching how status files are
# ACTUALLY used in this repo: every one is created once (`>`) and only ever
# appended to (`>>`) - never replaced, renamed, or rewritten in place. So the
# ways a cursor can go stale are a fold-version mismatch, a shrink (truncated),
# or the file at this path being a different file than before
# (replaced/rotated/recreated), which a changed device+inode makes an O(1) check
# via a single `stat` call - no content hashing, no re-reading the consumed
# prefix. Any signal falls back to a full re-fold of the whole current file from
# byte 0 - byte for byte what status_open_decisions itself would compute - and
# rewrites the cursor from that clean baseline. A same-inode, same-size,
# in-place byte edit is NOT detected; that is a deliberately accepted gap
# because no code path in this repo ever does that to a status file.
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
_fm_open_decisions_cursor_path() {  # <status-file>
  local f=$1 dir base
  dir=$(dirname "$f")
  base=$(basename "$f")
  printf '%s/.%s.open-decisions-cursor' "$dir" "${base%.status}"
}

FM_OPEN_DECISIONS_FOLD_VERSION=2

# Portable device:inode identity for the rotation/recreation check below.
_fm_open_decisions_file_ident() {  # <file> -> "dev:inode", empty on I/O failure
  local f=$1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null
  fi
}

status_open_decisions_incremental() {  # <status-file>
  local f=$1 cf offset ident open='' trusted_open='' cursor_data first rest offset_line ident_line
  local version='' size cur_ident resolve held chunk_file chunk_size line cursor_dirty=0
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cf=$(_fm_open_decisions_cursor_path "$f")
  offset=0
  ident=''
  if [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ]; then
    if cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null); then
      first=${cursor_data%%$'\n'*}
      case "$first" in
        version=*)
          version=${first#version=}
          [ "$version" = "$FM_OPEN_DECISIONS_FOLD_VERSION" ] || version=''
          rest=${cursor_data#*$'\n'}
          offset_line=${rest%%$'\n'*}
          case "$offset_line" in
            offset=*) offset=${offset_line#offset=} ;;
            *) offset=0; version='' ;;
          esac
          case "$offset" in
            ''|*[!0-9]*) offset=0; version='' ;;
            *)
              case "$rest" in
                *$'\n'*)
                  rest=${rest#*$'\n'}
                  ident_line=${rest%%$'\n'*}
                  case "$ident_line" in
                    ident=*)
                      ident=${ident_line#ident=}
                      case "$rest" in
                        *$'\n'*) open=${rest#*$'\n'} ;;
                      esac
                      if [ -n "$version" ] && [ -n "$ident" ]; then trusted_open=$open; fi
                      ;;
                    *) offset=0; version='' ;;
                  esac
                  ;;
                *) offset=0; version='' ;;
              esac
              ;;
          esac
          ;;
      esac
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

  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=0
    open=''
    trusted_open=''
    cursor_dirty=1
  fi

  if [ "$offset" -lt "$size" ]; then
    chunk_file="$cf.read.$$"
    tail -c "+$((offset + 1))" "$f" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    chunk_size=$(LC_ALL=C wc -c < "$chunk_file" 2>/dev/null) \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    chunk_size=${chunk_size//[[:space:]]/}
    case "$chunk_size" in
      ''|*[!0-9]*) rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0 ;;
    esac
    # Test-only observability seam (off by default, no production behavior
    # change): when set, records exactly how many bytes THIS call folded, so a
    # test can assert the incremental path stays bounded by new appends rather
    # than re-reading the whole file, without relying on timing or source text.
    [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
      && printf '%s\t%s\n' "$f" "$chunk_size" >> "$FM_OPEN_DECISIONS_READ_PROBE"
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
    while IFS= read -r line || [ -n "$line" ]; do
      open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
    done < "$chunk_file"
    rm -f "$chunk_file"
    offset=$size
    cursor_dirty=1
  fi
  if [ "$cursor_dirty" -eq 1 ]; then
    {
      printf 'version=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      # An `if` (not `[ -n "$open" ] && printf ...`) so the group's exit status
      # is always 0 even when open is empty (fully resolved) - a bare `&&`
      # there would make the whole group fail on that condition, silently
      # skipping the mv below and leaving the cursor stuck on the OLD offset.
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$cf.tmp.$$" && mv -f "$cf.tmp.$$" "$cf"
  fi
  printf '%s' "$open"
}

# Incremental sibling of scan_open_decisions: same fleet-wide directory walk and
# output shape ("<task>\t<key>\t<verb>\t<note>" per open decision), but folds
# each task's status log through status_open_decisions_incremental instead of
# the whole-file status_open_decisions, so a fleet-wide per-drain scan stays
# bounded by new appends rather than total lifetime log size across every task.
scan_open_decisions_incremental() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions_incremental "$f") || continue
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

# --- blocking_on: DERIVED, never declared ------------------------------------
#
# What a task is waiting on is the single most useful fact on this boundary and
# the single one a worker cannot be trusted to report. A worker knows what it
# just did; it does not know whether its own run is still advancing, whether the
# question it asked was already answered, or whether firstmate escalated it. A
# crew that wrote "blocked: waiting on the captain" and then resumed work leaves
# that sentence sitting in the log as a control fact that is no longer true.
#
# So `blocking_on` is DERIVED here, from three inputs the worker does not own:
# its declared VERB, its decision KEY folded against the whole durable stream,
# and the authoritative crew state from bin/fm-crew-state.sh (CFVC-05). A worker
# may not write the field at all - bin/fm-status-event-lib.sh refuses the whole
# event rather than stripping the value, so there is no path by which a crew's
# own words reach this answer.
#
# Declaring a verb is not the self-report this rule forbids. "I asked a question"
# is something the worker genuinely observed; "I am currently blocked on the
# captain" is a claim about the fleet around it. The verb is evidence, and the
# derivation is free to overrule it: proof of work outranks any declaration.
#
# The vocabulary answers "whose move is it":
#   nothing   - provably not waiting on anyone.
#   self      - the worker's own move: a gate it must answer, a run to re-drive.
#   firstmate - firstmate must act. Every crew escalation lands here first, even
#               one destined for the captain, because a crewmate never addresses
#               the captain directly - firstmate applies the authority contract
#               and escalates if it must.
#   captain   - the captain owes a ruling, proven by a verified captain-held
#               transfer rather than by a crew saying so.
#   external  - a declared wait on something outside the fleet.
#   unknown   - could not be observed. Never narrowed into `nothing`: an
#               unobserved answer is not an answer.
FM_BLOCKING_ON_VOCABULARY='nothing self firstmate captain external unknown'

# 0 if <value> is a member of that vocabulary.
blocking_on_is_known() {  # <value>
  [ -n "${1:-}" ] || return 1
  case " $FM_BLOCKING_ON_VOCABULARY " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# The crew verdicts that DECIDE blocking_on on their own, outranking the event.
# Prints the answer and returns 0 when one does; returns 1 when the verdict
# leaves the question to the event. Total over FM_CREW_STATE_VOCABULARY for the
# same reason crew_state_absorb_class is: 3 means this fleet declares a verdict
# this function was never taught, and the coverage gate in
# tests/fm-watch-triage.test.sh fails on it.
_fm_blocking_on_decisive() {  # <state> <source>
  case "${1:-}" in
    # Only run-step and pane are POSITIVE evidence of work in flight, the same
    # rule crew_state_absorb_class applies. A `working` recovered from the status
    # log is the crew's own claim, and this is exactly the function that must not
    # treat a claim as a verdict.
    working)
      case "${2:-}" in run-step|pane) printf 'nothing'; return 0 ;; esac
      return 1
      ;;
    done) printf 'nothing'; return 0 ;;
    # The three re-run verdicts. Each leaves work the CREW does next: a rejected
    # run to fix, a superseded run whose custody it recovers, a broken pipeline
    # to re-drive. None of them is owed by anyone above it.
    failed|aborted|interrupted) printf 'self'; return 0 ;;
    # A gate exists but the verdict alone does not say whose it is; the event
    # answers, and _fm_blocking_on_floor keeps `nothing` off the table.
    parked|blocked|paused) return 1 ;;
    # No usable read of the crew at all, so the event stands alone.
    idle|stale|unknown) return 1 ;;
  esac
  crew_state_is_known "${1:-}" && return 3
  return 2
}

# The floor a crew verdict puts under the answer: the verdict proves a gate
# exists, so `unknown` is no longer available even when the event declared
# nothing. Prints the floor and returns 0, or returns 1 when the verdict imposes
# none. Total over the vocabulary on the same terms as above.
_fm_blocking_on_floor() {  # <state>
  case "${1:-}" in
    parked) printf 'self'; return 0 ;;
    blocked) printf 'firstmate'; return 0 ;;
    paused) printf 'external'; return 0 ;;
    working|done|failed|aborted|interrupted|idle|stale|unknown) return 1 ;;
  esac
  crew_state_is_known "${1:-}" && return 3
  return 2
}

# Who the EVENT declares is owed, before the crew state is allowed to overrule
# it. Prints one of captain/firstmate/external, or returns 1 when the event
# declares no one.
#
# The durable fold outranks the last line, for the reason status_open_decisions
# exists: a later unrelated event never clears an open captain decision, so a
# crew that asked a question and then appended `working:` is still owed an
# answer. Reading the fold needs the task's log; without it, the line speaks for
# itself.
_fm_blocking_on_from_event() {  # <status-line> [task-id] [state-dir]
  local line=$1 id=${2:-} dir=${3:-} verb
  if [ -n "$id" ] && [ -n "$dir" ] && [ -n "$(status_open_decisions "$dir/$id.status")" ]; then
    printf 'firstmate'
    return 0
  fi
  verb=$(status_line_verb "$line")
  if [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]; then
    printf 'captain'
    return 0
  fi
  if [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]; then
    printf 'external'
    return 0
  fi
  case "$verb" in
    needs-decision|blocked) printf 'firstmate'; return 0 ;;
  esac
  return 1
}

# Derive what a task is waiting on. Prints exactly one member of
# FM_BLOCKING_ON_VOCABULARY.
#
# <crew-state> and <crew-source> are bin/fm-crew-state.sh's typed verdict, passed
# in rather than read here: that reader may make a bounded no-mistakes call, so
# the caller that already paid for it (bin/fm-fleet-snapshot.sh) does not pay
# twice, and the per-wake triage path is never tempted to pay at all. An empty
# state is an unread crew, which is could-not-observe and never `nothing`.
#
# <task-id> and <state-dir> are optional and enable the open-decision fold only.
#
# Precedence, highest first:
#   1. a refused typed event                      -> unknown
#   2. a decisive crew verdict                    -> nothing | self
#   3. what the event declares, folded over the
#      whole durable stream                       -> captain | firstmate | external
#   4. the floor a gate verdict puts under it     -> self | firstmate | external
#   5. otherwise                                  -> unknown
# Step 2 above step 3 is what makes the derivation, not the crew, the decider: a
# stale "blocked:" cannot survive proof that the run is advancing. Step 3 above
# step 4 is what keeps an escalation addressed to firstmate from being demoted to
# the worker's own gate.
status_event_blocking_on() {  # <status-line> <crew-state> <crew-source> [task-id] [state-dir]
  local line=${1-} state=${2-} source=${3-} id=${4-} dir=${5-} answer
  if fm_status_event_is_typed "$line" && [ -n "$(fm_status_event_invalid_reason "$line")" ]; then
    printf 'unknown'
    return 0
  fi
  if answer=$(_fm_blocking_on_decisive "$state" "$source") && [ -n "$answer" ]; then
    printf '%s' "$answer"
    return 0
  fi
  if answer=$(_fm_blocking_on_from_event "$line" "$id" "$dir") && [ -n "$answer" ]; then
    printf '%s' "$answer"
    return 0
  fi
  if answer=$(_fm_blocking_on_floor "$state") && [ -n "$answer" ]; then
    printf '%s' "$answer"
    return 0
  fi
  printf 'unknown'
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
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
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

# 0 if <reconciled-state> is a SETTLED terminal state for crew <id>: the crew's
# own work is over and the next move belongs above it, so an idle pane is the
# CORRECT condition rather than a wedge symptom. The state word comes from
# bin/fm-crew-state.sh, which reconciles the run-step and pane against the status
# log - so, unlike a read of the log's last line, a leftover terminal line under
# an ACTIVE run never reaches here (that crew reconciles as working and keeps its
# wedge timer).
#
#   done            - the run passed or its checks are green, or the log reports
#                     done and the pane is exactly idle. Nothing is left for the
#                     crew to do on its own.
#   parked, blocked - the next move belongs above the crew, but ONLY while a
#                     durable open decision proves it. status_open_decisions is
#                     the one owner of that fold. A crew idling at a pipeline gate
#                     it is supposed to answer ITSELF opens no decision, so it
#                     keeps aging and still escalates as a possible wedge.
#
# `failed` is deliberately NOT settled: a run the pipeline judged and rejected
# leaves the crew work to do, so an idle pane there is a genuine stall. Neither
# are `aborted` and `interrupted`, the two re-run verdicts - `aborted` is the
# mid-supersession state in which a crew is expected to recover custody and
# resume, and `interrupted` means the pipeline broke without judging the work.
# `stale` and `unknown` are never settled either: a record that aged out, a dead
# endpoint, or a torn-down worktree must keep aging.
#
# A missing or unreadable status file yields no open decision, so parked/blocked
# stay unsettled and keep escalating.
crew_state_is_settled() {  # <id> <reconciled-state> [state-dir]
  local id=$1 s=$2 dir=${3:-${STATE:-${FM_STATE_OVERRIDE:-}}}
  case "$s" in
    done) return 0 ;;
    parked|blocked)
      [ -n "$id" ] || return 1
      [ -n "$(status_open_decisions "$dir/$id.status")" ]
      ;;
    *) return 1 ;;
  esac
}

# --- process liveness: descendant CPU advancement ---------------------------
#
# Every absorb source below is SEMANTIC: the no-mistakes run step, the status
# log, the harness busy signal. All three correctly read "not working" the
# moment an agent backgrounds a long command and ends its turn - while the real
# work continues in a child process none of them can see. Measured 2026-08-03:
# one crew running the portable suite in the background produced seven
# consecutive false wedge escalations across 42 minutes, each demanding a deep
# inspection, and at least three other crews hit the same pattern while pipeline
# stages ran underneath them.
#
# This adds the missing PROCESS-level evidence ALONGSIDE those sources, never in
# place of them. Two rules keep it from becoming a blindfold:
#
#   1. Identity, never a bare pid. The kernel reissues pids, so a recorded pid
#      routinely resolves to an unrelated live process; `kill -0`, a `/proc/<pid>`
#      directory test and a bare `ps -p` all report that impostor as alive
#      (data/learnings.md records the measured evidence). Every stored sample is
#      bound to the fm_pid_identity of the agent it was taken from, and a sample
#      whose anchor identity no longer matches is discarded, never compared.
#   2. ADVANCEMENT, never existence. A descendant that merely EXISTS is no
#      evidence of work: a hung child would then mask a genuine wedge, trading a
#      false alarm for the far more dangerous silence. Only cumulative CPU that
#      GREW since the previous sample counts.
#
# The agent is resolved from kernel facts, never a vendor process name: the
# task's recorded worktree is the agent's working directory, and the agent is
# the LEADER of the foreground process group on that pane's terminal.
#
# Leader, not the whole group, and that choice is load-bearing. Whether a tool
# subprocess ends up in its parent's process group or its own is entirely a
# harness implementation detail - Claude Code detaches its Bash-tool children
# into a new session, a plain shell leaves a background job in the shell's own
# group and on the shell's terminal. Excluding the whole group would therefore
# make this signal silently measure nothing for any harness that spawns children
# the second way, which is far worse than the cost of the leader rule: where a
# harness does NOT get its own foreground group (a multi-process launcher such
# as pi-signed, or an agent started without `exec`), the second harness process
# is a descendant of the leader and its own CPU is counted. The threshold below
# and the caller's completed-turn bound are what keep that over-inclusion safe.
#
# The LEADER's own utime/stime is deliberately EXCLUDED. That is the agent
# itself working, which the semantic busy contract (bin/fm-busy-lib.sh) already
# owns, and counting it would let an idle agent's rendering jitter - or worse, a
# genuinely looping wedged agent - read as work. What is counted is everything
# below it: every live strict descendant's CPU, plus every already-reaped
# descendant's CPU through the leader's own cutime/cstime. That sum is monotonic
# across a child exiting (the child's total leaves the live set and lands in its
# parent's cutime), so one aggregate is enough and no per-child bookkeeping is
# needed - which is also what makes a long run of short-lived children, such as
# a test suite driving one script after another, register as advancing at all.
#
# A Linux-compatible /proc is required. Where it is absent this reports `none`,
# which is exactly today's no-evidence behaviour: the wake surfaces.

# Kernel ticks of descendant CPU that must accrue between two samples before a
# crew counts as working. A tick is 10ms at the standard Linux USER_HZ of 100,
# so the default is one full CPU-second per sample: far above what a harness
# helper being spawned and reaped costs incidentally, and far below any real
# build, test run, or pipeline stage. At the watcher's default 15s poll that is
# roughly 7% of one core sustained.
FM_CHILD_CPU_MIN_TICKS_DEFAULT=100
# A baseline older than this proves nothing about NOW, so it is refreshed and
# the probe reports no evidence for that poll rather than comparing against it.
FM_CHILD_CPU_MAX_SAMPLE_AGE_DEFAULT=120
# The baseline is replaced only once it is at least this old. Both the no-verb
# signal path and the stale path can probe within one watcher cycle; without
# this the second probe would reset the baseline to a near-zero measurement
# window and report live work as static.
FM_CHILD_CPU_SAMPLE_INTERVAL_DEFAULT=5

# fm_pid_identity lives in bin/fm-wake-lib.sh, which creates the state directory
# when sourced. This library is also sourced by strictly read-only readers
# (bin/fm-crew-state.sh), so it is loaded on first probe instead of at source
# time. Every consumer that actually probes - the watcher and the away-mode
# daemon - has already loaded it, so this normally sources nothing.
_fm_child_cpu_need_identity() {
  command -v fm_pid_identity >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_CLASSIFY_LIB_DIR/fm-wake-lib.sh" 2>/dev/null || return 1
  command -v fm_pid_identity >/dev/null 2>&1
}

# Print "<ticks>\t<agent-identity>" for the agent that owns <worktree>: the
# total CPU its descendants have consumed, live and already reaped, and the
# identity that total is bound to. Returns 1 when no agent can be resolved -
# no readable /proc, no live process whose working directory is that worktree,
# no controlling terminal, no foreground group, no live foreground group leader,
# or two different panes claiming the same worktree (refused rather than
# guessed).
_fm_child_cpu_measure() {  # <worktree>
  local wt=$1 proc d pid line rest cur c i
  local tty='' tpgid='' total=0 identity
  local -a ppid_of pgrp_of own_of reaped_of kids_of visited queue
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  proc=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -d "$proc" ] || return 1
  for d in "$proc"/[0-9]*; do
    pid=${d#"$proc"/}
    # stderr is redirected BEFORE stdin on purpose: redirections are applied
    # left to right, so this also swallows the shell's own "no such file"
    # complaint for a process that exited mid-scan, or for the literal glob left
    # behind when the process table is empty.
    read -r line 2>/dev/null < "$d/stat" || continue
    # The comm field is parenthesised and may itself contain ") ", so strip
    # greedily to the LAST one; every field after it is numeric. What remains
    # starts at proc stat field 3, so field N sits at position N-2: ppid 4->2,
    # pgrp 5->3, tty_nr 7->5, tpgid 8->6, utime 14->12, stime 15->13,
    # cutime 16->14, cstime 17->15.
    rest=${line##*') '}
    # shellcheck disable=SC2086  # deliberate split of the fixed-shape numeric stat tail
    set -- $rest
    [ "$#" -ge 15 ] || continue
    ppid_of[pid]=$2
    pgrp_of[pid]=$3
    own_of[pid]=$(( ${12} + ${13} ))
    reaped_of[pid]=$(( ${14} + ${15} ))
    # `-ef` compares the RESOLVED directory by device and inode, so it needs no
    # readlink fork and is immune to a symlinked or bind-mounted worktree path.
    [ "$d/cwd" -ef "$wt" ] 2>/dev/null || continue
    # tty_nr 0 means no controlling terminal and tpgid -1 means no foreground
    # group; neither can anchor an agent.
    [ "$5" != 0 ] && [ "$6" != -1 ] || continue
    if [ -z "$tty" ]; then
      tty=$5
      tpgid=$6
    elif [ "$tty" != "$5" ] || [ "$tpgid" != "$6" ]; then
      return 1
    fi
  done
  [ -n "$tpgid" ] || return 1
  # The foreground group's LEADER is the agent, and it must still be alive: a
  # group whose leader has gone describes an agent already replaced.
  [ -n "${pgrp_of[tpgid]+set}" ] && [ "${pgrp_of[tpgid]}" = "$tpgid" ] || return 1
  for pid in "${!ppid_of[@]}"; do
    kids_of[ppid_of[pid]]="${kids_of[ppid_of[pid]]:-} $pid"
  done
  # The leader's own cutime/cstime: the CPU of every descendant it has already
  # reaped. Its own utime/stime is excluded on purpose (see above).
  total=${reaped_of[tpgid]}
  visited[tpgid]=1
  queue=("$tpgid")
  i=0
  while [ "$i" -lt "${#queue[@]}" ]; do
    cur=${queue[i]}
    i=$(( i + 1 ))
    for c in ${kids_of[cur]:-}; do
      [ -z "${visited[c]+set}" ] || continue
      visited[c]=1
      total=$(( total + own_of[c] + reaped_of[c] ))
      queue+=("$c")
    done
  done
  identity=$(fm_pid_identity "$tpgid") || return 1
  printf '%s\t%s' "$total" "$identity"
}

# Print the process-liveness verdict for crew <id>:
#   advancing - its agent's descendants burned at least FM_CHILD_CPU_MIN_TICKS
#               of CPU since the previous sample, so work is happening NOW in a
#               child process even though the pane and every semantic source
#               look idle;
#   static    - an agent was resolved but its descendants did not advance (they
#               are hung, finished, or absent), or there is no usable baseline
#               to compare against yet;
#   none      - no agent could be resolved at all: no /proc, no worktree
#               recorded, no live agent on it, or an unreadable process table.
# NOT a pure read: it maintains the state/<id>.childcpu sample the next call
# measures against. Safe to call more than once per cycle - the baseline is
# replaced only once it is FM_CHILD_CPU_SAMPLE_INTERVAL old, so a second probe
# re-scores the SAME baseline instead of resetting the measurement window.
fm_child_cpu_state() {  # <state-dir> <id>
  local state=$1 id=$2 meta wt file now measured identity ticks verdict
  local prev_ts='' prev_ticks='' prev_identity='' age min interval max_age
  [ -n "$state" ] && [ -n "$id" ] || { printf 'none'; return; }
  meta="$state/$id.meta"
  [ -f "$meta" ] || { printf 'none'; return; }
  wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] || { printf 'none'; return; }
  _fm_child_cpu_need_identity || { printf 'none'; return; }
  measured=$(_fm_child_cpu_measure "$wt") || { printf 'none'; return; }
  ticks=${measured%%$'\t'*}
  identity=${measured#*$'\t'}
  file="$state/$id.childcpu"
  now=$(date +%s)
  min=${FM_CHILD_CPU_MIN_TICKS:-$FM_CHILD_CPU_MIN_TICKS_DEFAULT}
  interval=${FM_CHILD_CPU_SAMPLE_INTERVAL:-$FM_CHILD_CPU_SAMPLE_INTERVAL_DEFAULT}
  max_age=${FM_CHILD_CPU_MAX_SAMPLE_AGE:-$FM_CHILD_CPU_MAX_SAMPLE_AGE_DEFAULT}
  # Identity last, so a stray separator inside it can never shift the numbers.
  if [ -f "$file" ]; then
    IFS=$'\t' read -r prev_ts prev_ticks prev_identity < "$file" 2>/dev/null || true
  fi
  # A missing, truncated, or corrupt baseline is no baseline: measure afresh.
  case "$prev_ts" in ''|*[!0-9]*) prev_ts='' ;; esac
  case "$prev_ticks" in ''|*[!0-9]*) prev_ts='' ;; esac
  verdict=static
  if [ -n "$prev_ts" ] && [ "$prev_identity" = "$identity" ]; then
    age=$(( now - prev_ts ))
    if [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ] \
      && [ $(( ticks - prev_ticks )) -ge "$min" ]; then
      verdict=advancing
    fi
  fi
  if [ -z "$prev_ts" ] || [ "$prev_identity" != "$identity" ] \
    || [ $(( now - prev_ts )) -ge "$interval" ]; then
    printf '%s\t%s\t%s\n' "$now" "$ticks" "$identity" > "$file" 2>/dev/null || true
  fi
  printf '%s' "$verdict"
}

# 0 if crew <id> shows advancing descendant CPU. The positive half of the
# process-liveness signal; see fm_child_cpu_state for the exact verdict.
crew_child_cpu_advancing() {  # <id> [state-dir]
  local id=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}}
  [ "$(fm_child_cpu_state "$state" "$id")" = advancing ]
}

# The ONE read of bin/fm-crew-state.sh's authoritative verdict that both
# classifications below share. Prints "<class> <reconciled-state>", because the
# two callers need different halves of the same read and that read may make a
# bounded no-mistakes call - splitting it into two reads would double that cost
# for every definite verdict.
# The read is TYPED. This used to recover `state` and `source` by slicing the
# prose line apart on its separators, which is what CFVC-05 retires: the reader
# now emits the same derivation as fields, so no consumer reconstructs structure
# from a sentence written for a human. FM_CREW_STATE_BIN lets tests stub it.
_fm_crew_read_class() {  # <id>
  local id=$1 json state src class
  [ -n "$id" ] || { printf 'definite unreadable'; return; }
  json=$("$FM_CREW_STATE_BIN" --json "$id" 2>/dev/null) || true
  [ -n "$json" ] || { printf 'inconclusive unreadable'; return; }
  state=$(crew_state_json_token "$json" state) || { printf 'inconclusive unreadable'; return; }
  # A present-but-empty state field is the field carrying no answer, which is the
  # same condition as an absent one. Both are `unreadable` rather than a verdict,
  # so process liveness still gets its turn instead of the read silently
  # narrowing to a decided-looking class on malformed output.
  [ -n "$state" ] || { printf 'inconclusive unreadable'; return; }
  src=$(crew_state_json_token "$json" source) || src=''
  # crew_state_absorb_class owns the verdict-to-class mapping, beside the
  # vocabulary it must cover. This function's job is the read, and its
  # three-valued code is for the coverage gate, not for a caller here.
  class=$(crew_state_absorb_class "$state" "$src") || true
  case "$class" in
    working|paused) printf '%s %s' "$class" "$state"; return ;;
  esac
  # `none` from the mapper means "the semantic read alone does not absorb". The
  # two extra sources below still need to know WHY, because they answer for
  # different verdicts: an UNPROVEN verdict may yet be answered by process
  # liveness, while a DECIDED one may only be answered by the settled test. An
  # untaught verdict lands in `definite`, which cannot absorb unless the settled
  # test independently says so.
  case "$state" in
    working|unknown) printf 'inconclusive %s' "$state" ;;
    *) printf 'definite %s' "$state" ;;
  esac
}

# Classify bin/fm-crew-state.sh's authoritative typed verdict without consulting
# process liveness. Prints working, paused, definite, or inconclusive.
# FM_CREW_STATE_BIN lets tests stub the semantic verdict.
crew_semantic_class() {  # <id>
  local read
  read=$(_fm_crew_read_class "$1")
  printf '%s' "${read%% *}"
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced.
# Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci), a busy
#             pane, or advancing descendant CPU; the crew is legitimately
#             mid-work on a static-looking pane (e.g. waiting on CI, or
#             supervising a command it backgrounded before ending its turn);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   settled - the crew's reconciled state is terminal and the idle pane is the
#             expected finished/waiting condition (crew_state_is_settled above);
#   none    - none of those, so the wake must surface (a failed or cancelled run,
#             a torn-down or unknown crew whose descendants are hung, dead, or
#             absent, a run parked at a gate the crew owns, or an unreadable
#             verdict).
# The two extra sources are consulted on exactly the semantic verdicts they
# answer for and never both: process liveness only after an INCONCLUSIVE read,
# the settled test only after a DEFINITE one. So the semantic sources keep their
# precedence in every direction - a crew that appended paused: but then STARTED a
# run reports working, never paused, a crew whose log still shows a
# pre-validation done: reports working, not settled, and a definite verdict is
# never overridden by whatever its process tree happens to still be doing.
# NOT a pure read: the shared current-state read may make a bounded no-mistakes
# call and the probe maintains its own sample, so callers run it only on no-verb
# signal and first-sighting stale paths, never every wake.
crew_absorb_class() {  # <id> [state-dir]
  local id=$1 state_dir=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} read semantic state
  [ -n "$id" ] || { printf 'none'; return; }
  read=$(_fm_crew_read_class "$id")
  semantic=${read%% *}
  state=${read#* }
  case "$semantic" in
    working|paused) printf '%s' "$semantic"; return ;;
    definite)
      crew_state_is_settled "$id" "$state" ${state_dir:+"$state_dir"} \
        && { printf 'settled'; return; }
      printf 'none'
      return
      ;;
  esac
  if [ "$(fm_child_cpu_state "$state_dir" "$id")" = advancing ]; then
    printf 'working'
    return
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
