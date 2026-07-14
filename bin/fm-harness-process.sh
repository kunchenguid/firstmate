#!/usr/bin/env bash
# Shared process-shape classification for verified harness adapters.

fm_harness_executable_name() {  # <executable basename>
  local name=${1##*/}
  name=${name#-}
  case "$name" in
    claude|claude-code) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    opencode) printf 'opencode\n' ;;
    grok) printf 'grok\n' ;;
    kimi) printf 'kimi\n' ;;
    devin) printf 'devin\n' ;;
    pi|pi-signed|pi-launcher|Pi) printf 'pi\n' ;;
    *) return 1 ;;
  esac
}

fm_harness_script_name() {  # <interpreter script path>
  local path=$1 component stem
  path=${path#\"}
  path=${path%\"}
  path=${path#\'}
  path=${path%\'}
  while [ -n "$path" ]; do
    component=${path%%/*}
    path=${path#*/}
    [ "$component" = "$path" ] && path=
    stem=${component%%.*}
    case "$component:$stem" in
      claude-code:*|claude:claude) printf 'claude\n'; return 0 ;;
      codex:codex|*:codex) printf 'codex\n'; return 0 ;;
      opencode:opencode|*:opencode) printf 'opencode\n'; return 0 ;;
      grok:grok|*:grok) printf 'grok\n'; return 0 ;;
      kimi:kimi|*:kimi) printf 'kimi\n'; return 0 ;;
      devin:devin|*:devin) printf 'devin\n'; return 0 ;;
      pi:pi|pi-signed:*|pi-launcher:*|Pi:*|*:pi) printf 'pi\n'; return 0 ;;
    esac
  done
  return 1
}

fm_harness_process_name() {  # <comm> <full argv>
  local comm=$1 args=${2:-} executable script
  executable=${comm##*/}
  fm_harness_executable_name "$executable" && return 0
  case "$executable" in
    node|node[0-9]*|nodejs|python|python[0-9]*)
      script=${args#* }
      [ "$script" != "$args" ] || return 1
      case "$script" in
        \"*) script=${script#\"}; script=${script%%\"*} ;;
        \'*) script=${script#\'}; script=${script%%\'*} ;;
        *) script=${script%% *} ;;
      esac
      fm_harness_script_name "$script"
      ;;
    *) return 1 ;;
  esac
}
