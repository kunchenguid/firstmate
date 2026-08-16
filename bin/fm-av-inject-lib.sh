# shellcheck shell=bash
# Automic Vault secret-injection primitives.
# Usage: . bin/fm-av-inject-lib.sh
#
# This library owns the contract for wrapping a crewmate/secondmate launch in
# `av inject +KEY... -- <launch>` so the worker receives the captain's static
# API keys from Automic Vault as environment variables, never on disk and never
# printed. bin/fm-spawn.sh assembles the launch command and calls
# fm_av_inject_prefix once per spawn to obtain the wrapper text.
#
# Automic Vault ("av") is a macOS-only local secrets manager: `av inject` copies
# the full ambient environment plus the named secrets and execs the target, so
# every env prefix firstmate already sets (FM_HOME, CLAUDE_CONFIG_DIR,
# TRACEPARENT, ...) is preserved as long as it appears BEFORE `av inject` on the
# launch line. The value reaches the worker's environment only; `av inject`
# itself prints nothing. See data/automic-vault-r1/report.md for the researched
# model and the migration prerequisites (verified launcher, per-secret Direct
# Access Rules, availability), and data/automic-vault-r1/decisions.md for the
# captain's approvals.
#
# Enablement is OFF by default because the shared template runs on homes and CI
# that have no Automic Vault app, and because the secrets must be migrated with
# an attended `av save` copy BEFORE injection can succeed (turning it on before
# the keys exist would make every `av inject` fail closed and break every
# spawn). Turn it on per home only after the migration is verified.

# The static API keys approved for injection (data/automic-vault-r1 plan, key
# names exactly as stored by `av save`). Key NAMES are not secret (they are what
# `av list` returns); the VALUES live only in the macOS keychain and are never
# handled here. Override for tests with FM_AV_INJECT_KEYS.
FM_AV_INJECT_DEFAULT_KEYS="EXA_API_KEY PARALLEL_API_KEY TAVILY_API_KEY LINKUP_API_KEY BRAVE_SEARCH_API_KEY BRAVE_ANSWERS_API_KEY DEEPSEEK_API_KEY BUZZ_XYZ_KEY"

FM_AV_INJECT_FILE="av-inject"
FM_AV_INJECT_ERROR=""

# Read the enablement decision. FM_AV_INJECT (env) wins over the local,
# gitignored config/<FM_AV_INJECT_FILE> file; absent/empty/off/false/no/0 all
# mean disabled (the default), on/true/yes/1 mean enabled. An unrecognized value
# is treated as disabled so a typo fails safe rather than breaking every spawn.
# Prints "on" or "off".
# Args: <config-dir>
fm_av_inject_mode() {  # <config-dir>
  local raw="" file="$1/$FM_AV_INJECT_FILE"
  if [ -n "${FM_AV_INJECT:-}" ]; then
    raw=$FM_AV_INJECT
  elif [ -f "$file" ]; then
    # `read` takes the first line with leading/trailing whitespace trimmed; a
    # missing final newline still yields the value, so `|| true` guards the
    # non-zero read at EOF. Builtins only, so the check works even when PATH is
    # too restricted to resolve coreutils.
    IFS= read -r raw < "$file" 2>/dev/null || true
    raw=${raw#"${raw%%[![:space:]]*}"}
    raw=${raw%"${raw##*[![:space:]]}"}
  fi
  # Case-insensitive bracket patterns avoid a lowercasing external command
  # (portable to bash 3.2, and works under a PATH too restricted for coreutils).
  case "$raw" in
    [Oo][Nn]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1) printf 'on\n' ;;
    *) printf 'off\n' ;;
  esac
}

# Resolve the `av` executable to an absolute path, mirroring resolve_pi_executable
# in bin/fm-spawn.sh so the pane runs the same signed CLI firstmate resolved.
# Prints the absolute path on success; returns non-zero when not found.
fm_av_inject_bin() {
  local candidate dir
  candidate=$(type -P -- av 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
      printf '%s/%s\n' "$dir" "$(basename "$candidate")"
      ;;
  esac
}

# Compute the launch-command prefix that wraps a worker launch in `av inject`.
# When injection is disabled, prints nothing and succeeds (the launch is
# unchanged). When enabled, resolves `av` and every key name and prints
# `<av> inject +KEY1 +KEY2 ... -- ` (with a trailing space) so the caller can
# splice it immediately before the agent binary. Fails closed with a message in
# FM_AV_INJECT_ERROR when enabled but `av` is missing or a key name is invalid,
# so a misconfigured home refuses to spawn rather than launching without the
# secrets it was told to inject.
# Args: <config-dir>
fm_av_inject_prefix() {  # <config-dir>
  local config_dir=$1 av key keys quoted
  FM_AV_INJECT_ERROR=""
  [ "$(fm_av_inject_mode "$config_dir")" = on ] || { printf '%s' ''; return 0; }
  if ! av=$(fm_av_inject_bin); then
    FM_AV_INJECT_ERROR="av-inject is enabled but the 'av' CLI (Automic Vault) was not found on PATH; install Automic Vault or set config/av-inject to off"
    return 1
  fi
  keys=${FM_AV_INJECT_KEYS:-$FM_AV_INJECT_DEFAULT_KEYS}
  # `av` validates key names as [A-Za-z_][A-Za-z0-9_]* (src/cli/inject.rs); mirror
  # that here so an invalid name is a loud refusal rather than a mangled launch.
  quoted=""
  for key in $keys; do
    case "$key" in
      [A-Za-z_]*)
        case "$key" in
          *[!A-Za-z0-9_]*)
            FM_AV_INJECT_ERROR="av-inject key name '$key' is not a valid secret name ([A-Za-z_][A-Za-z0-9_]*)"
            return 1
            ;;
        esac
        ;;
      *)
        FM_AV_INJECT_ERROR="av-inject key name '$key' is not a valid secret name ([A-Za-z_][A-Za-z0-9_]*)"
        return 1
        ;;
    esac
    quoted="$quoted +$key"
  done
  if [ -z "$quoted" ]; then
    FM_AV_INJECT_ERROR="av-inject is enabled but no secret key names are configured"
    return 1
  fi
  # <av> inject +K1 +K2 -- <agent...>. av path is single-quoted; key names passed
  # this validation and need no quoting.
  printf "'%s' inject%s -- " "$(printf '%s' "$av" | sed "s/'/'\\\\''/g")" "$quoted"
}
