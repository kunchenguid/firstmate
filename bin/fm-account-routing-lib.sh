# shellcheck shell=bash
# Agent Fleet account-routing helpers shared by spawn, recovery, supervision,
# and teardown.
#
# This file owns Firstmate's shell-side Agent Fleet contract.
# It consumes only `agent-fleet --format json contract` version 2 commands and
# never reads Agent Fleet state, profile homes, provider credentials, or quota
# caches directly.
#
# Production routing mode precedence is:
#   1. an explicit per-spawn account pool/profile (enforce for that spawn), or
#      --no-account-routing (off for that spawn);
#   2. config/account-routing-mode;
#   3. off.
# FM_ACCOUNT_ROUTING and executable overrides are accepted only when the
# unmistakable FM_ACCOUNT_ROUTING_TEST_LAB opt-in is active.
# Valid modes are off, observe, and enforce.
# New observe and enforce launches use bin/fm-account-directory.sh and do not
# invoke Agent Fleet.
# Agent Fleet selection and lease helpers remain as legacy recovery support and
# isolated dead-code fixtures pending remove-fleet-routing-deadcode.
#
# FM_AGENT_FLEET_BIN may name a deterministic fake only in tests/labs.
# Production always opens the current passwd user's fixed regular front door at
# ~/.local/bin/agent-fleet; ambient HOME, PATH, and executable overrides cannot
# redirect it.
# Selection and recovery commands use FM_ACCOUNT_SELECTION_TIMEOUT (120s by
# default); an explicitly set legacy FM_ACCOUNT_CONTROL_TIMEOUT still governs
# them when the selection-specific override is unset. Other control calls keep
# the 10s FM_ACCOUNT_CONTROL_TIMEOUT default.

case "${BASH_SOURCE[0]}" in
  */*) FM_ACCOUNT_ROUTING_LIB_SOURCE_DIR=${BASH_SOURCE[0]%/*} ;;
  *) FM_ACCOUNT_ROUTING_LIB_SOURCE_DIR=. ;;
esac
FM_ACCOUNT_ROUTING_LIB_DIR="$(cd "$FM_ACCOUNT_ROUTING_LIB_SOURCE_DIR" && pwd)"
unset FM_ACCOUNT_ROUTING_LIB_SOURCE_DIR
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$FM_ACCOUNT_ROUTING_LIB_DIR/fm-checkout-lock-lib.sh"

# Security-sensitive control-plane helpers never resolve utilities through the
# caller's PATH. Test/lab mode may still supply fake timeout runners, but path,
# ownership, process, hashing, and passwd-home checks use only fixed system
# executables.
FM_ACCOUNT_SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin
FM_ACCOUNT_SYSTEM_PERL_BIN=
[ ! -x /usr/bin/perl ] || FM_ACCOUNT_SYSTEM_PERL_BIN=/usr/bin/perl
FM_ACCOUNT_SYSTEM_UNAME_BIN=
[ ! -x /usr/bin/uname ] || FM_ACCOUNT_SYSTEM_UNAME_BIN=/usr/bin/uname
[ -n "$FM_ACCOUNT_SYSTEM_UNAME_BIN" ] || [ ! -x /bin/uname ] || FM_ACCOUNT_SYSTEM_UNAME_BIN=/bin/uname
FM_ACCOUNT_SYSTEM_STAT_BIN=
[ ! -x /usr/bin/stat ] || FM_ACCOUNT_SYSTEM_STAT_BIN=/usr/bin/stat
[ -n "$FM_ACCOUNT_SYSTEM_STAT_BIN" ] || [ ! -x /bin/stat ] || FM_ACCOUNT_SYSTEM_STAT_BIN=/bin/stat
FM_ACCOUNT_SYSTEM_ID_BIN=
[ ! -x /usr/bin/id ] || FM_ACCOUNT_SYSTEM_ID_BIN=/usr/bin/id
[ -n "$FM_ACCOUNT_SYSTEM_ID_BIN" ] || [ ! -x /bin/id ] || FM_ACCOUNT_SYSTEM_ID_BIN=/bin/id
FM_ACCOUNT_SYSTEM_SED_BIN=
[ ! -x /usr/bin/sed ] || FM_ACCOUNT_SYSTEM_SED_BIN=/usr/bin/sed
[ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || [ ! -x /bin/sed ] || FM_ACCOUNT_SYSTEM_SED_BIN=/bin/sed
FM_ACCOUNT_SYSTEM_AWK_BIN=
[ ! -x /usr/bin/awk ] || FM_ACCOUNT_SYSTEM_AWK_BIN=/usr/bin/awk
[ -n "$FM_ACCOUNT_SYSTEM_AWK_BIN" ] || [ ! -x /bin/awk ] || FM_ACCOUNT_SYSTEM_AWK_BIN=/bin/awk
FM_ACCOUNT_SYSTEM_DATE_BIN=
[ ! -x /bin/date ] || FM_ACCOUNT_SYSTEM_DATE_BIN=/bin/date
[ -n "$FM_ACCOUNT_SYSTEM_DATE_BIN" ] || [ ! -x /usr/bin/date ] || FM_ACCOUNT_SYSTEM_DATE_BIN=/usr/bin/date
FM_ACCOUNT_SYSTEM_GIT_BIN=
[ ! -x /usr/bin/git ] || FM_ACCOUNT_SYSTEM_GIT_BIN=/usr/bin/git
[ -n "$FM_ACCOUNT_SYSTEM_GIT_BIN" ] || [ ! -x /bin/git ] || FM_ACCOUNT_SYSTEM_GIT_BIN=/bin/git
FM_ACCOUNT_SYSTEM_JQ_BIN=
[ ! -x /usr/bin/jq ] || FM_ACCOUNT_SYSTEM_JQ_BIN=/usr/bin/jq
[ -n "$FM_ACCOUNT_SYSTEM_JQ_BIN" ] || [ ! -x /bin/jq ] || FM_ACCOUNT_SYSTEM_JQ_BIN=/bin/jq
FM_ACCOUNT_SYSTEM_CAT_BIN=
[ ! -x /bin/cat ] || FM_ACCOUNT_SYSTEM_CAT_BIN=/bin/cat
[ -n "$FM_ACCOUNT_SYSTEM_CAT_BIN" ] || [ ! -x /usr/bin/cat ] || FM_ACCOUNT_SYSTEM_CAT_BIN=/usr/bin/cat
FM_ACCOUNT_SYSTEM_RM_BIN=
[ ! -x /bin/rm ] || FM_ACCOUNT_SYSTEM_RM_BIN=/bin/rm
[ -n "$FM_ACCOUNT_SYSTEM_RM_BIN" ] || [ ! -x /usr/bin/rm ] || FM_ACCOUNT_SYSTEM_RM_BIN=/usr/bin/rm
FM_ACCOUNT_SYSTEM_MV_BIN=
[ ! -x /bin/mv ] || FM_ACCOUNT_SYSTEM_MV_BIN=/bin/mv
[ -n "$FM_ACCOUNT_SYSTEM_MV_BIN" ] || [ ! -x /usr/bin/mv ] || FM_ACCOUNT_SYSTEM_MV_BIN=/usr/bin/mv
# One publication-failure regression needs to make the final rename fail.
# Accept that fake only behind both exact test opt-ins; production keeps the
# fixed system binary regardless of ambient PATH or override variables.
if [ "${FM_ACCOUNT_ROUTING_TEST_LAB:-}" = firstmate-account-routing-test-lab-v1 ] \
  && [ "${FM_ACCOUNT_TEST_HOOKS:-}" = firstmate-account-tests-v1 ] \
  && [ -n "${FM_TEST_ACCOUNT_MV_BIN:-}" ]; then
  case "$FM_TEST_ACCOUNT_MV_BIN" in
    /*) ;;
    *) FM_ACCOUNT_SYSTEM_MV_BIN= ;;
  esac
  if [ -n "$FM_ACCOUNT_SYSTEM_MV_BIN" ]; then
    [ -f "$FM_TEST_ACCOUNT_MV_BIN" ] && [ ! -L "$FM_TEST_ACCOUNT_MV_BIN" ] \
      && [ -x "$FM_TEST_ACCOUNT_MV_BIN" ] \
      && FM_ACCOUNT_SYSTEM_MV_BIN=$FM_TEST_ACCOUNT_MV_BIN \
      || FM_ACCOUNT_SYSTEM_MV_BIN=
  fi
fi
FM_ACCOUNT_SYSTEM_CP_BIN=
[ ! -x /bin/cp ] || FM_ACCOUNT_SYSTEM_CP_BIN=/bin/cp
[ -n "$FM_ACCOUNT_SYSTEM_CP_BIN" ] || [ ! -x /usr/bin/cp ] || FM_ACCOUNT_SYSTEM_CP_BIN=/usr/bin/cp
FM_ACCOUNT_SYSTEM_MKTEMP_BIN=
[ ! -x /usr/bin/mktemp ] || FM_ACCOUNT_SYSTEM_MKTEMP_BIN=/usr/bin/mktemp
[ -n "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" ] || [ ! -x /bin/mktemp ] || FM_ACCOUNT_SYSTEM_MKTEMP_BIN=/bin/mktemp
FM_ACCOUNT_SYSTEM_SLEEP_BIN=
[ ! -x /bin/sleep ] || FM_ACCOUNT_SYSTEM_SLEEP_BIN=/bin/sleep
[ -n "$FM_ACCOUNT_SYSTEM_SLEEP_BIN" ] || [ ! -x /usr/bin/sleep ] || FM_ACCOUNT_SYSTEM_SLEEP_BIN=/usr/bin/sleep
FM_ACCOUNT_SYSTEM_ENV_BIN=
[ ! -x /usr/bin/env ] || FM_ACCOUNT_SYSTEM_ENV_BIN=/usr/bin/env
[ -n "$FM_ACCOUNT_SYSTEM_ENV_BIN" ] || [ ! -x /bin/env ] || FM_ACCOUNT_SYSTEM_ENV_BIN=/bin/env
FM_ACCOUNT_SYSTEM_BASENAME_BIN=
[ ! -x /usr/bin/basename ] || FM_ACCOUNT_SYSTEM_BASENAME_BIN=/usr/bin/basename
[ -n "$FM_ACCOUNT_SYSTEM_BASENAME_BIN" ] || [ ! -x /bin/basename ] || FM_ACCOUNT_SYSTEM_BASENAME_BIN=/bin/basename
FM_ACCOUNT_SYSTEM_DIRNAME_BIN=
[ ! -x /usr/bin/dirname ] || FM_ACCOUNT_SYSTEM_DIRNAME_BIN=/usr/bin/dirname
[ -n "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" ] || [ ! -x /bin/dirname ] || FM_ACCOUNT_SYSTEM_DIRNAME_BIN=/bin/dirname
FM_ACCOUNT_SYSTEM_LN_BIN=
[ ! -x /bin/ln ] || FM_ACCOUNT_SYSTEM_LN_BIN=/bin/ln
[ -n "$FM_ACCOUNT_SYSTEM_LN_BIN" ] || [ ! -x /usr/bin/ln ] || FM_ACCOUNT_SYSTEM_LN_BIN=/usr/bin/ln
FM_ACCOUNT_SYSTEM_MKDIR_BIN=
[ ! -x /bin/mkdir ] || FM_ACCOUNT_SYSTEM_MKDIR_BIN=/bin/mkdir
[ -n "$FM_ACCOUNT_SYSTEM_MKDIR_BIN" ] || [ ! -x /usr/bin/mkdir ] || FM_ACCOUNT_SYSTEM_MKDIR_BIN=/usr/bin/mkdir
FM_ACCOUNT_SYSTEM_RMDIR_BIN=
[ ! -x /bin/rmdir ] || FM_ACCOUNT_SYSTEM_RMDIR_BIN=/bin/rmdir
[ -n "$FM_ACCOUNT_SYSTEM_RMDIR_BIN" ] || [ ! -x /usr/bin/rmdir ] || FM_ACCOUNT_SYSTEM_RMDIR_BIN=/usr/bin/rmdir

# Invoke the fixed system Perl with every ambient module/loader injection
# surface explicitly scrubbed.  Some helpers exec their bounded child from
# Perl, so keep the caller's otherwise intentional environment intact.
fm_account_system_perl() {
  [ -n "$FM_ACCOUNT_SYSTEM_PERL_BIN" ] || return 127
  PERL5OPT='' PERL5LIB='' PERLLIB='' \
    DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' LD_PRELOAD='' \
    LD_LIBRARY_PATH='' LD_AUDIT='' LD_DEBUG='' GCONV_PATH='' \
    NODE_OPTIONS='' NODE_PATH='' PYTHONHOME='' PYTHONPATH='' \
    RUBYOPT='' RUBYLIB='' BASH_ENV='' ENV='' \
    "$FM_ACCOUNT_SYSTEM_PERL_BIN" "$@"
}

# Fixed paths stop PATH shadowing but not loader/language startup injection.
# Use this envelope for every authority-bearing system child.  Environment
# values needed as ordinary arguments are passed explicitly by callers; only
# executable startup hooks are removed here.
fm_account_system_exec() {
  local -x LD_PRELOAD='' LD_LIBRARY_PATH='' LD_AUDIT='' LD_DEBUG=''
  local -x DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' DYLD_FRAMEWORK_PATH=''
  local -x DYLD_FALLBACK_LIBRARY_PATH='' DYLD_FALLBACK_FRAMEWORK_PATH=''
  local -x PERL5OPT='' PERL5LIB='' PERLLIB='' NODE_OPTIONS='' NODE_PATH=''
  local -x PYTHONHOME='' PYTHONPATH='' RUBYOPT='' RUBYLIB='' BASH_ENV='' ENV=''
  local -x GCONV_PATH=''
  "$@"
}

fm_account_shell_quote() {
  printf "'"
  [ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || return 1
  printf '%s' "$1" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" "s/'/'\\\\''/g"
  printf "'"
}

fm_account_test_lab_enabled() {
  [ "${FM_ACCOUNT_ROUTING_TEST_LAB:-}" = firstmate-account-routing-test-lab-v1 ]
}

FM_ACCOUNT_PASSWD_HOME=
FM_ACCOUNT_PASSWD_NAME=
FM_ACCOUNT_CANONICAL_CONFIG=
fm_account_resolve_passwd_identity() {
  local identity name home
  [ -z "$FM_ACCOUNT_PASSWD_HOME" ] || return 0
  [ -n "$FM_ACCOUNT_SYSTEM_PERL_BIN" ] || {
    echo "error: perl is required to resolve the current passwd identity" >&2
    return 1
  }
  # Dollar expressions in the single-quoted program belong to Perl.
  # shellcheck disable=SC2016
  identity=$(fm_account_system_perl -e '
    my @p = getpwuid($<);
    exit 1 unless @p && defined $p[0] && defined $p[7];
    exit 1 unless length($p[0]) && $p[0] !~ /[\x00-\x1f\x7f=]/;
    exit 1 unless $p[7] =~ m{^/} && $p[7] !~ /[\x00\r\n]/;
    print "$p[0]\n$p[7]";
  ' 2>/dev/null) || {
    echo "error: cannot resolve the current passwd identity for Agent Fleet" >&2
    return 1
  }
  case "$identity" in *$'\n'*) ;; *) return 1 ;; esac
  name=${identity%%$'\n'*}
  home=${identity#*$'\n'}
  case "$name" in ''|*$'\n'*|*=*) return 1 ;; esac
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$home" in *$'\n'*) return 1 ;; esac
  FM_ACCOUNT_PASSWD_NAME=$name
  FM_ACCOUNT_PASSWD_HOME=$home
  FM_ACCOUNT_CANONICAL_CONFIG=$home/.config/agent-fleet/accounts.toml
}

fm_account_run_bounded() {
  local seconds=$1 status foreground_flag=()
  shift
  case "$seconds" in ''|*[!0-9]*|0) return 2 ;; esac
  [ "${FM_ACCOUNT_BOUND_INHERIT_GROUP:-0}" != 1 ] || foreground_flag=(--foreground)
  if fm_account_test_lab_enabled && command -v timeout >/dev/null 2>&1; then
    timeout "${foreground_flag[@]}" --kill-after=1 "$seconds" "$@" || {
      status=$?
      [ "$status" -ne 137 ] || status=124
      return "$status"
    }
    return 0
  elif fm_account_test_lab_enabled && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${foreground_flag[@]}" --kill-after=1 "$seconds" "$@" || {
      status=$?
      [ "$status" -ne 137 ] || status=124
      return "$status"
    }
    return 0
  elif [ -n "$FM_ACCOUNT_SYSTEM_PERL_BIN" ]; then
    # shellcheck disable=SC2016
    fm_account_system_perl -e 'my $t = shift; my $inherit = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $inherit; exec @ARGV } my $target = $inherit ? $pid : -$pid; local $SIG{ALRM} = sub { kill "TERM", $target; select undef, undef, undef, 0.2; kill "KILL", $target; exit 124 }; alarm $t; waitpid $pid, 0; my $status = $?; exit(($status & 127) ? 128 + ($status & 127) : $status >> 8)' "$seconds" "${FM_ACCOUNT_BOUND_INHERIT_GROUP:-0}" "$@" || {
      status=$?
      return "$status"
    }
    return 0
  else
    return 127
  fi
}

fm_account_valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*|-*) return 1 ;;
  esac
  return 0
}

fm_account_real_directory() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

fm_account_task_tmp_path() {  # <task-id> <generation-id>
  local task=$1 generation=$2 token state
  fm_account_valid_id "$task" || return 1
  case "$generation" in
    spawn:*|account:*)
      token=${generation##*:}
      ;;
    *)
      return 1
      ;;
  esac
  fm_account_valid_id "$token" || return 1
  if [ -n "${STATE:-}" ]; then
    state=$STATE
  elif [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    state=$FM_STATE_OVERRIDE
  elif [ -n "${FM_HOME:-}" ]; then
    state=$FM_HOME/state
  else
    return 1
  fi
  fm_account_real_directory "$state" || return 1
  state=$(cd "$state" 2>/dev/null && pwd -P) || return 1
  [ "$state" != / ] || return 1
  printf '%s/.task-tmp/fm-%s-%s\n' "${state%/}" "$task" "$token"
}

fm_account_previous_task_tmp_path() {  # <task-id>
  local task=$1 state
  fm_account_valid_id "$task" || return 1
  if [ -n "${STATE:-}" ]; then
    state=$STATE
  elif [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    state=$FM_STATE_OVERRIDE
  elif [ -n "${FM_HOME:-}" ]; then
    state=$FM_HOME/state
  else
    return 1
  fi
  fm_account_real_directory "$state" || return 1
  state=$(cd "$state" 2>/dev/null && pwd -P) || return 1
  [ "$state" != / ] || return 1
  printf '%s/.task-tmp/fm-%s\n' "${state%/}" "$task"
}

fm_account_legacy_task_tmp_path() {  # <task-id>
  fm_account_valid_id "$1" || return 1
  printf '/tmp/fm-%s\n' "$1"
}

fm_account_task_tmp_is_current() {  # <task-id> <path> <generation-id>
  local expected
  expected=$(fm_account_task_tmp_path "$1" "$3") || return 1
  [ "$2" = "$expected" ]
}

fm_account_task_tmp_is_previous() {  # <task-id> <path>
  local previous
  previous=$(fm_account_previous_task_tmp_path "$1") || return 1
  [ "$2" = "$previous" ]
}

fm_account_task_tmp_is_legacy() {  # <task-id> <path>
  local legacy
  legacy=$(fm_account_legacy_task_tmp_path "$1") || return 1
  [ "$2" = "$legacy" ]
}

fm_account_task_tmp_is_expected() {  # <task-id> <path> <generation-id>
  # Legacy metadata remains recognizable, but callers must use
  # fm_account_task_tmp_is_current before any filesystem mutation.
  fm_account_task_tmp_is_current "$1" "$2" "$3" \
    || fm_account_task_tmp_is_previous "$1" "$2" \
    || fm_account_task_tmp_is_legacy "$1" "$2"
}

fm_account_safe_remove_task_tmp() {  # <task-id> <path> <generation-id> [subdirectory]
  local task=$1 target=$2 generation=$3 child=${4:-} legacy
  [ -n "$target" ] || return 0
  fm_account_task_tmp_is_expected "$task" "$target" "$generation" || return 1
  legacy=$(fm_account_legacy_task_tmp_path "$task") || return 1
  [ "$target" != "$legacy" ] || return 0
  fm_account_task_tmp_is_current "$task" "$target" "$generation" \
    || fm_account_task_tmp_is_previous "$task" "$target" \
    || return 1
  case "$child" in
    '') ;;
    gotmp) target="$target/$child" ;;
    *) return 1 ;;
  esac
  python3 "$FM_ACCOUNT_ROUTING_LIB_DIR/fm-safe-task-tmp.py" "$target" || return 1
}

fm_account_safe_file_destination() {
  [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; }
}

fm_account_path_uid() {
  [ -n "$FM_ACCOUNT_SYSTEM_UNAME_BIN" ] && [ -n "$FM_ACCOUNT_SYSTEM_STAT_BIN" ] || return 1
  if [ "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_UNAME_BIN")" = Darwin ]; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -f %u "$1" 2>/dev/null
  else
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -c %u "$1" 2>/dev/null
  fi
}

fm_account_path_mode() {
  [ -n "$FM_ACCOUNT_SYSTEM_UNAME_BIN" ] && [ -n "$FM_ACCOUNT_SYSTEM_STAT_BIN" ] || return 1
  if [ "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_UNAME_BIN")" = Darwin ]; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -f %Mp%Lp "$1" 2>/dev/null
  else
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -c %a "$1" 2>/dev/null
  fi
}

fm_account_path_nlink() {
  [ -n "$FM_ACCOUNT_SYSTEM_UNAME_BIN" ] && [ -n "$FM_ACCOUNT_SYSTEM_STAT_BIN" ] || return 1
  if [ "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_UNAME_BIN")" = Darwin ]; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -f %l "$1" 2>/dev/null
  else
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -c %h "$1" 2>/dev/null
  fi
}

fm_account_validate_physical_fleet_bin() {  # <physical-path>
  local binary=$1 current leaf=1 uid mode nlink numeric owner_uid
  [ -n "$binary" ] && [ "${binary#/}" != "$binary" ] || {
    echo "error: Agent Fleet entrypoint did not resolve to an absolute path" >&2
    return 1
  }
  [ -n "$FM_ACCOUNT_SYSTEM_ID_BIN" ] || return 1
  owner_uid=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_ID_BIN" -u) || return 1
  current=$binary
  while :; do
    [ ! -L "$current" ] || {
      echo "error: physical Agent Fleet path contains a symlink: $current" >&2
      return 1
    }
    uid=$(fm_account_path_uid "$current") || {
      echo "error: cannot inspect Agent Fleet path: $current" >&2
      return 1
    }
    mode=$(fm_account_path_mode "$current") || {
      echo "error: cannot inspect Agent Fleet path permissions: $current" >&2
      return 1
    }
    case "$uid" in ''|*[!0-9]*) return 1 ;; esac
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    numeric=$((8#$mode))
    [ "$uid" -eq 0 ] || [ "$uid" -eq "$owner_uid" ] || {
      echo "error: Agent Fleet path is not owned by the current user or root: $current" >&2
      return 1
    }
    if [ "$leaf" -eq 1 ]; then
      [ -f "$current" ] && [ -x "$current" ] || {
        echo "error: Agent Fleet entrypoint is not a regular executable: $current" >&2
        return 1
      }
      [ $((numeric & 8#22)) -eq 0 ] || {
        echo "error: Agent Fleet entrypoint is group/world writable: $current" >&2
        return 1
      }
      nlink=$(fm_account_path_nlink "$current") || return 1
      [ "$nlink" = 1 ] || {
        echo "error: Agent Fleet entrypoint must have exactly one hard link: $current" >&2
        return 1
      }
      leaf=0
    else
      [ -d "$current" ] || {
        echo "error: Agent Fleet path ancestor is not a directory: $current" >&2
        return 1
      }
      if [ $((numeric & 8#22)) -ne 0 ]; then
        [ "$uid" -eq 0 ] && [ $((numeric & 8#1000)) -ne 0 ] || {
          echo "error: Agent Fleet path ancestor is writable without root sticky protection: $current" >&2
          return 1
        }
      fi
    fi
    [ "$current" != / ] || break
    current=${current%/*}
    [ -n "$current" ] || current=/
  done
}

fm_account_fleet_bin() {  # [test/lab override]
  local explicit_override=${1:-} discovered physical passwd_home
  if fm_account_test_lab_enabled; then
    if [ -n "$explicit_override" ]; then
      discovered=$explicit_override
    elif [ -n "${FM_AGENT_FLEET_BIN:-}" ]; then
      discovered=$FM_AGENT_FLEET_BIN
    else
      discovered=$(command -v agent-fleet 2>/dev/null) || {
        echo "error: agent-fleet is required for account routing" >&2
        return 1
      }
    fi
  else
    [ -z "$explicit_override" ] && [ -z "${FM_AGENT_FLEET_BIN:-}" ] || {
      echo "error: Agent Fleet executable overrides require the explicit test/lab opt-in" >&2
      return 1
    }
    fm_account_resolve_passwd_identity || return 1
    passwd_home=$FM_ACCOUNT_PASSWD_HOME
    discovered=$passwd_home/.local/bin/agent-fleet
    fm_account_validate_physical_fleet_bin "$discovered" || return 1
    printf '%s\n' "$discovered"
    return 0
  fi
  [ -n "$FM_ACCOUNT_SYSTEM_PERL_BIN" ] || {
    echo "error: perl is required to resolve the physical Agent Fleet entrypoint" >&2
    return 1
  }
  # shellcheck disable=SC2016
  physical=$(fm_account_system_perl -MCwd=abs_path -e 'my $p = abs_path($ARGV[0]); exit 1 unless defined $p; print "$p\n"' "$discovered") || {
    echo "error: cannot resolve the physical Agent Fleet entrypoint: $discovered" >&2
    return 1
  }
  fm_account_validate_physical_fleet_bin "$physical" || return 1
  printf '%s\n' "$physical"
}

FM_ACCOUNT_FLEET_PINNED_BIN=
fm_account_pin_fleet_bin() {
  local binary
  [ -z "$FM_ACCOUNT_FLEET_PINNED_BIN" ] || return 0
  binary=$(fm_account_fleet_bin) || return 1
  case "$binary" in ''|*$'\n'*) echo "error: invalid Agent Fleet entrypoint path" >&2; return 1 ;; esac
  FM_ACCOUNT_FLEET_PINNED_BIN=$binary
}

fm_account_control_timeout() {
  local seconds=${FM_ACCOUNT_CONTROL_TIMEOUT:-10}
  case "$seconds" in
    ''|*[!0-9]*|0)
      echo "error: FM_ACCOUNT_CONTROL_TIMEOUT must be a positive integer" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$seconds"
}

fm_account_run_control() {
  local seconds
  seconds=$(fm_account_control_timeout) || return 1
  fm_account_run_fleet_bounded "$seconds" "$@"
}

fm_account_selection_timeout() {
  local seconds source
  if [ -n "${FM_ACCOUNT_SELECTION_TIMEOUT:-}" ]; then
    seconds=$FM_ACCOUNT_SELECTION_TIMEOUT
    source=FM_ACCOUNT_SELECTION_TIMEOUT
  elif [ -n "${FM_ACCOUNT_CONTROL_TIMEOUT:-}" ]; then
    seconds=$FM_ACCOUNT_CONTROL_TIMEOUT
    source=FM_ACCOUNT_CONTROL_TIMEOUT
  else
    seconds=120
    source=FM_ACCOUNT_SELECTION_TIMEOUT
  fi
  case "$seconds" in
    ''|*[!0-9]*|0)
      echo "error: $source must be a positive integer" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$seconds"
}

fm_account_run_selection() {
  local seconds
  seconds=$(fm_account_selection_timeout) || return 1
  fm_account_run_fleet_bounded "$seconds" "$@"
}

# Run one Agent Fleet control operation. Production gets an exact closed
# environment plus an explicit canonical registry path, so ambient and future
# AGENT_FLEET_*/QUOTA_AXI_* variables cannot redirect config, state, share, or
# runtime authority. The deterministic test harness keeps its fake variables
# only behind the exact lab opt-in.
fm_account_run_fleet_bounded() {  # <seconds> <binary> <args...>
  local seconds=$1 binary=$2
  shift 2
  if fm_account_test_lab_enabled; then
    fm_account_run_bounded "$seconds" "$binary" "$@" || return $?
    return 0
  fi
  fm_account_resolve_passwd_identity || return 1
  [ -n "$FM_ACCOUNT_SYSTEM_ENV_BIN" ] || return 127
  fm_account_run_bounded "$seconds" "$FM_ACCOUNT_SYSTEM_ENV_BIN" -i \
    "HOME=$FM_ACCOUNT_PASSWD_HOME" \
    "USER=$FM_ACCOUNT_PASSWD_NAME" \
    "LOGNAME=$FM_ACCOUNT_PASSWD_NAME" \
    "PATH=$FM_ACCOUNT_SYSTEM_PATH" \
    LC_ALL=C LANG=C \
    "$binary" --config "$FM_ACCOUNT_CANONICAL_CONFIG" "$@" || return $?
  return 0
}

# The fixed Perl launcher starts before any new shell can interpret inherited
# BASH_ENV, SHELLOPTS/PS4, or exported functions. It preserves intentional
# worker variables, but dynamically removes every Fleet/Quota/XDG authority
# override plus loader and language-runtime injection before exec.
# shellcheck disable=SC2016  # Dollar expressions belong to the fixed Perl program.
FM_ACCOUNT_WORKER_PERL_PROGRAM='my ($home, $name, $config, $binary) = splice @ARGV, 0, 4;
die "invalid launcher arguments" unless defined($binary) && length($binary);
my %blocked = map { $_ => 1 } qw(
  BASH_ENV ENV SHELLOPTS BASHOPTS PS4 BASH_XTRACEFD BASH_COMPAT
  BASH_LOADABLES_PATH CDPATH GLOBIGNORE IFS KSHENV ZDOTDIR GCONV_PATH
);
for my $variable (keys %ENV) {
  delete $ENV{$variable} if $blocked{$variable}
    || $variable =~ /^(?:AGENT_FLEET_|QUOTA_AXI_|XDG_|BASH_FUNC_)/
    || $variable =~ /^(?:LD_|DYLD_|PERL|PYTHON|RUBY|NODE_)/;
}
$ENV{HOME} = $home;
$ENV{USER} = $name;
$ENV{LOGNAME} = $name;
exec {$binary} $binary, "--config", $config, @ARGV;
die "cannot exec pinned Agent Fleet entrypoint: $!";'

# Build the prefix used by long-lived managed exec/resume workers. Unlike
# closed control operations, workers retain non-routing ambient values (for
# example project credentials and terminal settings). The pre-shell launcher
# above removes authority and startup injection, pins passwd identity, and
# passes the canonical registry explicitly. Test fakes retain their legacy
# command shape only inside the exact lab.
fm_account_fleet_worker_prefix() {  # <binary>
  local binary=$1
  if fm_account_test_lab_enabled; then
    fm_account_shell_quote "$binary"
    return
  fi
  fm_account_resolve_passwd_identity || return 1
  [ -n "$FM_ACCOUNT_SYSTEM_PERL_BIN" ] || return 127
  printf '%s' "LD_PRELOAD='' LD_LIBRARY_PATH='' LD_AUDIT='' LD_DEBUG='' DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' DYLD_FRAMEWORK_PATH='' DYLD_FALLBACK_LIBRARY_PATH='' DYLD_FALLBACK_FRAMEWORK_PATH='' PERL5OPT='' PERL5LIB='' PERLLIB='' NODE_OPTIONS='' NODE_PATH='' PYTHONHOME='' PYTHONPATH='' RUBYOPT='' RUBYLIB='' BASH_ENV='' ENV='' GCONV_PATH='' "
  printf '%s -e %s %s %s %s %s' \
    "$(fm_account_shell_quote "$FM_ACCOUNT_SYSTEM_PERL_BIN")" \
    "$(fm_account_shell_quote "$FM_ACCOUNT_WORKER_PERL_PROGRAM")" \
    "$(fm_account_shell_quote "$FM_ACCOUNT_PASSWD_HOME")" \
    "$(fm_account_shell_quote "$FM_ACCOUNT_PASSWD_NAME")" \
    "$(fm_account_shell_quote "$FM_ACCOUNT_CANONICAL_CONFIG")" \
    "$(fm_account_shell_quote "$binary")"
}

FM_ACCOUNT_CONTRACT_BIN=
fm_account_validate_contract() {  # <agent-fleet-bin>
  local binary=$1 json version
  [ "$FM_ACCOUNT_CONTRACT_BIN" != "$binary" ] || return 0
  [ -n "$FM_ACCOUNT_SYSTEM_JQ_BIN" ] || {
    echo "error: fixed system jq is required for account routing" >&2
    return 1
  }
  json=$(fm_account_run_control "$binary" --format json contract 2>/dev/null) || {
    echo "error: cannot verify the Agent Fleet contract" >&2
    return 1
  }
  version=$(printf '%s\n' "$json" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_JQ_BIN" -er '.contract_version | select(type == "number")' 2>/dev/null) || {
    echo "error: agent-fleet returned an invalid contract" >&2
    return 1
  }
  [ "$version" = 2 ] || {
    echo "error: unsupported Agent Fleet contract version $version (expected 2)" >&2
    return 1
  }
  FM_ACCOUNT_CONTRACT_BIN=$binary
}

fm_account_read_single_value() {  # <file>
  local file=$1 values count value
  [ -n "$FM_ACCOUNT_SYSTEM_AWK_BIN" ] || return 2
  [ -e "$file" ] || return 1
  [ -f "$file" ] && [ -r "$file" ] || {
    echo "error: cannot read $file" >&2
    return 2
  }
  # shellcheck disable=SC2016
  values=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_AWK_BIN" '
    {
      sub(/[[:space:]]*#.*/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if (length($0) > 0) print
    }
  ' "$file") || {
    echo "error: cannot read $file" >&2
    return 2
  }
  count=$(printf '%s\n' "$values" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_AWK_BIN" 'NF { count++ } END { print count + 0 }')
  [ "$count" -le 1 ] || {
    echo "error: $file must contain exactly one value" >&2
    return 2
  }
  [ "$count" -eq 1 ] || return 1
  value=$(printf '%s\n' "$values" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_AWK_BIN" 'NF { print; exit }')
  printf '%s\n' "$value"
}

fm_account_resolve_mode() {  # <config-dir> <explicit-route:0|1> <disabled:0|1>
  local config=$1 explicit=$2 disabled=$3 value source status
  if [ "$disabled" = 1 ]; then
    printf 'off\n'
    return 0
  fi
  if [ "$explicit" = 1 ]; then
    printf 'enforce\n'
    return 0
  fi
  if fm_account_test_lab_enabled && [ -n "${FM_ACCOUNT_ROUTING:-}" ]; then
    value=$FM_ACCOUNT_ROUTING
    source=FM_ACCOUNT_ROUTING
  else
    if value=$(fm_account_read_single_value "$config/account-routing-mode"); then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0) source=config/account-routing-mode ;;
      1) value=off; source=default ;;
      *) return "$status" ;;
    esac
  fi
  case "$value" in
    off|observe|enforce) printf '%s\n' "$value" ;;
    *) echo "error: invalid account routing mode '$value' from $source (expected off, observe, or enforce)" >&2; return 1 ;;
  esac
}

fm_account_attempt_id() {  # <home> <task>
  local home=$1 task=$2 seed
  fm_account_valid_id "$task" || {
    echo "error: invalid task id '$task' for account routing" >&2
    return 1
  }
  [ -n "$FM_ACCOUNT_SYSTEM_DATE_BIN" ] && [ -n "$FM_ACCOUNT_SYSTEM_GIT_BIN" ] || return 1
  seed=$(printf '%s\n%s\n%s\n%s\n%s\n' "$home" "$task" "$$" "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s)" "${RANDOM:-0}" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_GIT_BIN" hash-object --stdin 2>/dev/null) || {
    echo "error: cannot generate Agent Fleet attempt identity" >&2
    return 1
  }
  printf 'a%.15s\n' "$seed"
}

fm_account_task_key() {  # <home> <task> <attempt>
  local home=$1 task=$2 attempt=$3 abs_home home_hash
  fm_account_valid_id "$task" || { echo "error: invalid task id '$task' for account routing" >&2; return 1; }
  fm_account_valid_id "$attempt" || { echo "error: invalid account attempt '$attempt'" >&2; return 1; }
  abs_home=$(cd "$home" 2>/dev/null && pwd -P) || {
    echo "error: cannot resolve firstmate home for account routing: $home" >&2
    return 1
  }
  [ -n "$FM_ACCOUNT_SYSTEM_GIT_BIN" ] || return 1
  home_hash=$(printf '%s\n' "$abs_home" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_GIT_BIN" hash-object --stdin 2>/dev/null) || {
    echo "error: cannot namespace Agent Fleet task for $abs_home" >&2
    return 1
  }
  printf 'fm-%.16s-%s-%s\n' "$home_hash" "$task" "$attempt"
}

fm_tasktmp_path() {  # <task> <generation>
  local task=$1 generation=$2 token
  fm_account_valid_id "$task" || return 1
  token=${generation##*:}
  fm_account_valid_id "$token" || return 1
  printf '/tmp/fm-%s-%s\n' "$task" "$token"
}

fm_tasktmp_owner_record() {  # <state> <task> <generation>
  local state=$1 task=$2 generation=$3 token
  fm_account_valid_id "$task" || return 1
  token=${generation##*:}
  fm_account_valid_id "$token" || return 1
  printf '%s/%s.tasktmp-owner.%s\n' "$state" "$task" "$token"
}

fm_tasktmp_owner_write() {  # <state> <home> <task> <generation> <root>
  local state=$1 home=$2 task=$3 generation=$4 root=$5 home_real expected record tmp
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  expected=$(fm_tasktmp_path "$task" "$generation") || return 1
  [ "$root" = "$expected" ] || return 1
  record=$(fm_tasktmp_owner_record "$state" "$task" "$generation") || return 1
  [ ! -e "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$state/.$task.tasktmp-owner.XXXXXX") || return 1
  {
    printf 'home=%s\n' "$home_real"
    printf 'task=%s\n' "$task"
    printf 'generation=%s\n' "$generation"
    printf 'root=%s\n' "$root"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! ln "$tmp" "$record" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

fm_tasktmp_owner_validate() {  # <record> <home> <task> <generation> <root>
  local record=$1 home=$2 task=$3 generation=$4 root=$5 home_real expected
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  [ "$(wc -l < "$record" | tr -d ' ')" = 4 ] || return 1
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  expected=$(fm_tasktmp_path "$task" "$generation") || return 1
  [ "$root" = "$expected" ] || return 1
  [ "$(sed -n '1s/^home=//p' "$record")" = "$home_real" ] || return 1
  [ "$(sed -n '2s/^task=//p' "$record")" = "$task" ] || return 1
  [ "$(sed -n '3s/^generation=//p' "$record")" = "$generation" ] || return 1
  [ "$(sed -n '4s/^root=//p' "$record")" = "$root" ] || return 1
}

fm_tasktmp_create() {  # <state> <home> <task> <generation> <root>
  local state=$1 home=$2 task=$3 generation=$4 root=$5 proof="$5/.fm-tasktmp-owner" record
  record=$(fm_tasktmp_owner_record "$state" "$task" "$generation") || return 1
  fm_tasktmp_owner_write "$state" "$home" "$task" "$generation" "$root" || return 1
  if ! mkdir "$root"; then
    rm -f "$record"
    return 1
  fi
  if ! cp "$record" "$proof" || ! chmod 600 "$proof" || ! mkdir "$root/gotmp"; then
    rm -rf "$root"
    rm -f "$record"
    return 1
  fi
}

fm_tasktmp_remove_owned() {  # <state> <home> <task> <generation> <root>
  local state=$1 home=$2 task=$3 generation=$4 root=$5 record
  record=$(fm_tasktmp_owner_record "$state" "$task" "$generation") || return 1
  fm_tasktmp_owner_validate "$record" "$home" "$task" "$generation" "$root" || return 1
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    fm_tasktmp_owner_validate "$root/.fm-tasktmp-owner" "$home" "$task" "$generation" "$root" || return 1
    rm -rf "$root" || return 1
  fi
  rm -f "$record"
}

fm_account_ps_bin() {
  if fm_account_test_lab_enabled \
    && [ "${FM_ACCOUNT_TEST_HOOKS:-}" = firstmate-account-tests-v1 ] \
    && [ -n "${FM_TEST_ACCOUNT_PS_BIN:-}" ]; then
    [ -x "$FM_TEST_ACCOUNT_PS_BIN" ] || return 1
    printf '%s\n' "$FM_TEST_ACCOUNT_PS_BIN"
  elif [ -x /bin/ps ]; then
    printf '%s\n' /bin/ps
  elif [ -x /usr/bin/ps ]; then
    printf '%s\n' /usr/bin/ps
  else
    return 1
  fi
}

fm_account_process_start_time() {  # <pid>
  local out ps_bin
  ps_bin=$(fm_account_ps_bin) || return 1
  out=$(LC_ALL=C fm_account_system_exec "$ps_bin" -o lstart= -p "$1" 2>/dev/null) || return 1
  [ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || return 1
  out=$(printf '%s\n' "$out" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

FM_ACCOUNT_LOCK_OWNER_PID=
FM_ACCOUNT_LOCK_OWNER_START=
# Return 0 only for the same live owner, 1 only when process identity is
# proven dead/reused, 2 for an indeterminate process probe, and 3 for an
# invalid owner record. Reclaimers must never treat rc=2 as dead.
fm_account_lock_owner_state() {  # <lock-path>
  local lock=$1 owner identity pid recorded current probe probe_status ps_bin
  FM_ACCOUNT_LOCK_OWNER_PID=
  FM_ACCOUNT_LOCK_OWNER_START=
  if [ -f "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock
  elif [ -d "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock/owner
  else
    return 3
  fi
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 3
  [ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || return 3
  identity=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" -n '1p;2p' "$owner" 2>/dev/null) || return 3
  case "$identity" in *$'\n'*) ;; *) return 3 ;; esac
  pid=${identity%%$'\n'*}
  recorded=${identity#*$'\n'}
  case "$pid" in ''|*[!0-9]*) return 3 ;; esac
  [ -n "$recorded" ] || return 3
  FM_ACCOUNT_LOCK_OWNER_PID=$pid
  FM_ACCOUNT_LOCK_OWNER_START=$recorded
  ps_bin=$(fm_account_ps_bin) || return 2
  if probe=$(LC_ALL=C fm_account_system_exec "$ps_bin" -o lstart= -p "$pid" 2>&1); then
    probe_status=0
  else
    probe_status=$?
  fi
  current=$(printf '%s\n' "$probe" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$probe_status" -eq 0 ]; then
    [ -n "$current" ] || return 2
    [ "$current" = "$recorded" ] && return 0
    return 1
  fi
  kill -0 "$pid" 2>/dev/null && return 2
  case "$current" in
    *"process id too large"*|*"No such process"*|*"no such process"*) return 1 ;;
  esac
  [ -z "$current" ] && return 1
  return 2
}

fm_account_lock_owner_identity() {  # <lock-path>
  fm_account_lock_owner_state "$1" || return 1
  printf '%s\n%s\n' "$FM_ACCOUNT_LOCK_OWNER_PID" "$FM_ACCOUNT_LOCK_OWNER_START"
}

fm_account_meta_lock_owner_alive() {  # <lock-path>
  local state
  if fm_account_lock_owner_state "$1"; then state=0; else state=$?; fi
  [ "$state" -eq 0 ] || [ "$state" -eq 2 ]
}

fm_account_path_mtime() {
  [ -n "$FM_ACCOUNT_SYSTEM_UNAME_BIN" ] && [ -n "$FM_ACCOUNT_SYSTEM_STAT_BIN" ] || return 1
  if [ "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_UNAME_BIN")" = Darwin ]; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -f %m "$1" 2>/dev/null
  else
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -c %Y "$1" 2>/dev/null
  fi
}

fm_account_path_inode() {
  [ -n "$FM_ACCOUNT_SYSTEM_UNAME_BIN" ] && [ -n "$FM_ACCOUNT_SYSTEM_STAT_BIN" ] || return 1
  if [ "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_UNAME_BIN")" = Darwin ]; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -f %i "$1" 2>/dev/null
  else
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_STAT_BIN" -c %i "$1" 2>/dev/null
  fi
}

fm_account_reclaim_owner_alive() {  # <reclaim-directory>
  fm_account_meta_lock_owner_alive "$1"
}

fm_account_reclaim_guard_owned() {  # <reclaim-directory>
  local reclaim=$1 owner pid recorded current
  if [ -f "$reclaim" ] && [ ! -L "$reclaim" ]; then
    owner=$reclaim
  elif [ -d "$reclaim" ] && [ ! -L "$reclaim" ]; then
    owner=$reclaim/owner
  else
    return 1
  fi
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  [ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || return 1
  pid=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" -n '1p' "$owner" 2>/dev/null)
  recorded=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" -n '2p' "$owner" 2>/dev/null)
  [ "$pid" = "$$" ] || return 1
  current=$(fm_account_process_start_time "$$") || return 1
  [ -n "$recorded" ] && [ "$current" = "$recorded" ]
}

fm_account_reclaim_guard_release() {  # <reclaim-directory>
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  fm_account_reclaim_guard_owned "$1" || return 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$1"
}

fm_account_reclaim_guard_acquire() {  # <reclaim-directory> <grace-seconds>
  local reclaim=$1 grace=$2 start age candidate candidate_inode reclaim_inode nested nested_inode
  local quarantine observed_inode quarantined_inode
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  start=$(fm_account_process_start_time "$$") || return 1
  candidate=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$reclaim.candidate.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n%s\n' "$$" "$start" > "$candidate"; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$candidate"
    return 1
  fi
  candidate_inode=$(fm_account_path_inode "$candidate") || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$candidate"; return 1; }
  if { [ ! -e "$reclaim" ] && [ ! -L "$reclaim" ]; } \
    && fm_account_system_exec "$FM_ACCOUNT_SYSTEM_LN_BIN" -n "$candidate" "$reclaim" 2>/dev/null; then
    reclaim_inode=$(fm_account_path_inode "$reclaim" 2>/dev/null || true)
    if [ -f "$reclaim" ] && [ ! -L "$reclaim" ] && [ "$candidate_inode" = "$reclaim_inode" ]; then
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$candidate"
      return 0
    fi
    nested="$reclaim/${candidate##*/}"
    nested_inode=$(fm_account_path_inode "$nested" 2>/dev/null || true)
    if [ -d "$reclaim" ] && [ ! -L "$reclaim" ] && [ -f "$nested" ] && [ "$candidate_inode" = "$nested_inode" ]; then
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$nested" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$candidate"; return 1; }
    else
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$candidate"
      return 1
    fi
  fi
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$candidate"
  fm_account_reclaim_owner_alive "$reclaim" && return 1
  { [ -f "$reclaim" ] || [ -d "$reclaim" ]; } && [ ! -L "$reclaim" ] || return 1
  age=$(fm_account_path_mtime "$reclaim") || return 1
  [ -n "$FM_ACCOUNT_SYSTEM_DATE_BIN" ] || return 1
  [ $(( $(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s) - age )) -ge "$grace" ] || return 1
  observed_inode=$(fm_account_path_inode "$reclaim") || return 1
  fm_account_reclaim_owner_alive "$reclaim" && return 1
  [ "$(fm_account_path_inode "$reclaim" 2>/dev/null || true)" = "$observed_inode" ] || return 1
  quarantine=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" -d "$reclaim.stale.XXXXXX" 2>/dev/null) || return 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RMDIR_BIN" "$quarantine" || return 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$reclaim" "$quarantine" 2>/dev/null || return 1
  quarantined_inode=$(fm_account_path_inode "$quarantine" 2>/dev/null || true)
  if [ "$quarantined_inode" != "$observed_inode" ]; then
    if [ ! -e "$reclaim" ] && [ ! -L "$reclaim" ]; then
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$quarantine" "$reclaim" 2>/dev/null || true
    fi
    return 1
  fi
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$quarantine" || return 1
  fm_account_reclaim_guard_acquire "$reclaim" "$grace"
}

fm_account_meta_lock_reclaim() {  # <lock-path> <ownerless-grace-seconds>
  local lock=$1 grace=$2 now mtime reclaim guard inode_before inode_after generation
  local ownerless_since ownerless_tmp baseline required_grace
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  [ ! -L "$lock" ] || return 1
  required_grace=$grace
  [ "$required_grace" -ge 1 ] || required_grace=1
  if [ -f "$lock" ]; then
    mtime=$(fm_account_path_mtime "$lock") || return 1
    [ -n "$FM_ACCOUNT_SYSTEM_DATE_BIN" ] || return 1
    now=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s)
    [ $((now - mtime)) -ge "$required_grace" ] || return 1
    guard="$lock.reclaiming"
    fm_account_reclaim_guard_acquire "$guard" "$required_grace" || return 1
    # Pin the observed generation so unlink-and-replace cannot recycle its inode before comparison.
    generation=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" -d "$lock.generation.XXXXXX" 2>/dev/null) || { fm_account_reclaim_guard_release "$guard"; return 1; }
    if ! fm_account_system_exec "$FM_ACCOUNT_SYSTEM_LN_BIN" -n "$lock" "$generation/lock" 2>/dev/null; then
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation"
      fm_account_reclaim_guard_release "$guard"
      return 1
    fi
    inode_before=$(fm_account_path_inode "$generation/lock") || {
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation"
      fm_account_reclaim_guard_release "$guard"
      return 1
    }
    if fm_account_meta_lock_owner_alive "$lock"; then
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation"
      fm_account_reclaim_guard_release "$guard"
      return 1
    fi
    fm_account_reclaim_guard_owned "$guard" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation"; return 1; }
    inode_after=$(fm_account_path_inode "$lock") || {
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation"
      fm_account_reclaim_guard_release "$guard"
      return 1
    }
    if [ "$inode_before" != "$inode_after" ]; then
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation"
      fm_account_reclaim_guard_release "$guard"
      return 1
    fi
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$lock" || {
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation"
      fm_account_reclaim_guard_release "$guard"
      return 1
    }
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$generation" || { fm_account_reclaim_guard_release "$guard"; return 1; }
    fm_account_reclaim_guard_release "$guard"
    return 0
  fi
  [ -d "$lock" ] || return 1
  inode_before=$(fm_account_path_inode "$lock") || return 1
  mtime=$(fm_account_path_mtime "$lock") || return 1
  guard="$lock/.reclaiming"
  fm_account_reclaim_guard_acquire "$guard" "$required_grace" || return 1
  inode_after=$(fm_account_path_inode "$lock") || { fm_account_reclaim_guard_release "$guard"; return 1; }
  if [ "$inode_before" != "$inode_after" ]; then
    fm_account_reclaim_guard_release "$guard"
    return 1
  fi
  if [ -f "$lock/owner" ]; then
    if fm_account_meta_lock_owner_alive "$lock"; then
      fm_account_reclaim_guard_release "$guard"
      return 1
    fi
  else
    ownerless_since="$lock/.ownerless-since"
    if [ -e "$ownerless_since" ] || [ -L "$ownerless_since" ]; then
      [ -f "$ownerless_since" ] && [ ! -L "$ownerless_since" ] || {
        fm_account_reclaim_guard_release "$guard"
        return 1
      }
    else
      ownerless_tmp=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$lock/.ownerless-since.XXXXXX" 2>/dev/null) || {
        fm_account_reclaim_guard_release "$guard"
        return 1
      }
      if ! printf '%s\n' "$mtime" > "$ownerless_tmp"; then
        fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$ownerless_tmp"
        fm_account_reclaim_guard_release "$guard"
        return 1
      fi
      if ! fm_account_system_exec "$FM_ACCOUNT_SYSTEM_LN_BIN" -n "$ownerless_tmp" "$ownerless_since" 2>/dev/null; then
        fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$ownerless_tmp"
        [ -f "$ownerless_since" ] && [ ! -L "$ownerless_since" ] || {
          fm_account_reclaim_guard_release "$guard"
          return 1
        }
      else
        fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$ownerless_tmp"
      fi
    fi
    [ -f "$ownerless_since" ] && [ ! -L "$ownerless_since" ] || {
      fm_account_reclaim_guard_release "$guard"
      return 1
    }
    [ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || return 1
    baseline=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" -n '1p' "$ownerless_since" 2>/dev/null)
    case "$baseline" in
      ''|*[!0-9]*) fm_account_reclaim_guard_release "$guard"; return 1 ;;
    esac
    [ -n "$FM_ACCOUNT_SYSTEM_DATE_BIN" ] || return 1
    now=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s)
    if [ $((now - baseline)) -lt "$required_grace" ]; then
      if fm_account_meta_lock_owner_alive "$lock"; then
        fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$ownerless_since"
      fi
      fm_account_reclaim_guard_release "$guard"
      return 1
    fi
  fi
  if fm_account_meta_lock_owner_alive "$lock"; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$lock/.ownerless-since"
    fm_account_reclaim_guard_release "$guard"
    return 1
  fi
  fm_account_reclaim_guard_owned "$guard" || return 1
  inode_after=$(fm_account_path_inode "$lock") || return 1
  [ "$inode_before" = "$inode_after" ] || return 1
  reclaim=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" -d "$lock.reclaim.XXXXXX" 2>/dev/null) || { fm_account_reclaim_guard_release "$guard"; return 1; }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RMDIR_BIN" "$reclaim" \
    || { fm_account_reclaim_guard_release "$guard"; return 1; }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$lock" "$reclaim" 2>/dev/null || { fm_account_reclaim_guard_release "$guard"; return 1; }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$reclaim"
}

fm_account_lock_acquire() {  # <state-dir> <task> <name> <label> <wait-seconds>
  local state=$1 task=$2 name=$3 label=$4 wait_seconds=$5 lock deadline now start owner_tmp owner_inode lock_inode
  local ownerless_grace=${FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS:-2}
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  fm_account_valid_id "$task" || { echo "error: invalid task id '$task' for $label lock" >&2; return 1; }
  case "$name" in *[!A-Za-z0-9._-]*|'') echo "error: invalid account lock name '$name'" >&2; return 1 ;; esac
  case "$wait_seconds" in ''|*[!0-9]*) echo "error: invalid $label lock wait '$wait_seconds'" >&2; return 1 ;; esac
  case "$ownerless_grace" in ''|*[!0-9]*) echo "error: invalid $label lock ownerless grace '$ownerless_grace'" >&2; return 1 ;; esac
  start=$(fm_account_process_start_time "$$") || {
    echo "error: cannot record $label lock owner for $task" >&2
    return 1
  }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKDIR_BIN" -p "$state" || return 1
  fm_account_real_directory "$state" || return 1
  lock="$state/.$name-$task.lock"
  owner_tmp=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$state/.$name-$task.owner.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n%s\n' "$$" "$start" > "$owner_tmp" || {
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$owner_tmp"
    return 1
  }
  owner_inode=$(fm_account_path_inode "$owner_tmp") || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$owner_tmp"; return 1; }
  [ -n "$FM_ACCOUNT_SYSTEM_DATE_BIN" ] || return 1
  deadline=$(( $(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s) + wait_seconds ))
  while :; do
    if fm_account_system_exec "$FM_ACCOUNT_SYSTEM_LN_BIN" -n "$owner_tmp" "$lock" 2>/dev/null; then
      lock_inode=$(fm_account_path_inode "$lock" 2>/dev/null || true)
      if [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$lock_inode" = "$owner_inode" ]; then
        break
      fi
      if [ -d "$lock" ] && [ ! -L "$lock" ]; then
        fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$lock/${owner_tmp##*/}" 2>/dev/null || true
      fi
    fi
    if fm_account_meta_lock_reclaim "$lock" "$ownerless_grace"; then
      continue
    fi
    if [ "${FM_ACCOUNT_ROUTING_TEST_LAB:-}" = firstmate-account-routing-test-lab-v1 ] \
      && [ "${FM_ACCOUNT_TEST_HOOKS:-}" = firstmate-account-tests-v1 ] \
      && [ -n "${FM_ACCOUNT_LOCK_WAIT_TEST_OBSERVED:-}" ]; then
      printf '%s\n' "$lock" > "$FM_ACCOUNT_LOCK_WAIT_TEST_OBSERVED" || {
        fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$owner_tmp"
        return 1
      }
    fi
    now=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s)
    [ "$now" -lt "$deadline" ] || {
      echo "error: timed out waiting for $label lock for $task" >&2
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$owner_tmp"
      return 1
    }
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SLEEP_BIN" 0.05
  done
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$owner_tmp"
  printf '%s\n' "$lock"
}

fm_account_meta_lock_acquire() {  # <state-dir> <task>
  fm_account_lock_acquire "$1" "$2" account-meta "account metadata" "${FM_ACCOUNT_META_LOCK_WAIT_SECONDS:-10}"
}

fm_account_lifecycle_lock_acquire() {  # <state-dir> <task>
  fm_account_lock_acquire "$1" "$2" account-lifecycle "account lifecycle" "${FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS:-10}"
}

fm_account_stable_path_key() {
  fm_checkout_stable_path_key "$1" "$2" 1 24
}

fm_secondmate_home_lifecycle_lock_acquire() {
  local state_base=$1 home=$2 key
  key=$(fm_account_stable_path_key "$home" directory) || {
    echo "error: secondmate home lifecycle target is unsafe or its lock identity is unavailable: $home" >&2
    return 1
  }
  fm_account_lock_acquire "$state_base/secondmate-home-lifecycle" "home-$key" \
    secondmate-home-lifecycle "secondmate home lifecycle" "${FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS:-10}"
}

fm_secondmate_registry_lock_acquire() {
  local state_base=$1 registry=$2 key
  key=$(fm_account_stable_path_key "$registry" file) || {
    echo "error: secondmate registry lock identity is unavailable: $registry" >&2
    return 1
  }
  fm_account_lock_acquire "$state_base/secondmate-registry" "registry-$key" \
    secondmate-registry "secondmate registry" "${FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS:-10}"
}

fm_secondmate_registry_query() {
  local registry=$1 mode=${2:-validate} expected_id=${3:-} key=${4:-}
  fm_account_system_perl -MErrno=ENOENT - "$registry" "$mode" "$expected_id" "$key" <<'PERL'
    my ($registry, $mode, $expected_id, $key) = @ARGV;
    if (!lstat($registry)) {
      exit 0 if $! == ENOENT && ($mode eq q{validate} || $mode eq q{list});
      exit 1;
    }
    exit 1 if -l _ || !-f _ || !-r _;
    open my $fh, q{<}, $registry or exit 1;
    my @entries;
    my $line_number = 0;
    while (my $line = <$fh>) {
      ++$line_number;
      next if $line =~ /^\s*$/ || $line =~ /^#/;
      exit 1 if $line !~ /^- /;
      chomp $line;
      my ($id, $summary, $home, $scope, $projects, $added) =
        $line =~ /^- ([A-Za-z0-9][A-Za-z0-9._-]*) - (.+) \(home: ([^;]+); scope: ([^;]+); projects: ([^;]*); added ([0-9]{4}-[0-9]{2}-[0-9]{2})\)$/;
      exit 1 if !defined($id) || $summary eq q{} || $scope eq q{};
      exit 1 if $home !~ m{^/} || $home =~ /[\0\t\r\n]/ || $home =~ m{(?:^|/)\.\.?($|/)};
      exit 1 if $projects ne q{} && $projects !~ /^[A-Za-z0-9][A-Za-z0-9._-]*(?:, [A-Za-z0-9][A-Za-z0-9._-]*)*$/;
      my $current = q{};
      for my $component (grep { $_ ne q{} } split m{/+}, $home) {
        $current .= q{/} . $component;
        lstat($current) or exit 1;
        exit 1 if -l _;
      }
      exit 1 if !-d $home;
      my @identity = stat($home);
      exit 1 if !@identity;
      push @entries, [$id, $home, $projects, "$identity[0]:$identity[1]"];
    }
    my (%ids, %homes);
    for my $index (0 .. $#entries) {
      my $entry = $entries[$index];
      exit 1 if $ids{$entry->[0]}++ || exists $homes{$entry->[3]};
      $homes{$entry->[3]} = $entry->[0];
      for my $prior_index (0 .. $index - 1) {
        my $prior = $entries[$prior_index];
        exit 1 if index($entry->[1], $prior->[1] . q{/}) == 0;
        exit 1 if index($prior->[1], $entry->[1] . q{/}) == 0;
      }
    }
    if ($mode eq q{validate}) {
      exit 0;
    }
    if ($mode eq q{list}) {
      for my $entry (@entries) {
        print join(qq{\t}, $entry->[0], $entry->[1], $entry->[2]), qq{\n};
      }
      exit 0;
    }
    my @matches = grep { $_->[0] eq $expected_id } @entries;
    exit 1 if @matches != 1;
    if ($key eq q{home}) {
      print $matches[0]->[1];
    } elsif ($key eq q{projects}) {
      print $matches[0]->[2];
    } else {
      exit 1;
    }
PERL
}

fm_account_lifecycle_lock_owned() {  # <lock-path>
  fm_account_reclaim_guard_owned "$1"
}

fm_account_lifecycle_lock_held() {  # <lock-path>
  fm_account_meta_lock_owner_alive "$1"
}

fm_account_lifecycle_lock_identity() {  # <lock-path>
  fm_account_lock_owner_identity "$1"
}

fm_account_meta_lock_release() {  # <lock-path>
  local lock=$1 owner pid released
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  [ -e "$lock" ] || return 0
  if [ -f "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock
  elif [ -d "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock/owner
  else
    echo "error: refusing to release unsafe account metadata lock $lock" >&2
    return 1
  fi
  [ -f "$owner" ] && [ ! -L "$owner" ] || {
    echo "error: refusing to release account metadata lock with unsafe owner control $owner" >&2
    return 1
  }
  [ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || return 1
  pid=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" -n '1p' "$owner" 2>/dev/null)
  [ "$pid" = "$$" ] || {
    echo "error: refusing to release account metadata lock owned by ${pid:-unknown}" >&2
    return 1
  }
  if [ -f "$lock" ]; then
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$lock" || return 1
    return 0
  fi
  released=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" -d "$lock.release.XXXXXX" 2>/dev/null) || return 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RMDIR_BIN" "$released" || return 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$lock" "$released" || return 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$released"
}

fm_account_lifecycle_lock_release() {  # <lock-path>
  fm_account_meta_lock_release "$1"
}

fm_account_safe_lineage_value() {
  case "$1" in *$'\t'*|*$'\n'*) return 1 ;; esac
}

fm_account_meta_key_owned() {  # <key>
  case "$1" in
    window|worktree|worktree_git_dir|worktree_git_dir_identity|worktree_git_ref|worktree_git_head|worktree_git_setup_ref|worktree_git_setup_head|project|harness|kind|mode|yolo|tasktmp|tasktmp_phase|model|effort|report_required|generation_id|backend|tmux_window_id|tmux_session_target|account_home|direct_spawn_cleanup|direct_spawn_endpoint|direct_spawn_backup|direct_spawn_artifacts|direct_recovery_cleanup|direct_recovery_backup|direct_recovery_artifacts|account_pool|account_profile|account_task|account_attempt|account_predecessor_task|account_predecessor_attempt|account_predecessor_provider|account_predecessor_profile|account_predecessor_pool|account_predecessor_session|account_predecessor_cleanup|account_rollback_cleanup|account_rollback_backup|account_rollback_artifacts|account_rollback_preserve_session|continuation_packet|provider_session_id|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id|zellij_session|zellij_tab_id|zellij_pane_id|orca_worktree_id|terminal|orca_cleanup_pending|orca_cleanup_phase|orca_terminal_proof|orca_repo_id|orca_expected_task|orca_provider_task|orca_discovery_label|orca_provider_scope|cmux_workspace_id|cmux_surface_id|home|projects|rollback_pending) return 0 ;;
    *) return 1 ;;
  esac
}

fm_account_meta_merge_extensions() {  # <source-meta> <destination-meta>
  local source=$1 destination=$2 line key tmp
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  [ -f "$source" ] || return 0
  tmp=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" \
    "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$destination")/.account-extensions.XXXXXX" 2>/dev/null) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    fm_account_meta_key_owned "$key" || continue
    printf '%s\n' "$line" >> "$tmp" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; return 1; }
  done < "$destination"
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    fm_account_meta_key_owned "$key" && continue
    printf '%s\n' "$line" >> "$tmp" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; return 1; }
  done < "$source"
  fm_account_safe_file_destination "$destination" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; return 1; }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$tmp" "$destination" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; return 1; }
}

fm_account_task_dir() {  # <data-dir> <task> [create]
  local data=$1 task=$2 create=${3:-} data_real expected actual
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  fm_account_valid_id "$task" || return 1
  [ -d "$data" ] || return 1
  data_real=$(cd "$data" 2>/dev/null && pwd -P) || return 1
  expected="$data_real/$task"
  if [ ! -e "$expected" ] && [ ! -L "$expected" ]; then
    [ "$create" = create ] || return 1
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKDIR_BIN" "$expected" || return 1
  fi
  [ -d "$expected" ] && [ ! -L "$expected" ] || return 1
  actual=$(cd "$expected" 2>/dev/null && pwd -P) || return 1
  [ "$actual" = "$expected" ] || return 1
  printf '%s\n' "$expected"
}

fm_account_safe_task_file() {  # <file>
  if [ -e "$1" ] || [ -L "$1" ]; then
    [ -f "$1" ] && [ ! -L "$1" ]
  fi
}

fm_account_lineage_append() (  # <data-dir> <task> <event> <attempt> <fleet-task> <provider> <pool> <profile> <session> <predecessor>
  local data=$1 task=$2 event=$3 attempt=$4 fleet_task=$5 provider=$6 pool=$7 profile=$8 session=$9 predecessor=${10}
  local dir file value data_real lineage_lock lib_dir
  for value in "$task" "$event" "$attempt" "$fleet_task" "$provider" "$pool" "$profile" "$session" "$predecessor"; do
    fm_account_safe_lineage_value "$value" || {
      echo "error: unsafe account-attempt lineage value" >&2
      return 1
    }
  done
  dir=$(fm_account_task_dir "$data" "$task" create) || return 1
  data_real=${dir%/*}
  [ -n "$data_real" ] || data_real=/
  lineage_lock=$(fm_account_lock_acquire "$data_real" "$task" account-lineage "account lineage" "${FM_ACCOUNT_LINEAGE_LOCK_WAIT_SECONDS:-10}") || return 1
  trap 'fm_account_meta_lock_release "$lineage_lock" >/dev/null 2>&1 || true' EXIT
  file="$dir/account-attempts.md"
  fm_account_safe_task_file "$file" || return 1
  lib_dir=${BASH_SOURCE[0]%/*}
  [ "$lib_dir" != "${BASH_SOURCE[0]}" ] || lib_dir=.
  lib_dir=$(cd "$lib_dir" && pwd -P) || return 1
  printf -- '- %s event=%s attempt=%s agent_fleet_task=%s provider=%s pool=%s profile=%s session=%s predecessor=%s.\n' \
    "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$attempt" "$fleet_task" "$provider" "$pool" "$profile" "${session:-pending}" "${predecessor:-none}" \
    | node "$lib_dir/fm-task-file-append.mjs" "$data_real" "$task" account-attempts.md '# Account attempt lineage'
)

fm_account_meta_value() {  # <meta> <key>
  [ -n "$FM_ACCOUNT_SYSTEM_AWK_BIN" ] || return 1
  # shellcheck disable=SC2016
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_AWK_BIN" -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$1" 2>/dev/null
}

fm_account_restore_artifacts() {
  local state=$1 task=$2 backup_name=$3 tasktmp=${4:-} retain=${5:-0} generation=${6:-} backup name source
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  [ -n "$backup_name" ] || return 0
  case "$backup_name" in
    ".$task.artifacts.rollback."*) ;;
    *) return 1 ;;
  esac
  fm_account_valid_id "${backup_name#".$task.artifacts.rollback."}" || return 1
  backup="$state/$backup_name"
  [ -d "$backup" ] && [ ! -L "$backup" ] || return 1
  for name in "$task.status" "$task.turn-ended" "$task.check.sh" "$task.pi-ext.ts" "$task.grok-turnend-token"; do
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$state/$name" || return 1
    source="$backup/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then
      fm_account_system_exec "$FM_ACCOUNT_SYSTEM_CP_BIN" -Pp "$source" "$state/$name" || return 1
    fi
  done
  if [ -n "$tasktmp" ]; then
    if fm_account_task_tmp_is_current "$task" "$tasktmp" "$generation" \
      || fm_account_task_tmp_is_previous "$task" "$tasktmp"; then
      if [ -e "$backup/tasktmp-existed" ]; then
        [ -e "$backup/gotmp-existed" ] || fm_account_safe_remove_task_tmp "$task" "$tasktmp" "$generation" gotmp || return 1
      else
        fm_account_safe_remove_task_tmp "$task" "$tasktmp" "$generation" || return 1
      fi
    else
      # A legacy tasktmp is metadata-only compatibility. Never inspect or
      # mutate the shared /tmp path while restoring task-owned artifacts.
      fm_account_task_tmp_is_legacy "$task" "$tasktmp" || return 1
    fi
  fi
  [ "$retain" = 1 ] || fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$backup"
}

fm_account_cleanup_rollback() {  # <meta> <data-dir> <task>
  local meta=$1 data=$2 task=$3 pending account_task attempt provider pool profile session preserve backup_name backup_token backup predecessor backup_task tmp artifacts_name artifacts_token artifacts tasktmp lock
  local caller_path=$PATH
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  pending=$(fm_account_meta_value "$meta" account_rollback_cleanup)
  [ "$pending" = pending ] || return 0
  account_task=$(fm_account_meta_value "$meta" account_task)
  attempt=$(fm_account_meta_value "$meta" account_attempt)
  provider=$(fm_account_meta_value "$meta" harness)
  pool=$(fm_account_meta_value "$meta" account_pool)
  profile=$(fm_account_meta_value "$meta" account_profile)
  session=$(fm_account_meta_value "$meta" provider_session_id)
  preserve=$(fm_account_meta_value "$meta" account_rollback_preserve_session)
  backup_name=$(fm_account_meta_value "$meta" account_rollback_backup)
  artifacts_name=$(fm_account_meta_value "$meta" account_rollback_artifacts)
  tasktmp=$(fm_account_meta_value "$meta" tasktmp)
  predecessor=$(fm_account_meta_value "$meta" account_predecessor_task)
  fm_account_valid_id "$account_task" || {
    echo "error: invalid failed Agent Fleet attempt for $task" >&2
    return 1
  }
  case "$preserve" in ''|0|1) ;; *) echo "error: invalid rollback session policy for $task" >&2; return 1 ;; esac
  backup=
  if [ -n "$backup_name" ]; then
    case "$backup_name" in
      ".$task.meta.rollback."*) ;;
      *) echo "error: unsafe rollback backup for $task" >&2; return 1 ;;
    esac
    backup_token=${backup_name#".$task.meta.rollback."}
    fm_account_valid_id "$backup_token" || { echo "error: unsafe rollback backup for $task" >&2; return 1; }
    backup="$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")/$backup_name"
    [ -f "$backup" ] && [ ! -L "$backup" ] || {
      echo "error: rollback backup is missing for $task" >&2
      return 1
    }
    backup_task=$(fm_account_meta_value "$backup" account_task)
    if [ -n "$predecessor" ]; then
      [ "$backup_task" = "$predecessor" ] || {
        echo "error: rollback backup does not match the predecessor for $task" >&2
        return 1
      }
    elif [ "$preserve" = 1 ]; then
      [ "$backup_task" = "$account_task" ] || {
        echo "error: rollback backup does not match the native recovery for $task" >&2
        return 1
      }
    fi
  fi
  artifacts=
  if [ -n "$artifacts_name" ]; then
    case "$artifacts_name" in
      ".$task.artifacts.rollback."*) ;;
      *) echo "error: unsafe rollback artifact backup for $task" >&2; return 1 ;;
    esac
    artifacts_token=${artifacts_name#".$task.artifacts.rollback."}
    fm_account_valid_id "$artifacts_token" || { echo "error: unsafe rollback artifact backup for $task" >&2; return 1; }
    artifacts="$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")/$artifacts_name"
    [ -d "$artifacts" ] && [ ! -L "$artifacts" ] || {
      echo "error: rollback artifact backup is missing for $task" >&2
      return 1
    }
  fi
  fm_account_release "$account_task" --force || return 1
  if [ "$preserve" != 1 ]; then
    fm_account_session_remove "$account_task" || return 1
  fi
  fm_account_restore_artifacts "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")" "$task" "$artifacts_name" "$tasktmp" 1 "$(fm_account_meta_value "$meta" generation_id)" || return 1
  lock=$(fm_account_meta_lock_acquire "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")" "$task") || return 1
  if [ ! -f "$meta" ] \
    || [ "$(fm_account_meta_value "$meta" account_task)" != "$account_task" ] \
    || [ "$(fm_account_meta_value "$meta" account_rollback_cleanup)" != pending ]; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: managed task generation changed before rollback cleanup commit for $task" >&2
    return 1
  fi
  if [ -n "$backup" ]; then
    if [ ! -f "$backup" ] || [ -L "$backup" ]; then
      fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
      echo "error: rollback backup is missing for $task" >&2
      return 1
    fi
    tmp=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")/.$task.meta.rollback-restore.XXXXXX" 2>/dev/null) || { fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_CP_BIN" -p "$backup" "$tmp" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    fm_account_meta_merge_extensions "$meta" "$tmp" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    fm_account_safe_file_destination "$meta" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$tmp" "$meta" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$backup"
  else
    tmp=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")/.$task.meta.rollback-clean.XXXXXX" 2>/dev/null) || { fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_AWK_BIN" '!/^account_/ && !/^provider_session_id=/ && !/^continuation_packet=/ && !/^rollback_pending=/' "$meta" > "$tmp" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    printf 'rollback_pending=1\n' >> "$tmp"
    fm_account_safe_file_destination "$meta" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$tmp" "$meta" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"; fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true; return 1; }
  fi
  fm_account_meta_lock_release "$lock" || return 1
  [ -z "$artifacts" ] || fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -rf "$artifacts"
  [ -n "$attempt" ] || attempt=legacy
  PATH=$caller_path fm_account_lineage_append "$data" "$task" rolled-back "$attempt" "$account_task" "$provider" "$pool" "$profile" "$session" "${predecessor:-none}" || {
    echo "warning: failed attempt cleanup completed but lineage recording failed for $task" >&2
  }
}

fm_account_cleanup_predecessor() {  # <meta> <data-dir> <task>
  fm_account_cleanup_predecessor_serialized "$@"
}

fm_account_cleanup_predecessor_serialized() {  # <meta> <data-dir> <task>
  local meta=$1 data=$2 task=$3 pending predecessor current attempt provider pool profile session tmp lock
  local caller_path=$PATH
  local PATH=$FM_ACCOUNT_SYSTEM_PATH
  pending=$(fm_account_meta_value "$meta" account_predecessor_cleanup)
  [ "$pending" = pending ] || return 0
  predecessor=$(fm_account_meta_value "$meta" account_predecessor_task)
  current=$(fm_account_meta_value "$meta" account_task)
  attempt=$(fm_account_meta_value "$meta" account_predecessor_attempt)
  provider=$(fm_account_meta_value "$meta" account_predecessor_provider)
  [ -n "$provider" ] || provider=$(fm_account_meta_value "$meta" harness)
  pool=$(fm_account_meta_value "$meta" account_predecessor_pool)
  profile=$(fm_account_meta_value "$meta" account_predecessor_profile)
  session=$(fm_account_meta_value "$meta" account_predecessor_session)
  [ -n "$predecessor" ] && [ -n "$current" ] && [ "$predecessor" != "$current" ] || {
    echo "error: invalid predecessor cleanup metadata for $task" >&2
    return 1
  }
  if ! fm_account_valid_id "$predecessor" || ! fm_account_valid_id "$current"; then
    echo "error: unsafe predecessor cleanup identity for $task" >&2
    return 1
  fi
  [ -n "$(fm_account_meta_value "$meta" provider_session_id)" ] || {
    echo "error: current managed session is unverified for predecessor cleanup of $task" >&2
    return 1
  }
  fm_account_release "$predecessor" --force || return 1
  fm_account_session_remove "$predecessor" || return 1
  lock=$(fm_account_meta_lock_acquire "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")" "$task") || return 1
  if [ ! -f "$meta" ] \
    || [ "$(fm_account_meta_value "$meta" account_task)" != "$current" ] \
    || [ "$(fm_account_meta_value "$meta" account_predecessor_task)" != "$predecessor" ] \
    || [ "$(fm_account_meta_value "$meta" account_predecessor_cleanup)" != pending ]; then
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    echo "error: managed task generation changed before predecessor cleanup commit for $task" >&2
    return 1
  fi
  tmp=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DIRNAME_BIN" "$meta")/.$task.meta.predecessor.XXXXXX" 2>/dev/null) || {
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_AWK_BIN" '!/^account_predecessor_/ && !/^account_predecessor_cleanup=/' "$meta" > "$tmp" || {
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  }
  fm_account_safe_file_destination "$meta" || {
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$tmp" "$meta" || {
    fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$tmp"
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  }
  fm_account_meta_lock_release "$lock" || return 1
  [ -n "$attempt" ] || attempt=legacy
  PATH=$caller_path fm_account_lineage_append "$data" "$task" predecessor-released "$attempt" "$predecessor" "$provider" "$pool" "$profile" "$session" "$current" || {
    echo "warning: predecessor cleanup completed but lineage recording failed for $task" >&2
  }
}

fm_account_secondmate_pool() {  # <config-dir>
  local value
  value=$(fm_account_read_single_value "$1/secondmate-account-pool") || return $?
  fm_account_valid_id "$value" || {
    echo "error: invalid account pool '$value' in config/secondmate-account-pool" >&2
    return 2
  }
  printf '%s\n' "$value"
}

fm_account_default_pool() {  # <harness>
  case "$1" in
    claude|codex) printf '%s-crew\n' "$1" ;;
    *) return 1 ;;
  esac
}

fm_account_json_field() {  # <json> <jq-expression> <label>
  local json=$1 expression=$2 label=$3 value
  [ -n "$FM_ACCOUNT_SYSTEM_JQ_BIN" ] || {
    echo "error: fixed system jq is required for account routing" >&2
    return 1
  }
  value=$(printf '%s\n' "$json" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_JQ_BIN" -er "$expression" 2>/dev/null) || {
    echo "error: agent-fleet returned invalid $label JSON" >&2
    return 1
  }
  printf '%s\n' "$value"
}

fm_account_reconcile_lease_mutation() {  # <binary> <task> <workspace> <operation>
  local binary=$1 task=$2 workspace=$3 operation=$4
  FM_ACCOUNT_RECONCILED_JSON=
  if FM_ACCOUNT_RECONCILED_JSON=$(fm_account_run_selection "$binary" --format json lease recover --task "$task" --workspace "$workspace"); then
    return 0
  fi
  echo "error: Agent Fleet $operation failed and ownership could not be reconciled for $task" >&2
  return 2
}

fm_account_mutation_defer_signals() {
  FM_ACCOUNT_MUTATION_PENDING_SIGNAL=
  FM_ACCOUNT_MUTATION_SAVED_TRAPS=$(trap -p HUP INT TERM)
  trap 'FM_ACCOUNT_MUTATION_PENDING_SIGNAL=HUP' HUP
  trap 'FM_ACCOUNT_MUTATION_PENDING_SIGNAL=INT' INT
  trap 'FM_ACCOUNT_MUTATION_PENDING_SIGNAL=TERM' TERM
}

fm_account_mutation_finish_handoff() {
  local pending=${FM_ACCOUNT_MUTATION_PENDING_SIGNAL:-} saved=${FM_ACCOUNT_MUTATION_SAVED_TRAPS:-}
  trap - HUP INT TERM
  [ -z "$saved" ] || eval "$saved"
  FM_ACCOUNT_MUTATION_PENDING_SIGNAL=
  FM_ACCOUNT_MUTATION_SAVED_TRAPS=
  [ -z "$pending" ] || kill -s "$pending" "$$"
}

fm_account_mutation_owned() {
  [ "${FM_ACCOUNT_MUTATION_ACQUIRED:-0}" = 1 ]
}

# Sets FM_ACCOUNT_SELECTED_PROFILE and FM_ACCOUNT_SELECTED_PROVIDER.
# In observe mode these are shadow values only and callers must not persist or
# apply them.
fm_account_select() {  # <mode> <harness> <pool> <profile-or-empty> <task> <workspace>
  local mode=$1 harness=$2 pool=$3 requested_profile=$4 task=$5 workspace=$6 binary json status acquired=0 selected_task selected_pool selected_workspace
  FM_ACCOUNT_MUTATION_ACQUIRED=0
  FM_ACCOUNT_SELECTED_PROFILE=
  FM_ACCOUNT_SELECTED_PROVIDER=
  case "$harness" in
    claude|codex) ;;
    *)
      if [ "$mode" = enforce ]; then
        echo "error: account routing supports only claude and codex, not '$harness'" >&2
        return 1
      fi
      return 0
      ;;
  esac
  fm_account_valid_id "$pool" || { echo "error: invalid account pool '$pool'" >&2; return 1; }
  [ -d "$workspace" ] || { echo "error: account routing workspace is unavailable: $workspace" >&2; return 1; }
  [ -z "$requested_profile" ] || fm_account_valid_id "$requested_profile" || {
    echo "error: invalid account profile '$requested_profile'" >&2
    return 1
  }
  fm_account_pin_fleet_bin || {
    [ "$mode" = observe ] && { echo "fm-account-routing: observe unavailable; legacy launch unchanged" >&2; return 0; }
    return 1
  }
  binary=$FM_ACCOUNT_FLEET_PINNED_BIN
  fm_account_validate_contract "$binary" || {
    [ "$mode" = observe ] && { echo "fm-account-routing: observe contract unavailable; legacy launch unchanged" >&2; return 0; }
    return 1
  }
  if [ "$mode" = observe ]; then
    if json=$(fm_account_run_selection "$binary" --format json choose --pool "$pool" --task "$task" --provider "$harness" --workspace "$workspace" --dry-run 2>/dev/null); then
      status=0
    else
      status=$?
    fi
    if [ "$status" -ne 0 ]; then
      echo "fm-account-routing: observe decision unavailable for pool=$pool provider=$harness; legacy launch unchanged" >&2
      return 0
    fi
  else
    fm_account_mutation_defer_signals
    if [ -n "$requested_profile" ] && [ "$pool" = explicit ]; then
      if json=$(fm_account_run_selection "$binary" --format json lease acquire --profile "$requested_profile" --task "$task" --pool "$pool" --workspace "$workspace"); then status=0; else status=$?; fi
    elif [ -n "$requested_profile" ]; then
      if json=$(fm_account_run_selection "$binary" --format json lease choose --pool "$pool" --task "$task" --provider "$harness" --profile "$requested_profile" --workspace "$workspace"); then status=0; else status=$?; fi
    else
      if json=$(fm_account_run_selection "$binary" --format json lease choose --pool "$pool" --task "$task" --provider "$harness" --workspace "$workspace"); then status=0; else status=$?; fi
    fi
    if [ "$status" -ne 0 ]; then
      if fm_account_reconcile_lease_mutation "$binary" "$task" "$workspace" "lease mutation"; then
        json=$FM_ACCOUNT_RECONCILED_JSON
        status=0
      else
        status=$?
        fm_account_mutation_finish_handoff
        return "$status"
      fi
    fi
    [ "$status" -eq 0 ] || return "$status"
    acquired=1
    FM_ACCOUNT_MUTATION_ACQUIRED=1
    fm_account_mutation_finish_handoff
  fi
  if ! selected_task=$(fm_account_json_field "$json" '.task | select(type == "string" and length > 0)' selection) \
    || ! selected_pool=$(fm_account_json_field "$json" '.pool | select(type == "string" and length > 0)' selection) \
    || ! FM_ACCOUNT_SELECTED_PROFILE=$(fm_account_json_field "$json" '.profile | select(type == "string" and length > 0)' selection) \
    || ! FM_ACCOUNT_SELECTED_PROVIDER=$(fm_account_json_field "$json" '.provider | select(type == "string" and length > 0)' selection) \
    || ! selected_workspace=$(fm_account_json_field "$json" '.workspace | select(type == "string" and length > 0)' selection) \
    || [ "$selected_task" != "$task" ] \
    || [ "$selected_pool" != "$pool" ] \
    || [ "$selected_workspace" != "$workspace" ] \
    || ! fm_account_valid_id "$FM_ACCOUNT_SELECTED_PROFILE" \
    || [ "$FM_ACCOUNT_SELECTED_PROVIDER" != "$harness" ] \
    || { [ -n "$requested_profile" ] && [ "$FM_ACCOUNT_SELECTED_PROFILE" != "$requested_profile" ]; }; then
    FM_ACCOUNT_SELECTED_PROFILE=
    FM_ACCOUNT_SELECTED_PROVIDER=
    if [ "$mode" = observe ]; then
      echo "fm-account-routing: observe decision invalid for pool=$pool provider=$harness; legacy launch unchanged" >&2
      return 0
    fi
    echo "error: agent-fleet returned a mismatched account selection" >&2
    if [ "$acquired" = 1 ]; then
      if fm_account_release "$task" --force; then
        FM_ACCOUNT_MUTATION_ACQUIRED=0
      else
        echo "error: failed to release invalid Agent Fleet reservation for $task" >&2
        return 2
      fi
    fi
    return 1
  fi
  if [ "$mode" = observe ]; then
    echo "fm-account-routing: observe pool=$pool provider=$harness profile=$FM_ACCOUNT_SELECTED_PROFILE (no lease; legacy launch unchanged)" >&2
  fi
}

fm_account_exec_command() {  # <profile> <pool> <task> <workspace> <turn-end-marker>
  local binary prefix
  fm_account_pin_fleet_bin || return 1
  binary=$FM_ACCOUNT_FLEET_PINNED_BIN
  fm_account_validate_contract "$binary" || return 1
  prefix=$(fm_account_fleet_worker_prefix "$binary") || return 1
  printf '%s --format json exec --profile %s --task %s --pool %s --workspace %s --turn-end %s --' \
    "$prefix" \
    "$(fm_account_shell_quote "$1")" \
    "$(fm_account_shell_quote "$3")" \
    "$(fm_account_shell_quote "$2")" \
    "$(fm_account_shell_quote "$4")" \
    "$(fm_account_shell_quote "$5")"
}

fm_account_resume_command() {  # <task> <workspace> <turn-end-marker>
  local binary prefix
  fm_account_pin_fleet_bin || return 1
  binary=$FM_ACCOUNT_FLEET_PINNED_BIN
  fm_account_validate_contract "$binary" || return 1
  prefix=$(fm_account_fleet_worker_prefix "$binary") || return 1
  printf '%s --format json resume --task %s --workspace %s --turn-end %s --' \
    "$prefix" \
    "$(fm_account_shell_quote "$1")" \
    "$(fm_account_shell_quote "$2")" \
    "$(fm_account_shell_quote "$3")"
}

# Sets FM_ACCOUNT_SELECTED_PROFILE and FM_ACCOUNT_SELECTED_PROVIDER from a
# sticky recovery reservation. This path intentionally bypasses new-task quota
# reserve filtering inside Agent Fleet while still refusing a live owner.
fm_account_recover() {  # <task> <expected-profile> <expected-pool> <expected-provider> <workspace>
  local task=$1 expected_profile=$2 expected_pool=$3 expected_provider=$4 workspace=$5 binary json status mapped_task profile pool provider mapped_workspace
  FM_ACCOUNT_MUTATION_ACQUIRED=0
  fm_account_pin_fleet_bin || return 1
  binary=$FM_ACCOUNT_FLEET_PINNED_BIN
  fm_account_validate_contract "$binary" || return 1
  fm_account_mutation_defer_signals
  if json=$(fm_account_run_selection "$binary" --format json lease recover --task "$task" --workspace "$workspace"); then status=0; else status=$?; fi
  if [ "$status" -ne 0 ]; then
    if fm_account_reconcile_lease_mutation "$binary" "$task" "$workspace" "recovery mutation"; then
      json=$FM_ACCOUNT_RECONCILED_JSON
      status=0
    else
      status=$?
      fm_account_mutation_finish_handoff
      return "$status"
    fi
  fi
  if [ "$status" -ne 0 ]; then
    fm_account_mutation_finish_handoff
    return "$status"
  fi
  FM_ACCOUNT_MUTATION_ACQUIRED=1
  fm_account_mutation_finish_handoff
  if ! mapped_task=$(fm_account_json_field "$json" '.task | select(type == "string" and length > 0)' recovery) \
    || ! profile=$(fm_account_json_field "$json" '.profile | select(type == "string" and length > 0)' recovery) \
    || ! pool=$(fm_account_json_field "$json" '.pool | select(type == "string" and length > 0)' recovery) \
    || ! provider=$(fm_account_json_field "$json" '.provider | select(type == "string" and length > 0)' recovery) \
    || ! mapped_workspace=$(fm_account_json_field "$json" '.workspace | select(type == "string" and length > 0)' recovery) \
    || [ "$mapped_task" != "$task" ] \
    || [ "$profile" != "$expected_profile" ] \
    || [ "$pool" != "$expected_pool" ] \
    || [ "$provider" != "$expected_provider" ] \
    || [ "$mapped_workspace" != "$workspace" ]; then
    echo "error: agent-fleet returned mismatched recovery state for $task" >&2
    if fm_account_release "$task" --force; then
      FM_ACCOUNT_MUTATION_ACQUIRED=0
    else
      echo "error: failed to release invalid Agent Fleet recovery reservation for $task" >&2
    fi
    return 2
  fi
  FM_ACCOUNT_SELECTED_PROFILE=$profile
  FM_ACCOUNT_SELECTED_PROVIDER=$provider
}

fm_account_release() {  # <task> [--force]
  local binary task=$1 force=${2:-} out status errexit_was_on=0
  # Callers like spawn_abort_cleanup run their whole rollback with errexit
  # off; restore the caller's entry state instead of unconditionally
  # re-enabling errexit.
  case $- in *e*) errexit_was_on=1 ;; esac
  fm_account_pin_fleet_bin || return 1
  binary=$FM_ACCOUNT_FLEET_PINNED_BIN
  fm_account_validate_contract "$binary" || return 1
  set +e
  if [ "$force" = --force ]; then
    out=$(fm_account_run_control "$binary" --format json lease release --task "$task" --force 2>&1)
  else
    out=$(fm_account_run_control "$binary" --format json lease release --task "$task" 2>&1)
  fi
  status=$?
  if [ "$status" -eq 124 ]; then
    if [ "$force" = --force ]; then
      out=$(fm_account_run_control "$binary" --format json lease release --task "$task" --force 2>&1)
    else
      out=$(fm_account_run_control "$binary" --format json lease release --task "$task" 2>&1)
    fi
    status=$?
  fi
  [ "$errexit_was_on" -eq 0 ] || set -e
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  case "$out" in
    *"no lease for task"*) return 0 ;;
  esac
  printf '%s\n' "$out" >&2
  return "$status"
}

fm_account_session_remove() {  # <task>
  local binary out status errexit_was_on=0
  # Same errexit contract as fm_account_release.
  case $- in *e*) errexit_was_on=1 ;; esac
  fm_account_pin_fleet_bin || return 1
  binary=$FM_ACCOUNT_FLEET_PINNED_BIN
  fm_account_validate_contract "$binary" || return 1
  set +e
  out=$(fm_account_run_control "$binary" --format json session remove --task "$1" 2>&1)
  status=$?
  if [ "$status" -eq 124 ]; then
    out=$(fm_account_run_control "$binary" --format json session remove --task "$1" 2>&1)
    status=$?
  fi
  [ "$errexit_was_on" -eq 0 ] || set -e
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  case "$out" in
    *"no recorded provider session"*) return 0 ;;
  esac
  printf '%s\n' "$out" >&2
  return "$status"
}
