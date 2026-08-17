# shellcheck shell=bash
# shellcheck disable=SC2034 # output globals are consumed by scripts sourcing this library
# Home-local Claude account-profile mapping and native authentication preflight.
# Usage: . bin/fm-claude-account-profile-lib.sh
#
# docs/configuration.md owns the config/claude-account-profiles schema and setup.
# This library owns its validation and native authentication mechanics.
#
# fm_claude_account_profile_resolve validates the complete mapping and publishes
# only the selected canonical directory in FM_CLAUDE_ACCOUNT_PROFILE_DIR. A
# profile directory holds native credentials, so it must be owned by the calling
# user and carry no group or other permission bits.
# fm_claude_account_profile_preflight runs the exact native
# `claude auth status --json` command under that directory and accepts only a
# successful paid Claude-account session. Both functions keep paths and native
# status output out of diagnostics.
#
# bin/fm-vendor-auth-probe.sh remains the owner of registered fixed-argv vendor
# probes; this preflight is not one, because it must point the CLI at a
# caller-selected config directory and reads a paid-account discriminator that
# the probe's no-verdict status vocabulary does not carry. It adopts that
# script's safety envelope verbatim instead: stdin closed so caller input can
# never reach the vendor CLI, and a hard positive timeout so a hung or
# interactive CLI cannot wedge a spawn intake. Unlike the probe, an unbounded or
# unanswered command refuses the launch, because this function IS a gate.
#
# Environment:
#   FM_CLAUDE_ACCOUNT_PROFILE_TIMEOUT  hard bound in seconds for the native auth
#                                      command; a non-positive or non-numeric
#                                      value is rejected in favor of 20.

FM_CLAUDE_ACCOUNT_PROFILE_ERROR=
FM_CLAUDE_ACCOUNT_PROFILE_DIR=

fm_claude_account_profile_fail() {
  FM_CLAUDE_ACCOUNT_PROFILE_ERROR=$1
  return 1
}

fm_claude_account_profile_name_valid() {
  local name=$1
  [ -n "$name" ] && [ "${#name}" -le 32 ] || return 1
  case "$name" in
    [a-z]*) ;;
    *) return 1 ;;
  esac
  case "$name" in
    *[!a-z0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_claude_account_profile_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_claude_account_profile_file_owner() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

# Group and other bits are the last two octal digits in either stat spelling, so
# this reads the same on a plain 700 and on a setgid 2700.
fm_claude_account_profile_mode_is_private() {
  local mode=$1
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  [ "${mode#"${mode%??}"}" = 00 ]
}

# Bounded execution, mirroring bin/fm-vendor-auth-probe.sh's run_timed selection
# so a macOS host without coreutils still gets a hard bound. Exit 124 means the
# bound was hit or nothing on this host can impose one.
fm_claude_account_profile_run_timed() { # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}

fm_claude_account_profile_resolve() { # <config-dir> <profile-name>
  local config_dir=$1 selected=$2 file line alias dir physical line_no=0 entries=0
  local match=0 seen_aliases='' seen_dirs='' lf=$'\n' self_uid
  self_uid=$(id -u)
  FM_CLAUDE_ACCOUNT_PROFILE_ERROR=
  FM_CLAUDE_ACCOUNT_PROFILE_DIR=
  fm_claude_account_profile_name_valid "$selected" \
    || fm_claude_account_profile_fail "unsafe account profile name" || return 1
  file="$config_dir/claude-account-profiles"
  [ ! -L "$file" ] \
    || fm_claude_account_profile_fail "config/claude-account-profiles is a symlink" || return 1
  [ -f "$file" ] \
    || fm_claude_account_profile_fail "config/claude-account-profiles is missing or not a regular file" || return 1
  [ "$(fm_claude_account_profile_file_mode "$file")" = 600 ] \
    || fm_claude_account_profile_fail "config/claude-account-profiles must have mode 600" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      ''|'#'*) continue ;;
      *[[:cntrl:]]*)
        fm_claude_account_profile_fail "config/claude-account-profiles has a control character on line $line_no"
        return 1
        ;;
      *=*) alias=${line%%=*}; dir=${line#*=} ;;
      *)
        fm_claude_account_profile_fail "config/claude-account-profiles has a malformed record on line $line_no"
        return 1
        ;;
    esac
    entries=$((entries + 1))
    fm_claude_account_profile_name_valid "$alias" || {
      fm_claude_account_profile_fail "config/claude-account-profiles has an unsafe name on line $line_no"
      return 1
    }
    case "$dir" in
      /*) ;;
      *)
        fm_claude_account_profile_fail "account profile '$alias' does not name an absolute directory"
        return 1
        ;;
    esac
    [ ! -L "$dir" ] && [ -d "$dir" ] || {
      fm_claude_account_profile_fail "account profile '$alias' is missing, not a directory, or a symlink"
      return 1
    }
    physical=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || {
      fm_claude_account_profile_fail "account profile '$alias' cannot be resolved"
      return 1
    }
    [ "$physical" = "$dir" ] || {
      fm_claude_account_profile_fail "account profile '$alias' is not written as its physical canonical directory"
      return 1
    }
    [ "$(fm_claude_account_profile_file_owner "$dir")" = "$self_uid" ] || {
      fm_claude_account_profile_fail "account profile '$alias' directory is not owned by the current user"
      return 1
    }
    fm_claude_account_profile_mode_is_private "$(fm_claude_account_profile_file_mode "$dir")" || {
      fm_claude_account_profile_fail "account profile '$alias' directory must not be group- or world-accessible"
      return 1
    }
    case "$lf$seen_aliases$lf" in
      *"$lf$alias$lf"*)
        fm_claude_account_profile_fail "config/claude-account-profiles repeats an account profile name"
        return 1
        ;;
    esac
    case "$lf$seen_dirs$lf" in
      *"$lf$physical$lf"*)
        fm_claude_account_profile_fail "config/claude-account-profiles maps more than one name to the same directory"
        return 1
        ;;
    esac
    seen_aliases="${seen_aliases}${seen_aliases:+$lf}$alias"
    seen_dirs="${seen_dirs}${seen_dirs:+$lf}$physical"
    if [ "$alias" = "$selected" ]; then
      FM_CLAUDE_ACCOUNT_PROFILE_DIR=$physical
      match=1
    fi
  done < "$file"
  [ "$entries" -gt 0 ] \
    || fm_claude_account_profile_fail "config/claude-account-profiles contains no profile records" || return 1
  [ "$match" -eq 1 ] \
    || fm_claude_account_profile_fail "selected account profile is not mapped" || return 1
}

fm_claude_account_profile_preflight() { # <profile-name> <canonical-dir>
  local profile=$1 dir=$2 status bound rc=0
  FM_CLAUDE_ACCOUNT_PROFILE_ERROR=
  command -v claude >/dev/null 2>&1 \
    || fm_claude_account_profile_fail "account profile '$profile' cannot run native claude auth status" || return 1
  command -v jq >/dev/null 2>&1 \
    || fm_claude_account_profile_fail "account profile '$profile' cannot validate native claude auth status without jq" || return 1
  # A non-positive bound is not a bound: `timeout 0` and the Perl fallback's
  # `alarm 0` both disable the deadline.
  bound=${FM_CLAUDE_ACCOUNT_PROFILE_TIMEOUT:-20}
  case "$bound" in
    ''|*[!0-9]*|0*) bound=20 ;;
  esac
  # `env` carries the directory as one literal argv word, so no shell re-parses
  # it, and </dev/null keeps the caller's stdin away from the vendor CLI.
  status=$(fm_claude_account_profile_run_timed "$bound" \
    env CLAUDE_CONFIG_DIR="$dir" claude auth status --json 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    fm_claude_account_profile_fail "account profile '$profile' native claude auth status exceeded its ${bound}s bound or could not be bounded"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    fm_claude_account_profile_fail "account profile '$profile' is not authenticated with the native Claude account flow"
    return 1
  fi
  printf '%s\n' "$status" | jq -e '
    type == "object" and
    .loggedIn == true and
    .authMethod == "claude.ai" and
    .apiProvider == "firstParty"
  ' >/dev/null 2>&1 || {
    fm_claude_account_profile_fail "account profile '$profile' is not authenticated with the native paid Claude account flow"
    return 1
  }
}
