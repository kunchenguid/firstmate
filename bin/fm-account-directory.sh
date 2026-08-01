#!/usr/bin/env bash
# Select and prepare direct Claude or Codex account-directory launches.
# Usage:
#   fm-account-directory.sh select <claude|codex>
#   fm-account-directory.sh install-herdr-hook <claude|codex> <account-home>
#   fm-account-directory.sh prepare <claude|codex>
#
# This header is the single owner of the direct account-directory contract.
# FM_ACCOUNT_DIRECTORY_CUTOVER: direct-pool-rotation-v3
# Account homes are discovered under the current passwd user's
# .local/share/agent-fleet/accounts/<vendor>/ tree without fixed counts.
# Agent Fleet's read-only profile list is the source of pool eligibility:
# direct crewmate selection considers only enabled worker profiles with real homes
# registered in the fixed <vendor>-crew pool, so a disabled, manual-only, or
# non-worker profile is never a crewmate candidate and no caller-supplied
# compatibility alias can weaken that boundary.
# Claude may also declare a separate claude-crew-last-resort pool.
# It is consulted only when no usable claude-crew profile remains; Firstmate
# never guesses that membership from credentials or identity metadata.
# Claude eligibility also requires quota-axi's exact, non-secret per-directory
# Keychain access marker.
# That check happens after pool filtering and before rotation, so a reserved
# profile cannot become a fallback and an unapproved crewmate profile fails honestly.
# Codex selection removes that account's quota-axi window cache immediately
# before every read, sets CODEX_HOME plus the account-isolated XDG_CACHE_HOME,
# accepts only a fresh result with at least one numeric five_hour or weekly
# window, and finds the accounts with the highest minimum remaining percentage.
# Accounts without a freshly readable window do not participate in quota
# ranking while any readable account remains.
# If every eligible Codex account lacks a readable window, selection degrades
# explicitly to rotation across the whole eligible set instead of failing or
# choosing the stable first directory.
# Claude quota is not currently distinguishable per config directory because
# quota-axi cannot non-interactively resolve Claude's config-dir-specific macOS
# Keychain credential.
# Claude therefore never treats a missing usage window as account failure and
# rotates across every eligible account in stable bytewise order.
# Codex uses the same rotation only to break exact best-score ties.
# Rotation is machine-global, persisted under the passwd user's
# .local/state/firstmate/account-directory/, and serialized by an advisory file
# lock so concurrent selections spread deterministically instead of racing back
# to the first candidate.
# Selection prints only the chosen absolute account home on stdout and logs
# health, fallback, and choice diagnostics on stderr.
# prepare selects the account and idempotently runs Herdr's own integration
# installer with CODEX_HOME or CLAUDE_CONFIG_DIR set to the chosen home.
# It verifies the installed per-profile hook before printing the chosen home.
#
# Credential and profile-registry state is read-only.
# This script never logs in, imports credentials, or invokes a provider model.
# Test-only command, root, state-root, passwd-home, Perl, timeout, openat preprocessor,
# and marker-race hook overrides require FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1.
set -u

TEST_LAB_TOKEN=firstmate-account-directory-test-lab-v1

case "${BASH_SOURCE[0]}" in
  */*) FM_ACCOUNT_DIRECTORY_SOURCE_DIR=${BASH_SOURCE[0]%/*} ;;
  *) FM_ACCOUNT_DIRECTORY_SOURCE_DIR=. ;;
esac
FM_ACCOUNT_DIRECTORY_BIN_DIR="$(cd "$FM_ACCOUNT_DIRECTORY_SOURCE_DIR" && pwd)"
unset FM_ACCOUNT_DIRECTORY_SOURCE_DIR
# shellcheck source=bin/fm-account-routing-lib.sh
. "$FM_ACCOUNT_DIRECTORY_BIN_DIR/fm-account-routing-lib.sh"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2
}

log() {
  printf 'fm-account-directory: %s\n' "$*" >&2
}

test_lab_enabled() {
  [ "${FM_ACCOUNT_DIRECTORY_TEST_LAB:-}" = "$TEST_LAB_TOKEN" ]
}

system_perl() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_PERL_BIN:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_PERL_BIN"
  else
    printf '%s\n' /usr/bin/perl
  fi
}

passwd_home() {
  local home perl_bin
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_PASSWD_HOME:-}" ]; then
    home=$FM_ACCOUNT_DIRECTORY_PASSWD_HOME
  else
    perl_bin=$(system_perl) || return 1
    [ -x /usr/bin/env ] && [ -x "$perl_bin" ] || {
      echo "error: /usr/bin/env and /usr/bin/perl are required to resolve the current passwd home" >&2
      return 1
    }
    # shellcheck disable=SC2016 # Perl source is intentionally single-quoted.
    home=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$perl_bin" -e '
      my @p = getpwuid($<);
      exit 1 unless @p && defined $p[7] && $p[7] =~ m{^/};
      exit 1 if $p[7] =~ /[\x00-\x1f\x7f]/;
      print $p[7];
    ' 2>/dev/null) || {
      echo "error: cannot resolve the current passwd home" >&2
      return 1
    }
  fi
  case "$home" in
    *$'\n'*|*$'\r'*)
      echo "error: passwd home contains a line break" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "error: passwd home must be absolute: $home" >&2
      return 1
      ;;
  esac
  [ -d "$home" ] && [ ! -L "$home" ] || {
    echo "error: passwd home is not a real directory: $home" >&2
    return 1
  }
  printf '%s\n' "$home"
}

account_root() {
  local root home
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_ROOT:-}" ]; then
    root=$FM_ACCOUNT_DIRECTORY_ROOT
  else
    home=$(passwd_home) || return 1
    root=$home/.local/share/agent-fleet/accounts
  fi
  case "$root" in
    *$'\n'*|*$'\r'*)
      echo "error: account-directory root contains a line break" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "error: account-directory root must be absolute: $root" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$root"
}

quota_command() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_QUOTA_AXI:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_QUOTA_AXI"
    return 0
  fi
  command -v quota-axi 2>/dev/null || {
    echo "error: quota-axi is required for fresh Codex account selection" >&2
    return 1
  }
}

herdr_command() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_HERDR:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_HERDR"
    return 0
  fi
  command -v herdr 2>/dev/null || {
    echo "error: herdr is required to install the selected account's integration hook" >&2
    return 1
  }
}

agent_fleet_command() {
  local binary
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_AGENT_FLEET:-}" ]; then
    binary=$(
      FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1
      FM_AGENT_FLEET_BIN=''
      fm_account_fleet_bin "$FM_ACCOUNT_DIRECTORY_AGENT_FLEET"
    ) || return 1
  else
    binary=$(fm_account_fleet_bin) || {
      echo "error: agent-fleet is required to enforce direct crew-pool eligibility" >&2
      return 1
    }
  fi
  printf '%s\n' "$binary"
}

read_profile_registry() { # <agent-fleet-bin>
  local passwd_root
  if test_lab_enabled; then
    "$1" --format json profile list
  else
    passwd_root=$(passwd_home) || return 1
    /usr/bin/env -i \
      HOME="$passwd_root" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$1" --format json profile list
  fi
}

openat_syscall_number() {
  local cpp_bin output
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_OPENAT_CPP:-}" ]; then
    cpp_bin=$FM_ACCOUNT_DIRECTORY_OPENAT_CPP
  elif [ -x /usr/bin/cpp ] && [ -f /usr/bin/cpp ]; then
    cpp_bin=/usr/bin/cpp
  elif [ -x /bin/cpp ] && [ -f /bin/cpp ]; then
    cpp_bin=/bin/cpp
  else
    echo "error: descriptor-relative approval validation is unsupported: system openat binding unavailable" >&2
    return 1
  fi
  output=$(
    printf '#include <sys/syscall.h>\nSYS_openat\n' \
      | /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$cpp_bin" -P - 2>/dev/null
  ) || {
    echo "error: descriptor-relative approval validation is unsupported: system openat binding unavailable" >&2
    return 1
  }
  output=${output//$'\n'/}
  output=${output//[[:space:]]/}
  case "$output" in
    ''|*[!0-9]*)
      echo "error: descriptor-relative approval validation is unsupported: system openat binding unavailable" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$output"
}

rotation_state_root() {
  local root home
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_STATE_ROOT:-}" ]; then
    root=$FM_ACCOUNT_DIRECTORY_STATE_ROOT
  else
    home=$(passwd_home) || return 1
    root=$home/.local/state/firstmate/account-directory
  fi
  case "$root" in
    *$'\n'*|*$'\r'*)
      echo "error: account rotation state root contains a line break" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "error: account rotation state root must be absolute: $root" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$root"
}

quota_timeout_seconds() {
  local timeout=15
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_QUOTA_TIMEOUT_SECONDS:-}" ]; then
    timeout=$FM_ACCOUNT_DIRECTORY_QUOTA_TIMEOUT_SECONDS
  fi
  case "$timeout" in
    ''|*[!0-9]*|0)
      echo "error: Codex quota timeout must be a positive integer" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$timeout"
}

run_bounded() {
  local timeout=$1 perl_bin
  shift
  perl_bin=$(system_perl) || return 1
  [ -x "$perl_bin" ] || return 127
  # shellcheck disable=SC2016 # Perl source is intentionally single-quoted.
  PERL5LIB='' PERL5OPT='' "$perl_bin" -e '
    use POSIX qw(setpgid WNOHANG);
    my ($timeout, @command) = @ARGV;
    my $pid = fork();
    exit 125 unless defined $pid;
    if ($pid == 0) {
      setpgid(0, 0);
      exec {$command[0]} @command;
      exit 127;
    }
    setpgid($pid, $pid);
    my $deadline = time() + $timeout;
    while (1) {
      my $waited = waitpid($pid, WNOHANG);
      if ($waited == $pid) {
        my $status = $?;
        exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
      }
      exit 125 if $waited == -1;
      if (time() >= $deadline) {
        kill "TERM", -$pid;
        for (1 .. 4) {
          select undef, undef, undef, 0.05;
          exit 124 if waitpid($pid, WNOHANG) == $pid;
        }
        kill "KILL", -$pid;
        waitpid($pid, 0);
        exit 124;
      }
      select undef, undef, undef, 0.05;
    }
  ' "$timeout" "$@"
}

valid_account_home() { # <vendor-dir> <candidate>
  local vendor_dir=$1 candidate=$2 name
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  case "$candidate" in
    "$vendor_dir"/*) ;;
    *) return 1 ;;
  esac
  name=${candidate##*/}
  case "$name" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

valid_pool_id() {
  case "$1" in
    ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

crew_pool() { # <vendor>
  local vendor=$1 pool=$1-crew
  valid_pool_id "$pool" || {
    echo "error: invalid direct account crew pool '$pool'" >&2
    return 1
  }
  printf '%s\n' "$pool"
}

last_resort_pool() { # <vendor>
  local vendor=$1 pool=$1-crew-last-resort
  valid_pool_id "$pool" || return 1
  printf '%s\n' "$pool"
}

eligible_account_homes() { # <vendor> <pool>
  local vendor=$1 pool=$2 root vendor_dir fleet_bin profiles candidate eligible matched reason marker marker_root marker_dir marker_race_hook openat_number
  root=$(account_root) || return 1
  vendor_dir=$root/$vendor
  [ -d "$vendor_dir" ] && [ ! -L "$vendor_dir" ] || {
    echo "error: no account-directory root for $vendor at $vendor_dir" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required for direct account pool eligibility" >&2
    return 1
  }
  if [ "$vendor" = claude ]; then
    openat_number=$(openat_syscall_number) || return 1
  fi
  fleet_bin=$(agent_fleet_command) || return 1
  profiles=$(read_profile_registry "$fleet_bin" 2>/dev/null) || {
    echo "error: agent-fleet could not read the account profile registry for $vendor crew selection" >&2
    return 1
  }
  printf '%s\n' "$profiles" | jq -e \
    'type == "object" and (.profiles | type) == "array"' >/dev/null 2>&1 || {
    echo "error: agent-fleet returned an invalid account profile registry" >&2
    return 1
  }
  eligible=$(printf '%s\n' "$profiles" | jq -r \
    --arg vendor "$vendor" --arg pool "$pool" '
      [.profiles[]
          | select(
              (.provider? == $vendor)
              and (.home? | type) == "string"
              and (.pools? | type) == "array"
              and (.pools | all(type == "string"))
              and ((.pools | index($pool)) != null)
              and (.enabled? == true)
              and (.safety_policy? == "worker")
            )
          | .home]
      | unique[]
    ' 2>/dev/null) || {
    echo "error: agent-fleet returned invalid profile fields for $vendor crew selection" >&2
    return 1
  }
  LC_ALL=C
  export LC_ALL
  for candidate in "$vendor_dir"/*; do
    valid_account_home "$vendor_dir" "$candidate" || continue
    matched=0
    while IFS= read -r registered; do
      [ "$candidate" = "$registered" ] || continue
      matched=1
      break
    done <<EOF
$eligible
EOF
    if [ "$matched" != 1 ]; then
      reason=$(printf '%s\n' "$profiles" | jq -r \
        --arg vendor "$vendor" --arg pool "$pool" --arg home "$candidate" '
          [.profiles[]
            | select(
                (.provider? == $vendor)
                and (.home? == $home)
                and (.pools? | type) == "array"
                and (.pools | all(type == "string"))
                and ((.pools | index($pool)) != null)
              )]
          | if length == 0 then
              "registry pool membership does not allow crew selection"
            elif any(.[]; .enabled? != true) then
              "profile is disabled"
            elif any(.[]; .safety_policy? != "worker") then
              "safety policy is not worker"
            else
              "registry eligibility does not allow crew selection"
            end
        ' 2>/dev/null) || reason="registry eligibility could not be verified"
      log "$vendor account $candidate excluded from $pool: $reason"
      continue
    fi
    if [ "$vendor" = claude ]; then
      marker_race_hook=
      if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_MARKER_RACE_HOOK:-}" ]; then
        marker_race_hook=$FM_ACCOUNT_DIRECTORY_MARKER_RACE_HOOK
      fi
      marker_root=$candidate/.agent-fleet-quota-cache
      marker_dir=$marker_root/quota-axi
      marker=$marker_dir/claude-keychain-access-granted
      if [ ! -d "$marker_root" ] || [ -L "$marker_root" ] \
        || [ ! -d "$marker_dir" ] || [ -L "$marker_dir" ] \
        || [ ! -f "$marker" ] || [ -L "$marker" ]; then
        log "claude account $candidate excluded from $pool: missing quota-axi's non-secret Keychain access marker; captain approval is required"
        continue
      fi
      # shellcheck disable=SC2016
      if ! PERL5LIB='' PERL5OPT='' "$(system_perl)" -e '
          use strict;
          use warnings;
          use Fcntl qw(:DEFAULT);

          my ($openat_number, $account_home, $path, $race_hook) = @ARGV;
          exit 1 unless $openat_number =~ /\A[0-9]+\z/;

          my $openat_handle = sub {
            my ($parent, $name, $flags) = @_;
            my $fd = syscall($openat_number, fileno($parent), $name, $flags, 0);
            exit 1 if $fd < 0;
            open(my $handle, "<&=$fd") or exit 1;
            return $handle;
          };

          sysopen(my $account, $account_home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            or exit 1;
          my $cache = $openat_handle->(
            $account, ".agent-fleet-quota-cache",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
          );
          my $quota = $openat_handle->(
            $cache, "quota-axi",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
          );
          my $marker = $openat_handle->(
            $quota, "claude-keychain-access-granted",
            O_RDONLY | O_NOFOLLOW,
          );

          my @handles = ($account, $cache, $quota);
          my @paths = (
            $account_home,
            "$account_home/.agent-fleet-quota-cache",
            "$account_home/.agent-fleet-quota-cache/quota-axi",
          );
          my @directory_stats;
          for my $handle (@handles) {
            my @opened = stat($handle);
            exit 1 unless @opened && -d _;
            exit 1 unless $opened[4] == $< && ($opened[2] & 0022) == 0;
            push @directory_stats, \@opened;
          }

          my @opened = stat($marker);
          exit 1 unless @opened && -f _;
          exit 1 unless ($opened[2] & 07777) == 0600;
          exit 1 unless $opened[4] == $< && $opened[3] == 1;
          binmode($marker);
          local $/;
          my $payload = <$marker>;
          exit 1 unless defined($payload) && $payload eq "granted\n";
          if (length($race_hook)) {
            system($race_hook) == 0 or exit 1;
          }

          for my $index (0 .. $#paths) {
            my @after = lstat($paths[$index]);
            exit 1 unless @after && -d _ && !-l _;
            my $expected = $directory_stats[$index];
            for my $field (0, 1, 2, 3, 4, 5, 7, 9, 10) {
              exit 1 unless $expected->[$field] == $after[$field];
            }
          }
          my @after = lstat($path);
          exit 1 unless @after && -f _ && !-l _;
          for my $index (0, 1, 2, 3, 4, 5, 7, 9, 10) {
            exit 1 unless $opened[$index] == $after[$index];
          }
          close($marker) or exit 1;
          close($quota) or exit 1;
          close($cache) or exit 1;
          close($account) or exit 1;
        ' "$openat_number" "$candidate" "$marker" "$marker_race_hook" 2>/dev/null; then
        log "claude account $candidate excluded from $pool: invalid quota-axi Keychain approval marker; expected exact granted payload, mode 0600, current-user ownership, one link, real path components, and stable metadata"
        continue
      fi
    fi
    printf '%s\n' "$candidate"
  done
}

rotate_account_home() { # <vendor> <pool> <candidate>...
  local vendor=$1 pool=$2 state_root perl_bin selected
  shift 2
  [ "$#" -gt 0 ] || {
    echo "error: no eligible account directories remain for $vendor crew pool '$pool'" >&2
    return 1
  }
  state_root=$(rotation_state_root) || return 1
  if [ -e "$state_root" ] || [ -L "$state_root" ]; then
    [ -d "$state_root" ] && [ ! -L "$state_root" ] || {
      echo "error: account rotation state root is not a real directory: $state_root" >&2
      return 1
    }
  else
    mkdir -p "$state_root" || {
      echo "error: cannot create account rotation state root: $state_root" >&2
      return 1
    }
  fi
  chmod 700 "$state_root" 2>/dev/null || {
    echo "error: cannot secure account rotation state root: $state_root" >&2
    return 1
  }
  perl_bin=$(system_perl) || return 1
  # shellcheck disable=SC2016 # Perl source is intentionally single-quoted.
  selected=$(PERL5LIB='' PERL5OPT='' "$perl_bin" -e '
    use strict;
    use warnings;
    use Fcntl qw(:DEFAULT :flock);

    my ($state_root, $vendor, $pool, @homes) = @ARGV;
    die "no candidates\n" unless @homes;
    my $stem = "$vendor-$pool";
    my $lock_path = "$state_root/$stem.lock";
    my $state_path = "$state_root/$stem.last";

    sysopen(my $lock, $lock_path, O_CREAT | O_RDWR, 0600)
      or die "cannot open rotation lock\n";
    chmod 0600, $lock_path;
    local $SIG{ALRM} = sub { die "rotation lock timed out\n" };
    alarm 10;
    flock($lock, LOCK_EX) or die "cannot lock rotation state\n";
    alarm 0;

    my $last = "";
    if (open(my $state, "<", $state_path)) {
      $last = <$state> // "";
      close $state;
      chomp $last;
    }
    my $index = 0;
    for my $i (0 .. $#homes) {
      if ($homes[$i] eq $last) {
        $index = ($i + 1) % scalar(@homes);
        last;
      }
    }
    my $selected = $homes[$index];
    my $tmp = "$state_path.$$";
    unlink $tmp if -e $tmp;
    sysopen(my $out, $tmp, O_CREAT | O_EXCL | O_WRONLY, 0600)
      or die "cannot create rotation state\n";
    print {$out} "$selected\n" or die "cannot write rotation state\n";
    close $out or die "cannot close rotation state\n";
    rename $tmp, $state_path or die "cannot publish rotation state\n";
    chmod 0600, $state_path;
    print "$selected\n";
  ' "$state_root" "$vendor" "$pool" "$@" 2>/dev/null) || {
    echo "error: deterministic account rotation failed for $vendor crew pool '$pool'" >&2
    return 1
  }
  printf '%s\n' "$selected"
}

fresh_codex_usage_json() { # <account-home> <quota-command>
  local account_home=$1 quota_bin=$2 cache_home cache_file environment_name timeout status
  timeout=$(quota_timeout_seconds) || return 1
  cache_home=$account_home/.agent-fleet-quota-cache
  cache_file=$cache_home/quota-axi/quotas.json
  if { [ -e "$cache_home" ] || [ -L "$cache_home" ]; } \
    && { [ ! -d "$cache_home" ] || [ -L "$cache_home" ]; }; then
    log "codex account $account_home skipped: its quota cache root is not a real directory"
    return 1
  fi
  if { [ -e "$cache_home/quota-axi" ] || [ -L "$cache_home/quota-axi" ]; } \
    && { [ ! -d "$cache_home/quota-axi" ] || [ -L "$cache_home/quota-axi" ]; }; then
    log "codex account $account_home skipped: its quota-axi cache directory is not a real directory"
    return 1
  fi
  if [ -e "$cache_file" ] || [ -L "$cache_file" ]; then
    rm -f "$cache_file" || {
      log "codex account $account_home skipped: could not clear its quota cache for a fresh health read"
      return 1
    }
  fi
  (
    while IFS='=' read -r environment_name _; do
      case "$environment_name" in
        XDG_*|QUOTA_AXI_*|AGENT_FLEET_*) unset "$environment_name" ;;
      esac
    done < <(/usr/bin/env)
    CODEX_HOME=$account_home
    XDG_CACHE_HOME=$cache_home
    export CODEX_HOME XDG_CACHE_HOME
    if run_bounded "$timeout" "$quota_bin" --provider codex --json 2>/dev/null; then
      return 0
    else
      status=$?
    fi
    if [ "$status" -eq 124 ]; then
      log "codex account $account_home skipped: quota read timed out after ${timeout}s"
    fi
    return "$status"
  )
}

codex_score() { # <quota-json>
  jq -er '
    [.providers[]?
      | select(.provider == "codex" and .state.status == "fresh")
      | (.windows // [])[]?
      | select((.id == "five_hour" or .id == "weekly")
          and (.kind // "") != "model"
          and (.percentRemaining | type) == "number")
      | .percentRemaining]
    | if length == 0 then empty else min end
  ' 2>/dev/null <<EOF
$1
EOF
}

select_codex() {
  local pool quota_bin candidate usage score selected eligible
  local best_score=''
  local -a best_homes=()
  local -a candidates=()
  pool=$(crew_pool codex) || return 1
  eligible=$(eligible_account_homes codex "$pool") || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidates+=("$candidate")
  done <<EOF
$eligible
EOF
  [ "${#candidates[@]}" -gt 0 ] || {
    echo "error: no eligible account directories remain for codex crew pool '$pool'" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required for Codex account usage selection" >&2
    return 1
  }
  quota_bin=$(quota_command) || return 1
  LC_ALL=C
  export LC_ALL
  for candidate in "${candidates[@]}"; do
    usage=$(fresh_codex_usage_json "$candidate" "$quota_bin") || usage=
    score=$(codex_score "$usage") || score=
    if [ -z "$score" ]; then
      log "codex account $candidate skipped: no freshly readable usage window"
      continue
    fi
    log "codex account $candidate fresh remaining score=$score"
    if [ "${#best_homes[@]}" -eq 0 ] || awk -v candidate_score="$score" -v current_score="$best_score" \
      'BEGIN { exit !(candidate_score > current_score) }'; then
      best_homes=("$candidate")
      best_score=$score
    elif awk -v candidate_score="$score" -v current_score="$best_score" \
      'BEGIN { exit !(candidate_score == current_score) }'; then
      best_homes+=("$candidate")
    fi
  done
  if [ "${#best_homes[@]}" -eq 0 ]; then
    selected=$(rotate_account_home codex "$pool" "${candidates[@]}") || return 1
    log "CODEX USAGE UNAVAILABLE: no eligible account has a freshly readable usage window; round-robin selection across ${#candidates[@]} eligible $pool accounts chose $selected"
    printf '%s\n' "$selected"
    return 0
  fi
  selected=$(rotate_account_home codex "$pool" "${best_homes[@]}") || return 1
  log "selected codex account $selected with fresh remaining score=$best_score; round-robin among ${#best_homes[@]} tied accounts"
  printf '%s\n' "$selected"
}

select_claude() {
  local pool fallback_pool selected eligible candidate
  local -a candidates=()
  pool=$(crew_pool claude) || return 1
  eligible=$(eligible_account_homes claude "$pool") || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidates+=("$candidate")
  done <<EOF
$eligible
EOF
  if [ "${#candidates[@]}" -eq 0 ]; then
    fallback_pool=$(last_resort_pool claude) || return 1
    eligible=$(eligible_account_homes claude "$fallback_pool") || return 1
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      candidates+=("$candidate")
    done <<EOF
$eligible
EOF
    if [ "${#candidates[@]}" -gt 0 ]; then
      pool=$fallback_pool
      log "CLAUDE LAST RESORT: no usable claude-crew account remains; using the explicitly declared $fallback_pool tier"
    fi
  fi
  [ "${#candidates[@]}" -gt 0 ] || {
    echo "error: no usable Claude account directories remain in claude-crew or claude-crew-last-resort; every profile is reserved outside those pools or still needs captain Keychain approval" >&2
    return 1
  }
  selected=$(rotate_account_home claude "$pool" "${candidates[@]}") || return 1
  log "CLAUDE USAGE UNREADABLE: quota-axi cannot non-interactively resolve Claude's config-dir-specific macOS Keychain credential today; round-robin selection across ${#candidates[@]} eligible $pool accounts chose $selected"
  printf '%s\n' "$selected"
}

select_account() { # <vendor>
  case "$1" in
    codex) select_codex ;;
    claude) select_claude ;;
    *)
      echo "error: direct account-directory selection supports only claude or codex, not '$1'" >&2
      return 1
      ;;
  esac
}

install_herdr_hook() { # <vendor> <account-home>
  local vendor=$1 account_home=$2 root vendor_dir herdr_bin expected_hook
  root=$(account_root) || return 1
  vendor_dir=$root/$vendor
  valid_account_home "$vendor_dir" "$account_home" || {
    echo "error: unsafe $vendor account home for Herdr hook installation: $account_home" >&2
    return 1
  }
  herdr_bin=$(herdr_command) || return 1
  case "$vendor" in
    codex)
      CODEX_HOME=$account_home "$herdr_bin" integration install codex >/dev/null || {
        echo "error: Herdr Codex integration install failed for $account_home" >&2
        return 1
      }
      expected_hook=$account_home/herdr-agent-state.sh
      ;;
    claude)
      CLAUDE_CONFIG_DIR=$account_home "$herdr_bin" integration install claude >/dev/null || {
        echo "error: Herdr Claude integration install failed for $account_home" >&2
        return 1
      }
      expected_hook=$account_home/hooks/herdr-agent-state.sh
      ;;
    *)
      echo "error: Herdr account hook installation supports only claude or codex, not '$vendor'" >&2
      return 1
      ;;
  esac
  [ -f "$expected_hook" ] && [ ! -L "$expected_hook" ] || {
    echo "error: Herdr installer did not create the expected $vendor hook at $expected_hook" >&2
    return 1
  }
  log "Herdr $vendor hook ready at $expected_hook"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  select)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    select_account "$2"
    ;;
  install-herdr-hook)
    [ "$#" -eq 3 ] || { usage; exit 2; }
    install_herdr_hook "$2" "$3"
    ;;
  prepare)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    selected_home=$(select_account "$2") || exit 1
    install_herdr_hook "$2" "$selected_home" || exit 1
    printf '%s\n' "$selected_home"
    ;;
  *)
    usage
    exit 2
    ;;
esac
