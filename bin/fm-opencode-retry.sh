#!/usr/bin/env bash
# fm-opencode-retry.sh - the ONE owner of OpenCode retry-backoff evidence.
#
# Why this exists: a usage-capped opencode lane does NOT fail. OpenCode holds
# the session in `session.status` type `retry` and re-schedules forever (no
# max attempt; verified against the vendor schema and the 2026-09-07 twelve-
# lane stall), while firstmate's own plugin still reports busy and supervision
# reads `working` for the whole ~22h backoff. Nothing in any status log says
# otherwise, so the cap is invisible to supervision.
#
# The detector is structural, never banner text. The vendor's retry Info is a
# closed shape `{type:"retry", attempt:int, message:str, next:epoch-ms}` (see
# docs/verification/supervision.md for the dated schema evidence). `next` is
# the vendor's own scheduled-retry timestamp, so `next - now` IS the backoff
# horizon with no vendor string involved: transient rate-limit backoff is
# seconds (the vendor caps its own schedule at 30s absent a Retry-After
# header), while a quota/usage cap parks the lane for hours. A horizon longer
# than FM_OPENCODE_RETRY_BLOCK_SECS (default 600) therefore reads as a
# quota-scale block, and anything shorter keeps the existing working verdict.
#
# Sidecar: state/<id>.opencode-retry - exactly one line, atomically replaced
# by the spawn-installed plugin on every retry status event:
#
#   v1 attempt=<uint> next=<epoch-ms> ts=<epoch-s> [model=<id>] [session=<sid>]
#
# `ts` is when the plugin observed the event; `next` bounds the sidecar's own
# validity (see check). The record is written only for the latched worker
# session and cleared on idle, so a previous turn's backoff can never brand a
# resumed turn. As a second guard, bin/fm-crew-state.sh only consults this
# file while the busy record's own event is still `session-retry`: a genuinely
# resumed turn writes `session-busy` first, which drops the blocked verdict
# even if a stale sidecar survives.
#
# THE IDLE SHAPE (2026-09-14: four of five capped lanes were invisible).
# A lane that takes the provider error and ends its turn goes idle: the plugin
# writes the idle busy event and clears the sidecar (or no retry status event
# ever fired for it), so the structural sidecar above says nothing while the
# pane's own rendered text still carries the cap verbatim:
#   Free usage exceeded, subscribe to Go [retrying in 35s attempt #5]
# The sidecar-only detector therefore answers OPEN for a dead rung, and the
# dispatch gate plus the descent go blind together. The idle shape is detected
# off that rendered text, through scan-text below - the pane is the only
# evidence left, and reading it here keeps this file the ONE detector rather
# than growing a second one beside it.
#
# Rendered text wraps, so matching is never a long string: the text is
# lowercased with every whitespace run collapsed to one space, then compared
# against short distinctive phrases only (`free usage exceeded`,
# `subscribe to go`). A wrap can split those phrases across rendered lines and
# the normalization rejoins them; a vendor rephrase defeats them, which then
# reads as unknown rather than open (see the three states below).
#
# `Rate limit exceeded` is DELIBERATELY not a cap phrase. It was seen beside
# the free-tier phrase in the same incident, but on its own it is generic: a
# transient per-minute throttle renders the same way, and text alone carries
# no horizon to tell the two apart the way the sidecar's `next` timestamp
# does. Matching it would descend working lanes onto the paid rung and spend
# the captain's money for nothing - the one false positive this detector must
# not produce. A lane showing only the generic phrase stays unknown.
#
# Callers capture the lane's tail themselves (last 60 lines,
# FM_OPENCODE_CAP_TEXT_LINES) and hand it in as a file, so this helper stays
# dependency-free and the fixture is a text file rather than burnt quota.
# An unreadable or empty capture is unknown, never open.
#
# THREE STATES, NOT TWO. verdict answers capped, open, or unknown as separate
# words, because absence of retry evidence used to render as "the rung is
# fine" when it actually meant "no idea". capped carries positive evidence
# from either source; open requires a fresh non-empty capture with no cap
# phrase and no blocking sidecar; everything else is unknown. On unknown the
# dispatch gate still dispatches free: the captain's standing position is that
# missing evidence must not stall the fleet, and that choice is documented at
# the gate rather than hidden inside this detector.
#
# Subcommands:
#
#   record <state-dir> <id> <attempt> <next-ms> [model] [session]
#       Validate and atomically store one retry observation. Non-numeric
#       attempt/next, or a model/session outside the token charset, is refused
#       (exit 1): on vendor shape drift this degrades to the old behavior
#       (no sidecar, lane still reads working) rather than a false blocked.
#       A model or session of `-` or empty is stored as absent.
#
#   clear <state-dir> <id>
#       Remove the sidecar. Best-effort hygiene called on idle; always exits 0
#       so a missing file never breaks the plugin's lifecycle.
#
#   check <state-dir> <id> [--text-file <path>]
#       Classify the stored observation. Prints one line:
#         status=<blocked|waiting> attempt=<n> horizon_s=<s> [model=<id>]
#       Exit 0 when the sidecar is present, well-formed, and unexpired;
#       exit 1 when it is absent, malformed, or expired (the scheduled retry
#       time plus FM_OPENCODE_RETRY_STALE_SECS grace has passed, so the file
#       no longer describes the present). `blocked` iff horizon_s exceeds
#       FM_OPENCODE_RETRY_BLOCK_SECS. With --text-file, a sidecar miss falls
#       through to the idle shape: a cap phrase in the captured text prints
#         status=blocked source=text match=<slug> episode=text-<fp>
#       (no horizon_s: an idle lane's bracketed retry duration is not a
#       trustworthy horizon, so none is claimed) and exits 0; clean or
#       unreadable text still exits 1. Without the flag this is byte-for-byte
#       the old sidecar-only contract.
#
#   scan-text [--file <path>]
#       Classify rendered pane text alone (file, or stdin when --file is
#       absent). Prints `status=blocked source=text match=<slug>
#       episode=text-<fp>` and exits 0 on a cap-phrase match, exits 1
#       otherwise (clean, empty, or unreadable). <slug> is
#       free-usage-exceeded or subscribe-to-go; episode is the text-evidence
#       episode identity (see scan_stream).
#
#   verdict <state-dir> <id> [--text-file <path>]
#       The honest three-state answer. Always prints one line and exits 0:
#         verdict=capped evidence=sidecar status=blocked attempt=<n>
#           horizon_s=<s> [model=<id>]      a blocking sidecar, as check reads it
#         verdict=capped evidence=text match=<slug> episode=text-<fp>
#                                          no blocking sidecar, but the capture
#                                          carries the cap verbatim
#         verdict=open evidence=text-clean
#                                          a fresh non-empty capture with no cap
#                                          phrase and no blocking sidecar
#         verdict=unknown reason=<slug>
#                                          no blocking sidecar and no usable
#                                          capture. <slug> is no-evidence,
#                                          unreadable-text, transient-backoff
#                                          (a live but short-horizon sidecar),
#                                          or expired-evidence. Unknown is not
#                                          open: callers decide what an
#                                          absence may license, and the dispatch
#                                          gate documents allowing it.
#
# Environment:
#   FM_OPENCODE_RETRY_BLOCK_SECS   horizon above which a retry reads as a
#                                  quota-scale block (default 600)
#   FM_OPENCODE_RETRY_STALE_SECS   grace after the scheduled retry time during
#                                  which the sidecar still describes the
#                                  present (default 600)
#
# Exit codes: 0 classified/recorded/cleared; 1 refused or nothing to classify;
# 2 usage. All plugin invocations swallow failures so supervision evidence can
# never break the harness's own lifecycle.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-opencode-retry.sh record <state-dir> <id> <attempt> <next-ms> [model] [session]
  fm-opencode-retry.sh clear <state-dir> <id>
  fm-opencode-retry.sh check <state-dir> <id> [--text-file <path>]
  fm-opencode-retry.sh scan-text [--file <path>]
  fm-opencode-retry.sh verdict <state-dir> <id> [--text-file <path>]
See the header comment for the full contract.
EOF
  exit 2
}

BLOCK_SECS=${FM_OPENCODE_RETRY_BLOCK_SECS:-600}
case "$BLOCK_SECS" in ''|*[!0-9]*) BLOCK_SECS=600 ;; esac
STALE_SECS=${FM_OPENCODE_RETRY_STALE_SECS:-600}
case "$STALE_SECS" in ''|*[!0-9]*) STALE_SECS=600 ;; esac

# Cap phrases, lowercase single-spaced: the matcher normalizes rendered text
# into this shape before comparing, so a wrap can never split a match.
# `Rate limit exceeded` is absent on purpose (see the header).
cap_phrase_slug() {  # <normalized-text> -> slug, or failure
  case "$1" in
    *'free usage exceeded'*) printf 'free-usage-exceeded'; return 0 ;;
  esac
  case "$1" in
    *'subscribe to go'*) printf 'subscribe-to-go'; return 0 ;;
  esac
  return 1
}

# normalize_stream: lowercase stdin with every whitespace run collapsed to one
# space, on a single line. Rendered wraps rejoin; an empty stream stays empty.
normalize_stream() {
  tr '[:upper:]' '[:lower:]' 2>/dev/null | tr '\n\t\r' '   ' | tr -s ' '
}

# scan_stream: 0 with `status=blocked source=text match=<slug>
# episode=text-<fp>` on stdout when stdin carries a cap phrase, 1 otherwise.
# Empty input never matches. <fp> fingerprints the normalized capture with
# digits stripped, so a ticking retry countdown or attempt counter cannot mint
# a new episode every poll while genuinely new output re-arms it; callers use
# it as the cap-episode identity for text-only evidence, exactly as the
# sidecar's `next` timestamp identifies a structural episode.
scan_stream() {
  local norm slug fp
  norm=$(normalize_stream) || return 1
  case "$norm" in ''|' ') return 1 ;; esac
  slug=$(cap_phrase_slug "$norm") || return 1
  fp=$(printf '%s' "$norm" | tr -d '0-9' 2>/dev/null | cksum 2>/dev/null | awk '{print $1}')
  case "$fp" in ''|*[!0-9]*) fp=0 ;; esac
  printf 'status=blocked source=text match=%s episode=text-%s\n' "$slug" "$fp"
}

CMD=${1:-}
case "$CMD" in
  record|clear|check|verdict|scan-text) shift ;;
  *) usage ;;
esac

if [ "$CMD" = scan-text ]; then
  TEXT_FILE=
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) TEXT_FILE=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  if [ -n "$TEXT_FILE" ]; then
    [ -f "$TEXT_FILE" ] || exit 1
    scan_stream < "$TEXT_FILE" 2>/dev/null || exit 1
  else
    scan_stream || exit 1
  fi
  exit 0
fi

STATE=${1:-}
ID=${2:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
case "$ID" in *[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

# --text-file is honored by check and verdict only; record and clear take no
# flags, and anything else here is usage.
TEXT_FILE=
if [ "$CMD" = check ] || [ "$CMD" = verdict ]; then
  case "${3:-}" in
    '') ;;
    --text-file)
      TEXT_FILE=${4:-}
      [ -n "$TEXT_FILE" ] || usage
      [ -z "${5:-}" ] || usage
      ;;
    *) usage ;;
  esac
else
  case "${3:-}" in
    --text-file|--file) usage ;;
  esac
fi

REC="$STATE/$ID.opencode-retry"

# Model ids carry a provider prefix with a slash (e.g.
# opencode-go/muse-spark-1.3-contributor); session ids are plain tokens.
# Anything else (spaces, quotes, shell metacharacters) is refused.
token_valid() {  # <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._/:-]*) return 1 ;;
  esac
  return 0
}

if [ "$CMD" = clear ]; then
  rm -f "$REC"
  exit 0
fi

if [ "$CMD" = record ]; then
  ATTEMPT=${3:-}
  NEXT_MS=${4:-}
  MODEL=${5:-}
  SESSION=${6:-}
  case "$ATTEMPT" in ''|*[!0-9]*) echo "error: invalid attempt: $ATTEMPT" >&2; exit 1 ;; esac
  case "$NEXT_MS" in ''|*[!0-9]*) echo "error: invalid next: $NEXT_MS" >&2; exit 1 ;; esac
  case "$MODEL" in ''|-) MODEL= ;; *) token_valid "$MODEL" || { echo "error: invalid model" >&2; exit 1; } ;; esac
  case "$SESSION" in ''|-) SESSION= ;; *) token_valid "$SESSION" || { echo "error: invalid session" >&2; exit 1; } ;; esac
  old_umask=$(umask)
  umask 077
  tmp="$REC.tmp.$$"
  {
    printf 'v1 attempt=%s next=%s ts=%s' "$ATTEMPT" "$NEXT_MS" "$(date +%s)"
    [ -n "$MODEL" ] && printf ' model=%s' "$MODEL"
    [ -n "$SESSION" ] && printf ' session=%s' "$SESSION"
    printf '\n'
  } > "$tmp" || { rm -f "$tmp"; umask "$old_umask"; echo "error: record write failed for $ID" >&2; exit 1; }
  mv -f "$tmp" "$REC" || { rm -f "$tmp"; umask "$old_umask"; echo "error: record write failed for $ID" >&2; exit 1; }
  umask "$old_umask"
  exit 0
fi

# sidecar_check: classify the stored observation exactly as check always has.
# Prints the classification line (`status=blocked|waiting ...`) and returns 0
# whenever the sidecar is present, well-formed, and unexpired; returns 1 with
# SIDE_STATUS set to absent|malformed|expired when there is nothing to report,
# so verdict can name the reason honestly instead of guessing. SIDE_STATUS is
# blocked|waiting on success, mirroring the printed status for callers that
# must tell a quota-scale sidecar from a transient one without re-parsing.
SIDE_STATUS=
sidecar_check() {
  local line extra ver attempt='' next='' model='' session='' f
  local -a fields
  SIDE_STATUS=absent
  [ -f "$REC" ] || return 1
  SIDE_STATUS=malformed
  # Exactly one line; a second line (or an unreadable file) is malformed.
  # shellcheck disable=SC2034 # extra exists only to prove the record is one line
  { IFS= read -r line && ! IFS= read -r extra; } < "$REC" 2>/dev/null || return 1
  [ -n "$line" ] || return 1
  # `read -a` never glob-expands a field and never touches positional params.
  # shellcheck disable=SC3045
  IFS=' ' read -r -a fields <<< "$line" 2>/dev/null || return 1
  ver=${fields[0]:-}
  [ "$ver" = v1 ] || return 1
  for f in "${fields[@]:1}"; do
    case "$f" in
      attempt=*) attempt=${f#attempt=} ;;
      next=*) next=${f#next=} ;;
      model=*) model=${f#model=} ;;
      session=*) session=${f#session=} ;;
      ts=*) ;;
      *) return 1 ;;
    esac
  done
  case "$attempt" in ''|*[!0-9]*) return 1 ;; esac
  case "$next" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$model" ]; then token_valid "$model" || return 1; fi
  if [ -n "$session" ]; then token_valid "$session" || return 1; fi
  now_ms=$(($(date +%s) * 1000))
  # Expired: the vendor's own scheduled retry time plus grace has passed, so
  # this file no longer describes the present (the retry fired, resolved, or
  # the lane moved on without an idle clear reaching us).
  if [ "$now_ms" -gt $((next + STALE_SECS * 1000)) ]; then
    SIDE_STATUS=expired
    return 1
  fi
  horizon_s=$(((next - now_ms) / 1000))
  [ "$horizon_s" -ge 0 ] || horizon_s=0
  if [ "$horizon_s" -gt "$BLOCK_SECS" ]; then
    status=blocked
  else
    status=waiting
  fi
  SIDE_STATUS=$status
  out="status=$status attempt=$attempt horizon_s=$horizon_s"
  [ -n "$model" ] && out="$out model=$model"
  [ -n "$session" ] && out="$out session=$session"
  printf '%s\n' "$out"
}

# scan_file: the idle shape off a captured tail. Prints the blocked line and
# returns 0 on a cap-phrase match; returns 1 when the capture is missing,
# unreadable, empty, or clean. TEXT_PRESENT is 1 only when a fresh non-empty
# capture was actually read, which is what separates open from unknown.
TEXT_PRESENT=0
scan_file() {  # <path>
  local norm
  TEXT_PRESENT=0
  [ -n "${1:-}" ] && [ -f "$1" ] || return 1
  norm=$(normalize_stream < "$1" 2>/dev/null) || return 1
  case "$norm" in ''|' ') return 1 ;; esac
  TEXT_PRESENT=1
  printf '%s' "$norm" | scan_stream
}

# Command substitution would run the classifiers in a subshell and lose the
# SIDE_STATUS / TEXT_PRESENT globals verdict depends on, so their output goes
# through a temp file instead. Outside the repo (TMPDIR), never in state/.
if [ "$CMD" = check ]; then
  tmp_out="${TMPDIR:-/tmp}/fm-opencode-retry.$$.out"
  if sidecar_check > "$tmp_out" 2>/dev/null; then
    cat "$tmp_out"; rm -f "$tmp_out"; exit 0
  fi
  rm -f "$tmp_out"
  if [ -n "$TEXT_FILE" ] && scan_file "$TEXT_FILE" > "$tmp_out" 2>/dev/null; then
    cat "$tmp_out"; rm -f "$tmp_out"; exit 0
  fi
  rm -f "$tmp_out"
  exit 1
fi

if [ "$CMD" = verdict ]; then
  tmp_out="${TMPDIR:-/tmp}/fm-opencode-retry.$$.out"
  side_reason=no-evidence
  if sidecar_check > "$tmp_out" 2>/dev/null; then
    if [ "$SIDE_STATUS" = blocked ]; then
      printf 'verdict=capped evidence=sidecar %s\n' "$(cat "$tmp_out")"
      rm -f "$tmp_out"; exit 0
    fi
    side_reason=transient-backoff
  else
    case "$SIDE_STATUS" in
      waiting) side_reason=transient-backoff ;;
      expired) side_reason=expired-evidence ;;
      *) side_reason=no-evidence ;;
    esac
  fi
  rm -f "$tmp_out"
  if [ -n "$TEXT_FILE" ]; then
    if scan_file "$TEXT_FILE" > "$tmp_out" 2>/dev/null; then
      rest=$(sed -n 's/^status=blocked source=text //p' "$tmp_out" | head -n 1)
      [ -n "$rest" ] || rest='match=unknown'
      printf 'verdict=capped evidence=text %s\n' "$rest"
      rm -f "$tmp_out"; exit 0
    fi
    rm -f "$tmp_out"
    if [ "$TEXT_PRESENT" = 1 ]; then
      printf 'verdict=open evidence=text-clean\n'
      exit 0
    fi
    printf 'verdict=unknown reason=unreadable-text\n'
    exit 0
  fi
  printf 'verdict=unknown reason=%s\n' "$side_reason"
  exit 0
fi
