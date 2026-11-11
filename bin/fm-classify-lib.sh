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
# Status-span classification captures one file endpoint and reports every
# actionable event through that endpoint before the endpoint may be committed.
# An absent status file is a successful empty span, while an existing status
# object that cannot be read or identified is a classification failure with no
# committable endpoint.
# A presentation marker independently stores the last reported file signature
# and the last successfully classified position.
# Successful classification advances both facts through the captured endpoint;
# after a failure is reported, only the reported signature advances, so the same
# observed state alarms once while every unclassified byte remains for recovery.
# The reported signature includes path type, mode, symlink target, and observable
# failure kind, so a readability change is a new state that triggers another read.
# A missing, malformed, identity-mismatched, or past-end classified position reads
# from byte 0, preferring a bounded duplicate over a lost event.
#
# There are three documented exceptions. The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/fm-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor and folded open-set as a side effect, so a per-drain fleet-wide scan
# stays bounded by new appends instead of re-reading each task's whole lifetime
# log every time. crew_worktree_written_since reads the task's meta file and walks
# a bounded slice of its worktree instead of a status file, so callers run it only
# at the moment they would otherwise escalate.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# fm_run_timed, the shared hard bound the worktree write probe below puts around
# its one filesystem walk. bin/fm-timeout-lib.sh owns bounded execution for this
# repo, so nothing here re-derives the coreutils/BSD/perl selection. That library
# declares `set -u` for its own hygiene, which a sourced sibling must not impose on
# THIS library's consumers - several of them deliberately run without it - so the
# caller's setting is restored around the source.
case $- in *u*) _fm_classify_nounset=on ;; *) _fm_classify_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_CLASSIFY_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_classify_nounset" = on ] || set +u
unset _fm_classify_nounset

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

# Bounded re-surface cadence for a declared pause or a verified captain hold.
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
# fm-captain-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# --- bounded status-log reads -------------------------------------------------
#
# A long-lived lane's status log is append-only and can reach many megabytes.
# Every per-task read in the supervision path must therefore be bounded by the
# bytes it actually needs, never by the log's total lifetime size, or one big
# log stalls a drain, a snapshot, a watcher poll, or a session start. The
# cursor-backed folds further down this file already bound their own reads to
# appended bytes; last_status_line below bounds the latest-line read the same
# way. Neither ever rotates or truncates a log, because the fold cursors are
# byte offsets into it.
FM_STATUS_TAIL_BYTES=65536

# Return the last non-blank line of a status file (empty if missing/blank).
# Reads at most the final FM_STATUS_TAIL_BYTES (64 KiB): the live line of an
# append-only log is at its tail, so the bounded read is exact for real logs.
# A pathological file whose tail window holds no non-blank line falls back to
# the whole-file scan, so the verdict is never wrong - only slower on that edge.
last_status_line() {
  local f=$1 line
  [ -e "$f" ] || return 0
  if line=$(_fm_status_tail_last_nonblank "$f" "$FM_STATUS_TAIL_BYTES"); then
    printf '%s\n' "$line"
    return 0
  fi
  # The tail window held no non-blank line (a tail of more than <limit> blank
  # bytes, or a final line longer than the window). The whole-file scan is the
  # exact verdict for that edge and is never reached on a normal status log.
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# Bounded tail reader behind last_status_line. Prints the last non-blank line
# fully inside the final <limit> bytes and exits 0, or exits 1 when that window
# holds no complete non-blank line. One process, one bounded read, no whole-file
# scan. FM_STATUS_TAIL_READ_PROBE records the byte count actually read, the
# test-only seam a bounded-cost test asserts on.
_fm_status_tail_last_nonblank() {  # <file> <limit-bytes>
  local f=$1 limit=$2
  perl -e '
    my ($path, $limit) = @ARGV;
    open my $fh, "<", $path or exit 1;
    binmode $fh;
    my $size = -s $path;
    my $start = ($size > $limit) ? $size - $limit : 0;
    # A tail window that does not begin on a line boundary starts mid-line; that
    # first partial line is dropped below, never mistaken for a complete one.
    my $partial = 0;
    if ($start > 0) {
      seek($fh, $start - 1, 0) or exit 1;
      my $prev = "";
      read($fh, $prev, 1);
      $partial = 1 if $prev ne "\n";
    }
    seek($fh, $start, 0) or exit 1;
    my $data = do { local $/; <$fh> };
    if ($partial) {
      my $nl = index($data, "\n");
      $data = ($nl >= 0) ? substr($data, $nl + 1) : "";
    }
    my $probe = $ENV{FM_STATUS_TAIL_READ_PROBE};
    if (defined $probe && length $probe) {
      if (open my $pf, ">>", $probe) { print $pf "$path\t", ($size - $start), "\n"; close $pf; }
    }
    my @lines = split /\n/, $data, -1;
    for (my $i = $#lines; $i >= 0; $i--) {
      next if $lines[$i] =~ /^[[:space:]]*$/;
      print $lines[$i];
      exit 0;
    }
    exit 1;
  ' "$f" "$limit"
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
# The no-fork predicate core: it takes the already-parsed verb (or parses one)
# and returns the verdict without a command substitution, so the span classifier's
# per-line pass can classify a long cold log without a subshell per line.
status_is_captain_relevant_verb() {  # <status-line> [<verb>]
  local line=$1 verb=${2-}
  [ -n "$line" ] || return 1
  [ -n "$verb" ] || { status_line_verb_core "$line"; verb=$_FM_STATUS_VERB; }
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
    # The default vocabulary is a fixed set of literal substrings, so a
    # case-insensitive `case` answers it with builtins only. A per-line grep
    # fork here is what made a cold classification of a multi-thousand-line log
    # take minutes; shopt -q is a builtin, so the prior nocasematch state is
    # restored without a subshell.
    local _fm_nocase_was_on=0
    shopt -q nocasematch && _fm_nocase_was_on=1
    shopt -s nocasematch
    case "$line" in
      *done:*|*needs-decision:*|*blocked:*|*failed:*|*"PR ready"*|*"checks green"*|*"ready in branch"*|*merged*)
        [ "$_fm_nocase_was_on" = 1 ] || shopt -u nocasematch
        return 0
        ;;
    esac
    [ "$_fm_nocase_was_on" = 1 ] || shopt -u nocasematch
    return 1
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

status_is_captain_relevant() {
  status_is_captain_relevant_verb "$1"
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

# 0 if a status line's leading verb is the verified captain-held transfer verb.
# The same pure verb read as status_is_paused, and the discriminator a supervisor
# needs once a declared wait has already been recognized: the two declarations get
# the same bounded cadence, but they block on DIFFERENT humans, so a recheck that
# names an external dependency for a hold points the captain away from the fact
# that they are the one who can clear it.
status_is_captain_held() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave a crew's endpoint idle, so both
# supervisors give them one cadence: the away-mode daemon defers the wedge and
# ages a pause marker instead, and the watcher applies its bounded pause cadence
# once pause_state_class has admitted the wait (fm-watch.sh owns which liveness
# evidence each kind of crew must supply for that).
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1
  status_is_paused "$line" || status_is_captain_held "$line"
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
# format): an OPTIONAL "[key=<slug>]" token names the decision. Its documented
# position sits between the verb and the colon, and a complete token at the
# head of the note is accepted as an EQUIVALENT position, because that
# misplaced-colon shape is common real worker output whose stated key must
# never silently collapse into the shared "default" bucket (issue #2109):
#   needs-decision [key=api-shape]: <summary>
#   needs-decision: [key=api-shape] <summary>
#   resolved       [key=api-shape]: <how it was decided>
# Both positions state the same key and yield the same note (a consumed
# note-head token is key metadata, stripped from the note); when both positions
# carry a token, the documented before-colon one wins and the note-head token
# stays note text. A token deeper inside the note is prose, never a stated key,
# so a summary merely MENTIONING "[key=x]" cannot open or close that decision.
# A line with no token in either position uses the key "default", preserving
# the historical one-open-decision-per-task behavior (a bare "resolved:" closes
# "default"). A stated key whose slug fails the charset below is rejected (the
# folds skip the line), never rewritten to "default".
# The parsers are pure reads of a single line. Status metadata may contain any
# number of "[name=value]" tags before the colon, in any order, so verb parsing
# ends at the first tag rather than special-casing "[key=...]".
#
# Correlation tokens. That bracket rule already covers every BRACKETED tag,
# including the "[corr=<16 hex>]" form bin/fm-secondmate-report.sh writes. It
# does not cover the UNBRACKETED token that bin/fm-pending-reply-lib.sh writes
# (fm_pending_reply_corr_token), which a secondmate answering a marked request
# echoes on its parent status line ahead of the key tag (bin/fm-brief.sh), so a
# real transition routinely arrives as
#   needs-decision corr=<16 hex> [key=texte-du-mur]: <summary>
#   resolved       corr=<16 hex> [key=texte-du-mur]: <how it was decided>
# and a recovery turn can leave two such tokens on one line. All of those must
# read as the bare verb, in BOTH directions: a verb parse that keeps the token
# glued on matches no arm of _fm_fold_line_state, so the opener never opens
# and the closer never closes, and a captain decision goes silently missing.
# Recognition starts only AFTER the retained leading verb: a token-first line
# keeps that token, so its following word cannot impersonate a transition and
# close a decision the captain is owed.
#
# The token grammar is OWNED by bin/fm-pending-reply-lib.sh
# (fm_pending_reply_corr_token, FM_PENDING_REPLY_CORR_RE). That library sources
# this one, so it cannot be sourced back here; the pattern below is a deliberate
# second statement of the SHAPE alone, and tests/fm-classify-corr-token.test.sh
# pins the two together through the real writers so they cannot drift.
#
# Recognition is deliberately narrow: EXACTLY the token that writer emits, whole
# word, and nothing else. An arbitrary "<name>=<value>" token is NOT skipped.
# Skipping unknown tokens would be the permissive road - it would let any
# free-text word carrying an equals sign ("resolved x=1 [key=k]: ...") reduce to
# a bare verb and impersonate a transition, which is the takeover the strict
# parse and _fm_decision_key_transition_allowed exist to prevent. Recognising
# only what a firstmate library actually writes costs one more line here each
# time a real new token shape is introduced, and that is the intended trade: a
# new shape is a deliberate, reviewed edit rather than a silent widening. A line
# whose token is malformed, wrong-length, or merely mentioned in prose keeps its
# extra words and therefore stays a non-transition, exactly as before.
#
# The 16 hex classes are written out literally rather than built from a
# variable, the same way bin/fm-secondmate-report.sh validates the id it is
# handed: a variable holding a glob is only re-read as a pattern under some
# shells' expansion rules, and a safety parse must not turn on that.
#
# 0 if <word> is, in whole, an unbracketed correlation token this fleet's own
# tooling writes. The bracketed form never reaches here: the tag rule above has
# already ended the verb parse at its opening bracket.
_fm_classify_is_corr_token() {  # <word>
  case "$1" in
    corr=[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
      return 0
      ;;
  esac
  return 1
}

# A status line may be written with a leading ISO-8601 ("2026-09-11T02:09Z")
# or clock ("02:09Z") timestamp ahead of the state word. That token carries its
# own colons, so the parsers below would otherwise split on the timestamp's colon
# instead of the state/note one, and a keyed decision written that way would
# never be seen as open - no wake fires and --resolve-key refuses it. Strip
# exactly one such token before the state/colon split, so a timestamp-first line
# parses exactly like the documented state-first shape. Only the line head is
# touched: a timestamp inside the note body stays note text.
#
# The token must be the line's entire first whitespace-delimited word, so it ends
# the line or is followed by whitespace. A head that is not a complete timestamp,
# or a timestamp glued to anything else ("2026-09-11T02:09Zebra",
# "2026-09-11T02:09Z-ish"), leaves the line byte-for-byte unchanged.
#
# The result is returned in FM_STATUS_LINE_HEAD rather than on stdout - the
# fm_cap_line_var/FM_LINE_CAP_LINE shape - because every parsing layer below
# strips independently, and a command substitution per layer per line would
# multiply the per-line fold cost this file budgets so carefully. The digit guard
# keeps an ordinary state-first line off the regex entirely.
_fm_status_strip_leading_timestamp() {  # <status-line> -> FM_STATUS_LINE_HEAD
  local line=$1 word
  FM_STATUS_LINE_HEAD=$line
  case "$line" in
    [0-9]*) ;;
    *) return 0 ;;
  esac
  word=${line%%[[:space:]]*}
  [[ $word =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?|[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z)$ ]] || return 0
  line=${line#"$word"}
  FM_STATUS_LINE_HEAD=${line#"${line%%[![:space:]]*}"}
}

# The no-fork core behind status_line_verb: it assigns the leading verb to
# _FM_STATUS_VERB instead of printing it, so a per-line fold loop can parse a
# status line with zero command substitutions. The public status_line_verb below
# is a thin print of this same single implementation, so the parsing rule still
# has exactly one owner.
_FM_STATUS_VERB=
status_line_verb_core() {  # <status-line> -> _FM_STATUS_VERB
  local v=$1 out='' word
  _fm_status_strip_leading_timestamp "$v"
  v=$FM_STATUS_LINE_HEAD
  v=${v%%:*}
  v=${v%%\[*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  # Fast path, and the whole no-regression guarantee: a prefix that cannot
  # contain a correlation token is assigned byte-for-byte as before, so every
  # line without one keeps its exact historical verb, spacing included.
  case "$v" in
    *corr=*) ;;
    *) _FM_STATUS_VERB=$v; return 0 ;;
  esac
  # Retain the first word, then drop only recognised tokens from the remaining
  # whole words. Anything unrecognised stays, so prose still matches no verb.
  word=${v%%[[:space:]]*}
  out=$word
  v=${v#"$word"}
  v=${v#"${v%%[![:space:]]*}"}
  while [ -n "$v" ]; do
    word=${v%%[[:space:]]*}
    v=${v#"$word"}
    v=${v#"${v%%[![:space:]]*}"}
    _fm_classify_is_corr_token "$word" && continue
    out="$out $word"
  done
  _FM_STATUS_VERB=$out
}

status_line_verb() {  # <status-line> -> leading verb word
  status_line_verb_core "$1"
  printf '%s' "$_FM_STATUS_VERB"
}
# 0 when a complete "[key=...]" token sits in the documented position before
# the line's first colon (or anywhere on a line that has no colon at all).
_fm_key_before_colon() {  # <status-line>
  local line=$1
  _fm_status_strip_leading_timestamp "$line"
  line=$FM_STATUS_LINE_HEAD
  case "${line%%:*}" in
    *\[key=*\]*) return 0 ;;
    *) return 1 ;;
  esac
}
# Raw slug of a complete "[key=<slug>]" token at the head of the note (the
# first thing after the line's first colon, ignoring whitespace). Fails when
# the line has no colon or no complete token there; slug charset validity is
# the caller's check via _fm_decision_slug_ok, exactly as for the before-colon
# position.
# No-fork core for the note-head key token; it assigns the slug to
# _FM_DECISION_KEY_HEAD instead of printing it.
_FM_DECISION_KEY_HEAD=
_fm_key_at_note_head_core() {  # <status-line> -> _FM_DECISION_KEY_HEAD
  local line=$1 rest
  _FM_DECISION_KEY_HEAD=
  _fm_status_strip_leading_timestamp "$line"
  line=$FM_STATUS_LINE_HEAD
  case "$line" in
    *:*) rest=${line#*:} ;;
    *) return 1 ;;
  esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \[key=*\]*) rest=${rest#\[key=}; _FM_DECISION_KEY_HEAD=${rest%%\]*}; return 0 ;;
    *) return 1 ;;
  esac
}
# 0 when a stated key slug is well-formed: nonempty, A-Za-z0-9._- only.
_fm_decision_slug_ok() {  # <slug>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
# No-fork core for the note text; the public status_line_note below prints the
# same value, so the note rule keeps exactly one owner.
_FM_STATUS_NOTE=
status_line_note_core() {  # <status-line> -> _FM_STATUS_NOTE
  local line=$1 n k
  _fm_status_strip_leading_timestamp "$line"
  line=$FM_STATUS_LINE_HEAD
  case "$line" in
    *:*) n=${line#*:}; n=${n#"${n%%[![:space:]]*}"} ;;
    *) _FM_STATUS_NOTE=$line; return 0 ;;
  esac
  # A note-head token that states this line's key (no before-colon token, valid
  # slug) is key metadata, not note text: strip it so both stated-key positions
  # yield the same note.
  if ! _fm_key_before_colon "$line" && _fm_key_at_note_head_core "$line" \
    && _fm_decision_slug_ok "$_FM_DECISION_KEY_HEAD"; then
    k=$_FM_DECISION_KEY_HEAD
    n=${n#"[key=$k]"}
    n=${n#"${n%%[![:space:]]*}"}
  fi
  _FM_STATUS_NOTE=$n
}

status_line_note() {  # <status-line> -> text after the first colon, trimmed
  status_line_note_core "$1"
  printf '%s' "$_FM_STATUS_NOTE"
}
_FM_DECISION_KEY=
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  _fm_decision_key_core "$1" || return 1
  printf '%s' "$_FM_DECISION_KEY"
}
_fm_decision_key_core() {  # <status-line> -> _FM_DECISION_KEY
  local line=$1 k
  _FM_DECISION_KEY=
  _fm_status_strip_leading_timestamp "$line"
  line=$FM_STATUS_LINE_HEAD
  if _fm_key_before_colon "$line"; then
    k=${line%%:*}
    k=${k#*\[key=}
    k=${k%%\]*}
  else
    _fm_key_at_note_head_core "$line" || { _FM_DECISION_KEY=default; return 0; }
    k=$_FM_DECISION_KEY_HEAD
  fi
  _fm_decision_slug_ok "$k" || return 1
  _FM_DECISION_KEY=$k
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_FM_DECISION_DROP=
_fm_decision_drop_core() {  # <open-set> <key> -> _FM_DECISION_DROP (no trailing newline)
  local set=$1 key=$2 line out='' sep=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) continue ;;
    esac
    out="${out}${sep}${line}"
    sep=$'\n'
  done <<EOF
$set
EOF
  _FM_DECISION_DROP=$out
}
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

_fm_is_pending_reply_escalation() {  # <key> <note>
  case "$1" in pending-reply-*) ;; *) return 1 ;; esac
  case "$2" in
    pending-reply-missed:*|pending-reply-delivery-unknown:*|pending-reply-recovery-delivery-failed:*|pending-reply-recovery-delivery-unknown:*) return 0 ;;
    *) return 1 ;;
  esac
}

# The no-fork fold engine: the ONE place the per-line open/resolved rule is
# written. It updates the globals _FM_FOLD_OPEN, _FM_FOLD_OP, and _FM_FOLD_KEY in
# place instead of printing, so a fold loop pays no command substitution per line.
# _FM_FOLD_OPEN deliberately carries NO trailing newline, matching what the old
# printing form produced through a `$(...)`.
_FM_FOLD_OPEN=
_FM_FOLD_OP=none
_FM_FOLD_KEY=
_fm_fold_line_state() {  # <open-set> <status-line> <resolve-verb> <held-verb>
  local open=$1 line=$2 resolve=$3 held=$4 verb key note
  _FM_FOLD_OP=none
  _FM_FOLD_KEY=
  # Blank-line guard. A `case` glob answers "does this line hold any non-space
  # character" in one pattern match; the equivalent ${line//[[:space:]]/} costs
  # tens of milliseconds per line under bash 3.2's global bracket-class
  # substitution, which is the whole per-line cost of both folds on a status log
  # of ordinary width. Same verdict, bounded cost.
  case "$line" in
    *[![:space:]]*) ;;
    *) _FM_FOLD_OPEN=$open; return 0 ;;
  esac
  status_line_verb_core "$line"
  verb=$_FM_STATUS_VERB
  _fm_decision_key_core "$line" || { _FM_FOLD_OPEN=$open; return 0; }
  key=$_FM_DECISION_KEY
  status_line_note_core "$line"
  note=$_FM_STATUS_NOTE
  _fm_decision_key_transition_allowed "$key" "$note" || { _FM_FOLD_OPEN=$open; return 0; }
  _FM_FOLD_KEY=$key
  case "$verb" in
    needs-decision|blocked)
      if _fm_open_set_has "$open" "$key"; then
        _fm_decision_drop_core "$open" "$key"
        open=$_FM_DECISION_DROP
      fi
      if [ -n "$open" ]; then
        open="${open}"$'\n'"${key}"$'\t'"${verb}"$'\t'"${note}"
      else
        open="${key}"$'\t'"${verb}"$'\t'"${note}"
      fi
      _FM_FOLD_OP=open
      ;;
    "$resolve"|"$held")
      if _fm_open_set_has "$open" "$key"; then
        _fm_decision_drop_core "$open" "$key"
        open=$_FM_DECISION_DROP
      fi
      _FM_FOLD_OP=close
      ;;
  esac
  _FM_FOLD_OPEN=$open
  return 0
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
    _fm_fold_line_state "$open" "$line" "$resolve" "$held"
    open=$_FM_FOLD_OPEN
  done < "$f"
  printf '%s' "$open"
}

# 0 when <key> has a record in a folded "<key>\t<verb>\t<note>" open set.
_fm_open_set_has() {  # <open-set> <key>
  case "$1" in
    "$2"$'\t'*|*$'\n'"$2"$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The verb stored for <key> in a folded open set (empty when it has no record).
_fm_open_set_verb() {  # <open-set> <key>
  local line
  while IFS= read -r line; do
    case "$line" in
      "$2"$'\t'*) line=${line#*$'\t'}; printf '%s' "${line%%$'\t'*}"; return 0 ;;
    esac
  done <<EOF
$1
EOF
  return 0
}

# The verb that last moved <key> in a status stream, which is what tells a
# consumer HOW the status side currently reads that key. Prints the opening verb
# (needs-decision or blocked) while the key is still open, the closing verb
# (resolved, or the captain-held durable-transfer verb) once it is closed, and
# nothing at all when no line in the stream ever stated a transition for it.
#
# The distinction between the two closing verbs is the whole point: a
# `captain-held` close is the VERIFIED handoff to a durable captain-held task
# (fm-captain-hold.sh complete writes it only after verifying that task), so the
# structured row staying open afterwards is correct. A `resolved` close claims
# the question is settled outright, so a structured row still open behind it is a
# contradiction between the two records - see fm-captain-hold.sh's `diverged`.
#
# Semantics are not re-derived here: every line goes through the same
# _fm_fold_line_state rule the two folds use, and the reported verb is read
# off the transitions that rule produces. Only lines whose parsed key equals the
# requested one can move that key, so a caller-supplied key other than "default"
# lets the scan pre-filter the stream to lines carrying its token and stay cheap
# on a long log.
status_key_closing_verb() {  # <status-file> <key>
  local f=$1 want=$2 line resolve held open='' was verb='' stream
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  [ -n "$want" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  if [ "$want" = default ]; then
    stream=$(cat "$f") || return 0
  else
    stream=$(grep -F "[key=$want]" "$f") || stream=''
  fi
  [ -n "$stream" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    was=0
    _fm_open_set_has "$open" "$want" && was=1
    _fm_fold_line_state "$open" "$line" "$resolve" "$held"
    open=$_FM_FOLD_OPEN
    if [ "$was" = 1 ] && ! _fm_open_set_has "$open" "$want"; then
      status_line_verb_core "$line"
      verb=$_FM_STATUS_VERB
    fi
  done <<EOF
$stream
EOF
  if _fm_open_set_has "$open" "$want"; then
    _fm_open_set_verb "$open" "$want"
    return 0
  fi
  printf '%s' "$verb"
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
# persisted running open-set, via the exact same _fm_fold_line_state rule
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
# _fm_fold_line_state semantics change, so persisted state from an older
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
  _fm_open_decisions_cursor_path_var "$1"
  printf '%s' "$_FM_OD_CURSOR_PATH"
}

# Fork-free core of _fm_open_decisions_cursor_path: assigns the path to
# _FM_OD_CURSOR_PATH with the same dirname/basename semantics, so per-file
# loops over the whole fleet pay no subshell for it.
_FM_OD_CURSOR_PATH=
_fm_open_decisions_cursor_path_var() {  # <status-file> -> _FM_OD_CURSOR_PATH
  local f=$1 dir base
  case "$f" in
    */*) dir=${f%/*}; [ -n "$dir" ] || dir=/ ;;
    *) dir=. ;;
  esac
  base=${f##*/}
  _FM_OD_CURSOR_PATH="$dir/.${base%.status}.open-decisions-cursor"
}

# Fork-free whole-file read into a named variable with command-substitution
# semantics (trailing newlines dropped). Fails when the file cannot be opened.
_fm_status_read_text_var() {  # <file> <output-variable>
  local _fm_rt_data=
  [ -r "$1" ] || return 1
  { IFS= read -r -d '' _fm_rt_data || true; } < "$1" 2>/dev/null || return 1
  while :; do
    case "$_fm_rt_data" in
      *$'\n') _fm_rt_data=${_fm_rt_data%$'\n'} ;;
      *) break ;;
    esac
  done
  printf -v "$2" '%s' "$_fm_rt_data"
}

# 4: verb parsing ends at the first "[name=value]" tag rather than only at a
# "[key=...]" one, so lines carrying another bracketed tag first became opens
# and closes.
# 5: status_line_verb now also reads through an UNBRACKETED correlation token,
# so lines that previously folded as ordinary status become opens and closes.
# Version 4 was already spent on the bracketed-tag parser change above, and a
# cursor persisted under that reading predates this one, so it must still be
# discarded and rebuilt from byte 0 under the new reading.
# 6: the parsers now strip one leading timestamp token before the state/colon
# split, so a timestamp-first line that folded as ordinary status becomes an open
# or a close. A cursor persisted under the older reading has already consumed
# such lines as ordinary status and would keep their decisions invisible
# forever, so it must be discarded and rebuilt from byte 0.
FM_OPEN_DECISIONS_FOLD_VERSION=6

# The host OS name, resolved once and EXPORTED so the many $(...) subshells that
# call the stat helpers below inherit it instead of forking `uname` per call.
# That per-call fork was a measured per-task cost on a large fleet; the value is
# constant for the life of a process tree, so one resolution is enough.
_FM_CLASSIFY_UNAME_S=${_FM_CLASSIFY_UNAME_S:-$(uname -s 2>/dev/null)}
export _FM_CLASSIFY_UNAME_S

# Portable device:inode identity for the rotation/recreation check below.
# One `stat` call answers identity, birth epoch, and birth string together, so
# the three forks the separate reads cost are paid once per call.
_fm_open_decisions_file_ident() {  # <file> -> strongest available identity
  local f=$1 line
  if [ -n "${FM_STATUS_IDENTITY_READER:-}" ]; then
    "$FM_STATUS_IDENTITY_READER" "$f"
    return
  fi
  if _fm_status_stat_cache_row "$f"; then
    printf '%s' "$_FM_SC_IDENT"
    return 0
  fi
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    line=$(LC_ALL=C stat -f '%d:%i|%B|%FB' "$f" 2>/dev/null) \
      || line=$(LC_ALL=C stat -f '%d:%i' "$f" 2>/dev/null) || return 1
  else
    line=$(LC_ALL=C stat -c '%d:%i|%W|%w' "$f" 2>/dev/null) \
      || line=$(LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null) || return 1
  fi
  _fm_status_ident_parse "$line" || return 1
  printf '%s' "$_FM_STATUS_IDENT"
}

# The one parse of a "<dev:ino>|<birth-epoch>|<birth-string>" stat answer
# (or a bare "<dev:ino>" from the fallback format) into the identity token.
_FM_STATUS_IDENT=
_fm_status_ident_parse() {  # <stat-line> -> _FM_STATUS_IDENT
  local line=$1 ident epoch birth
  _FM_STATUS_IDENT=
  ident=${line%%|*}
  case "$line" in
    *'|'*)
      line=${line#*|}
      epoch=${line%%|*}
      birth=${line#*|}
      ;;
    *) epoch=; birth= ;;
  esac
  case "$epoch" in ''|*[!0-9]*|0) birth='' ;; esac
  case "$ident$birth" in *$'\t'*|*$'\n'*|'') return 1 ;; esac
  if [ -n "$birth" ]; then _FM_STATUS_IDENT="strong:$ident:$birth"; else _FM_STATUS_IDENT="weak:$ident"; fi
}

# --- per-pass stat cache ------------------------------------------------------
#
# A fleet-wide presentation pass (bin/fm-wake-drain.sh) asks the size, mtime,
# and identity of every status log in every one of its sections; one `stat`
# fork per question was ~5,000 forks per drain, minutes of kernel time on a
# loaded host. fm_status_stat_cache_load answers all three for every
# <state>/*.status in ONE stat call; while it is loaded, the three readers
# below answer those paths from it without forking. It is a snapshot: the
# caller loads it at a defined point, reloads it wherever it must re-prove a
# file is unchanged (the drain reloads before committing its cursors), and
# clears it. Paths the cache does not hold, and every test reader seam, keep
# their ordinary per-call read. No caller that never loads it is affected.
# The cache is a bash 4.2+ associative array (a hash lookup per question; a
# plain-string search was slower than the forks it replaced). On an older bash
# loading is a no-op and every reader keeps its per-call stat.
# Result slot of the fork-free *_r cores below; copy it before the next call.
_FM_R=
FM_STATUS_STAT_CACHE_LOADED=0
_FM_STATUS_STAT_CACHE_SUPPORTED=0
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] \
  || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
  declare -gA _FM_STATUS_STAT_CACHE_MAP=() 2>/dev/null \
    && declare -gA _FM_STATUS_SPAN_MEMO=() 2>/dev/null \
    && declare -gA _FM_STATUS_LATEST_MEMO=() 2>/dev/null \
    && declare -gA _FM_PM_IDX=() _FM_PM_CNT=() _FM_PM_ID=() _FM_PM_LEG=() _FM_PM_BS=() 2>/dev/null \
    && _FM_STATUS_STAT_CACHE_SUPPORTED=1
fi
_FM_SC_SIZE=
_FM_SC_MTIME=
_FM_SC_IDENT=
fm_status_stat_cache_load() {  # <state>
  local state=$1 out path size mtime raw
  # Library-local arrays carry the _fm_ prefix on purpose: ShellCheck's
  # --external-sources analysis leaks a sourced file's `local -a` name into the
  # sourcing file's function scopes, so a plain `files`/`keys` array here makes
  # every consumer's scalar of that name trip SC2178/SC2128. Keep the prefix.
  local -a _fm_files=()
  fm_status_stat_cache_clear
  [ "$_FM_STATUS_STAT_CACHE_SUPPORTED" = 1 ] || return 0
  # A test reader seam owns those answers; never shadow it with real stats.
  [ -z "${FM_STATUS_IDENTITY_READER:-}" ] && [ -z "${FM_STATUS_SIZE_READER:-}" ] || return 0
  for path in "$state"/*.status; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    case "$path" in *$'\t'*|*$'\n'*) continue ;; esac
    _fm_files+=("$path")
  done
  [ "${#_fm_files[@]}" -gt 0 ] || return 0
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    out=$(LC_ALL=C stat -f '%N%t%z%t%m%t%d:%i|%B|%FB' -- "${_fm_files[@]}" 2>/dev/null) || true
  else
    out=$(LC_ALL=C stat --printf '%n\t%s\t%Y\t%d:%i|%W|%w\n' -- "${_fm_files[@]}" 2>/dev/null) || true
  fi
  while IFS=$'\t' read -r path size mtime raw; do
    [ -n "$path" ] && [ -n "$raw" ] || continue
    case "$size:$mtime" in *[!0-9:]*|:*|*:) continue ;; esac
    _fm_status_ident_parse "$raw" || continue
    _FM_STATUS_STAT_CACHE_MAP[$path]="$size"$'\t'"$mtime"$'\t'"$_FM_STATUS_IDENT"
  done <<EOF
$out
EOF
  FM_STATUS_STAT_CACHE_LOADED=1
}

fm_status_stat_cache_clear() {
  FM_STATUS_STAT_CACHE_LOADED=0
  [ "$_FM_STATUS_STAT_CACHE_SUPPORTED" = 1 ] || return 0
  _FM_STATUS_STAT_CACHE_MAP=()
  _FM_STATUS_SPAN_MEMO=()
  _FM_STATUS_LATEST_MEMO=()
  _FM_PM_PATH=
  _FM_PM_RAW=
  _FM_PM_IDX=() _FM_PM_CNT=() _FM_PM_ID=() _FM_PM_LEG=() _FM_PM_BS=()
}

# Per-pass parse of the presentation manifest. Both manifest readers below
# walked every row for every task (quadratic in the fleet); while a stat pass
# is loaded they read the manifest bytes (no fork) and reparse only when those
# bytes differ from the last parse, recording for each task its first row and
# row count and the index of the first malformed row, which is exactly what
# each reader's own row walk decides from.
_FM_PM_PATH=
_FM_PM_RAW=
_FM_PM_BAD=
_fm_presentation_manifest_parse() {  # <manifest> <data>
  local row_task ident legacy backstop extra idx=0
  [ "$_FM_PM_PATH" = "$1" ] && [ "$_FM_PM_RAW" = "$2" ] && return 0
  _FM_PM_IDX=() _FM_PM_CNT=() _FM_PM_ID=() _FM_PM_LEG=() _FM_PM_BS=()
  _FM_PM_BAD=
  while IFS=$'\t' read -r row_task ident legacy backstop extra; do
    [ -n "$row_task" ] || continue
    idx=$((idx + 1))
    if [ -z "$_FM_PM_BAD" ]; then
      case "$legacy:$backstop" in *[!0-9:]*) _FM_PM_BAD=$idx ;; esac
      { [ -z "$extra" ] && [ -n "$legacy" ] && [ -n "$ident" ]; } || _FM_PM_BAD=$idx
    fi
    if [ -n "${_FM_PM_CNT[$row_task]+set}" ]; then
      _FM_PM_CNT[$row_task]=$((_FM_PM_CNT[$row_task] + 1))
    else
      _FM_PM_CNT[$row_task]=1
      _FM_PM_IDX[$row_task]=$idx
      _FM_PM_ID[$row_task]=$ident
      _FM_PM_LEG[$row_task]=$legacy
      _FM_PM_BS[$row_task]=$backstop
    fi
  done <<EOF
$2
EOF
  _FM_PM_PATH=$1
  _FM_PM_RAW=$2
}

_fm_status_stat_cache_row() {  # <path> -> _FM_SC_SIZE _FM_SC_MTIME _FM_SC_IDENT
  local row
  [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ] || return 1
  row=${_FM_STATUS_STAT_CACHE_MAP[$1]-}
  [ -n "$row" ] || return 1
  _FM_SC_SIZE=${row%%$'\t'*}
  row=${row#*$'\t'}
  _FM_SC_MTIME=${row%%$'\t'*}
  _FM_SC_IDENT=${row#*$'\t'}
}

_fm_status_file_size() {  # <status-file>
  local f=$1
  if [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
    "$FM_STATUS_SIZE_READER" "$f"
    return
  fi
  if _fm_status_stat_cache_row "$f"; then
    printf '%s' "$_FM_SC_SIZE"
    return 0
  fi
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C stat -f '%z' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%s' "$f" 2>/dev/null
  fi
}

_fm_status_file_mtime() {  # <status-file>
  local f=$1
  if _fm_status_stat_cache_row "$f"; then
    printf '%s' "$_FM_SC_MTIME"
    return 0
  fi
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C stat -f '%m' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%Y' "$f" 2>/dev/null
  fi
}

# Fork-free variants of the three readers for per-file loops: they assign the
# answer to the named variable instead of printing it, so a cache hit costs no
# subshell at all. A miss runs the ordinary reader.
_fm_status_size_into() {  # <file> <output-variable>
  local _fm_si_v
  if [ -z "${FM_STATUS_SIZE_READER:-}" ] && _fm_status_stat_cache_row "$1"; then
    printf -v "$2" '%s' "$_FM_SC_SIZE"
    return 0
  fi
  _fm_si_v=$(_fm_status_file_size "$1") || return 1
  printf -v "$2" '%s' "$_fm_si_v"
}

_fm_status_ident_into() {  # <file> <output-variable>
  local _fm_ii_v
  if [ -z "${FM_STATUS_IDENTITY_READER:-}" ] && _fm_status_stat_cache_row "$1"; then
    printf -v "$2" '%s' "$_FM_SC_IDENT"
    return 0
  fi
  _fm_ii_v=$(_fm_open_decisions_file_ident "$1") || return 1
  printf -v "$2" '%s' "$_fm_ii_v"
}

_fm_status_mtime_into() {  # <file> <output-variable>
  local _fm_mi_v
  if _fm_status_stat_cache_row "$1"; then
    printf -v "$2" '%s' "$_FM_SC_MTIME"
    return 0
  fi
  _fm_mi_v=$(_fm_status_file_mtime "$1") || return 1
  printf -v "$2" '%s' "$_fm_mi_v"
}

# Private scratch path for a one-shot span read, alongside the status file the
# same way the cursor above is, and PID-scoped so concurrent readers of one log
# (the watcher and the away-mode daemon both classify the same stream) never
# truncate each other's chunk.
_fm_status_span_scratch() {  # <status-file>
  printf '%s.span.%s' "$(_fm_open_decisions_cursor_path "$1")" "$$"
}

_fm_status_read_span() {  # <status-file> <start-offset> <byte-length>
  local f=$1 start=$2 length=$3
  # Test-only observability seam (off by default, no production behavior
  # change): records the byte length of every span read, so a test can assert
  # that a warm span classification reads only the appended span rather than
  # re-reading the whole log.
  [ -n "${FM_STATUS_SPAN_READ_PROBE:-}" ] \
    && printf '%s\t%s\n' "$f" "$length" >> "$FM_STATUS_SPAN_READ_PROBE"
  if [ -n "${FM_STATUS_SPAN_READER:-}" ]; then
    "$FM_STATUS_SPAN_READER" "$f" "$start" "$length"
    return
  fi
  perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $length) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    sysseek($file, $start, 0) == $start or exit 1;
    while ($length > 0) {
      my $want = $length > 65536 ? 65536 : $length;
      my $read = sysread($file, my $chunk, $want);
      defined($read) && $read > 0 or exit 1;
      print $chunk or exit 1;
      $length -= $read;
    }
  ' "$f" "$start" "$length"
}

# Bounded span read: like _fm_status_read_span, but prints only the bytes
# through the last newline inside the requested window, so a caller that bounds
# a fold (the watcher's heartbeat backstop) never hands the fold a partial
# trailing line and can advance its marker to the exact byte it inspected.
# Exits non-zero when the window holds no newline, which leaves the caller's
# recorded position unmoved rather than parked mid-line. Honors the same
# FM_STATUS_SPAN_READER/PROBE seam as _fm_status_read_span.
_fm_status_read_complete_span() {  # <status-file> <start-offset> <byte-length>
  _fm_status_read_span "$1" "$2" "$3" 2>/dev/null \
    | perl -e 'local $/; my $d = <>; my $i = rindex(defined($d) ? $d : "", "\n"); exit 1 if $i < 0; print substr($d, 0, $i + 1)'
}

# Prints the open set; _status_open_decisions_incremental_r below is the one
# implementation and leaves it in _FM_R for callers that loop over the fleet.
status_open_decisions_incremental() {  # <status-file> [<captured-end-offset>]
  _status_open_decisions_incremental_r "$@" || return
  printf '%s' "$_FM_R"
}

_status_open_decisions_incremental_r() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} cf offset ident open='' trusted_open='' cursor_data first rest offset_line ident_line
  local version='' size actual_size cur_ident resolve held chunk_file chunk_size line cursor_dirty=0
  local target_cursor
  _FM_R=
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  _fm_open_decisions_cursor_path_var "$f"
  cf=$_FM_OD_CURSOR_PATH
  offset=0
  ident=''
  if [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ]; then
    _fm_status_read_text_var "$cf" cursor_data || cursor_data=''
  fi
  if [ -n "${cursor_data:-}" ]; then
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

  # A stat/size-read failure is a genuine I/O error, not "the file is empty" -
  # report the already-trusted persisted set unchanged rather than risking a
  # silent invalidation that would wipe it.
  _fm_status_ident_into "$f" cur_ident || { _FM_R=$trusted_open; return 0; }
  [ -n "$cur_ident" ] || { _FM_R=$trusted_open; return 0; }
  _fm_status_size_into "$f" actual_size \
    || { _FM_R=$trusted_open; return 0; }
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) _FM_R=$trusted_open; return 0 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in
      ''|*[!0-9]*) _FM_R=$trusted_open; return 0 ;;
    esac
    [ "$captured_end" -le "$actual_size" ] || { _FM_R=$trusted_open; return 0; }
    size=$captured_end
  else
    size=$actual_size
  fi

  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    # No usable cursor (a brand-new task, or one invalidated by a fold-version
    # bump, an identity change, or a replaced file), or a cursor that has already
    # folded past the caller's captured end: its persisted open set may carry a
    # transition appended after the capture, so a caller bounded at that capture
    # must refold the captured prefix instead. This fold must start at byte
    # 0 so NO decision is ever dropped; the no-fork engine makes that full read
    # cheap, and _fm_status_read_span reads it in bounded 64 KiB syscalls. The
    # watcher, whose poll drives the span classifier, touches its liveness beacon
    # between status files and between poll stages, so a cold fold cannot starve
    # supervision.
    offset=0
    open=''
    trusted_open=''
    cursor_dirty=1
  fi

  if [ "$offset" -lt "$size" ]; then
    chunk_file="${FM_OPEN_DECISIONS_SCRATCH_DIR:-${cf%/*}}/${cf##*/}.read.$$"
    _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; _FM_R=$trusted_open; return 0; }
    chunk_size=$(LC_ALL=C wc -c < "$chunk_file" 2>/dev/null) \
      || { rm -f "$chunk_file"; _FM_R=$trusted_open; return 0; }
    chunk_size=${chunk_size//[[:space:]]/}
    case "$chunk_size" in
      ''|*[!0-9]*) rm -f "$chunk_file"; _FM_R=$trusted_open; return 0 ;;
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
      _fm_fold_line_state "$open" "$line" "$resolve" "$held"
      open=$_FM_FOLD_OPEN
    done < "$chunk_file"
    rm -f "$chunk_file"
    offset=$size
    cursor_dirty=1
  fi
  # A caller that must not mutate shared supervision state (the fleet snapshot,
  # which folds each task's open set for its own read but never owns the drain's
  # cursor) sets FM_OPEN_DECISIONS_READONLY=1: it still gets the identical folded
  # open set from the persisted cursor plus the appended bytes, but leaves the
  # cursor untouched. That keeps the cursor's ownership unambiguous - it is a
  # presentation offset in status_presentation_cursor_offset's legacy fallback,
  # so only the drain may advance it. Such a caller also points
  # FM_OPEN_DECISIONS_SCRATCH_DIR at a directory it owns, so the scratch chunk
  # above never lands in the drain's state dir, where a caller killed at its
  # deadline (the snapshot runs under a timed bound) would leave it behind.
  if [ "$cursor_dirty" -eq 1 ] && [ "${FM_OPEN_DECISIONS_READONLY:-0}" != 1 ]; then
    target_cursor="$cf.tmp.$$"
    {
      printf 'version=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$target_cursor" || return 1
    mv -f "$target_cursor" "$cf" || return 1
  fi
  _FM_R=$open
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

status_presentation_snapshot() {  # <state>
  local state=$1 f task size ident
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    task=${f##*/}; task="${task%.status}"
    _fm_status_size_into "$f" size || return 1
    size=${size//[[:space:]]/}
    _fm_status_ident_into "$f" ident || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$ident" ] || return 1
    printf '%s\t%s\t%s\n' "$task" "$size" "$ident" || return 1
  done
}

# Read the latest non-blank event through one captured presentation endpoint.
# This is the bounded latest-event owner for fleet-wide backstops: at most the
# final 64 KiB is inspected, and a file that changes during the read is deferred
# to the next snapshot instead of combining a line from one state with the mtime
# from another. The status log is append-only and ordinary event lines are far
# below this bound. A pathological latest line that crosses the fixed bound is
# intentionally unclassifiable and omitted: bounded memory and never presenting
# a possibly routine line as captain-facing take precedence on that edge.
FM_STATUS_SNAPSHOT_EVENT_LINE=
FM_STATUS_SNAPSHOT_EVENT_MTIME=
FM_STATUS_SNAPSHOT_EVENT_ENDPOINT=
# shellcheck disable=SC2034 # Output globals are consumed by sourcing drain scripts.
status_snapshot_latest_event() {  # <status-file> <captured-endpoint> <captured-identity>
  local f=$1 endpoint=$2 expected_ident=$3 limit=65536 start length scratch record line event_endpoint
  local expected_devino expected_ino memo
  local before_mtime after_mtime before_size after_size before_ident after_ident skip_first=0
  FM_STATUS_SNAPSHOT_EVENT_LINE=
  FM_STATUS_SNAPSHOT_EVENT_MTIME=
  FM_STATUS_SNAPSHOT_EVENT_ENDPOINT=
  case "$endpoint" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$expected_ident" ] || return 1

  _fm_status_mtime_into "$f" before_mtime || return 1
  _fm_status_size_into "$f" before_size || return 1
  before_size=${before_size//[[:space:]]/}
  _fm_status_ident_into "$f" before_ident || return 1
  case "$before_mtime:$before_size" in *[!0-9:]*) return 1 ;; esac
  [ "$before_size" -eq "$endpoint" ] && [ "$before_ident" = "$expected_ident" ] || return 1

  if [ "$endpoint" -gt "$limit" ]; then
    start=$((endpoint - limit))
    skip_first=1
  else
    start=0
  fi
  length=$((endpoint - start))
  memo=
  if [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ]; then
    memo=${_FM_STATUS_LATEST_MEMO["$f"$'\t'"$endpoint"$'\t'"$expected_ident"]-}
  fi
  if [ "$memo" = '!' ]; then
    return 1
  elif [ -n "$memo" ]; then
    record=$memo
  elif [ -z "${FM_STATUS_SPAN_READER:-}" ] && [ -z "${FM_STATUS_SPAN_READ_PROBE:-}" ]; then
    # One process reads and scans the window straight from the file, and
    # proves through the open handle that it is the captured inode and still
    # reaches the captured endpoint - the guarantee the after-read stat below
    # cannot give while a per-pass stat cache is answering it.
    # Identity tokens are strong:<dev>:<ino>:<birth> or weak:<dev>:<ino>, and
    # a Linux birth string itself contains colons, so take the two fields
    # after the kind rather than trimming from the end.
    expected_devino=${expected_ident#*:}
    expected_ino=${expected_devino#*:}
    expected_devino="${expected_devino%%:*}:${expected_ino%%:*}"
    # A test identity seam supplies synthetic tokens with no inode to compare.
    [ -z "${FM_STATUS_IDENTITY_READER:-}" ] || expected_devino=
    record=$(LC_ALL=C perl -MFcntl=:DEFAULT -e '
      my ($path, $start, $length, $skip_first, $devino, $endpoint) = @ARGV;
      sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
      my @st = stat($file) or exit 1;
      exit 1 if length $devino && "$st[0]:$st[1]" ne $devino;
      exit 1 if $st[7] < $endpoint;
      sysseek($file, $start, 0) == $start or exit 1;
      my $data = "";
      while (length($data) < $length) {
        my $want = $length - length($data);
        $want = 65536 if $want > 65536;
        my $read = sysread($file, my $chunk, $want);
        defined($read) && $read > 0 or exit 1;
        $data .= $chunk;
      }
      my $pos = 0;
      if ($skip_first) {
        my $nl = index($data, "\n");
        exit 1 if $nl < 0;
        $pos = $nl + 1;
      }
      my ($latest, $end);
      while ($pos < length($data)) {
        my $nl = index($data, "\n", $pos);
        my $next = $nl < 0 ? length($data) : $nl + 1;
        my $line = substr($data, $pos, $next - $pos);
        if ($line =~ /[^\s]/) {
          $line =~ s/[\r\n]+\z//;
          ($latest, $end) = ($line, $start + $next);
        }
        $pos = $next;
      }
      exit 1 unless defined $end;
      print "$end\t$latest";
    ' "$f" "$start" "$length" "$skip_first" "$expected_devino" "$endpoint") || return 1
  else
    scratch="$(_fm_status_span_scratch "$f").latest"
    _fm_status_read_span "$f" "$start" "$length" > "$scratch" 2>/dev/null \
      || { rm -f "$scratch"; return 1; }
    if record=$(LC_ALL=C perl -e '
      my ($path, $start, $skip_first) = @ARGV;
      open my $file, "<", $path or exit 1;
      binmode $file;
      scalar(<$file>) if $skip_first;
      my ($latest, $end);
      while (defined(my $line = <$file>)) {
        next unless $line =~ /[^\s]/;
        $line =~ s/[\r\n]+\z//;
        ($latest, $end) = ($line, $start + tell($file));
      }
      exit 1 unless defined $end;
      print "$end\t$latest";
    ' "$scratch" "$start" "$skip_first"); then :; else rm -f "$scratch"; return 1; fi
    rm -f "$scratch"
  fi
  event_endpoint=${record%%$'\t'*}
  line=${record#*$'\t'}
  case "$event_endpoint" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$line" ] || return 1

  _fm_status_mtime_into "$f" after_mtime || return 1
  _fm_status_size_into "$f" after_size || return 1
  after_size=${after_size//[[:space:]]/}
  _fm_status_ident_into "$f" after_ident || return 1
  case "$after_mtime:$after_size" in *[!0-9:]*) return 1 ;; esac
  [ "$after_mtime" = "$before_mtime" ] \
    && [ "$after_size" -eq "$endpoint" ] \
    && [ "$after_ident" = "$expected_ident" ] \
    || return 1

  FM_STATUS_SNAPSHOT_EVENT_LINE=$line
  FM_STATUS_SNAPSHOT_EVENT_MTIME=$before_mtime
  FM_STATUS_SNAPSHOT_EVENT_ENDPOINT=$event_endpoint
}

# Batched form of the window read in status_snapshot_latest_event: one process
# answers every <status-file> <captured-endpoint> <captured-identity> row of a
# snapshot whose backstop receipt is behind its endpoint, under the same inode
# and endpoint proof, and records each answer in a per-pass memo that
# status_snapshot_latest_event consults before reading on its own. A no-op
# without a loaded stat pass or under a span test seam.
status_snapshot_latest_event_prefetch() {  # <state> <snapshot>
  local state=$1 snapshot=$2 task endpoint ident f start skip devino ino out rec key i=0 limit=65536
  local -a args=() _fm_keys=()
  [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ] || return 0
  [ -z "${FM_STATUS_SPAN_READER:-}" ] && [ -z "${FM_STATUS_SPAN_READ_PROBE:-}" ] || return 0
  while IFS=$'\t' read -r task endpoint ident; do
    [ -n "$task" ] || continue
    case "$endpoint" in ''|*[!0-9]*|0) continue ;; esac
    f="$state/$task.status"
    _status_outcome_backstop_cursor_offset_r "$f" || continue
    [ "$_FM_R" -lt "$endpoint" ] || continue
    if [ "$endpoint" -gt "$limit" ]; then start=$((endpoint - limit)); skip=1; else start=0; skip=0; fi
    devino=${ident#*:}
    ino=${devino#*:}
    devino="${devino%%:*}:${ino%%:*}"
    [ -z "${FM_STATUS_IDENTITY_READER:-}" ] || devino=
    args+=("$f" "$start" "$((endpoint - start))" "$skip" "$devino" "$endpoint")
    _fm_keys+=("$f"$'\t'"$endpoint"$'\t'"$ident")
  done <<EOF
$snapshot
EOF
  [ "${#_fm_keys[@]}" -gt 0 ] || return 0
  out=$(LC_ALL=C perl -MFcntl=:DEFAULT -e '
    sub latest {
      my ($path, $start, $length, $skip_first, $devino, $endpoint) = @_;
      sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or return;
      my @st = stat($file) or return;
      return if length $devino && "$st[0]:$st[1]" ne $devino;
      return if $st[7] < $endpoint;
      sysseek($file, $start, 0) == $start or return;
      my $data = "";
      while (length($data) < $length) {
        my $want = $length - length($data);
        $want = 65536 if $want > 65536;
        my $read = sysread($file, my $chunk, $want);
        defined($read) && $read > 0 or return;
        $data .= $chunk;
      }
      my $pos = 0;
      if ($skip_first) {
        my $nl = index($data, "\n");
        return if $nl < 0;
        $pos = $nl + 1;
      }
      my ($latest, $end);
      while ($pos < length($data)) {
        my $nl = index($data, "\n", $pos);
        my $next = $nl < 0 ? length($data) : $nl + 1;
        my $line = substr($data, $pos, $next - $pos);
        if ($line =~ /[^\s]/) {
          $line =~ s/[\r\n]+\z//;
          ($latest, $end) = ($line, $start + $next);
        }
        $pos = $next;
      }
      return unless defined $end;
      return "$end\t$latest";
    }
    while (@ARGV >= 6) {
      my $r = latest(splice(@ARGV, 0, 6));
      print defined $r ? "ok\t$r\n" : "fail\n";
    }
  ' "${args[@]}" 2>/dev/null) || return 0
  while IFS= read -r rec; do
    [ "$i" -lt "${#_fm_keys[@]}" ] || break
    key=${_fm_keys[$i]}
    i=$((i + 1))
    case "$rec" in
      ok$'\t'*) _FM_STATUS_LATEST_MEMO[$key]=${rec#ok$'\t'} ;;
      *) _FM_STATUS_LATEST_MEMO[$key]=! ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

status_presentation_cursor_offset() {  # <status-file>
  _status_presentation_cursor_offset_r "$1" || return
  printf '%s' "$_FM_R"
}

# Fork-free core of status_presentation_cursor_offset (result in _FM_R).
_status_presentation_cursor_offset_r() {  # <status-file>
  local f=$1 state task manifest data row_task offset ident backstop extra cur_ident size legacy
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
    _fm_status_read_text_var "$manifest" data || return 1
    offset=
    if [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ]; then
      _fm_presentation_manifest_parse "$manifest" "$data"
      [ -z "$_FM_PM_BAD" ] || return 1
      if [ -n "${_FM_PM_CNT[$task]+set}" ]; then
        [ "${_FM_PM_CNT[$task]}" -eq 1 ] || return 1
        offset=${_FM_PM_LEG[$task]}
        cur_ident=${_FM_PM_ID[$task]}
      fi
      data=
    fi
    while IFS=$'\t' read -r row_task ident legacy backstop extra; do
      [ -n "$row_task" ] || continue
      [ -z "$extra" ] || return 1
      case "$legacy:$backstop" in *[!0-9:]*) return 1 ;; esac
      [ -n "$legacy" ] && [ -n "$ident" ] || return 1
      if [ "$row_task" = "$task" ]; then
        [ -z "$offset" ] || return 1
        offset=$legacy
        cur_ident=$ident
      fi
    done <<EOF
$data
EOF
    if [ -z "$offset" ]; then
      _FM_R=0
      return 0
    fi
    ident=$cur_ident
  else
    _fm_open_decisions_cursor_path_var "$f"
    legacy=$_FM_OD_CURSOR_PATH
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      _FM_R=$(status_open_decisions_cursor_offset "$f") || return 1
      return 0
    fi
    offset=0
    _fm_status_ident_into "$f" ident || return 1
  fi
  _fm_status_ident_into "$f" cur_ident || return 1
  _fm_status_size_into "$f" size || return 1
  size=${size//[[:space:]]/}
  case "$size:$offset" in *[!0-9:]*) return 1 ;; esac
  if [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then offset=0; fi
  _FM_R=$offset
}

status_outcome_backstop_cursor_offset() {  # <status-file>
  _status_outcome_backstop_cursor_offset_r "$1" || return
  printf '%s' "$_FM_R"
}

# Fork-free core of status_outcome_backstop_cursor_offset (result in _FM_R).
_status_outcome_backstop_cursor_offset_r() {  # <status-file>
  local f=$1 state task manifest data row_task ident presented row_backstop backstop extra current size
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  [ -e "$manifest" ] || { _FM_R=0; return 0; }
  [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
  _fm_status_read_text_var "$manifest" data || return 1
  backstop=0
  if [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ]; then
    _fm_presentation_manifest_parse "$manifest" "$data"
    if [ -n "${_FM_PM_IDX[$task]+set}" ]; then
      [ -z "$_FM_PM_BAD" ] || [ "$_FM_PM_BAD" -gt "${_FM_PM_IDX[$task]}" ] || return 1
      ident=${_FM_PM_ID[$task]}
      row_backstop=${_FM_PM_BS[$task]}
      _fm_status_ident_into "$f" current || return 1
      _fm_status_size_into "$f" size || return 1
      size=${size//[[:space:]]/}
      case "$size" in ''|*[!0-9]*) return 1 ;; esac
      [ "$ident" = "$current" ] || { _FM_R=0; return 0; }
      backstop=${row_backstop:-0}
      [ "$backstop" -le "$size" ] || backstop=0
      _FM_R=$backstop
      return 0
    fi
    [ -z "$_FM_PM_BAD" ] || return 1
    _FM_R=0
    return 0
  fi
  while IFS=$'\t' read -r row_task ident presented row_backstop extra; do
    [ -n "$row_task" ] || continue
    [ -z "$extra" ] || return 1
    case "$presented:$row_backstop" in *[!0-9:]*) return 1 ;; esac
    [ -n "$presented" ] && [ -n "$ident" ] || return 1
    if [ "$row_task" = "$task" ]; then
      _fm_status_ident_into "$f" current || return 1
      _fm_status_size_into "$f" size || return 1
      size=${size//[[:space:]]/}
      case "$size" in ''|*[!0-9]*) return 1 ;; esac
      [ "$ident" = "$current" ] || { _FM_R=0; return 0; }
      backstop=${row_backstop:-0}
      [ "$backstop" -le "$size" ] || backstop=0
      _FM_R=$backstop
      return 0
    fi
  done <<EOF
$data
EOF
  _FM_R=0
}

status_signal_seen_marker_path() {  # <state> <task-id>
  printf '%s/.seen-%s' "$1" "$(printf '%s.status' "$2" | tr '.' '_')"
}

status_heartbeat_seen_marker_path() {  # <state> <task-id>
  printf '%s/.hb-surfaced-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

status_daemon_seen_marker_path() {  # <state> <task-id>
  printf '%s/.subsuper-seen-status-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

_status_presentation_signature_valid() {
  local value=$1 size ident encoded
  [ "$value" = unverifiable ] && return 0
  case "$value" in
    r1:*)
      encoded=${value#r1:}
      case "$encoded" in ''|*[!0-9a-f]*) return 1 ;; esac
      return 0
      ;;
  esac
  case "$value" in *@*) size=${value%%@*}; ident=${value#*@} ;; *) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$ident" in ''|*$'\t'*|*$'\n'*) return 1 ;; esac
}

STATUS_PRESENTATION_REPORTED=
STATUS_PRESENTATION_CLASSIFIED=
status_presentation_marker_parse() {
  local raw=$1 rest reported classified
  STATUS_PRESENTATION_REPORTED=
  STATUS_PRESENTATION_CLASSIFIED=
  case "$raw" in
    v2$'\t'*)
      rest=${raw#v2$'\t'}
      case "$rest" in *$'\t'*) reported=${rest%%$'\t'*}; classified=${rest#*$'\t'} ;; *) return 1 ;; esac
      case "$classified" in *$'\t'*) return 1 ;; esac
      _status_presentation_signature_valid "$reported" || return 1
      if [ "$classified" != - ]; then
        _status_presentation_signature_valid "$classified" || return 1
        case "$classified" in unverifiable|r1:*) return 1 ;; esac
      fi
      ;;
    *)
      _status_presentation_signature_valid "$raw" || return 1
      case "$raw" in unverifiable|r1:*) return 1 ;; esac
      reported=$raw
      classified=$raw
      ;;
  esac
  STATUS_PRESENTATION_REPORTED=$reported
  STATUS_PRESENTATION_CLASSIFIED=$classified
}

_status_observed_path_state() {
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    LC_ALL=C stat -f '%HT:%p' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%F:%f' "$1" 2>/dev/null
  fi
}

status_observed_signature() {
  local f=$1 size=${2-} ident=${3-} path_state link_target=- access kind encoded
  path_state=$(_status_observed_path_state "$f") || path_state=stat-error
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then
    kind=absent
  elif [ ! -f "$f" ]; then
    kind=nonregular
  elif [ -r "$f" ]; then
    kind=readable
  else
    kind=unreadable
  fi
  if [ -z "$size" ]; then
    size=$(_fm_status_file_size "$f") || size='size-error'
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  fi
  if [ -z "$ident" ]; then
    ident=$(_fm_open_decisions_file_ident "$f") || ident=identity-error
    [ -n "$ident" ] || ident=identity-error
  fi
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  encoded=$(printf '%s\0%s\0%s\0%s\0%s\0%s' \
    "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" \
    | LC_ALL=C od -An -v -tx1 | tr -d ' \n') || return 1
  printf 'r1:%s' "$encoded"
}

status_presentation_marker_reported_matches() {
  local raw
  raw=$(cat "$1" 2>/dev/null) || return 1
  status_presentation_marker_parse "$raw" || return 1
  [ "$STATUS_PRESENTATION_REPORTED" = "$2" ]
}

status_presentation_marker_offset() {
  local raw classified offset ident current
  raw=$(cat "$1" 2>/dev/null) || { printf '0'; return 0; }
  status_presentation_marker_parse "$raw" || { printf '0'; return 0; }
  classified=$STATUS_PRESENTATION_CLASSIFIED
  [ "$classified" != - ] || { printf '0'; return 0; }
  offset=${classified%%@*}; ident=${classified#*@}
  current=$(_fm_open_decisions_file_ident "$2") || { printf '0'; return 0; }
  [ "$ident" = "$current" ] || { printf '0'; return 0; }
  printf '%s' "$offset"
}

status_presentation_marker_report() {
  local marker=$1 reported=$2 raw classified=-
  _status_presentation_signature_valid "$reported" || return 1
  if raw=$(cat "$marker" 2>/dev/null) && status_presentation_marker_parse "$raw"; then
    classified=$STATUS_PRESENTATION_CLASSIFIED
  fi
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}

status_presentation_marker_commit() {
  local marker=$1 file=$2 endpoint=$3 ident=$4 current reported classified
  case "$endpoint" in ''|*[!0-9]*) return 1 ;; esac
  current=$(_fm_open_decisions_file_ident "$file") || return 1
  [ -n "$ident" ] && [ "$ident" = "$current" ] || return 1
  reported=$(status_observed_signature "$file" "$endpoint" "$ident") || return 1
  classified="${endpoint}@${ident}"
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}

status_retire_presentation_task() {  # <state> <task-id>
  local state=$1 task=$2 lock manifest tmp data row_task ident offset backstop extra rc=0 found=0
  local signal_marker heartbeat_marker daemon_marker
  lock="$state/.status-presentation-lock"
  manifest="$state/.status-presentation-cursor"
  tmp="$manifest.tmp.$$"
  signal_marker=$(status_signal_seen_marker_path "$state" "$task")
  heartbeat_marker=$(status_heartbeat_seen_marker_path "$state" "$task")
  daemon_marker=$(status_daemon_seen_marker_path "$state" "$task")

  # A remote-home teardown can legitimately retire an endpoint ID that has no
  # status log in that home. Do not contend with that home's unrelated status
  # presenter in this no-op case. A concurrent presenter cannot add this task
  # without its status file, so a valid manifest with no matching row is a
  # durable proof that there is nothing to retire.
  if [ ! -e "$state/$task.status" ] && [ ! -L "$state/$task.status" ] \
    && [ ! -e "$state/.$task.open-decisions-cursor" ] \
    && [ ! -L "$state/.$task.open-decisions-cursor" ] \
    && [ ! -e "$signal_marker" ] && [ ! -L "$signal_marker" ] \
    && [ ! -e "$heartbeat_marker" ] && [ ! -L "$heartbeat_marker" ] \
    && [ ! -e "$daemon_marker" ] && [ ! -L "$daemon_marker" ]; then
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
      return 0
    fi
    if [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] \
      && data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      while IFS=$'\t' read -r row_task ident offset backstop extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset:$backstop" in *[!0-9:]*) rc=1; break ;; esac
        [ -n "$offset" ] || { rc=1; break; }
        [ "$row_task" != "$task" ] || found=1
      done <<EOF
$data
EOF
      [ "$rc" -ne 0 ] || [ "$found" -ne 0 ] || return 0
      rc=0
    fi
  fi

  fm_lock_acquire_wait "$lock" || return 1
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    if [ ! -f "$manifest" ] || [ ! -r "$manifest" ] || [ -L "$manifest" ]; then
      rc=1
    elif ! data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      rc=1
    elif ! : > "$tmp"; then
      rc=1
    else
      while IFS=$'\t' read -r row_task ident offset backstop extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset:$backstop" in *[!0-9:]*) rc=1; break ;; esac
        [ -n "$offset" ] || { rc=1; break; }
        if [ "$row_task" != "$task" ]; then
          printf '%s\t%s\t%s\t%s\n' "$row_task" "$ident" "$offset" "${backstop:-0}" >> "$tmp" \
            || { rc=1; break; }
        fi
      done <<EOF
$data
EOF
      if [ "$rc" -eq 0 ]; then mv -f "$tmp" "$manifest" || rc=1; fi
      [ "$rc" -eq 0 ] || rm -f "$tmp"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$state/$task.status" "$state/.$task.open-decisions-cursor" \
      "$signal_marker" "$heartbeat_marker" "$daemon_marker" || rc=1
  fi
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

# Read every captured unread span once in the CALLING shell while a stat pass
# is loaded, so sections that run in command substitutions (acknowledgement,
# the unread surface) inherit the memo instead of each re-reading the same
# bytes. A no-op without a loaded pass; a failed read is left for the section
# itself to report.
status_presentation_prefetch_spans() {  # <state> <snapshot>
  local state=$1 snapshot=$2 task endpoint ident f offset size out rec n line lines i=0
  local -a args=() _fm_keys=()
  [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ] || return 0
  [ -z "${FM_STATUS_SPAN_READER:-}" ] && [ -z "${FM_STATUS_SPAN_READ_PROBE:-}" ] || return 0
  while IFS=$'\t' read -r task endpoint ident; do
    [ -n "$task" ] || continue
    case "$endpoint" in ''|*[!0-9]*) continue ;; esac
    f="$state/$task.status"
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    _status_presentation_cursor_offset_r "$f" || continue
    offset=$_FM_R
    case "$offset" in ''|*[!0-9]*) continue ;; esac
    _fm_status_size_into "$f" size || continue
    [ "$endpoint" -le "$size" ] && [ "$offset" -lt "$endpoint" ] || continue
    args+=("$f" "$offset" "$((endpoint - offset))")
    _fm_keys+=("$f"$'\t'"$offset"$'\t'"$endpoint")
  done <<EOF
$snapshot
EOF
  [ "${#_fm_keys[@]}" -gt 0 ] || return 0
  # One process reads every span: per span a "<ok|fail>\t<count>" header, then
  # its <count> non-blank lines exactly as the per-span `read -r` loop keeps
  # them (newline-split, a final unterminated line included, NULs dropped).
  out=$(LC_ALL=C perl -MFcntl=:DEFAULT -e '
    while (@ARGV >= 3) {
      my ($path, $start, $length) = splice(@ARGV, 0, 3);
      my $ok = sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW)
        && sysseek($file, $start, 0) == $start;
      my $data = "";
      while ($ok && length($data) < $length) {
        my $want = $length - length($data);
        $want = 65536 if $want > 65536;
        my $read = sysread($file, my $chunk, $want);
        if (defined($read) && $read > 0) { $data .= $chunk } else { $ok = 0 }
      }
      unless ($ok) { print "fail\t0\n"; next }
      $data =~ tr/\0//d;
      my @keep = grep { /[^ \t\n\x0B\f\r]/ } split /\n/, $data;
      print "ok\t" . scalar(@keep) . "\n";
      print "$_\n" for @keep;
    }
  ' "${args[@]}" 2>/dev/null) || return 0
  while IFS=$'\t' read -r rec n; do
    [ "$i" -lt "${#_fm_keys[@]}" ] || break
    case "$n" in ''|*[!0-9]*) break ;; esac
    lines=
    while [ "$n" -gt 0 ] && IFS= read -r line; do
      lines="$lines$line"$'\n'
      n=$((n - 1))
    done
    [ "$n" -eq 0 ] || break
    [ "$rec" != ok ] || _FM_STATUS_SPAN_MEMO[${_fm_keys[$i]}]=${lines%$'\n'}
    i=$((i + 1))
  done <<EOF
$out
EOF
  return 0
}

status_acknowledge_presented_snapshot() {  # <state> <snapshot> [<fully-presented-task-ids>]
  local state=$1 snapshot=$2 fully_presented=${3:-} task endpoint ident f offset lines line safe
  while IFS=$'\t' read -r task endpoint ident; do
    [ -n "$task" ] || continue
    safe=false
    case "
$fully_presented
" in *$'\n'"$task"$'\n'*) safe=true ;; esac
    if [ "$safe" = false ]; then
      f="$state/$task.status"
      _status_presentation_cursor_offset_r "$f" || return 1
      offset=$_FM_R
      _status_new_lines_since_cursor_r "$f" "$endpoint" || return 1
      lines=$_FM_R
      # Once any informational line in this span is presented fleet-wide, the
      # contiguous cursor may advance through the captured endpoint. Routine
      # lines remain unacknowledged only while they are the sole unread content,
      # preserving delayed signal annotations without replaying a handled note
      # that happened to follow a routine line.
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *[![:space:]]*)
            if status_line_is_unread_surface "$line"; then safe=true; break; fi
            ;;
        esac
      done <<EOF
$lines
EOF
      if [ "$safe" = false ]; then endpoint=$offset; fi
    fi
    printf '%s\t%s\t%s\n' "$task" "$endpoint" "$ident" || return 1
  done <<EOF
$snapshot
EOF
}

status_commit_presentation_snapshot() {  # <state> <snapshot>
  local state=$1 snapshot=$2 task endpoint ident f cur_ident size tmp backstop acknowledged_task acknowledged_endpoint
  tmp="$state/.status-presentation-cursor.tmp.$$"
  : > "$tmp" || return 1
  while IFS=$'\t' read -r task endpoint ident; do
    [ -n "$task" ] || continue
    case "$endpoint" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ -n "$ident" ] || { rm -f "$tmp"; return 1; }
    f="$state/$task.status"
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || { rm -f "$tmp"; return 1; }
    _fm_status_ident_into "$f" cur_ident || { rm -f "$tmp"; return 1; }
    _fm_status_size_into "$f" size || { rm -f "$tmp"; return 1; }
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$cur_ident" = "$ident" ] && [ "$endpoint" -le "$size" ] \
      || { rm -f "$tmp"; return 1; }
    _status_outcome_backstop_cursor_offset_r "$f" || { rm -f "$tmp"; return 1; }
    backstop=$_FM_R
    while IFS=$'\t' read -r acknowledged_task acknowledged_endpoint; do
      if [ "$acknowledged_task" = "$task" ]; then backstop=$acknowledged_endpoint; fi
    done <<EOF
${STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED:-}
EOF
    case "$backstop" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$backstop" -le "$size" ] || { rm -f "$tmp"; return 1; }
    printf '%s\t%s\t%s\t%s\n' "$task" "$ident" "$endpoint" "$backstop" >> "$tmp" \
      || { rm -f "$tmp"; return 1; }
  done <<EOF
$snapshot
EOF
  mv -f "$tmp" "$state/.status-presentation-cursor" || { rm -f "$tmp"; return 1; }
}

scan_open_decisions_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f open line
  while IFS=$'\t' read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    _status_open_decisions_incremental_r "$f" "$endpoint" || return 1
    open=$_FM_R
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done <<EOF
$snapshot
EOF
}

# --- unread status lines since the presentation cursor ----------------------
#
# The drain annotation historically printed only the newest status line, so a
# substantive `note:` answer immediately followed by a routine `note:` (or a
# pending-reply resolution buried under a later unrelated append) never reached
# the supervisor. Those verbs also never enter the OPEN DECISIONS fold, so they
# had no other surfacing path.
# These helpers are the ONE owner of "what is still unread since the last drain
# presentation": one fleet manifest records each status identity and last-
# presented byte offset, and one atomic replacement commits only the contiguous
# status spans that were successfully presented. A quiet fleet scan leaves
# routine working/done bytes unacknowledged so a subsequently published signal
# can still annotate them. A missing manifest row or changed file identity is
# offset 0 for the current file, while malformed or unreadable cursor state
# aborts presentation without advancing any offset. A trusted cursor at EOF
# prints nothing, so already-presented bytes are not replayed as new. Teardown
# retires a task's manifest row with its status file, so reusing a task ID starts
# the replacement log unread at byte 0. Informational `note:` lines and
# reserved-key pending-reply resolutions are the fleet-wide unread surface;
# they are not open decisions and are not persisted in the folded open-set.

# Read the legacy per-task open-decisions cursor used to seed the presentation
# offset before the fleet manifest exists. A fold-version mismatch, identity
# mismatch, or offset past the current size falls back to 0. Never writes unless
# a caller explicitly requests a migration snapshot.
status_open_decisions_cursor_offset() {  # <status-file>
  local f=$1 cf offset=0 ident='' version='' cursor_data first rest open=''
  local offset_line ident_line cur_ident size
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  _fm_open_decisions_cursor_path_var "$f"
  cf=$_FM_OD_CURSOR_PATH
  if [ -e "$cf" ] || [ -L "$cf" ]; then
    [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ] || return 1
    if _fm_status_read_text_var "$cf" cursor_data; then
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
                      case "$rest" in *$'\n'*) open=${rest#*$'\n'} ;; esac
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
    else
      return 1
    fi
  fi
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  [ -n "$cur_ident" ] || return 1
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=0
    open=''
  fi
  if [ -n "${FM_STATUS_CURSOR_SNAPSHOT_FILE:-}" ]; then
    {
      printf 'version=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$FM_STATUS_CURSOR_SNAPSHOT_FILE" || return 1
  fi
  printf '%s' "$offset"
}

# Print every non-blank status line whose bytes begin at or after the persisted
# presentation offset. Does not write the cursor. A missing manifest row or
# changed status identity reads the current file from offset 0; malformed or
# unreadable cursor state fails the scan. Symlinks and unreadable status files
# print nothing.
status_new_lines_since_cursor() {  # <status-file> [<captured-end-offset>]
  _status_new_lines_since_cursor_r "$@" || return
  [ -z "$_FM_R" ] || printf '%s\n' "$_FM_R"
}

# Fork-free core of status_new_lines_since_cursor: the same non-blank lines,
# newline-joined in _FM_R (no trailing newline).
_status_new_lines_since_cursor_r() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} cf offset size actual_size chunk_file line rc=0 out='' memo_key chunk
  _FM_R=
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  _fm_open_decisions_cursor_path_var "$f"
  cf=$_FM_OD_CURSOR_PATH
  chunk_file="$cf.unread.$$"
  _status_presentation_cursor_offset_r "$f" || return 1
  offset=$_FM_R
  _FM_R=
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  _fm_status_size_into "$f" actual_size || return 1
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in ''|*[!0-9]*) return 1 ;; esac
    [ "$captured_end" -le "$actual_size" ] || return 1
    size=$captured_end
  else
    size=$actual_size
  fi
  [ "$offset" -lt "$size" ] || return 0
  # Within one loaded stat pass the same captured span is asked for by more
  # than one section (acknowledgement, then the unread surface); the bytes
  # below a captured endpoint of an unchanged file cannot change, so the
  # first answer is reused. The memo is cleared with the pass.
  memo_key="$f"$'\t'"$offset"$'\t'"$size"
  if [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ] && [ -n "${_FM_STATUS_SPAN_MEMO[$memo_key]+set}" ]; then
    _FM_R=${_FM_STATUS_SPAN_MEMO[$memo_key]}
    return 0
  fi
  if [ "$FM_STATUS_STAT_CACHE_LOADED" = 1 ] && [ -z "${FM_STATUS_SPAN_READER:-}" ] \
    && [ -z "${FM_STATUS_SPAN_READ_PROBE:-}" ]; then
    # A fleet pass reads the span with one process and no scratch file; the
    # non-blank lines are all it keeps, so command substitution's trailing
    # newline trim cannot change them.
    chunk=$(LC_ALL=C perl -MFcntl=:DEFAULT -e '
      my ($path, $start, $length) = @ARGV;
      sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
      sysseek($file, $start, 0) == $start or exit 1;
      while ($length > 0) {
        my $want = $length > 65536 ? 65536 : $length;
        my $read = sysread($file, my $part, $want);
        defined($read) && $read > 0 or exit 1;
        print $part or exit 1;
        $length -= $read;
      }
    ' "$f" "$offset" "$((size - offset))" 2>/dev/null) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *[![:space:]]*) out="$out$line"$'\n' ;;
      esac
    done <<EOF
$chunk
EOF
  else
    _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *[![:space:]]*) out="$out$line"$'\n' ;;
      esac
    done < "$chunk_file"
    rm -f "$chunk_file"
  fi
  _FM_R=${out%$'\n'}
  [ "$FM_STATUS_STAT_CACHE_LOADED" != 1 ] || _FM_STATUS_SPAN_MEMO[$memo_key]=$_FM_R
  return "$rc"
}

# 0 when a status line is an informational `note:` or a reserved-key
# pending-reply resolution. Those lines never fold into OPEN DECISIONS, so the
# drain's unread-status surface is their only guaranteed presentation. The body
# is fork-free so the unread scan stays cheap on a cold read.
status_line_is_unread_surface() {  # <status-line>
  local line=$1 verb key note resolve held prefix
  [ -n "$line" ] || return 1
  status_line_verb_core "$line"
  verb=$_FM_STATUS_VERB
  [ "$verb" = note ] && return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    "$resolve"|"$held") ;;
    *) return 1 ;;
  esac
  _fm_decision_key_core "$line" || return 1
  key=$_FM_DECISION_KEY
  status_line_note_core "$line"
  note=$_FM_STATUS_NOTE
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        _fm_decision_key_transition_allowed "$key" "$note"
        return
        ;;
    esac
  done
  return 1
}

# Fleet-wide unread informational lines: one "<task>\t<status-line>" row per
# still-unread `note:` or pending-reply resolution, in glob (task id) order.
# Prints nothing when none are unread. Directory scan rejects status symlinks
# the same way scan_open_decisions does.
scan_unread_surface_lines() {  # <state>
  local state=$1 f task lines line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    lines=$(status_new_lines_since_cursor "$f") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done
  return 0
}

scan_unread_surface_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f lines line
  while IFS=$'\t' read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    _status_new_lines_since_cursor_r "$f" "$endpoint" || return 1
    lines=$_FM_R
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done <<EOF
$snapshot
EOF
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
  local line verb key note resolve held pause open=''
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    # Blank-line guard; see _fm_fold_line_state for why this is a glob.
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    status_line_verb_core "$line"
    verb=$_FM_STATUS_VERB
    _fm_decision_key_core "$line" || continue
    key=$_FM_DECISION_KEY
    case "$verb" in
      working|"$pause")
        status_line_note_core "$line"
        note=$_FM_STATUS_NOTE
        if _fm_open_set_has "$open" "$key"; then
          _fm_decision_drop_core "$open" "$key"
          open=$_FM_DECISION_DROP
        fi
        if [ -n "$open" ]; then
          open="${open}"$'\n'"${key}"$'\t'"${verb}"$'\t'"${note}"
        else
          open="${key}"$'\t'"${verb}"$'\t'"${note}"
        fi
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        if _fm_open_set_has "$open" "$key"; then
          _fm_decision_drop_core "$open" "$key"
          open=$_FM_DECISION_DROP
        fi
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

# Capture the bytes of an append-only status log at or after <start-offset> under
# one size-and-identity snapshot.
# The record form produces `<endpoint>\t<identity>\t<events>` and returns 0 when
# the span has actionable events, joining every such event in source order with
# ` ; ` so callers report the complete captured span before committing it.
# With optional <record-var>, it assigns that record instead of printing it; with
# optional <needs-decision-var>, it also assigns 1 when the span newly surfaces a
# needs-decision, captain-held declaration, or pending-reply escalation, otherwise
# 0. This side-band classification never changes the event text.
# It returns 1 after a successful classification with no actionable event; an
# existing log still produces its committable endpoint and identity, while an absent
# log is the ordinary empty case and produces no record.
# It returns 2 with no committable endpoint when an existing status object cannot
# be classified.
# The simpler wrapper prints only the event field, and the predicate discards the
# record; all three inherit the library-header contract above.
#
# A keyed `needs-decision` or `blocked` transition is included only when it is the
# LIVE opening for its key within this span: the last opening transition for that
# key in the span (a later `resolved`/`captain-held` for the key leaves no live
# opening, and a same-key reopening supersedes the earlier one). Because the span
# always runs to the file's end, that span-local last opening is exactly the
# whole-log live opening the old whole-file fold computed - but it costs one fold
# of the appended span instead of re-reading and re-folding the entire log.
# A transition rejected by the reserved-key vocabulary is surfaced instead as a
# reconciliation signal and never treated here as an open decision.
# status_open_decisions remains the single owner of open/closed semantics,
# including same-key reopening and reserved-key handling.
# Every other captain-relevant event is terminal and always actionable.
#
# Last-opening bookkeeping for one span. Pass one folds the span and records, per
# key, the line number of its last accepted opening transition, dropping a key's
# origin the moment the span closes it; pass two classifies the span and emits in
# source order, using those line numbers to report each live opening exactly once.
# Pruning on close keeps the origin set bounded by the keys currently open rather
# than by every key ever opened, so recording an opening is never quadratic.
_FM_SPAN_ORIGINS=
_fm_span_origin_record() {  # <key> <line-number>
  local key=$1 number=$2
  _fm_span_origin_forget "$key"
  if [ -n "$_FM_SPAN_ORIGINS" ]; then
    _FM_SPAN_ORIGINS="${_FM_SPAN_ORIGINS}"$'\n'"${key}"$'\t'"${number}"
  else
    _FM_SPAN_ORIGINS="${key}"$'\t'"${number}"
  fi
}

_fm_span_origin_forget() {  # <key>
  local key=$1 line out='' sep=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in "$key"$'\t'*) continue ;; esac
    out="${out}${sep}${line}"
    sep=$'\n'
  done <<EOF
$_FM_SPAN_ORIGINS
EOF
  _FM_SPAN_ORIGINS=$out
}

_FM_SPAN_ORIGIN_LINE=
_fm_span_origin_line_for() {  # <key> -> _FM_SPAN_ORIGIN_LINE: last opening line number, or empty
  local line
  _FM_SPAN_ORIGIN_LINE=
  while IFS= read -r line; do
    case "$line" in
      "$1"$'\t'*) _FM_SPAN_ORIGIN_LINE=${line#*$'\t'}; return 0 ;;
    esac
  done <<EOF
$_FM_SPAN_ORIGINS
EOF
  return 0
}

_fm_span_fold_last_open() {  # <chunk-file> <resolve> <held>
  local line open='' number=0
  _FM_SPAN_ORIGINS=
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    _fm_fold_line_state "$open" "$line" "$2" "$3"
    open=$_FM_FOLD_OPEN
    case "$_FM_FOLD_OP" in
      open)  _fm_span_origin_record "$_FM_FOLD_KEY" "$number" ;;
      close) _fm_span_origin_forget "$_FM_FOLD_KEY" ;;
    esac
  done < "$1"
}

status_span_first_actionable_record() {  # <status-file> <start-offset> [record-var] [needs-decision-var] [max-end-offset]
  local f=$1 start=${2:-0} output_var=${3-} needs_var=${4-} max_end=${5-} size ident cur_ident scratch chunk_file result
  local line verb key resolve held rc=1 line_number=0 live_line events='' _fm_span_needs_decision=0 end endpoint folded
  [ -e "$f" ] || { [ -L "$f" ] && return 2; return 1; }
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 2
  ident=$(_fm_open_decisions_file_ident "$f") || return 2
  size=$(_fm_status_file_size "$f") || return 2
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 2 ;; esac
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  [ "$start" -le "$size" ] || start=0
  if [ "$start" -ge "$size" ]; then
    result="${size}"$'\t'"${ident}"
    if [ -n "$output_var" ]; then
      printf -v "$output_var" '%s' "$result"
      [ -z "$needs_var" ] || printf -v "$needs_var" '%s' 0
    else
      printf '%s' "$result"
    fi
    return 1
  fi
  # An optional max-end-offset bounds the folded window (belt-and-braces for the
  # heartbeat backstop). The read stops at the last newline inside the bound so
  # the recorded endpoint is a byte the next fold resumes from cleanly; an empty
  # or absent bound keeps the original whole-append read exactly as before.
  end=$size
  case "$max_end" in
    ''|*[!0-9]*) ;;
    *) [ "$max_end" -gt "$start" ] && [ "$max_end" -lt "$size" ] && end=$max_end ;;
  esac
  scratch=$(_fm_status_span_scratch "$f") || return 2
  chunk_file="${scratch}.span"
  if [ "$end" -lt "$size" ]; then
    if _fm_status_read_complete_span "$f" "$start" "$((end - start))" > "$chunk_file" 2>/dev/null; then
      folded=$(_fm_status_file_size "$chunk_file") || { rm -f "$chunk_file"; return 2; }
      folded=${folded//[[:space:]]/}
      case "$folded" in ''|*[!0-9]*) rm -f "$chunk_file"; return 2 ;; esac
    else
      folded=0
      : > "$chunk_file" || { rm -f "$chunk_file"; return 2; }
    fi
    endpoint=$((start + folded))
  else
    _fm_status_read_span "$f" "$start" "$((size - start))" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; return 2; }
    endpoint=$size
  fi
  cur_ident=$(_fm_open_decisions_file_ident "$f") || { rm -f "$chunk_file"; return 2; }
  [ "$cur_ident" = "$ident" ] || { rm -f "$chunk_file"; return 2; }
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  _fm_span_fold_last_open "$chunk_file" "$resolve" "$held"
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    status_line_verb_core "$line"
    verb=$_FM_STATUS_VERB
    if [ "$verb" = "$held" ]; then
      # A transfer closes the status-log decision and remains non-actionable to
      # stale classification. The side-band marker lets signal routing surface
      # the captain-owned hold without changing that established stale verdict.
      _fm_span_needs_decision=1
      continue
    fi
    status_is_captain_relevant_verb "$line" "$verb" || continue
    case "$verb" in
      needs-decision|blocked)
        if ! _fm_decision_key_core "$line"; then
          [ -n "$events" ] && events="${events} ; "
          events="${events}${line}"
          [ "$verb" = needs-decision ] && _fm_span_needs_decision=1
          rc=0
          continue
        fi
        key=$_FM_DECISION_KEY
        status_line_note_core "$line"
        _fm_decision_key_transition_allowed "$key" "$_FM_STATUS_NOTE" || {
          [ -n "$events" ] && events="${events} ; "
          events="${events}reconciliation-required: ${line}"
          [ "$verb" = needs-decision ] && _fm_span_needs_decision=1
          rc=0
          continue
        }
        _fm_span_origin_line_for "$key"
        live_line=$_FM_SPAN_ORIGIN_LINE
        [ -n "$live_line" ] && [ "$line_number" = "$live_line" ] || continue
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        if [ "$verb" = needs-decision ] || { [ "$verb" = blocked ] &&
          _fm_is_pending_reply_escalation "$key" "$_FM_STATUS_NOTE"; }; then
          _fm_span_needs_decision=1
        fi
        rc=0
        ;;
      *)
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        rc=0
        ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file"
  if [ "$rc" -eq 0 ]; then result="${endpoint}"$'\t'"${ident}"$'\t'"${events}"; else result="${endpoint}"$'\t'"${ident}"; fi
  if [ -n "$output_var" ]; then
    printf -v "$output_var" '%s' "$result"
    [ -z "$needs_var" ] || printf -v "$needs_var" '%s' "$_fm_span_needs_decision"
  else
    printf '%s' "$result"
  fi
  return "$rc"
}

status_span_first_actionable() {  # <status-file> <start-offset>
  local record rc rest
  record=$(status_span_first_actionable_record "$1" "${2:-0}")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rest=${record#*$'\t'}
    printf '%s' "${rest#*$'\t'}"
  fi
  return "$rc"
}

status_span_has_actionable() {  # <status-file> <start-offset>
  status_span_first_actionable_record "$1" "${2:-0}" > /dev/null
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
# absorb-only-on-positive-evidence. This is the sole proof for stale wakes and the
# shared authoritative proof for no-verb signals. Where a home opts in, fm-watch.sh
# may additionally absorb a bare turn-end on bounded pane churn, while every other
# failed verdict surfaces
# because the crew may be done, waiting on a decision, or wedged. For stale panes
# it is checked before trusting the status log so a pre-validation captain-relevant
# line does not override an active run. See crew_absorb_class for the exact
# working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# Directories excluded from the worktree write probe below, and the depth it walks.
# The excluded set is everything a supervisor read or a package manager can write
# without the crew doing any work - .git first, so firstmate's own read-only git
# commands against the worktree can never make the probe self-fulfilling - plus the
# large generated trees that would make the walk expensive. Both are overridable so
# a home with an unusual layout can widen or narrow the probe. The list is a skip
# list, so clearing it skips nothing and widens the walk to the whole depth-bounded
# tree; it never disables the probe, which would quietly cost the wedge detector a
# liveness input on a home that meant to widen it. Defaulted with the plain form so
# an explicitly empty value stays empty: clearing the knob in the environment is the
# documented way to ask for that wider walk, and treating empty as unset would hand
# the default skip list back to exactly the home that asked for more coverage.
FM_WORKTREE_WRITE_PRUNE=${FM_WORKTREE_WRITE_PRUNE-'.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'}
FM_WORKTREE_WRITE_MAXDEPTH=${FM_WORKTREE_WRITE_MAXDEPTH:-6}

# Wall-clock seconds the probe's single walk may take. The walk runs synchronously
# inside the caller's poll loop at the exact moment an escalation would otherwise
# fire, and -xdev keeps it out of a nested mount but cannot help when the worktree
# root ITSELF sits on a hung network or container mount; unbounded, such a walk
# would wedge the very supervisor that exists to notice a wedge, stalling its
# heartbeat instead of escalating. Hitting the bound is a negative outcome like
# every other: it reads as no evidence, so the caller's escalation schedule is
# untouched and a stall that writes nothing still escalates on the existing
# schedule. A value that is not a positive integer is not a bound at all (`timeout
# 0` and the perl fallback's `alarm 0` both disable the deadline), so the default
# applies instead; the check lives at the point of use so an in-process override
# gets it too.
FM_WORKTREE_WRITE_TIMEOUT=${FM_WORKTREE_WRITE_TIMEOUT:-10}

# 0 when some regular file under <id>'s recorded worktree is newer than
# <anchor-file>: positive evidence the crew is still producing work even though its
# rendered pane has gone quiet. This is the third liveness input the wedge detector
# has, after pane quietness and the run step, and it exists because neither of
# those can see a crew that is writing source, then tests, then documentation
# behind a static pane - the 2026-08-14 case of eight consecutive possible-wedge
# escalations against a crew that was demonstrably working the whole time.
#
# 1 for every other outcome, including an id with no recorded worktree, a worktree
# that is gone, a missing anchor, and a walk that fails or finds nothing. Absence of
# evidence therefore always leaves the caller's existing escalation schedule
# untouched, so a crew that writes nothing still escalates exactly as before.
#
# A kind=secondmate task records a provisioned firstmate home, not a code tree, and
# such a home runs its OWN supervision inside it: its state/ directory churns a
# watcher beacon, pane hashes, and heartbeats whether or not the mate is producing
# anything, so a walk there would report liveness for a mate that has done nothing.
# Those homes are excluded outright rather than by pruning "state", which would also
# hide a legitimate source directory of that name in an ordinary worktree. The
# exclusion is a negative outcome like any other, so an unproductive mate keeps
# escalating on the caller's unchanged schedule.
#
# The anchor is the caller's own idle-window timer file, whose mtime already marks
# when the quiet window opened, so `-newer` needs no clock arithmetic, no temp
# file, and no portable mtime-setting. Not a pure status-file read (see the header):
# one pruned, depth-bounded, wall-clock-bounded walk per call, which callers must
# reach only when they are otherwise about to escalate, never on every poll. A walk
# that outlives FM_WORKTREE_WRITE_TIMEOUT is killed and reported as no evidence, so
# a hung mount costs the escalation nothing but the bound. -xdev holds that walk to the
# worktree's own filesystem rather than descending into a nested network or container
# mount, so a write that lands only under such a mount is one more negative outcome.
crew_worktree_written_since() {  # <id> <state> <anchor-file>
  local id=$1 state=$2 anchor=$3 wt kind name hit bound
  local -a names=() prune=()
  [ -n "$id" ] || return 1
  [ -f "$anchor" ] || return 1
  wt=$(grep '^worktree=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  kind=$(grep '^kind=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$kind" != secondmate ] || return 1
  if [ -e "$wt/.fm-secondmate-home" ] || [ -L "$wt/.fm-secondmate-home" ]; then
    return 1
  fi
  read -r -a names <<< "$FM_WORKTREE_WRITE_PRUNE"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  bound=$FM_WORKTREE_WRITE_TIMEOUT
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      \( "${prune[@]}" \) -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  else
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  fi
  [ -n "$hit" ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list the caller classified with the span read above.
# Files are mapped to task ids by stripping the .status / .turn-ended suffix;
# a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
# A kind=secondmate task's .status signal is never absorbable here regardless of
# busy evidence: that stream is the mate's routed-reply channel, so every append
# is parent-directed content the supervisor must read (a routed reply, a newly
# raised decision, a mirrored remote line), and a busy mate agent makes its note
# more current, not less deliverable. Scoped to .status files - a mate's bare
# turn-ended ping still uses the ordinary provably-working absorb.
signal_crew_provably_working() {  # <file> ...
  local f base dir task seen=""
  for f in "$@"; do
    base=${f##*/}
    dir=${f%/*}
    [ "$dir" != "$f" ] || dir=.
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case "$base" in
      *.status)
        if [ "$(grep '^kind=' "$dir/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2-)" = secondmate ]; then
          return 1
        fi
        ;;
    esac
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
