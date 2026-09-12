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
# A Pi root can hold several ChatGPT logins at once, one per provider id, so
# the Pi pin selects the root and the model's provider selects the account
# inside it. config/pi-account-side is what keeps work and personal apart:
# fm_account_pin_side_guard refuses any Pi launch whose provider does not match
# the side the home declares, and refuses a launch whose provider it cannot
# read off the model at all, because the root's defaultProvider is a personal
# account on the shared root and must never decide a work launch.
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
# cannot answer for an empty root. Claude: `quota-axi auth --json --provider
# claude`; a source that is available, expired (renewed on next use), or
# skipped with a credential present passes. Pi: `pi auth check --provider
# <the launch model's provider> --json --no-refresh`, and only status "ready"
# passes. That command loads no extensions, so an extension-registered provider
# comes back not_ready/provider_not_found; only that one answer falls through to
# `pi --list-models <provider>`, which does load them, and the launch passes
# only when a listed row's provider and model columns both match exactly. Every
# other answer, including a logged-out built-in provider's
# not_ready/credentials_not_configured and no answer within the bound, refuses.
# --no-refresh keeps the check from rewriting a root's tokens while other
# workers use them. A codex-native/<id> model is not checked: that provider
# comes from the pi-codex-native extension and signs in through Codex's own
# login, which has no pin.

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

# fm_account_pin_read_path <file>
# Prints the one absolute path <file> holds. Parses bytes before the shell can
# drop NULs or trailing newlines; paths are literal, not shell expressions, so
# spaces and quotes are valid. Returns 0 on success, 3 when the file does not
# exist, 4 when it cannot be inspected (one error already printed), 5 when it is
# not a readable regular file, and 6 when its contents are not one absolute path
# followed by exactly one newline. Callers own the message for each refusal,
# because the file they name differs.
fm_account_pin_read_path() {
  perl -MErrno=ENOENT -e '
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
  ' -- "$1"
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
  root=$(fm_account_pin_read_path "$cfg")
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

# The provider id reserved for the work ChatGPT account inside a shared Pi root
# (the pi-codex-accounts extension registers it from codex-accounts.json). It is
# a fixed id rather than a per-home setting so a home that declares nothing can
# still be told which provider it must not use.
FM_ACCOUNT_PIN_WORK_PROVIDER=openai-codex-work

# Thinking levels pi accepts as a trailing ":<level>" on a --model pattern; a
# model id may legitimately end in ":fast" or ":slow", which are not levels.
FM_ACCOUNT_PIN_PI_THINKING="off minimal low medium high xhigh max"

# fm_account_pin_pi_provider <model>
# Prints the provider a Pi --model names. Returns 1, silently, for anything
# that does not name one, so no caller can fall back to a root-wide default.
fm_account_pin_pi_provider() {
  local model=$1
  case "$model" in
    */*)
      [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
      printf '%s\n' "${model%%/*}"
      ;;
    *) return 1 ;;
  esac
}

# fm_account_pin_pi_model_listed <root> <executable> <provider> <model> <clean-env...>
# Returns 0 when `pi --list-models` prints a row whose provider and model
# columns are exactly this provider and this model's id. Fuzzy search means the
# listing also carries near matches, so the columns are compared exactly and the
# header row is skipped; a timeout, an unreadable root, or no matching row all
# return 1.
fm_account_pin_pi_model_listed() {
  local root=$1 executable=$2 provider=$3 model=$4 want alt level out
  shift 4
  want=${model#*/}
  alt=
  for level in $FM_ACCOUNT_PIN_PI_THINKING; do
    [ "$want" != "${want%:"$level"}" ] || continue
    alt=${want%:"$level"}
    break
  done
  out=$(fm_run_timed "$FM_ACCOUNT_PIN_PREFLIGHT_SECONDS" "$@" "PI_CODING_AGENT_DIR=$root" \
    "$executable" --list-models "$provider" 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$out" | awk -v p="$provider" -v a="$want" -v b="$alt" '
    NR > 1 && $1 == p && ($2 == a || (b != "" && $2 == b)) { found = 1; exit }
    END { exit !found }'
}

# fm_account_pin_side <config-dir>
# Prints the side config/pi-account-side declares for this home: "personal"
# when the file is absent, otherwise its exact "work" or "personal" contents.
# Anything else prints one error and returns 1, so an unreadable or misspelled
# declaration refuses the launch instead of defaulting to either account.
fm_account_pin_side() {
  local cfg="$1/pi-account-side" side
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    printf 'personal\n'
    return 0
  fi
  side=$(cat -- "$cfg" 2>/dev/null) || {
    echo "error: config/pi-account-side must be a readable regular file: $cfg" >&2
    return 1
  }
  case "$side" in
    work|personal) printf '%s\n' "$side" ;;
    *)
      echo "error: config/pi-account-side must contain exactly 'work' or 'personal' followed by one newline: $cfg" >&2
      return 1
      ;;
  esac
}

# fm_account_pin_side_guard <harness> <config-dir> <model>
# The work/personal separation a single shared Pi root can no longer give by
# construction. Returns 0 only when the launch model's provider matches the side
# this home declares; otherwise prints one error naming the harness, the model,
# the provider, the side, and the file that declares it, and returns 1.
# Non-Pi harnesses pass through: no other runner shares one root between
# accounts.
fm_account_pin_side_guard() {
  local harness=$1 config=$2 model=$3 cfg side provider
  case "$harness" in pi|pi-signed) ;; *) return 0 ;; esac
  cfg="$config/pi-account-side"
  side=$(fm_account_pin_side "$config") || return 1
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then
    cfg="$cfg (declares $side)"
  else
    cfg="$cfg (absent, so this home is personal)"
  fi
  provider=$(fm_account_pin_pi_provider "$model") || {
    echo "error: $harness launch refused for side $side: --model '${model:-none}' names no provider, so the account it would spend cannot be proved; pass --model as <provider>/<id>, because the shared Pi root's defaultProvider is a personal account and never decides this. Declared by $cfg" >&2
    return 1
  }
  case "$side" in
    work)
      [ "$provider" = "$FM_ACCOUNT_PIN_WORK_PROVIDER" ] && return 0
      echo "error: $harness launch refused: this home is work-side, so it may launch only on provider $FM_ACCOUNT_PIN_WORK_PROVIDER, but --model '$model' resolves to provider '$provider'. Declared by $cfg" >&2
      ;;
    personal)
      [ "$provider" != "$FM_ACCOUNT_PIN_WORK_PROVIDER" ] && return 0
      echo "error: $harness launch refused: this home is personal-side, so it may never launch on the work provider $FM_ACCOUNT_PIN_WORK_PROVIDER, but --model '$model' resolves to it. Declared by $cfg" >&2
      ;;
  esac
  return 1
}

# fm_account_pin_preflight <harness> <root> <executable> [<model>]
# Returns 0 only when the runner's own check says the root can authenticate
# the launch; otherwise prints one error and returns 1.
fm_account_pin_preflight() {
  local harness=$1 root=$2 executable=$3 model=${4:-} out verdict provider
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=$PATH")
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
      provider=$(fm_account_pin_pi_provider "$model") || {
        echo "error: a $harness launch needs --model as <provider>/<id>: '${model:-none}' names no provider, and the account inside a shared Pi root is chosen by the provider, never by the root's defaultProvider" >&2
        return 1
      }
      [ "$provider" != codex-native ] || return 0
      out=$(fm_run_timed "$FM_ACCOUNT_PIN_PREFLIGHT_SECONDS" "${clean[@]}" "PI_CODING_AGENT_DIR=$root" \
        "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
      verdict=$(printf '%s\n' "$out" | jq -r '
        if .status == "ready" then "ready"
        elif .status == "not_ready" and .reason == "provider_not_found" then "unloaded"
        else "\(.status // "unknown") \(.provider // "") \(.reason // "")"
        end' 2>/dev/null)
      [ "$verdict" != ready ] || return 0
      if [ "$verdict" = unloaded ]; then
        # pi auth check loads no extensions, so a provider an extension
        # registers is indistinguishable to it from a typo. pi --list-models
        # does load them, and it prints an extension provider's rows only when
        # that provider can actually serve them.
        fm_account_pin_pi_model_listed "$root" "$executable" "$provider" "$model" "${clean[@]}" && return 0
        echo "error: the Pi account pin $root offers no model '$model' (pi auth check does not know provider '$provider', and pi --list-models does not list that provider and model under this root); log in under it with PI_CODING_AGENT_DIR=$root $harness, then /login, or pass a --model this root serves" >&2
        return 1
      fi
      echo "error: the Pi account pin $root cannot authenticate --provider $provider (pi auth check: ${verdict:-no answer}); log in under it with PI_CODING_AGENT_DIR=$root $harness, then /login, or pass --model as <provider>/<id>" >&2
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
