#!/usr/bin/env bash
# shellcheck disable=SC2034 # Output globals are read by sourcing callers.
# fm-codex-tier-lib.sh - read-only Codex fast-tier capability checks.

fm_codex_fast_tier_runtime_resolve() {
  local candidate dir path resolved
  FM_CODEX_FAST_TIER_BIN=
  FM_CODEX_FAST_TIER_HOME=
  candidate=$(type -P -- codex 2>/dev/null) || {
    echo "error: Codex executable not found; cannot verify --tier fast support" >&2
    return 1
  }
  [ -x "$candidate" ] || {
    echo "error: Codex executable not found; cannot verify --tier fast support" >&2
    return 1
  }
  case "$candidate" in
    /*) FM_CODEX_FAST_TIER_BIN=$candidate ;;
    *)
      dir=$(CDPATH='' cd -- "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
      FM_CODEX_FAST_TIER_BIN="$dir/$(basename "$candidate")"
      ;;
  esac
  if [ "${CODEX_HOME+x}" = x ]; then
    path=$CODEX_HOME
    [ -n "$path" ] || {
      echo "error: CODEX_HOME is set but empty; cannot pin the Codex launch configuration" >&2
      return 1
    }
  else
    [ -n "${HOME:-}" ] || {
      echo "error: HOME is unset; cannot resolve Codex's default config home" >&2
      return 1
    }
    path=$HOME/.codex
  fi
  [ -d "$path" ] || {
    echo "error: effective CODEX_HOME directory does not exist: $path" >&2
    return 1
  }
  case "$path" in
    /*) FM_CODEX_FAST_TIER_HOME=$path ;;
    *)
      resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
        echo "error: CODEX_HOME directory cannot be resolved: $path" >&2
        return 1
      }
      FM_CODEX_FAST_TIER_HOME=$resolved
      ;;
  esac
}

fm_codex_fast_tier_supported() {
  local worktree=$1 model=$2 executable=$3 config_home=$4 doctor catalog
  if [ -z "$model" ] || [ "$model" = default ]; then
    doctor=$(cd "$worktree" && CODEX_HOME="$config_home" "$executable" doctor --json 2>/dev/null) || true
    case "$doctor" in
      \{*\}) ;;
      *)
        echo "error: could not resolve Codex's effective model; refusing --tier fast" >&2
        return 1
        ;;
    esac
    if ! model=$(printf '%s\n' "$doctor" | awk '
      { json = json $0 }
      END {
        count = split(json, checks, /"id"[[:space:]]*:[[:space:]]*"/)
        for (i = 2; i <= count; i++) {
          id = checks[i]
          sub(/".*/, "", id)
          if (id != "config.load") continue
          if (!match(checks[i], /"model"[[:space:]]*:[[:space:]]*"[^"]+"/)) exit 1
          model = substr(checks[i], RSTART, RLENGTH)
          sub(/^[^:]*:[[:space:]]*"/, "", model)
          sub(/"$/, "", model)
          print model
          exit 0
        }
        exit 1
      }
    '); then
      echo "error: could not resolve Codex's effective model; refusing --tier fast" >&2
      return 1
    fi
  fi
  if ! catalog=$(cd "$worktree" && CODEX_HOME="$config_home" "$executable" debug models 2>/dev/null); then
    echo "error: could not inspect the installed Codex model catalog; refusing --tier fast" >&2
    return 1
  fi
  if ! printf '%s\n' "$catalog" | awk -v wanted="$model" '
    { json = json $0 }
    END {
      count = split(json, models, /"slug"[[:space:]]*:[[:space:]]*"/)
      for (i = 2; i <= count; i++) {
        slug = models[i]
        sub(/".*/, "", slug)
        if (slug == wanted && models[i] ~ /"service_tiers"[[:space:]]*:[[:space:]]*\[[^]]*"id"[[:space:]]*:[[:space:]]*"priority"/) exit 0
      }
      exit 1
    }
  '; then
    echo "error: Codex model '$model' does not advertise the priority service tier; refusing --tier fast" >&2
    return 1
  fi
}
