#!/usr/bin/env bash
# fm-deploy-check.sh - verify that a merged commit actually reached Live on its
# Render service, instead of assuming a merged PR is shipped.
#
# Why this exists: a merge is not shipped until its deploy goes Live. A Render
# service keeps serving the last good build when a new deploy fails, so nothing
# LOOKS broken - mattmccarthy.dev served a stale build for 5 days across 10
# consecutive silently-failed deploys (data/learnings.md "Render - deploys can
# fail silently for days"). The merge poll only watches the PR, never the
# deploy. This helper closes that gap, read-only: it never triggers a deploy or
# changes service state, it only lists deploys and reads boot logs.
#
# Requires the Render CLI (v2.5.0+, logged in) and jq on PATH.
#
# Modes:
#   fm-deploy-check.sh <service|project> <sha>
#       Blocking poll until the deploy for <sha> reaches Live, fails, or a
#       bounded timeout elapses. Prints progress to stderr. On a failed deploy
#       it prints the recent service boot log to stdout so the failure cause
#       (e.g. a missing env var boot guard) is visible. Exit: 0 Live, 3 failed,
#       2 timeout, 4 resolve/usage error.
#
#   fm-deploy-check.sh --once <service|project> <sha>
#       Single non-blocking probe for the watcher check contract
#       (state/<id>.check.sh): prints exactly one line iff the deploy reached a
#       terminal state firstmate should wake on (Live or failed), and stays
#       silent (no output) while the deploy is still pending or not yet created.
#       On a failure it also writes the boot log to $FM_DEPLOY_LOG_OUT when set.
#       Always exits 0 so a transient CLI/network hiccup never wakes firstmate.
#
#   fm-deploy-check.sh --resolve <project>
#       Print the resolved Render service id for a project name and exit.
#
#   fm-deploy-check.sh --arm <task-id> <service|project> <sha>
#       Resolve the service once (loudly, now), record deploy_service=/deploy_sha=
#       into state/<id>.meta, and write state/<id>.check.sh so the watcher polls
#       the deploy on its normal cadence. This replaces the merge poll's single
#       check slot with the post-merge deploy verification.
#
# Service resolution order for the <service|project> argument:
#   1. A literal Render service id (matches ^srv-...) is used as-is.
#   2. A line "<project> <srv-id>" in the local map file
#      ($FM_RENDER_SERVICES_MAP, else $FM_HOME/config/render-services.map). This
#      is the override path; the map is local and gitignored per fleet. See
#      docs/examples/render-services.map for the format.
#   3. Otherwise `render services -o json` is queried and matched by name. IDs
#      drift, so verifying against the live service list at runtime is the cheap
#      fallback when the map has no entry.
# Resolution failure exits 4; it never guesses a service.
#
# Deploy classification (docs/render-deploy-verification.md owns the full table):
#   success  - any deploy for <sha> reached live or inactive (both built and
#              served; inactive just means a newer deploy has since replaced it)
#   failed   - newest deploy for <sha> is build_failed/update_failed/
#              pre_deploy_failed/canceled and none reached a served state
#   pending  - newest deploy is created/queued/*_in_progress, or no deploy for
#              <sha> exists yet (not created)
#   other    - any other status (e.g. deactivated); surfaced, never silently Live
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

RENDER_BIN="${FM_RENDER_BIN:-render}"
POLL_INTERVAL="${FM_DEPLOY_POLL_INTERVAL:-15}"
POLL_TIMEOUT="${FM_DEPLOY_TIMEOUT:-900}"
LOG_LINES="${FM_DEPLOY_LOG_LINES:-50}"

usage() {
  echo "usage: fm-deploy-check.sh [--once|--resolve|--arm] <service|project> <sha> ..." >&2
  exit 4
}

# resolve_service <service-or-project> -> prints a srv- id or exits 4.
resolve_service() {
  local arg=$1 map line name id
  case "$arg" in
    srv-*)
      printf '%s\n' "$arg"
      return 0
      ;;
  esac

  map="${FM_RENDER_SERVICES_MAP:-$FM_HOME/config/render-services.map}"
  if [ -f "$map" ]; then
    # Lines: "<project> <srv-id>"; '#' comments and blanks ignored.
    while read -r name id _rest; do
      case "$name" in ''|'#'*) continue ;; esac
      if [ "$name" = "$arg" ] && [ -n "$id" ]; then
        printf '%s\n' "$id"
        return 0
      fi
    done < "$map"
  fi

  # Runtime fallback: match the live service list by name. `render services
  # -o json` wraps each resource under a type key, so a web service's name/id
  # live under .service.
  if command -v "$RENDER_BIN" >/dev/null 2>&1; then
    line=$("$RENDER_BIN" services -o json --confirm 2>/dev/null \
      | jq -r --arg n "$arg" 'map(select(.service.name == $n)) | .[0].service.id // empty' 2>/dev/null || true)
    if [ -n "$line" ] && [ "$line" != "null" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi

  echo "error: no Render service mapped for '$arg' (add it to ${map} or pass a srv- id)" >&2
  return 4
}

# probe_status <service> <sha> -> one classification word plus optional detail:
#   live | failed <status> <depid> | pending | other <status> <depid> | none
# Any CLI/jq failure degrades to "pending" so callers keep waiting rather than
# treating a transient hiccup as terminal.
probe_status() {
  local service=$1 sha=$2 json result
  json=$("$RENDER_BIN" deploys list "$service" -o json --confirm 2>/dev/null || true)
  [ -n "$json" ] || { echo pending; return 0; }
  result=$(printf '%s' "$json" | jq -r --arg sha "$sha" '
    ( if type == "array" then . else [] end )
    | [ .[] | select((.commit.id // "") | startswith($sha)) ] as $m
    | if ($m | length) == 0 then "none"
      elif any($m[]; .status == "live" or .status == "inactive") then "live"
      else ($m | sort_by(.createdAt) | last) as $n
        | ($n.status // "unknown") as $s | ($n.id // "?") as $id
        | if ($s | IN("build_failed","update_failed","pre_deploy_failed","canceled"))
            then "failed \($s) \($id)"
          elif ($s | IN("created","queued","build_in_progress","update_in_progress","pre_deploy_in_progress"))
            then "pending"
          else "other \($s) \($id)" end
      end' 2>/dev/null || true)
  [ -n "$result" ] || result=pending
  printf '%s\n' "$result"
}

# fetch_boot_log <service> -> recent service logs, best-effort (never fatal).
fetch_boot_log() {
  local service=$1
  "$RENDER_BIN" logs -r "$service" -o text --limit "$LOG_LINES" --direction backward --confirm 2>/dev/null \
    || echo "(boot log unavailable; run: $RENDER_BIN logs -r $service -o text --limit $LOG_LINES)"
}

# --- mode: --resolve --------------------------------------------------------
if [ "${1:-}" = "--resolve" ]; then
  [ $# -eq 2 ] || usage
  resolve_service "$2"
  exit $?
fi

# --- mode: --arm ------------------------------------------------------------
if [ "${1:-}" = "--arm" ]; then
  [ $# -eq 4 ] || usage
  id=$2
  service=$(resolve_service "$3") || exit 4
  sha=$4
  meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    grep -qxF "deploy_service=$service" "$meta" || echo "deploy_service=$service" >> "$meta"
    grep -qxF "deploy_sha=$sha" "$meta" || echo "deploy_sha=$sha" >> "$meta"
  fi
  # The generated check runs --once every watcher check sweep; the watcher's
  # cadence is the poll loop, so this stays a single cheap probe per sweep.
  cat > "$STATE/$id.check.sh" <<EOF
FM_DEPLOY_LOG_OUT="$STATE/$id.deploy-log" \\
  "$SCRIPT_DIR/fm-deploy-check.sh" --once "$service" "$sha"
EOF
  echo "armed: state/$id.check.sh verifies $sha reaches Live on $service"
  exit 0
fi

# --- mode: --once (watcher check contract) ----------------------------------
if [ "${1:-}" = "--once" ]; then
  [ $# -eq 3 ] || usage
  service=$(resolve_service "$2" 2>/dev/null) || exit 0
  sha=$3
  read -r kind status depid <<EOF
$(probe_status "$service" "$sha")
EOF
  case "$kind" in
    live)
      echo "deploy live: $sha on $service"
      ;;
    failed)
      if [ -n "${FM_DEPLOY_LOG_OUT:-}" ]; then
        fetch_boot_log "$service" > "$FM_DEPLOY_LOG_OUT" 2>/dev/null || true
        echo "deploy FAILED: $sha on $service ($status, $depid) - boot log: $FM_DEPLOY_LOG_OUT"
      else
        echo "deploy FAILED: $sha on $service ($status, $depid)"
      fi
      ;;
    *)
      : # pending / other / none: stay silent, keep sleeping
      ;;
  esac
  exit 0
fi

# --- default mode: blocking poll --------------------------------------------
[ $# -eq 2 ] || usage
service=$(resolve_service "$1") || exit 4
sha=$2
deadline=$(( $(date +%s) + POLL_TIMEOUT ))
echo "polling $service for deploy of $sha (timeout ${POLL_TIMEOUT}s)..." >&2
while :; do
  read -r kind status depid <<EOF
$(probe_status "$service" "$sha")
EOF
  case "$kind" in
    live)
      echo "Live: $sha is serving on $service" >&2
      exit 0
      ;;
    failed)
      echo "FAILED: deploy $depid for $sha is $status on $service" >&2
      echo "--- recent boot log ($service) ---"
      fetch_boot_log "$service"
      exit 3
      ;;
    none)
      echo "  no deploy for $sha yet; waiting..." >&2
      ;;
    pending)
      echo "  deploy in progress; waiting..." >&2
      ;;
    *)
      echo "  status $status ($depid); waiting..." >&2
      ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "TIMEOUT: $sha did not reach Live on $service within ${POLL_TIMEOUT}s (last: $kind $status)" >&2
    exit 2
  fi
  sleep "$POLL_INTERVAL"
done
