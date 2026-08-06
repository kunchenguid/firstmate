#!/usr/bin/env bash
# fm-ruling-reconcile.sh - deterministic, model-free prefilter that reconciles
# this home's ruling documents against its OPEN captain decision holds.
#
# Why this exists: a captain answers a decision in a ruling document and the
# hold that asked the question stays queued. The register then re-asks answered
# questions and investigations inherit stale premises. Nothing read the ruling
# back onto the hold, so the reconciliation was done by hand, repeatedly, by
# re-reading ruling prose on every bearings and every investigation.
#
# This script answers only the deterministic part: which open captain hold is
# named, verbatim, in which ruling document, at which line, next to which
# explicit verdict token. It reaches the `no_delta` terminal without opening a
# ruling document at all when nothing that could change the answer has changed.
#
# It NEVER grades and NEVER closes. Grading an excerpt as rules / commissions /
# cites / defers requires classifying natural language, which is the caller's
# work. Closing a hold is the captain's authority, exercised through
# bin/fm-decision-hold.sh resolve. This script produces evidence and an
# eligibility verdict; .agents/skills/decision-hold-lifecycle/SKILL.md owns the
# surrounding decision policy.
#
# THE CLOSURE RULE THIS SCRIPT ENFORCES (captain ruling, 2026-08-06, option c):
# a hold may be closed on the strength of a ruling only when BOTH hold - the
# ruling document names the hold identifier VERBATIM, and the ruling carries an
# EXPLICIT VERDICT TOKEN. Everything else escalates. A hold named in a
# commission rather than a ruling is never eligible. Both conditions together
# are NECESSARY AND NOT SUFFICIENT: eligibility still requires a caller grade of
# `rules`, and closure is still performed by fm-decision-hold.sh, never here.
# The error direction is deliberate - a document class or verdict token this
# script cannot recognise escalates to a human, and can never close a hold.
#
# The derived index lives under the home's existing volatile-state owner
# ($FM_HOME/state/ruling-index). Deleting the whole index is always safe; the
# next scan rebuilds it deterministically from the canonical sources. The index
# is derived, never authority: decision truth stays in the ruling documents and
# hold truth stays in the backlog.
#
# Usage:
#   fm-ruling-reconcile.sh [scan] [--rebuild] [--quiet]
#                                inventory, fingerprint, match, write the index
#   fm-ruling-reconcile.sh status           print the current index header only
#   fm-ruling-reconcile.sh propose          emit the stale_holds grading envelope
#   fm-ruling-reconcile.sh closure-test <hold-id> --ruling <path> --line <n>
#                                --grade <rules|commissions|cites|defers>
#                                apply the captain's two-condition closure rule
#                                to one graded excerpt and print the permitted
#                                fm-decision-hold.sh command, or escalate
#   fm-ruling-reconcile.sh schema           print the derived-index schema
#   fm-ruling-reconcile.sh --help           print this usage
#
# Environment:
#   FM_HOME                     home whose data/ and state/ are used
#   FM_DATA_OVERRIDE            corpus root (default $FM_HOME/data)
#   FM_STATE_OVERRIDE           state root (default $FM_HOME/state)
#   FM_RULING_EXCERPT_CHARS     excerpt trim width (default 300)
#   FM_RULING_MAX_MATCHES       matched lines kept per hold (default 20)
#   FM_RULING_VERDICT_WINDOW    lines after a match scanned for a verdict token
#                               (default 12)
#   FM_RULING_VERDICT_TOKENS    extended-regex alternation of verdict tokens
#   FM_RULING_NOW               fixed generation stamp (deterministic rebuilds)
set -u

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INDEX="$STATE/ruling-index"

SCHEMA_INDEX=fm-ruling-index.v1

EXCERPT_CHARS="${FM_RULING_EXCERPT_CHARS:-300}"
MAX_MATCHES="${FM_RULING_MAX_MATCHES:-20}"
VERDICT_WINDOW="${FM_RULING_VERDICT_WINDOW:-12}"

# The explicit-verdict vocabulary. A token counts only inside single-line
# markdown emphasis (**...**), which is how this home's ruling tables record a
# verdict, so ordinary prose that merely discusses a decision does not qualify.
#
# The set is tuned for PRECISION, not recall, because the two error directions
# are not symmetric. A verdict this set misses escalates to a human, which costs
# a read. A non-verdict this set accepts weakens the captain's condition 2
# toward vacuity, which is the "brittle regex replacing judgment" failure this
# increment exists to avoid. Common English words were therefore removed after
# measurement: `OPTION` matched the attribution span
# `**Captain, 2026-08-06, choosing option (c) verbatim:**`, and `RUN` matches
# ordinary instruction prose (`**Run the migration**`) as a whole word, so
# anchoring cannot rescue it. Structural emphasis in this corpus
# (`**Captain, verbatim:**`, `**One owner:**`, `**not met**`) matches nothing
# here, which is the intended behaviour.
#
# A token is matched as a WHOLE WORD, never as a substring of a longer one, and
# only a verb inflection may follow it. Without that anchoring the set accepts
# any emphasised word that merely CONTAINS a token - `**Runtime**` for `RUN`,
# `**sparkline**` for `PARK`, `**acceptable**` for `ACCEPT`, `**adoption**` for
# `ADOPT` - which is precisely the condition-2 vacuity this set exists to avoid.
# The inflection tail keeps the intended readings (`**ADOPTED**`, `**PARKED**`,
# `**REPLACED**`) while refusing the accidental ones.
#
# Recall is deliberately NOT tuned up to a target count. On this home's flagship
# ruling table the set recognised 15 of 24 rows when measured, an upper bound now
# that tokens are whole-word anchored; the other nine state their verdict without
# emphasis ("Replace the fictional cap of 3 with an **enforced ceiling of 10**"
# emphasises the ceiling, not the verb) and therefore escalate.
# Widening the vocabulary until it reproduced a hoped-for number would be the
# exact failure this increment exists to avoid.
#
# Both conditions together remain NECESSARY AND NOT SUFFICIENT: a match makes a
# row eligible for grading, never closed.
VERDICT_TOKENS="${FM_RULING_VERDICT_TOKENS:-APPROVED|AUTHORI[SZ]ED|RESOLVED|REJECTED|DECLINED|DEFERRED|WITHDRAWN|SUPERSEDED|ADOPT|ACCEPT|PARK|RETAIN|RETARGET|REPLACE|PRUNE|CONSOLIDATE|ACTIVATE|DO NOT|NOT READY|NO-GO|GO-AHEAD|FAIL CLOSED|DECISION:|RULING:}"
VERDICT_RE='(^|[^A-Za-z])('"$VERDICT_TOKENS"')(E?[DS]|ING)?([^A-Za-z]|$)'

GRADES='rules commissions cites defers'

die() { printf 'fm-ruling-reconcile.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

WORK=
cleanup_work() { [ -n "$WORK" ] && rm -rf -- "$WORK"; WORK=; }
trap cleanup_work EXIT HUP INT TERM

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

now_stamp() {
  if [ -n "${FM_RULING_NOW:-}" ]; then
    printf '%s\n' "$FM_RULING_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# One TSV cell: tabs and carriage returns collapse to spaces and the cell is
# trimmed, so a pathological ruling line cannot corrupt the index shape.
tsv_cell() {  # <text>
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c "1-$EXCERPT_CHARS"
}

# The hold identifier as an extended regex that matches only a WHOLE identifier.
# Hold ids are `<origin>-decision-<key>`, so one id is routinely a prefix of
# another and a bare substring test satisfies the captain's condition 1 with the
# WRONG row: `sample-review-decision-alpha` would be "named verbatim" by a row
# that rules `sample-review-decision-alpha-two`. The index scan and the closure
# gate share this one pattern so they can never disagree about what verbatim
# means.
#
# A dot is legal inside a hold id, so it has to be excluded from the boundary to
# keep `a.b` from standing in for a line that names `a.b.c`. Excluding it
# outright, though, refused every prose naming that ends in a full stop, and the
# hold was then reported `unmatched: no ruling document names this hold`. A
# silent false-unmatch is the exact failure this increment exists to eliminate:
# it tells the reader nothing names the hold and the reader believes it, so
# "safe for closure" is not a sufficient bar when the scan's whole job is to
# find the naming. A trailing dot is therefore a boundary only when the dot
# itself ends the line or is followed by whitespace, which recognises the
# sentence-ending naming while leaving the anti-shadowing property intact.
hold_pattern() {  # <hold-id>
  local esc
  esc=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]/\\&/g')
  printf '(^|[^A-Za-z0-9._-])%s([^A-Za-z0-9._-]|[.]([[:space:]]|$)|$)' "$esc"
}

# --- corpus scope -----------------------------------------------------------

resolve_data_root() {
  [ -e "$DATA" ] || die "corpus root is absent: $DATA"
  [ ! -L "$DATA" ] || die "corpus root must not be a symlink: $DATA"
  [ -d "$DATA" ] || die "corpus root is not a directory: $DATA"
  (cd "$DATA" && pwd -P)
}

# Candidate ruling-corpus paths. Mirrors bin/fm-research-scan.sh's
# decision_sources inventory shape deliberately: same corpus, same discipline,
# no second definition of where durable decisions live.
ruling_candidates() {  # <resolved-root>
  local root=$1
  # Symlinks are listed, not filtered out, so build_ruling_inventory can REFUSE
  # them. A `-type f` filter would drop a symlinked ruling document silently,
  # and a silently dropped ruling is exactly the "unruled" claim the empty-set
  # law forbids.
  {
    find "$root" -maxdepth 1 \( -type f -o -type l \) -name '*.md' \
      \( -name '*ruling*' -o -name '*commission*' -o -name 'decision*' \) -print
    find "$root" -mindepth 2 -maxdepth 2 \( -type f -o -type l \) -name '*.md' \
      \( -name '*ruling*' -o -name '*commission*' -o -name 'decision*' \) -print
  } 2>/dev/null | LC_ALL=C sort -u
}

# Document class, decided structurally rather than by loose substring, because
# this corpus contains both a ruling ABOUT a commission
# (captain-rulings-2026-08-04-commission-32.md) and a commission INSIDE a
# rulings directory (captain-rulings-2026-08-06/cfvc-remediation-commission.md).
# Naming carries the class in two stable positions: a ruling declares itself in
# the `<who>-rulings-<when>` PREFIX form, evaluated only over the leading one or
# two dash-separated segments, and a commission declares itself in the
# `<what>commission.md` SUFFIX form. The directory is a third, weaker signal.
#
# THE IMPLEMENTED ORDER IS SUFFIX, THEN PREFIX, THEN DIRECTORY, AND IT MUST NOT
# BE REORDERED. The commission suffix is decisive and is therefore tested first:
# a document that ends in `commission.md` is a commission however much its name
# resembles a ruling elsewhere. That order can only ever bias a name toward
# `commission`, and a commission escalates rather than closes, so it fails safe
# by construction. Testing the ruling prefix first would let a commission-suffixed
# name classify as a ruling and satisfy the captain's condition 1, which is the
# exact inversion this two-position design exists to prevent - do not "correct"
# the order back. The prefix form is anchored for the same reason: an unanchored
# `*ruling-*` matches `cfvc-remediation-ruling-commission.md` and makes the
# commission branch unreachable. The directory is consulted last and only when
# the name itself declares nothing. Anything else is `other` and escalates, so an
# unrecognised naming convention costs a human read and can never close a hold.
declares_ruling() {  # <basename-or-directory-name>
  local n
  n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$n" in
    ruling|rulings|ruling-*|rulings-*|ruling.*|rulings.*) return 0 ;;
  esac
  case "$n" in
    *-*) case "${n#*-}" in ruling-*|rulings-*) return 0 ;; esac ;;
  esac
  return 1
}

doc_class() {  # <path>
  local base parent lower
  base=$(basename "$1")
  parent=$(basename "$(dirname "$1")")
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *commission.md) printf 'commission\n'; return ;;
  esac
  if declares_ruling "$base" || declares_ruling "$parent"; then
    printf 'ruling\n'
    return
  fi
  printf 'other\n'
}

# --- hold inventory ---------------------------------------------------------
#
# Open captain holds come from tasks-axi, which is the backlog's owner. Rows are
# accepted only when the identifier is a slug and the state is one this script
# recognises, so the listing's count/help decoration can never enter the index.
#
# THE EMPTY-SET LAW APPLIES TO THIS READER TOO. A `list` that fails - an older
# build that rejects a flag, a broken backlog, any runtime error - is a terminal
# refusal, never an empty hold set. Absorbing it would publish `open_holds=0`,
# and session start's quiet path would then say nothing at all, which reads as
# "no captain decision is waiting" on exactly the evidence that no one could
# tell. A genuinely empty backlog exits 0 with a count of 0 and stays distinct.

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

collect_holds() {  # <out-tsv> <err-file>
  local out=$1 err=$2 state raw
  : > "$out"
  for state in queued held in_flight; do
    if ! raw=$(tasks_axi list --kind captain --state "$state" 2>"$err"); then
      printf 'schema=%s\nverdict=NO_HOLD_READ\nunreadable=tasks-axi list --kind captain --state %s\nreason=%s\n' \
        "$SCHEMA_INDEX" "$state" "$(tr '\t\r\n' '   ' < "$err")" >&2
      return 3
    fi
    printf '%s\n' "$raw" | awk -F',' '
      /^  [A-Za-z0-9]/ {
        id = $1; sub(/^  +/, "", id)
        if (id !~ /^[A-Za-z0-9._-]+$/) next
        if ($2 != "queued" && $2 != "held" && $2 != "in_flight") next
        printf "%s\t%s\n", id, $2
      }' >> "$out"
  done
  LC_ALL=C sort -u -o "$out" "$out"
}

# --- fingerprints -----------------------------------------------------------
#
# Two independent inputs can change the answer: the open-hold set and the
# ruling corpus. Either change forces a rescan.

ruling_fingerprint() {  # <inventory-tsv>
  sha256_stdin < "$1"
}

hold_fingerprint() {  # <holds-tsv>
  sha256_stdin < "$1"
}

# --- inventory --------------------------------------------------------------
#
# THE EMPTY-SET LAW. A ruling-class document this script cannot read is a
# terminal refusal, not a silent omission, because the verdict it would have
# carried is exactly what "unmatched" would otherwise deny. An unread ruling
# never becomes "unruled".

build_ruling_inventory() {  # <resolved-root> <out-tsv>
  local root=$1 out=$2 path rel class sha dir
  : > "$out"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rel=${path#"$root"/}
    class=$(doc_class "$path")
    if [ -L "$path" ]; then
      printf 'schema=%s\nverdict=NO_RULING_READ\nunreadable=%s\nreason=symlinked-ruling-document-not-read\n' \
        "$SCHEMA_INDEX" "$rel" >&2
      return 3
    fi
    dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || dir=''
    case "$dir" in
      "$root"|"$root"/*) : ;;
      *)
        printf 'schema=%s\nverdict=NO_RULING_READ\nunreadable=%s\nreason=ruling-document-outside-corpus-root\n' \
          "$SCHEMA_INDEX" "$rel" >&2
        return 3 ;;
    esac
    if [ ! -r "$path" ] || ! sha=$(sha256_file "$path") || [ -z "$sha" ]; then
      printf 'schema=%s\nverdict=NO_RULING_READ\nunreadable=%s\nreason=ruling-document-could-not-be-read\n' \
        "$SCHEMA_INDEX" "$rel" >&2
      return 3
    fi
    printf '%s\t%s\t%s\n' "$rel" "$class" "$sha" >> "$out"
  done < <(ruling_candidates "$root")
  LC_ALL=C sort -o "$out" "$out"
}

# --- verdict detection ------------------------------------------------------
#
# Deterministic presence of an emphasis-marked verdict token within a bounded
# window starting at the matched line. Reports the literal emphasised span and
# the line it was found on, so the caller can audit every eligibility verdict
# against the document rather than trusting this classifier.

verdict_in_window() {  # <file> <line> -> "<line>\t<token>" or ""
  local file=$1 line=$2 end span text hit
  # A markdown table row is self-contained: one ruling per line, verdict in its
  # own cells. Scanning a window from a table row would attribute a NEIGHBOURING
  # row's verdict to this hold - measured, on the real corpus, where row A4's
  # window reached row B1's `**RESOLVED**` six lines below. A table row is
  # therefore scanned alone.
  text=$(sed -n "${line}p" "$file" 2>/dev/null)
  case "$text" in
    '|'*|' '*'|'*|$'\t'*'|'*)
      span=$(printf '%s' "$text" \
        | grep -oE '\*\*[^*]+\*\*' 2>/dev/null \
        | grep -iE "$VERDICT_RE" 2>/dev/null \
        | head -n1)
      [ -n "$span" ] || return 1
      printf '%s\t%s\n' "$line" "$(tsv_cell "$span")"
      return 0
      ;;
  esac
  # The window is read once, as a range, and the emphasised spans it contains
  # are numbered relative to its first line. Re-reading the file once per window
  # line costs a full scan from the start per candidate, and this runs inline in
  # fm-session-start.sh for every hold in every document.
  end=$((line + VERDICT_WINDOW))
  hit=$(sed -n "${line},${end}p" "$file" 2>/dev/null \
    | grep -noE '\*\*[^*]+\*\*' 2>/dev/null \
    | grep -iE "$VERDICT_RE" 2>/dev/null \
    | head -n1)
  [ -n "$hit" ] || return 1
  printf '%s\t%s\n' "$((line + ${hit%%:*} - 1))" "$(tsv_cell "${hit#*:}")"
}

eligibility_of() {  # <doc-class> <verdict-token>
  if [ "$1" != ruling ]; then
    printf 'escalate\n'
  elif [ -z "$2" ]; then
    printf 'escalate\n'
  else
    printf 'closable-if-graded-rules\n'
  fi
}

# --- scan -------------------------------------------------------------------

cmd_scan() {
  local rebuild=0 quiet=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rebuild) rebuild=1 ;;
      --quiet) quiet=1 ;;
      *) die "unknown scan option: $1" 2 ;;
    esac
    shift
  done

  command -v tasks-axi >/dev/null 2>&1 || die "tasks-axi is required"

  local root
  root=$(resolve_data_root) || exit 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state root is unavailable: $STATE"

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-ruling-reconcile.XXXXXX") || die "cannot create work directory"
  local tmp=$WORK rc=0

  collect_holds "$tmp/holds.tsv" "$tmp/holds.err" || rc=$?
  if [ "$rc" -eq 3 ]; then
    # The empty-set law, applied to the hold reader: a backlog nobody could read
    # is not an empty hold set.
    exit 3
  fi
  build_ruling_inventory "$root" "$tmp/rulings.tsv" || rc=$?
  if [ "$rc" -eq 3 ]; then
    # The empty-set law: refuse the whole run rather than publish an index whose
    # "unmatched" rows rest on a ruling nobody read.
    exit 3
  fi

  local hold_fp ruling_fp hold_n ruling_n
  hold_fp=$(hold_fingerprint "$tmp/holds.tsv")
  ruling_fp=$(ruling_fingerprint "$tmp/rulings.tsv")
  hold_n=$(grep -c . "$tmp/holds.tsv" || true)
  ruling_n=$(grep -c . "$tmp/rulings.tsv" || true)

  # The no_delta terminal, reached before any ruling document is opened for
  # matching, so an unchanged corpus and an unchanged hold set cost one
  # directory walk plus the inventory hash and no extraction at all.
  if [ "$rebuild" -eq 0 ] && index_is_current "$hold_fp" "$ruling_fp" "$tmp/holds.tsv" "$tmp/rulings.tsv"; then
    emit_summary no_delta "$hold_n" "$ruling_n" 0 "$quiet"
    return 0
  fi

  mkdir -p "$INDEX" || die "cannot create index directory: $INDEX"

  local hold state path rel class line text vline vtoken vout elig hits pattern matched=0 candidates=0
  : > "$tmp/matches.tsv"
  while IFS=$'\t' read -r hold state; do
    [ -n "$hold" ] || continue
    hits=0
    pattern=$(hold_pattern "$hold")
    while IFS=$'\t' read -r rel class; do
      [ -n "$rel" ] || continue
      path="$root/$rel"
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        text=${line#*:}
        line=${line%%:*}
        vline=''
        vtoken=''
        if vout=$(verdict_in_window "$path" "$line"); then
          vline=${vout%%$'\t'*}
          vtoken=${vout#*$'\t'}
        fi
        elig=$(eligibility_of "$class" "$vtoken")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$hold" "$rel" "$line" "$class" "${vtoken:-none}" "${vline:-0}" "$elig" "$(tsv_cell "$text")" \
          >> "$tmp/matches.tsv"
        hits=$((hits + 1))
        matched=$((matched + 1))
      done < <(grep -nE -- "$pattern" "$path" 2>/dev/null | head -n "$MAX_MATCHES")
    done < <(cut -f1,2 "$tmp/rulings.tsv")
    if [ "$hits" -eq 0 ]; then
      # An unmatched hold is REPORTED, never dropped. Durable-source silence is
      # not evidence that a decision was never ruled; it is evidence that this
      # corpus does not name it.
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$hold" none 0 none none 0 escalate "unmatched: no ruling document names this hold ($state)" \
        >> "$tmp/matches.tsv"
    else
      candidates=$((candidates + 1))
    fi
  done < "$tmp/holds.tsv"
  LC_ALL=C sort -o "$tmp/matches.tsv" "$tmp/matches.tsv"

  cp "$tmp/holds.tsv" "$INDEX/holds.tsv"
  cp "$tmp/rulings.tsv" "$INDEX/rulings.tsv"
  cp "$tmp/matches.tsv" "$INDEX/matches.tsv"
  {
    printf 'schema=%s\n' "$SCHEMA_INDEX"
    printf 'derived=true\n'
    printf 'authority=none\n'
    printf 'generated=%s\n' "$(now_stamp)"
    printf 'corpus_root=%s\n' "$root"
    printf 'hold_fingerprint=%s\n' "$hold_fp"
    printf 'ruling_fingerprint=%s\n' "$ruling_fp"
    printf 'open_holds=%s\n' "$hold_n"
    printf 'ruling_documents=%s\n' "$ruling_n"
    printf 'verdict_window=%s\n' "$VERDICT_WINDOW"
  } > "$INDEX/index.meta"

  emit_summary delta "$hold_n" "$ruling_n" "$matched" "$quiet" "$candidates"
}

emit_summary() {  # <verdict> <holds> <rulings> <matched> <quiet> [candidates]
  local verdict=$1 holds=$2 rulings=$3 matched=$4 quiet=$5 candidates=${6:-} eligible=0
  if [ -s "$INDEX/matches.tsv" ]; then
    eligible=$(awk -F'\t' '$7 == "closable-if-graded-rules"' "$INDEX/matches.tsv" | grep -c . || true)
  fi
  if [ "$quiet" -eq 1 ]; then
    [ "$holds" -eq 0 ] && return 0
    printf 'RULING_RECONCILE: %s open captain decision(s); %s ruling excerpt(s) await grading before any closure\n' \
      "$holds" "$eligible"
    return 0
  fi
  printf 'schema=%s\n' "$SCHEMA_INDEX"
  printf 'verdict=%s\n' "$verdict"
  printf 'open_holds=%s\n' "$holds"
  printf 'ruling_documents=%s\n' "$rulings"
  printf 'extracted=%s\n' "$matched"
  [ -n "$candidates" ] && printf 'holds_with_candidates=%s\n' "$candidates"
  printf 'eligible_excerpts=%s\n' "$eligible"
  printf 'index=%s\n' "$INDEX"
}

index_is_current() {  # <hold-fp> <ruling-fp> <fresh-holds> <fresh-rulings>
  local hold_fp=$1 ruling_fp=$2 fresh_holds=$3 fresh_rulings=$4
  [ -f "$INDEX/index.meta" ] || return 1
  [ -f "$INDEX/matches.tsv" ] || return 1
  grep -qxF "schema=$SCHEMA_INDEX" "$INDEX/index.meta" || return 1
  grep -qxF "hold_fingerprint=$hold_fp" "$INDEX/index.meta" || return 1
  grep -qxF "ruling_fingerprint=$ruling_fp" "$INDEX/index.meta" || return 1
  cmp -s "$fresh_holds" "$INDEX/holds.tsv" || return 1
  cmp -s "$fresh_rulings" "$INDEX/rulings.tsv" || return 1
  return 0
}

# --- propose ----------------------------------------------------------------
#
# The grading envelope: schema header, then rows. Every row is an excerpt a
# caller must READ and grade. No row carries a grade, because this script does
# not grade; `grade` is emitted as `ungraded` and stays that way until a caller
# supplies one to closure-test.
#
# The excerpt and the verdict token are the two cells whose content comes from
# the ruling document, and an excerpt is a markdown table row, which routinely
# contains commas. They are therefore RFC 4180 double-quoted so the declared
# nine-field row stays honest; the column order is fixed by the schema and does
# not move.

cmd_propose() {
  [ -f "$INDEX/matches.tsv" ] || die "no index; run: fm-ruling-reconcile.sh scan" 2
  local n
  n=$(grep -c . "$INDEX/matches.tsv" || true)
  printf 'schema=%s\n' "$SCHEMA_INDEX"
  printf 'authority=none\n'
  printf 'grading=required\n'
  printf 'closure_rule=verbatim-identifier-in-ruling AND explicit-verdict-token AND grade=rules\n'
  printf 'quoted_fields=excerpt,verdict_token\n'
  printf 'stale_holds[%s]{hold_id,ruling_file,ruling_line,excerpt,grade,doc_class,verdict_token,verdict_line,eligibility}:\n' "$n"
  awk -F'\t' '
    function q(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
    { printf "  %s,%s,%s,%s,ungraded,%s,%s,%s,%s\n", $1, $2, $3, q($8), $4, q($5), $6, $7 }
  ' "$INDEX/matches.tsv"
}

# --- closure test -----------------------------------------------------------
#
# The captain's rule, applied to ONE graded excerpt, re-verified against the
# document rather than against the index, so a stale or hand-edited index can
# never authorise a closure. Prints the permitted fm-decision-hold.sh command;
# never runs it. Closure remains the captain's authority.

cmd_closure_test() {
  [ "$#" -ge 1 ] || die "closure-test requires a hold id" 2
  local hold=$1 ruling='' line='' grade='' g root path dir class vout vtoken vline known text verbatim
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ruling) shift; ruling=${1:-} ;;
      --line) shift; line=${1:-} ;;
      --grade) shift; grade=${1:-} ;;
      *) die "unknown closure-test option: $1" 2 ;;
    esac
    shift
  done
  case "$hold" in
    ''|*[!A-Za-z0-9._-]*) die "hold id must be a privacy-safe slug: $hold" 2 ;;
  esac
  [ -n "$ruling" ] || die "--ruling is required" 2
  # The path is echoed back on `ruling_file=` for auditability, so it must not be
  # able to forge a line of this script's own output.
  case "$ruling" in
    *[[:cntrl:]]*) die "--ruling must not contain control characters" 2 ;;
  esac
  [ -n "$line" ] || die "--line is required" 2
  case "$line" in ''|*[!0-9]*) die "--line must be a line number: $line" 2 ;; esac
  [ -n "$grade" ] || die "--grade is required" 2
  known=0
  for g in $GRADES; do [ "$g" = "$grade" ] && known=1; done
  [ "$known" -eq 1 ] || die "--grade must be one of: $GRADES" 2

  root=$(resolve_data_root) || exit 1
  case "$ruling" in
    /*) path=$ruling ;;
    *) path="$root/$ruling" ;;
  esac

  printf 'schema=%s\n' "$SCHEMA_INDEX"
  printf 'hold_id=%s\n' "$hold"
  printf 'ruling_file=%s\n' "$ruling"
  printf 'ruling_line=%s\n' "$line"
  printf 'grade=%s\n' "$grade"

  # Corpus containment, enforced here and not only in build_ruling_inventory,
  # because THIS is the path that authorises a closure. Without it a caller
  # satisfies the captain's condition 1 with a ruling it authored anywhere on
  # disk, by absolute path or by `../` traversal. The directory is resolved
  # physically, so a symlinked path component cannot step outside either.
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || dir=''
  case "$dir" in
    "$root"|"$root"/*) : ;;
    *)
      printf 'closure=escalate\nreason=ruling-document-outside-corpus-root\n'
      return 0 ;;
  esac

  if [ -L "$path" ] || [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf 'closure=escalate\nreason=NO_RULING_READ\n'
    return 0
  fi

  class=$(doc_class "$path")
  printf 'doc_class=%s\n' "$class"

  # Condition 1: the named line names the hold identifier VERBATIM. A
  # paraphrase, a near-match, or a semantically equivalent identifier is not
  # verbatim and is not detected here by construction - this is a literal,
  # delimiter-bounded test against the exact line the caller cited, sharing the
  # index scan's pattern so a longer identifier that merely CONTAINS this one
  # cannot stand in for it.
  verbatim=no
  text=$(sed -n "${line}p" "$path" 2>/dev/null)
  if printf '%s\n' "$text" | grep -qE -- "$(hold_pattern "$hold")"; then
    verbatim=yes
  fi
  printf 'verbatim_identifier=%s\n' "$verbatim"

  # Condition 2: an explicit verdict token in the bounded window.
  vtoken=''
  vline=0
  if vout=$(verdict_in_window "$path" "$line"); then
    vline=${vout%%$'\t'*}
    vtoken=${vout#*$'\t'}
  fi
  printf 'verdict_token=%s\n' "${vtoken:-none}"
  printf 'verdict_line=%s\n' "$vline"

  if [ "$class" != ruling ]; then
    printf 'closure=escalate\nreason=not-a-ruling-document\n'
    return 0
  fi
  if [ "$verbatim" != yes ]; then
    printf 'closure=escalate\nreason=identifier-not-verbatim-on-cited-line\n'
    return 0
  fi
  if [ -z "$vtoken" ]; then
    printf 'closure=escalate\nreason=no-explicit-verdict-token\n'
    return 0
  fi
  if [ "$grade" != rules ]; then
    printf 'closure=escalate\nreason=grade-is-%s-not-rules\n' "$grade"
    return 0
  fi

  printf 'closure=permitted\n'
  printf 'provenance=%s:%s\n' "$ruling" "$line"
  printf 'command=bin/fm-decision-hold.sh resolve <origin-id> <decision-key> --decision-file <path> --routed-to <task-id> --from-ruling %s:%s\n' \
    "$ruling" "$line"
  printf 'note=this script never closes a hold; fm-decision-hold.sh performs the closure and re-verifies this provenance\n'
}

# --- status / schema --------------------------------------------------------

cmd_status() {
  [ -f "$INDEX/index.meta" ] || { printf 'verdict=absent\nindex=%s\n' "$INDEX"; return 0; }
  cat "$INDEX/index.meta"
  printf 'eligible_excerpts=%s\n' \
    "$(awk -F'\t' '$7 == "closable-if-graded-rules"' "$INDEX/matches.tsv" 2>/dev/null | grep -c . || true)"
}

cmd_schema() {
  cat <<EOF
$SCHEMA_INDEX

The derived index lives at \$FM_HOME/state/ruling-index and is rebuildable and
never authority. Delete it freely; the next scan reproduces it from the
canonical sources - the ruling documents and the backlog.

index.meta      key=value header
  schema, derived=true, authority=none, generated, corpus_root,
  hold_fingerprint        sha256 over holds.tsv
  ruling_fingerprint      sha256 over rulings.tsv
  open_holds, ruling_documents, verdict_window

holds.tsv       <hold-id>\t<state>            open captain holds, from tasks-axi
rulings.tsv     <rel-path>\t<class>\t<sha256>  class is ruling|commission|other
matches.tsv     <hold-id>\t<rel-path>\t<line>\t<class>\t<verdict-token>\t
                <verdict-line>\t<eligibility>\t<excerpt>

An unmatched hold gets one matches.tsv row with ruling_file=none and
eligibility=escalate. It is reported open, never dropped.

Invalidation: the index is current only when both fingerprints match and both
inventories are byte-identical. Any hold or ruling change forces a rescan.

Empty-set law: a ruling-class document that cannot be read yields
verdict=NO_RULING_READ and exit 3, and a tasks-axi hold listing that fails
yields verdict=NO_HOLD_READ and exit 3. No index is published in either case,
because "unmatched" must never rest on a ruling nobody read and open_holds=0
must never rest on a backlog nobody could list.
EOF
}

# --- entry ------------------------------------------------------------------

case "${1:-scan}" in
  -h|--help) usage; exit 0 ;;
  schema) cmd_schema ;;
  status) shift; cmd_status "$@" ;;
  propose) shift; cmd_propose "$@" ;;
  closure-test) shift; cmd_closure_test "$@" ;;
  scan) shift; cmd_scan "$@" ;;
  --rebuild|--quiet) cmd_scan "$@" ;;
  *) die "unknown command: $1 (see --help)" 2 ;;
esac
