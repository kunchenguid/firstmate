#!/usr/bin/env bash
# Route Firstmate-launched Claude and Codex workers through TeamClaude. This
# script is the single owner of that launch contract.
# fm-spawn.sh calls the functions below; the subcommands are the same contract
# for operators and tests.
#
# Claude launches take the MITM environment from `teamclaude env --mitm`
# (HTTPS_PROXY, HTTP_PROXY, the lowercase twins, NO_PROXY,
# NODE_EXTRA_CA_CERTS, and API_TIMEOUT_MS when TeamClaude holds requests),
# unset ANTHROPIC_BASE_URL, and never set
# ANTHROPIC_API_KEY. They do not use `teamclaude run` and they do not pass
# --auto-fallback. A missing teamclaude CLI, a `teamclaude status` failure, or
# a missing CA file refuses the launch. There is no direct-login fallback.
#
# Codex launches pass the TeamClaude provider with -c (model_provider and
# model_providers.teamclaude base_url/wire_api/name). fm-spawn keeps the
# ambient proxy and CA variables on that process and adds 127.0.0.1 and
# localhost to NO_PROXY/no_proxy, so only the loopback base URL skips a
# proxy. When the first `codex` on PATH is an opencodex autostart shim (the
# marker "opencodex codex autostart shim"), the launch executes the sibling
# `<codex>.opencodex-real` instead of the shim, and refuses the worker when
# that sibling is missing or not executable. opencodex is not stopped and
# OpenCode launches are not rewritten.
#
# Pi and pi-signed launches do not go through TeamClaude for now (bead
# ag-awb).
#
# Rotation stays TeamClaude's. This script does not pick accounts. Every
# routed launch requires `teamclaude threshold` to report an effective
# unified5h threshold of 80% and unified7d threshold of 95% (a bucket without
# its own line uses the "Switch threshold" default). When either differs, the
# launch runs `teamclaude threshold unified5h=80 unified7d=95` (TeamClaude
# writes its config and notifies the running proxy), reads the thresholds
# again, and refuses the worker when they still differ. It never sets one
# flat number, which would drop the 5-hour bucket.
#
# omp is not this contract: its worker overlay does not rewrite provider
# endpoints. The Herdr primary is started by Herdr's own agent command, not
# by fm-spawn, so this script does not change it. Every fm-spawn backend
# sends the same launch command, so the routing covers tmux, herdr, zellij,
# orca, and cmux workers alike.
#
# Usage: fm-teamclaude.sh <claude-env|codex-exec|codex-config|help>
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
  _FM_TC_API_TIMEOUT_MS=
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
          API_TIMEOUT_MS) _FM_TC_API_TIMEOUT_MS=$value ;;
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
  fm_teamclaude_enforce_threshold || return 1
  _FM_TC_READY=1
}

fm_teamclaude_threshold_ok() {
  local report errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-teamclaude.XXXXXX") || return 2
  if ! report=$(teamclaude threshold 2>"$errfile"); then
    fm_teamclaude_die "could not read TeamClaude's rotation threshold. Refusing to start this worker. There is no direct fallback." || true
    sed 's/^/error: /' "$errfile" >&2
    rm -f "$errfile"
    return 2
  fi
  rm -f "$errfile"
  _FM_TC_THRESHOLD=$(printf '%s\n' "$report" | awk '
    /^Switch threshold: / { base = $3 }
    /^  unified5h: / { h5 = $2 }
    /^  unified7d: / { d7 = $2 }
    END {
      if (h5 == "") h5 = base
      if (d7 == "") d7 = base
      print "unified5h=" h5 " unified7d=" d7
    }')
  [ "$_FM_TC_THRESHOLD" = "unified5h=80% unified7d=95%" ]
}

fm_teamclaude_enforce_threshold() {
  local out rc
  fm_teamclaude_threshold_ok && return 0 || rc=$?
  [ "$rc" = 1 ] || return 1
  if ! out=$(teamclaude threshold unified5h=80 unified7d=95 2>&1); then
    fm_teamclaude_die "TeamClaude's rotation thresholds are ${_FM_TC_THRESHOLD}, not unified5h=80% unified7d=95%, and \`teamclaude threshold unified5h=80 unified7d=95\` failed. Refusing to start this worker. There is no direct fallback." || true
    printf '%s\n' "$out" | sed 's/^/error: /' >&2
    return 1
  fi
  fm_teamclaude_threshold_ok && return 0 || rc=$?
  [ "$rc" = 1 ] || return 1
  fm_teamclaude_die "TeamClaude's rotation thresholds are still ${_FM_TC_THRESHOLD} after \`teamclaude threshold unified5h=80 unified7d=95\`, not unified5h=80% unified7d=95%. Refusing to start this worker. There is no direct fallback."
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
  [ -z "$_FM_TC_API_TIMEOUT_MS" ] || printf '%s ' "API_TIMEOUT_MS=$(fm_teamclaude_shell_quote "$_FM_TC_API_TIMEOUT_MS")"
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
      fm_teamclaude_die "the first codex on PATH ($candidate) is the opencodex autostart shim, and its real binary $sibling is missing or not executable. Refusing to start this worker because the shim would run Codex through opencodex instead of TeamClaude."
      return 1
    fi
    printf '%s\n' "$candidate"
    return 0
  done
  # No codex on PATH: print nothing and leave the launch's bare `codex`.
  return 0
}

fm_teamclaude_codex_exec() {
  local resolved first
  fm_teamclaude_require_proxy || return 1
  resolved=$(fm_teamclaude_resolve_codex) || return 1
  first=$(command -v codex 2>/dev/null || true)
  if [ -z "$resolved" ] || [ "$first" = "$resolved" ]; then
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
      [A-Za-z_]*=*)
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

fm_teamclaude_usage() {
  sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

set -euo pipefail

case "${1:-}" in
  claude-env) fm_teamclaude_claude_env ;;
  codex-exec) fm_teamclaude_codex_exec ;;
  codex-config) fm_teamclaude_codex_config ;;
  help | --help | -h) fm_teamclaude_usage ;;
  *) fm_teamclaude_die "usage: fm-teamclaude.sh <claude-env|codex-exec|codex-config|help>"; exit 1 ;;
esac
