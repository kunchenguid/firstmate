# shellcheck shell=bash
# Best-effort "is a newer STABLE version available?" probe for fm-bootstrap.sh.
# Usage: . bin/fm-update-check-lib.sh   then   uc_report <root> <state-dir> <detect-only>
#
# fm-bootstrap.sh already enforces a version FLOOR (is the tool present, is it new
# enough to work at all). This library answers the other question - has the fleet
# silently fallen behind a released fix - and prints one line per stale tool:
#
#   UPDATE_AVAILABLE: <tool> <current> -> <latest> (update: <command>)
#
# It covers no-mistakes and treehouse (GitHub releases), tasks-axi (npm registry),
# and firstmate itself (commits behind origin's default branch, updated via
# /updatefirstmate rather than a raw git command).
#
# It is REPORT-ONLY and never installs anything: firstmate surfaces the line to
# the captain, who consents, exactly like the MISSING: flow. `no-mistakes update`
# restarts its daemon and kills any active pipeline run, so its suggestion says so.
#
# Four properties this library must never violate:
#   1. It cannot fail or hang bootstrap. Every network probe is a background child
#      whose stdout is redirected to a result FILE, never to bootstrap's stdout, so
#      a straggler can never hold open a caller's $(...) capture; probes are bounded
#      by FM_UPDATE_CHECK_TIMEOUT (default 5s) on top of curl's own --max-time and
#      git's http low-speed bound. Offline, rate-limited, unauthenticated, or missing
#      curl/jq all degrade to silence. uc_report always returns 0.
#   2. It never nags onto a prerelease. GitHub releases carrying draft:true or
#      prerelease:true are filtered out, and any tag that is not a bare vX.Y.Z is
#      refused. This is not hypothetical: no-mistakes v1.33.0 was a PRERELEASE while
#      v1.31.2 was the newest stable, so a naive "latest release" check would have
#      recommended a downgrade onto a known gate bug.
#   3. It caches. The remote answers (not the report) are cached in
#      <state>/.update-check with a checked_at epoch; a hit inside
#      FM_UPDATE_CHECK_TTL (default 86400s) makes ZERO network calls, while the
#      local current-version reads still run so the report stays accurate. A
#      read-only session (FM_BOOTSTRAP_DETECT_ONLY=1, i.e. it did not get the fleet
#      lock) probes but never writes the cache. A probe round that learned nothing
#      writes no cache either, so a transient outage does not blind the next 24h.
#   4. It is silent when everything is current, per bootstrap's silence-means-all-good
#      contract.
#
# Set FM_UPDATE_CHECK=0 to skip the check entirely; tests/lib.sh exports that so the
# suite stays hermetic, and the update-check cases opt back in explicitly.

if ! command -v fm_default_branch >/dev/null 2>&1; then
  # shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tangle-lib.sh"
fi

UC_CACHE_KEYS="no-mistakes treehouse tasks-axi firstmate"
UC_PIDS=()
UC_KEYS=()

uc_enabled() {
  [ "${FM_UPDATE_CHECK:-1}" != 0 ]
}

# Hard bound per probe round, in seconds. Mirrors FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT's
# contract: a non-numeric or non-positive override falls back to the default.
uc_timeout() {
  local v=${FM_UPDATE_CHECK_TIMEOUT:-}
  case "$v" in
    ''|*[!0-9]*) printf '5\n'; return 0 ;;
  esac
  [ "$v" -gt 0 ] || { printf '5\n'; return 0; }
  printf '%s\n' "$v"
}

# Cache lifetime in seconds. 0 is legal and forces a refresh every run.
uc_ttl() {
  local v=${FM_UPDATE_CHECK_TTL:-}
  case "$v" in
    ''|*[!0-9]*) printf '86400\n'; return 0 ;;
  esac
  printf '%s\n' "$v"
}

# Echo "<major> <minor> <patch>" for any string containing a semver triple, or return 1.
uc_semver_triple() {
  local out
  out=$(printf '%s\n' "$1" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# A stable version is a BARE vX.Y.Z or X.Y.Z. Anything carrying a prerelease or build
# suffix (v1.2.0-rc1, 1.2.0+build) is refused, so a mislabeled GitHub release or an
# npm `latest` dist-tag pointing at a prerelease can never produce a suggestion.
uc_is_stable_version() {
  printf '%s\n' "$1" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$'
}

# uc_version_gt "<M m p>" "<M m p>": true when the first triple is strictly newer.
uc_version_gt() {
  local a1 a2 a3 b1 b2 b3
  read -r a1 a2 a3 <<< "$1"
  read -r b1 b2 b3 <<< "$2"
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}

# --- probes (run as background children; stdout is their result file) -------

# Newest STABLE release tag of <owner/repo>, or return 1. GitHub returns releases
# newest-first by creation, which is NOT the same as newest by version once
# prereleases are interleaved, so pick the max by semver rather than the first row.
uc_latest_stable_release() {
  local repo=$1 timeout=$2 tags tag best best_t t
  tags=$(curl -fsSL --max-time "$timeout" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/releases?per_page=30" 2>/dev/null \
    | jq -r '.[]? | select((.draft // false) | not) | select((.prerelease // false) | not) | .tag_name // empty' 2>/dev/null)
  [ -n "$tags" ] || return 1
  best=""
  best_t=""
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    uc_is_stable_version "$tag" || continue
    t=$(uc_semver_triple "$tag") || continue
    if [ -z "$best" ] || uc_version_gt "$t" "$best_t"; then
      best=$tag
      best_t=$t
    fi
  done <<< "$tags"
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Version behind npm's `latest` dist-tag for <pkg>, or return 1.
uc_latest_npm_version() {
  local pkg=$1 timeout=$2 v
  v=$(curl -fsSL --max-time "$timeout" "https://registry.npmjs.org/$pkg/latest" 2>/dev/null \
    | jq -r '.version // empty' 2>/dev/null)
  [ -n "$v" ] || return 1
  uc_is_stable_version "$v" || return 1
  printf '%s\n' "$v"
}

# Commit sha of origin's <branch>, read WITHOUT fetching so nothing in the repo is
# mutated. Credential and host-key prompts are disabled so this can never block.
uc_remote_default_head() {
  local root=$1 branch=$2 timeout=$3 sha
  sha=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
    git -C "$root" -c http.lowSpeedLimit=1 -c "http.lowSpeedTime=$timeout" \
    ls-remote --heads origin "$branch" 2>/dev/null | awk 'NR==1 {print $1}')
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# --- bounded parallel probe driver -----------------------------------------

# Run <func> <args...> as a background child. Its stdout goes to <wd>/<key>, NEVER to
# our own stdout: bootstrap's output is read through $(...), and a child inheriting
# that pipe would keep the capture open past bootstrap's own exit.
uc_spawn_probe() {
  local wd=$1 key=$2
  shift 2
  ( "$@" > "$wd/$key" 2>/dev/null; : > "$wd/$key.done" ) >/dev/null 2>&1 &
  UC_PIDS+=("$!")
  UC_KEYS+=("$key")
}

uc_wait_probes() {
  local wd=$1 timeout=$2 start key pid pending
  [ "${#UC_KEYS[@]}" -gt 0 ] || return 0
  start=$SECONDS
  while :; do
    pending=0
    for key in "${UC_KEYS[@]}"; do
      [ -f "$wd/$key.done" ] || pending=1
    done
    [ "$pending" -eq 0 ] && return 0
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      for pid in "${UC_PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
      done
      return 1
    fi
    sleep 0.2
  done
}

# Probe every checkable tool in parallel into <wd>. A tool that is not installed is
# not probed: its absence is already the MISSING: flow's business, not ours.
uc_refresh() {
  local root=$1 wd=$2 timeout=$3 branch
  UC_PIDS=()
  UC_KEYS=()
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    if command -v no-mistakes >/dev/null 2>&1; then
      uc_spawn_probe "$wd" no-mistakes uc_latest_stable_release kunchenguid/no-mistakes "$timeout"
    fi
    if command -v treehouse >/dev/null 2>&1; then
      uc_spawn_probe "$wd" treehouse uc_latest_stable_release kunchenguid/treehouse "$timeout"
    fi
    if command -v tasks-axi >/dev/null 2>&1; then
      uc_spawn_probe "$wd" tasks-axi uc_latest_npm_version tasks-axi "$timeout"
    fi
  fi
  branch=$(fm_default_branch "$root" 2>/dev/null || true)
  if [ -n "$branch" ] && git -C "$root" remote get-url origin >/dev/null 2>&1; then
    uc_spawn_probe "$wd" firstmate uc_remote_default_head "$root" "$branch" "$timeout"
  fi
  uc_wait_probes "$wd" "$timeout" || true
  return 0
}

# --- cache ------------------------------------------------------------------

uc_read_value() {
  [ -f "$1" ] || return 0
  tr -d '[:space:]' < "$1" 2>/dev/null || true
}

uc_cache_fresh() {
  local cache=$1 now=$2 ttl=$3 checked
  [ -f "$cache" ] || return 1
  checked=$(sed -n 's/^checked_at=//p' "$cache" 2>/dev/null | head -n 1)
  case "$checked" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ $((now - checked)) -lt "$ttl" ]
}

# Load cached remote answers into <wd> as if they had just been probed. The key
# allowlist means a corrupted cache line can never name a path outside <wd>.
uc_cache_load() {
  local cache=$1 wd=$2 key val
  while IFS='=' read -r key val; do
    case " $UC_CACHE_KEYS " in
      *" $key "*) ;;
      *) continue ;;
    esac
    [ -n "$val" ] || continue
    printf '%s\n' "$val" > "$wd/$key" 2>/dev/null || true
  done < "$cache"
}

# Persist only a round that actually learned something: caching an all-empty probe
# would suppress retries for a full TTL after one transient outage.
uc_cache_write() {
  local cache=$1 wd=$2 now=$3 key val wrote tmp
  wrote=0
  tmp="$cache.$$.tmp"
  {
    printf 'checked_at=%s\n' "$now"
    for key in $UC_CACHE_KEYS; do
      val=$(uc_read_value "$wd/$key")
      [ -n "$val" ] || continue
      wrote=1
      printf '%s=%s\n' "$key" "$val"
    done
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  if [ "$wrote" -eq 1 ]; then
    mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# --- report -----------------------------------------------------------------

uc_current_version() {
  command -v "$1" >/dev/null 2>&1 || return 0
  "$1" --version 2>/dev/null | head -n 1
}

uc_emit_tool() {
  local tool=$1 cur=$2 latest=$3 cmd=$4 ct lt
  [ -n "$cur" ] && [ -n "$latest" ] || return 0
  uc_is_stable_version "$latest" || return 0
  ct=$(uc_semver_triple "$cur") || return 0
  lt=$(uc_semver_triple "$latest") || return 0
  uc_version_gt "$lt" "$ct" || return 0
  printf 'UPDATE_AVAILABLE: %s %s -> %s (update: %s)\n' "$tool" "${ct// /.}" "${lt// /.}" "$cmd"
}

# firstmate's own staleness is measured in commits, not versions. The remote sha is
# only counted against when its objects are already local (a prior fetch); otherwise
# we know we are behind but not by how much, and say exactly that.
uc_emit_firstmate() {
  local root=$1 remote=$2 branch local_sha n behind
  [ -n "$remote" ] || return 0
  # A cache file is editable state; refuse anything that is not a full sha rather
  # than interpolating it into the report.
  printf '%s\n' "$remote" | grep -Eq '^[0-9a-f]{40}$' || return 0
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  branch=$(fm_default_branch "$root" 2>/dev/null) || return 0
  local_sha=$(git -C "$root" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null) || return 0
  [ -n "$local_sha" ] || return 0
  [ "$remote" != "$local_sha" ] || return 0
  if git -C "$root" cat-file -e "$remote^{commit}" 2>/dev/null; then
    n=$(git -C "$root" rev-list --count "$local_sha..$remote" 2>/dev/null || printf '0\n')
    case "$n" in
      ''|*[!0-9]*) n=0 ;;
    esac
    [ "$n" -gt 0 ] || return 0
    if [ "$n" -eq 1 ]; then
      behind="1 commit behind origin/$branch"
    else
      behind="$n commits behind origin/$branch"
    fi
  else
    behind="behind origin/$branch"
  fi
  printf 'UPDATE_AVAILABLE: firstmate %s -> %s, %s (update: /updatefirstmate)\n' \
    "${local_sha:0:7}" "${remote:0:7}" "$behind"
}

uc_emit() {
  local root=$1 wd=$2
  uc_emit_tool no-mistakes "$(uc_current_version no-mistakes)" "$(uc_read_value "$wd/no-mistakes")" \
    'no-mistakes update - restarts the daemon and aborts any in-flight validation run'
  uc_emit_tool treehouse "$(uc_current_version treehouse)" "$(uc_read_value "$wd/treehouse")" \
    'treehouse update'
  uc_emit_tool tasks-axi "$(uc_current_version tasks-axi)" "$(uc_read_value "$wd/tasks-axi")" \
    'npm install -g tasks-axi@latest'
  uc_emit_firstmate "$root" "$(uc_read_value "$wd/firstmate")"
}

# uc_report <root> <state-dir> <detect-only>: print zero or more UPDATE_AVAILABLE
# lines. Always returns 0 - a failed check is never a failed bootstrap.
uc_report() {
  local root=$1 state=$2 detect_only=${3:-0} wd cache now timeout ttl
  uc_enabled || return 0
  wd=$(mktemp -d "${TMPDIR:-/tmp}/fm-update-check.XXXXXX" 2>/dev/null) || return 0
  cache="$state/.update-check"
  now=$(date +%s 2>/dev/null) || now=0
  timeout=$(uc_timeout)
  ttl=$(uc_ttl)
  if uc_cache_fresh "$cache" "$now" "$ttl"; then
    uc_cache_load "$cache" "$wd"
  else
    uc_refresh "$root" "$wd" "$timeout"
    if [ "$detect_only" != 1 ] && mkdir -p "$state" 2>/dev/null; then
      uc_cache_write "$cache" "$wd" "$now"
    fi
  fi
  uc_emit "$root" "$wd"
  rm -rf "$wd" 2>/dev/null || true
  return 0
}
