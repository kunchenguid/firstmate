#!/usr/bin/env bash
# fm-run.sh - the autonomous-run engine: one frozen manifest, one state machine,
# and the deterministic gates every `/afk-*` autonomous mode runs behind.
#
# The product policy for each mode is owned by its user-invocable skill; the
# shared agent procedure is owned by .agents/skills/autonomous-run-engine/. This
# script owns only the mechanics those documents point at, so a mode cannot make
# its own read-only claim: the claim is whatever this engine will actually permit.
#
# Five invariants are enforced here rather than described:
#   1. A run cannot expand its own manifest. `set`/`add` refuse after `freeze`,
#      and every later command re-verifies the manifest against the hash recorded
#      at freeze, so an edit by anything at all stops the run.
#   2. A tool is permitted only by a closed allowlist. Absence is the mechanism;
#      the denylist and the built-in floor are defense in depth on top of it.
#   3. A write is permitted only into the run's evidence directory, plus the
#      explicitly granted paths of a change-authorized run. Paths are compared
#      after physical resolution, so a symlinked parent cannot smuggle one out.
#   4. Exactly one owner may mutate a run. A second owner may take over only from
#      a quiesced state, so a failed handoff converges to one owner or none.
#   5. Every gate decision, allowed or refused, writes a receipt. `prove-no-write`
#      is only meaningful because the refusals are recorded too.
#
# Usage:
#   fm-run.sh new <run-id> --mode <mode> --lane <lane> --grant <grant>
#                          [--submode <submode>] [--authorized-at <iso8601>]
#                          [--yolo on|off] [--wall-seconds <n>]
#   fm-run.sh set <run-id> <jq-path> <value> [--json]   pre-freeze manifest edit
#   fm-run.sh add <run-id> <jq-path> <value>            pre-freeze array append
#   fm-run.sh freeze <run-id>                           hash and seal the manifest
#   fm-run.sh verify <run-id>                           re-check the frozen hash
#   fm-run.sh show <run-id> [<jq-filter>]               read the manifest
#   fm-run.sh preflight <run-id>                        run every start assertion
#   fm-run.sh state <run-id>                            print the run-state record
#   fm-run.sh advance <run-id> <state>                  guarded state transition
#   fm-run.sh claim <run-id> [--owner <t>] [--takeover] acquire mutable custody
#   fm-run.sh resume <run-id> [--reauthorized-at <iso>] idempotent re-entry
#   fm-run.sh tool-check <run-id> <tool>                allowlist gate + receipt
#   fm-run.sh write-check <run-id> <path>               write gate + receipt
#   fm-run.sh read-check <run-id> <path>                read/lane gate + receipt
#   fm-run.sh cross-lane-attest <run-id> --summary-file <path>
#   fm-run.sh receipt <run-id> <kind> <subject> <verdict> [note]
#   fm-run.sh prove-no-write <run-id>                   assert nothing was written
#   fm-run.sh checkpoint <run-id> --note <t> [--resume-when <t>]
#   fm-run.sh check-stop <run-id>                       budget rules, and what it cannot judge
#   fm-run.sh stop <run-id> --rule <rule> [--note <t>] [--resume-when <t>]
#   fm-run.sh cancel <run-id> --note <t>
#   fm-run.sh summary <run-id>                          machine-readable run summary
#   fm-run.sh list
#
# Custody: `--owner <token>` (or FM_RUN_OWNER) defaults to the active FM_HOME, so
# one home is one owner and a second home cannot mutate another's run at all.
#
# Layout, lane registration, and the receipt record are owned by
# bin/fm-run-lib.sh; the quota thresholds are owned by bin/fm-run-governor.sh;
# the operator-facing contract is docs/autonomous-runs.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-run-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-run-lib.sh"

# A resumed run whose captain authorization is older than this needs an explicit
# re-authorization stamp. Authority is a fact with a timestamp, not a file that
# stays true because it is still on disk.
FM_RUN_STALE_AUTHORITY_SECS=${FM_RUN_STALE_AUTHORITY_SECS:-86400}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-run: %s\n' "$*" >&2
  exit 1
}

# Exit 3 is the gate-refusal status, distinct from exit 1 for an operator error,
# so a caller can tell "this run may not do that" from "this command was wrong".
refuse() {
  printf 'fm-run: refused: %s\n' "$*" >&2
  exit 3
}

# Every exit path, including a refusal and a failed assertion, releases whatever
# this process still holds. A command that dies inside a critical section must
# not leave the next one waiting on a lock nobody owns.
trap fm_run_lock_release_all EXIT

# hold_run_lock <run-id>: serialize one run's state-changing commands.
# Two concurrent claims previously each read generation 0, each decided they
# could take the run, and each wrote - producing two owners for one run. Reading,
# deciding, and writing under this lock is what makes the claim a real
# compare-and-swap instead of three independent writes.
hold_run_lock() {  # <run-id>
  fm_run_lock_acquire "$(fm_run_lock_path "$1")"
}

# --- known vocabularies -----------------------------------------------------

FM_RUN_MODES='afk-research afk-app afk-obsidian-projects afk-session-review afk-jira-research'
FM_RUN_STATES='intake preflight baseline plan dispatch supervise checkpoint decision stop report resume cancel done'
FM_RUN_STOP_RULES='reserve-threshold deadline no-progress unstable-baseline health ambiguity captain-only-decision low-value-only cleanup-unprovable auth-uncertainty policy-ambiguity unexpected-access sensitive-content insufficient-sample unverifiable-authorship mutation-requested schema-drift'

# The floor no manifest can lower. A denylist lives in the manifest and can be
# authored badly; these patterns are compiled in and are checked before the
# allowlist is consulted at all. They are arrays, not a word-split string, so a
# pattern is never filename-expanded on its way to the matcher.
FM_RUN_ALWAYS_DENY=('http:POST' 'http:PUT' 'http:PATCH' 'http:DELETE' 'graphql:mutation')
FM_RUN_READONLY_DENY=('*:write' '*:mutate' '*:create' '*:update' '*:delete' '*:deploy' '*:merge')

in_list() {  # <needle> <space-separated-list>
  local item
  for item in $2; do
    [ "$item" = "$1" ] && return 0
  done
  return 1
}

# --- time -------------------------------------------------------------------

# ISO 8601 to epoch seconds across BSD and GNU date. Returns nonzero rather than
# guessing, so an unparseable authorization timestamp fails the assertion that
# reads it instead of silently becoming 1970.
iso_to_epoch() {  # <iso8601>
  local value=$1 normalized
  normalized=${value%Z}
  normalized=${normalized%%+*}
  normalized=${normalized%%.*}
  if date -d "$value" +%s >/dev/null 2>&1; then
    date -d "$value" +%s
    return 0
  fi
  if date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" +%s >/dev/null 2>&1; then
    date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" +%s
    return 0
  fi
  return 1
}

# --- manifest construction --------------------------------------------------

mode_submode_default() {  # <mode>
  case "$1" in
    afk-research) printf 'research-only\n' ;;
    afk-app) printf 'audit\n' ;;
    afk-obsidian-projects) printf 'authorized-tasks\n' ;;
    afk-session-review) printf 'retrospective\n' ;;
    afk-jira-research) printf 'read-only-review\n' ;;
    *) return 1 ;;
  esac
}

mode_submode_valid() {  # <mode> <submode>
  case "$1" in
    afk-app)
      case "$2" in audit|fix-known|bounded-improvement) return 0 ;; esac
      return 1
      ;;
    *)
      [ "$2" = "$(mode_submode_default "$1")" ]
      ;;
  esac
}

# The grant a submode is allowed to carry. Read-only modes have exactly one legal
# grant, so a change-authorized manifest cannot be built for them at all.
submode_grant_kind() {  # <mode> <submode>
  case "$1/$2" in
    afk-app/fix-known) printf 'fix-known\n' ;;
    afk-app/bounded-improvement) printf 'bounded-improvement\n' ;;
    *) printf 'read-only\n' ;;
  esac
}

mode_tool_allowlist() {  # <mode> <submode>
  case "$1/$2" in
    afk-research/*)
      printf '%s\n' read grep glob web:read github:read
      ;;
    afk-app/audit)
      printf '%s\n' read grep glob browser:read semgrep:scan osv:scan schemathesis:read github:read
      ;;
    afk-app/*)
      printf '%s\n' read grep glob browser:read semgrep:scan osv:scan schemathesis:read github:read \
        edit test:run lint:run build:run git:local
      ;;
    afk-obsidian-projects/*)
      printf '%s\n' read grep glob vault:read
      ;;
    afk-session-review/*)
      printf '%s\n' read grep glob
      ;;
    afk-jira-research/*)
      # The design's exact read-only Atlassian surface. Every write tool is absent
      # from this list, which is the whole enforcement: the allowlist is closed.
      # jira_get_transitions reads which transitions exist; jira_transition_issue,
      # the tool that performs one, is not here. Attachment downloads are treated
      # as write-adjacent and are excluded until a per-run field grant adds them.
      printf '%s\n' read grep glob \
        jira_search jira_get_issue jira_get_project_issues jira_get_board_issues \
        jira_get_sprint_issues jira_get_sprints_from_board jira_get_agile_boards \
        jira_batch_get_changelogs jira_get_worklog jira_get_issue_watchers \
        jira_get_transitions jira_get_link_types jira_get_project_components \
        jira_get_project_versions jira_get_project_epic_hierarchy jira_get_issue_dates \
        jira_get_user_profile \
        confluence_search confluence_get_page confluence_get_page_children \
        confluence_get_page_history confluence_get_comments confluence_get_labels \
        confluence_get_space_page_tree confluence_get_page_views
      ;;
    *) return 1 ;;
  esac
}

mode_tool_denylist() {  # <mode>
  printf '%s\n' '*:write' '*:mutate' http:POST http:PUT http:PATCH http:DELETE graphql:mutation
  case "$1" in
    afk-jira-research)
      printf '%s\n' 'jira_create*' 'jira_update*' 'jira_delete*' 'jira_add*' 'jira_assign*' \
        'jira_transition*' 'jira_move*' 'jira_link*' 'jira_download*' \
        'confluence_create*' 'confluence_update*' 'confluence_delete*' 'confluence_add*' \
        'confluence_copy*' 'confluence_move*' 'confluence_reply*' 'confluence_upload*' \
        'confluence_set*' 'confluence_download*'
      ;;
  esac
}

mode_stop_rules() {  # <mode>
  printf '%s\n' reserve-threshold deadline no-progress unstable-baseline health ambiguity \
    captain-only-decision low-value-only cleanup-unprovable
  case "$1" in
    afk-jira-research)
      printf '%s\n' auth-uncertainty policy-ambiguity unexpected-access sensitive-content \
        insufficient-sample unverifiable-authorship mutation-requested schema-drift
      ;;
  esac
}

json_array() {  # reads lines on stdin
  jq -R . | jq -s .
}

command_new() {
  local run_id=${1:-} mode='' submode='' lane='' grant='' yolo=off authorized_at='' wall_seconds=28800
  local root manifest lane_class lane_root grant_kind expected_kind
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) shift; mode=${1:-} ;;
      --submode) shift; submode=${1:-} ;;
      --lane) shift; lane=${1:-} ;;
      --grant) shift; grant=${1:-} ;;
      --yolo) shift; yolo=${1:-} ;;
      --authorized-at) shift; authorized_at=${1:-} ;;
      --wall-seconds) shift; wall_seconds=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  in_list "$mode" "$FM_RUN_MODES" || fail "unknown mode: '$mode' (one of: $FM_RUN_MODES)"
  [ -n "$submode" ] || submode=$(mode_submode_default "$mode")
  mode_submode_valid "$mode" "$submode" || fail "mode $mode does not accept submode $submode"
  case "$yolo" in on|off) ;; *) fail "--yolo must be on or off" ;; esac
  case "$wall_seconds" in ''|*[!0-9]*|0) fail "--wall-seconds must be a positive integer" ;; esac
  [ -n "$grant" ] || fail "--grant is required (read-only, fix-known:<hash>, bounded-improvement:<hash>)"
  grant_kind=${grant%%:*}
  expected_kind=$(submode_grant_kind "$mode" "$submode")
  [ "$grant_kind" = "$expected_kind" ] \
    || fail "mode $mode submode $submode requires a $expected_kind grant, got $grant_kind"
  if [ "$grant_kind" = read-only ]; then
    [ "$grant" = read-only ] || fail "a read-only grant carries no envelope: $grant"
  else
    case "$grant" in
      "$grant_kind":?*) ;;
      *) fail "$grant_kind requires an envelope hash: $grant_kind:<hash>" ;;
    esac
  fi
  [ -n "$authorized_at" ] || authorized_at=$(fm_run_now_iso)
  iso_to_epoch "$authorized_at" >/dev/null || fail "--authorized-at is not an ISO 8601 timestamp: $authorized_at"

  local lane_record
  lane_record=$(fm_run_lane_lookup "$lane") || exit 1
  read -r lane_class lane_root <<EOF
$lane_record
EOF
  [ -n "$lane_class" ] && [ -n "$lane_root" ] || fail "lane $lane is not registered"

  root=$(fm_run_root "$run_id")
  [ ! -e "$root" ] || fail "run $run_id already exists at $root"
  mkdir -p "$root/evidence" "$root/checkpoints"
  manifest=$(fm_run_manifest_path "$run_id")

  jq -n \
    --arg schemaVersion "$FM_RUN_SCHEMA_VERSION" \
    --arg runId "$run_id" \
    --arg mode "$mode" \
    --arg submode "$submode" \
    --arg createdAt "$(fm_run_now_iso)" \
    --arg authorizedAt "$authorized_at" \
    --arg grant "$grant" \
    --arg yolo "$yolo" \
    --arg lane "$lane" \
    --arg laneClass "$lane_class" \
    --arg configRoot "$lane_root" \
    --arg evidenceDir "$root/evidence" \
    --argjson wallSeconds "$wall_seconds" \
    --argjson allowlist "$(mode_tool_allowlist "$mode" "$submode" | json_array)" \
    --argjson denylist "$(mode_tool_denylist "$mode" | json_array)" \
    --argjson stopRules "$(mode_stop_rules "$mode" | json_array)" \
    '{
      schemaVersion: $schemaVersion,
      runId: $runId,
      mode: $mode,
      submode: $submode,
      createdAt: $createdAt,
      authority: {
        captainAuthorizedAt: $authorizedAt,
        grant: $grant,
        yolo: ($yolo == "on"),
        decisionsCaptainOwns: [
          "merge","credentials","external-comm","production","destructive",
          "irreversible","security","scope-expansion"
        ]
      },
      source: {
        projects: [], taskPaths: [], baseQueryFrozenMembers: [],
        sessionLanes: [], readRoots: [],
        jira: { site: null, projects: [], spaces: [], authorship: null, statuses: [], window: null }
      },
      account: { lane: $lane, laneClass: $laneClass, configRoot: $configRoot, isolationAsserted: false },
      privacy: {
        crossLaneAllowed: "none",
        reconstructionTest: true,
        noRawIntoObsidian: true,
        noRawIntoPersonalAccounts: true
      },
      selfAnalysis: { enabled: false, lane: null, subjectCaptainOnly: true },
      tools: { allowlist: $allowlist, denylist: $denylist, surfaceProof: null },
      writes: {
        allowedPaths: [],
        protectedPaths: ["**/tests/**","**/*.evaluator.*","AGENTS.md","CLAUDE.md","**/.git/**"],
        evidenceDir: $evidenceDir,
        vaultWriter: "firstmate-only"
      },
      budgets: {
        wallSeconds: $wallSeconds,
        perLaneReserve: { noNewLarge: 25, checkpointOnly: 15, emergency: 10 },
        maxWorkers: 5, maxConcurrentBrowsers: 1,
        maxConsecutiveCrashes: 3, maxNonImprovingRounds: 5,
        verificationReservePct: 20
      },
      acceptance: {
        perFinding: "reproduce-twice+evidence+intent-tie+dedupe+fp-countercheck",
        perChange: "reproduce-before+targeted-test+full-suite+lint/type/build+independent-review"
      },
      stop: { rules: $stopRules },
      reporting: { morning: "brief", tldraw: "optional" },
      receipts: { queryLog: "receipts.jsonl", proveNoWrite: ($grant == "read-only") }
    }' > "$manifest"

  fm_run_state_set "$run_id" state intake
  fm_run_state_set "$run_id" generation 0
  fm_run_state_set "$run_id" updated "$(fm_run_now_iso)"
  fm_run_receipt_append "$run_id" lifecycle "new" created "mode=$mode submode=$submode lane=$lane grant=$grant"
  printf '%s\n' "$root"
}

require_unfrozen() {  # <run-id>
  fm_run_exists "$1" || fail "run $1 does not exist"
  ! fm_run_frozen "$1" \
    || refuse "run $1 is frozen; a run cannot expand its own manifest (start a new run instead)"
}

command_set() {
  local run_id=${1:-} path=${2:-} value=${3:-} as_json=0 manifest tmp
  [ "$#" -ge 3 ] || { usage >&2; exit 2; }
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) as_json=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  hold_run_lock "$run_id"
  require_unfrozen "$run_id"
  manifest=$(fm_run_manifest_path "$run_id")
  tmp="$manifest.tmp.$$"
  if [ "$as_json" = 1 ]; then
    jq --argjson v "$value" ".$path = \$v" "$manifest" > "$tmp" || fail "invalid JSON value for .$path"
  else
    jq --arg v "$value" ".$path = \$v" "$manifest" > "$tmp" || fail "could not set .$path"
  fi
  mv -f "$tmp" "$manifest"
  fm_run_receipt_append "$run_id" manifest ".$path" set "$value"
}

command_add() {
  local run_id=${1:-} path=${2:-} value=${3:-} manifest tmp
  [ "$#" -eq 3 ] || { usage >&2; exit 2; }
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  hold_run_lock "$run_id"
  require_unfrozen "$run_id"
  manifest=$(fm_run_manifest_path "$run_id")
  tmp="$manifest.tmp.$$"
  jq --arg v "$value" ".$path = ((.$path // []) + [\$v])" "$manifest" > "$tmp" \
    || fail "could not append to .$path"
  mv -f "$tmp" "$manifest"
  fm_run_receipt_append "$run_id" manifest ".$path" add "$value"
}

command_freeze() {
  local run_id=${1:-} manifest hash entry allowlist
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  fm_run_exists "$run_id" || fail "run $run_id does not exist"
  hold_run_lock "$run_id"
  if fm_run_frozen "$run_id"; then
    fm_run_manifest_verify "$run_id" || exit 1
    printf 'freeze: %s already frozen (%s)\n' "$run_id" "$(cat "$(fm_run_hash_path "$run_id")")"
    return 0
  fi
  manifest=$(fm_run_manifest_path "$run_id")
  jq -e . "$manifest" >/dev/null 2>&1 || fail "manifest is not valid JSON: $manifest"
  allowlist=$(fm_run_manifest_get "$run_id" '.tools.allowlist')
  [ -n "$allowlist" ] || fail "tools.allowlist must not be empty"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" != '*' ] || fail "tools.allowlist must not contain the catch-all '*'"
  done <<EOF
$allowlist
EOF
  hash=$(fm_run_sha256_file "$manifest") || exit 1
  printf '%s\n' "$hash" > "$(fm_run_hash_path "$run_id")"
  fm_run_receipt_append "$run_id" manifest frozen "$hash" ''
  printf 'freeze: %s %s\n' "$run_id" "$hash"
}

command_verify() {
  local run_id=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  fm_run_manifest_verify "$run_id" || exit 1
  printf 'verify: %s manifest matches its frozen hash\n' "$run_id"
}

command_show() {
  local run_id=${1:-} filter=${2:-.}
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  fm_run_exists "$run_id" || fail "run $run_id does not exist"
  jq -r "$filter" "$(fm_run_manifest_path "$run_id")"
}

command_state() {
  local run_id=${1:-} file
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_run_validate_id "$run_id" || exit 1
  file=$(fm_run_state_path "$run_id")
  [ -f "$file" ] || fail "run $run_id has no run state"
  cat "$file"
}

command_list() {
  local dir
  [ -d "$FM_RUN_ROOTS" ] || return 0
  for dir in "$FM_RUN_ROOTS"/*; do
    [ -d "$dir" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$dir")" \
      "$(fm_run_state_get "$(basename "$dir")" state)" \
      "$(fm_run_state_get "$(basename "$dir")" generation)"
  done
}

# --- custody ----------------------------------------------------------------

owner_token() {  # <explicit-or-empty>
  local token=${1:-}
  [ -n "$token" ] || token=${FM_RUN_OWNER:-}
  [ -n "$token" ] || token=$FM_HOME
  printf '%s\n' "$token"
}

require_custody() {  # <run-id> <owner>
  local recorded
  recorded=$(fm_run_state_get "$1" owner)
  [ -n "$recorded" ] || refuse "run $1 has no owner; claim it before mutating it"
  [ "$recorded" = "$2" ] \
    || refuse "run $1 is owned by $recorded, not $2; a takeover needs a quiesced run"
}

command_claim() {
  local run_id=${1:-} owner='' takeover=0 recorded state generation
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner) shift; owner=${1:-} ;;
      --takeover) takeover=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  fm_run_exists "$run_id" || fail "run $run_id does not exist"
  owner=$(owner_token "$owner")
  # Read, decide, and write inside the lock: this is the compare-and-swap.
  hold_run_lock "$run_id"
  recorded=$(fm_run_state_get "$run_id" owner)
  state=$(fm_run_state_get "$run_id" state)
  generation=$(fm_run_state_get "$run_id" generation)
  case "$generation" in ''|*[!0-9]*) generation=0 ;; esac
  if [ -n "$recorded" ] && [ "$recorded" != "$owner" ]; then
    [ "$takeover" = 1 ] \
      || refuse "run $run_id is owned by $recorded; pass --takeover from a quiesced run to transfer it"
    # A takeover is legal only where the previous owner can hold no live loop.
    # Everything else converges to old-owner-retains rather than two owners.
    case "$state" in
      intake|stop|report|cancel|done) ;;
      *) refuse "run $run_id is in state $state; its owner must checkpoint or stop before a takeover" ;;
    esac
  fi
  if [ "$recorded" = "$owner" ]; then
    printf 'claim: %s already owned by %s (generation %s)\n' "$run_id" "$owner" "$generation"
    return 0
  fi
  generation=$((generation + 1))
  fm_run_state_set "$run_id" owner "$owner"
  fm_run_state_set "$run_id" generation "$generation"
  fm_run_state_set "$run_id" updated "$(fm_run_now_iso)"
  fm_run_receipt_append "$run_id" custody "$owner" claimed "generation=$generation previous=${recorded:-none}"
  printf 'claim: %s owner=%s generation=%s\n' "$run_id" "$owner" "$generation"
}

# --- state machine ----------------------------------------------------------

transition_ok() {  # <from> <to>
  # cancel is reachable from every live state; done only from report.
  if [ "$2" = cancel ]; then
    [ "$1" != "done" ] || return 1
    return 0
  fi
  case "$1/$2" in
    intake/preflight) return 0 ;;
    preflight/baseline|baseline/plan|plan/dispatch|dispatch/supervise) return 0 ;;
    supervise/checkpoint|supervise/decision|supervise/plan|supervise/stop) return 0 ;;
    checkpoint/supervise|checkpoint/stop) return 0 ;;
    decision/supervise|decision/stop) return 0 ;;
    preflight/stop|baseline/stop|plan/stop|dispatch/stop) return 0 ;;
    stop/report|cancel/report) return 0 ;;
    report/done|report/resume) return 0 ;;
    resume/supervise) return 0 ;;
    *) return 1 ;;
  esac
}

set_state() {  # <run-id> <to> <note>
  fm_run_state_set "$1" state "$2"
  fm_run_state_set "$1" updated "$(fm_run_now_iso)"
  fm_run_receipt_append "$1" state "$2" entered "${3:-}"
}

command_advance() {
  local run_id=${1:-} target=${2:-} owner='' current
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner) shift; owner=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  in_list "$target" "$FM_RUN_STATES" || fail "unknown state: $target"
  case "$target" in
    preflight|checkpoint|stop|cancel|resume)
      fail "$target has its own command; advance drives the ordinary states only"
      ;;
  esac
  fm_run_exists "$run_id" || fail "run $run_id does not exist"
  fm_run_manifest_verify "$run_id" || exit 1
  owner=$(owner_token "$owner")
  hold_run_lock "$run_id"
  require_custody "$run_id" "$owner"
  current=$(fm_run_state_get "$run_id" state)
  transition_ok "$current" "$target" || refuse "run $run_id cannot go from $current to $target"
  set_state "$run_id" "$target" "from=$current"
  printf 'advance: %s %s -> %s\n' "$run_id" "$current" "$target"
}

# --- preflight --------------------------------------------------------------

# Which pass is asserting: the run's own preflight, or the revalidation a resume
# performs before it re-enters supervision. Only the wording differs; the
# assertions are deliberately identical, because a gate worth checking before the
# first dispatch is worth checking again before the next one.
FM_RUN_ASSERT_PHASE=preflight

preflight_fail() {  # <run-id> <reason>
  fm_run_receipt_append "$1" "$FM_RUN_ASSERT_PHASE" assertion failed "$2"
  printf 'fm-run: %s failed: %s\n' "$FM_RUN_ASSERT_PHASE" "$2" >&2
  exit 3
}

# The four identity facts run_assertions establishes, published as globals rather
# than printed. Printing them would force the caller into a command
# substitution, and a failed assertion's `exit` inside one kills only the
# subshell: preflight would then report success on a run that failed its checks.
FM_RUN_FACT_MODE=
FM_RUN_FACT_SUBMODE=
FM_RUN_FACT_LANE=
FM_RUN_FACT_GRANT=

# Every start assertion, with no state change of its own, so both the preflight
# command and resume's revalidation run exactly the same set.
run_assertions() {  # <run-id>
  local run_id=$1
  local mode submode grant lane lane_class config_root registered_class registered_root
  local allowlist denylist protected rules rule entry evidence authorized_at authorized_epoch now
  local project_count task_paths read_roots session_lanes surface_proof self_analysis vault_writer
  local cross_lane allowed_paths resolved

  [ "$(fm_run_manifest_get "$run_id" '.schemaVersion')" = "$FM_RUN_SCHEMA_VERSION" ] \
    || preflight_fail "$run_id" "manifest schemaVersion is not $FM_RUN_SCHEMA_VERSION"

  mode=$(fm_run_manifest_get "$run_id" '.mode')
  submode=$(fm_run_manifest_get "$run_id" '.submode')
  grant=$(fm_run_manifest_get "$run_id" '.authority.grant')
  in_list "$mode" "$FM_RUN_MODES" || preflight_fail "$run_id" "unknown mode $mode"
  mode_submode_valid "$mode" "$submode" || preflight_fail "$run_id" "mode $mode rejects submode $submode"
  [ "${grant%%:*}" = "$(submode_grant_kind "$mode" "$submode")" ] \
    || preflight_fail "$run_id" "grant $grant does not match submode $submode"

  # Bounded-improvement stays deferred until the fix-known pilots pass. The gate
  # is here rather than in prose so the mode cannot start by being described well.
  [ "$submode" != bounded-improvement ] \
    || preflight_fail "$run_id" "bounded-improvement is deferred until fix-known pilots pass; the captain must authorize enabling it"

  authorized_at=$(fm_run_manifest_get "$run_id" '.authority.captainAuthorizedAt')
  [ -n "$authorized_at" ] || preflight_fail "$run_id" "authority.captainAuthorizedAt is absent"
  authorized_epoch=$(iso_to_epoch "$authorized_at") \
    || preflight_fail "$run_id" "authority.captainAuthorizedAt is not parseable: $authorized_at"
  now=$(date -u +%s)
  [ "$authorized_epoch" -le "$now" ] \
    || preflight_fail "$run_id" "authority.captainAuthorizedAt is in the future: $authorized_at"

  lane=$(fm_run_manifest_get "$run_id" '.account.lane')
  lane_class=$(fm_run_manifest_get "$run_id" '.account.laneClass')
  config_root=$(fm_run_manifest_get "$run_id" '.account.configRoot')
  [ -n "$lane" ] || preflight_fail "$run_id" "account.lane is absent"
  read -r registered_class registered_root <<EOF
$(fm_run_lane_lookup "$lane" 2>/dev/null)
EOF
  [ -n "$registered_root" ] || preflight_fail "$run_id" "lane $lane is not registered in config/run-lanes.conf"
  [ "$config_root" = "$registered_root" ] \
    || preflight_fail "$run_id" "account.configRoot $config_root is not lane $lane's registered root $registered_root"
  [ "$lane_class" = "$registered_class" ] \
    || preflight_fail "$run_id" "account.laneClass $lane_class is not lane $lane's registered class $registered_class"
  [ -d "$config_root" ] || preflight_fail "$run_id" "lane $lane config root does not exist: $config_root"
  [ "$(fm_run_manifest_get "$run_id" '.account.isolationAsserted')" = true ] \
    || preflight_fail "$run_id" "account.isolationAsserted is false; profile isolation must be asserted before dispatch"

  allowlist=$(fm_run_manifest_get "$run_id" '.tools.allowlist')
  [ -n "$allowlist" ] || preflight_fail "$run_id" "tools.allowlist is empty"
  while IFS= read -r entry; do
    [ "$entry" != '*' ] || preflight_fail "$run_id" "tools.allowlist contains the catch-all '*'"
  done <<EOF
$allowlist
EOF
  denylist=$(fm_run_manifest_get "$run_id" '.tools.denylist')
  [ -n "$denylist" ] || preflight_fail "$run_id" "tools.denylist is empty"
  protected=$(fm_run_manifest_get "$run_id" '.writes.protectedPaths')
  [ -n "$protected" ] || preflight_fail "$run_id" "writes.protectedPaths is empty"

  rules=$(fm_run_manifest_get "$run_id" '.stop.rules')
  [ -n "$rules" ] || preflight_fail "$run_id" "stop.rules is empty"
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    in_list "$rule" "$FM_RUN_STOP_RULES" || preflight_fail "$run_id" "unknown stop rule: $rule"
  done <<EOF
$rules
EOF

  evidence=$(fm_run_manifest_get "$run_id" '.writes.evidenceDir')
  [ -n "$evidence" ] || preflight_fail "$run_id" "writes.evidenceDir is absent"
  # Resolve and validate BEFORE creating anything. Creating first meant a manifest
  # naming a path through a symlink to somewhere else got the refusal it deserved
  # and left a directory behind outside the run root anyway: a refusal that still
  # writes is not a refusal.
  resolved=$(fm_run_resolve_path "$evidence")
  fm_run_path_within "$(fm_run_resolve_path "$(fm_run_root "$run_id")")" "$resolved" \
    || preflight_fail "$run_id" "writes.evidenceDir must live inside the run root: $evidence"
  mkdir -p "$resolved" \
    || preflight_fail "$run_id" "could not create the evidence directory: $resolved"

  allowed_paths=$(fm_run_manifest_get "$run_id" '.writes.allowedPaths')
  if [ "$grant" = read-only ]; then
    [ -z "$allowed_paths" ] \
      || preflight_fail "$run_id" "a read-only run must declare no writes.allowedPaths"
    # A read-only grant's whole guarantee is the read boundary, and the read gate
    # can only bound what the manifest names. An empty list would leave the gate
    # with nothing to compare against and permit the entire filesystem, so the
    # run is refused here rather than at the first read that escapes.
    read_roots=$(fm_run_manifest_get "$run_id" '.source.readRoots')
    [ -n "$read_roots" ] \
      || preflight_fail "$run_id" "a read-only run needs a non-empty source.readRoots; the read gate bounds reads to the roots the manifest names, so an unbounded run is refused before it starts"
  else
    [ -n "$allowed_paths" ] \
      || preflight_fail "$run_id" "a $grant run must declare its writes.allowedPaths"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      resolved=$(fm_run_resolve_path "$entry")
      # Change-authorized work happens in a disposable worktree. Firstmate's own
      # home and its read-only project clones are never a legal write target.
      ! fm_run_path_within "$(fm_run_resolve_path "$FM_HOME")" "$resolved" \
        || preflight_fail "$run_id" "writes.allowedPaths must be an isolated worktree, not inside the firstmate home: $entry"
    done <<EOF
$allowed_paths
EOF
  fi

  case "$mode" in
    afk-app)
      project_count=$(fm_run_manifest_get "$run_id" '.source.projects' | grep -c . || true)
      [ "$project_count" -ge 1 ] || preflight_fail "$run_id" "afk-app needs at least one source.projects entry"
      ;;
    afk-obsidian-projects)
      task_paths=$(fm_run_manifest_get "$run_id" '.source.taskPaths')
      [ -n "$task_paths" ] \
        || preflight_fail "$run_id" "afk-obsidian-projects needs the exact frozen source.taskPaths; readiness is not authority"
      vault_writer=$(fm_run_manifest_get "$run_id" '.writes.vaultWriter')
      [ "$vault_writer" = firstmate-only ] \
        || preflight_fail "$run_id" "writes.vaultWriter must be firstmate-only; workers never write the vault"
      ;;
    afk-session-review)
      session_lanes=$(fm_run_manifest_get "$run_id" '.source.sessionLanes')
      [ -n "$session_lanes" ] || preflight_fail "$run_id" "afk-session-review needs source.sessionLanes"
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        fm_run_lane_lookup "$entry" >/dev/null 2>&1 \
          || preflight_fail "$run_id" "session lane $entry is not registered in config/run-lanes.conf"
      done <<EOF
$session_lanes
EOF
      if [ "$(printf '%s\n' "$session_lanes" | grep -c .)" -gt 1 ]; then
        cross_lane=$(fm_run_manifest_get "$run_id" '.privacy.crossLaneAllowed')
        [ "$cross_lane" = sanitized-abstract-pattern-only ] \
          || preflight_fail "$run_id" "a multi-lane review must set privacy.crossLaneAllowed to sanitized-abstract-pattern-only"
        [ "$(fm_run_manifest_get "$run_id" '.privacy.reconstructionTest')" = true ] \
          || preflight_fail "$run_id" "a multi-lane review must keep privacy.reconstructionTest true"
      fi
      ;;
    afk-jira-research)
      # Read-only here means the write tools are absent from the worker's surface,
      # not that the worker was asked nicely. Firstmate has no verified prover for
      # that absence yet, so this mode stops before access and names what is
      # missing instead of running on an unproven surface.
      surface_proof=$(fm_run_manifest_get "$run_id" '.tools.surfaceProof')
      [ -n "$surface_proof" ] && [ "$surface_proof" != null ] \
        || preflight_fail "$run_id" "afk-jira-research needs tools.surfaceProof: a verified record that every Atlassian write tool is absent from the worker surface (no such prover exists yet)"
      [ -f "$surface_proof" ] \
        || preflight_fail "$run_id" "tools.surfaceProof does not exist: $surface_proof"
      ;;
  esac

  self_analysis=$(fm_run_manifest_get "$run_id" '.selfAnalysis.enabled')
  if [ "$self_analysis" = true ]; then
    [ "$lane_class" = personal ] \
      || preflight_fail "$run_id" "self-analysis runs on a personal lane only; $lane is $lane_class"
    [ "$(fm_run_manifest_get "$run_id" '.selfAnalysis.subjectCaptainOnly')" = true ] \
      || preflight_fail "$run_id" "selfAnalysis.subjectCaptainOnly must stay true; no other person is ever analysed"
    [ "$mode" != afk-jira-research ] \
      || preflight_fail "$run_id" "a company-facing run never enables self-analysis"
  fi

  fm_run_receipt_append "$run_id" "$FM_RUN_ASSERT_PHASE" assertions passed \
    "mode=$mode submode=$submode lane=$lane grant=$grant"
  FM_RUN_FACT_MODE=$mode
  FM_RUN_FACT_SUBMODE=$submode
  FM_RUN_FACT_LANE=$lane
  FM_RUN_FACT_GRANT=$grant
}

command_preflight() {
  local run_id=${1:-} owner='' current
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner) shift; owner=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  fm_run_exists "$run_id" || fail "run $run_id does not exist"
  fm_run_manifest_verify "$run_id" || exit 1
  owner=$(owner_token "$owner")
  hold_run_lock "$run_id"
  require_custody "$run_id" "$owner"
  current=$(fm_run_state_get "$run_id" state)
  [ "$current" = intake ] || refuse "preflight runs from intake, not $current"

  FM_RUN_ASSERT_PHASE=preflight
  run_assertions "$run_id"
  set_state "$run_id" preflight "assertions=passed"
  printf 'preflight: %s passed (mode=%s submode=%s lane=%s grant=%s)\n' \
    "$run_id" "$FM_RUN_FACT_MODE" "$FM_RUN_FACT_SUBMODE" "$FM_RUN_FACT_LANE" "$FM_RUN_FACT_GRANT"
}

# --- gates ------------------------------------------------------------------

gate_manifest_ready() {  # <run-id>
  fm_run_require_jq || exit 1
  fm_run_validate_id "$1" || exit 1
  fm_run_exists "$1" || fail "run $1 does not exist"
  fm_run_manifest_verify "$1" || exit 1
}

command_tool_check() {
  local run_id=${1:-} tool=${2:-} grant pattern
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  gate_manifest_ready "$run_id"
  [ -n "$tool" ] || fail "a tool name is required"
  grant=$(fm_run_manifest_get "$run_id" '.authority.grant')

  for pattern in "${FM_RUN_ALWAYS_DENY[@]}"; do
    if fm_run_glob_match "$pattern" "$tool"; then
      fm_run_receipt_append "$run_id" tool "$tool" refused "always-deny:$pattern"
      refuse "tool $tool matches the built-in floor $pattern"
    fi
  done
  if [ "$grant" = read-only ]; then
    for pattern in "${FM_RUN_READONLY_DENY[@]}"; do
      if fm_run_glob_match "$pattern" "$tool"; then
        fm_run_receipt_append "$run_id" tool "$tool" refused "read-only-deny:$pattern"
        refuse "tool $tool matches the read-only floor $pattern"
      fi
    done
  fi
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if fm_run_glob_match "$pattern" "$tool"; then
      fm_run_receipt_append "$run_id" tool "$tool" refused "denylist:$pattern"
      refuse "tool $tool matches manifest denylist $pattern"
    fi
  done <<EOF
$(fm_run_manifest_get "$run_id" '.tools.denylist')
EOF
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if fm_run_glob_match "$pattern" "$tool"; then
      fm_run_receipt_append "$run_id" tool "$tool" allowed "allowlist:$pattern"
      printf 'tool-check: %s allowed\n' "$tool"
      return 0
    fi
  done <<EOF
$(fm_run_manifest_get "$run_id" '.tools.allowlist')
EOF
  fm_run_receipt_append "$run_id" tool "$tool" refused "not-in-allowlist"
  refuse "tool $tool is absent from this run's allowlist"
}

command_write_check() {
  local run_id=${1:-} path=${2:-} grant resolved evidence pattern entry
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  gate_manifest_ready "$run_id"
  [ -n "$path" ] || fail "a path is required"
  grant=$(fm_run_manifest_get "$run_id" '.authority.grant')

  # A write target whose final component is a symlink is refused outright rather
  # than resolved. Resolving it would answer the question about the link's target
  # at this instant, and the caller writes later: the link can be repointed in
  # between, so an "allowed" verdict would be a verdict about a path that no
  # longer exists. Refusing is the race-safe answer, and a write through a
  # symlink has no legitimate use inside an evidence or worktree area.
  if fm_run_symlink_leaf "$path"; then
    fm_run_receipt_append "$run_id" write "$path" refused "symlink-leaf"
    refuse "$path is a symlink; a write target must be a real path inside this run's write area"
  fi
  resolved=$(fm_run_resolve_path "$path")

  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if fm_run_glob_match "$pattern" "$resolved" || fm_run_glob_match "$pattern" "${resolved##*/}"; then
      fm_run_receipt_append "$run_id" write "$resolved" refused "protected:$pattern"
      refuse "$resolved matches protected path $pattern"
    fi
  done <<EOF
$(fm_run_manifest_get "$run_id" '.writes.protectedPaths')
EOF

  evidence=$(fm_run_resolve_path "$(fm_run_manifest_get "$run_id" '.writes.evidenceDir')")
  if fm_run_path_within "$evidence" "$resolved"; then
    fm_run_receipt_append "$run_id" write "$resolved" allowed evidence-dir
    printf 'write-check: %s allowed (evidence)\n' "$resolved"
    return 0
  fi
  if [ "$grant" != read-only ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if fm_run_path_within "$(fm_run_resolve_path "$entry")" "$resolved"; then
        fm_run_receipt_append "$run_id" write "$resolved" allowed "allowed-path:$entry"
        printf 'write-check: %s allowed (%s)\n' "$resolved" "$entry"
        return 0
      fi
    done <<EOF
$(fm_run_manifest_get "$run_id" '.writes.allowedPaths')
EOF
  fi
  fm_run_receipt_append "$run_id" write "$resolved" refused "outside-write-area"
  refuse "$resolved is outside this run's write area"
}

command_read_check() {
  local run_id=${1:-} path=${2:-} resolved lane other_lane other_class other_root roots root_seen=0 entry
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  gate_manifest_ready "$run_id"
  [ -n "$path" ] || fail "a path is required"
  # A read follows its final component rather than refusing it: reading through a
  # symlink is ordinary, and the resolver now yields the physical target, so the
  # containment checks below judge the file the read would actually open instead
  # of the name it was reached by.
  resolved=$(fm_run_resolve_path "$path")
  lane=$(fm_run_manifest_get "$run_id" '.account.lane')

  # Account partitioning: a run never reads another registered lane's config root.
  # This is the mechanical half of "company data stays on the company lane".
  while read -r other_lane other_class other_root; do
    case "$other_lane" in ''|'#'*) continue ;; esac
    [ -n "$other_root" ] || continue
    [ "$other_lane" != "$lane" ] || continue
    if fm_run_path_within "$(fm_run_resolve_path "$other_root")" "$resolved"; then
      fm_run_receipt_append "$run_id" read "$resolved" refused "other-lane:$other_lane class=$other_class"
      refuse "$resolved belongs to lane $other_lane, not this run's lane $lane"
    fi
  done <<EOF
$(all_registered_lanes)
EOF

  roots=$(fm_run_manifest_get "$run_id" '.source.readRoots')
  if [ -n "$roots" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if fm_run_path_within "$(fm_run_resolve_path "$entry")" "$resolved"; then
        root_seen=1
        break
      fi
    done <<EOF
$roots
EOF
    if [ "$root_seen" != 1 ] \
      && ! fm_run_path_within "$(fm_run_resolve_path "$(fm_run_root "$run_id")")" "$resolved"; then
      fm_run_receipt_append "$run_id" read "$resolved" refused "outside-read-roots"
      refuse "$resolved is outside this run's frozen source.readRoots"
    fi
  fi
  fm_run_receipt_append "$run_id" read "$resolved" allowed ''
  printf 'read-check: %s allowed\n' "$resolved"
}

# Every lane this home knows: the local registration file first, then the two
# built-in Claude lanes when the file did not already redefine them.
all_registered_lanes() {
  local file="$FM_RUN_CONFIG/run-lanes.conf" name class root seen=''
  if [ -f "$file" ]; then
    while read -r name class root; do
      case "$name" in ''|'#'*) continue ;; esac
      [ -n "$root" ] || continue
      printf '%s %s %s\n' "$name" "$class" "$root"
      seen="$seen $name"
    done < "$file"
  fi
  for name in company-claude personal-claude; do
    in_list "$name" "$seen" && continue
    printf '%s %s\n' "$name" "$(fm_run_lane_builtin "$name")"
  done
}

command_cross_lane_attest() {
  local run_id=${1:-} summary='' digest allowed
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary-file) shift; summary=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  gate_manifest_ready "$run_id"
  [ -n "$summary" ] || fail "--summary-file is required"
  [ -f "$summary" ] || fail "summary file does not exist: $summary"
  allowed=$(fm_run_manifest_get "$run_id" '.privacy.crossLaneAllowed')
  [ "$allowed" = sanitized-abstract-pattern-only ] \
    || refuse "this run's privacy.crossLaneAllowed is $allowed; nothing may cross lanes"
  [ "$(fm_run_manifest_get "$run_id" '.privacy.reconstructionTest')" = true ] \
    || refuse "privacy.reconstructionTest is false; a cross-lane summary needs the irreversibility test"
  digest=$(fm_run_sha256_file "$summary") || exit 1
  fm_run_receipt_append "$run_id" cross-lane "$digest" attested \
    "reconstruction-test=passed file=$(basename "$summary")"
  printf 'cross-lane-attest: %s %s\n' "$run_id" "$digest"
}

command_receipt() {
  local run_id=${1:-} kind=${2:-} subject=${3:-} verdict=${4:-} note=${5:-}
  [ "$#" -ge 4 ] || { usage >&2; exit 2; }
  fm_run_require_jq || exit 1
  fm_run_validate_id "$run_id" || exit 1
  fm_run_exists "$run_id" || fail "run $run_id does not exist"
  fm_run_receipt_append "$run_id" "$kind" "$subject" "$verdict" "$note"
}

command_prove_no_write() {
  local run_id=${1:-} file writes refusals
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  gate_manifest_ready "$run_id"
  [ "$(fm_run_manifest_get "$run_id" '.receipts.proveNoWrite')" = true ] \
    || fail "run $run_id did not declare receipts.proveNoWrite"
  file=$(fm_run_receipts_path "$run_id")
  [ -f "$file" ] || fail "run $run_id has no receipt log"
  local evidence
  evidence=$(fm_run_resolve_path "$(fm_run_manifest_get "$run_id" '.writes.evidenceDir')")
  writes=$(jq -r --arg dir "$evidence" '
    select(.kind == "write" and .verdict == "allowed")
    | select((.subject == $dir or (.subject | startswith($dir + "/"))) | not)
    | .subject' "$file")
  if [ -n "$writes" ]; then
    printf 'fm-run: prove-no-write failed for %s:\n%s\n' "$run_id" "$writes" >&2
    exit 3
  fi
  refusals=$(jq -r 'select(.verdict == "refused") | .subject' "$file" | grep -c . || true)
  # Say exactly what was proved. This reads the receipt log, so it can only speak
  # for writes that came through these gates; a process that wrote directly is
  # invisible here, and claiming "no write outside the evidence directory" implied
  # a filesystem audit this command never performs.
  printf 'prove-no-write: %s no outside write recorded through fm-run gates (refusals recorded: %s)\n' \
    "$run_id" "$refusals"
  printf 'prove-no-write: scope: receipts only; a write that never called the write gate leaves no record here\n'
}

# --- checkpoints, stop, resume ----------------------------------------------

command_checkpoint() {
  local run_id=${1:-} note='' resume_when='' owner='' current index
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) shift; note=${1:-} ;;
      --resume-when) shift; resume_when=${1:-} ;;
      --owner) shift; owner=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  gate_manifest_ready "$run_id"
  [ -n "$note" ] || fail "--note is required; a checkpoint records what is durable"
  owner=$(owner_token "$owner")
  hold_run_lock "$run_id"
  require_custody "$run_id" "$owner"
  current=$(fm_run_state_get "$run_id" state)
  index=$(write_checkpoint "$run_id" "$current" "$note" "$resume_when")
  if [ "$current" = supervise ]; then
    set_state "$run_id" checkpoint "checkpoint=$index"
    set_state "$run_id" supervise "checkpoint=$index"
  fi
  printf 'checkpoint: %s #%s\n' "$run_id" "$index"
}

# Write one durable checkpoint and print its index. Callers hold the run lock, so
# the read-increment-write of the checkpoint counter is atomic.
write_checkpoint() {  # <run-id> <state> <note> <resume-when>
  local run_id=$1 state=$2 note=$3 resume_when=$4 index file
  index=$(fm_run_state_get "$run_id" checkpoints)
  case "$index" in ''|*[!0-9]*) index=0 ;; esac
  index=$((index + 1))
  file="$(fm_run_root "$run_id")/checkpoints/$index.json"
  mkdir -p "$(dirname "$file")"
  jq -n --arg at "$(fm_run_now_iso)" --arg state "$state" --arg note "$note" \
    --arg resumeWhen "$resume_when" --argjson index "$index" \
    '{index: $index, at: $at, state: $state, note: $note, resumeWhen: $resumeWhen}' > "$file"
  fm_run_state_set "$run_id" checkpoints "$index"
  [ -z "$resume_when" ] || fm_run_state_set "$run_id" resume_when "$resume_when"
  fm_run_receipt_append "$run_id" checkpoint "$index" recorded "$note"
  printf '%s\n' "$index"
}

command_stop() {
  local run_id=${1:-} rule='' note='' resume_when='' owner='' current index
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rule) shift; rule=${1:-} ;;
      --note) shift; note=${1:-} ;;
      --resume-when) shift; resume_when=${1:-} ;;
      --owner) shift; owner=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  gate_manifest_ready "$run_id"
  [ -n "$rule" ] || fail "--rule is required (one of the manifest's frozen stop.rules)"
  owner=$(owner_token "$owner")
  hold_run_lock "$run_id"
  require_custody "$run_id" "$owner"
  fm_run_manifest_get "$run_id" '.stop.rules' | grep -Fxq -- "$rule" \
    || refuse "stop rule $rule is not in this run's frozen stop.rules"
  current=$(fm_run_state_get "$run_id" state)
  transition_ok "$current" stop || refuse "run $run_id cannot stop from $current"
  fm_run_state_set "$run_id" stop_rule "$rule"
  # Stopping means reaching a durable checkpoint, not just recording that a rule
  # fired. Leaving the checkpoint to a separate command the caller had to remember
  # made the safety procedure depend on memory; the stop writes it.
  index=$(write_checkpoint "$run_id" "$current" \
    "stop:$rule${note:+ - $note}" "$resume_when")
  set_state "$run_id" stop "rule=$rule checkpoint=$index ${note:+note=$note}"
  printf 'stop: %s rule=%s checkpoint=%s\n' "$run_id" "$rule" "$index"
}

command_cancel() {
  local run_id=${1:-} note='' owner='' current
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) shift; note=${1:-} ;;
      --owner) shift; owner=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  gate_manifest_ready "$run_id"
  [ -n "$note" ] || fail "--note is required; a cancellation records why"
  owner=$(owner_token "$owner")
  hold_run_lock "$run_id"
  require_custody "$run_id" "$owner"
  current=$(fm_run_state_get "$run_id" state)
  transition_ok "$current" cancel || refuse "run $run_id cannot cancel from $current"
  set_state "$run_id" cancel "note=$note"
  printf 'cancel: %s\n' "$run_id"
}

command_resume() {
  local run_id=${1:-} owner='' reauthorized='' current generation resumed authorized_at authorized_epoch now age
  [ -n "$run_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner) shift; owner=${1:-} ;;
      --reauthorized-at) shift; reauthorized=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  gate_manifest_ready "$run_id"
  owner=$(owner_token "$owner")
  hold_run_lock "$run_id"
  require_custody "$run_id" "$owner"
  generation=$(fm_run_state_get "$run_id" generation)
  resumed=$(fm_run_state_get "$run_id" resumed_generation)
  current=$(fm_run_state_get "$run_id" state)

  # Idempotent per generation: a second resume in the same generation is the
  # duplicate-loop bug this record exists to prevent, so it is a no-op, not a
  # second entry into supervise.
  if [ -n "$resumed" ] && [ "$resumed" = "$generation" ]; then
    printf 'resume: %s already resumed in generation %s (state %s)\n' "$run_id" "$generation" "$current"
    return 0
  fi

  authorized_at=$(fm_run_manifest_get "$run_id" '.authority.captainAuthorizedAt')
  authorized_epoch=$(iso_to_epoch "$authorized_at") || fail "authority.captainAuthorizedAt is not parseable"
  now=$(date -u +%s)
  age=$((now - authorized_epoch))
  if [ "$age" -gt "$FM_RUN_STALE_AUTHORITY_SECS" ] && [ -z "$reauthorized" ]; then
    [ -n "$(fm_run_state_get "$run_id" reauthorized_at)" ] \
      || refuse "run $run_id was authorized ${age}s ago; pass --reauthorized-at <iso8601> after confirming the captain's intent still stands"
  fi
  if [ -n "$reauthorized" ]; then
    iso_to_epoch "$reauthorized" >/dev/null || fail "--reauthorized-at is not an ISO 8601 timestamp"
    fm_run_state_set "$run_id" reauthorized_at "$reauthorized"
    fm_run_receipt_append "$run_id" authority "$reauthorized" reauthorized ''
  fi

  case "$current" in
    report|stop|cancel|resume|supervise) ;;
    *) refuse "run $run_id cannot resume from $current" ;;
  esac

  # Re-run every start assertion before re-entering supervision. Time passed
  # while the run was stopped: a lane can be de-registered, a config root can
  # disappear, an evidence directory can be moved onto a symlink. A gate worth
  # checking before the first dispatch is worth checking before the next one, so
  # resume revalidates rather than trusting that preflight once passed.
  FM_RUN_ASSERT_PHASE=resume-revalidation
  run_assertions "$run_id"
  FM_RUN_ASSERT_PHASE=preflight

  case "$current" in
    report) set_state "$run_id" resume "generation=$generation" ;;
    stop|cancel)
      set_state "$run_id" report "from=$current"
      set_state "$run_id" resume "generation=$generation"
      ;;
  esac
  [ "$(fm_run_state_get "$run_id" state)" = supervise ] || set_state "$run_id" supervise "resumed=$generation"
  fm_run_state_set "$run_id" resumed_generation "$generation"
  fm_run_receipt_append "$run_id" lifecycle resume entered "generation=$generation revalidated=yes"
  printf 'resume: %s generation=%s state=supervise revalidated=yes\n' "$run_id" "$generation"
}

# Only the wall-clock budget is decidable from the run's own durable record. The
# other frozen rules need the governor, a baseline, machine health, or a
# judgement, so they are named as unevaluated rather than silently reported as
# not firing: "rule=none" from a command that only ever checked the clock would
# read as a clean bill of health it never established.
command_check_stop() {
  local run_id=${1:-} created wall now elapsed rule unevaluated
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  gate_manifest_ready "$run_id"
  created=$(fm_run_manifest_get "$run_id" '.createdAt')
  wall=$(fm_run_manifest_get "$run_id" '.budgets.wallSeconds')
  case "$wall" in ''|*[!0-9]*) wall=0 ;; esac
  now=$(date -u +%s)
  elapsed=0
  if created=$(iso_to_epoch "$created" 2>/dev/null); then
    elapsed=$((now - created))
  fi
  rule=none
  if [ "$wall" -gt 0 ] && [ "$elapsed" -ge "$wall" ]; then
    rule=deadline
  fi
  unevaluated=$(fm_run_manifest_get "$run_id" '.stop.rules' \
    | grep -v '^deadline$' | paste -sd, - | sed 's/^,*//;s/,*$//')
  printf 'rule=%s elapsed=%s wall=%s\nunevaluated=%s\n' \
    "$rule" "$elapsed" "$wall" "${unevaluated:-none}"
}

command_summary() {
  local run_id=${1:-} file
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  gate_manifest_ready "$run_id"
  file=$(fm_run_receipts_path "$run_id")
  printf 'run=%s\n' "$run_id"
  printf 'mode=%s\n' "$(fm_run_manifest_get "$run_id" '.mode')"
  printf 'submode=%s\n' "$(fm_run_manifest_get "$run_id" '.submode')"
  printf 'grant=%s\n' "$(fm_run_manifest_get "$run_id" '.authority.grant')"
  printf 'lane=%s\n' "$(fm_run_manifest_get "$run_id" '.account.lane')"
  printf 'manifest_sha256=%s\n' "$(cat "$(fm_run_hash_path "$run_id")")"
  printf 'state=%s\n' "$(fm_run_state_get "$run_id" state)"
  printf 'generation=%s\n' "$(fm_run_state_get "$run_id" generation)"
  printf 'owner=%s\n' "$(fm_run_state_get "$run_id" owner)"
  printf 'checkpoints=%s\n' "$(fm_run_state_get "$run_id" checkpoints)"
  printf 'stop_rule=%s\n' "$(fm_run_state_get "$run_id" stop_rule)"
  printf 'resume_when=%s\n' "$(fm_run_state_get "$run_id" resume_when)"
  if [ -f "$file" ]; then
    printf 'receipts_total=%s\n' "$(grep -c . "$file" || true)"
    printf 'receipts_refused=%s\n' "$(jq -r 'select(.verdict == "refused") | .kind' "$file" | grep -c . || true)"
  else
    printf 'receipts_total=0\nreceipts_refused=0\n'
  fi
  printf 'evidence_dir=%s\n' "$(fm_run_manifest_get "$run_id" '.writes.evidenceDir')"
}

case "${1:-}" in
  new) shift; command_new "$@" ;;
  set) shift; command_set "$@" ;;
  add) shift; command_add "$@" ;;
  freeze) shift; command_freeze "$@" ;;
  verify) shift; command_verify "$@" ;;
  show) shift; command_show "$@" ;;
  state) shift; command_state "$@" ;;
  list) shift; command_list "$@" ;;
  claim) shift; command_claim "$@" ;;
  preflight) shift; command_preflight "$@" ;;
  advance) shift; command_advance "$@" ;;
  tool-check) shift; command_tool_check "$@" ;;
  write-check) shift; command_write_check "$@" ;;
  read-check) shift; command_read_check "$@" ;;
  cross-lane-attest) shift; command_cross_lane_attest "$@" ;;
  receipt) shift; command_receipt "$@" ;;
  prove-no-write) shift; command_prove_no_write "$@" ;;
  checkpoint) shift; command_checkpoint "$@" ;;
  check-stop) shift; command_check_stop "$@" ;;
  stop) shift; command_stop "$@" ;;
  cancel) shift; command_cancel "$@" ;;
  resume) shift; command_resume "$@" ;;
  summary) shift; command_summary "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
