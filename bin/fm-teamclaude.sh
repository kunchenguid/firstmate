#!/usr/bin/env bash
# Route Firstmate-launched Claude, Codex, and Pi openai-codex workers through
# TeamClaude. This script is the single owner of that launch contract.
# fm-spawn.sh calls the functions below; the subcommands are the same contract
# for operators and tests.
#
# Claude launches take the MITM environment from `teamclaude env --mitm`
# (HTTPS_PROXY, HTTP_PROXY, the lowercase twins, NO_PROXY, and
# NODE_EXTRA_CA_CERTS), unset ANTHROPIC_BASE_URL, and never set
# ANTHROPIC_API_KEY. They do not use `teamclaude run` and they do not pass
# --auto-fallback. A missing teamclaude CLI, a `teamclaude status` failure, or
# a missing CA file refuses the launch. There is no direct-login fallback.
#
# Codex launches pass the TeamClaude provider with -c (model_provider and
# model_providers.teamclaude base_url/wire_api/name) and clear proxy variables
# on that process so the HTTP base URL is the only route. When the first
# `codex` on PATH is an opencodex autostart shim (the marker
# "opencodex codex autostart shim"), the launch executes the sibling
# `<codex>.opencodex-real` instead of the shim. opencodex is not stopped and
# OpenCode launches are not rewritten.
#
# Pi and pi-signed launches route only when the model or the provider is
# openai-codex. The per-task agent directory's models.json sets that
# provider's baseUrl to the proxy's /backend-api path, which Pi normalizes
# onto /codex/responses. OpenAI API-key models are not redirected. A launch
# that does not name openai-codex is unchanged and does not require the proxy.
#
# Rotation stays TeamClaude's. This script does not pick accounts. When
# `teamclaude threshold` does not report a flat 95%, the routed launch still
# proceeds and warns that the remaining local step is
# `bin/fm-teamclaude.sh apply-threshold`. That subcommand runs
# `teamclaude threshold 95` (TeamClaude writes its config and notifies the
# running proxy). A task copy must not run it.
#
# omp is not this contract: its worker overlay does not rewrite provider
# endpoints. The Herdr primary is started by Herdr's own agent command, not
# by fm-spawn, so this script does not change it. Every fm-spawn backend
# sends the same launch command, so the routing covers tmux, herdr, zellij,
# orca, and cmux workers alike.
#
# Usage: fm-teamclaude.sh <claude-env|codex-exec|codex-config|pi-prefix|apply-threshold|help>
#        fm-teamclaude.sh pi-prefix --model <model> --provider <provider> --agent-dir <dir> --dest <dir>
fm_teamclaude_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_teamclaude_unquote() {
  local value=$1
  case "$value" in
    \'*\') value=${value#\'}; value=${value%\'} ;;
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  printf '%s' "$value"
}

fm_teamclaude_die() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

fm_teamclaude_require_proxy() {
  local env_out errfile line name raw value
  if [ "${_FM_TC_READY:-}" = 1 ]; then
    return 0
  fi
  if ! command -v teamclaude >/dev/null 2>&1; then
    fm_teamclaude_die "teamclaude is not on PATH. Refusing to start this worker because a direct login would be spent. Install TeamClaude and start its proxy. There is no direct fallback."
    return 1
  fi
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-teamclaude.XXXXXX") || return 1
  if ! env_out=$(teamclaude env --mitm 2>"$errfile"); then
    fm_teamclaude_die "teamclaude env --mitm failed. Refusing to start this worker. There is no direct fallback." || true
    sed 's/^/error: /' "$errfile" >&2
    rm -f "$errfile"
    return 1
  fi
  _FM_TC_HTTPS_PROXY=
  _FM_TC_HTTP_PROXY=
  _FM_TC_https_proxy=
  _FM_TC_http_proxy=
  _FM_TC_NO_PROXY=
  _FM_TC_no_proxy=
  _FM_TC_CA=
  while IFS= read -r line; do
    case "$line" in
      export\ *)
        line=${line#export }
        name=${line%%=*}
        raw=${line#*=}
        value=$(fm_teamclaude_unquote "$raw")
        case "$name" in
          HTTPS_PROXY) _FM_TC_HTTPS_PROXY=$value ;;
          HTTP_PROXY) _FM_TC_HTTP_PROXY=$value ;;
          https_proxy) _FM_TC_https_proxy=$value ;;
          http_proxy) _FM_TC_http_proxy=$value ;;
          NO_PROXY) _FM_TC_NO_PROXY=$value ;;
          no_proxy) _FM_TC_no_proxy=$value ;;
          NODE_EXTRA_CA_CERTS) _FM_TC_CA=$value ;;
          ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL) ;;
        esac
        ;;
    esac
  done <<EOF
$env_out
EOF
  if [ -z "$_FM_TC_HTTPS_PROXY" ] || [ -z "$_FM_TC_CA" ]; then
    rm -f "$errfile"
    fm_teamclaude_die "teamclaude env --mitm did not provide HTTPS_PROXY and NODE_EXTRA_CA_CERTS. Refusing to start this worker. There is no direct fallback."
    return 1
  fi
  if [ ! -f "$_FM_TC_CA" ]; then
    rm -f "$errfile"
    fm_teamclaude_die "TeamClaude CA file is missing at ${_FM_TC_CA}. Refusing to start this worker. There is no direct fallback."
    return 1
  fi
  if ! teamclaude status --json >/dev/null 2>"$errfile"; then
    fm_teamclaude_die "TeamClaude proxy is not available. Refusing to start this worker. There is no direct fallback." || true
    sed 's/^/error: /' "$errfile" >&2
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  fm_teamclaude_warn_threshold || return 1
  _FM_TC_READY=1
}

fm_teamclaude_warn_threshold() {
  local report first extra
  if ! report=$(teamclaude threshold 2>&1); then
    fm_teamclaude_die "could not read TeamClaude's rotation threshold. Refusing to guess a second rotator."
    return 1
  fi
  first=${report%%$'\n'*}
  extra=$(printf '%s\n' "$report" | awk 'NR > 1 && $0 ~ /^  / { found = 1 } END { if (found) print "yes" }')
  if [ "$first" = "Switch threshold: 95%" ] && [ -z "$extra" ]; then
    return 0
  fi
  printf '%s\n' "warning: TeamClaude rotation threshold is not a flat 95% (${first})." >&2
  printf '%s\n' "warning: remaining local step: run bin/fm-teamclaude.sh apply-threshold from the firstmate code root on the machine that hosts the proxy. That runs \`teamclaude threshold 95\`, which is TeamClaude's own threshold command: it writes the proxy config and notifies the running proxy. Firstmate does not rotate accounts itself." >&2
}

fm_teamclaude_claude_env() {
  fm_teamclaude_require_proxy || return 1
  printf '%s ' "-u ANTHROPIC_BASE_URL"
  printf '%s ' "HTTPS_PROXY=$(fm_teamclaude_shell_quote "$_FM_TC_HTTPS_PROXY")"
  [ -z "$_FM_TC_HTTP_PROXY" ] || printf '%s ' "HTTP_PROXY=$(fm_teamclaude_shell_quote "$_FM_TC_HTTP_PROXY")"
  [ -z "$_FM_TC_https_proxy" ] || printf '%s ' "https_proxy=$(fm_teamclaude_shell_quote "$_FM_TC_https_proxy")"
  [ -z "$_FM_TC_http_proxy" ] || printf '%s ' "http_proxy=$(fm_teamclaude_shell_quote "$_FM_TC_http_proxy")"
  [ -z "$_FM_TC_NO_PROXY" ] || printf '%s ' "NO_PROXY=$(fm_teamclaude_shell_quote "$_FM_TC_NO_PROXY")"
  [ -z "$_FM_TC_no_proxy" ] || printf '%s ' "no_proxy=$(fm_teamclaude_shell_quote "$_FM_TC_no_proxy")"
  printf '%s ' "NODE_EXTRA_CA_CERTS=$(fm_teamclaude_shell_quote "$_FM_TC_CA")"
}

fm_teamclaude_is_shim() {
  local path=$1
  [ -f "$path" ] || return 1
  grep -a -q -F 'opencodex codex autostart shim' "$path" 2>/dev/null
}

fm_teamclaude_resolve_codex() {
  local rest path_dir candidate sibling
  rest=$PATH
  while [ -n "$rest" ]; do
    path_dir=${rest%%:*}
    case "$rest" in
      *:*) rest=${rest#*:} ;;
      *) rest= ;;
    esac
    [ -n "$path_dir" ] || continue
    candidate=$path_dir/codex
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    if fm_teamclaude_is_shim "$candidate"; then
      sibling=$path_dir/codex.opencodex-real
      if [ -x "$sibling" ] && [ ! -d "$sibling" ] && ! fm_teamclaude_is_shim "$sibling"; then
        printf '%s\n' "$sibling"
        return 0
      fi
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

fm_teamclaude_codex_exec() {
  local resolved first
  fm_teamclaude_require_proxy || return 1
  if ! resolved=$(fm_teamclaude_resolve_codex); then
    printf '%s\n' codex
    return 0
  fi
  first=$(command -v codex 2>/dev/null || true)
  if [ -n "$first" ] && [ "$first" = "$resolved" ]; then
    printf '%s\n' codex
    return 0
  fi
  fm_teamclaude_shell_quote "$resolved"
  printf '\n'
}

fm_teamclaude_codex_config() {
  local origin base
  fm_teamclaude_require_proxy || return 1
  origin=${_FM_TC_HTTPS_PROXY%/}
  base="${origin}/backend-api/codex"
  printf '%s ' "-c $(fm_teamclaude_shell_quote 'model_provider="teamclaude"')"
  printf '%s ' "-c $(fm_teamclaude_shell_quote 'model_providers.teamclaude.name="teamclaude"')"
  printf '%s ' "-c $(fm_teamclaude_shell_quote "model_providers.teamclaude.base_url=\"${base}\"")"
  printf '%s ' "-c $(fm_teamclaude_shell_quote 'model_providers.teamclaude.wire_api="responses"')"
}

fm_teamclaude_splice_codex() {
  local launch=$1 exec_token=$2 config=$3 prefix='' rest=$1 word=''
  # Only a leading assignment word counts. A later `=` inside a flag such as
  # codex -c notify=... is not an assignment and must not hide the command.
  while [ -n "$rest" ]; do
    word=${rest%% *}
    case "$word" in
      [A-Za-z_][A-Za-z0-9_]*=*)
        prefix="$prefix$word "
        case "$rest" in
          *" "*) rest=${rest#* } ;;
          *) rest= ;;
        esac
        ;;
      *) break ;;
    esac
  done
  # Keep the historical flag order at the front of the command. The
  # provider overrides go immediately before the launch-brief argument so
  # they are still Codex config and do not split flags the launch already
  # documents as a prefix.
  if [ "$word" = codex ]; then
    launch="$prefix$exec_token${rest#codex}"
  fi
  # The single quotes are intentional: the brief marker is the literal
  # characters `"$(`, not a command substitution.
  # shellcheck disable=SC2016
  case "$launch" in
    *'"$('*)
      # shellcheck disable=SC2016
      prefix=${launch%'"$('*}
      rest=${launch#"$prefix"}
      printf '%s%s%s' "$prefix" "$config" "$rest"
      ;;
    *)
      printf '%s %s' "$launch" "$config"
      ;;
  esac
}

fm_teamclaude_pi_routes() {
  local model=$1 provider=$2
  case "$model" in
    openai-codex | openai-codex/*) return 0 ;;
  esac
  case "$provider" in
    openai-codex) return 0 ;;
  esac
  return 1
}

fm_teamclaude_pi_prefix() {
  local model=$1 provider=$2 agent_dir=$3 dest=$4 origin base name src
  fm_teamclaude_pi_routes "$model" "$provider" || return 0
  fm_teamclaude_require_proxy || return 1
  command -v python3 >/dev/null 2>&1 || {
    fm_teamclaude_die "python3 is required to point a Pi openai-codex model at TeamClaude. Refusing to start this worker. There is no direct fallback."
    return 1
  }
  origin=${_FM_TC_HTTPS_PROXY%/}
  base="${origin}/backend-api"
  mkdir -p "$dest" || return 1
  chmod 700 "$dest" || return 1
  python3 - "$agent_dir/models.json" "$dest/models.json" "$base" <<'PY' || return 1
import json, os, sys
src, dest, base = sys.argv[1:]
data = {"providers": {}}
if os.path.isfile(src):
    with open(src) as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict):
        data = loaded
providers = data.get("providers")
if not isinstance(providers, dict):
    providers = {}
    data["providers"] = providers
entry = providers.get("openai-codex")
if not isinstance(entry, dict):
    entry = {}
entry["baseUrl"] = base
providers["openai-codex"] = entry
with open(dest, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
os.chmod(dest, 0o600)
PY
  for name in auth.json settings.json models-store.json bin themes tools prompts; do
    src=$agent_dir/$name
    if [ -e "$src" ] || [ -L "$src" ]; then
      if [ ! -e "$dest/$name" ] && [ ! -L "$dest/$name" ]; then
        ln -s "$src" "$dest/$name" || return 1
      fi
    fi
  done
  printf '%s ' "PI_CODING_AGENT_DIR=$(fm_teamclaude_shell_quote "$dest")"
}

fm_teamclaude_apply_threshold() {
  command -v teamclaude >/dev/null 2>&1 || {
    fm_teamclaude_die "teamclaude is not on PATH"
    return 1
  }
  exec teamclaude threshold 95
}

fm_teamclaude_usage() {
  sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_teamclaude_pi_args() {
  local model='' provider='' agent_dir='' dest=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) model=${2:-}; shift 2 ;;
      --provider) provider=${2:-}; shift 2 ;;
      --agent-dir) agent_dir=${2:-}; shift 2 ;;
      --dest) dest=${2:-}; shift 2 ;;
      *) fm_teamclaude_die "unknown pi-prefix argument: $1"; return 1 ;;
    esac
  done
  [ -n "$dest" ] || {
    fm_teamclaude_die "pi-prefix requires --dest"
    return 1
  }
  fm_teamclaude_pi_prefix "$model" "$provider" "$agent_dir" "$dest"
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

set -euo pipefail

case "${1:-}" in
  claude-env) fm_teamclaude_claude_env ;;
  codex-exec) fm_teamclaude_codex_exec ;;
  codex-config) fm_teamclaude_codex_config ;;
  pi-prefix) shift; fm_teamclaude_pi_args "$@" ;;
  apply-threshold) fm_teamclaude_apply_threshold ;;
  help | --help | -h) fm_teamclaude_usage ;;
  *) fm_teamclaude_die "usage: fm-teamclaude.sh <claude-env|codex-exec|codex-config|pi-prefix|apply-threshold|help>"; exit 1 ;;
esac
