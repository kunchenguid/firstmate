#!/usr/bin/env bash
# fm-research-scan.sh - deterministic, model-free prefilter over this home's
# scout-report corpus, plus the separate approval, implementation, and
# delivery evidence provers the research-approved-work skill needs.
#
# Why this exists: `data/**/report.md` in a working home is multi-megabyte, so
# re-reading it to answer "which approved work is still unimplemented?" costs a
# model context every time it is asked. This script answers the cheap part of
# that question with no model involvement at all: it inventories the corpus,
# fingerprints it, and reaches the `no_delta` terminal without extracting
# anything when nothing that could change the answer has changed.
#
# It never classifies work and never decides approval. It produces evidence;
# .agents/skills/research-approved-work/SKILL.md owns the classification
# procedure and is the single owner of the class definitions.
#
# The derived index lives under the home's existing volatile-state owner
# ($FM_HOME/state/research-index) and is content-addressed: a report's bounded
# extraction is stored under its own SHA-256, so identical or unchanged content
# is reused instead of re-read. Deleting the whole index is always safe; the
# next scan rebuilds it deterministically from the canonical sources. The index
# is derived, never authority: approval truth stays in the home's decision
# records and implementation truth stays in the repositories at HEAD.
#
# Usage:
#   fm-research-scan.sh [scan] [--rebuild]   inventory, diff, extract, write index
#   fm-research-scan.sh status               print the current index header only
#   fm-research-scan.sh show <key|sha256>    print one cached bounded extraction
#   fm-research-scan.sh evidence <ident> [--token <t>]... [--landing]
#                                            locate approval, implementation,
#                                            and delivery evidence SEPARATELY
#                                            for one identifier
#
# The evidence provers deliberately under-claim. They report that durable
# records MENTION an identifier, that repositories MATCH a token at HEAD, and
# that a pull request title or branch NAMES one - never that something was
# approved, implemented, or delivered. A commission asking an investigation to
# examine LC-R4 mentions it exactly as a ruling approving it would; "route="
# matches a local shell variable as readily as a recorded dispatch field. The
# skill reads the cited excerpts and named paths and makes those calls.
#   fm-research-scan.sh schema               print the derived-index schema
#   fm-research-scan.sh --help               print this usage
#
# Environment:
#   FM_HOME                   home whose data/ and state/ are used
#   FM_DATA_OVERRIDE          corpus root (default $FM_HOME/data)
#   FM_STATE_OVERRIDE         state root (default $FM_HOME/state)
#   FM_RESEARCH_MAX_BYTES     per-report read ceiling (default 262144)
#   FM_RESEARCH_MAX_HEADINGS  headings kept per report (default 80)
#   FM_RESEARCH_MAX_IDENTS    distinct identifiers kept per report (default 120)
#   FM_RESEARCH_MAX_DECISIONS decision-language excerpts per report (default 60)
#   FM_RESEARCH_EXCERPT_CHARS excerpt trim width (default 300)
#   FM_RESEARCH_PR_LIMIT      pull requests listed per repo with --landing (default 100)
#   FM_RESEARCH_NOW           fixed generation stamp (deterministic rebuilds)
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INDEX="$STATE/research-index"

SCHEMA_INDEX=fm-research-index.v1
SCHEMA_EXTRACT=fm-research-extract.v1

MAX_BYTES="${FM_RESEARCH_MAX_BYTES:-262144}"
MAX_HEADINGS="${FM_RESEARCH_MAX_HEADINGS:-80}"
MAX_IDENTS="${FM_RESEARCH_MAX_IDENTS:-120}"
MAX_DECISIONS="${FM_RESEARCH_MAX_DECISIONS:-60}"
EXCERPT_CHARS="${FM_RESEARCH_EXCERPT_CHARS:-300}"
PR_LIMIT="${FM_RESEARCH_PR_LIMIT:-100}"

# Identifier token shape, matched against whole tokens so no word-boundary
# escape is needed: ADR-0050, CAP-015, LC-R4, HKR-1, FM-9 all qualify.
IDENT_RE='[A-Z][A-Z0-9]{1,7}-R?[0-9]{1,4}'

# Decision language. Deliberately broad: this selects lines worth an excerpt,
# it does not decide anything.
DECISION_RE='approv|authoris|authoriz|ruled|ruling|reject|declin|defer|supersed|greenlit|green-lit|go-ahead|sign-off|signed off|do not build|not approved|no-go'

die() { printf 'fm-research-scan.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

# Work directory is global so the cleanup trap survives the function that
# created it.
WORK=
cleanup_work() { [ -n "$WORK" ] && rm -rf -- "$WORK"; WORK=; }
trap cleanup_work EXIT HUP INT TERM

usage() {
  sed -n '2,/^set -u$/p' "$SELF_DIR/fm-research-scan.sh" | sed 's/^# \{0,1\}//; $d'
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

file_bytes() {  # <path>
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

now_stamp() {
  if [ -n "${FM_RESEARCH_NOW:-}" ]; then
    printf '%s\n' "$FM_RESEARCH_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# --- scope enforcement ------------------------------------------------------
#
# Every path this script reads must be a regular file physically inside the
# resolved corpus root. `find` without -L already refuses to descend symlinked
# directories; the explicit containment check below is the enforced boundary
# so an escape is refused and reported rather than silently read.

resolve_data_root() {
  [ -e "$DATA" ] || die "corpus root is absent: $DATA"
  [ ! -L "$DATA" ] || die "corpus root must not be a symlink: $DATA"
  [ -d "$DATA" ] || die "corpus root is not a directory: $DATA"
  (cd "$DATA" && pwd -P)
}

in_scope() {  # <path> <resolved-root>
  local path=$1 root=$2 dir
  [ -L "$path" ] && return 1
  [ -f "$path" ] || return 1
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  case "$dir" in
    "$root") return 0 ;;
    "$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- fingerprints -----------------------------------------------------------
#
# The index is invalidated by any of three independent inputs, because any one
# of them can change the answer: the report corpus, the durable decision
# evidence, and the implementation HEADs.

decision_sources() {  # <resolved-root>
  local root=$1
  {
    find "$root" -maxdepth 1 -type f -name '*.md' \
      \( -name '*ruling*' -o -name '*commission*' -o -name 'decision*' \
         -o -name 'backlog.md' -o -name 'done-archive.md' -o -name 'note-archive.md' \) -print
    find "$root" -mindepth 2 -maxdepth 2 -type f -name 'commission.md' -print
  } 2>/dev/null | LC_ALL=C sort
}

decision_fingerprint() {  # <resolved-root>
  local root=$1 f h
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    h=$(sha256_file "$f") || h=unreadable
    printf '%s\t%s\n' "${f#"$root"/}" "$h"
  done < <(decision_sources "$root") | sha256_stdin
}

# Repositories whose HEAD can turn "unimplemented" into "implemented": this
# firstmate checkout plus every project clone in the home.
implementation_repos() {
  local p
  if [ -e "$FM_ROOT/.git" ]; then
    printf '%s\n' "$FM_ROOT"
  fi
  for p in "$FM_HOME"/projects/*; do
    [ -d "$p" ] || continue
    [ -e "$p/.git" ] || continue
    printf '%s\n' "$p"
  done
}

head_fingerprint() {
  local repo head
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    head=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || head=unknown
    printf '%s\t%s\n' "$(basename "$repo")" "$head"
  done < <(implementation_repos) | LC_ALL=C sort | sha256_stdin
}

# --- bounded extraction -----------------------------------------------------
#
# Reads at most MAX_BYTES of a report and emits a capped, line-trimmed
# projection. A malformed, binary, or single-enormous-line report cannot push
# this past the ceiling: the byte ceiling is applied before any parsing and
# every emitted line is trimmed.

extract_report() {  # <path> <out-file>
  local path=$1 out=$2 bytes truncated=0 body
  bytes=$(file_bytes "$path")
  [ "${bytes:-0}" -gt "$MAX_BYTES" ] && truncated=1
  body=$(mktemp "${TMPDIR:-/tmp}/fm-research-body.XXXXXX") || return 1
  head -c "$MAX_BYTES" "$path" 2>/dev/null | tr -d '\000' > "$body" || true

  {
    printf '# schema %s\n' "$SCHEMA_EXTRACT"
    printf '# source_bytes=%s read_bytes=%s truncated=%s\n' \
      "${bytes:-0}" "$(file_bytes "$body")" "$truncated"

    grep -aE '^#{1,6}[[:space:]]' "$body" 2>/dev/null \
      | head -n "$MAX_HEADINGS" \
      | cut -c "1-$EXCERPT_CHARS" \
      | sed 's/^/[heading] /'

    tr -c 'A-Za-z0-9-' '\n' < "$body" 2>/dev/null \
      | grep -xE "$IDENT_RE" 2>/dev/null \
      | LC_ALL=C sort -u \
      | head -n "$MAX_IDENTS" \
      | sed 's/^/[ident] /'

    grep -anEi "$DECISION_RE" "$body" 2>/dev/null \
      | head -n "$MAX_DECISIONS" \
      | cut -c "1-$EXCERPT_CHARS" \
      | sed 's/^/[decision] /'
  } > "$out" 2>/dev/null
  rm -f -- "$body"
}

# --- scan -------------------------------------------------------------------

cmd_scan() {
  local rebuild=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rebuild) rebuild=1 ;;
      *) die "unknown scan option: $1" 2 ;;
    esac
    shift
  done

  local root
  root=$(resolve_data_root) || exit 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state root is unavailable: $STATE"

  local tmp
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-research-scan.XXXXXX") || die "cannot create work directory"
  tmp=$WORK

  # 1. Inventory, with scope refusals recorded rather than silently dropped.
  local path rel bytes sha refused=0
  : > "$tmp/reports.tsv"
  : > "$tmp/refused.tsv"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! in_scope "$path" "$root"; then
      printf '%s\t%s\n' "${path#"$root"/}" out-of-scope >> "$tmp/refused.tsv"
      refused=$((refused + 1))
      continue
    fi
    rel=${path#"$root"/}
    bytes=$(file_bytes "$path")
    sha=$(sha256_file "$path") || die "sha256 (shasum or sha256sum) is required"
    printf '%s\t%s\t%s\n' "$rel" "${bytes:-0}" "$sha" >> "$tmp/reports.tsv"
  done < <(find "$root" -mindepth 1 -name 'report.md' \( -type f -o -type l \) -print 2>/dev/null | LC_ALL=C sort)

  LC_ALL=C sort -o "$tmp/reports.tsv" "$tmp/reports.tsv"
  LC_ALL=C sort -o "$tmp/refused.tsv" "$tmp/refused.tsv"

  local corpus_fp decision_fp head_fp total_bytes report_n
  corpus_fp=$(sha256_stdin < "$tmp/reports.tsv")
  decision_fp=$(decision_fingerprint "$root")
  head_fp=$(head_fingerprint)
  report_n=$(wc -l < "$tmp/reports.tsv" | tr -d ' ')
  total_bytes=$(awk -F'\t' '{s+=$2} END {printf "%d", s+0}' "$tmp/reports.tsv")

  # 2. The no_delta terminal. Reached before any report is opened, so an
  #    unchanged corpus costs one directory walk and no extraction at all.
  if [ "$rebuild" -eq 0 ] && index_is_current "$corpus_fp" "$decision_fp" "$head_fp" "$tmp/reports.tsv"; then
    printf 'schema=%s\n' "$SCHEMA_INDEX"
    printf 'verdict=no_delta\n'
    printf 'reports=%s\n' "$report_n"
    printf 'corpus_bytes=%s\n' "$total_bytes"
    printf 'extracted=0\n'
    printf 'reused=%s\n' "$report_n"
    printf 'reports_reopened=0\n'
    printf 'index=%s\n' "$INDEX"
    return 0
  fi

  # 3. Extraction, content-addressed. A report whose bytes are unchanged
  #    already has its extraction under that SHA and is never reopened.
  mkdir -p "$INDEX/extract" || die "cannot create index directory: $INDEX"
  local extracted=0 reused=0
  : > "$tmp/changed.tsv"
  while IFS=$'\t' read -r rel bytes sha; do
    [ -n "$rel" ] || continue
    if [ -s "$INDEX/extract/$sha.txt" ]; then
      reused=$((reused + 1))
      continue
    fi
    extract_report "$root/$rel" "$INDEX/extract/$sha.txt" || die "extraction failed: $rel"
    extracted=$((extracted + 1))
    printf '%s\t%s\n' "$rel" "$sha" >> "$tmp/changed.tsv"
  done < "$tmp/reports.tsv"

  # 4. Identifier map and duplicate grouping, both derived from the bounded
  #    extractions rather than from the reports.
  : > "$tmp/idents.tsv"
  while IFS=$'\t' read -r rel bytes sha; do
    [ -n "$rel" ] || continue
    sed -n 's/^\[ident\] //p' "$INDEX/extract/$sha.txt" 2>/dev/null \
      | while IFS= read -r id; do
          [ -n "$id" ] && printf '%s\t%s\n' "$id" "$rel"
        done
  done < "$tmp/reports.tsv" >> "$tmp/idents.tsv"
  LC_ALL=C sort -u -o "$tmp/idents.tsv" "$tmp/idents.tsv"

  group_duplicates "$tmp/reports.tsv" "$tmp/idents.tsv" > "$tmp/duplicates.tsv"

  # 5. Publish. Written whole so a partial index is never left behind.
  cp "$tmp/reports.tsv" "$INDEX/reports.tsv"
  cp "$tmp/idents.tsv" "$INDEX/idents.tsv"
  cp "$tmp/duplicates.tsv" "$INDEX/duplicates.tsv"
  cp "$tmp/refused.tsv" "$INDEX/refused.tsv"
  {
    printf 'schema=%s\n' "$SCHEMA_INDEX"
    printf 'derived=true\n'
    printf 'authority=none\n'
    printf 'generated=%s\n' "$(now_stamp)"
    printf 'corpus_root=%s\n' "$root"
    printf 'corpus_fingerprint=%s\n' "$corpus_fp"
    printf 'decision_fingerprint=%s\n' "$decision_fp"
    printf 'head_fingerprint=%s\n' "$head_fp"
    printf 'reports=%s\n' "$report_n"
    printf 'corpus_bytes=%s\n' "$total_bytes"
    printf 'max_bytes_per_report=%s\n' "$MAX_BYTES"
  } > "$INDEX/index.meta"

  printf 'schema=%s\n' "$SCHEMA_INDEX"
  printf 'verdict=delta\n'
  printf 'reports=%s\n' "$report_n"
  printf 'corpus_bytes=%s\n' "$total_bytes"
  printf 'extracted=%s\n' "$extracted"
  printf 'reused=%s\n' "$reused"
  printf 'reports_reopened=%s\n' "$extracted"
  printf 'refused_out_of_scope=%s\n' "$refused"
  printf 'duplicate_groups=%s\n' "$(cut -f1 "$tmp/duplicates.tsv" | LC_ALL=C sort -u | grep -c . || true)"
  printf 'index=%s\n' "$INDEX"
  local r
  while IFS=$'\t' read -r rel sha; do
    [ -n "$rel" ] && printf 'changed=%s\n' "$rel"
  done < "$tmp/changed.tsv"
  while IFS=$'\t' read -r r _; do
    [ -n "$r" ] && printf 'refused=%s\n' "$r"
  done < "$tmp/refused.tsv"
}

index_is_current() {  # <corpus-fp> <decision-fp> <head-fp> <fresh-reports.tsv>
  local corpus_fp=$1 decision_fp=$2 head_fp=$3 fresh=$4 sha
  [ -f "$INDEX/index.meta" ] || return 1
  [ -f "$INDEX/reports.tsv" ] || return 1
  grep -qxF "schema=$SCHEMA_INDEX" "$INDEX/index.meta" || return 1
  grep -qxF "corpus_fingerprint=$corpus_fp" "$INDEX/index.meta" || return 1
  grep -qxF "decision_fingerprint=$decision_fp" "$INDEX/index.meta" || return 1
  grep -qxF "head_fingerprint=$head_fp" "$INDEX/index.meta" || return 1
  cmp -s "$fresh" "$INDEX/reports.tsv" || return 1
  # Every referenced extraction must still be present, so a hand-deleted
  # cache entry rebuilds instead of reading as current.
  while IFS=$'\t' read -r _ _ sha; do
    [ -n "$sha" ] || continue
    [ -s "$INDEX/extract/$sha.txt" ] || return 1
  done < "$INDEX/reports.tsv"
  return 0
}

# Likely-duplicate grouping over REPORTS. Identical bytes form an exact group.
# Beyond that two reports are grouped only when they share at least three
# identifiers AND those account for most of the smaller report's identifier
# set, because a bare shared-count threshold pairs almost every report in a
# corpus with a house-wide identifier vocabulary. This is a cheap deterministic
# signal for a human to check, never a semantic judgement.
DUP_MIN_SHARED=3
DUP_MIN_PERCENT=60

group_duplicates() {  # <reports.tsv> <idents.tsv>
  awk -F'\t' -v min_shared="$DUP_MIN_SHARED" -v min_pct="$DUP_MIN_PERCENT" '
    # reports.tsv: <report-key> <bytes> <sha256>
    FNR==NR {
      if ($3 != "") { members[$3] = members[$3] (members[$3] ? SUBSEP : "") $1; n[$3]++ }
      next
    }
    # idents.tsv: <identifier> <report-key>
    { set[$2] = set[$2] (set[$2] ? SUBSEP : "") $1 }
    END {
      for (sha in members) if (n[sha] > 1) {
        c = split(members[sha], m, SUBSEP)
        for (i = 1; i <= c; i++) printf "exact:%s\t%s\n", substr(sha, 1, 12), m[i]
      }
      for (a in set) {
        na = split(set[a], ia, SUBSEP)
        split("", seen)
        for (i = 1; i <= na; i++) seen[ia[i]] = 1
        for (b in set) {
          if (a >= b) continue
          nb = split(set[b], ib, SUBSEP)
          shared = 0
          for (j = 1; j <= nb; j++) if (ib[j] in seen) shared++
          smaller = (na < nb) ? na : nb
          if (shared >= min_shared && smaller > 0 && shared * 100 >= smaller * min_pct) {
            printf "shared:%s|%s\t%s\n", a, b, a
            printf "shared:%s|%s\t%s\n", a, b, b
          }
        }
      }
    }
  ' "$1" "$2" | LC_ALL=C sort -u
}

# --- status / show ----------------------------------------------------------

cmd_status() {
  [ -f "$INDEX/index.meta" ] || { printf 'verdict=absent\nindex=%s\n' "$INDEX"; return 0; }
  cat "$INDEX/index.meta"
  printf 'identifiers=%s\n' "$(cut -f1 "$INDEX/idents.tsv" 2>/dev/null | LC_ALL=C sort -u | grep -c . || true)"
}

cmd_show() {  # <key|sha256>
  [ "$#" -eq 1 ] || die "show requires one report key or sha256" 2
  local want=$1 sha
  if [ -s "$INDEX/extract/$want.txt" ]; then
    cat "$INDEX/extract/$want.txt"
    return 0
  fi
  sha=$(awk -F'\t' -v k="$want" '$1 == k {print $3; exit}' "$INDEX/reports.tsv" 2>/dev/null)
  [ -n "$sha" ] || die "no cached extraction for: $want"
  cat "$INDEX/extract/$sha.txt"
}

# --- evidence ---------------------------------------------------------------
#
# Approval and implementation are proven SEPARATELY and reported separately.
# Neither prover is allowed to answer the other's question, and neither emits a
# classification: absence of durable approval evidence is reported as absence,
# never as "never approved", because this home's own record shows approvals
# that were given only as a chat instruction and left no durable trace.

cmd_evidence() {
  [ "$#" -ge 1 ] || die "evidence requires an identifier" 2
  local ident=$1 landing=0
  shift
  local -a tokens=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --token)
        [ "$#" -gt 1 ] || die "--token requires a value" 2
        tokens+=("$2"); shift ;;
      --token=*) tokens+=("${1#--token=}") ;;
      --landing) landing=1 ;;
      *) die "unknown evidence option: $1" 2 ;;
    esac
    shift
  done

  local root
  root=$(resolve_data_root) || exit 1

  printf 'identifier=%s\n' "$ident"

  # Approval prover: durable decision records only.
  local swept=0 hits=0 src line
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    swept=$((swept + 1))
    printf 'approval_source_swept=%s\n' "${src#"$root"/}"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      hits=$((hits + 1))
      printf 'approval_hit=%s\t%s\n' "${src#"$root"/}" "$(printf '%s' "$line" | cut -c "1-$EXCERPT_CHARS")"
    done < <(grep -nF -- "$ident" "$src" 2>/dev/null | head -n "$MAX_DECISIONS")
  done < <(decision_sources "$root")

  printf 'approval_sources_swept=%s\n' "$swept"
  # A mention is not an approval. A commission that asks an investigation to
  # examine an identifier mentions it exactly as a ruling that approves it
  # does, so this prover reports mentions and the caller judges each excerpt.
  if [ "$hits" -gt 0 ]; then
    printf 'approval=mentions-found\n'
  else
    printf 'approval=no-mentions-in-durable-sources\n'
  fi
  printf 'approval_caveat=a mention is not an approval; read each excerpt. Absence is not disproof: chat approvals leave no durable record\n'

  # Implementation prover: independent, multi-signal, over code at HEAD.
  # Refuses to conclude from fewer than two search tokens, so "not
  # implemented" can never rest on one absent name.
  # Each signal reports how many tracked files match at HEAD and names the
  # first few, because a textual match is not an implementation: a token like
  # "route=" matches an unrelated shell variable assignment just as readily as
  # the recorded field the recommendation asked for. The caller judges the
  # named paths; this prover only locates them.
  local repo tok files match signals=0 positive=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    for tok in "$ident" ${tokens+"${tokens[@]}"}; do
      files=$(git -C "$repo" grep -lF -- "$tok" HEAD 2>/dev/null | wc -l | tr -d ' ')
      printf 'impl_signal=%s\t%s\tfiles=%s\n' "$(basename "$repo")" "$tok" "${files:-0}"
      while IFS= read -r match; do
        [ -n "$match" ] || continue
        printf 'impl_match=%s\t%s\t%s\n' "$(basename "$repo")" "$tok" "${match#HEAD:}"
      done < <(git -C "$repo" grep -lF -- "$tok" HEAD 2>/dev/null | head -n 5)
      [ "${files:-0}" -gt 0 ] && positive=$((positive + 1))
      signals=$((signals + 1))
    done
  done < <(implementation_repos)

  printf 'impl_tokens=%s\n' "${#tokens[@]}"
  printf 'impl_signals=%s\n' "$signals"
  if [ "$positive" -gt 0 ]; then
    printf 'implementation=matches-at-head\n'
    printf 'implementation_caveat=a textual match is not an implementation; check the named paths\n'
  elif [ "${#tokens[@]}" -lt 2 ]; then
    printf 'implementation=insufficient-signals\n'
    printf 'implementation_note=supply at least two --token artifacts before concluding absence\n'
  else
    printf 'implementation=no-matches-at-head\n'
  fi

  # Landing prover: opt-in and networked, because finished work can be
  # delivered in an unmerged pull request and absent from every HEAD.
  if [ "$landing" -eq 1 ]; then
    emit_landing_evidence "$ident" ${tokens+"${tokens[@]}"}
  else
    printf 'landing=not-checked\n'
  fi
}

emit_landing_evidence() {  # <ident> [token...]
  local ident=$1 repo out tok found=0 listed=0 failed=0
  shift
  if ! command -v gh-axi >/dev/null 2>&1; then
    printf 'landing=unavailable-gh-axi-missing\n'
    return 0
  fi
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    # No --fields: the default listing already carries number, title, and
    # state, and a rejected field list would fail the whole call. A failed
    # listing must never be reported as an absence of delivery.
    if ! out=$( (cd "$repo" && gh-axi pr list --state all --limit "$PR_LIMIT") 2>&1 ); then
      printf 'landing_error=%s\t%s\n' "$(basename "$repo")" \
        "$(printf '%s' "$out" | head -n1 | cut -c "1-$EXCERPT_CHARS")"
      failed=$((failed + 1))
      continue
    fi
    listed=$((listed + $(printf '%s\n' "$out" | grep -cE '^ +[0-9]+,' || true)))
    for tok in "$ident" "$@"; do
      [ -n "$tok" ] || continue
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        found=$((found + 1))
        printf 'landing_hit=%s\t%s\t%s\n' "$(basename "$repo")" "$tok" \
          "$(printf '%s' "$line" | cut -c "1-$EXCERPT_CHARS")"
      done < <(printf '%s\n' "$out" | grep -iF -- "$tok" 2>/dev/null | head -n 20)
    done
  done < <(implementation_repos)
  # Titles are all this sees, across a bounded recent window. Work delivered
  # in a pull request whose title names neither the identifier nor a token is
  # invisible here, so a negative is never proof that nothing was delivered.
  printf 'landing_listed=%s\n' "$listed"
  if [ "$failed" -gt 0 ] && [ "$found" -eq 0 ]; then
    printf 'landing=unavailable-listing-failed\n'
  elif [ "$found" -gt 0 ]; then
    printf 'landing=title-match\n'
  else
    printf 'landing=no-title-match\n'
    printf 'landing_caveat=only the %s most recent pull request titles were searched; delivery can exist without naming the identifier\n' "$PR_LIMIT"
  fi
}

# --- schema -----------------------------------------------------------------

cmd_schema() {
  cat <<EOF
$SCHEMA_INDEX

The derived index lives at \$FM_HOME/state/research-index and is rebuildable,
content-addressed, and never authority. Delete it freely; the next scan
reproduces it byte-for-byte from the canonical sources.

index.meta      key=value header
  schema, derived=true, authority=none, generated, corpus_root,
  corpus_fingerprint      sha256 over reports.tsv
  decision_fingerprint    sha256 over the durable decision-record inventory
  head_fingerprint        sha256 over every implementation repository HEAD
  reports, corpus_bytes, max_bytes_per_report

reports.tsv     <report-key>\t<bytes>\t<sha256>   one row per in-scope report
idents.tsv      <identifier>\t<report-key>        which reports mention which
duplicates.tsv  <group>\t<report-key>             exact:<sha> or shared:<a>|<b>
refused.tsv     <path>\t<reason>                  out-of-scope paths, not read
extract/<sha256>.txt                              bounded projection, $SCHEMA_EXTRACT

$SCHEMA_EXTRACT lines
  # schema / # source_bytes= read_bytes= truncated=
  [heading] <text>            at most FM_RESEARCH_MAX_HEADINGS
  [ident] <ID>                at most FM_RESEARCH_MAX_IDENTS, sorted, unique
  [decision] <line>: <text>   at most FM_RESEARCH_MAX_DECISIONS

Invalidation: the index is current only when all three fingerprints match and
every referenced extraction is present. Any corpus, decision-record, or
implementation-HEAD change forces a rescan.
EOF
}

# --- entry ------------------------------------------------------------------

case "${1:-scan}" in
  -h|--help) usage; exit 0 ;;
  schema) cmd_schema ;;
  status) shift; cmd_status "$@" ;;
  show) shift; cmd_show "$@" ;;
  evidence) shift; cmd_evidence "$@" ;;
  scan) shift; cmd_scan "$@" ;;
  --rebuild) cmd_scan "$@" ;;
  *) die "unknown command: $1 (see --help)" 2 ;;
esac
