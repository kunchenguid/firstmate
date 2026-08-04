#!/usr/bin/env bash
# Automatic pull-request review adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-pr-review.sh arm
#   fm-procevent-pr-review.sh source
#   fm-procevent-pr-review.sh classify <result-file>
#   fm-procevent-pr-review.sh terminal <result-file>
#   fm-procevent-pr-review.sh source-id
#   fm-procevent-pr-review.sh retire
#
# The registered source blocks until the durable slow-poll deadline, performs one
# bounded gh-axi inventory, and exits with no result when nothing needs model
# attention. A result is only a bounded private notification that durable queue
# work or one deduplicated diagnostic exists; feedback bodies and response text
# never enter the wake queue. Every captured result classifies terminal, so the
# generic runner retires this registration; coverage resumes when the adjudication
# owner acknowledges the event and re-arms, or when a locked bootstrap re-arms.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

classify() {
  local file=$1 schema category pending responses
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'malformed\n'; return; }
  schema=$(node -e '
    const fs=require("fs");
    try { const x=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      if (x.schema!=="fm-pr-review-event.v1" || !/^[0-9]{1,18}-[0-9a-f]{16}$/.test(x.event_id)
        || !/^[a-z][a-z-]{0,31}$/.test(x.category)
        || !Number.isSafeInteger(x.changed) || x.changed<0
        || !Number.isSafeInteger(x.pending) || x.pending<0
        || !Number.isSafeInteger(x.response_pending) || x.response_pending<0
        || !Number.isSafeInteger(x.degraded ?? 0) || (x.degraded ?? 0)<0
        || typeof x.message!=="string" || x.message.length>1000) process.exit(2);
      process.stdout.write([x.category,x.pending,x.response_pending].join("\t"));
    } catch { process.exit(2); }
  ' "$file" 2>/dev/null) || { printf 'malformed\n'; return; }
  IFS=$(printf '\t') read -r category pending responses <<EOF
$schema
EOF
  case "$pending:$responses" in *[!0-9:]*) printf 'malformed\n'; return ;; esac
  case "$category" in inventory) printf 'work\n' ;; *) printf 'diagnostic\n' ;; esac
}

case "${1-}" in
  arm)
    [ "$#" -eq 1 ] || usage
    "$SCRIPT_DIR/fm-pr-review.sh" arm
    ;;
  source)
    [ "$#" -eq 1 ] || usage
    exec "$SCRIPT_DIR/fm-pr-review.sh" source
    ;;
  classify)
    [ "$#" -eq 2 ] || usage
    classify "$2"
    ;;
  terminal)
    [ "$#" -eq 2 ] || usage
    verdict=$(classify "$2")
    [ "$verdict" = work ] || [ "$verdict" = diagnostic ]
    ;;
  source-id)
    [ "$#" -eq 1 ] || usage
    "$SCRIPT_DIR/fm-pr-review.sh" source-id
    ;;
  retire)
    [ "$#" -eq 1 ] || usage
    sid=$("$SCRIPT_DIR/fm-pr-review.sh" source-id) || die "cannot derive source identity"
    "$SCRIPT_DIR/fm-procevent.sh" retire "$sid"
    ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
