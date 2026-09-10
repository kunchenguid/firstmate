#!/usr/bin/env bash
# fm-account-pin-lib.sh - the single owner of account-pin mechanics: which
# runners require a pin, how a home's pin is resolved and validated, the
# spawn-time authentication preflight under that pin, and the environment
# credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Account pins" owns the operator-facing contract and
# the reasons the other runners carry no pin. Sourced by bin/fm-spawn.sh,
# bin/fm-quota-snapshot.sh, and bin/fm-quota-choose.sh.
#
# Pinned runners, each a credential file inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-config-dir
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-agent-dir
#
# Resolution: both pins are home-local, never inherited, and name the accounts
# the home's workers use, so a worker or scout launch reads only the home's
# file: inside a secondmate the ambient CLAUDE_CONFIG_DIR is the supervisor's
# account. A secondmate is a supervisor and is resolved against the launching
# home instead, where a non-empty ambient CLAUDE_CONFIG_DIR still wins for
# Claude. The root must be an absolute, existing, readable, searchable
# directory. A missing pin refuses; nothing falls back to ~/.claude or
# ~/.pi/agent.
#
# Preflight: the runner's own non-interactive check, run with only HOME, PATH,
# TMPDIR, and the pin in its environment, so a provider key left in the caller
# cannot answer for an empty root. Pi: `pi auth check --json --no-refresh`, for
# the launch model or, without one, the root's settings.json defaultProvider;
# only status "ready" passes. Claude: `quota-axi auth --json --provider claude`;
# a source that is available, expired (renewed on next use), or skipped with a
# credential present passes. --no-refresh keeps the check from rewriting a
# root's tokens while other workers use them. Anything else, including no
# answer within the bound, refuses. A codex-native/<id> model is not checked:
# that provider comes from the pi-codex-native extension, which `pi auth check`
# does not load, and it signs in through Codex's own login, which has no pin.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_ACCOUNT_PIN_PREFLIGHT_SECONDS=30

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence").
FM_ACCOUNT_PIN_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_account_pin_var <harness>
# Prints the pin's environment variable; returns 1 for a runner with no pin.
fm_account_pin_var() {
  case "$1" in
    claude) printf 'CLAUDE_CONFIG_DIR\n' ;;
    pi|pi-signed) printf 'PI_CODING_AGENT_DIR\n' ;;
    *) return 1 ;;
  esac
}

# fm_account_pin_resolve <harness> <config-dir> <home> [<kind>]
# Prints the validated root. On refusal prints one error naming the runner,
# the home, and the file, and returns 1. For kind "secondmate" a non-empty
# ambient CLAUDE_CONFIG_DIR wins over the file; any other launch reads only
# the file.
fm_account_pin_resolve() {
  local harness=$1 config=$2 home=$3 kind=${4:-} runner file fallback cfg root rc
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
    claude) runner=Claude file=claude-config-dir fallback='~/.claude' ;;
    pi|pi-signed) runner=Pi file=pi-agent-dir fallback='~/.pi/agent' ;;
    *) return 1 ;;
  esac
  cfg="$config/$file"
  if [ "$runner" = Claude ] && [ "$kind" = secondmate ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    root=$CLAUDE_CONFIG_DIR
    case "$root" in
      /*) ;;
      *) echo "error: CLAUDE_CONFIG_DIR must be an absolute path to this home's Claude account root: $root" >&2; return 1 ;;
    esac
    if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
      echo "error: CLAUDE_CONFIG_DIR must name a readable, searchable existing directory: $root" >&2
      return 1
    fi
    printf '%s\n' "$root"
    return 0
  fi
  # Parse bytes before the shell can drop NULs or trailing newlines. Paths are
  # literal, not shell expressions; spaces and quotes are valid.
  root=$(perl -MErrno=ENOENT -e '
    my $f = $ARGV[0];
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    $body =~ /\A(\/[^\x00-\x1f\x7f]*)\n\z/ or exit 6;
    print $1;
  ' -- "$cfg")
  rc=$?
  case "$rc" in
    0) ;;
    3)
      echo "error: $runner launches from home $home require an account pin: create $cfg containing one absolute path to this home's $runner account root followed by a newline; Firstmate does not fall back to $fallback" >&2
      return 1
      ;;
    4) return 1 ;;
    5) echo "error: config/$file must be a readable regular file: $cfg" >&2; return 1 ;;
    *) echo "error: config/$file must contain one absolute path followed by one newline: $cfg" >&2; return 1 ;;
  esac
  if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
    echo "error: config/$file must name a readable, searchable existing directory: $cfg" >&2
    return 1
  fi
  printf '%s\n' "$root"
}

# fm_account_pin_preflight <harness> <root> <executable> [<model>]
# Returns 0 only when the runner's own check says the root can authenticate
# the launch; otherwise prints one error and returns 1.
fm_account_pin_preflight() {
  local harness=$1 root=$2 executable=$3 model=${4:-} out verdict provider
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=$PATH") check=()
  [ -z "${TMPDIR:-}" ] || clean+=("TMPDIR=$TMPDIR")
  case "$harness" in
    claude)
      out=$(fm_run_timed "$FM_ACCOUNT_PIN_PREFLIGHT_SECONDS" "${clean[@]}" "CLAUDE_CONFIG_DIR=$root" \
        quota-axi auth --json --provider claude 2>/dev/null </dev/null)
      verdict=$(printf '%s\n' "$out" | jq -r '
        [.auth[]? | select(.provider == "claude") | .sources[]?] as $s |
        if any($s[]; .status == "available" or .status == "expired" or
               (.status == "skipped" and .credentialPresent == true))
        then "ready"
        else ($s | map("\(.source)=\(.status)") | join(", "))
        end' 2>/dev/null)
      [ "$verdict" != ready ] || return 0
      echo "error: the Claude account pin $root holds no usable login (quota-axi auth: ${verdict:-no answer}); log in under it with CLAUDE_CONFIG_DIR=$root claude, then /login, or pin another root" >&2
      return 1
      ;;
    pi|pi-signed)
      case "$model" in codex-native/*) return 0 ;; esac
      if [ -n "$model" ]; then
        check=(--model "$model")
      else
        provider=$(jq -r '.defaultProvider // empty' "$root/settings.json" 2>/dev/null)
        if [ -z "$provider" ]; then
          echo "error: cannot confirm the Pi account pin $root: pass --model <provider>/<id>, or set defaultProvider in $root/settings.json" >&2
          return 1
        fi
        check=(--provider "$provider")
      fi
      out=$(fm_run_timed "$FM_ACCOUNT_PIN_PREFLIGHT_SECONDS" "${clean[@]}" "PI_CODING_AGENT_DIR=$root" \
        "$executable" auth check "${check[@]}" --json --no-refresh 2>/dev/null </dev/null)
      verdict=$(printf '%s\n' "$out" | jq -r '
        if .status == "ready" then "ready"
        else "\(.status // "unknown") \(.provider // "") \(.reason // "")"
        end' 2>/dev/null)
      [ "$verdict" != ready ] || return 0
      echo "error: the Pi account pin $root cannot authenticate ${check[*]} (pi auth check: ${verdict:-no answer}); log in under it with PI_CODING_AGENT_DIR=$root $harness, then /login, or pass --model as <provider>/<id>" >&2
      return 1
      ;;
    *) return 0 ;;
  esac
}

# fm_account_pin_shed_prefix <harness>
# Prints an `env -u ...` launch prefix removing the environment credentials
# that would outrank the pin, or nothing for a runner without one.
fm_account_pin_shed_prefix() {
  local var prefix=env
  [ "$1" = claude ] || return 0
  for var in $FM_ACCOUNT_PIN_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
