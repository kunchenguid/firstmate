#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of managed-launch account
# selection: which runners require an explicit home declaration, how that
# declaration is resolved and validated, the spawn-time authentication
# preflight under it, and the environment credentials a selected Claude
# launch sheds.
#
# docs/configuration.md "Worker accounts" owns the operator-facing contract
# and the reasons the other runners carry no declaration. Sourced by
# bin/fm-spawn.sh and bin/fm-control.sh.
#
# Required runners, each a credential file inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# A missing declaration refuses; nothing treats an ambient or vendor-default
# login as consent. `ordinary` is the explicit selection of the vendor default:
# for Claude that is CLAUDE_CONFIG_DIR unset, because Claude keys its macOS
# Keychain entry to any CLAUDE_CONFIG_DIR that is set, even $HOME/.claude; for
# Pi it is $HOME/.pi/agent. Any other value is one absolute path to an existing
# readable, searchable directory. Firstmate never copies credentials or changes
# a global login.
#
# A Pi root can hold several provider identities at once, so selecting the
# root alone is insufficient. config/pi-account names the root on line 1 and
# the providers that home may spend on line 2, separated by spaces. The launch
# model's provider must be one of them; an unqualified model, or a provider
# the file does not name, refuses before any endpoint exists. That is the
# work/personal boundary: a home declares the providers it spends, so an
# extra identity sitting in a shared root cannot be used by accident. The
# prefix alone does not bind Pi: without --provider, Pi falls back to an
# identical model id under another, authenticated provider. So every
# canonical Pi launch also passes --provider <the model's provider>, and a raw
# Pi command, which Firstmate launches verbatim, must pass that same
# --provider itself.
#
# Environment credentials (Claude's API key, auth token, setup-token, cloud
# provider switches, profiles; a Pi provider's API key variable) are ambient
# unless the declaration ends with one more line, `environment`. Without it, a
# Claude launch sheds the ones Claude ranks above the root's stored /login, and
# the preflight below proves the root itself can authenticate. With it, the
# launch keeps them, and no preflight runs: their values come from the worker
# pane at execution time, which spawn cannot read. The selected root stays the
# fallback when none is present. Pi ranks its root's stored credentials above
# environment variables, so a Pi launch never sheds anything.
#
# Declarations are home-local and never inherited. A ship or scout reads the
# active home's files. A local secondmate is a supervisor and reads the
# launching home's files, never its own home's worker declarations and never
# an ambient CLAUDE_CONFIG_DIR; a remote secondmate's host-local launch reads
# its own remote home's files. Relaunch and startup recovery use that same
# home.
#
# Preflight: the runner's own non-interactive check, run with only HOME, PATH,
# TMPDIR, and the selected root in its environment, so a provider key left in
# the caller cannot answer for an empty root. Claude: `quota-axi auth --json
# --provider claude`; a source that is available or expired (renewed on next
# use) passes. A source skipped with credentialPresent passes only when the
# root's own .claude.json records a login (oauthAccount): quota-axi 0.1.41
# answers an empty root skipped/keychain_presence_check_failed with
# credentialPresent true, while a keychain-only /login still writes
# oauthAccount to that file ($HOME/.claude.json for the ordinary account).
# Pi: `pi auth check --provider <the launch model's provider> --json
# --no-refresh`; status "ready" passes, and any other JSON answer, such as a
# logged-out built-in provider's not_ready/credentials_not_configured, refuses.
# Two answers instead fall through to `pi --list-models <provider>`, which
# lists only the models a root can authenticate: not_ready/provider_not_found,
# because that command loads no extensions and so cannot see an
# extension-registered provider, and any non-JSON answer, which is what a Pi
# without `auth check` (0.84.0 and earlier) prints. The launch then passes
# only when a listed row's provider column is exactly the launch model's
# provider, the same provider-level question `auth check` answers; no such row
# within the bound refuses. --no-refresh keeps the check from rewriting a
# root's tokens while other workers use them. A codex-native/<id> model is not
# checked: that provider comes from the pi-codex-native extension and signs in
# through Codex's own login, which has no worker-account declaration.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_PREFLIGHT_SECONDS=30

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# AWS switches from code.claude.com/docs/en/claude-platform-on-aws and
# code.claude.com/docs/en/amazon-bedrock, "Use the Mantle endpoint").
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_read <harness> <file>
# Prints "root<TAB>providers<TAB>environment" for a valid declaration. The
# space-separated providers are empty for Claude; the last field is
# `environment` or empty. The final newline is optional; any other control
# byte, including a CR, refuses. Parses bytes before the shell can drop NULs or
# trailing newlines; paths are literal, not shell expressions. Returns 0 on
# success, 3 when the file does not exist, 4 when it cannot be inspected (one
# error already printed), 5 when it is not a readable regular file, and 6 when
# its contents are not a valid declaration. Callers own the message for each
# refusal.
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
    my ($root, $provider, $env) = ("", "", "");
    if ($harness eq "claude") {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)(?:\n(environment))?\n?\z/ or exit 6;
      ($root, $env) = ($1, $2 // "");
    } elsif ($harness eq "pi" || $harness eq "pi-signed") {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)(?:\n(environment))?\n?\z/ or exit 6;
      ($root, $provider, $env) = ($1, $2, $3 // "");
    } else {
      exit 6;
    }
    print $root, "\t", $provider, "\t", $env;
  ' -- "$1" "$2"
}

# fm_worker_account_pi_provider <model>
# Prints the provider a Pi --model names. Returns 1, silently, for anything
# that does not name one, so no caller can fall back to a root-wide default.
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

# fm_worker_account_raw_flag <raw launch command> <flag>
# Prints the value of <flag> (--model or --provider) embedded in a raw launch
# command as a separate word, the only form Pi parses, or nothing. A raw
# command is passed through verbatim, so fm-spawn's own flags do not reach the
# agent and only these values say which account a raw Pi launch would spend.
# Model and provider ids carry no spaces, so word splitting is enough; one
# layer of shell quoting around the value is removed.
fm_worker_account_raw_flag() {
  local flag=$2 word next=0 value=
  # ponytail: O(n) word split is enough because model ids carry no spaces; a
  # quoted argv parser is the upgrade if a raw command ever needs one.
  for word in $1; do
    if [ "$next" -eq 1 ]; then
      value=$word
      break
    fi
    [ "$word" != "$flag" ] || next=1
  done
  case "$value" in
  \'*\')
    value=${value#\'}
    value=${value%\'}
    ;;
  '"'*)
    value=${value#'"'}
    value=${value%'"'}
    ;;
  esac
  printf '%s\n' "$value"
}

# fm_worker_account_resolve <harness> <config-dir> <home>
# Prints "root<TAB>providers<TAB>environment" for the validated declaration.
# Root is empty for ordinary Claude, meaning CLAUDE_CONFIG_DIR unset. On
# refusal prints one error naming the runner, the home, and the file, and
# returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 home=$3 runner file fallback cfg token root rc
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude)
    runner=Claude
    file=claude-account
    fallback='~/.claude'
    ;;
  pi | pi-signed)
    runner=Pi
    file=pi-account
    fallback='~/.pi/agent'
    ;;
  *) return 1 ;;
  esac
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3)
    echo "error: $runner launches from home $home require an explicit account selection: create $cfg (see docs/configuration.md \"Worker accounts\"); Firstmate does not spend an ambient or $fallback login when that file is absent" >&2
    return 1
    ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$runner" = Pi ]; then
      echo "error: config/$file must contain an ordinary-or-absolute root on line 1, the providers this home may spend on line 2 separated by spaces, and optionally 'environment' on line 3, LF-separated with no other control characters: $cfg" >&2
    else
      echo "error: config/$file must contain 'ordinary' or one absolute path on line 1, and optionally 'environment' on line 2, LF-separated with no other control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  root=${token%%$'\t'*}
  if [ "$root" = ordinary ]; then
    root=
    [ "$runner" = Claude ] || root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent"
  fi
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: config/$file must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
    return 1
  fi
  printf '%s\t%s\n' "$root" "${token#*$'\t'}"
}

# fm_worker_account_pi_guard <declared-providers> <model>
# Returns 0 only when <model> is <provider>/<id> for one of the space-separated
# <declared-providers>. Otherwise prints one error and returns 1. Selecting a
# Pi root without naming the provider would spend whichever identity the
# shared root's defaultProvider holds.
fm_worker_account_pi_guard() {
  local declared=$1 model=$2 provider
  provider=$(fm_worker_account_pi_provider "$model") || {
    echo "error: a Pi launch needs --model as <provider>/<id> for a provider config/pi-account declares ($declared): '${model:-none}' names no provider, so the account inside a shared Pi root cannot be proved; the root's defaultProvider never decides this" >&2
    return 1
  }
  case " $declared " in
  *" $provider "*) return 0 ;;
  esac
  echo "error: a Pi launch may spend only the providers config/pi-account declares ($declared), but --model '$model' resolves to provider '$provider'" >&2
  return 1
}

# fm_worker_account_pi_raw_provider <provider> <raw launch command>
# Returns 0 only when a raw Pi command passes --provider <provider>, its
# model's declared provider.
# Otherwise prints one error and returns 1: Firstmate cannot add the flag to a
# command it launches verbatim, and without it Pi may resolve --model to an
# identical id under another provider.
fm_worker_account_pi_raw_provider() {
  local declared=$1 provider
  provider=$(fm_worker_account_raw_flag "$2" --provider)
  [ "$provider" != "$declared" ] || return 0
  echo "error: a raw Pi launch command must pass --provider $declared, the declared provider its --model names (config/pi-account); it passes '${provider:-none}', and without it Pi may resolve --model to an identical id under another provider" >&2
  return 1
}

# fm_worker_account_pi_provider_listed <root> <executable> <provider> <clean-env...>
# Returns 0 when `pi --list-models` prints a row whose provider column is
# exactly <provider>. Fuzzy search means the listing also carries near matches,
# so the column is compared exactly and the header row is skipped; a timeout,
# an unreadable root, or no matching row all return 1.
fm_worker_account_pi_provider_listed() {
  local root=$1 executable=$2 provider=$3 out
  shift 3
  out=$(fm_run_timed "$FM_WORKER_ACCOUNT_PREFLIGHT_SECONDS" "$@" "PI_CODING_AGENT_DIR=$root" \
    "$executable" --list-models "$provider" 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'
}

# fm_worker_account_preflight <harness> <root> <executable> [<model>]
# Returns 0 only when the runner's own check says the root can authenticate
# the launch; otherwise prints one error and returns 1. An empty Claude root is
# the ordinary account, checked with CLAUDE_CONFIG_DIR unset.
fm_worker_account_preflight() {
  local harness=$1 root=$2 executable=$3 model=${4:-} out verdict provider
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=$PATH")
  [ -z "${TMPDIR:-}" ] || clean+=("TMPDIR=$TMPDIR")
  case "$harness" in
  claude)
    local logged_in=false who="the Claude account $root" login="CLAUDE_CONFIG_DIR=$root claude"
    if [ -n "$root" ]; then
      clean+=("CLAUDE_CONFIG_DIR=$root")
    else
      who="the ordinary Claude account"
      login="env -u CLAUDE_CONFIG_DIR claude"
    fi
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_PREFLIGHT_SECONDS" "${clean[@]}" \
      quota-axi auth --json --provider claude 2>/dev/null </dev/null)
    [ "$(jq -r 'has("oauthAccount")' "${root:-${HOME:-}}/.claude.json" 2>/dev/null)" != true ] || logged_in=true
    verdict=$(printf '%s\n' "$out" | jq -r --argjson logged_in "$logged_in" '
      [.auth[]? | select(.provider == "claude") | .sources[]?] as $s |
      if any($s[]; .status == "available" or .status == "expired" or
             (.status == "skipped" and .credentialPresent == true and $logged_in))
      then "ready"
      else ($s | map("\(.source)=\(.status)") | join(", "))
      end' 2>/dev/null)
    [ "$verdict" != ready ] || return 0
    echo "error: $who holds no usable login (quota-axi auth: ${verdict:-no answer}); log in under it with $login, then /login, select another root in config/claude-account, or declare environment credentials there" >&2
    return 1
    ;;
  pi | pi-signed)
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: a $harness launch needs --model as <provider>/<id>: '${model:-none}' names no provider, and the account inside a shared Pi root is chosen by the provider, never by the root's defaultProvider" >&2
      return 1
    }
    [ "$provider" != codex-native ] || return 0
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_PREFLIGHT_SECONDS" "${clean[@]}" "PI_CODING_AGENT_DIR=$root" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.provider // "") \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      # A Pi without `auth check` (0.84.0 and earlier) answers with an error
      # instead of JSON, and `auth check` loads no extensions, so an
      # extension-registered provider is unknown to it. pi --list-models
      # exists in every supported Pi, loads extensions, and lists only the
      # models a root can authenticate, so a listed row answers the same
      # question.
      fm_worker_account_pi_provider_listed "$root" "$executable" "$provider" "${clean[@]}" && return 0
      echo "error: the Pi account $root lists no model for provider '$provider' (pi --list-models shows only the models a root can authenticate); log in under it with PI_CODING_AGENT_DIR=$root $harness, then /login, or pass --model as <provider>/<id> for a provider this root serves" >&2
      return 1
      ;;
    esac
    echo "error: the Pi account $root cannot authenticate --provider $provider (pi auth check: $verdict); log in under it with PI_CODING_AGENT_DIR=$root $harness, then /login, or pass --model as <provider>/<id>" >&2
    return 1
    ;;
  *) return 0 ;;
  esac
}

# fm_worker_account_select <harness> <config-dir> <home> <model> <executable>
# The whole launch-time decision: resolves the home's declaration, holds a Pi
# launch to a declared provider, and runs the preflight unless the home
# declared environment credentials. Prints "root<TAB>provider<TAB>environment"
# for a runner with a declaration, where provider is the Pi launch model's own
# (empty for Claude), and nothing for any other runner; on refusal prints one
# error and returns 1. bin/fm-control.sh runs it before a relaunch stops the
# live agent, and bin/fm-spawn.sh before any endpoint exists.
fm_worker_account_select() {
  local harness=$1 config=$2 home=$3 model=$4 executable=$5 selection root rest provider=
  case "$harness" in
  claude | pi | pi-signed) ;;
  *) return 0 ;;
  esac
  selection=$(fm_worker_account_resolve "$harness" "$config" "$home") || return 1
  root=${selection%%$'\t'*}
  rest=${selection#*$'\t'}
  if [ "$harness" != claude ]; then
    fm_worker_account_pi_guard "${rest%%$'\t'*}" "$model" || return 1
    provider=$(fm_worker_account_pi_provider "$model")
  fi
  if [ -z "${rest#*$'\t'}" ]; then
    fm_worker_account_preflight "$harness" "$root" "$executable" "$model" || return 1
  fi
  printf '%s\t%s\t%s\n' "$root" "$provider" "${rest#*$'\t'}"
}

# fm_worker_account_claude_env <environment>
# Prints the `env` launch prefix for a selected Claude account. It unsets the
# environment credentials Claude ranks above the root's stored /login unless
# the home declared `environment`, which selects them. The caller appends the
# root assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_env() {
  local var prefix=env
  [ -n "$1" ] || for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
