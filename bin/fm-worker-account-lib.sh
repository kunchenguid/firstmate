#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# and per-secondmate account pins: which runners can be pinned, how a pin file
# is parsed and resolved, the launch-time sign-in check under it, and the
# environment credentials a pinned Claude launch sheds.
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
#
# A home that spends several subscriptions of one runner declares them instead
# in a declared account list, each entry a root its vendor lets a process
# select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-accounts
#   codex           CODEX_HOME            config/codex-accounts
# One entry per line, each `ordinary` or an absolute path exactly as a pin
# would hold it, with no blank lines, duplicates, or control characters, and an
# optional final newline. `ordinary` unsets the variable, so the runner uses its
# default root (~/.claude or ~/.codex). The list is opt-in in the same way:
# absent, nothing here changes. Present, every ship or scout launch of that
# runner names one declared entry with --account; Firstmate chooses it at
# intake (bin/fm-<runner>-account-quota.sh measures each entry) and never
# defaults to the first entry, another entry, or the ambient account. The named
# entry passes the same root, raw-command, and sign-in refusals as a pin and is
# recorded as account=, which a ship or scout relaunch reuses unless an
# explicit --account moves it. config/claude-accounts replaces the home-wide
# Claude pin, which must then be absent, and a local Claude secondmate's agent
# never draws from it: it needs its own per-secondmate pin. Codex has no pin,
# so a Codex secondmate's agent launches exactly as it would without the list.
# Codex's sign-in check is `codex login status`, which exits 0 only when the
# selected CODEX_HOME holds a login and ignores environment credentials.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"
# Credentials Codex can spend instead of the login stored in CODEX_HOME: an API
# key (codex exec honors it) and an agent-identity access token. OPENAI_API_KEY
# is not one; Codex reads it only through `codex login --with-api-key`.
FM_WORKER_ACCOUNT_CODEX_SHED="CODEX_API_KEY CODEX_ACCESS_TOKEN"

# fm_worker_account_root_var <harness>
# Prints the variable a declared account list entry selects; returns 1 for a
# runner without a list.
fm_worker_account_root_var() {
  case "$1" in
  claude) printf '%s\n' CLAUDE_CONFIG_DIR ;;
  codex) printf '%s\n' CODEX_HOME ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_list_file <harness>
# Prints the declared account list file name for a runner that has one;
# returns 1 for any other.
fm_worker_account_list_file() {
  case "$1" in
  claude) printf '%s\n' claude-accounts ;;
  codex) printf '%s\n' codex-accounts ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_label <harness>
fm_worker_account_label() {
  case "$1" in
  claude) printf '%s\n' Claude ;;
  codex) printf '%s\n' Codex ;;
  *) printf '%s\n' "$1" ;;
  esac
}

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
# Prints "declared<TAB>providers" for a valid pin, where declared is
# `ordinary` or the absolute path and providers is empty for Claude. The final
# newline is optional; any other control byte, including a CR, is malformed.
# Parses bytes before the shell can drop NULs or trailing newlines; paths are
# literal, never shell expressions. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
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
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
      print $1, "\t";
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_config <harness> <config-dir> [<secondmate-id>]
# Prints the directory containing the applicable pin. Only a missing per-mate
# file falls back to the home pin; unreadable or malformed files still select
# the override so the ordinary parser refuses them. Non-pinnable runners and
# ordinary workers keep the supplied directory unchanged.
fm_worker_account_config() {
  local harness=$1 config=$2 mate=${3:-} file candidate rc
  if [ -z "$mate" ] || ! file=$(fm_worker_account_file "$harness"); then
    printf '%s\n' "$config"
    return 0
  fi
  candidate="$config/secondmate-accounts/$mate"
  fm_worker_account_read "$harness" "$candidate/$file" >/dev/null
  rc=$?
  case "$rc" in
  3) printf '%s\n' "$config" ;;
  4) return 1 ;;
  *) printf '%s\n' "$candidate" ;;
  esac
}

# fm_worker_account_resolve <harness> <config-dir> <setting>
# Prints "declared<TAB>root<TAB>providers" for a valid pin, where root is the
# directory the launch selects (empty for ordinary Claude, meaning
# CLAUDE_CONFIG_DIR unset). Prints nothing and returns 0 when the runner is
# not pinnable or the home has no pin. On refusal prints one error naming the
# file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 setting=$3 file cfg token rc declared root fallback
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: $setting must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: $setting must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: $setting must hold 'ordinary' or one absolute path on a single line with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  declared=${token%%$'\t'*}
  root=$declared
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  if [ "$declared" = ordinary ]; then
    case "$harness" in
    claude) root= ;;
    *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
    esac
  fi
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: $setting must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$declared" "$root" "${token#*$'\t'}"
}

# fm_worker_account_list <harness> <config-dir>
# Prints the entries the runner's declared account list holds, one per line.
# Prints nothing and returns 0 for a runner without a list or when the list is
# absent. On a malformed or unreadable list prints one error naming the file
# and returns 1.
fm_worker_account_list() {
  local harness=$1 file cfg out rc
  file=$(fm_worker_account_list_file "$harness") || return 0
  cfg="$2/$file"
  out=$(perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    $body =~ /\A(?:(?:ordinary|\/[^\x00-\x1f\x7f]*)\n)*(?:ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
    my %seen;
    for my $entry (split /\n/, $body) {
      exit 7 if $seen{$entry}++;
      print $entry, "\n";
    }
  ' -- "$cfg")
  rc=$?
  case "$rc" in
  0) printf '%s\n' "$out" ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  7)
    echo "error: config/$file declares the same account twice: $cfg" >&2
    return 1
    ;;
  *)
    echo "error: config/$file must hold one account per line, each 'ordinary' or an absolute path, with no blank lines or control characters: $cfg" >&2
    return 1
    ;;
  esac
}

# fm_worker_account_relaunch_request <harness> <config-dir> <prior-harness> <recorded-account> <explicit-account> [<secondmate-id>]
# Prints the declared account a relaunch asks fm_worker_account_select for:
# the explicit one when given, otherwise the task's recorded account when the
# home declares the runner's account list and a ship or scout stays on that
# runner. Prints nothing otherwise, so a relaunch without a list re-reads the
# pin exactly as before. Returns 1 when the explicit account holds a control
# character or the list cannot be read.
fm_worker_account_relaunch_request() {
  local harness=$1 config=$2 prior=$3 recorded=$4 explicit=$5 mate=${6:-} listed
  fm_worker_account_request_valid "$explicit" "$harness" || return 1
  if [ -n "$explicit" ] || [ -n "$mate" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  listed=$(fm_worker_account_list "$harness" "$config") || return 1
  [ -n "$listed" ] && [ "$prior" = "$harness" ] || return 0
  printf '%s\n' "$recorded"
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

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>] [<setting>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} setting=${6:-} out verdict name
  [ -n "$setting" ] || setting="config/$(fm_worker_account_file "$harness")"
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
      echo "error: $setting pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: $setting pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
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
    echo "error: $setting pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  codex)
    [ -z "$root" ] || clean+=("CODEX_HOME=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" login status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: $setting pins Codex workers to $root, which is not signed in (codex login status); sign in with CODEX_HOME=$root codex login, or change $setting" >&2
    else
      echo "error: $setting pins Codex workers to the ordinary account, which is not signed in (codex login status); sign in with env -u CODEX_HOME codex login, or change $setting" >&2
    fi
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_request_valid <account> [<harness>]
# Refuses an --account value holding a control character. Declared entries
# never hold one, and a newline would otherwise split the value before the
# whole-entry membership check or the account= record sees it.
fm_worker_account_request_valid() {
  local list
  case "$1" in
  *[[:cntrl:]]*)
    list=$(fm_worker_account_list_file "${2:-}") || list='claude-accounts or config/codex-accounts'
    echo "error: --account must name one config/$list entry exactly, with no control characters" >&2
    return 1
    ;;
  esac
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>] [<secondmate-id>] [<account>]
# The whole launch-time decision. Prints nothing for an unpinned runner, so
# the caller keeps today's launch unchanged. For a pinned one, or a ship or
# scout launching on a declared account list entry named by <account>, prints
# "declared<TAB>root<TAB>provider", where provider is the Pi launch model's
# own (empty for Claude and Codex), after the model guard and the sign-in
# check pass. On refusal prints one error and returns 1.
# bin/fm-spawn.sh runs it before any endpoint exists, and bin/fm-control.sh
# before a relaunch stops the live agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} mate=${6:-} account=${7:-}
  local selection declared root providers word provider='' selected_config setting listed count
  local list_file pin_file label root_var ordinary_root
  fm_worker_account_request_valid "$account" "$harness" || return 1
  list_file=$(fm_worker_account_list_file "$harness") || list_file=
  pin_file=$(fm_worker_account_file "$harness") || pin_file=
  label=$(fm_worker_account_label "$harness")
  if [ -n "$account" ] && [ -z "$list_file" ]; then
    echo "error: --account names one entry of config/claude-accounts or config/codex-accounts and applies to Claude and Codex workers only, not $harness" >&2
    return 1
  fi
  if [ -n "$account" ] && [ -n "$mate" ]; then
    if [ -n "$pin_file" ]; then
      echo "error: --account applies to ships and scouts; secondmate $mate launches on its own config/secondmate-accounts/$mate/$pin_file pin" >&2
    else
      echo "error: --account applies to ships and scouts; secondmate $mate launches as it would without config/$list_file" >&2
    fi
    return 1
  fi
  listed=$(fm_worker_account_list "$harness" "$config") || return 1
  if [ -z "$listed" ] && [ -n "$account" ]; then
    echo "error: --account '$account' needs config/$list_file, which this home does not declare" >&2
    return 1
  fi
  if [ -n "$listed" ] && [ -n "$pin_file" ] && { [ -e "$config/$pin_file" ] || [ -L "$config/$pin_file" ]; }; then
    echo "error: config/$list_file and config/$pin_file are both present; keep the account list or the single pin, not both" >&2
    return 1
  fi
  if [ -n "$listed" ] && [ -z "$mate" ]; then
    setting=config/$list_file
    if [ -z "$account" ]; then
      count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
      echo "error: $setting declares $count $label accounts, so a $label ship or scout launch must name one with --account; bin/fm-$harness-account-quota.sh measures each, and Firstmate never picks a default" >&2
      return 1
    fi
    declared=
    while IFS= read -r word; do
      [ "$word" != "$account" ] || { declared=$account; break; }
    done <<< "$listed"
    [ -n "$declared" ] || {
      echo "error: account '$account' is not declared in $setting; name a declared entry with --account" >&2
      return 1
    }
    root=$account
    [ "$declared" != ordinary ] || root=
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      root_var=$(fm_worker_account_root_var "$harness")
      # shellcheck disable=SC2088  # Literal text for the refusal.
      ordinary_root='~/.claude'
      # shellcheck disable=SC2088  # Literal text for the refusal.
      [ "$harness" != codex ] || ordinary_root='~/.codex'
      echo "error: $setting must name readable, searchable existing directories (ordinary means $ordinary_root with $root_var unset): $root" >&2
      return 1
    fi
    providers=
  elif [ -z "$pin_file" ]; then
    return 0
  else
    selected_config=$(fm_worker_account_config "$harness" "$config" "$mate") || return 1
    setting="config/$pin_file"
    [ "$selected_config" = "$config" ] || setting="$selected_config/$pin_file"
    if [ -n "$listed" ] && [ "$selected_config" = "$config" ]; then
      echo "error: config/$list_file chooses accounts for ships and scouts only; secondmate $mate needs its own pin in config/secondmate-accounts/$mate/$pin_file" >&2
      return 1
    fi
    selection=$(fm_worker_account_resolve "$harness" "$selected_config" "$setting") || return 1
    if [ -z "$selection" ]; then
      [ "$selected_config" = "$config" ] && return 0
      echo "error: secondmate account pin disappeared during selection: $setting" >&2
      return 1
    fi
    declared=${selection%%$'\t'*}
    root=${selection#*$'\t'}
    providers=${root#*$'\t'}
    root=${root%%$'\t'*}
  fi
  case "$harness" in
  claude | codex)
    root_var=$(fm_worker_account_root_var "$harness")
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " $root_var $(fm_worker_account_shed_vars "$harness") " in
        *" ${word%%=*} "*)
          echo "error: $setting pins $label workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove $setting" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
    ;;
  *)
    if [ -n "$raw" ]; then
      echo "error: $setting pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: $setting pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: $setting pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
    ;;
  esac
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" "$setting" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_shed_vars <harness>
# Prints the environment credentials a launch on a selected Claude or Codex
# root unsets, because the runner would spend them instead of that root's login.
fm_worker_account_shed_vars() {
  case "$1" in
  claude) printf '%s\n' "$FM_WORKER_ACCOUNT_CLAUDE_SHED" ;;
  codex) printf '%s\n' "$FM_WORKER_ACCOUNT_CODEX_SHED" ;;
  esac
}

# fm_worker_account_shed <harness>
# Prints the `env` launch prefix that unsets those credentials. The caller
# appends the root assignment, or -u <root variable> for the ordinary account.
fm_worker_account_shed() {
  local var prefix=env
  for var in $(fm_worker_account_shed_vars "$1"); do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
