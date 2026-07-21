#!/usr/bin/env bash
# fm-provider-hold.sh - durable provider exhaustion holds.
#
# A hold records that a provider's quota/rate exhaustion was VERIFIED (by
# bin/fm-failover.sh evidence or an explicit captain instruction) and blocks
# every NEW launch on that provider until recovery is verified: fm-spawn.sh
# refuses a launch whose resolved (harness, model) route lands on a held
# provider, and fm-failover.sh skips held destination candidates without
# probing them. The hold is deliberately independent of any quota cache or
# dispatch-selection data, so a stale quota read can never re-open a held
# provider.
#
# Usage:
#   fm-provider-hold.sh list
#       Print one line per active hold: "<provider> held since <date>: <detail>".
#   fm-provider-hold.sh set <provider> [--task <id>] [--evidence <text>]
#       Record a hold (idempotent; refreshes the detail).
#   fm-provider-hold.sh release <provider> [--force]
#       Verify recovery with a live bounded probe of the provider and remove
#       the hold ONLY when the probe succeeds. A failed probe keeps the hold
#       and exits non-zero. --force skips the probe and requires explicit
#       captain authority; never use it on your own judgment.
#
# Providers and their release probes (each a bounded, task-free model call in
# a scratch directory; FM_FAILOVER_PROBE_TIMEOUT bounds it, default 90s):
#   openai     codex exec 'Reply with exactly OK.'
#   anthropic  claude -p 'Reply with exactly OK.'
#   ollama     pi --print --model "$FM_PROVIDER_PROBE_MODEL_OLLAMA" (default
#              ollama/glm-5.2) 'Reply with exactly OK.'
# Any other provider has no verified probe; release requires --force.
#
# Hold files live at state/.provider-hold-<provider>; docs/provider-failover.md
# owns the surrounding mechanism narrative.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-failover-lib.sh
. "$SCRIPT_DIR/fm-failover-lib.sh"

usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"; }

CMD=${1:-}
case "$CMD" in
  -h|--help|'') usage; [ -n "$CMD" ] && exit 0 || exit 2 ;;
esac
shift

PROBE_TIMEOUT=${FM_FAILOVER_PROBE_TIMEOUT:-90}
case "$PROBE_TIMEOUT" in ''|*[!0-9]*) PROBE_TIMEOUT=90 ;; esac

bounded_run() {  # <seconds> <cmd...>
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"
  fi
}

case "$CMD" in
  list)
    found=0
    for hold in "$STATE"/.provider-hold-*; do
      [ -e "$hold" ] || continue
      found=1
      provider=${hold##*/.provider-hold-}
      printf '%s %s\n' "$provider" "$(head -1 "$hold" 2>/dev/null)"
    done
    [ "$found" = 1 ] || echo "no active provider holds"
    exit 0
    ;;
  set)
    PROVIDER=${1:-}
    shift || true
    TASK=
    EVIDENCE=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) shift; TASK=${1:-} ;;
        --evidence) shift; EVIDENCE=${1:-} ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
      esac
      shift || true
    done
    fm_failover_provider_name_valid "$PROVIDER" || { echo "error: invalid provider name" >&2; exit 2; }
    mkdir -p "$STATE"
    HOLD=$(fm_failover_hold_path "$STATE" "$PROVIDER")
    TMP=$(mktemp "$STATE/.provider-hold-tmp.XXXXXX") || exit 1
    printf 'held since %s epoch=%s task=%s evidence=%s\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date +%s)" "${TASK:-none}" "${EVIDENCE:-unspecified}" > "$TMP" || { rm -f "$TMP"; exit 1; }
    mv "$TMP" "$HOLD" || { rm -f "$TMP"; exit 1; }
    echo "held: provider $PROVIDER - new launches on this provider will be refused until 'fm-provider-hold.sh release $PROVIDER' verifies recovery"
    exit 0
    ;;
  release)
    PROVIDER=${1:-}
    shift || true
    FORCE=0
    [ "${1:-}" = --force ] && FORCE=1
    fm_failover_provider_name_valid "$PROVIDER" || { echo "error: invalid provider name" >&2; exit 2; }
    HOLD=$(fm_failover_hold_path "$STATE" "$PROVIDER")
    if [ ! -e "$HOLD" ]; then
      echo "no active hold for provider $PROVIDER"
      exit 0
    fi
    if [ "$FORCE" = 1 ]; then
      rm -f "$HOLD"
      echo "released: provider $PROVIDER (FORCED - recovery was NOT verified; captain authority required for this path)"
      exit 0
    fi
    PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-provider-probe.XXXXXX") || exit 1
    trap '[ -z "${PROBE_DIR:-}" ] || rm -rf "$PROBE_DIR"' EXIT
    code=0
    case "$PROVIDER" in
      openai)
        command -v codex >/dev/null 2>&1 || { echo "error: codex CLI not installed; cannot verify openai recovery" >&2; exit 1; }
        OUT=$( (cd "$PROBE_DIR" && bounded_run "$PROBE_TIMEOUT" codex exec 'Reply with exactly OK.') 2>&1 ) || code=$?
        ;;
      anthropic)
        command -v claude >/dev/null 2>&1 || { echo "error: claude CLI not installed; cannot verify anthropic recovery" >&2; exit 1; }
        OUT=$( (cd "$PROBE_DIR" && bounded_run "$PROBE_TIMEOUT" claude -p 'Reply with exactly OK.') 2>&1 ) || code=$?
        ;;
      ollama)
        command -v pi >/dev/null 2>&1 || { echo "error: pi CLI not installed; cannot verify ollama recovery" >&2; exit 1; }
        OUT=$( (cd "$PROBE_DIR" && bounded_run "$PROBE_TIMEOUT" pi --print --model "${FM_PROVIDER_PROBE_MODEL_OLLAMA:-ollama/glm-5.2}" 'Reply with exactly OK.') 2>&1 ) || code=$?
        ;;
      *)
        echo "error: no verified recovery probe for provider '$PROVIDER'; release requires --force with explicit captain authority" >&2
        exit 1
        ;;
    esac
    if [ "$code" = 0 ]; then
      rm -f "$HOLD"
      echo "released: provider $PROVIDER (recovery verified by live probe)"
      exit 0
    fi
    echo "error: provider $PROVIDER recovery probe failed (exit $code: $(printf '%s' "$OUT" | head -1 | cut -c1-200)); hold kept" >&2
    exit 1
    ;;
  *)
    echo "error: unknown command '$CMD'" >&2
    usage >&2
    exit 2
    ;;
esac
