# shellcheck shell=bash
# fm-claim-lib.sh - atomic mechanism for cross-home work claims.
#
# The claim record format, the machine-wide claim root, the canonical-target
# normalization rules, and the CLI exit codes are owned by docs/configuration.md
# under "Cross-home work claims" - this file owns the mechanism: the portable
# hash, the create-if-absent write, the stale-holder proof, and the short
# per-target mutex that makes a stale reclaim race-free.
#
# Usage: . bin/fm-claim-lib.sh   (no other dependency; harness-neutral)
#
# WHY A MACHINE-WIDE ROOT. A claim says "one firstmate home owns this shared
# external target". That rule cannot live inside a single home, exactly as
# bin/fm-procevent-lib.sh's source claim root cannot, because the whole point is
# to be visible to every other home on this machine. The primary home and every
# LOCAL secondmate share one filesystem (docs/configuration.md "FM_HOME"), so a
# shared directory coordinates them. A remote secondmate is a separate host by
# construction (docs/remote-secondmates.md), so it is outside this mechanism -
# state that limit, never imply cross-machine claims.

# fm_claim_root: the machine-wide claim root. FM_CLAIM_ROOT overrides it for
# tests and specialized setups, mirroring FM_PROCEVENT_CLAIM_ROOT.
fm_claim_root() {
  printf '%s\n' "${FM_CLAIM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/claims}"
}

# fm_claim_pending_grace: seconds during which a claim whose task record is not
# yet visible is treated as still-live rather than stale. A live claimant
# acquires the claim just before it publishes state/<task>.meta, so this window
# must cover that gap; it also bounds how long a claim leaked by a failed spawn
# blocks a retry before it becomes reclaimable.
fm_claim_pending_grace() {
  printf '%s\n' "${FM_CLAIM_PENDING_GRACE:-300}"
}

fm_claim_kind_valid() {
  case "${1-}" in
  pr | issue | area) return 0 ;;
  *) return 1 ;;
  esac
}

# fm_claim_task_valid: a claim's task id must be safe to embed in a
# `<home>/state/<task>.meta` existence probe, so it follows the same shape as a
# task id (bin/fm-pr-lib.sh's fm_task_id_path_safe) without pulling that lib in.
fm_claim_task_valid() {
  local id=${1-}
  case "$id" in
  '' | .* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 128 ]
}

fm_claim_key_valid() {
  local key=${1-}
  [ -n "$key" ] || return 1
  [ "${#key}" -le 512 ] || return 1
  case "$key" in
  *$'\n'* | *" "*) return 1 ;;
  esac
}

# fm_claim_hash <string>: 16 lowercase hex chars. shasum (macOS/BSD) or
# sha256sum (GNU), matching bin/fm-backend-hometag-lib.sh's portable pattern.
fm_claim_hash() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,16)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print substr($1,1,16)}')
  else
    return 1
  fi
  case "$out" in
  '' | *[!0-9a-f]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

fm_claim_slug() {
  local s=${1-}
  s=${s//[^A-Za-z0-9._-]/_}
  printf '%s\n' "${s:0:48}"
}

# fm_claim_path <canonical-key>: the claim file for a target. The name is
# `<hash16>-<slug>.claim` so the mapping is deterministic from the canonical key
# while staying path-safe and human-scannable.
fm_claim_path() {
  local key=$1 hash slug
  hash=$(fm_claim_hash "$key") || return 1
  slug=$(fm_claim_slug "$key")
  printf '%s/%s-%s.claim\n' "$(fm_claim_root)" "$hash" "$slug"
}

# fm_claim_read <path>: parse a claim record into FM_CLAIM_* globals. Returns
# non-zero on a missing, symlinked, or unreadable record, or on one whose
# mandatory fields are absent, so callers fail closed rather than trusting a
# torn or foreign file.
# shellcheck disable=SC2034 # FM_CLAIM_KIND/TARGET/PID/HOST are output globals read by the sourcing CLI (bin/fm-claim.sh).
fm_claim_read() {
  local path=$1 line
  FM_CLAIM_SCHEMA=
  FM_CLAIM_KEY=
  FM_CLAIM_KIND=
  FM_CLAIM_TARGET=
  FM_CLAIM_HOME=
  FM_CLAIM_TASK=
  FM_CLAIM_CREATED=
  FM_CLAIM_PID=
  FM_CLAIM_HOST=
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    schema=*) FM_CLAIM_SCHEMA=${line#schema=} ;;
    key=*) FM_CLAIM_KEY=${line#key=} ;;
    kind=*) FM_CLAIM_KIND=${line#kind=} ;;
    target=*) FM_CLAIM_TARGET=${line#target=} ;;
    home=*) FM_CLAIM_HOME=${line#home=} ;;
    task=*) FM_CLAIM_TASK=${line#task=} ;;
    created=*) FM_CLAIM_CREATED=${line#created=} ;;
    pid=*) FM_CLAIM_PID=${line#pid=} ;;
    host=*) FM_CLAIM_HOST=${line#host=} ;;
    esac
  done <"$path" 2>/dev/null || true
  [ "$FM_CLAIM_SCHEMA" = "fm-claim.v1" ] || return 1
  [ -n "$FM_CLAIM_KEY" ] && [ -n "$FM_CLAIM_HOME" ] && [ -n "$FM_CLAIM_TASK" ] || return 1
  return 0
}

# fm_claim_stale <path>: 0 only when the holder is PROVABLY gone - its recorded
# home directory is absent, or its task record is absent and the claim is older
# than the pending grace. Any uncertainty returns non-zero (never steal a claim
# that cannot be proven dead), mirroring bin/fm-lock-lib.sh's fail-safe rule.
fm_claim_stale() {
  local now age grace
  fm_claim_read "$1" || return 1
  [ -n "$FM_CLAIM_HOME" ] || return 0
  if [ ! -d "$FM_CLAIM_HOME" ]; then
    return 0
  fi
  if [ -e "$FM_CLAIM_HOME/state/$FM_CLAIM_TASK.meta" ] || [ -L "$FM_CLAIM_HOME/state/$FM_CLAIM_TASK.meta" ]; then
    return 1
  fi
  case "$FM_CLAIM_CREATED" in
  '' | *[!0-9]*) return 0 ;;
  esac
  now=$(date +%s) || return 1
  grace=$(fm_claim_pending_grace)
  case "$grace" in
  '' | *[!0-9]*) grace=300 ;;
  esac
  age=$((now - FM_CLAIM_CREATED))
  [ "$age" -ge "$grace" ]
}

# fm_claim_mutex_acquire <lockdir> [tries]: a short critical section around the
# read-decide-replace of one target's claim file. mkdir is the atomic create; a
# lock whose recorded pid is dead is removed once, so a crashed CLI never wedges
# the target. Bounded, then fails closed.
fm_claim_mutex_acquire() {
  local lockdir=$1 tries=${2:-50} n=0 pid
  while :; do
    if (umask 077; mkdir "$lockdir") 2>/dev/null; then
      printf '%s\n' "$$" >"$lockdir/pid" 2>/dev/null || true
      return 0
    fi
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$lockdir/pid" 2>/dev/null || true
      rmdir "$lockdir" 2>/dev/null || true
      continue
    fi
    n=$((n + 1))
    if [ "$n" -ge "$tries" ]; then
      return 1
    fi
    sleep 0.1
  done
}

fm_claim_mutex_release() {
  [ -n "${1:-}" ] || return 0
  rm -f "$1/pid" 2>/dev/null || true
  rmdir "$1" 2>/dev/null || true
}

# fm_claim_write_record <path> <key> <kind> <target> <home> <task>: write a
# fresh fm-claim.v1 record atomically. The caller holds the target's mutex.
fm_claim_write_record() {
  local path=$1 key=$2 kind=$3 target=$4 home=$5 task=$6 root tmp
  root=$(dirname "$path") || return 1
  tmp=$(umask 077; mktemp "$root/.claim.XXXXXX") || return 1
  {
    printf 'schema=fm-claim.v1\n'
    printf 'key=%s\n' "$key"
    printf 'kind=%s\n' "$kind"
    printf 'target=%s\n' "$target"
    printf 'home=%s\n' "$home"
    printf 'task=%s\n' "$task"
    printf 'created=%s\n' "$(date +%s)"
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "$(uname -n 2>/dev/null || printf 'unknown')"
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 0600 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$path" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# fm_claim_root_ok <dir>: the root must exist, be a real directory (not a
# symlink), and be private to this user (mode 0700), so no other local account
# can inject or forge claims.
fm_claim_root_ok() {
  local dir=$1 mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$dir" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
  fi
  case "$mode" in
  700 | 0700) return 0 ;;
  *) return 1 ;;
  esac
}

# --- canonical target normalization ----------------------------------------
#
# Two homes naming the same external target must produce the SAME canonical key,
# so a second claim refuses. The canonical forms (owned by docs/configuration.md
# "Cross-home work claims") are:
#   pr:<host>/<owner>/<repo>#<n>      issue:<host>/<owner>/<repo>#<n>
#   issue:<TICKET-ID>                 area:<project>:<normalized-path>

fm_claim_norm_area() {
  local raw=$1 project path
  case "$raw" in
  area:*) raw=${raw#area:} ;;
  esac
  case "$raw" in
  *:*) ;;
  *) return 1 ;;
  esac
  project=${raw%%:*}
  path=${raw#*:}
  [ -n "$project" ] && [ -n "$path" ] || return 1
  case "$project" in
  *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$path" in
  *$'\n'*) return 1 ;;
  esac
  while [ "$path" != "${path#./}" ]; do path=${path#./}; done
  path=$(printf '%s' "$path" | tr -s '/')
  path=${path#/}
  while [ "$path" != "${path%/}" ]; do path=${path%/}; done
  [ -n "$path" ] || return 1
  printf 'area:%s:%s\n' "$project" "$path"
}

fm_claim_norm_ref() {
  local kind=$1 raw=$2 host owner repo num sub rest path
  case "$raw" in
  http://* | https://*)
    rest=${raw#*://}
    local authority=${rest%%/*}
    path=${rest#"$authority"}
    path=${path%%[?#]*}
    host=${authority%%:*}
    host=${host,,}
    [ -n "$host" ] || return 1
    path=${path#/}
    owner=${path%%/*}
    rest=${path#*/}
    repo=${rest%%/*}
    rest=${rest#*/}
    sub=${rest%%/*}
    rest=${rest#*/}
    num=${rest%%/*}
    case "$kind" in
    pr) case "$sub" in pull | merge_requests) ;; *) return 1 ;; esac ;;
    issue) case "$sub" in issues) ;; *) return 1 ;; esac ;;
    *) return 1 ;;
    esac
    ;;
  *'#'*)
    local base=${raw%#*}
    num=${raw#*#}
    case "$base" in
    */*) ;;
    *) return 1 ;;
    esac
    owner=${base%%/*}
    repo=${base#*/}
    host=github.com
    ;;
  *)
    [ "$kind" = issue ] || return 1
    local up=${raw^^}
    case "$up" in
    *[!A-Z0-9-]*) return 1 ;;
    esac
    case "${up%%-*}" in
    '' | *[!A-Z0-9]*) return 1 ;;
    esac
    case "${up#*-}" in
    '' | *[!0-9]*) return 1 ;;
    esac
    printf 'issue:%s\n' "$up"
    return 0
    ;;
  esac
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$num" ] || return 1
  case "$num" in
  *[!0-9]*) return 1 ;;
  esac
  case "$owner$repo" in
  *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  owner=${owner,,}
  repo=${repo,,}
  printf '%s:%s/%s/%s#%s\n' "$kind" "$host" "$owner" "$repo" "$num"
}

# fm_claim_normalize <kind> <raw>: the canonical key, or non-zero on anything
# that cannot be normalized unambiguously.
fm_claim_normalize() {
  local kind=$1 raw=$2
  fm_claim_kind_valid "$kind" || return 1
  case "$raw" in
  '' | *$'\n'*) return 1 ;;
  esac
  case "$kind" in
  area) fm_claim_norm_area "$raw" ;;
  pr | issue) fm_claim_norm_ref "$kind" "$raw" ;;
  *) return 1 ;;
  esac
}

# fm_claim_kind_of <raw>: detect a target kind when the caller did not name one.
# A bare `owner/repo#N` is ambiguous on GitHub (issues and PRs share numbering),
# so it resolves to pr; pass --kind issue for an issue reference.
fm_claim_kind_of() {
  local raw=$1
  case "$raw" in
  area:*) printf 'area\n' ;;
  http://* | https://*)
    case "$raw" in
    */pull/* | */merge_requests/*) printf 'pr\n' ;;
    */issues/*) printf 'issue\n' ;;
    *) return 1 ;;
    esac
    ;;
  *'#'*) printf 'pr\n' ;;
  *)
    case "${raw^^}" in
    [A-Z0-9]*-[0-9]*) printf 'issue\n' ;;
    *) return 1 ;;
    esac
    ;;
  esac
}
