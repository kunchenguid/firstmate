#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e) and extracts the real typed content with the
# shared, fleet-wide fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops
# every de-emphasised run - dim/faint (SGR 2) AND a dark/muted truecolor
# foreground - so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that de-emphasises placeholder/ghost text
# benefits, and the herdr adapter routes through the same owner (task
# afk-herdr-false-pending), so the two backends cannot drift.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
# Claude quota parking override: FM_RATELIMIT_REGEX and FM_OVERLOAD_REGEX match
# only the footer render inspected by fm_ratelimit_render_match, never the full
# transcript. FM_RATELIMIT_FALLBACK is the fallback reset delay in seconds.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer-content classification (empty|pending|unknown, and the fleet-wide
# rule that a BARE shell prompt glyph is a dead shell, not an empty agent
# composer) is NOT owned here: it is the shared bin/fm-composer-lib.sh, sourced
# below and reused by every backend adapter so the decision cannot drift.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73).
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'
FM_RATELIMIT_REGEX_DEFAULT='(Claude[[:space:]]+)?((AI[[:space:]]+)?usage[[:space:]-]+limit|rate[[:space:]-]+limit|quota)[^[:cntrl:]]*(reached|exceeded|reset|try again)|limit[[:space:]-]+reached'
FM_OVERLOAD_REGEX_DEFAULT='API Error: 529'

fm_ratelimit_numeric_or_default() {  # <value> <default>
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

# fm_ratelimit_reset_epoch: parse a human reset time from a quota footer.
# The parser prefers python3/zoneinfo so IANA zones such as
# America/Los_Angeles follow DST rules. If parsing fails, it returns
# now + FM_RATELIMIT_FALLBACK (default 3600s).
fm_ratelimit_reset_epoch() {  # <footer-text> [now-epoch]
  local text=$1 now fallback parsed
  now=$(fm_ratelimit_numeric_or_default "${2:-$(date +%s)}" "$(date +%s)")
  fallback=$(fm_ratelimit_numeric_or_default "${FM_RATELIMIT_FALLBACK:-3600}" 3600)
  if command -v python3 >/dev/null 2>&1; then
    parsed=$(FM_RATELIMIT_PARSE_TEXT="$text" python3 - "$now" "$fallback" <<'PY' 2>/dev/null
import os
import re
import sys
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

text = " ".join(os.environ.get("FM_RATELIMIT_PARSE_TEXT", "").split())
now = int(sys.argv[1])
fallback = int(sys.argv[2])

def emit_fallback():
    print(now + fallback)
    raise SystemExit

def fixed_tz(hours=0, minutes=0):
    return timezone(timedelta(hours=hours, minutes=minutes))

def parse_tz(raw):
    if not raw:
        return None
    raw = raw.strip().strip(".,;")
    upper = raw.upper()
    abbrev = {
        "UTC": timezone.utc,
        "GMT": timezone.utc,
        "Z": timezone.utc,
        "PST": fixed_tz(-8),
        "PDT": fixed_tz(-7),
        "MST": fixed_tz(-7),
        "MDT": fixed_tz(-6),
        "CST": fixed_tz(-6),
        "CDT": fixed_tz(-5),
        "EST": fixed_tz(-5),
        "EDT": fixed_tz(-4),
    }
    if upper in abbrev:
        return abbrev[upper]
    m = re.fullmatch(r"(?:GMT|UTC)?([+-])(\d{1,2})(?::?(\d{2}))?", upper)
    if m:
        sign = -1 if m.group(1) == "-" else 1
        hours = int(m.group(2)) * sign
        minutes = int(m.group(3) or "0") * sign
        return fixed_tz(hours, minutes)
    if "/" in raw and ZoneInfo is not None:
        try:
            return ZoneInfo(raw)
        except Exception:
            return None
    return None

def discover_tz():
    candidates = []
    candidates.extend(m.group(1).strip() for m in re.finditer(r"\(([^)]{2,80})\)", text))
    candidates.extend(m.group(1) for m in re.finditer(r"\b([A-Za-z]+/[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+)?)\b", text))
    candidates.extend(m.group(1) for m in re.finditer(r"\b(UTC|GMT|PST|PDT|MST|MDT|CST|CDT|EST|EDT|Z|[+-]\d{2}:?\d{2})\b", text, re.I))
    candidates.extend(m.group(0) for m in re.finditer(r"\b(?:UTC|GMT)[+-]\d{1,2}(?::?\d{2})?\b", text, re.I))
    for candidate in candidates:
        tz = parse_tz(candidate)
        if tz is not None:
            return tz
    return datetime.now().astimezone().tzinfo or timezone.utc

tz = discover_tz()
base = datetime.fromtimestamp(now, tz)

iso = re.search(r"\b(\d{4}-\d{2}-\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?\s*(Z|[+-]\d{2}:?\d{2})?\b", text)
if iso:
    suffix = iso.group(5) or ""
    value = f"{iso.group(1)}T{int(iso.group(2)):02d}:{iso.group(3)}:{iso.group(4) or '00'}"
    if suffix:
        value += "+00:00" if suffix == "Z" else suffix
    try:
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=tz)
        print(int(dt.timestamp()))
        raise SystemExit
    except Exception:
        pass

months = {
    "jan": 1, "january": 1,
    "feb": 2, "february": 2,
    "mar": 3, "march": 3,
    "apr": 4, "april": 4,
    "may": 5,
    "jun": 6, "june": 6,
    "jul": 7, "july": 7,
    "aug": 8, "august": 8,
    "sep": 9, "sept": 9, "september": 9,
    "oct": 10, "october": 10,
    "nov": 11, "november": 11,
    "dec": 12, "december": 12,
}

def normalize_hour(hour, ampm):
    hour = int(hour)
    ampm = (ampm or "").lower().replace(".", "")
    if ampm == "pm" and hour < 12:
        hour += 12
    if ampm == "am" and hour == 12:
        hour = 0
    return hour

def candidate(year, month, day, hour, minute, second=0, date_was_explicit=False):
    try:
        dt = datetime(year, month, day, hour, minute, second, tzinfo=tz)
    except ValueError:
        emit_fallback()
    if date_was_explicit:
        if dt <= base - timedelta(hours=1) and year == base.year:
            try:
                dt = datetime(year + 1, month, day, hour, minute, second, tzinfo=tz)
            except ValueError:
                pass
    elif dt <= base:
        dt += timedelta(days=1)
    print(int(dt.timestamp()))
    raise SystemExit

month_names = "|".join(sorted(months, key=len, reverse=True))
md = re.search(rf"\b({month_names})\.?\s+(\d{{1,2}})(?:,\s*(\d{{4}}))?(?:\s+(?:at\s+)?)?(\d{{1,2}})(?::(\d{{2}}))?\s*([AaPp]\.?[Mm]\.?)?\b", text, re.I)
if md:
    month = months[md.group(1).lower().rstrip(".")]
    year = int(md.group(3) or base.year)
    hour = normalize_hour(md.group(4), md.group(6))
    minute = int(md.group(5) or "0")
    candidate(year, month, int(md.group(2)), hour, minute, date_was_explicit=True)

ymd = re.search(r"\b(\d{4})[/-](\d{1,2})[/-](\d{1,2}).{0,12}?(\d{1,2})(?::(\d{2}))?\s*([AaPp]\.?[Mm]\.?)?\b", text)
if ymd:
    hour = normalize_hour(ymd.group(4), ymd.group(6))
    candidate(int(ymd.group(1)), int(ymd.group(2)), int(ymd.group(3)), hour, int(ymd.group(5) or "0"), date_was_explicit=True)

tm = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*([AaPp]\.?[Mm]\.?)\b", text)
if tm:
    hour = normalize_hour(tm.group(1), tm.group(3))
    candidate(base.year, base.month, base.day, hour, int(tm.group(2) or "0"))

tm24 = re.search(r"\b(?:reset(?:s)?|try again|available|resume|until|at)\D{0,40}(\d{1,2}):(\d{2})\b", text, re.I)
if tm24 and int(tm24.group(1)) < 24:
    candidate(base.year, base.month, base.day, int(tm24.group(1)), int(tm24.group(2)))

emit_fallback()
PY
)
    case "$parsed" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "$parsed"; return 0 ;;
    esac
  fi
  printf '%s' "$((now + fallback))"
}

fm_ratelimit_footer_text() {  # <tail-text>
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -3
}

# fm_ratelimit_render_match: classify only the footer-sized tail render.
# Prints "<reset-epoch><TAB><reason>" on a limit/overload match.
fm_ratelimit_render_match() {  # <tail-text> [now-epoch]
  local tail footer now reset
  tail=$1
  now=${2:-$(date +%s)}
  footer=$(fm_ratelimit_footer_text "$tail")
  [ -n "$footer" ] || return 1
  if printf '%s\n' "$footer" | grep -qiE "${FM_RATELIMIT_REGEX:-$FM_RATELIMIT_REGEX_DEFAULT}"; then
    reset=$(fm_ratelimit_reset_epoch "$footer" "$now")
    printf '%s\t%s\n' "$reset" ratelimit
    return 0
  fi
  if printf '%s\n' "$footer" | grep -qiE "${FM_OVERLOAD_REGEX:-$FM_OVERLOAD_REGEX_DEFAULT}"; then
    reset=$((now + $(fm_ratelimit_numeric_or_default "${FM_RATELIMIT_FALLBACK:-3600}" 3600)))
    printf '%s\t%s\n' "$reset" overload
    return 0
  fi
  return 1
}

fm_ratelimit_marker_write() {  # <state> <id> <reset-epoch> <window> <harness>
  local state=$1 id=$2 reset=$3 window=$4 harness=$5 marker old old_reset old_window old_harness tmp
  marker="$state/$id.ratelimit"
  old=$(cat "$marker" 2>/dev/null || true)
  if [ "$old" = "$(printf '%s\t%s\t%s' "$reset" "$window" "$harness")" ]; then
    return 1
  fi
  IFS=$(printf '\t') read -r old_reset old_window old_harness <<EOF
$old
EOF
  case "$old_reset" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$old_window" = "$window" ] && [ "$old_harness" = "$harness" ]; then
        return 1
      fi
      ;;
  esac
  tmp="$marker.tmp.$$"
  printf '%s\t%s\t%s\n' "$reset" "$window" "$harness" > "$tmp" || return 1
  mv -f "$tmp" "$marker" || return 1
  rm -f "$marker.attempts" "$marker.failed" 2>/dev/null || true
  return 0
}

fm_ratelimit_id_from_marker() {  # <marker-path>
  local base
  base=${1##*/}
  printf '%s' "${base%.ratelimit}"
}

fm_ratelimit_backend_for_marker() {  # <state> <id> <window>
  local state=$1 id=$2 window=$3 meta
  if [ "$id" = firstmate ] && [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  meta="$state/$id.meta"
  if [ -f "$meta" ] && command -v fm_backend_of_meta >/dev/null 2>&1; then
    fm_backend_of_meta "$meta"
    return 0
  fi
  if command -v fm_backend_meta_for_window >/dev/null 2>&1; then
    meta=$(fm_backend_meta_for_window "$window" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

fm_ratelimit_label_for_marker() {  # <state> <id>
  local state=$1 id=$2 meta
  meta="$state/$id.meta"
  [ -f "$meta" ] && { printf 'fm-%s' "$id"; return 0; }
  printf '%s' "$id"
}

fm_ratelimit_target_ready_for_resume() {  # <backend> <window> <label> -> prints limited|recovered
  local backend=$1 window=$2 label=$3 bs tail state
  command -v fm_backend_target_exists >/dev/null 2>&1 || return 1
  fm_backend_target_exists "$backend" "$window" "$label" || return 1
  bs=$(fm_backend_busy_state "$backend" "$window" 2>/dev/null)
  [ "$bs" = busy ] && return 1
  tail=$(fm_backend_capture "$backend" "$window" 40 "$label" 2>/dev/null) || return 1
  printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}" && return 1
  if fm_ratelimit_render_match "$tail" >/dev/null; then
    printf 'limited'
    return 0
  fi
  state=$(fm_backend_composer_state "$backend" "$window" 2>/dev/null)
  if [ "$state" = empty ]; then
    printf 'recovered'
    return 0
  fi
  return 1
}

fm_ratelimit_resume_scan() {  # <state> -> prints escalation reason on exhausted failure
  local state=$1 now margin max marker id line reset window harness backend label due attempts_file attempts verdict reason ready
  now=$(date +%s)
  margin=$(fm_ratelimit_numeric_or_default "${FM_RATELIMIT_MARGIN:-60}" 60)
  max=$(fm_ratelimit_numeric_or_default "${FM_RATELIMIT_MAX_RESUMES:-3}" 3)
  for marker in "$state"/*.ratelimit; do
    [ -e "$marker" ] || continue
    [ -e "$marker.failed" ] && continue
    line=$(cat "$marker" 2>/dev/null || true)
    IFS=$(printf '\t') read -r reset window harness <<EOF
$line
EOF
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    due=$((reset + margin))
    [ "$now" -ge "$due" ] || continue
    id=$(fm_ratelimit_id_from_marker "$marker")
    backend=$(fm_ratelimit_backend_for_marker "$state" "$id" "$window")
    label=$(fm_ratelimit_label_for_marker "$state" "$id")
    attempts_file="$marker.attempts"
    ready=$(fm_ratelimit_target_ready_for_resume "$backend" "$window" "$label") || continue
    if [ "$ready" = recovered ]; then
      rm -f "$marker" "$attempts_file" "$marker.failed" 2>/dev/null || true
      if command -v fm_wake_append >/dev/null 2>&1; then
        STATE="$state" FM_WAKE_QUEUE="$state/.wake-queue" FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock" \
          fm_wake_append ratelimited-resumed "$id" "ratelimited-resumed: $id $window" >/dev/null 2>&1 || true
      fi
      continue
    fi
    attempts=$(( $(cat "$attempts_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$attempts" > "$attempts_file" 2>/dev/null || true
    verdict=$(fm_backend_send_text_submit "$backend" "$window" continue "${FM_SEND_RETRIES:-3}" "${FM_SEND_SLEEP:-0.4}" 0.3 "$label" 2>/dev/null) || verdict=send-failed
    if [ "$verdict" = empty ]; then
      rm -f "$marker" "$attempts_file" "$marker.failed" 2>/dev/null || true
      if command -v fm_wake_append >/dev/null 2>&1; then
        STATE="$state" FM_WAKE_QUEUE="$state/.wake-queue" FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock" \
          fm_wake_append ratelimited-resumed "$id" "ratelimited-resumed: $id $window" >/dev/null 2>&1 || true
      fi
      continue
    fi
    if [ "$attempts" -ge "$max" ]; then
      reason="check: $marker: ratelimit auto-resume exhausted after $attempts attempts for $id ($window; verdict=$verdict)"
      {
        printf 'ratelimit auto-resume exhausted at %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'id=%s\nwindow=%s\nharness=%s\nbackend=%s\nattempts=%s\nverdict=%s\n' "$id" "$window" "$harness" "$backend" "$attempts" "$verdict"
      } > "$marker.failed" 2>/dev/null || true
      if command -v fm_wake_append >/dev/null 2>&1; then
        STATE="$state" FM_WAKE_QUEUE="$state/.wake-queue" FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock" \
          fm_wake_append check "$marker" "$reason" >/dev/null 2>&1 || true
      fi
      printf '%s\n' "$reason"
      return 2
    fi
  done
  return 0
}

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a busy footer, an empty agent composer, or
#             only de-emphasised ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error), OR the cursor line is a
#             bare shell prompt (`$`/`%`/`#`/`>`) - a dead shell, not an agent
#             composer, so NOT a safe injection target. The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E). The bordered flag (a genuine composer box) is
# read from the PLAIN row (fm_composer_strip_ansi keeps ghost text so the box
# border is still visible), while the real-typed CONTENT is extracted with the
# shared fm_composer_strip_ghost so dim/faint AND dark-truecolor ghost text drops
# out before classification (grok's dark box border drops with the ghost, which
# is why the bordered flag is read from the plain row, not the ghost-stripped
# one). Both are internal only, never surfaced. The detector strips the harness's
# box-drawing composer borders ("│ … │", heavy "┃", or a plain ASCII "|") using
# literal-string substitution (bash 3.2 safe, locale-independent - no \u escapes,
# no multibyte character classes), and delegates the empty/pending/unknown
# decision to the shared owner fm_composer_classify_content
# (bin/fm-composer-lib.sh). The bordered flag is what lets a bordered `│ > │`
# (claude's own idle composer) read empty while a bare, unbordered `$ ` dead-shell
# prompt reads unknown.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw plain stripped bordered=0
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  # bordered: from the plain row (borders survive an all-ANSI strip).
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  case "$plain" in
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  # content: from the ghost-stripped row (real typed text only).
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A busy footer landing on the cursor line is not pending input (tmux-specific:
  # only tmux captures the raw cursor row, which may BE the footer).
  if [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  fm_composer_classify_content "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-}" insensitive "$plain"
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
