#!/usr/bin/env bash
# Opt-in per-command bridge from repository/no-mistakes shell commands to the
# disposable Azure runner.
#
# FM_AZURE_RUNNER_REMOTE_CLASSES is a comma-separated selection whose entries
# are <command-class>=<resource-class>, for example:
#   test=behavior-heavy,lint=validation-standard
# A missing command class executes locally, preserving today's default.
# Once selected remote, any transport/identity/staging/quota/result failure is
# returned as failure; this bridge never retries the command on the Mac.
# FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES is an explicit comma-separated local
# recovery selection and wins only for the named classes.
#
# Remote execution additionally requires:
#   FM_AZURE_RUNNER_TASK
#   FM_AZURE_RUNNER_GENERATION
#   FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION (must equal FM_AZURE_SUBSCRIPTION_ID)
#
# Usage:
#   fm-azure-runner-dispatch.sh <command-class> -- <argv...>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
COMMAND_CLASS=${1:-}
[ -n "$COMMAND_CLASS" ] || { echo "usage: fm-azure-runner-dispatch.sh <command-class> -- <argv...>" >&2; exit 2; }
shift
[ "${1:-}" = -- ] || { echo "dispatch requires -- before exact command argv" >&2; exit 2; }
shift
[ "$#" -gt 0 ] || { echo "dispatch requires command argv" >&2; exit 2; }
[[ "$COMMAND_CLASS" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || { echo "invalid command class" >&2; exit 2; }

contains_class() {
  local raw=$1 wanted=$2 entry name
  IFS=, read -r -a entries <<<"$raw"
  for entry in "${entries[@]:-}"; do
    name=${entry%%=*}
    [ "$name" = "$wanted" ] && return 0
  done
  return 1
}

resource_for_class() {
  local raw=$1 wanted=$2 entry name resource
  IFS=, read -r -a entries <<<"$raw"
  for entry in "${entries[@]:-}"; do
    name=${entry%%=*}
    resource=${entry#*=}
    if [ "$name" = "$wanted" ]; then
      [ "$resource" != "$entry" ] && [ -n "$resource" ] || return 2
      printf '%s\n' "$resource"
      return 0
    fi
  done
  return 1
}

if contains_class "${FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES:-}" "$COMMAND_CLASS"; then
  printf 'azure-runner dispatch: explicit local recovery selected for %s\n' "$COMMAND_CLASS" >&2
  exec "$@"
fi

if ! contains_class "${FM_AZURE_RUNNER_REMOTE_CLASSES:-}" "$COMMAND_CLASS"; then
  exec "$@"
fi

RESOURCE_CLASS=$(resource_for_class "$FM_AZURE_RUNNER_REMOTE_CLASSES" "$COMMAND_CLASS") || {
  echo "remote command selection must be <command-class>=<resource-class>" >&2
  exit 2
}
: "${FM_AZURE_RUNNER_TASK:?remote class requires FM_AZURE_RUNNER_TASK}"
: "${FM_AZURE_RUNNER_GENERATION:?remote class requires FM_AZURE_RUNNER_GENERATION}"
: "${FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION:?remote class requires FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION}"

exec "$SCRIPT_DIR/fm-azure-runner.sh" run \
  --confirm-run \
  --confirm-subscription "$FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION" \
  --task "$FM_AZURE_RUNNER_TASK" \
  --generation "$FM_AZURE_RUNNER_GENERATION" \
  --resource-class "$RESOURCE_CLASS" \
  -- "$@"
