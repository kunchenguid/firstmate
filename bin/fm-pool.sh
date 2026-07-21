#!/usr/bin/env bash
# Multi-account dispatch pool: choose which agent account a NEW spawn launches on.
#
# Usage:
#   fm-pool.sh select [--harness <name>] [--exclude <id>] [--peek]
#   fm-pool.sh resolve <id>
#   fm-pool.sh status [--json]
#   fm-pool.sh backends
#   fm-pool.sh cooldown <id> [--seconds <n>|--until <epoch>] [--reason <text>]
#                            [--from-file <path>|--from-stdin]
#   fm-pool.sh clear <id>
#   fm-pool.sh detect [--file <path>]
#
# The pool is INERT until config/dispatch-pool.json exists. With that file
# absent every subcommand that needs it exits 3 without touching state, and no
# other firstmate path changes behavior. docs/dispatch-pool.md owns the schema,
# the rotation contract, and the limit-signature catalogue; the example config is
# docs/examples/dispatch-pool.json.
#
# `select` prints one `key=value` line per fact, in this order, and prints
# NOTHING else on stdout:
#   backend=<id>
#   harness=<name>
#   model=<value>          (empty when the backend pins no model)
#   effort=<value>         (empty when the backend pins no effort)
#   env=<NAME>=<VALUE>     (zero or more; non-secret env assignments)
#   key_env=<NAME>         (at most one; the env var the secret must arrive in)
#   key_file=<path>        (present iff key_env is; the file holding that secret)
# A key's CONTENT is never read, printed, or logged here. The caller passes the
# path through to the launch so the value is expanded at launch time in the
# target process, keeping the secret out of pane text, logs, meta, and errors.
#
# Rotation is equal round-robin over HEALTHY backends: selection resumes at the
# config-order position after the last selected backend and takes the first
# healthy one, wrapping around. `state/.pool-cursor` persists that position and
# `state/.pool.lock` serializes the read-modify-write, so concurrent spawns do
# not both land on the same account.
#
# A backend is UNHEALTHY when it is `"enabled": false`, when its key file is
# missing or empty, or while it is in cooldown. Every unhealthy backend is
# reported with a concrete reason rather than silently skipped. When EVERY
# backend is unhealthy, `select` exits 4 and names the earliest reset time
# instead of handing work to a dead account.
#
# Cooldowns live in `state/.pool-cooldown-<id>` and hold `until=<epoch>`. They
# expire on their own: every reader treats `now >= until` as expired and unlinks
# the file opportunistically, so a cooldown never needs manual clearing.
# `clear` exists for tests and captain overrides, not for routine operation.
#
# Environment overrides (tests and callers):
#   FM_POOL_CONFIG                path to the pool config, overriding config/dispatch-pool.json
#   FM_POOL_KEY_DIR               key directory, overriding ~/.config/firstmate/keys
#   FM_POOL_NOW                   epoch seconds to treat as "now"
#   FM_POOL_MAX_COOLDOWN_SECONDS  ceiling on any single cooldown (default 86400)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
POOL_CONFIG="${FM_POOL_CONFIG:-$CONFIG/dispatch-pool.json}"
KEY_DIR="${FM_POOL_KEY_DIR:-$HOME/.config/firstmate/keys}"
MAX_COOLDOWN=${FM_POOL_MAX_COOLDOWN_SECONDS:-86400}
DEFAULT_COOLDOWN_FALLBACK=10800

# fm-wake-lib.sh is the owner of firstmate's portable lock helpers
# (fm_lock_try_acquire / fm_lock_release), which serialize the rotation cursor.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

log() {
  printf 'fm-pool: %s\n' "$*" >&2
}

now_epoch() {
  if [ -n "${FM_POOL_NOW:-}" ]; then
    printf '%s\n' "$FM_POOL_NOW"
  else
    date +%s
  fi
}

# Render an epoch as a local ISO-ish timestamp for human-facing messages.
fmt_epoch() {
  local epoch=$1
  date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
    || date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
    || printf 'epoch %s\n' "$epoch"
}

# Render a duration in seconds as a compact human string ("42m", "3h10m").
fmt_duration() {
  local secs=$1 h m
  [ "$secs" -gt 0 ] 2>/dev/null || { printf 'now\n'; return; }
  h=$((secs / 3600))
  m=$(((secs % 3600) / 60))
  if [ "$h" -gt 0 ]; then
    printf '%sh%sm\n' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%sm\n' "$m"
  else
    printf '%ss\n' "$secs"
  fi
}

# Expand a leading ~ and a $HOME reference in a config path or env value. This is
# the ONLY expansion performed on config values; nothing is passed to a shell.
expand_path() {
  local v=$1 tilde='~'
  # The tilde lives in a variable so this reads as deliberate prefix handling of
  # DATA, which is what it is - no shell tilde expansion is attempted anywhere.
  case "$v" in
    "$tilde") v=$HOME ;;
    "$tilde"/*) v=$HOME/${v:2} ;;
  esac
  printf '%s\n' "${v//\$HOME/$HOME}"
}

require_config() {
  if [ ! -f "$POOL_CONFIG" ]; then
    log "no dispatch pool configured ($POOL_CONFIG absent); the pool is inert and spawns behave exactly as they do without it"
    exit 3
  fi
  command -v jq >/dev/null 2>&1 || { log "jq is required to read $POOL_CONFIG"; exit 2; }
  if ! jq -e 'type == "object" and (.backends | type) == "array" and (.backends | length) > 0' \
      "$POOL_CONFIG" >/dev/null 2>&1; then
    log "$POOL_CONFIG must be an object with a non-empty \"backends\" array"
    exit 2
  fi
  if ! jq -e '[.backends[] | select((.id | type) != "string" or (.harness | type) != "string")] | length == 0' \
      "$POOL_CONFIG" >/dev/null 2>&1; then
    log "every backend in $POOL_CONFIG needs a string \"id\" and a string \"harness\""
    exit 2
  fi
  if ! jq -e '([.backends[].id] | length) == ([.backends[].id] | unique | length)' \
      "$POOL_CONFIG" >/dev/null 2>&1; then
    log "backend ids in $POOL_CONFIG must be unique"
    exit 2
  fi
}

default_cooldown_seconds() {
  local v
  v=$(jq -r '.cooldown_default_seconds // empty' "$POOL_CONFIG" 2>/dev/null)
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$DEFAULT_COOLDOWN_FALLBACK" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

backend_ids() {
  jq -r '.backends[].id' "$POOL_CONFIG"
}

# Print one field of one backend, or empty when unset.
backend_field() {
  local id=$1 field=$2
  jq -r --arg id "$id" --arg f "$field" '
    [.backends[] | select(.id == $id)][0][$f] // "" | if type == "string" then . else "" end
  ' "$POOL_CONFIG" 2>/dev/null
}

backend_exists() {
  local id=$1
  jq -e --arg id "$id" '[.backends[] | select(.id == $id)] | length > 0' "$POOL_CONFIG" >/dev/null 2>&1
}

backend_enabled() {
  local id=$1
  # Absent "enabled" means enabled; only an explicit false disables.
  jq -e --arg id "$id" '[.backends[] | select(.id == $id)][0] | (.enabled != false)' \
    "$POOL_CONFIG" >/dev/null 2>&1
}

# Print `NAME=VALUE` lines for the backend's non-secret env overrides.
backend_env_lines() {
  local id=$1 line name value
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%=*}
    value=${line#*=}
    printf 'env=%s=%s\n' "$name" "$(expand_path "$value")"
  done < <(jq -r --arg id "$id" '
    [.backends[] | select(.id == $id)][0].env // {}
    | to_entries[]
    | select((.value | type) == "string")
    | "\(.key)=\(.value)"
  ' "$POOL_CONFIG" 2>/dev/null)
}

# Resolve the key file path for a backend that declares key_env: explicit
# key_file wins, otherwise the shared key directory plus `<id>.key`.
backend_key_file() {
  local id=$1 kf
  kf=$(backend_field "$id" key_file)
  if [ -n "$kf" ]; then
    expand_path "$kf"
  else
    printf '%s/%s.key\n' "$KEY_DIR" "$id"
  fi
}

cooldown_file() {
  printf '%s/.pool-cooldown-%s\n' "$STATE" "$1"
}

# Print the remaining cooldown epoch for a backend, or nothing when it is not
# cooling. An expired cooldown is removed here, which is what makes cooldowns
# self-expiring and never in need of manual clearing.
cooldown_until() {
  local id=$1 f until now
  f=$(cooldown_file "$id")
  [ -f "$f" ] || return 1
  until=$(sed -n 's/^until=\([0-9][0-9]*\)$/\1/p' "$f" 2>/dev/null | tail -1)
  if [ -z "$until" ]; then
    rm -f "$f" 2>/dev/null || true
    return 1
  fi
  now=$(now_epoch)
  if [ "$now" -ge "$until" ]; then
    rm -f "$f" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$until"
}

cooldown_reason() {
  local f
  f=$(cooldown_file "$1")
  [ -f "$f" ] || return 1
  sed -n 's/^reason=//p' "$f" 2>/dev/null | tail -1
}

# Classify one backend. Prints "<state>\t<detail>" where state is
# ready|disabled|cooling|nokey. Every non-ready state carries a stated reason.
backend_state() {
  local id=$1 key_env key_file until
  if ! backend_enabled "$id"; then
    printf 'disabled\tdisabled in %s\n' "$POOL_CONFIG"
    return
  fi
  key_env=$(backend_field "$id" key_env)
  if [ -n "$key_env" ]; then
    key_file=$(backend_key_file "$id")
    if [ ! -f "$key_file" ]; then
      printf 'nokey\tno key file at %s\n' "$key_file"
      return
    fi
    # Read only enough to know the file is non-blank; the value is never printed.
    if ! LC_ALL=C tr -d '[:space:]' < "$key_file" | head -c 1 | grep -q .; then
      printf 'nokey\tkey file is empty: %s\n' "$key_file"
      return
    fi
  fi
  if until=$(cooldown_until "$id"); then
    printf 'cooling\tuntil %s (%s)\n' "$(fmt_epoch "$until")" "$(cooldown_reason "$id" || echo 'limit reported')"
    return
  fi
  printf 'ready\t\n'
}

# --- limit detection --------------------------------------------------------
#
# Convert a wall-clock reset token ("2:20pm", "14:20") in a named timezone to an
# epoch, rolling to tomorrow when that time has already passed today. Both BSD
# and GNU date are supported; an unparseable token returns non-zero so the caller
# falls back to the default cooldown rather than inventing a reset.
parse_reset_epoch() {
  local token=$1 tz=$2 hh mm ampm day epoch now
  token=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  case "$token" in
    [0-9]*:[0-9][0-9]am|[0-9]*:[0-9][0-9]pm)
      ampm=${token: -2}
      hh=${token%%:*}
      mm=${token#*:}
      mm=${mm%??}
      ;;
    [0-9]*:[0-9][0-9])
      ampm=
      hh=${token%%:*}
      mm=${token#*:}
      ;;
    [0-9]am|[0-9][0-9]am|[0-9]pm|[0-9][0-9]pm)
      ampm=${token: -2}
      hh=${token%??}
      mm=00
      ;;
    *) return 1 ;;
  esac
  case "$hh$mm" in *[!0-9]*) return 1 ;; esac
  [ "$hh" -le 23 ] 2>/dev/null || return 1
  [ "$mm" -le 59 ] 2>/dev/null || return 1
  case "$ampm" in
    am) [ "$hh" -le 12 ] || return 1; [ "$hh" -ne 12 ] || hh=0 ;;
    pm) [ "$hh" -le 12 ] || return 1; [ "$hh" -eq 12 ] || hh=$((hh + 12)) ;;
  esac
  [ -n "$tz" ] || tz=$(date +%Z)
  day=$(TZ="$tz" date +%Y-%m-%d 2>/dev/null) || return 1
  # Pin :00 seconds explicitly - BSD `date -j -f` leaves the CURRENT seconds in
  # place for any field the format string omits, which would make an otherwise
  # exact reset time drift by up to 59 seconds.
  local hhmm
  hhmm=$(printf '%02d:%02d:00' "$hh" "$mm")
  epoch=$(TZ="$tz" date -j -f '%Y-%m-%d %H:%M:%S' "$day $hhmm" +%s 2>/dev/null) \
    || epoch=$(TZ="$tz" date -d "$day $hhmm" +%s 2>/dev/null) \
    || return 1
  now=$(now_epoch)
  # A reset that already passed today is tomorrow's reset.
  while [ "$epoch" -le "$now" ]; do
    epoch=$((epoch + 86400))
  done
  printf '%s\n' "$epoch"
}

# Read agent output on stdin and classify any usage-limit signature in it.
# Prints `limit=`, `reset_epoch=`, and `reason=` lines; exits 1 when the text
# holds no limit signature at all.
detect_limit() {
  local text kind reason token tz epoch
  text=$(cat)
  kind=
  reason=
  if printf '%s' "$text" | grep -qiE "hit your (session|usage) limit|session limit reached|rate limit reached"; then
    kind=session-limit
    reason=$(printf '%s' "$text" | grep -oiE "[^|]*hit your (session|usage) limit[^|]*" | head -1)
  elif printf '%s' "$text" | grep -qiE "usage credits exhausted|out of usage credits|credit balance is too low"; then
    kind=credits-exhausted
    reason=$(printf '%s' "$text" | grep -oiE "[^|]*(usage credits exhausted|out of usage credits|credit balance is too low)[^|]*" | head -1)
  elif printf '%s' "$text" | grep -qiE "quota exceeded|insufficient quota"; then
    kind=quota-exceeded
    reason=$(printf '%s' "$text" | grep -oiE "[^|]*(quota exceeded|insufficient quota)[^|]*" | head -1)
  else
    return 1
  fi
  # Reset token: "resets 2:20pm (America/Los_Angeles)" and the "resets at" variant.
  token=$(printf '%s' "$text" | sed -n 's/.*[Rr]esets\( at\)\{0,1\} \([0-9][0-9]*:\{0,1\}[0-9]*[ ]\{0,1\}[APMapm]\{0,2\}\).*/\2/p' | head -1)
  tz=$(printf '%s' "$text" | sed -n 's/.*[Rr]esets[^(]*(\([A-Za-z_]*\/[A-Za-z_]*\)).*/\1/p' | head -1)
  epoch=
  if [ -n "$token" ]; then
    epoch=$(parse_reset_epoch "$token" "$tz" || true)
  fi
  # Collapse the reason to one clean single line; it goes into state and stderr.
  reason=$(printf '%s' "$reason" | tr -d '\r' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//' | cut -c1-160)
  [ -n "$reason" ] || reason=$kind
  printf 'limit=%s\n' "$kind"
  printf 'reset_epoch=%s\n' "$epoch"
  printf 'reason=%s\n' "$reason"
}

write_cooldown() {
  local id=$1 until=$2 reason=$3 f now
  now=$(now_epoch)
  # Clamp: a misparsed reset must never strand an account. The ceiling keeps a
  # bad parse bounded, and a past/absent value still yields a real cooldown.
  if [ -z "$until" ] || [ "$until" -le "$now" ] 2>/dev/null; then
    until=$((now + $(default_cooldown_seconds)))
  fi
  if [ "$((until - now))" -gt "$MAX_COOLDOWN" ]; then
    until=$((now + MAX_COOLDOWN))
  fi
  mkdir -p "$STATE" 2>/dev/null || true
  f=$(cooldown_file "$id")
  {
    printf 'until=%s\n' "$until"
    printf 'set=%s\n' "$now"
    printf 'reason=%s\n' "$reason"
  } > "$f"
  printf '%s\n' "$until"
}

# --- rotation ---------------------------------------------------------------

CURSOR_FILE=
POOL_LOCK=
POOL_LOCK_HELD=0

pool_lock_release() {
  [ "$POOL_LOCK_HELD" = 1 ] || return 0
  POOL_LOCK_HELD=0
  fm_lock_release "$POOL_LOCK" || true
}
trap pool_lock_release EXIT

cmd_select() {
  local harness_filter='' exclude='' peek=0 a want=''
  for a in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in
        harness) harness_filter=$a ;;
        exclude) exclude=$a ;;
      esac
      want=
      continue
    fi
    case "$a" in
      --harness) want=harness ;;
      --harness=*) harness_filter=${a#--harness=} ;;
      --exclude) want=exclude ;;
      --exclude=*) exclude=${a#--exclude=} ;;
      --peek|--no-advance) peek=1 ;;
      *) log "unknown select option '$a'"; exit 2 ;;
    esac
  done
  [ -z "$want" ] || { log "--$want requires a value"; exit 2; }
  require_config

  local ids=() id state detail
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ids+=("$id")
  done < <(backend_ids)

  mkdir -p "$STATE" 2>/dev/null || true
  CURSOR_FILE="$STATE/.pool-cursor"
  POOL_LOCK="$STATE/.pool.lock"
  # Bounded acquisition, never fm_lock_acquire_wait: that helper spins forever,
  # and a wedged rotation lock must not be able to hang a spawn.
  local attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$POOL_LOCK"; then POOL_LOCK_HELD=1; break; fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$POOL_LOCK_HELD" = 1 ]; then
    :
  else
    # Rotation fairness is not worth blocking a spawn over: proceed unlocked and
    # say so, rather than refusing to select an account at all.
    log "rotation lock busy; selecting without it (rotation may repeat an account)"
  fi

  local last='' start=0 i n=${#ids[@]}
  [ ! -f "$CURSOR_FILE" ] || last=$(head -1 "$CURSOR_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$last" ]; then
    for i in $(seq 0 $((n - 1))); do
      if [ "${ids[$i]}" = "$last" ]; then start=$((i + 1)); break; fi
    done
  fi

  local chosen='' skipped=() idx
  for i in $(seq 0 $((n - 1))); do
    idx=$(((start + i) % n))
    id=${ids[$idx]}
    [ "$id" != "$exclude" ] || { skipped+=("$id: excluded by caller"); continue; }
    if [ -n "$harness_filter" ] && [ "$(backend_field "$id" harness)" != "$harness_filter" ]; then
      skipped+=("$id: harness is not $harness_filter")
      continue
    fi
    IFS=$'\t' read -r state detail < <(backend_state "$id")
    if [ "$state" = ready ]; then chosen=$id; break; fi
    skipped+=("$id: $state, $detail")
  done

  local s
  for s in ${skipped[@]+"${skipped[@]}"}; do
    log "skipping $s"
  done

  if [ -z "$chosen" ]; then
    report_all_unavailable "$exclude" "$harness_filter"
    exit 4
  fi

  [ "$peek" = 1 ] || printf '%s\n' "$chosen" > "$CURSOR_FILE"
  pool_lock_release
  print_backend_block "$chosen"
}

# The `select` stdout contract, shared with `resolve`. A key's CONTENT is never
# read here - only its path travels, so the secret stays out of every log.
print_backend_block() {
  local id=$1 key_env key_file
  printf 'backend=%s\n' "$id"
  printf 'harness=%s\n' "$(backend_field "$id" harness)"
  printf 'model=%s\n' "$(backend_field "$id" model)"
  printf 'effort=%s\n' "$(backend_field "$id" effort)"
  backend_env_lines "$id"
  key_env=$(backend_field "$id" key_env)
  if [ -n "$key_env" ]; then
    key_file=$(backend_key_file "$id")
    printf 'key_env=%s\n' "$key_env"
    printf 'key_file=%s\n' "$key_file"
  fi
}

# resolve <id> prints the same block for one NAMED backend, without rotating.
# Used when a caller already knows which account it wants (failover pinning a
# replacement). It still refuses an unhealthy backend, so pinning cannot route
# work to a cooling or keyless account.
cmd_resolve() {
  local id=${1:-} state detail
  [ -n "$id" ] || { log "resolve requires a backend id"; exit 2; }
  require_config
  backend_exists "$id" || { log "unknown backend '$id'"; exit 2; }
  IFS=$'\t' read -r state detail < <(backend_state "$id")
  if [ "$state" != ready ]; then
    log "backend $id is $state: $detail"
    exit 4
  fi
  print_backend_block "$id"
}

# Every backend is unavailable: say so once, clearly, and name the earliest
# reset so the caller can tell the captain when work can resume.
report_all_unavailable() {
  local exclude=$1 harness_filter=$2 id state detail until best='' best_id=''
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$id" != "$exclude" ] || continue
    if [ -n "$harness_filter" ] && [ "$(backend_field "$id" harness)" != "$harness_filter" ]; then
      continue
    fi
    if until=$(cooldown_until "$id"); then
      if [ -z "$best" ] || [ "$until" -lt "$best" ]; then best=$until; best_id=$id; fi
    fi
  done < <(backend_ids)
  if [ -n "$best" ]; then
    log "every backend is cooling down; earliest reset is $best_id at $(fmt_epoch "$best") (in $(fmt_duration $((best - $(now_epoch)))))"
  else
    log "no healthy backend is available; run 'fm-pool.sh status' for the per-backend reason"
  fi
}

cmd_status() {
  require_config
  local json=0 id state detail harness until
  [ "${1:-}" != "--json" ] || json=1
  if [ "$json" = 1 ]; then
    command -v jq >/dev/null 2>&1 || { log "jq is required for --json"; exit 2; }
  fi
  local rows=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    harness=$(backend_field "$id" harness)
    IFS=$'\t' read -r state detail < <(backend_state "$id")
    until=
    [ "$state" != cooling ] || until=$(cooldown_until "$id" || true)
    if [ "$json" = 1 ]; then
      rows+=("$(jq -nc --arg id "$id" --arg h "$harness" --arg s "$state" \
        --arg d "$detail" --arg u "$until" \
        '{id: $id, harness: $h, state: $s, detail: $d, until: (if $u == "" then null else ($u | tonumber) end)}')")
    else
      rows+=("$(printf '%-12s %-8s %-9s %s' "$id" "$harness" "$state" "$detail")")
    fi
  done < <(backend_ids)
  if [ "$json" = 1 ]; then
    printf '%s\n' "${rows[@]}" | jq -sc '{backends: .}'
  else
    printf '%s\n' "${rows[@]}"
  fi
}

cmd_backends() {
  require_config
  backend_ids
}

cmd_cooldown() {
  local id='' seconds='' until='' reason='' src='' a want=''
  for a in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in
        seconds) seconds=$a ;;
        until) until=$a ;;
        reason) reason=$a ;;
        from-file) src=$a ;;
      esac
      want=
      continue
    fi
    case "$a" in
      --seconds) want=seconds ;;
      --seconds=*) seconds=${a#--seconds=} ;;
      --until) want=until ;;
      --until=*) until=${a#--until=} ;;
      --reason) want=reason ;;
      --reason=*) reason=${a#--reason=} ;;
      --from-file) want=from-file ;;
      --from-file=*) src=${a#--from-file=} ;;
      --from-stdin) src=- ;;
      -*) log "unknown cooldown option '$a'"; exit 2 ;;
      *) [ -z "$id" ] || { log "cooldown takes one backend id"; exit 2; }; id=$a ;;
    esac
  done
  [ -z "$want" ] || { log "--$want requires a value"; exit 2; }
  [ -n "$id" ] || { log "cooldown requires a backend id"; exit 2; }
  require_config
  backend_exists "$id" || { log "unknown backend '$id'"; exit 2; }

  local now detected epoch=
  now=$(now_epoch)
  if [ -n "$src" ]; then
    if [ "$src" = - ]; then
      detected=$(detect_limit || true)
    else
      [ -f "$src" ] || { log "cannot read agent output at $src"; exit 2; }
      detected=$(detect_limit < "$src" || true)
    fi
    if [ -z "$detected" ]; then
      log "no usage-limit signature found in the supplied agent output; not cooling $id down"
      exit 1
    fi
    epoch=$(printf '%s\n' "$detected" | sed -n 's/^reset_epoch=//p')
    [ -n "$reason" ] || reason=$(printf '%s\n' "$detected" | sed -n 's/^reason=//p')
  fi
  if [ -n "$until" ]; then
    case "$until" in *[!0-9]*) log "--until takes epoch seconds"; exit 2 ;; esac
    epoch=$until
  elif [ -n "$seconds" ]; then
    case "$seconds" in *[!0-9]*) log "--seconds takes a whole number"; exit 2 ;; esac
    epoch=$((now + seconds))
  fi
  [ -n "$reason" ] || reason='usage limit reported'
  local applied
  applied=$(write_cooldown "$id" "$epoch" "$reason")
  printf 'cooldown %s until=%s (%s, in %s)\n' \
    "$id" "$applied" "$(fmt_epoch "$applied")" "$(fmt_duration $((applied - now)))"
}

cmd_clear() {
  local id=${1:-}
  [ -n "$id" ] || { log "clear requires a backend id"; exit 2; }
  require_config
  backend_exists "$id" || { log "unknown backend '$id'"; exit 2; }
  rm -f "$(cooldown_file "$id")"
  printf 'cleared %s\n' "$id"
}

cmd_detect() {
  local file=
  case "${1:-}" in
    --file) file=${2:-} ;;
    --file=*) file=${1#--file=} ;;
    '') ;;
    *) log "unknown detect option '$1'"; exit 2 ;;
  esac
  if [ -n "$file" ]; then
    [ -f "$file" ] || { log "cannot read $file"; exit 2; }
    detect_limit < "$file"
  else
    detect_limit
  fi
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac
SUB=$1
shift
case "$SUB" in
  select) cmd_select "$@" ;;
  resolve) cmd_resolve "$@" ;;
  status) cmd_status "$@" ;;
  backends) cmd_backends "$@" ;;
  cooldown) cmd_cooldown "$@" ;;
  clear) cmd_clear "$@" ;;
  detect) cmd_detect "$@" ;;
  *) log "unknown subcommand '$SUB'"; usage >&2; exit 2 ;;
esac
