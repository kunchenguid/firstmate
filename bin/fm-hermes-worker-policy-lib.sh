#!/usr/bin/env bash
# Recursive active-fleet policy validation for a Hermes primary.

FM_HERMES_POLICY_VISITED=${FM_HERMES_POLICY_VISITED:-}

fm_hermes_policy_meta_value() {  # <meta> <key>
  awk -v key="$2" '
    index($0, key "=") == 1 { count++; value=substr($0, length(key) + 2) }
    END {
      if (count == 1) print value
      else if (count > 1) exit 2
      else exit 1
    }
  ' "$1"
}

fm_hermes_policy_check_home() {  # <home> [state] [remote-callback]
  local home=$1 state=${2:-$1/state} remote_callback=${3:-}
  local canonical meta id harness backend remote_backend remote_host kind child_home rc
  [ -d "$home" ] && [ ! -L "$home" ] || {
    echo "error: Hermes worker policy cannot inspect unsafe home: $home" >&2
    return 1
  }
  canonical=$(cd "$home" && pwd -P) || return 1
  case "$FM_HERMES_POLICY_VISITED" in *$'\n'"$canonical"$'\n'*) return 0 ;; esac
  FM_HERMES_POLICY_VISITED="${FM_HERMES_POLICY_VISITED}"$'\n'"$canonical"$'\n'
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ] || {
      echo "error: Hermes worker policy refuses unsafe state directory: $state" >&2
      return 1
    }
  else
    return 0
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || {
      echo "error: Hermes worker policy refuses unsafe active task record: $meta" >&2
      return 1
    }
    id=$(basename "$meta" .meta)
    harness=$(fm_hermes_policy_meta_value "$meta" harness 2>/dev/null) || {
      echo "error: Hermes worker policy requires active task $id to name harness=pi" >&2
      return 1
    }
    [ "$harness" = pi ] || {
      echo "error: Hermes worker policy refuses active task $id with harness=$harness" >&2
      return 1
    }
    kind=$(fm_hermes_policy_meta_value "$meta" kind 2>/dev/null || true)
    remote_host=$(fm_hermes_policy_meta_value "$meta" remote_host 2>/dev/null || true)
    if [ -n "$remote_host" ]; then
      [ "$kind" = secondmate ] || {
        echo "error: Hermes worker policy refuses non-secondmate remote task $id" >&2
        return 1
      }
      remote_backend=$(fm_hermes_policy_meta_value "$meta" remote_backend 2>/dev/null) || {
        echo "error: Hermes worker policy requires remote secondmate $id to name remote_backend=herdr" >&2
        return 1
      }
      [ "$remote_backend" = herdr ] || {
        echo "error: Hermes worker policy refuses remote secondmate $id with remote_backend=$remote_backend" >&2
        return 1
      }
      [ -n "$remote_callback" ] || {
        echo "error: Hermes worker policy cannot inspect remote secondmate $id" >&2
        return 1
      }
      "$remote_callback" "$id" || return 1
      continue
    fi
    rc=0
    backend=$(fm_hermes_policy_meta_value "$meta" backend 2>/dev/null) || rc=$?
    case "$rc" in
      0) ;;
      1) backend=tmux ;;
      *)
        echo "error: Hermes worker policy requires one unambiguous backend for active task $id" >&2
        return 1
        ;;
    esac
    [ "$backend" = herdr ] || {
      echo "error: Hermes worker policy refuses active task $id with backend=$backend" >&2
      return 1
    }
    [ "$kind" = secondmate ] || continue
    child_home=$(fm_hermes_policy_meta_value "$meta" home 2>/dev/null) || {
      echo "error: Hermes worker policy requires secondmate $id to name its home" >&2
      return 1
    }
    fm_hermes_policy_check_home "$child_home" "$child_home/state" "$remote_callback" || return 1
  done
}
