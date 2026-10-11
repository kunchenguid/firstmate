#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# account pin: which runners can be pinned, how a pin file is parsed and
# resolved, the launch-time sign-in check under it, and the environment
# credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# config/claude-account may declare a pool: several lines, each `ordinary` or
# one absolute path, all distinct, with no blank or other lines. The first
# line is the home's default account; a launch selects another only by naming
# that exact line (fm-spawn.sh --account). A single line is today's pin,
# unchanged. Every declared root must be usable, so a broken pool refuses
# every Claude launch rather than being selected around. A relaunch keeps the
# account recorded on its task while the file still declares it, and refuses
# before the running agent stops when the file no longer does; an explicit
# --account is a deliberate switch, and a home whose file is gone launches
# unpinned as before. The Pi pin keeps one root and re-resolves on relaunch.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# For Claude prints every declared entry, one per line, in file order; for Pi
# prints "declared<TAB>providers". An entry is `ordinary` or an absolute path.
# The final newline is optional; any other control byte, including a CR, is
# malformed. Parses bytes before the shell can drop NULs or trailing newlines;
# paths are literal, never shell expressions. Returns 0 on success, 3 when the
# file does not exist, 4 when it cannot be inspected (one error already
# printed), 5 when it is not a readable regular file, 6 when a single-line
# file is malformed, and 7 when a several-line Claude pool is malformed (a
# blank, invalid, or repeated line).
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      (my $lines = $body) =~ s/\n\z//;
      if ($lines !~ /\n/) {
        $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
        print $1, "\n";
      } else {
        my %seen;
        my @entries = split /\n/, $lines, -1;
        for (@entries) {
          /\A(?:ordinary|\/[^\x00-\x1f\x7f]*)\z/ or exit 7;
          $seen{$_}++ and exit 7;
        }
        print "$_\n" for @entries;
      }
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_entries <harness> <config-dir>
# Prints one "declared<TAB>root<TAB>providers" line per declared account of a
# valid pin, in file order, where root is the directory a launch on it selects
# (empty for ordinary Claude, meaning CLAUDE_CONFIG_DIR unset) and providers
# is empty for Claude. Prints nothing and returns 0 when the runner is not
# pinnable or the home has no pin. On refusal prints one error naming the file
# and returns 1.
fm_worker_account_entries() {
  local harness=$1 config=$2 file cfg token rc declared root fallback providers=
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  7)
    echo "error: config/$file must hold one account per line - 'ordinary' or an absolute path - each distinct, with no blank lines or control characters; the first line is this home's default account: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: config/$file must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: config/$file must hold 'ordinary' or one absolute path on a single line with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *)
    fallback='~/.pi/agent'
    providers=${token#*$'\t'}
    token=${token%%$'\t'*}
    ;;
  esac
  while IFS= read -r declared; do
    root=$declared
    if [ "$declared" = ordinary ]; then
      case "$harness" in
      claude) root= ;;
      *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
      esac
    fi
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      echo "error: config/$file must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
      return 1
    fi
    printf '%s\t%s\t%s\n' "$declared" "$root" "$providers"
  done <<EOF_ENTRIES
$token
EOF_ENTRIES
}

# fm_worker_account_resolve <harness> <config-dir> [<entry>]
# Prints "declared<TAB>root<TAB>providers" for the account a launch selects:
# the declared line exactly equal to <entry>, or the first line when <entry>
# is empty. Prints nothing and returns 0 when the runner is not pinnable or
# the home has no pin and no <entry> was asked for. On refusal - a malformed
# pin, an <entry> for a runner other than Claude, an <entry> in a home with
# no config/claude-account, or an <entry> the file does not declare - prints
# one error and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 entry=${3:-} entries line declared list=
  if [ -n "$entry" ] && [ "$harness" != claude ]; then
    echo "error: --account selects a declared line of config/claude-account, so it applies only to Claude launches, not '${harness:-a raw launch command}'" >&2
    return 1
  fi
  entries=$(fm_worker_account_entries "$harness" "$config") || return 1
  if [ -z "$entries" ]; then
    [ -z "$entry" ] && return 0
    echo "error: --account '$entry' needs config/claude-account, which this home does not have; only the captain declares the accounts a home may launch Claude workers on: $config/claude-account" >&2
    return 1
  fi
  if [ -z "$entry" ]; then
    printf '%s\n' "${entries%%$'\n'*}"
    return 0
  fi
  while IFS= read -r line; do
    declared=${line%%$'\t'*}
    if [ "$declared" = "$entry" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    list="${list:+$list, }$declared"
  done <<EOF_ENTRIES
$entries
EOF_ENTRIES
  echo "error: --account '$entry' is not declared in config/claude-account (declared: $list); pass one declared line exactly: $config/claude-account" >&2
  return 1
}

# fm_worker_account_relaunch_entry <harness> <config-dir> <recorded-harness> <recorded-account> <explicit-entry> <task-id>
# Prints the Claude account a relaunch must name with --account, or nothing
# for the launch's ordinary selection. An explicit entry wins and is validated
# by the launch itself. Otherwise a Claude task recorded on a Claude account
# keeps it while config/claude-account still declares it; when the file no
# longer declares it, prints one error naming the recorded account and the fix
# and returns 1, so the caller refuses before the running agent stops. A home
# whose file is gone, another runner, or a task with no recorded Claude
# account prints nothing.
fm_worker_account_relaunch_entry() {
  local harness=$1 config=$2 recorded_harness=$3 recorded=$4 explicit=$5 id=$6 entries line list=
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  [ "$harness" = claude ] && [ "$recorded_harness" = claude ] && [ -n "$recorded" ] || return 0
  entries=$(fm_worker_account_entries claude "$config") || return 1
  [ -n "$entries" ] || return 0
  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" = "$recorded" ]; then
      printf '%s\n' "$recorded"
      return 0
    fi
    list="${list:+$list, }${line%%$'\t'*}"
  done <<EOF_ENTRIES
$entries
EOF_ENTRIES
  echo "error: task $id was launched on Claude account '$recorded', which config/claude-account no longer declares (declared: $list); restore that line in $config/claude-account, or relaunch with --account <entry> to move the task to a declared account deliberately" >&2
  return 1
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} out verdict name
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: config/claude-account pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: config/claude-account pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: config/pi-account pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>] [<entry>]
# The whole launch-time decision. <entry> names one declared Claude account
# (fm_worker_account_resolve); empty selects the first line. Prints nothing
# for an unpinned runner, so the caller keeps today's launch unchanged. For a
# pinned one prints "declared<TAB>root<TAB>provider", where provider is the Pi
# launch model's own (empty for Claude), after the model guard and the sign-in
# check pass. On refusal prints one error and returns 1. bin/fm-spawn.sh runs it before any
# endpoint exists, and bin/fm-control.sh before a relaunch stops the live
# agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} entry=${6:-} selection declared root providers word provider=
  selection=$(fm_worker_account_resolve "$harness" "$config" "$entry") || return 1
  [ -n "$selection" ] || return 0
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  root=${root%%$'\t'*}
  if [ "$harness" = claude ]; then
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
        *" ${word%%=*} "*)
          echo "error: config/claude-account pins Claude workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove config/claude-account" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
  else
    if [ -n "$raw" ]; then
      echo "error: config/pi-account pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: config/pi-account pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: config/pi-account pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
