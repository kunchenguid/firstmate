#!/usr/bin/env bash
# fm-usage-wall.sh - the provider usage wall: see it coming, diagnose it when it
# lands, and read back what was in flight when it did.
#
# Usage: fm-usage-wall.sh headroom [--json]
#        fm-usage-wall.sh diagnose <task-id> [--endpoint-only]
#        fm-usage-wall.sh resume [--print] [--out <path>]
#
# A provider usage limit is not a crash, and that single confusion is what makes
# it expensive. The harness exits non-zero, the pipeline run goes terminal
# failed, every worker on that account dies inside the same minute, and the
# recorded evidence reads exactly like a fleet-wide failure. It is not one: the
# work is intact on disk, the branches are intact, and the pipeline is holding
# fix commits the worktrees never saw. Reconstructing that by hand costs an hour
# it should never cost, so the three things that hour buys are commands here:
#
#   headroom   read the gauge BEFORE dispatching, and never read an unmeasured
#              gauge as a healthy one.
#   diagnose   decide from evidence whether a stranded task hit the wall or
#              actually failed, so the two are never confused again.
#   resume     regenerate, from live durable state, exactly what a recovery
#              needs to know about every task in flight.
#
# This command decides NOTHING about what to run. It reports; firstmate and the
# captain choose. There is deliberately no budgeting, scheduling, throttling, or
# admission policy here, and the `tight` label below is presentation only - it
# never gates, blocks, or reorders a dispatch.
#
# The recovery PROCEDURE is not here either: .agents/skills/usage-limit-recovery
# owns it. This script owns the data that procedure reads. Neither restates the
# other.
#
# --- headroom ---------------------------------------------------------------
#
# Reads `quota-axi`'s default TOON, which is the surface AGENTS.md section 4
# already makes the dispatch-facing one, and the only surface that carries the
# derived `effective` headroom block: at the observed build (0.1.17) `quota-axi
# --json` is schemaVersion 3 and carries raw provider windows only, with no
# effective-headroom, status, or authStatus fields at all. So there is no JSON
# fallback here - a JSON read could not answer the question this command asks.
# The TOON block is parsed BY FIELD NAME out of its own declared header, never
# by column position, so a provider, window, or field added upstream shifts
# nothing.
#
# UNMEASURABLE IS UNKNOWN, NEVER FINE. This is the whole point of the command,
# so it is structural rather than conventional: a reading is emitted only from a
# present, parseable `effective` row whose `effectivePercentRemaining` is a
# number. Every other outcome - quota-axi absent, the call timing out, the
# effective block missing, the scope unresolved, a provider needing
# authentication - prints `unknown` with the concrete reason. There is no code
# path from a failed read to `ok`.
#
# It never prompts. `quota-axi` returns auth_required and unknown headroom until
# the operator approves keychain access once, and the command that does that
# (`quota-axi --allow-keychain-prompt`) blocks on a GUI dialog - fatal on the
# session-start path, which runs inside a bounded session-open hook. So this
# command runs quota-axi WITHOUT that flag, always, and names the flag in the
# unknown line as the one-time operator action instead.
#
# It reports below-floor builds rather than suppressing them. bin/fm-quota-axi-lib.sh
# owns FM_QUOTA_AXI_MIN for the dispatch-profile feature and bin/fm-bootstrap.sh
# owns turning a failing check into the operator MISSING diagnostic. A gauge that
# blanked itself to `unknown` on an older-but-working build would be a false
# negative in exactly the situation it exists for, so a parseable reading is
# still reported and the summary carries `build=below-floor(<min>)` so the
# reading is never mistaken for a fully supported one.
#
# --- diagnose ---------------------------------------------------------------
#
# Answers one question about one task: is this stranding a usage wall?
# Evidence, cheapest first, stopping at the first positive:
#   1. the recorded endpoint's captured output (the harness prints the limit
#      line into its own terminal before exiting);
#   2. the no-mistakes step logs of the run attributed to this task's worktree
#      (the 2026-08-23 incident's evidence was here and NOT in the run status:
#      both the review and test step logs ended on the vendor limit line, while
#      `status: failed` looked like a code verdict and was not one).
#
# Verdicts are deliberately three, not two:
#   wall          a signature matched; the quoted line and its source are printed.
#   no-signature  evidence was read and nothing matched. This is NOT a claim that
#                 the task crashed - only that no wall signature is present in
#                 what was readable.
#   unknown       the evidence could not be read at all. A step log that failed
#                 to read lands here (`reason=step-log-unreadable`), never on
#                 `no-signature`, because "nothing matched" is a claim about
#                 evidence that was actually read.
# A negative therefore never hardens into "it really failed", which matters
# because the signature table below is only as complete as the vendor phrasings
# actually observed.
#
# --- resume -----------------------------------------------------------------
#
# Regenerates the resume record from live durable state. The record is GENERATED,
# never hand-authored, and that is the design point: a hand-written plan is stale
# the moment anything moves, is lost with the session that wrote it, and only
# exists at all if someone remembered to write it. Everything this record needs
# is already on disk and none of it dies with the agent - task metadata,
# worktrees, branches, merge posture, delivered instructions, open captain calls
# - so regenerating on demand is not merely as good as a pre-wall snapshot, it is
# strictly better: it cannot be stale, and it is available to a session that has
# never seen the wall coming.
#
# It composes rather than re-parses: bin/fm-fleet-snapshot.sh is the declared
# owner of structured fleet state and supplies identity, merge posture, current
# state, endpoint, PR, and open captain calls. This command adds only what that
# snapshot does not carry and a recovery needs: the worktree's branch, head, and
# dirty count; the attributed pipeline run and its branch custody; and the
# steering records the worker has and has not acknowledged.
#
# Read-only apart from its own output file. It acquires no lock, drains no wakes,
# touches no task, and never runs `no-mistakes axi sync`, `respond`, or any other
# state-changing pipeline command - returning custody belongs to the worker that
# owns the branch (AGENTS.md section 7), not to the process writing a record
# about it.
#
# Tunables (env):
#   FM_USAGE_WALL_QUOTA_TIMEOUT     bound on the quota-axi read (default 20s)
#   FM_USAGE_WALL_NM_TIMEOUT        bound on each no-mistakes read (default 20s)
#   FM_USAGE_WALL_SCAN_BUDGET       bound on diagnose's whole step-log scan
#                                   (default 60s), so its cost is a constant
#                                   rather than growing with failed-step count
#   FM_USAGE_WALL_SNAPSHOT_TIMEOUT  bound on the fleet snapshot (default 300s)
#   FM_USAGE_WALL_CAPTURE_LINES     endpoint lines scanned by diagnose (default 200)
#   FM_USAGE_WALL_TIGHT_PCT         percent at or below which a reading is
#                                   labelled tight (default 20)
#   FM_USAGE_WALL_TIGHT_RUNWAY_SECS runway at or below which a reading is
#                                   labelled tight (default 3600)
#   FM_USAGE_WALL_NOW               fixed UTC stamp for the record (tests)
#
# Exit status: 0 when a verdict or record was produced, 2 on a usage error, 1 on
# an internal failure. A verdict of `unknown` is a successful report of an
# unmeasurable condition, not an error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# Sourced at top level, not lazily: the run helpers are read inside command
# substitutions, and a library sourced inside one dies with its subshell.
# fm-nm-run-lib.sh sources nothing itself, so this costs nothing on the
# headroom path.
# shellcheck source=bin/fm-nm-run-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

QUOTA_TIMEOUT=${FM_USAGE_WALL_QUOTA_TIMEOUT:-20}
NM_TIMEOUT=${FM_USAGE_WALL_NM_TIMEOUT:-20}
SCAN_BUDGET=${FM_USAGE_WALL_SCAN_BUDGET:-60}
SNAPSHOT_TIMEOUT=${FM_USAGE_WALL_SNAPSHOT_TIMEOUT:-300}
CAPTURE_LINES=${FM_USAGE_WALL_CAPTURE_LINES:-200}
TIGHT_PCT=${FM_USAGE_WALL_TIGHT_PCT:-20}
TIGHT_RUNWAY=${FM_USAGE_WALL_TIGHT_RUNWAY_SECS:-3600}

die() { printf 'fm-usage-wall: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
  cat <<'EOF'
usage: fm-usage-wall.sh headroom [--json]
       fm-usage-wall.sh diagnose <task-id> [--endpoint-only]
       fm-usage-wall.sh resume [--print] [--out <path>]

headroom  Report provider headroom from quota-axi before dispatching.
          Unmeasurable headroom reports `unknown` with its reason; it is never
          reported as healthy, and this command never prompts for credentials.
diagnose  Decide from evidence whether one task's stranding is a provider usage
          wall rather than a crash. --endpoint-only skips the pipeline step logs
          and downgrades every negative to `unknown`.
resume    Regenerate the resume record from live durable state and write it to
          state/resume-record.md. --print also writes the record to stdout.

Load the usage-limit-recovery skill for the recovery procedure itself.
EOF
}

positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) die "$1 must be a positive integer" ;;
  esac
}
non_negative_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a non-negative integer" ;;
  esac
}
positive_int FM_USAGE_WALL_QUOTA_TIMEOUT "$QUOTA_TIMEOUT"
positive_int FM_USAGE_WALL_NM_TIMEOUT "$NM_TIMEOUT"
positive_int FM_USAGE_WALL_SCAN_BUDGET "$SCAN_BUDGET"
positive_int FM_USAGE_WALL_SNAPSHOT_TIMEOUT "$SNAPSHOT_TIMEOUT"
positive_int FM_USAGE_WALL_CAPTURE_LINES "$CAPTURE_LINES"
non_negative_int FM_USAGE_WALL_TIGHT_PCT "$TIGHT_PCT"
non_negative_int FM_USAGE_WALL_TIGHT_RUNWAY_SECS "$TIGHT_RUNWAY"

# --- usage-wall signatures --------------------------------------------------
#
# Vendor phrasings that positively identify a provider usage limit, as extended
# regular expressions matched case-insensitively. Provenance matters more than
# breadth here: an over-broad pattern turns an ordinary failure into a false
# "not your fault" verdict, which is worse than no verdict at all, so this table
# stays limited to limit-exhaustion wording and deliberately excludes transient
# transport wording such as HTTP 429 or "rate limited", which a harness retries
# and survives.
#
#   1-2  observed verbatim in the 2026-08-23 incident's review and test step
#        logs ("You've hit your weekly limit - resets Aug 26 at 10am
#        (Europe/Rome)") and in its 5-hour-window counterpart.
#   3    `session` observed verbatim on 2026-08-27 in this repo's own pipeline
#        log ("You've hit your session limit - resets 1:40am
#        (America/Los_Angeles)"), which stranded a run whose step log this
#        command then read as `no-signature`. That miss is why the rule below
#        says to diagnose a real wall rather than only a fixture: the table is
#        only ever as complete as the phrasings actually observed, which is also
#        why a negative is `no-signature` and never "it crashed".
#   4-6  the neighbouring exhaustion phrasings of the same vendor family.
# A phrasing that is not here yields `no-signature`, which this command
# explicitly does not treat as proof of a crash. Add a pattern only with an
# observed line to justify it, and extend tests/fm-usage-wall.test.sh with it.
USAGE_WALL_PATTERNS='hit your (weekly|session|[0-9]+-hour|five-hour|daily|monthly) limit'
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|usage limit reached"
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|hit your usage limit"
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|you have (reached|hit) your (usage|weekly|monthly) limit"
USAGE_WALL_PATTERNS="$USAGE_WALL_PATTERNS|quota exceeded"

# first_wall_line: print the first line of stdin matching a usage-wall
# signature, or nothing. Streams, so an arbitrarily large step log costs one
# pass and no memory.
first_wall_line() {
  grep -m1 -i -E -- "$USAGE_WALL_PATTERNS" 2>/dev/null || true
}

# --- TOON block parsing -----------------------------------------------------
#
# Reads one self-describing TOON block by name and prints the requested fields
# as TSV, in the requested order, resolved BY FIELD NAME from the block's own
# declared header. An absent field prints "-", so a caller never silently reads
# a neighbouring column. Quoted fields (a value containing a comma, colon, or
# space) are honoured.
toon_block() {  # <block-name> <comma-separated-field-names> ; TOON on stdin
  awk -v block="$1" -v want="$2" '
    function unquote(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (s ~ /^".*"$/) { s = substr(s, 2, length(s) - 2) }
      return s
    }
    function split_row(line, out,   i, c, n, cur, inq) {
      n = 0; cur = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { inq = !inq; cur = cur c; continue }
        if (c == "," && !inq) { out[++n] = unquote(cur); cur = ""; continue }
        cur = cur c
      }
      out[++n] = unquote(cur)
      return n
    }
    BEGIN { nw = split(want, wantf, ","); inblock = 0 }
    {
      if (!inblock) {
        if ($0 ~ "^" block "\\[[0-9]+\\]\\{[^}]*\\}:[ \t]*$") {
          hdr = $0
          sub(/^[^{]*\{/, "", hdr)
          sub(/\}.*$/, "", hdr)
          nf = split(hdr, fields, ",")
          for (i = 1; i <= nf; i++) { idx[fields[i]] = i }
          inblock = 1
        }
        next
      }
      if ($0 !~ /^[ \t]+[^ \t]/) { inblock = 0; next }
      n = split_row($0, vals)
      out = ""
      for (i = 1; i <= nw; i++) {
        v = "-"
        if ((wantf[i] in idx) && idx[wantf[i]] <= n && vals[idx[wantf[i]]] != "") {
          v = vals[idx[wantf[i]]]
        }
        out = out (i > 1 ? "\t" : "") v
      }
      print out
    }
  '
}

# --- headroom ---------------------------------------------------------------

# humanize_secs: whole-unit runway, e.g. 4828 -> 1h20m.
humanize_secs() {  # <seconds>
  local s=$1 h m
  case "$s" in ''|*[!0-9]*) printf '%s' "$s"; return 0 ;; esac
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

cmd_headroom() {
  local json=0 out rc quota_version floor_note='' line
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown headroom option: $1" ;;
    esac
    shift
  done

  if ! command -v quota-axi >/dev/null 2>&1; then
    headroom_unmeasurable 'quota-axi is not installed' \
      'install it with npm install -g quota-axi to get a reading' "$json"
    return 0
  fi
  # Read --version ONCE. The floor check used to re-invoke quota-axi, which cost
  # this reading three bounded calls against a single outer bound: a slow but
  # working gauge then exhausted the caller's bound and printed `unknown` for a
  # gauge that could have been read - a false unmeasurable in the one surface
  # built to prevent them. bin/fm-quota-axi-lib.sh owns the comparison.
  local version_raw
  version_raw=$(fm_run_timed "$QUOTA_TIMEOUT" quota-axi --version 2>/dev/null </dev/null) || version_raw=
  quota_version=$(printf '%s' "$version_raw" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$quota_version" ] || quota_version=unknown
  # A below-floor build is reported, not suppressed: bin/fm-bootstrap.sh owns the
  # operator-facing MISSING diagnostic, and blanking a parseable reading here
  # would be a false negative in exactly the case this gauge exists for.
  fm_quota_axi_version_at_least "$version_raw" || floor_note=" build=below-floor($FM_QUOTA_AXI_MIN)"

  # No --allow-keychain-prompt, ever: it blocks on a GUI dialog, and this runs
  # inside session start's bounded session-open hook.
  out=$(fm_run_timed "$QUOTA_TIMEOUT" quota-axi 2>/dev/null </dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    headroom_unmeasurable "quota-axi did not answer within ${QUOTA_TIMEOUT}s" \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version$floor_note"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    headroom_unmeasurable "quota-axi exited $rc with no readable report" \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version$floor_note"
    return 0
  fi

  local effective providers
  effective=$(printf '%s\n' "$out" | toon_block effective \
    'provider,scope,effectivePercentRemaining,limitingWindowId,runway,usableRunwaySeconds,projectionConfidence')
  providers=$(printf '%s\n' "$out" | toon_block providers 'provider,status,authStatus,plan,source')
  if [ -z "$effective" ]; then
    headroom_unmeasurable 'quota-axi printed no effective-headroom block' \
      'treat every provider as unproven when deciding what to dispatch' "$json" "$quota_version$floor_note"
    return 0
  fi

  local windows
  windows=$(printf '%s\n' "$out" | toon_block windows 'provider,id,resetsAt')

  local measured=0 tight=0 wall=0 unknown=0 rows='' summary_verdict
  while IFS="$(printf '\t')" read -r provider scope pct win runway runway_s conf; do
    [ -n "$provider" ] || continue
    # One account-level reading per provider. A model-scoped row bounds only that
    # model (quota-axi owns that relationship) and is not the dispatch gauge.
    case "$scope" in
      all_models|unresolved) ;;
      *) continue ;;
    esac
    local pstatus pauth resets verdict detail hint=''
    pstatus=$(printf '%s\n' "$providers" | awk -F'\t' -v p="$provider" '$1 == p { print $2; exit }')
    pauth=$(printf '%s\n' "$providers" | awk -F'\t' -v p="$provider" '$1 == p { print $3; exit }')
    [ -n "$pstatus" ] || pstatus='-'
    [ -n "$pauth" ] || pauth='-'
    case "$pct" in
      ''|*[!0-9]*)
        unknown=$((unknown + 1))
        verdict=unknown
        detail="reason=$(headroom_unknown_reason "$scope" "$pstatus") status=$pstatus auth=$pauth"
        case "$pstatus" in
          auth_required) hint=" - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read" ;;
        esac
        ;;
      *)
        measured=$((measured + 1))
        resets=$(printf '%s\n' "$windows" | awk -F'\t' -v p="$provider" -v w="$win" '$1 == p && $2 == w { print $3; exit }')
        [ -n "$resets" ] || resets='-'
        if [ "$pct" -eq 0 ]; then
          verdict=wall; wall=$((wall + 1))
        elif [ "$pct" -le "$TIGHT_PCT" ]; then
          verdict=tight; tight=$((tight + 1))
        elif [ "$runway_s" != '-' ] && [ -z "${runway_s//[0-9]/}" ] && [ "$runway_s" -le "$TIGHT_RUNWAY" ]; then
          verdict=tight; tight=$((tight + 1))
        else
          verdict=ok
        fi
        detail="pct=$pct bound=$win resets=$resets"
        if [ "$runway_s" != '-' ] && [ -z "${runway_s//[0-9]/}" ]; then
          detail="$detail runway=$(humanize_secs "$runway_s")"
        else
          detail="$detail runway=unknown($runway)"
        fi
        detail="$detail confidence=$conf"
        ;;
    esac
    rows="$rows$provider	$verdict	$detail$hint"$'\n'
  done <<EOF
$effective
EOF

  # Verdict precedence. `wall` outranks `tight` because they are different
  # states, not degrees of one: tight means a dispatch may still land, wall
  # means that provider has already stopped and every worker on it is down.
  # Collapsing the second into the first would leave the aggregate line - and
  # `--json`'s `.verdict`, the field a programmatic reader branches on - unable
  # to express the one condition this command exists to announce.
  if [ "$measured" -eq 0 ]; then
    summary_verdict=unknown
  elif [ "$wall" -gt 0 ]; then
    summary_verdict=wall
  elif [ "$tight" -gt 0 ]; then
    summary_verdict=tight
  elif [ "$unknown" -gt 0 ]; then
    summary_verdict=partial
  else
    summary_verdict=ok
  fi

  if [ "$json" -eq 1 ]; then
    headroom_json "$summary_verdict" "$measured" "$tight" "$wall" "$unknown" \
      "$quota_version" "$floor_note" "$rows"
    return 0
  fi
  while IFS="$(printf '\t')" read -r provider verdict detail; do
    [ -n "$provider" ] || continue
    printf 'HEADROOM: %s %s %s\n' "$provider" "$verdict" "$detail"
  done <<EOF
$rows
EOF
  printf 'HEADROOM_SUMMARY: verdict=%s measured=%d tight=%d wall=%d unknown=%d source=quota-axi/%s%s\n' \
    "$summary_verdict" "$measured" "$tight" "$wall" "$unknown" "$quota_version" "$floor_note"
  if [ "$wall" -gt 0 ]; then
    printf 'HEADROOM_NOTE: %d provider(s) are AT the wall, not merely low - work on them has already stopped. Load the usage-limit-recovery skill.\n' "$wall"
  fi
  if [ "$unknown" -gt 0 ] || [ "$measured" -eq 0 ]; then
    printf 'HEADROOM_NOTE: an unknown provider is UNMEASURED, not healthy - treat its headroom as unproven when deciding what to dispatch.\n'
  fi
  if [ "$summary_verdict" = wall ] || [ "$summary_verdict" = tight ] || [ "$summary_verdict" = unknown ]; then
    printf 'HEADROOM_NEXT: %s/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.\n' "$FM_ROOT"
  fi
  line=$(printf '%s' "$rows" | grep -c . 2>/dev/null) || line=0
  [ "$line" -gt 0 ] || printf 'HEADROOM: (no provider rows) unknown reason=no-effective-rows\n'
}

headroom_unknown_reason() {  # <scope> <provider-status>
  case "$2" in
    auth_required) printf 'auth-required' ; return 0 ;;
    error) printf 'provider-read-failed' ; return 0 ;;
  esac
  case "$1" in
    unresolved) printf 'unresolved-scope' ;;
    *) printf 'no-measurable-window' ;;
  esac
}

# headroom_unmeasurable: the single exit for every path that could not read a
# gauge at all. There is deliberately no path from here to `ok`.
headroom_unmeasurable() {  # <reason> <advice> <json> [<source>]
  local reason=$1 advice=$2 json=$3 source=${4:-unavailable}
  if [ "$json" -eq 1 ]; then
    printf '{"schema":"fm-usage-wall-headroom.v1","verdict":"unknown","measured":0,"tight":0,"wall":0,"unknown":1,'
    printf '"source":"%s","reason":"%s","providers":[]}\n' "$(json_escape "$source")" "$(json_escape "$reason")"
    return 0
  fi
  printf 'HEADROOM: (all providers) unknown reason=%s\n' "$reason"
  printf 'HEADROOM_SUMMARY: verdict=unknown measured=0 tight=0 wall=0 unknown=1 source=quota-axi/%s\n' "$source"
  printf 'HEADROOM_NOTE: headroom is UNMEASURED, not healthy - %s.\n' "$advice"
  printf 'HEADROOM_NEXT: %s/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.\n' "$FM_ROOT"
}

json_escape() {  # <text>
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

headroom_json() {  # <verdict> <measured> <tight> <wall> <unknown> <version> <floor> <rows>
  local verdict=$1 measured=$2 tight=$3 wall=$4 unknown=$5 version=$6 floor=$7 rows=$8 first=1
  printf '{"schema":"fm-usage-wall-headroom.v1","verdict":"%s","measured":%d,"tight":%d,"wall":%d,"unknown":%d,' \
    "$verdict" "$measured" "$tight" "$wall" "$unknown"
  printf '"source":"quota-axi/%s","below_floor":%s,"providers":[' \
    "$(json_escape "$version")" "$([ -n "$floor" ] && printf true || printf false)"
  while IFS="$(printf '\t')" read -r provider pverdict detail; do
    [ -n "$provider" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"provider":"%s","verdict":"%s","detail":"%s"}' \
      "$(json_escape "$provider")" "$(json_escape "$pverdict")" "$(json_escape "$detail")"
  done <<EOF
$rows
EOF
  printf ']}\n'
}

# --- diagnose ---------------------------------------------------------------

load_backend_lib() {
  [ -n "${FM_USAGE_WALL_BACKEND_LOADED:-}" ] && return 0
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$SCRIPT_DIR/fm-backend.sh"
  FM_USAGE_WALL_BACKEND_LOADED=1
}

# endpoint_wall_line: first usage-wall line in the recorded endpoint's captured
# output, or nothing. Prints the capture status on fd 3 so the caller can tell
# "read it, nothing there" from "could not read it".
endpoint_evidence() {  # <meta> <task-id> -> "readable|unreadable\t<line>"
  local meta=$1 id=$2 backend target capture line
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  if [ -z "$target" ]; then
    printf 'unreadable\t\n'
    return 0
  fi
  capture=$(fm_backend_capture "$backend" "$target" "$CAPTURE_LINES" "fm-$id" 2>/dev/null) || {
    printf 'unreadable\t\n'
    return 0
  }
  if [ -z "$capture" ]; then
    printf 'unreadable\t\n'
    return 0
  fi
  line=$(printf '%s\n' "$capture" | first_wall_line)
  printf 'readable\t%s\n' "$line"
}

# attributed_run: the no-mistakes run report that belongs to <worktree>, or
# nothing when none is attributable.
#
# It asks the bare `no-mistakes axi` overview rather than `axi status`, because
# the two are scoped differently and only one of them answers this question:
# `axi status` reports the repo's active-or-most-recent run, which on a repo
# with several worktrees validating at once is routinely another task's run,
# while the bare overview reports the invoking worktree's own `active_run` and,
# when there is none, a `runs` table carrying the run IDs a targeted
# `axi status --run <id>` needs. (Verified against no-mistakes v1.57.0; the run
# IDs are in that table, and each row carries its branch and head.)
#
# Attribution binds on the run's BRANCH, and the head relationship is reported
# separately as evidence rather than used to discard the run. That split is
# deliberate. bin/fm-nm-run-lib.sh's shared rule requires the run head to be
# resolvable in the worktree, and a stranded run's head very often is NOT: the
# pipeline commits its fixes in its own gate copy, so those commits exist
# nowhere in the task's local copy. Discarding the run there would hide exactly
# the state a recovery most needs to see. This command reports rather than acts,
# so it names the run AND the head relationship and lets the reader judge.
attributed_run() {  # <worktree>
  local wt=$1 overview wt_branch run_id
  wt_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || wt_branch=
  [ -n "$wt_branch" ] || return 1
  overview=$(fm_nm_run "$wt" "$NM_TIMEOUT" axi) || overview=
  [ -n "$overview" ] || return 1

  case "$overview" in
    *active_run:*)
      if [ "$(fm_nm_strip_quotes "$(fm_nm_field "$overview" branch)")" = "$wt_branch" ]; then
        printf '%s\n' "$overview"
        return 0
      fi
      ;;
  esac

  run_id=$(printf '%s\n' "$overview" | toon_block runs 'id,branch,status,head' |
    awk -F'\t' -v b="$wt_branch" '$2 == b { print $1; exit }')
  [ -n "$run_id" ] || return 1
  overview=$(fm_nm_run "$wt" "$NM_TIMEOUT" axi status --run "$run_id") || overview=
  [ -n "$overview" ] || return 1
  printf '%s\n' "$overview"
}

# head_binding: how the attributed run's head relates to the local copy. The
# binding RULE stays owned by bin/fm-nm-run-lib.sh; this only names the cases it
# separates, including the one it rejects, because `pipeline-only` is the
# signature of a run holding commits the local copy never received.
head_binding() {  # <worktree> <run-head>
  local wt=$1 run_head=$2 local_full
  [ -n "$run_head" ] && [ "$run_head" != '-' ] || { printf 'unknown'; return 0; }
  if ! git -C "$wt" rev-parse --verify --quiet "${run_head}^{commit}" >/dev/null 2>&1; then
    printf 'pipeline-only'
    return 0
  fi
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'unknown'; return 0; }
  if [ "$local_full" = "$(git -C "$wt" rev-parse "${run_head}^{commit}" 2>/dev/null)" ]; then
    printf 'equal'
  elif fm_nm_head_matches_worktree "$wt" "$run_head"; then
    printf 'pipeline-ahead'
  else
    printf 'diverged'
  fi
}

# Every failed or cancelled step, in pipeline order. Deliberately uncapped: a
# cap here silently decides which evidence counts, and a run whose fourth failed
# step is the one carrying the vendor limit line would return `no-signature` -
# the verdict this command defines as "read and nothing matched". The scan is
# bounded by time instead (SCAN_BUDGET), which bounds cost without ever deciding
# in advance that some evidence does not matter, and what the budget cut is
# disclosed as `unread=` rather than folded into a clean result.
failed_steps() {  # <axi-status-toon>
  toon_steps "$1" | awk -F'\t' '$2 == "failed" || $2 == "cancelled" { print $1 }'
}

last_step() {  # <axi-status-toon>
  toon_steps "$1" | awk -F'\t' '$1 != "" { last = $1 } END { if (last != "") print last }'
}

# toon_steps: "<step>\t<status>" for every row of `axi status`'s steps block.
# A row is recognized structurally - indented, and a bare token followed by a
# comma - so a neighbouring indented key/value block is never read as a step.
toon_steps() {  # <axi-status-toon>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*steps\[[0-9]+\]\{/ { inblock = 1; next }
    !inblock { next }
    $0 !~ /^[[:space:]]+[^[:space:]:]+,/ { inblock = 0; next }
    {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      n = split(line, f, ",")
      if (n >= 2) { print f[1] "\t" f[2] }
    }
  '
}

cmd_diagnose() {
  local id='' endpoint_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint-only) endpoint_only=1 ;;
      -h|--help) usage; return 0 ;;
      -*) die "unknown diagnose option: $1" ;;
      *) [ -z "$id" ] || die "diagnose takes exactly one task id"; id=$1 ;;
    esac
    shift
  done
  [ -n "$id" ] || die "diagnose requires a task id"

  load_backend_lib
  local meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    printf 'USAGE_WALL: %s unknown reason=no-durable-record checked=none\n' "$id"
    printf 'USAGE_WALL_NEXT: %s has no local record in this home; reconcile ownership before concluding anything about it.\n' "$id"
    return 0
  fi

  local checked='' evidence status line wt
  evidence=$(endpoint_evidence "$meta" "$id")
  status=${evidence%%	*}
  line=${evidence#*	}
  line=${line%$'\n'}
  if [ "$status" = readable ]; then
    checked=endpoint
    if [ -n "$line" ]; then
      wall_verdict "$id" endpoint "$line"
      return 0
    fi
  fi

  if [ "$endpoint_only" -eq 1 ]; then
    # A cheap scan that found nothing proves nothing: the 2026-08-23 evidence was
    # in the pipeline step logs, not the terminal. So an endpoint-only negative
    # is reported as unknown, never as a clean bill of health.
    printf 'USAGE_WALL: %s unknown reason=endpoint-only-scan-inconclusive checked=%s\n' "$id" "${checked:-none}"
    printf 'USAGE_WALL_NEXT: run %s/bin/fm-usage-wall.sh diagnose %s for the pipeline step logs before treating this as a crash.\n' "$FM_ROOT" "$id"
    return 0
  fi

  wt=$(fm_meta_get_local "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    diagnose_inconclusive "$id" "${checked:-none}" no-local-copy 'the pipeline logs need a readable local copy to read them from'
    return 0
  fi

  local run steps step log_line=''
  run=$(attributed_run "$wt") || run=
  if [ -z "$run" ]; then
    diagnose_inconclusive "$id" "${checked:-none}" no-attributed-run 'no pipeline run is attributed to this local copy'
    return 0
  fi
  local run_id
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$run" id)")
  steps=$(failed_steps "$run")
  [ -n "$steps" ] || steps=$(last_step "$run")
  if [ -z "$steps" ]; then
    diagnose_inconclusive "$id" "${checked:-none}" no-readable-steps "pipeline run $run_id lists no readable steps"
    return 0
  fi
  local readable=0 unread='' logs bound spent
  spent=0
  for step in $steps; do
    bound=$((SCAN_BUDGET - spent))
    [ "$bound" -gt "$NM_TIMEOUT" ] && bound=$NM_TIMEOUT
    if [ "$bound" -le 0 ]; then
      unread="${unread:+$unread,}$step"
      continue
    fi
    local started
    started=$(date +%s)
    # fm_nm_run_checked, not fm_nm_run: the fail-open variant discards the read's
    # exit status, so a log that could not be read at all was indistinguishable
    # from one read cleanly with no match - and `checked=` then named a step
    # nothing had ever looked at. The status decides which of the two this is.
    if logs=$(fm_nm_run_checked "$wt" "$bound" axi logs --run "$run_id" --step "$step" --full); then
      readable=$((readable + 1))
      checked="${checked:+$checked,}step-log:$step"
      log_line=$(printf '%s\n' "$logs" | first_wall_line)
      if [ -n "$log_line" ]; then
        wall_verdict "$id" "step-log:$step" "$log_line"
        return 0
      fi
    else
      unread="${unread:+$unread,}$step"
    fi
    spent=$((spent + $(date +%s) - started))
  done
  if [ "$readable" -eq 0 ]; then
    diagnose_inconclusive "$id" "${checked:-none}" step-log-unreadable \
      "no step log of pipeline run $run_id could be read (unread: ${unread:-none})"
    return 0
  fi
  printf 'USAGE_WALL: %s no-signature checked=%s run=%s%s\n' "$id" "$checked" "$run_id" \
    "${unread:+ unread=$unread}"
  printf 'USAGE_WALL_NEXT: no usage-limit signature is present in what was readable; this is not proof the work crashed, so keep reading the evidence itself.\n'
}

diagnose_inconclusive() {  # <id> <checked> <reason-slug> <detail>
  printf 'USAGE_WALL: %s unknown reason=%s checked=%s - %s\n' "$1" "$3" "$2" "$4"
  printf 'USAGE_WALL_NEXT: the evidence that separates a usage wall from a crash could not be read; do not record a failure until it can.\n'
}

wall_verdict() {  # <id> <source> <line>
  local capped=$3
  [ "${#capped}" -le 200 ] || capped="${capped:0:200} [truncated]"
  printf 'USAGE_WALL: %s wall source=%s line="%s"\n' "$1" "$2" "$capped"
  printf 'USAGE_WALL_NEXT: this is a provider usage limit, not a crash - the work is intact. Load the usage-limit-recovery skill before touching the task.\n'
}

# fm_meta_get_local: meta lookup that does not require the backend library, so
# `diagnose` can report on a task whose backend cannot even be sourced.
fm_meta_get_local() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# --- resume -----------------------------------------------------------------

now_stamp() {
  if [ -n "${FM_USAGE_WALL_NOW:-}" ]; then
    printf '%s' "$FM_USAGE_WALL_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# branch_sync_field: one scalar from `axi status`'s branch_sync block, which is
# printed only when the pipeline has something to say about branch ownership.
# Scoped to that block so a same-named key elsewhere in the report (`status:`
# exists at run level too) can never be read as custody.
branch_sync_field() {  # <axi-status-toon> <key>
  printf '%s\n' "$1" | awk -v key="$2" '
    /^[[:space:]]*branch_sync:[[:space:]]*$/ { inblock = 1; next }
    inblock && $0 ~ /^[^[:space:]]/ { inblock = 0 }
    inblock {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (index(line, key ":") == 1) {
        v = substr(line, length(key) + 2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        if (v != "") { print v; exit }
      }
    }
  '
}

git_fact() {  # <worktree> <branch|head|dirty|unpushed>
  local wt=$1 v
  case "$2" in
    branch)
      v=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || v=
      [ -n "$v" ] || v='(detached)'
      ;;
    head) v=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null) || v='-' ;;
    dirty) v=$(git -C "$wt" status --porcelain 2>/dev/null | grep -c .) || v=0 ;;
    unpushed)
      # A branch the pipeline pushed often has no configured upstream, so fall
      # back to the remote branch of the same name before giving up. "not
      # pushed" is a real answer and must never be reported as zero unpushed
      # commits.
      local branch
      branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
      v=$(git -C "$wt" rev-list --count '@{upstream}..HEAD' 2>/dev/null) || v=
      if [ -z "$v" ] && [ -n "$branch" ]; then
        v=$(git -C "$wt" rev-list --count "origin/$branch..HEAD" 2>/dev/null) || v=
      fi
      [ -n "$v" ] || v='(branch not on origin)'
      ;;
    *) v='-' ;;
  esac
  printf '%s' "$v"
}

steering_fact() {  # <task-id> <unread|acknowledged>
  local id=$1 n=0
  local dir="$STATE/$id.inbox"
  case "$2" in
    unread) n=$(find "$dir" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | grep -c .) || n=0 ;;
    acknowledged) n=$(find "$dir/handled" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | grep -c .) || n=0 ;;
  esac
  printf '%s' "$n"
}

cmd_resume() {
  local print=0 out="$STATE/resume-record.md" snapshot rc tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --print) print=1 ;;
      --out) shift; [ $# -gt 0 ] || die "--out requires a path"; out=$1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown resume option: $1" ;;
    esac
    shift
  done
  command -v jq >/dev/null 2>&1 || die "jq is required to read the fleet snapshot" 1

  snapshot=$(fm_run_timed "$SNAPSHOT_TIMEOUT" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    die "the fleet snapshot did not finish within ${SNAPSHOT_TIMEOUT}s; no record was written so the previous one is still readable" 1
  fi
  [ "$rc" -eq 0 ] && [ -n "$snapshot" ] \
    || die "the fleet snapshot could not be read (exit $rc); no record was written so the previous one is still readable" 1

  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-resume-record.XXXXXX") || die "could not create a temporary file" 1
  # A record is published whole or not at all: a half-written record read during
  # a recovery is worse than the previous complete one.
  resume_body "$snapshot" > "$tmp" || { rm -f "$tmp"; die "the record could not be composed" 1; }
  mv "$tmp" "$out" || { rm -f "$tmp"; die "the record could not be published to $out" 1; }

  if [ "$print" -eq 1 ]; then
    cat "$out"
  else
    printf '%s\n' "$out"
  fi
}

RESUME_DUP_WORKTREES=""

resume_body() {  # <snapshot-json>
  local snapshot=$1 count
  count=$(printf '%s' "$snapshot" | jq -r '.tasks | length')
  printf '# Resume record\n\n'
  printf 'generated: %s\n' "$(now_stamp)"
  printf 'home: %s\n' "$FM_HOME"
  printf 'source: bin/fm-usage-wall.sh resume\n'
  printf 'tasks in flight: %s\n\n' "$count"
  printf 'This record is GENERATED from live durable state. Do not hand-edit it; regenerate it.\n'
  printf 'It carries state only. The recovery procedure is owned by the usage-limit-recovery skill.\n'
  printf 'Nothing here is a merge authorisation: each task keeps the posture recorded on its own line.\n\n'
  if [ "$count" = 0 ]; then
    printf 'No task metadata is present in this home, so no work is in flight to resume.\n'
    return 0
  fi

  # Two tasks recording the SAME local copy is a live hazard during recovery -
  # resuming either one lands both in the same checkout - so it is named on both
  # rows rather than left for the reader to notice by comparing paths.
  RESUME_DUP_WORKTREES=$(printf '%s' "$snapshot" |
    jq -r '[.tasks[] | select(.paths.worktree.path != null) | .paths.worktree.path]
           | group_by(.) | map(select(length > 1) | .[0]) | .[]')

  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    resume_task "$snapshot" "$id"
  done < <(printf '%s' "$snapshot" | jq -r '.tasks[].id')
}

resume_task() {  # <snapshot-json> <task-id>
  local snapshot=$1 id=$2
  local meta="$STATE/$id.meta"
  # One field per LINE, never one row of tab-separated fields: bash collapses
  # runs of tabs when IFS is whitespace, so an empty field in a TSV row silently
  # shifts every field after it. A recovery record that quietly reports the
  # wrong branch or the wrong merge posture is worse than no record.
  local -a f=()
  local line
  while IFS= read -r line; do
    f+=("$line")
  done < <(printf '%s' "$snapshot" | jq -r --arg id "$id" '
    .tasks[] | select(.id == $id) |
    (.kind // "-"), (.mode // "-"), (.yolo // "-"), (.harness // "-"), (.backend // "-"),
    (.endpoint.target // "-"),
    (if .endpoint.exists == null then "unknown" elif .endpoint.exists then "present" else "absent" end),
    (.paths.worktree.path // "-"),
    (if .paths.worktree.present then "present" else "absent" end),
    (.current_state.raw // "-"),
    (.pr.url // "-"),
    (((.hints.open_decisions // []) | map("\(.key) (\(.verb))") | join("; ")) | if . == "" then "-" else . end),
    ((.remote.host // "-") | tostring)')
  if [ "${#f[@]}" -lt 13 ]; then
    printf '## %s\n\n' "$id"
    printf -- '- RECORD INCOMPLETE: this task could not be read out of the fleet snapshot; read %s directly before acting on it.\n\n' "$meta"
    return 0
  fi
  local kind=${f[0]} mode=${f[1]} yolo=${f[2]} harness=${f[3]} backend=${f[4]}
  local target=${f[5]} endpoint=${f[6]} wt=${f[7]} wt_present=${f[8]}
  local state=${f[9]} pr=${f[10]} decisions=${f[11]} remote=${f[12]}

  printf '## %s\n\n' "$id"
  printf -- '- kind: %s\n' "$kind"
  printf -- '- merge posture: mode=%s yolo=%s (%s)\n' "$mode" "$yolo" "$(posture_note "$yolo")"
  printf -- '- runtime: harness=%s model=%s effort=%s backend=%s\n' \
    "$harness" "$(dash "$(fm_meta_get_local "$meta" model)")" \
    "$(dash "$(fm_meta_get_local "$meta" effort)")" "$backend"
  if [ "$remote" != '-' ] && [ -n "$remote" ]; then
    printf -- '- remote host: %s (its own home reconciles this work; do not drive it from here)\n' "$remote"
  fi
  printf -- '- endpoint: %s (%s)\n' "$target" "$endpoint"

  if [ "$wt_present" = present ]; then
    local branch head dirty unpushed
    branch=$(git_fact "$wt" branch)
    head=$(git_fact "$wt" head)
    dirty=$(git_fact "$wt" dirty)
    unpushed=$(git_fact "$wt" unpushed)
    printf -- '- local copy: %s\n' "$wt"
    if printf '%s\n' "${RESUME_DUP_WORKTREES:-}" | grep -Fqx -- "$wt"; then
      printf -- '  - SHARED: another task in this home records the same local copy; resolve which one owns it before resuming either\n'
    fi
    printf -- '- branch: %s head: %s uncommitted: %s unpushed commits: %s\n' \
      "$branch" "$head" "$dirty" "$unpushed"
    resume_pipeline_line "$wt"
  else
    printf -- '- local copy: %s (absent)\n' "$wt"
    printf -- '- pipeline: not read (no local copy to read it from)\n'
  fi

  printf -- '- pull request: %s\n' "$pr"
  printf -- '- current state: %s\n' "$state"
  printf -- '- open captain calls: %s\n' "$([ "$decisions" = '-' ] && printf '(none)' || printf '%s' "$decisions")"
  printf -- '- delivered instructions: %s acknowledged, %s still unread by the worker\n\n' \
    "$(steering_fact "$id" acknowledged)" "$(steering_fact "$id" unread)"
}

resume_pipeline_line() {  # <worktree>
  local wt=$1 run run_id run_status run_head failed custody next binding
  run=$(attributed_run "$wt") || run=
  if [ -z "$run" ]; then
    printf -- '- pipeline: no run is attributed to this local copy\n'
    return 0
  fi
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$run" id)")
  run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$run" status)")
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$run" head)")
  failed=$(failed_steps "$run" | tr '\n' ',' | sed 's/,$//')
  custody=$(branch_sync_field "$run" state)
  next=$(branch_sync_field "$run" code)
  binding=$(head_binding "$wt" "$run_head")
  printf -- '- pipeline: run=%s status=%s failed-steps=%s custody=%s next-action=%s head=%s (%s)\n' \
    "$run_id" "$(dash "$run_status")" "$(dash "$failed")" "$(dash "$custody")" "$(dash "$next")" \
    "$(dash "$run_head")" "$binding"
  case "$custody" in
    pipeline_owned*|blocked_pipeline_owned*)
      printf -- '  - the pipeline owns this branch; settle custody through its next-action before any new work on it\n'
      ;;
  esac
  case "$binding" in
    pipeline-only|pipeline-ahead)
      printf -- '  - the run holds commits this local copy does not have; rebuilding from the local head would silently redo work that already exists\n'
      ;;
  esac
}

posture_note() {  # <yolo>
  case "$1" in
    on) printf 'firstmate may merge green, in-scope work itself' ;;
    *) printf 'the captain approves every merge' ;;
  esac
}

dash() {  # <value>
  if [ -z "${1:-}" ]; then printf -- '-'; else printf '%s' "$1"; fi
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  headroom) shift; cmd_headroom "$@" ;;
  diagnose) shift; cmd_diagnose "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) printf 'fm-usage-wall: unknown command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
