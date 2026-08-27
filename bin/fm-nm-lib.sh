# shellcheck shell=bash
# Shared no-mistakes compatibility probes for session-start bootstrap and self-update.
# Usage: . bin/fm-nm-lib.sh
#
# Bootstrap classifies no-mistakes independently as absent, a comparable SemVer
# build, or a commit-hash development build. Comparable SemVer builds must meet
# the configured floor. A hash alone proves no ordering, so a hash build passes
# only when bounded, read-only help probes confirm both interfaces protected by
# the v1.31.2 contract: direct-PR `watch --pr` and AXI `run --intent`.
#
# The help probes neither arm a run nor contact a remote. FM_NM_PROBE_TIMEOUT
# bounds each call in seconds (default 5); malformed values use the default.
# The shared timeout library owns process-group cleanup on timeout.
#
# FM_NM_BIN overrides the binary name (default `no-mistakes`), matching
# bin/fm-nm-watch.sh so both resolve the same tool under test.

FM_NM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$FM_NM_LIB_DIR/fm-timeout-lib.sh"

fm_nm_bin() {
  printf '%s\n' "${FM_NM_BIN:-no-mistakes}"
}

fm_nm_probe_timeout() {
  local configured=${FM_NM_PROBE_TIMEOUT:-5}
  case "$configured" in
    ''|0|*[!0-9]*) printf '5\n' ;;
    *) printf '%s\n' "$configured" ;;
  esac
}

fm_nm_help_probe() {  # <arguments...>
  local bin timeout
  bin=$(fm_nm_bin)
  timeout=$(fm_nm_probe_timeout)
  fm_run_timed "$timeout" "$bin" "$@" </dev/null 2>&1
}

# fm_nm_supports_watch: is the no-mistakes `watch` subcommand available?
#   0 = present and exposes `watch` (compatible)
#   1 = present but too old / lacks `watch` (incompatible)
#   2 = not installed at all (command -v fails)
# The install/absence case (2) is deliberately distinct so callers can leave the
# not-installed report to their existing MISSING path and treat only 1 as the new
# incompatibility diagnostic.
fm_nm_supports_watch() {
  local bin output
  bin=$(fm_nm_bin)
  command -v "$bin" >/dev/null 2>&1 || return 2
  output=$(fm_nm_help_probe watch --help) || return 1
  printf '%s\n' "$output" | grep -Eq '^[[:space:]]*--pr([[:space:]]|$)'
}

# fm_nm_supports_axi_intent: does AXI run expose the required intent contract?
# Return values mirror fm_nm_supports_watch.
fm_nm_supports_axi_intent() {
  local bin output
  bin=$(fm_nm_bin)
  command -v "$bin" >/dev/null 2>&1 || return 2
  output=$(fm_nm_help_probe axi run --help) || return 1
  printf '%s\n' "$output" | grep -Eq '^[[:space:]]*--intent([[:space:]]|$)'
}

_fm_nm_semver_prerelease_ge() {  # <a_prerelease> <b_prerelease>
  local a=$1 b=$2 a_len b_len i a_tok b_tok
  [ -z "$a" ] && [ -z "$b" ] && return 0
  [ -z "$a" ] && return 0
  [ -z "$b" ] && return 1
  a_len=${#a}
  b_len=${#b}
  i=0
  while [ "$i" -le "$a_len" ] && [ "$i" -le "$b_len" ]; do
    a_tok=${a%%.*}
    b_tok=${b%%.*}
    [ "$a_tok" = "$a" ] && a= || a=${a#*.}
    [ "$b_tok" = "$b" ] && b= || b=${b#*.}
    [ -z "$a_tok" ] && [ -z "$b_tok" ] && break
    [ -z "$a_tok" ] && return 1
    [ -z "$b_tok" ] && return 0
    case "$a_tok$b_tok" in
      *[!0-9]*)
        case "$a_tok" in
          *[!0-9]*)
            case "$b_tok" in
              *[!0-9]*) ;;
              *) return 0 ;;
            esac ;;
          *) return 1 ;;
        esac
        [[ "$a_tok" < "$b_tok" ]] && return 1
        [[ "$a_tok" > "$b_tok" ]] && return 0 ;;
      *)
        a_tok=$((10#$a_tok))
        b_tok=$((10#$b_tok))
        [ "$a_tok" -lt "$b_tok" ] && return 1
        [ "$a_tok" -gt "$b_tok" ] && return 0 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

fm_nm_semver_at_least() {  # <version> <minimum>
  local version=$1 minimum=$2 core prerelease min_core min_prerelease
  case "$version" in
    *+*) core=${version%%+*} ;;
    *)   core=$version ;;
  esac
  case "$core" in
    *-*) prerelease=${core#*-}; core=${core%%-*} ;;
    *)   prerelease= ;;
  esac
  case "$minimum" in
    *+*) min_core=${minimum%%+*} ;;
    *)   min_core=$minimum ;;
  esac
  case "$min_core" in
    *-*) min_prerelease=${min_core#*-}; min_core=${min_core%%-*} ;;
    *)   min_prerelease= ;;
  esac
  local major minor patch min_major min_minor min_patch
  IFS='.' read -r major minor patch <<< "$core"
  IFS='.' read -r min_major min_minor min_patch <<< "$min_core"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] || return 1
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] || return 1
  case "$major$minor$patch$min_major$min_minor$min_patch" in
    *[!0-9]*) return 1 ;;
  esac
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -gt "$min_patch" ] && return 0
  [ "$patch" -eq "$min_patch" ] || return 1
  _fm_nm_semver_prerelease_ge "$prerelease" "$min_prerelease"
}

# fm_nm_bootstrap_compatible <minimum>: classify and verify the installed build.
#   0 = compatible SemVer, or recognized hash build with both capabilities
#   1 = installed but incompatible; fm_nm_incompatible_diagnostic explains why
#   2 = command absent; the caller's MISSING path owns that diagnostic
fm_nm_bootstrap_compatible() {
  local minimum=$1 bin output version_token version hash version_failed
  FM_NM_COMPATIBILITY_DETAIL=
  bin=$(fm_nm_bin)
  command -v "$bin" >/dev/null 2>&1 || return 2
  version_failed=0
  if output=$(fm_nm_help_probe --version); then
    version_token=$(printf '%s\n' "$output" | sed -nE 's/^no-mistakes version ([^[:space:]]+).*/\1/p' | head -n 1)
    version=$(printf '%s\n' "$version_token" | sed -nE 's/^[vV]?([0-9]+)\.([0-9]+)\.([0-9]+)([-+].*)?$/\1.\2.\3\4/p')
  else
    version_failed=1
    version_token=
    version=
  fi
  if [ -n "$version" ]; then
    if ! fm_nm_semver_at_least "$version" "$minimum"; then
      FM_NM_COMPATIBILITY_DETAIL="no-mistakes v$version is installed but below required v$minimum; upgrade it before relying on Firstmate's validation contract"
      return 1
    fi
    if ! fm_nm_supports_watch; then
      FM_NM_COMPATIBILITY_DETAIL="no-mistakes v$version is installed but required capability watch --pr is unavailable; upgrade it before using direct-PR delivery"
      return 1
    fi
    if ! fm_nm_supports_axi_intent; then
      FM_NM_COMPATIBILITY_DETAIL="no-mistakes v$version is installed but required capability axi run --intent is unavailable; upgrade it before relying on Firstmate's validation contract"
      return 1
    fi
    return 0
  fi
  if [ "$version_failed" -eq 1 ]; then
    if ! fm_nm_supports_watch; then
      FM_NM_COMPATIBILITY_DETAIL="no-mistakes is installed but its version probe failed or exceeded the $(fm_nm_probe_timeout)s bound and required capability watch --pr is unavailable; upgrade to a responsive build with direct-PR support"
      return 1
    fi
    if ! fm_nm_supports_axi_intent; then
      FM_NM_COMPATIBILITY_DETAIL="no-mistakes is installed but its version probe failed or exceeded the $(fm_nm_probe_timeout)s bound and required capability axi run --intent is unavailable; upgrade to a responsive build with intent support"
      return 1
    fi
    return 0
  fi
  hash=$(printf '%s\n' "$version_token" | sed -nE 's/^([0-9a-fA-F]{7,40})$/\1/p')
  if [ -z "$hash" ]; then
    FM_NM_COMPATIBILITY_DETAIL="no-mistakes is installed but its version cannot be compared with required v$minimum and it is not a recognized commit-hash development build; install or upgrade to a versioned build"
    return 1
  fi
  if ! fm_nm_supports_watch; then
    FM_NM_COMPATIBILITY_DETAIL="no-mistakes development build $hash is installed but required capability watch --pr is unavailable; upgrade it before relying on Firstmate's validation contract"
    return 1
  fi
  if ! fm_nm_supports_axi_intent; then
    FM_NM_COMPATIBILITY_DETAIL="no-mistakes development build $hash is installed but required capability axi run --intent is unavailable; upgrade it before relying on Firstmate's validation contract"
    return 1
  fi
  return 0
}

# fm_nm_incompatible_diagnostic: the single-owner captain-actionable line for an
# installed but incompatible build. Bootstrap classification sets a specific
# reason; direct callers retain the watch-only fallback.
fm_nm_incompatible_diagnostic() {
  echo "NM_INCOMPATIBLE: ${FM_NM_COMPATIBILITY_DETAIL:-no-mistakes is installed but required capability watch --pr is unavailable; direct-PR CI, review, and merge alerts will not arm} (upgrade: no-mistakes update)"
}

# fm_nm_unwatched_diagnostic <task-id> <pr-url> <reason>: the single-owner line
# for "this PR has a merge poll but nothing watching its CI". Two producers say
# it, and they must say it identically:
#   - bin/fm-pr-check.sh, at the moment the arm fails, because that is the one
#     time a person is looking at the PR record and can still fix it;
#   - bin/fm-bootstrap.sh, at every later session start, from the
#     nm_watch_unarmed= the failed arm recorded.
# Both render this text so firstmate reads one contract and the
# bootstrap-diagnostics skill owns one remedy.
fm_nm_unwatched_diagnostic() {  # <task-id> <pr-url> <reason>
  echo "NM_UNWATCHED: $1: $2 has no CI monitoring - $3; read that PR's CI yourself before relaying it, then re-arm with bin/fm-nm-watch.sh $1 $2"
}
