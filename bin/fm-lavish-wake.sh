#!/usr/bin/env bash
# Append one durable Lavish answer pointer through Firstmate's canonical wake
# queue lock, then attempt redundant visible delivery to the home-bound
# supervisor proven by the session lock.
#
# This is the narrow adapter used by the provider-neutral tools/lavish package.
# The answer file remains authoritative; visible delivery failure never weakens
# the durable record surfaced at the next ordinary wake drain.
#
# Usage:
#   fm-lavish-wake.sh --home <FM_HOME> --decision <id> \
#     --answer <absolute-answer.toon> --digest <sha256:hex> \
#     --destination <FM_HOME-relative-path>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOME_ARG=
DECISION=
ANSWER=
DIGEST=
DESTINATION=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) HOME_ARG=${2:-}; shift 2 ;;
    --decision) DECISION=${2:-}; shift 2 ;;
    --answer) ANSWER=${2:-}; shift 2 ;;
    --digest) DIGEST=${2:-}; shift 2 ;;
    --destination) DESTINATION=${2:-}; shift 2 ;;
    *) printf 'fm-lavish-wake: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$HOME_ARG" ] || { echo "fm-lavish-wake: --home is required" >&2; exit 2; }
[ -n "$DECISION" ] || { echo "fm-lavish-wake: --decision is required" >&2; exit 2; }
[ -n "$ANSWER" ] || { echo "fm-lavish-wake: --answer is required" >&2; exit 2; }
[ -n "$DIGEST" ] || { echo "fm-lavish-wake: --digest is required" >&2; exit 2; }
[ -n "$DESTINATION" ] || { echo "fm-lavish-wake: --destination is required" >&2; exit 2; }

case "$DECISION" in
  [a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9]) ;;
  *) echo "fm-lavish-wake: invalid decision id" >&2; exit 2 ;;
esac
[ "${#DECISION}" -le 64 ] || { echo "fm-lavish-wake: invalid decision id" >&2; exit 2; }
case "$DIGEST" in
  sha256:*) ;;
  *) echo "fm-lavish-wake: invalid answer digest" >&2; exit 2 ;;
esac
hex=${DIGEST#sha256:}
case "$hex" in
  ''|*[!0-9a-f]*) echo "fm-lavish-wake: invalid answer digest" >&2; exit 2 ;;
esac
[ "${#hex}" -eq 64 ] || { echo "fm-lavish-wake: invalid answer digest" >&2; exit 2; }
case "$DESTINATION" in
  data/?*) ;;
  *) echo "fm-lavish-wake: invalid destination" >&2; exit 2 ;;
esac
case "$DESTINATION" in
  /*|*\\*|*/|*//*|*/./*|*/../*|*$'\n'*|*$'\r'*)
    echo "fm-lavish-wake: invalid destination" >&2
    exit 2
    ;;
esac

[ -d "$HOME_ARG" ] && [ ! -L "$HOME_ARG" ] \
  || { echo "fm-lavish-wake: unsafe FM_HOME" >&2; exit 2; }
FM_HOME=$(cd "$HOME_ARG" && pwd -P)
STATE_ARG=${FM_STATE_OVERRIDE:-$FM_HOME/state}
mkdir -p "$STATE_ARG"
[ -d "$STATE_ARG" ] && [ ! -L "$STATE_ARG" ] \
  || { echo "fm-lavish-wake: unsafe state directory" >&2; exit 2; }
FM_STATE_OVERRIDE=$(cd "$STATE_ARG" && pwd -P)
EXPECTED="$FM_HOME/data/decisions/$DECISION/answer.toon"
[ -d "$(dirname "$ANSWER")" ] \
  || { echo "fm-lavish-wake: answer directory is missing" >&2; exit 2; }
ANSWER_CANONICAL="$(cd "$(dirname "$ANSWER")" && pwd -P)/$(basename "$ANSWER")"
[ "$ANSWER_CANONICAL" = "$EXPECTED" ] \
  || { echo "fm-lavish-wake: answer path does not match decision" >&2; exit 2; }
[ -f "$ANSWER_CANONICAL" ] && [ ! -L "$ANSWER_CANONICAL" ] \
  || { echo "fm-lavish-wake: answer is not a safe regular file" >&2; exit 2; }
if command -v shasum >/dev/null 2>&1; then
  actual="sha256:$(shasum -a 256 "$ANSWER_CANONICAL" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="sha256:$(sha256sum "$ANSWER_CANONICAL" | awk '{print $1}')"
else
  echo "fm-lavish-wake: no SHA-256 tool is available" >&2
  exit 2
fi
[ "$actual" = "$DIGEST" ] \
  || { echo "fm-lavish-wake: answer digest does not match file" >&2; exit 2; }

export FM_HOME FM_STATE_OVERRIDE
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

relative=${ANSWER_CANONICAL#"$FM_HOME/"}
fm_wake_append \
  signal \
  "lavish:$DECISION" \
  "decision-answer: $relative $DIGEST"

if [ "${FM_LAVISH_QUEUE_DISABLE:-}" = 1 ]; then
  printf 'lavish-delivery: prompt queue disabled for %s\n' "$DECISION"
  exit 0
fi

queue_out=$("$SCRIPT_DIR/fm-lavish-queue.sh" \
  --home "$FM_HOME" \
  --decision "$DECISION" \
  --answer "$ANSWER_CANONICAL" \
  --digest "$DIGEST" \
  --destination "$DESTINATION" 2>&1) || queue_status=$?
if [ "${queue_status:-0}" -eq 0 ]; then
  printf '%s\n' "$queue_out"
else
  printf 'lavish-delivery: prompt not queued for %s: %s\n' "$DECISION" "$queue_out"
fi
