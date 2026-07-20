#!/usr/bin/env bash
# fm-effort-board-loop.sh - one always-on Lavish board cycle.
#
# This is not a daemon.
# One invocation performs one bounded cycle:
#   1. re-ingest efforts into this checkout's data/efforts ledger,
#   2. render the self-contained Lavish board,
#   3. open or refresh it with `lavish-axi <html-file>`,
#   4. wait once for `lavish-axi poll <html-file>` bounded by --timeout seconds,
#   5. emit captain_decision ledger events for any queued decision prompts.
#
# Poll renewal belongs to the caller, which can invoke this script again as a
# tracked background job.
# Lavish itself has no normal timeout flag, so the bound is implemented outside
# `lavish-axi poll` with a small Perl alarm wrapper.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
EFFORT="$SCRIPT_DIR/fm-effort.sh"
LAVISH_RENDER="$SCRIPT_DIR/fm-effort-lavish.sh"
DEFAULT_HTML="$FM_ROOT/.lavish/fm-effort-captain-board.html"
NOW="${FM_EFFORT_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: fm-effort-board-loop.sh --home <firstmate-home> [--inventory <inventory.json>] [--repo-allowlist <patterns>] [--html <html>] [--timeout <secs>]

Runs one bounded always-on board cycle and exits.
Decision output lines are JSON prefixed with FM_EFFORT_DECISION.
EOF
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

run_poll_bounded() {  # <timeout-secs> <html> <out>
  local timeout_secs=$1 html=$2 out=$3
  perl -e '
    my $timeout = shift @ARGV;
    $SIG{ALRM} = sub { exit 124 };
    alarm($timeout);
    exec @ARGV;
  ' "$timeout_secs" lavish-axi poll "$html" > "$out" 2>&1
}

parse_poll_decisions() {  # <poll-output> <out-tsv>
  perl -ne '
    while (/FM_EFFORT_DECISION\s+effort_id=([^[:space:]"\\]+)\s+option=([^[:space:]"\\]+)\s+kind=([^[:space:]"\\]+)/g) {
      print "$1\t$2\t$3\n";
    }
  ' "$1" | awk '!seen[$0]++' > "$2"
}

target_stage_for() {  # <kind> <option>
  local kind=$1 option=$2
  case "$option" in
    APPROVE_MERGE_WORD)
      if [ "$kind" = merge_word ]; then printf 'merge_ready\n'; else printf 'in_progress\n'; fi
      ;;
    CHANGES_REQUESTED) printf 'in_progress\n' ;;
    PARK) printf 'blocked\n' ;;
    CLOSE_AS_OBSOLETE) printf 'abandoned\n' ;;
    *) printf 'needs_captain\n' ;;
  esac
}

emit_decision() {  # <html> <effort-id> <option> <kind>
  local html=$1 effort_id=$2 option=$3 kind=$4 to_stage decision_json output
  to_stage=$(target_stage_for "$kind" "$option")
  decision_json=$(jq -cn \
    --arg kind "$kind" \
    --arg option "$option" \
    --arg question "Lavish decision for $effort_id" \
    --arg at "$NOW" \
    '{
      kind:$kind,
      question:$question,
      recommendation:$option,
      selected:$option,
      options:["APPROVE_MERGE_WORD","CHANGES_REQUESTED","PARK","CLOSE_AS_OBSOLETE"],
      decided_at:$at,
      source:"fm-effort-lavish"
    }')
  "$EFFORT" emit \
    --effort-id "$effort_id" \
    --kind captain_decision \
    --actor captain \
    --to-stage "$to_stage" \
    --evidence "$html" \
    --note "lavish decision: $option" \
    --decision-json "$decision_json" >/dev/null
  output=$(jq -cn \
    --arg effort_id "$effort_id" \
    --arg option "$option" \
    --arg kind "$kind" \
    --arg to_stage "$to_stage" \
    --arg ledger "$("$EFFORT" list --json >/dev/null 2>&1; printf '%s' "${FM_EFFORT_LEDGER_OVERRIDE:-$FM_ROOT/data/efforts/ledger.jsonl}")" \
    '{effort_id:$effort_id, option:$option, kind:$kind, to_stage:$to_stage, ledger:$ledger}')
  printf 'FM_EFFORT_DECISION %s\n' "$output"
}

main() {
  need_tool jq
  need_tool lavish-axi
  need_tool perl

  local home="" inventory="" repo_allowlist="" html=$DEFAULT_HTML timeout_secs=3300 poll_out decisions effort_id option kind
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) [ $# -ge 2 ] || die "--home needs a value"; home=$2; shift 2 ;;
      --inventory) [ $# -ge 2 ] || die "--inventory needs a value"; inventory=$2; shift 2 ;;
      --repo-allowlist) [ $# -ge 2 ] || die "--repo-allowlist needs a value"; repo_allowlist=$2; shift 2 ;;
      --html) [ $# -ge 2 ] || die "--html needs a value"; html=$2; shift 2 ;;
      --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout_secs=$2; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  [ -n "$home" ] || die "--home is required"
  case "$timeout_secs" in ''|*[!0-9]*) die "--timeout must be a positive integer" ;; esac
  [ "$timeout_secs" -gt 0 ] || die "--timeout must be positive"

  if [ -n "$inventory" ]; then
    "$EFFORT" ingest all --home "$home" --inventory "$inventory" --repo-allowlist "$repo_allowlist"
    "$LAVISH_RENDER" --inventory "$inventory" --repo-allowlist "$repo_allowlist" --output "$html"
  else
    "$EFFORT" ingest all --home "$home"
    "$LAVISH_RENDER" --output "$html"
  fi
  lavish-axi "$html"

  poll_out=$(mktemp "${TMPDIR:-/tmp}/fm-effort-lavish-poll.XXXXXX")
  decisions=$(mktemp "${TMPDIR:-/tmp}/fm-effort-lavish-decisions.XXXXXX")
  if run_poll_bounded "$timeout_secs" "$html" "$poll_out"; then
    :
  else
    code=$?
    if [ "$code" -eq 124 ]; then
      printf 'poll_timeout: seconds=%s html=%s\n' "$timeout_secs" "$html"
      rm -f "$poll_out" "$decisions"
      exit 0
    fi
    cat "$poll_out" >&2
    rm -f "$poll_out" "$decisions"
    exit "$code"
  fi

  parse_poll_decisions "$poll_out" "$decisions"
  if [ ! -s "$decisions" ]; then
    cat "$poll_out"
    rm -f "$poll_out" "$decisions"
    exit 0
  fi
  while IFS="$(printf '\t')" read -r effort_id option kind; do
    [ -n "$effort_id" ] || continue
    emit_decision "$html" "$effort_id" "$option" "$kind"
  done < "$decisions"
  rm -f "$poll_out" "$decisions"
}

main "$@"
