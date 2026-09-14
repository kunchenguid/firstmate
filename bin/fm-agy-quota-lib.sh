#!/usr/bin/env bash
# fm-agy-quota-lib.sh - the EVIDENCE the agy model ladder decides on: how a
# quota reading is obtained, recorded, aged out, and how many launches are
# already in flight against it.
# Usage: . bin/fm-agy-quota-lib.sh
# bin/fm-agy-ladder-lib.sh owns the policy that consumes all of this; this file
# owns nothing but the evidence and never decides whether a launch may proceed.
#
# WHERE A READING COMES FROM. Two sources, in order of authority:
#
#   1. THE INTAKE POLL (fm_agy_quota_poll). `agy --print /quota --output-format
#      json` answers the account's live quota for EVERY model without running a
#      turn - verified against agy 1.1.15, which reports "num_turns":0 and
#      "total_tokens":0 on that call - so reading the floor costs none of the
#      budget the floor exists to protect. This is the primary source, and
#      bin/fm-agy-ladder-lib.sh runs it at dispatch time.
#   2. THE PANE FOOTER (fm_agy_quota_observe). bin/fm-watch.sh records the
#      footer of a live agy pane as it redraws. Opportunistic: it refreshes
#      only while an agy pane exists and happens to redraw, so it can never be
#      the only source.
#
# Before the intake poll existed, source 2 was the only writer. A home with no
# agy pane running therefore refreshed nothing at all, and a single reading
# authorised every launch until its own reset window rolled over - hours, during
# which quota only falls. That is what the max-age ceiling below closes.
#
# THE FRESHNESS RULE, WHICH IS TWO RULES. A reading reads back as `unknown`
# when EITHER bound is crossed:
#
#   - FM_AGY_QUOTA_MAX_AGE, an absolute ceiling in seconds. This is the
#     load-bearing one. Quota falls monotonically inside a reset window, so a
#     reading taken early in that window systematically OVERSTATES what is left
#     for the rest of it. The ceiling is what makes one reading authorise
#     minutes instead of hours.
#   - The reading's own reported reset window, when it is parseable. A window
#     that has rolled over describes quota that no longer exists.
#
# A reset window that does NOT parse no longer discards the reading. The window
# is a refinement; the ceiling is the guarantee, and throwing away a valid
# percentage because its window was written "0m" or "soon" was a silent
# fail-open at exactly the moment the percentage mattered.
#
# FAILING SOFT IS DELIBERATE. Every path here degrades to "no reading" rather
# than to a wrong reading, and never to an error that stops a spawn. The captain
# ruled on 2026-08-19 that missing evidence must not stall the fleet: "we should
# not allow the fleet to stall but there has to be a way to quickly poll the
# quota before going in and launching a crewmate". So the answer to thin
# evidence is this file's poll, not a refusal in bin/fm-agy-ladder-lib.sh.

# Resolve this library's own directory so it can pull in the agy binary and
# bounded-subprocess helpers whether it was sourced by a bin/ script or directly
# by a test.
_FM_AGY_QUOTA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_AGY_QUOTA_LIB_DIR="."
if ! declare -f fm_agy_resolve_binary >/dev/null 2>&1; then
  # shellcheck source=bin/fm-agy-lib.sh
  . "$_FM_AGY_QUOTA_LIB_DIR/fm-agy-lib.sh"
fi

# FM_AGY_QUOTA_MAX_AGE: seconds after which a recorded reading is no longer
# evidence, whatever its own reset window says. Minutes, not hours: the intake
# poll refreshes on demand, so a short ceiling costs a 3-second subprocess
# rather than a wedged fleet. Set to 0 to disable the ceiling, which restores
# the window-only rule and is never what a dispatch path wants.
FM_AGY_QUOTA_MAX_AGE=${FM_AGY_QUOTA_MAX_AGE:-300}

# FM_AGY_QUOTA_POLL: set to `off` to skip the live intake poll entirely and
# decide on whatever is already recorded. Tests that pin the decision matrix
# against hand-written readings set it; nothing in production should.
FM_AGY_QUOTA_POLL=${FM_AGY_QUOTA_POLL:-on}

# FM_AGY_INFLIGHT_TTL: how long a recorded launch counts as unreflected in a
# reading. A launch older than this has had its consumption counted by the
# account's own quota service, so any reading fresh enough to pass the ceiling
# above already includes it; counting it twice would reserve headroom that is
# not at risk. Defaulting it to the ceiling keeps the two definitions of
# "recent enough to matter" from drifting apart.
FM_AGY_INFLIGHT_TTL=${FM_AGY_INFLIGHT_TTL:-$FM_AGY_QUOTA_MAX_AGE}

# fm_agy_strip_ansi: drop ANSI escape sequences from stdin.
# The model name is the KEY a reading is stored under, so an escape sequence
# captured with it does not merely make the text ugly - it writes the reading
# under a key no reader will ever look up, and the floor silently loses the
# evidence it was about to enforce. Stripping happens before anything is
# extracted, so no key can ever carry one.
fm_agy_strip_ansi() {
  LC_ALL=C sed -E $'s/\033\\[[0-9;?]*[ -/]*[@-~]//g; s/\033[@-Z\\\\-_]//g; s/\r//g'
}

# fm_agy_is_number: 0 when the argument is a bare decimal percentage.
# A footer can render a percentage agy could not compute ("--", "n/a"). That is
# an absence of evidence, not a reading of zero, and must not be recorded as
# one: zero is the most consequential number on this scale.
fm_agy_is_number() {  # <value>
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;
    .|*.*.*) return 1 ;;
  esac
  return 0
}

# fm_agy_quota_key: the on-disk key for a model's reading.
fm_agy_quota_key() {  # <model>
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

# fm_agy_parse_reset_time: converts '4h 24m', '1d 2h', etc to seconds. Returns 0
# for anything it cannot read, which callers must treat as "no window stated"
# rather than as "the window has elapsed".
fm_agy_parse_reset_time() {
  local ts="$1"
  local total=0
  local d=0 h=0 m=0 s=0

  case "$ts" in
    *d*) d="${ts%%d*}"; d="${d##* }"; fm_agy_is_number "$d" && total=$((total + ${d%%.*} * 86400)) ;;
  esac
  case "$ts" in
    *h*) h="${ts%%h*}"; h="${h##* }"; fm_agy_is_number "$h" && total=$((total + ${h%%.*} * 3600)) ;;
  esac
  case "$ts" in
    *m*) m="${ts%%m*}"; m="${m##* }"; fm_agy_is_number "$m" && total=$((total + ${m%%.*} * 60)) ;;
  esac
  case "$ts" in
    *s*) s="${ts%%s*}"; s="${s##* }"; fm_agy_is_number "$s" && total=$((total + ${s%%.*})) ;;
  esac
  echo "$total"
}

# fm_agy_quota_record: write one reading. The single writer, so observe and poll
# cannot drift on the key, the field order, or the timestamp.
fm_agy_quota_record() {  # <model> <percent> <reset-window> <state_dir> [<now>]
  local model=$1 percent=$2 reset=$3 state_dir=$4 now=${5:-}
  [ -n "$model" ] || return 1
  fm_agy_is_number "$percent" || return 1
  [ -d "$state_dir" ] || return 1
  [ -n "$now" ] || now=$(date +%s)
  printf '%s|%s|%s|%s\n' "$model" "$percent" "$reset" "$now" \
    > "$state_dir/.agy-quota-$(fm_agy_quota_key "$model")"
}

# fm_agy_footer_fields: the ONE parse of an agy pane footer, printing
# "<model>\t<quota-percent>\t<reset-window>" for the last footer line in
# <text>, or nothing at all.
#
# Format: Gemini 3.1 Pro (High) | ctx: 10.5% | quota: 94.7% (4h 24m)
#
# One extraction for all three fields, so a partial match can never record a
# model against another line's percentage. The reset window is optional: the
# percentage is the evidence, and the ceiling in fm_agy_quota_read bounds it
# whether or not a window came with it.
#
# The separators are matched with tolerance for surrounding whitespace rather
# than as the exact literals " | ctx: " and " | quota: ". A renderer that pads a
# column differently is a cosmetic change to agy; it must not silently stop the
# floor being enforced, which is what an exact-literal match made it do.
#
# This is a SINGLE owner on purpose: bin/fm-agy-descent-lib.sh reads the same
# footer to confirm which model a running worker is actually on, and a second
# copy of this expression would drift the moment only one was updated.
fm_agy_footer_fields() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | fm_agy_strip_ansi | LC_ALL=C grep -F 'quota:' | tail -1)
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | LC_ALL=C sed -nE \
    's/^[[:space:]]*(.*[^[:space:]])[[:space:]]*\|[[:space:]]*ctx:[^|]*\|[[:space:]]*quota:[[:space:]]*([0-9]+(\.[0-9]+)?)[[:space:]]*%?[[:space:]]*(\(([^)]*)\))?.*$/\1\t\2\t\5/p'
}

# fm_agy_footer_model: just the model name the footer names, or nothing.
fm_agy_footer_model() {  # <text>
  local parsed
  parsed=$(fm_agy_footer_fields "$1") || return 1
  [ -n "$parsed" ] || return 1
  printf '%s' "${parsed%%	*}"
}

# fm_agy_quota_observe: record the quota an agy pane footer reports.
# fm_agy_footer_fields above owns the parse.
# The optional <now> stamps the reading instead of the wall clock, so a caller
# that must reason about a reading's exact age - a test pinning the max-age
# ceiling - can do so without racing the second hand.
fm_agy_quota_observe() {  # <text> <state_dir> [<now>]
  local text="$1" state_dir="$2" now="${3:-}" parsed model quota reset_time

  parsed=$(fm_agy_footer_fields "$text") || return 0
  [ -n "$parsed" ] || return 0

  model=${parsed%%	*}
  parsed=${parsed#*	}
  quota=${parsed%%	*}
  reset_time=${parsed#*	}

  fm_agy_quota_record "$model" "$quota" "$reset_time" "$state_dir" "$now" || return 0
}

# fm_agy_quota_read: the last known value for a model together with its age, or
# `unknown`. Both freshness bounds documented at the top of this file are
# applied here; the ceiling is the one that matters.
fm_agy_quota_read() {  # <model> <state_dir> [<now>]
  local model="$1" state_dir="$2" now_override="${3:-}"
  local file line file_model rest quota reset_time_str obs_ts now age reset_seconds

  file="$state_dir/.agy-quota-$(fm_agy_quota_key "$model")"
  if [ ! -f "$file" ]; then
    echo "unknown"
    return 0
  fi

  line=$(cat "$file" 2>/dev/null || true)
  if [ -z "$line" ]; then
    echo "unknown"
    return 0
  fi

  file_model="${line%%|*}"
  rest="${line#*|}"
  quota="${rest%%|*}"
  rest="${rest#*|}"
  reset_time_str="${rest%%|*}"
  obs_ts="${rest#*|}"
  quota="${quota%%%*}"

  # A reset window is no longer required. A record whose model, percentage, or
  # observation time is missing or unreadable still establishes nothing.
  if [ "$file_model" != "$model" ] || ! fm_agy_is_number "$quota" || ! fm_agy_is_number "$obs_ts"; then
    echo "unknown"
    return 0
  fi

  if [ -n "$now_override" ]; then
    now="$now_override"
  else
    now=$(date +%s)
  fi

  age=$((now - obs_ts))
  if [ "$age" -lt 0 ]; then
    age=0
  fi

  # The ceiling. Independent of the window, and checked first because it is the
  # bound that actually holds the floor up.
  if [ "$FM_AGY_QUOTA_MAX_AGE" -gt 0 ] && [ "$age" -ge "$FM_AGY_QUOTA_MAX_AGE" ]; then
    echo "unknown"
    return 0
  fi

  reset_seconds=$(fm_agy_parse_reset_time "$reset_time_str")
  if [ "$reset_seconds" -gt 0 ] && [ "$age" -ge "$reset_seconds" ]; then
    echo "unknown"
    return 0
  fi

  echo "$quota $age"
}

# fm_agy_reset_window: an absolute RFC3339 reset instant rendered as the
# "<n>h <n>m" window the recorded format speaks. Prints nothing when the instant
# cannot be read, which is not a failure: the ceiling still bounds the reading.
fm_agy_reset_window() {  # <rfc3339> [<now>]
  local stamp=$1 now=${2:-} epoch remain
  [ -n "$stamp" ] || return 0
  [ -n "$now" ] || now=$(date +%s)
  epoch=$(date -u -d "$stamp" +%s 2>/dev/null) \
    || epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null) \
    || return 0
  fm_agy_is_number "$epoch" || return 0
  remain=$((epoch - now))
  [ "$remain" -gt 0 ] || return 0
  printf '%dh %dm' $((remain / 3600)) $(((remain % 3600) / 60))
}

# fm_agy_quota_poll: ask agy for the account's live quota and record a reading
# for every model it reports. Prints nothing; the readings ARE the result.
#
#   0  at least one reading was recorded
#   1  no reading was obtained, for any reason
#
# Returning 1 is an ordinary outcome, not an error to escalate: agy may be
# absent, jq may be absent, the account may have no quota summary, or the call
# may time out. Each of those leaves whatever was already recorded in place and
# lets bin/fm-agy-ladder-lib.sh decide on that, which is the captain's no-stall
# ruling expressed in code.
fm_agy_quota_poll() {  # <state_dir> [<now>]
  local state_dir=$1 now=${2:-} bin out rows name fraction reset percent window recorded=1

  [ "$FM_AGY_QUOTA_POLL" != off ] || return 1
  [ -d "$state_dir" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  bin=$(fm_agy_resolve_binary 2>/dev/null) || return 1
  [ -n "$now" ] || now=$(date +%s)

  # `/quota` is answered locally by agy's own command runner against the quota
  # service. It runs no turn, so this costs no quota - which is the entire
  # reason the poll can sit on the dispatch path at all.
  out=$(fm_agy_bounded_output "$bin" --print /quota --output-format json) || return 1
  [ -n "$out" ] || return 1

  # remaining_fraction is the precise figure; the human-readable rows in
  # .response round to whole percents and would blur exactly the last point
  # above the floor.
  rows=$(printf '%s' "$out" | jq -r '
    .command.data.groups[]?.buckets[]?
    | select(.name != null and .remaining_fraction != null)
    | [.name, .remaining_fraction, (.reset_time // "")]
    | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1

  while IFS=$'\t' read -r name fraction reset; do
    [ -n "$name" ] || continue
    # One decimal place, the same precision the pane footer reports, so a
    # reading's provenance never changes how it compares against a floor.
    percent=$(awk -v f="$fraction" 'BEGIN { printf "%.1f", f * 100 }' 2>/dev/null)
    fm_agy_is_number "$percent" || continue
    window=$(fm_agy_reset_window "$reset" "$now")
    if fm_agy_quota_record "$name" "$percent" "$window" "$state_dir" "$now"; then
      recorded=0
    fi
  done <<EOF
$rows
EOF

  return "$recorded"
}

# --- reservations against the ACCOUNT, not against a home --------------------
#
# A reading describes quota as of the moment it was taken. Launches made since
# then are spending against it and are invisible to it, so at 26% remaining an
# unbounded burst of concurrent workers can all pass a 25% floor and drive the
# true figure well under it before anything is re-read. The ledger below is how
# many launches a model owes but no reading has yet seen.
#
# THE LEDGER IS SCOPED TO THE ACCOUNT, BECAUSE THE QUOTA IS. It used to live in
# the calling home's own state/ directory, and that was the wrong scope by one
# whole level. Every firstmate home that runs agy out of the same credential
# store draws on ONE quota pool, so a home's own ledger described only the
# launches that home had made itself. On 2026-09-02 the primary home and the
# Lucie secondmate both dispatched agy workers against the same Claude pool
# while it fell from 100% to 0%, and neither home's gate could see the other's
# launches: each reserved headroom against itself alone and authorised straight
# past the other.
#
# So the ledger is keyed by ACCOUNT and stored machine-wide, outside every
# FM_HOME, exactly as bin/fm-procevent-lib.sh stores its cross-home source
# claims and for the same reason it does: a rule about a resource several homes
# share cannot live inside any one of them.
#
# WHAT IS SHARED IS THE ACCOUNTING, NEVER THE ACTION, and that is the whole of
# the coupling. No home reads another home's tasks, durable records, backlog, or
# panes, and no home ever acts on another home's worker; bin/fm-agy-descent-lib.sh
# still moves only the workers of the home that runs it. The file below is a
# record about the ACCOUNT - an external resource both homes already draw on and
# already read the same figures from - not a record about either home, so the
# FM_HOME separation is not weakened to obtain it.
#
# THE KEY IS THE MODEL, NOT THE RUNG. A rung NUMBER is home-local policy: the
# order comes from each home's own config/crew-dispatch.json, so rung 2 in one
# home need not name the model rung 2 names in another, and a number written by
# one home would be counted against a different model by the next. A display
# name is the ACCOUNT's own vocabulary and means the same thing in every home,
# so that is what a reservation records. Entries written in the older
# rung-number format simply match no model and age out within
# FM_AGY_INFLIGHT_TTL, which under-reserves by that margin for one TTL rather
# than mismatching a model outright.
#
# WHICH ACCOUNT. agy answers for whichever account its credential store is
# logged into, and that store is fm_agy_config_home() - one per machine and OS
# user. Two homes draw on one pool exactly when they resolve to the same store,
# so that path IS the account identity here, and establishing it needs no
# network call and no read of the credential itself. It is a proxy and is
# documented as one: logging agy into a DIFFERENT account without moving that
# store keeps the same key, which counts the previous account's launches for at
# most FM_AGY_INFLIGHT_TTL before they expire. That errs toward reserving too
# much, which costs a launch that can be made a moment later - the direction
# every trade in this file already leans.
#
# A REMOTE SECONDMATE IS NOT COVERED, and that is stated rather than implied. A
# remote home (docs/remote-secondmates.md) runs on another machine with its own
# filesystem and its own agy credential store, so nothing here reaches it. If a
# remote home is ever logged into the SAME agy account, its launches are
# invisible to this ledger exactly as another local home's were before this
# change. Covering that needs a transport and an ownership story that do not
# exist yet, so never describe this ledger as fleet-wide; it is machine-wide.
#
# A HOME ALONE STILL WORKS, and so does a machine that cannot offer a shared
# location at all. Every path below degrades to the home-local ledger this used
# to be - no HOME, an unwritable state root, a read-only filesystem, a symlinked
# directory - and a home that is the only home then reserves against itself
# exactly as before. Nothing here can refuse a launch by failing.

# FM_AGY_SHARED_ROOT: machine-wide root for account-scoped agy records. A test
# points it at a scratch directory; `off` forces the home-local ledger.
FM_AGY_SHARED_ROOT=${FM_AGY_SHARED_ROOT:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/firstmate/agy-account}

# FM_AGY_INFLIGHT_LOCK_WAIT: seconds to wait for the account's reservation lock
# before deciding without it. Bounded rather than patient on purpose. This lock
# sits on the spawn path, so a home that waited indefinitely on it would turn a
# shared ACCOUNTING record into a shared AVAILABILITY dependency - one wedged
# home stalling every other home's dispatch - which is a worse coupling than the
# blindness the ledger exists to close.
FM_AGY_INFLIGHT_LOCK_WAIT=${FM_AGY_INFLIGHT_LOCK_WAIT:-5}

# fm_agy_account_key: a stable, path-safe id for the agy account a home draws
# on. Derived from the credential store's PATH, never from its contents: the
# token inside rotates on every refresh and is a secret, while the path is
# stable and answers exactly the question being asked - which homes reach the
# same account. fm_agy_quota_key is reused so this file has one hasher.
fm_agy_account_key() {
  local config_home
  config_home=$(fm_agy_config_home) || return 1
  [ -n "$config_home" ] || return 1
  fm_agy_quota_key "$config_home"
}

# fm_agy_shared_inflight_dir: the account's own directory, created on demand, or
# a failure when this machine cannot offer one. A symlink is refused rather than
# followed: this path is shared between homes, so it is exactly the kind of file
# that must not be redirected by whatever created it first.
fm_agy_shared_inflight_dir() {
  local root key dir
  root=${FM_AGY_SHARED_ROOT:-}
  [ -n "$root" ] && [ "$root" != off ] || return 1
  key=$(fm_agy_account_key) || return 1
  [ -n "$key" ] || return 1
  dir="$root/$key"
  [ -d "$dir" ] || (umask 077; mkdir -p "$dir") 2>/dev/null || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  printf '%s' "$dir"
}

# fm_agy_inflight_path: the ledger this home must read and write - the account's
# shared one whenever the machine can offer it, and the home's own otherwise.
# The single owner of that choice, so no caller can reach one ledger while
# another reaches the other.
fm_agy_inflight_path() {  # <state_dir>
  local dir
  if dir=$(fm_agy_shared_inflight_dir); then
    printf '%s/inflight' "$dir"
    return 0
  fi
  printf '%s/.agy-inflight' "$1"
}

# fm_agy_inflight_lock_path: the lock that serializes decide-and-reserve against
# every other home on this account. Beside the ledger, so it is shared exactly
# when the ledger is and home-local exactly when the ledger is.
fm_agy_inflight_lock_path() {  # <state_dir>
  printf '%s.lock' "$(fm_agy_inflight_path "$1")"
}

# fm_agy_inflight_lock: take the account's reservation lock, printing the lock
# path so a caller releases exactly what it took.
#
#   0  held; the caller MUST release it
#   1  not held, for any reason
#
# Failing to take it is an ordinary outcome and never refuses a launch. The
# caller proceeds against the same shared ledger unserialized, which still
# counts every home's launches instead of only its own and leaves a race window
# of milliseconds where there used to be no cross-home accounting at all.
fm_agy_inflight_lock() {  # <state_dir>
  local lock tries
  declare -f fm_lock_try_acquire >/dev/null 2>&1 || return 1
  [ -n "${1:-}" ] || return 1
  lock=$(fm_agy_inflight_lock_path "$1") || return 1
  tries=$((${FM_AGY_INFLIGHT_LOCK_WAIT:-5} * 10))
  [ "$tries" -gt 0 ] || tries=1
  while [ "$tries" -gt 0 ]; do
    if fm_lock_try_acquire "$lock"; then
      printf '%s' "$lock"
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

# fm_agy_inflight_record: note that a launch on <model> has been authorized.
# <model> is a DISPLAY NAME, which is what makes the entry mean the same model
# in every home drawing on this account.
#
# A name carrying a newline is refused rather than written. On a ledger only one
# home could read, a malformed line cost that home its own count; on a shared
# one it would corrupt every home's, so the check is worth its one line.
fm_agy_inflight_record() {  # <model> <state_dir> [<now>]
  local model=$1 state_dir=$2 now=${3:-} file
  [ -n "$model" ] || return 1
  case $model in *$'\n'*) return 1 ;; esac
  [ -d "$state_dir" ] || return 1
  [ -n "$now" ] || now=$(date +%s)
  file=$(fm_agy_inflight_path "$state_dir") || return 1
  printf '%s %s\n' "$now" "$model" >> "$file"
}

# _fm_agy_inflight_prune: drop expired entries. Re-reads the ledger itself
# rather than trusting a list its caller read earlier, because between that read
# and this rewrite another home may have appended - and on a SHARED ledger a
# lost append is another home's reservation, which is precisely the blindness
# this ledger exists to remove. Callers run it only while holding the account
# lock.
_fm_agy_inflight_prune() {  # <file> <now>
  local file=$1 now=$2 ts entry tmp kept=''
  [ -f "$file" ] || return 0
  while read -r ts entry; do
    fm_agy_is_number "$ts" || continue
    [ $((now - ts)) -lt "$FM_AGY_INFLIGHT_TTL" ] || continue
    kept="$kept$ts $entry
"
  done < "$file"
  tmp="$file.tmp.${BASHPID:-$$}"
  if printf '%s' "$kept" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# fm_agy_inflight_count: how many launches on <model> are still unreflected in a
# current reading. Prints a count, always.
#
# THE COUNT IS UNLOCKED AND THE PRUNE IS NOT. Appending one short line is atomic
# from any number of homes at once, so counting needs no lock and must not wait
# for one while a spawn holds its own locks. Dropping expired entries is a
# read-modify-write, which is not atomic, so it happens only under the account
# lock - and when that lock cannot be taken the count is still exact and only
# the prune is skipped, leaving the entries for the next reader that does hold
# it. Both of those are why a ledger that grew unbounded is impossible and a
# reservation that is silently dropped is not.
fm_agy_inflight_count() {  # <model> <state_dir> [<now>]
  local model=$1 state_dir=$2 now=${3:-} file ts entry count=0 expired=0 lock=''

  file=$(fm_agy_inflight_path "$state_dir") || { printf '0'; return 0; }
  if [ ! -f "$file" ]; then
    printf '0'
    return 0
  fi
  [ -n "$now" ] || now=$(date +%s)

  while read -r ts entry; do
    if ! fm_agy_is_number "$ts" || [ $((now - ts)) -ge "$FM_AGY_INFLIGHT_TTL" ]; then
      expired=1
      continue
    fi
    [ "$entry" = "$model" ] && count=$((count + 1))
  done < "$file"

  if [ "$expired" -eq 1 ]; then
    if [ -n "${_FM_AGY_INFLIGHT_LOCK_HELD:-}" ]; then
      # Already inside the gate's own hold: prune directly rather than reaching
      # for a lock this very process holds, which the shared lock library would
      # reclaim out from under the caller.
      _fm_agy_inflight_prune "$file" "$now"
    elif ! fm_agy_shared_inflight_dir >/dev/null 2>&1; then
      # A home-local ledger: only this home appends to it, and bin/fm-spawn.sh's
      # own locks already serialize agy dispatch within a home. That is the
      # trade this ledger shipped with and it is unchanged - a lost append here
      # could only ever be this home's own, and the next poll corrects it.
      _fm_agy_inflight_prune "$file" "$now"
    elif lock=$(fm_agy_inflight_lock "$state_dir"); then
      _fm_agy_inflight_prune "$file" "$now"
      fm_lock_release "$lock" || true
    fi
  fi

  printf '%s' "$count"
}
