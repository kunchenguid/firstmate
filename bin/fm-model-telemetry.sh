#!/usr/bin/env bash
# Own the private append-only model-attempt ledger and its recovery receipts.
#
# Usage:
#   fm-model-telemetry.sh intake --state <dir> --task <id> --payload <json>
#   fm-model-telemetry.sh terminal --state <dir> --task <id> [--attempt <mra_uuid>] --payload <json>
#   fm-model-telemetry.sh terminal-facts --state <dir> --task <id> [--attempt <mra_uuid>] --payload <json>
#   fm-model-telemetry.sh seal-or-incomplete --state <dir> --task <id> [--attempt <mra_uuid>] [--terminal-payload <json>]
#   fm-model-telemetry.sh usage --attempt <mra_uuid> --worktree <absolute-path>
#   fm-model-telemetry.sh candidate-register --candidate <id> --payload <json>
#   fm-model-telemetry.sh candidate-verdict --comparison <mrc_uuid> --verdict <adopted|discarded> --rollback-evidence <tested|documented>:<id>
#   fm-model-telemetry.sh sheet [--format json|csv|md]
#   fm-model-telemetry.sh subscription-sheet [--from <bound>] [--to <bound>] [--format json|csv|md]
#     A bound is a UTC RFC3339 timestamp or a bare YYYY-MM-DD date; a bare date
#     on --to covers that whole day. Anything else is refused rather than
#     silently narrowing the window.
#     Join intake+terminal over a bounded startedAt window and group by the
#     subscription axes (harness, provider, accountProfile, dispatchModelFamily,
#     model) to report attempts, acceptance, cost, tokens, task classes served,
#     quota utilization, and the usageSource breakdown. Proof that the existing
#     telemetry join answers a subscription-renewal question without a dashboard.
#   fm-model-telemetry.sh spawn-failures [--from <bound>] [--to <bound>] [--format json|csv|md]
#     Group recorded pre-launch spawn refusals over a bounded attemptedAt window
#     by the same pool axes the failure payload carries (harness, provider,
#     accountProfile, dispatchModelFamily, model) and report the failureKind,
#     capability, and quotaReader breakdown plus the most recent exact cause.
#     This is the read surface that makes login or credential rot visible; the
#     attempt projections stay attempt-only.
#   fm-model-telemetry.sh spawn-failure --state <dir> --task <id> --payload <json>
#     Record a pre-launch spawn refusal (credential, quota, validation, etc.)
#     with its exact cause so login or credential rot is visible in the join.
#     Best-effort evidence: the caller wraps it so a telemetry failure never
#     changes the spawn's own exit code.
#
# The ledger is FM_DATA_OVERRIDE/data/routing-outcomes.jsonl when that override
# is set, otherwise FM_HOME/data/routing-outcomes.jsonl. A pre-existing ledger is
# tightened to mode 600 before a write instead of being refused; a symlink or
# non-regular ledger is still refused.
# An intake payload is the V1 intake object plus privacy, with taskRootId either
# omitted/null for a new root or set to an existing opaque root for a retry.
# The writer generates eventId and attemptId, records a private receipt at
# state/model-telemetry-receipts/<task>.json, and prints a compact JSON result.
# A receipt is {schemaVersion,task,phase,attemptId,taskRootId,payloadSha256}; its
# phase is prepared or intake-recorded, and it contains no task/model content.
# Idempotency is reserved for an exact crash-recovery replay: only a receipt
# still in phase prepared replays its attempt, and only for that identical
# payload. Every other intake for a task that still holds a receipt is a genuine
# relaunch: the recorded prior attempt is sealed incomplete and the new attempt
# is recorded under the prior task root with the prior attempt as its parent, so
# a stale receipt never locks a task out of relaunching. A prepared receipt
# whose attempt reached no ledger row reserves nothing and is discarded.
# Terminal and seal-or-incomplete take their attempt from --attempt when the
# caller supplies one, and from the receipt selected by --task otherwise. A
# caller-supplied attempt is authoritative because the caller owns the task
# lifecycle: a receipt that is unreadable or names another attempt is reported
# as a warning and never refuses, so telemetry bookkeeping cannot block a
# teardown. Only a caller with no attempt of its own depends on the receipt.
# Omitting --terminal-payload seals the canonical incomplete terminal with null
# end and wall values; cleanup state is never interpreted as success. An attempt
# that already carries a terminal satisfies that implicit seal as a no-op, so a
# teardown retried after an explicit terminal is never locked out of cleanup.
# An explicit --terminal-payload that contradicts a recorded terminal still
# refuses, because a recorded terminal is immutable.
# A refused terminal has no bypass: the refusal names the ledger path and either
# the offending line or the attempt whose intake row is missing. Repair the
# ledger itself (restore the intake row or the malformed line from a backup and
# its regular-file form), confirm with
# `fm-model-telemetry.sh sheet --format json`, then re-run the caller.
# terminal-facts accepts only observable gate facts, outcome identity, directly
# reported usage, optional session-observed wall time, and an optional typed
# primaryFailureClass the caller already knows. It derives classification,
# first-pass acceptance, correction count, and end time at the immutable
# terminal seal, and preserves the observed wall time without substituting
# intake-to-seal elapsed time. A non-green gate uses the caller's class when
# present; a green gate is always none.
# Routing candidate registration and verdict rows share this canonical ledger
# under the additive firstmate.model-routing-candidate/v1 schema, so an older
# attempt-only reader treats them as opaque foreign rows instead of rejecting
# its V1 ledger during rollback.
# Registration freezes a task-class-blocked comparison method, exact candidate
# and comparator model/version tuples, minimum observations per model/class,
# time window, and rollback criterion before outcomes. A verdict counts one
# eligible quality outcome per distinct task root after registration and inside
# that window. Cancelled, incomplete, quota-stopped, and known execution-
# environment failures do not count. Every model/version/CLI and task-class
# cell reports its n, accepted-first-pass count, and rate; every cell must meet
# the frozen minimum (at least six), adoption must meet the frozen rollback
# threshold, and either verdict requires concrete rollback evidence. These two
# commands own only the
# candidate-to-adopted-or-
# discarded transition; they are not a general approval workflow.
# Task-terminal failure and forced-cancellation triggers remain compatible with
# the original V1 gate-source enum: terminal-facts records the trigger as a
# bounded transition evidence ref and keeps gateFacts.source=delivery.
# The read-only usage command derives the harness and attempt start from the
# immutable intake, then returns token totals and active wall time from durable
# harness sessions whose recorded cwd and start time identify that exact attempt.
# Its result is {usage:{inputTokens,outputTokens,cost,currency},wallSeconds}.
# Codex, Claude, Pi/pi-signed, and OpenCode have verified local sources; every
# other harness or missing exact match returns null facts. FM_CODEX_SESSIONS_OVERRIDE,
# FM_CLAUDE_PROJECTS_OVERRIDE, FM_PI_SESSIONS_OVERRIDE, and
# FM_OPENCODE_DB_OVERRIDE replace those source roots for hermetic verification.
# gate.stepReruns is how many delivery-gate steps ran a round beyond their
# first, counted once per extra round of a step. It is NOT a count of
# correction cycles: one review fix whose follow-up also re-runs `document` is
# two step reruns. The V1 correctionCount field mirrors it on this mechanical
# path, but the sheet's stepReruns column reads gateFacts.stepReruns and nothing
# else, because correctionCount also carries a caller-authored correction count
# on the explicit terminal path. A row
# with no observed gate therefore reports stepReruns absent, never 0, so a
# superseded or caller-sealed attempt never reads like a clean first pass.
# A green gate whose step-rerun count could not be read stays accepted with a
# null correctionCount rather than being downgraded to incomplete; the sheet
# reports that, and any accepted row with no gate-sourced count, as
# accepted-step-reruns-unknown.
# A green delivery gate is itself the acceptance oracle: exact local-main
# ancestry, a forge-confirmed merge, or a completed scout report gate. The
# derived oracle evidence therefore mirrors green/failed while tests and
# reviewer evidence stay unknown unless no-mistakes supplied those facts.
# Usage cost is only ever a spend figure the harness itself reports as billed.
# No verified harness reports one today: every installed harness renders a
# cost computed from its own token counts and price catalog, which is the
# estimate this ledger refuses. Cost therefore stays null until such a source
# exists, and null stays distinct from a reported zero.
# New events are at most 64 KiB, use schema firstmate.model-run-telemetry/v1,
# and reject every field outside the V1 whitelist. New intake events may carry
# the explicit exploration decision and an OS-observed machine-load snapshot;
# older V1 events without those additive fields remain valid.
# Legacy rows, including rows carrying any other schemaVersion, are checked only
# for being JSON objects and are never changed; sheet projects them as legacyRaw
# and emits all formats to stdout without modifying the ledger.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/routing-outcomes.jsonl"
RECEIPT_DIR="$STATE/model-telemetry-receipts"
LOCK="$STATE/.model-telemetry.lock"
SCHEMA_VERSION=firstmate.model-run-telemetry/v1
CANDIDATE_SCHEMA_VERSION=firstmate.model-routing-candidate/v1
RECEIPT_VERSION=firstmate.model-run-telemetry-receipt/v1
MAX_EVENT_BYTES=65536

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  if [ -n "${DIAG_CONTEXT:-}" ]; then
    echo "error: model telemetry: $* [$DIAG_CONTEXT]" >&2
  else
    echo "error: model telemetry: $*" >&2
  fi
  exit 1
}

warn() {
  echo "warning: model telemetry: $*" >&2
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

require_safe_task_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*|*..*|*/*) die "unsafe task id" ;;
  esac
  [ "${#1}" -le 96 ] || die "unsafe task id"
}

require_opaque_id() {
  local kind=$1 value=$2 pattern=
  case "$kind" in
    attempt) pattern='^mra_[0-9a-f-]{36}$' ;;
    root) pattern='^mrt_[0-9a-f-]{36}$' ;;
    comparison) pattern='^mrc_[0-9a-f-]{36}$' ;;
    *) die "internal id validator error" ;;
  esac
  printf '%s' "$value" | grep -Eq "$pattern" || die "unsafe $kind id"
}

secure_dirs() {
  [ ! -L "$DATA" ] || die "data directory is a symlink"
  [ ! -L "$STATE" ] || die "state directory is a symlink"
  mkdir -p "$DATA" "$STATE"
  if [ -e "$RECEIPT_DIR" ]; then
    [ -d "$RECEIPT_DIR" ] && [ ! -L "$RECEIPT_DIR" ] || die "receipt directory is not a regular directory"
    [ "$(path_mode "$RECEIPT_DIR")" = 700 ] || die "receipt directory mode must be 700"
  else
    mkdir "$RECEIPT_DIR"
    chmod 0700 "$RECEIPT_DIR"
  fi
}

validate_private_file() {
  local path=$1 label=$2
  [ ! -L "$path" ] || die "$label is a symlink"
  [ -e "$path" ] || return 0
  [ -f "$path" ] || die "$label is not a regular non-symlink file"
  [ "$(path_mode "$path")" = 600 ] || die "$label mode must be 600"
}

sha256_text() {
  node -e 'const c=require("crypto");let s="";process.stdin.setEncoding("utf8");process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(c.createHash("sha256").update(s).digest("hex")+"\n"));'
}

new_uuid() {
  node -e 'process.stdout.write(require("crypto").randomUUID()+"\n")'
}

now_rfc3339() {
  # Test-only wall-clock seam; production leaves the override unset.
  if [ -n "${FM_MODEL_TELEMETRY_NOW_OVERRIDE:-}" ]; then
    printf '%s' "$FM_MODEL_TELEMETRY_NOW_OVERRIDE" |
      grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ||
      die "invalid telemetry clock override"
    printf '%s\n' "$FM_MODEL_TELEMETRY_NOW_OVERRIDE"
    return
  fi
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

canonical_json() {
  printf '%s' "$1" | jq -ceS '.' 2>/dev/null || die "malformed JSON payload"
}

validate_intake() {
  printf '%s' "$1" | jq -e '
    def keys_are($a): (keys|sort)==($a|sort);
    def oneof($a): . as $v | ($a|index($v))!=null;
    def safeid: type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._:-]+$");
    def accountprofile: type=="string" and length>=1 and length<=32 and test("^[a-z][a-z0-9-]*$");
    def sha: type=="string" and test("^[0-9a-f]{64}$");
    def dt: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
    def tuple:
      (keys_are(["harness","provider","model","effort","modelVersion","cliVersion"]) or
       keys_are(["harness","provider","model","effort","modelVersion","cliVersion","accountProfile"])) and
      (.harness|safeid) and (.provider==null or (.provider|type=="string" and length<=96)) and
      (.model==null or (.model|type=="string" and length<=160)) and
      (.effort|oneof(["low","medium","high","xhigh","max","default",null])) and
      (.modelVersion==null or (.modelVersion|type=="string" and length<=160)) and
      (.cliVersion==null or (.cliVersion|type=="string" and length<=160)) and
      (if has("accountProfile") then .harness=="claude" and (.accountProfile|accountprofile) else true end);
    def selection_keys:
      has("matchedRule") and has("configSha256") and has("fitReasons") and has("candidateAssessments") and has("quota")
      and all(keys[]; . as $k | (["matchedRule","configSha256","fitReasons","candidateAssessments","quota","routingSource","dispatchAttestation","dispatchModelFamily"] | index($k)) != null);
    def dispatch_attestation:
      (.routingSource==null or (.routingSource|oneof(["captain","profile","fallback","secondmate-config"]))) and
      (.dispatchModelFamily==null or (.dispatchModelFamily|type=="string" and length>=1 and length<=96)) and
      (.dispatchAttestation as $da | ($da==null or
        ($da|keys_are(["kind"]) and $da.kind=="resolved") or
        ($da|keys_are(["kind","reason"]) and $da.kind=="override" and
          ($da.reason|type=="string" and length>=1 and length<=160))));
    def selection:
      selection_keys and
      (.matchedRule==null or (.matchedRule|type=="string" and test("^(rule-[0-9]+|default)$"))) and
      (.configSha256==null or (.configSha256|sha)) and
      (.fitReasons|type=="array" and length<=12 and all(.[]; oneof(["captain-override","task-class","required-tool","catalog-support","native-adapter","oracle-strength","tie-break"]))) and
      (.candidateAssessments|type=="array" and length<=16 and all(.[];
        keys_are(["tuple","eligibility","reasons"]) and (.tuple|tuple) and
        (.eligibility|oneof(["selected","eligible","blocked","unknown"])) and
        (.reasons|type=="array" and length<=8 and all(.[]; oneof(["class-fit","catalog-supported","credential-unusable","quota-tight","quota-exhausted","headroom-unknown","model-unsupported","tool-missing","tie-break"]))))) and
      (.quota|keys_are(["decision","headroom","runway","observedAt"]) and
        (.decision|oneof(["selected","stopped","not-applicable","unknown"])) and
        (.headroom|oneof(["sufficient","tight","exhausted","unmeasurable","unknown"])) and
        (.runway|oneof(["sufficient","tight","exhausted","unmeasurable","unknown"])) and
        (.observedAt==null or (.observedAt|dt))) and
      dispatch_attestation;
    def neutral:
      keys_are(["correlation","capabilityProfile","owner","phase","behavioralResult"]) and
      (.correlation==null or (.correlation|safeid)) and
      (.capabilityProfile|oneof(["fast","balanced","strong","review-diverse","unresolved","not-applicable"])) and
      (.owner|oneof(["kit","external","unresolved","not-applicable"])) and
      (.phase==null or (.phase|type=="string" and length<=64)) and
      (.behavioralResult|oneof(["requested","started","passed","failed","blocked","refused","timed-out","unresolved","not-applicable"]));
    def evaluation:
      keys_are(["kind","fixtureId","fixtureManifestSha256","oracleId","oracleSha256","sourceCommit"]) and
      (.kind|oneof(["none","frozen-fixture","pilot-live"])) and
      (.fixtureId==null or (.fixtureId|type=="string" and length<=96)) and
      (.fixtureManifestSha256==null or (.fixtureManifestSha256|sha)) and
      (.oracleId==null or (.oracleId|type=="string" and length<=96)) and
      (.oracleSha256==null or (.oracleSha256|sha)) and
      (.sourceCommit==null or (.sourceCommit|type=="string" and test("^[0-9a-f]{7,64}$")));
    def exploration:
      keys_are(["kind","machineCondition"]) and
      (.kind|oneof(["none","deliberate"])) and
      (.machineCondition|keys_are(["observedAt","loadAverage1m","logicalCpuCount"]) and
        (.observedAt|dt) and (.loadAverage1m|type=="number" and .>=0) and
        (.logicalCpuCount|type=="number" and floor==. and .>=1));
    ((keys_are(["attemptClass","source","taskRootId","parentAttemptId","projectRef","taskClass","tuple","selection","neutralExecution","evaluation","startedAt","privacy"])) or
     (keys_are(["attemptClass","source","taskRootId","parentAttemptId","projectRef","taskClass","tuple","selection","neutralExecution","evaluation","exploration","startedAt","privacy"]))) and
    (.attemptClass|oneof(["real","synthetic","pilot"])) and
    (.source|oneof(["firstmate","spec-kit"])) and
    (.taskRootId==null or (.taskRootId|type=="string" and test("^mrt_[0-9a-f-]{36}$"))) and
    (.parentAttemptId==null or (.parentAttemptId|type=="string" and test("^mra_[0-9a-f-]{36}$"))) and
    (.projectRef|type=="string" and test("^project_[0-9a-f]{16,64}$")) and
    (.taskClass|oneof(["rote-reversible-edit","bounded-implementation-proven-root-fix","unknown-root-diagnosis","adversarial-review-security-review","evidence-heavy-research","long-horizon-repository-work","visual-browser-sensitive-work","documentation-specification-decision-extraction","external-wait-integration-work","unresolved"])) and
    (.tuple|tuple) and (.selection|selection) and (.neutralExecution|neutral) and (.evaluation|evaluation) and
    (if has("exploration") then (.exploration|exploration) and (.exploration.kind!="deliberate" or .taskClass=="bounded-implementation-proven-root-fix") else true end) and
    (.startedAt|dt) and
    (.privacy|keys_are(["classification","contentPolicy"]) and
      (.classification|oneof(["operational-minimized","synthetic-fixture","pilot-live"])) and
      .contentPolicy=="ids-codes-hashes-bounded-evidence-only")
  ' >/dev/null || die "intake payload violates the V1 whitelist"
}

# Every axis but model must be a concrete non-empty string on a new intake, so
# the eligibility bucketing this guards has an exact tuple to key on. The model
# axis alone may be explicit null: that is the one spelling of "no model was
# selected" (bin/fm-spawn.sh), and the literal string "default" is not a safe
# stand-in because it is indistinguishable from a dispatch profile literally
# named "default". An empty string or a missing field remain rejected.
validate_new_intake_versions() {
  printf '%s' "$1" | jq -e '
    (.tuple.model==null or (.tuple.model|type=="string" and length>=1)) and
    (.tuple.modelVersion|type=="string" and length>=1) and
    (.tuple.cliVersion|type=="string" and length>=1) and
    all(.selection.candidateAssessments[].tuple;
      (.model==null or (.model|type=="string" and length>=1)) and
      (.modelVersion|type=="string" and length>=1) and
      (.cliVersion|type=="string" and length>=1))
  ' >/dev/null || die "new intake requires a concrete model version and CLI version on every tuple, and the model axis itself must be null or a non-empty string"
}

# Historic rows may still carry quota.decision=unknown. New writes must name
# selected, stopped, or not-applicable; unknown counts as absent.
validate_new_intake_quota_decision() {
  printf '%s' "$1" | jq -e '
    def oneof($a): . as $v | ($a|index($v))!=null;
    (.selection.quota.decision|oneof(["selected","stopped","not-applicable"]))
  ' >/dev/null || die "new intake quota decision must be one of selected, stopped, not-applicable"
}

validate_terminal() {
  printf '%s' "$1" | jq -e '
    def keys_are($a): (keys|sort)==($a|sort);
    def oneof($a): . as $v | ($a|index($v))!=null;
    def safeid: type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._:-]+$");
    def dt: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
    def terminal_keys:
      (keys|sort)==(["classification","refusalQuality","endedAt","wallSeconds","firstPassAccepted","correctionCount","interventionCount","evidence","outcomeLink","usage","primaryFailureClass","flags","reclassification"]|sort) or
      (keys|sort)==(["classification","refusalQuality","endedAt","wallSeconds","firstPassAccepted","correctionCount","interventionCount","evidence","outcomeLink","usage","primaryFailureClass","flags","reclassification","gateFacts"]|sort) or
      (keys|sort)==(["classification","refusalQuality","endedAt","wallSeconds","firstPassAccepted","correctionCount","interventionCount","evidence","outcomeLink","usage","primaryFailureClass","flags","reclassification","usageSource"]|sort) or
      (keys|sort)==(["classification","refusalQuality","endedAt","wallSeconds","firstPassAccepted","correctionCount","interventionCount","evidence","outcomeLink","usage","primaryFailureClass","flags","reclassification","gateFacts","usageSource"]|sort);
    def usage_source:
      (.usageSource==null or (.usageSource|oneof(["recorded","no-verified-source","session-not-found","session-matched-no-tokens","unreadable","worktree-missing"])));
    (terminal_keys) and
    usage_source and
    (.classification|oneof(["accepted","rejected","failed","refused","timed-out","quota-stopped","cancelled","incomplete"])) and
    (.refusalQuality|oneof(["compliant","noncompliant","not-applicable","unknown"])) and
    (.endedAt==null or (.endedAt|dt)) and (.wallSeconds==null or (.wallSeconds|type=="number" and .>=0)) and
    (.firstPassAccepted==null or (.firstPassAccepted|type=="boolean")) and
    (.correctionCount==null or (.correctionCount|type=="number" and floor==. and .>=0)) and
    (.interventionCount|type=="number" and floor==. and .>=0) and
    (.evidence|keys_are(["tests","reviewer","oracle","refs"]) and
      (.tests|oneof(["pass","fail","not-run","unknown"])) and
      (.reviewer|oneof(["pass","fail","not-run","unknown"])) and
      (.oracle|oneof(["pass","fail","not-run","unknown"])) and
      (.refs|type=="array" and length<=16 and all(.[]; keys_are(["kind","id"]) and (.kind|oneof(["test","review","oracle","receipt","transition","report"])) and (.id|safeid)))) and
    (.outcomeLink|keys_are(["kind","id"]) and (.kind|oneof(["none","commit","pull-request","report","spec-kit-outcome"])) and (.id==null or (.id|type=="string" and length<=160))) and
    (.usage|keys_are(["inputTokens","outputTokens","cost","currency"]) and all([.inputTokens,.outputTokens,.cost][]; .==null or (type=="number" and .>=0)) and (.currency==null or (.currency|type=="string" and test("^[A-Z]{3}$")))) and
    (.primaryFailureClass|oneof(["none","capability","refusal","timeout","quota","tool","transport","environment","external-wait","scope-change","integrity","approval-wait","custody-wait","lease-conflict","state-divergence","outcome-observed-cause-unobserved","unknown"])) and
    (.flags|keys_are(["tool","transport","environment","externalWait","scopeChange","quota"]) and all([.tool,.transport,.environment,.externalWait,.scopeChange,.quota][]; type=="boolean")) and
    (.reclassification|keys_are(["fromTaskClass","toTaskClass","reasonCodes","escalated"]) and
      (.fromTaskClass==null or (.fromTaskClass|type=="string" and length<=96)) and (.toTaskClass==null or (.toTaskClass|type=="string" and length<=96)) and
      (.reasonCodes|type=="array" and length<=8 and all(.[]; oneof(["scope-expanded","root-unknown","oracle-changed","capability-miss","integrity-stop","quota-stop","external-block","none"]))) and
      (.escalated|type=="boolean")) and
    (if has("gateFacts") then
      (.gateFacts|keys_are(["source","result","stepReruns"]) and
        (.source|oneof(["no-mistakes","delivery"])) and
        (.result|oneof(["green","failed","cancelled","incomplete"])) and
        (.stepReruns==null or (.stepReruns|type=="number" and floor==. and .>=0)))
     else true end)
  ' >/dev/null || die "terminal payload violates the V1 whitelist"
}

validate_terminal_facts() {
  printf '%s' "$1" | jq -e '
    def keys_are($a): (keys|sort)==($a|sort);
    def oneof($a): . as $v | ($a|index($v))!=null;
    def safeid: type=="string" and length>=1 and length<=160;
    (keys_are(["gate","outcomeLink","usage"]) or keys_are(["gate","outcomeLink","usage","wallSeconds"]) or
     keys_are(["gate","outcomeLink","usage","usageSource"]) or keys_are(["gate","outcomeLink","usage","wallSeconds","usageSource"]) or
     keys_are(["gate","outcomeLink","usage","primaryFailureClass"]) or keys_are(["gate","outcomeLink","usage","wallSeconds","primaryFailureClass"]) or
     keys_are(["gate","outcomeLink","usage","usageSource","primaryFailureClass"]) or keys_are(["gate","outcomeLink","usage","wallSeconds","usageSource","primaryFailureClass"])) and
    (.gate|keys_are(["source","result","stepReruns"]) and
      (.source|oneof(["no-mistakes","delivery","task-terminal","teardown"])) and
      (.result|oneof(["green","failed","cancelled","incomplete"])) and
      (.stepReruns==null or (.stepReruns|type=="number" and floor==. and .>=0))) and
    (.outcomeLink|keys_are(["kind","id"]) and
      (.kind|oneof(["none","commit","pull-request","report","spec-kit-outcome"])) and
      (.id==null or (.id|safeid))) and
    (.usage|keys_are(["inputTokens","outputTokens","cost","currency"]) and
      all([.inputTokens,.outputTokens,.cost][]; .==null or (type=="number" and .>=0)) and
      (.currency==null or (.currency|type=="string" and test("^[A-Z]{3}$")))) and
    (.usageSource==null or (.usageSource|oneof(["recorded","no-verified-source","session-not-found","session-matched-no-tokens","unreadable","worktree-missing"]))) and
    (.primaryFailureClass==null or (.primaryFailureClass|oneof(["none","capability","refusal","timeout","quota","tool","transport","environment","external-wait","scope-change","integrity","approval-wait","custody-wait","lease-conflict","state-divergence","outcome-observed-cause-unobserved","unknown"]))) and
    (.wallSeconds==null or (.wallSeconds|type=="number" and .>=0))
  ' >/dev/null || die "terminal facts payload violates the whitelist"
}

# A spawn failure is a pre-launch refusal: the spawn never produced a model
# attempt, so it carries no attemptId. It records the pool/model/task-type
# that was refused and the exact cause so login or credential rot is visible
# in the telemetry join without conflating with model-run attempts. Spawn
# capability and quota-reader availability are recorded SEPARATELY so a
# quota-read login gap (quotaReader=credential-expired) never falsely marks
# the pool undispatchable (capability stays "supported"/"unknown", never
# "unsupported" for a reader gap). failureKind "quota-reader" is distinct
# from "quota": "quota-reader" is a quota-READ credential gap (pool still
# dispatchable, just can't read its quota right now); "quota" is real quota
# exhaustion that quota-axi successfully read. failureKind "catalog" is
# reserved for a future config/model-catalog.json validation gate; this home
# does not carry that inherited file, so fm-spawn never emits "catalog"
# today and the schema does not assume its contents.
validate_spawn_failure() {
  printf '%s' "$1" | jq -e '
    def keys_are($a): (keys|sort)==($a|sort);
    def oneof($a): . as $v | ($a|index($v))!=null;
    def safeid: type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._:-]+$");
    def accountprofile: type=="string" and length>=1 and length<=32 and test("^[a-z][a-z0-9-]*$");
    def dt: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
    def tuple:
      (keys_are(["harness","provider","model","effort","modelVersion","cliVersion"]) or
       keys_are(["harness","provider","model","effort","modelVersion","cliVersion","accountProfile"])) and
      (.harness|safeid) and (.provider==null or (.provider|type=="string" and length<=96)) and
      (.model==null or (.model|type=="string" and length<=160)) and
      (.effort|oneof(["low","medium","high","xhigh","max","default",null])) and
      (.modelVersion==null or (.modelVersion|type=="string" and length<=160)) and
      (.cliVersion==null or (.cliVersion|type=="string" and length<=160)) and
      (if has("accountProfile") then .harness=="claude" and (.accountProfile|accountprofile) else true end);
    def dispatch_attestation:
      (.routingSource==null or (.routingSource|oneof(["captain","profile","fallback","secondmate-config"]))) and
      (.dispatchModelFamily==null or (.dispatchModelFamily|type=="string" and length>=1 and length<=96)) and
      (.dispatchAttestation==null or
        (.dispatchAttestation as $da | ($da==null or
          ($da|keys_are(["kind"]) and $da.kind=="resolved") or
          ($da|keys_are(["kind","reason"]) and $da.kind=="override" and
            ($da.reason|type=="string" and length>=1 and length<=160)))));
    keys_are(["attemptedAt","tuple","taskClass","failureKind","cause","routingSource","dispatchAttestation","dispatchModelFamily","capability","quotaReader"]) and
    (.attemptedAt|dt) and
    (.tuple|tuple) and
    (.taskClass|oneof(["rote-reversible-edit","bounded-implementation-proven-root-fix","unknown-root-diagnosis","adversarial-review-security-review","evidence-heavy-research","long-horizon-repository-work","visual-browser-sensitive-work","documentation-specification-decision-extraction","external-wait-integration-work","unresolved"])) and
    (.failureKind|oneof(["credential","quota","quota-reader","harness-auth","validation","catalog","harness-missing","backend","other"])) and
    (.cause|type=="string" and length>=1 and length<=512) and
    (.capability|oneof(["supported","unsupported","unknown"])) and
    (.quotaReader|oneof(["available","credential-expired","not-applicable","unknown"])) and
    dispatch_attestation
  ' >/dev/null || die "spawn failure payload violates the whitelist"
}

validate_candidate_plan() {
  printf '%s' "$1" | jq -e '
    def keys_are($a): (keys|sort)==($a|sort);
    def harness_selector: type=="string" and length>=1 and length<=160 and test("^[A-Za-z0-9._:+/-]+$");
    def version: type=="string" and length>=1 and length<=160 and test("^[ -~]+$") and .!="unreported";
    def dt: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      ((try fromdateiso8601 catch null) != null);
    def task_class: IN("rote-reversible-edit","bounded-implementation-proven-root-fix","unknown-root-diagnosis","adversarial-review-security-review","evidence-heavy-research","long-horizon-repository-work","visual-browser-sensitive-work","documentation-specification-decision-extraction","external-wait-integration-work");
    def tuple:
      keys_are(["harness","model","modelVersion","cliVersion"]) and
      (.harness|harness_selector) and (.model|version and .!="default") and
      (.modelVersion|version and .!="default") and (.cliVersion|version);
    keys_are(["method","candidate","comparator","taskClasses","minimumPerModelClass","window","rollbackCriteria"]) and
    .method=="task-class-blocked" and (.candidate|tuple) and (.comparator|tuple) and
    .candidate!=.comparator and
    (.taskClasses as $classes | ($classes|type)=="array" and ($classes|length)>=1 and ($classes|length)<=10 and ($classes|unique|length)==($classes|length)) and
    all(.taskClasses[]; task_class) and
    (.minimumPerModelClass|type=="number" and floor==. and .>=6) and
    (.window|keys_are(["startedAt","endedAt"]) and (.startedAt|dt) and (.endedAt|dt) and .startedAt<.endedAt) and
    (.rollbackCriteria|keys_are(["metric","operator","threshold"]) and
      .metric=="accepted-first-pass-rate" and .operator=="below" and
      (.threshold|type=="number" and .>=0 and .<=1))
  ' >/dev/null || die "candidate comparison plan violates the whitelist"
}

validate_candidate_registration() {
  printf '%s' "$1" | jq -e '
    (keys|sort)==(["schemaVersion","eventType","eventId","comparisonId","candidateId","recordedAt","privacy","plan"]|sort) and
    (.comparisonId|test("^mrc_[0-9a-f-]{36}$")) and
    (.candidateId|type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._-]+$")) and
    (.privacy=={classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"})
  ' >/dev/null || die "candidate registration violates the envelope whitelist"
  validate_candidate_plan "$(printf '%s' "$1" | jq -cS .plan)"
}

validate_candidate_verdict() {
  printf '%s' "$1" | jq -e '
    (keys|sort)==(["schemaVersion","eventType","eventId","comparisonId","candidateId","recordedAt","privacy","verdict","rollbackEvidence","sample"]|sort) and
    (.comparisonId|test("^mrc_[0-9a-f-]{36}$")) and
    (.candidateId|type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._-]+$")) and
    (.verdict|IN("adopted","discarded")) and
    (.rollbackEvidence|keys|sort)==(["kind","id"]|sort) and
    (.rollbackEvidence.kind|IN("tested","documented")) and
    (.rollbackEvidence.id|type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._:-]+$")) and
    (.sample|keys|sort)==(["method","minimumPerModelClass","cells"]|sort) and
    .sample.method=="task-class-blocked" and
    (.sample.minimumPerModelClass|type=="number" and floor==. and .>=6) and
    (.sample.cells|type=="array" and length>=2 and all(.[];
      (keys|sort)==(["arm","harness","model","modelVersion","cliVersion","taskClass","observations","acceptedFirstPass","acceptedFirstPassRate"]|sort) and
      (.arm|IN("candidate","comparator")) and
      (.harness|type=="string") and (.model|type=="string") and
      (.modelVersion|type=="string") and (.cliVersion|type=="string") and
      (.taskClass|type=="string") and
      (.observations|type=="number" and floor==. and .>=0) and
      (.acceptedFirstPass|type=="number" and floor==. and .>=0) and
      .acceptedFirstPass<=.observations and
      (.acceptedFirstPassRate==null or (.acceptedFirstPassRate|type=="number" and .>=0 and .<=1)))) and
    (.privacy=={classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"})
  ' >/dev/null || die "candidate verdict violates the envelope whitelist"
}

validate_event() {
  local event=$1 expected=$2 version=$SCHEMA_VERSION
  case "$expected" in routing-candidate-*) version=$CANDIDATE_SCHEMA_VERSION ;; esac
  [ "$(printf '%s' "$event" | LC_ALL=C wc -c | tr -d ' ')" -le "$MAX_EVENT_BYTES" ] || die "event exceeds 64 KiB"
  printf '%s' "$event" | jq -e --arg version "$version" --arg type "$expected" '
    (.schemaVersion==$version) and (.eventType==$type) and
    (.eventId|type=="string" and test("^mre_[0-9a-f-]{36}$")) and
    (.recordedAt|type=="string") and
    (if $type=="attempt-intake" then
       (.attemptId|type=="string" and test("^mra_[0-9a-f-]{36}$")) and
       ((keys|sort)==(["schemaVersion","eventType","eventId","attemptId","recordedAt","privacy","intake"]|sort) or
        ((keys|sort)==(["schemaVersion","eventType","eventId","attemptId","recordedAt","privacy","taskId","intake"]|sort) and
         (.taskId|type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._-]+$"))))
     elif $type=="attempt-terminal" then
       (.attemptId|type=="string" and test("^mra_[0-9a-f-]{36}$")) and
       (keys|sort)==(["schemaVersion","eventType","eventId","attemptId","recordedAt","privacy","terminal"]|sort)
     elif $type=="spawn-failure" then
       (keys|sort)==(["schemaVersion","eventType","eventId","recordedAt","privacy","failure"]|sort)
     else true end)
  ' >/dev/null 2>&1 || die "generated event violates the envelope whitelist"
}

validate_ledger() {
  local line compact event_type payload lineno=0 verdict_line registration_line comparison event_id plan expected_sample recorded_sample
  [ ! -L "$LEDGER" ] || die "ledger is a symlink"
  [ ! -e "$LEDGER" ] || [ -f "$LEDGER" ] || die "ledger is not a regular non-symlink file"
  [ -e "$LEDGER" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ -n "$line" ] || continue
    DIAG_CONTEXT="$LEDGER line $lineno"
    compact=$(printf '%s' "$line" | jq -ce '.' 2>/dev/null) || die "ledger contains malformed JSON"
    [ "$(printf '%s' "$compact" | jq -r 'type')" = object ] || die "ledger row is not an object"
    if [ "$(printf '%s' "$compact" | jq -r '.schemaVersion // empty')" = "$SCHEMA_VERSION" ]; then
      event_type=$(printf '%s' "$compact" | jq -r .eventType)
      case "$event_type" in
        attempt-intake)
          validate_event "$line" attempt-intake
          payload=$(printf '%s' "$compact" | jq -cS '.intake + {privacy:.privacy}')
          validate_intake "$payload"
          ;;
        attempt-terminal)
          validate_event "$line" attempt-terminal
          payload=$(printf '%s' "$compact" | jq -cS .terminal)
          validate_terminal "$payload"
          ;;
        spawn-failure)
          validate_event "$line" spawn-failure
          payload=$(printf '%s' "$compact" | jq -cS .failure)
          validate_spawn_failure "$payload"
          ;;
        *) die "ledger contains an unknown event type" ;;
      esac
    elif [ "$(printf '%s' "$compact" | jq -r '.schemaVersion // empty')" = "$CANDIDATE_SCHEMA_VERSION" ]; then
      event_type=$(printf '%s' "$compact" | jq -r .eventType)
      case "$event_type" in
        routing-candidate-registered)
          validate_event "$line" routing-candidate-registered
          validate_candidate_registration "$compact"
          ;;
        routing-candidate-verdict)
          validate_event "$line" routing-candidate-verdict
          validate_candidate_verdict "$compact"
          ;;
        *) die "ledger contains an unknown event type" ;;
      esac
    fi
    DIAG_CONTEXT=
  done < "$LEDGER"
  DIAG_CONTEXT="$LEDGER"
  jq -eRcs --arg v "$SCHEMA_VERSION" --arg cv "$CANDIDATE_SCHEMA_VERSION" '
    split("\n") | map(select(length>0)|fromjson) |
    map(select(.schemaVersion==$v or .schemaVersion==$cv)) as $events |
    ($events | map(select(.eventType=="attempt-intake")) | group_by(.attemptId) | all(.[]; length==1)) and
    ($events | map(select(.eventType=="attempt-terminal")) | group_by(.attemptId) | all(.[]; length<=1)) and
    (all($events[] | select(.eventType=="attempt-terminal"); .attemptId as $a | any($events[]; .eventType=="attempt-intake" and .attemptId==$a))) and
    (all($events[] | select(.eventType=="attempt-intake" and .intake.parentAttemptId!=null);
      .intake.parentAttemptId as $p | .intake.taskRootId as $r |
      any($events[]; .eventType=="attempt-intake" and .attemptId==$p and .intake.taskRootId==$r))) and
    ($events | map(select(.eventType=="routing-candidate-registered")) | group_by(.comparisonId) | all(.[]; length==1)) and
    ($events | map(select(.eventType=="routing-candidate-registered")) | group_by(.candidateId) | all(.[]; length==1)) and
    ($events | map(select(.eventType=="routing-candidate-verdict")) | group_by(.comparisonId) | all(.[]; length<=1)) and
    (all($events | to_entries[] | select(.value.eventType=="routing-candidate-verdict");
      .key as $verdictIndex | .value as $verdict |
      any($events | to_entries[]; .key<$verdictIndex and .value.eventType=="routing-candidate-registered" and
        .value.comparisonId==$verdict.comparisonId and .value.candidateId==$verdict.candidateId)))
  ' "$LEDGER" >/dev/null || die "ledger violates attempt identity or sealing invariants"
  while IFS= read -r verdict_line; do
    comparison=$(printf '%s' "$verdict_line" | jq -r .comparisonId)
    event_id=$(printf '%s' "$verdict_line" | jq -r .eventId)
    registration_line=$(jq -c --arg v "$CANDIDATE_SCHEMA_VERSION" --arg comparison "$comparison" \
      'select(.schemaVersion==$v and .eventType=="routing-candidate-registered" and .comparisonId==$comparison)' "$LEDGER")
    plan=$(printf '%s' "$registration_line" | jq -cS .plan)
    expected_sample=$(candidate_sample "$comparison" "$plan" "$event_id") || die "recorded candidate verdict has an inadmissible sample"
    recorded_sample=$(printf '%s' "$verdict_line" | jq -cS .sample)
    [ "$(printf '%s' "$expected_sample" | jq -cS .)" = "$recorded_sample" ] || die "recorded candidate verdict sample does not match its frozen plan and preceding evidence"
    if [ "$(printf '%s' "$verdict_line" | jq -r .verdict)" = adopted ]; then
      printf '%s' "$recorded_sample" | jq -e --argjson threshold "$(printf '%s' "$plan" | jq -c .rollbackCriteria.threshold)" \
        'all(.cells[] | select(.arm=="candidate"); .acceptedFirstPassRate >= $threshold)' >/dev/null ||
        die "recorded adoption falls below its frozen rollback criterion"
    fi
  done < <(jq -c --arg v "$CANDIDATE_SCHEMA_VERSION" 'select(.schemaVersion==$v and .eventType=="routing-candidate-verdict")' "$LEDGER")
  DIAG_CONTEXT=
}

validate_ledger_for_write() {
  validate_ledger
  if [ -e "$LEDGER" ] && [ "$(path_mode "$LEDGER")" != 600 ]; then
    chmod 0600 "$LEDGER" 2>/dev/null || die "ledger mode could not be tightened to 600"
  fi
}

durable_append() {
  local event=$1
  node - "$LEDGER" "$event" <<'NODE'
const fs=require('fs');
const [path,event]=process.argv.slice(2);
const fd=fs.openSync(path,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_APPEND,0o600);
try { fs.writeSync(fd,event+'\n',null,'utf8'); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
NODE
  chmod 0600 "$LEDGER"
}

durable_receipt_write() {
  local path=$1 body=$2
  node - "$path" "$body" <<'NODE'
const fs=require('fs');
const [path,body]=process.argv.slice(2);
const dir=require('path').dirname(path);
const tmp=path+'.tmp.'+process.pid+'.'+require('crypto').randomBytes(6).toString('hex');
let fd=fs.openSync(tmp,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL,0o600);
try { fs.writeSync(fd,body+'\n',null,'utf8'); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
fs.renameSync(tmp,path);
fd=fs.openSync(dir,fs.constants.O_RDONLY);
try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
NODE
}

receipt_path() {
  printf '%s/%s.json\n' "$RECEIPT_DIR" "$1"
}

load_receipt() {
  local path=$1
  validate_private_file "$path" receipt
  [ -f "$path" ] || die "no telemetry receipt for task"
  jq -ce --arg version "$RECEIPT_VERSION" '
    def oneof($a): . as $v | ($a|index($v))!=null;
    (keys|sort)==(["schemaVersion","task","phase","attemptId","taskRootId","payloadSha256"]|sort) and
    .schemaVersion==$version and (.task|type=="string") and
    (.phase|oneof(["prepared","intake-recorded"])) and
    (.attemptId|test("^mra_[0-9a-f-]{36}$")) and (.taskRootId|test("^mrt_[0-9a-f-]{36}$")) and
    (.payloadSha256|test("^[0-9a-f]{64}$"))
  ' "$path" >/dev/null 2>&1 || die "malformed telemetry receipt"
  cat "$path"
}

with_lock_begin() {
  fm_lock_acquire_wait "$LOCK"
  LOCK_HELD=1
}

with_lock_end() {
  if [ "${LOCK_HELD:-0}" = 1 ]; then
    LOCK_HELD=0
    fm_lock_release "$LOCK"
  fi
}

trap with_lock_end EXIT

find_intake() {
  local attempt=$1
  [ -e "$LEDGER" ] || return 1
  jq -eRcs --arg v "$SCHEMA_VERSION" --arg a "$attempt" '
    split("\n") | map(select(length>0)|fromjson) |
    map(select(.schemaVersion==$v and .eventType=="attempt-intake" and .attemptId==$a)) |
    if length==1 then .[0] else empty end
  ' "$LEDGER"
}

find_terminal() {
  local attempt=$1
  [ -e "$LEDGER" ] || return 1
  jq -eRcs --arg v "$SCHEMA_VERSION" --arg a "$attempt" '
    split("\n") | map(select(length>0)|fromjson) |
    map(select(.schemaVersion==$v and .eventType=="attempt-terminal" and .attemptId==$a)) |
    if length==1 then .[0] else empty end
  ' "$LEDGER"
}

find_candidate_registration() {
  local comparison=$1
  [ -e "$LEDGER" ] || return 1
  jq -eRcs --arg v "$CANDIDATE_SCHEMA_VERSION" --arg comparison "$comparison" '
    split("\n") | map(select(length>0)|fromjson) |
    map(select(.schemaVersion==$v and .eventType=="routing-candidate-registered" and .comparisonId==$comparison)) |
    if length==1 then .[0] else empty end
  ' "$LEDGER"
}

find_candidate_registration_by_id() {
  local candidate=$1
  [ -e "$LEDGER" ] || return 1
  jq -eRcs --arg v "$CANDIDATE_SCHEMA_VERSION" --arg candidate "$candidate" '
    split("\n") | map(select(length>0)|fromjson) |
    map(select(.schemaVersion==$v and .eventType=="routing-candidate-registered" and .candidateId==$candidate)) |
    if length==1 then .[0] else empty end
  ' "$LEDGER"
}

find_candidate_verdict() {
  local comparison=$1
  [ -e "$LEDGER" ] || return 1
  jq -eRcs --arg v "$CANDIDATE_SCHEMA_VERSION" --arg comparison "$comparison" '
    split("\n") | map(select(length>0)|fromjson) |
    map(select(.schemaVersion==$v and .eventType=="routing-candidate-verdict" and .comparisonId==$comparison)) |
    if length==1 then .[0] else empty end
  ' "$LEDGER"
}

recorded_intake_identity() {
  printf '%s' "$1" | jq -cS '.intake + {privacy:.privacy} | .taskRootId=null' | sha256_text
}

payload_intake_identity() {
  printf '%s' "$1" | jq -cS '.taskRootId=null' | sha256_text
}

intake_command() {
  local task=$1 payload=$2 path canonical hash receipt attempt root event status parent parent_event
  local prior_attempt='' prior_root='' prior_phase='' prior_hash='' prior_intake='' superseded=''
  require_safe_task_id "$task"
  canonical=$(canonical_json "$payload")
  validate_intake "$canonical"
  validate_new_intake_versions "$canonical"
  validate_new_intake_quota_decision "$canonical"
  hash=$(printf '%s' "$canonical" | sha256_text)
  path=$(receipt_path "$task")
  with_lock_begin
  validate_ledger_for_write
  parent=$(printf '%s' "$canonical" | jq -r '.parentAttemptId // empty')
  root=$(printf '%s' "$canonical" | jq -r '.taskRootId // empty')
  if [ -n "$parent" ]; then
    [ -n "$root" ] || die "parent attempt requires an existing task root"
    parent_event=$(find_intake "$parent") || die "parent attempt does not exist"
    [ "$(printf '%s' "$parent_event" | jq -r .intake.taskRootId)" = "$root" ] || die "parent attempt belongs to another task root"
  fi
  attempt=
  if [ -e "$path" ] || [ -L "$path" ]; then
    receipt=$(load_receipt "$path")
    [ "$(printf '%s' "$receipt" | jq -r .task)" = "$task" ] || die "receipt task conflict"
    prior_attempt=$(printf '%s' "$receipt" | jq -r .attemptId)
    prior_root=$(printf '%s' "$receipt" | jq -r .taskRootId)
    prior_phase=$(printf '%s' "$receipt" | jq -r .phase)
    prior_hash=$(printf '%s' "$receipt" | jq -r .payloadSha256)
    if prior_intake=$(find_intake "$prior_attempt"); then
      if [ "$prior_phase" = prepared ] &&
        [ "$(recorded_intake_identity "$prior_intake")" = "$(payload_intake_identity "$canonical")" ]; then
        attempt=$prior_attempt
        root=$prior_root
      else
        superseded=$prior_attempt
      fi
    elif [ "$prior_phase" = prepared ] && [ "$prior_hash" = "$hash" ]; then
      attempt=$prior_attempt
      root=$prior_root
    fi
  fi
  if [ -n "$superseded" ]; then
    seal_open_attempt "$superseded"
    if [ -z "$parent" ] && { [ -z "$root" ] || [ "$root" = "$prior_root" ]; }; then
      parent=$superseded
      root=$prior_root
      canonical=$(printf '%s' "$canonical" | jq -cS --arg parent "$parent" --arg root "$root" '.parentAttemptId=$parent|.taskRootId=$root')
      validate_intake "$canonical"
      hash=$(printf '%s' "$canonical" | sha256_text)
    fi
  fi
  if [ -z "$attempt" ]; then
    attempt="mra_$(new_uuid)"
    [ -n "$root" ] || root="mrt_$(new_uuid)"
    require_opaque_id root "$root"
    receipt=$(jq -cn --arg v "$RECEIPT_VERSION" --arg task "$task" --arg attempt "$attempt" --arg root "$root" --arg hash "$hash" \
      '{schemaVersion:$v,task:$task,phase:"prepared",attemptId:$attempt,taskRootId:$root,payloadSha256:$hash}')
    durable_receipt_write "$path" "$receipt"
    [ "${FM_MODEL_TELEMETRY_TEST_CRASH:-}" != after-receipt ] || exit 86
  fi
  status=duplicate
  if ! find_intake "$attempt" >/dev/null; then
    event=$(jq -cnS --arg v "$SCHEMA_VERSION" --arg eid "mre_$(new_uuid)" --arg aid "$attempt" --arg at "$(now_rfc3339)" --arg root "$root" --arg taskid "$task" --argjson payload "$canonical" \
      '{schemaVersion:$v,eventType:"attempt-intake",eventId:$eid,attemptId:$aid,recordedAt:$at,privacy:$payload.privacy,taskId:$taskid,intake:($payload|del(.privacy)|.taskRootId=$root)}')
    validate_event "$event" attempt-intake
    durable_append "$event"
    status=recorded
    [ "${FM_MODEL_TELEMETRY_TEST_CRASH:-}" != after-append ] || exit 87
  fi
  receipt=$(printf '%s' "$receipt" | jq -c '.phase="intake-recorded"')
  durable_receipt_write "$path" "$receipt"
  with_lock_end
  jq -cn --arg status "$status" --arg attempt "$attempt" --arg root "$root" \
    '{status:$status,attemptId:$attempt,taskRootId:$root}'
}

# Sealed for an attempt whose receipt still shows it open with no terminal ever
# recorded: the slot it held (a relaunch's stale receipt, or a bare cleanup
# close) is being reclaimed without confirmed output, so the observed
# condition is a lease held past the point its work could still report in.
incomplete_terminal() {
  jq -cn '{classification:"incomplete",refusalQuality:"unknown",endedAt:null,wallSeconds:null,firstPassAccepted:null,correctionCount:null,interventionCount:0,evidence:{tests:"unknown",reviewer:"unknown",oracle:"unknown",refs:[]},outcomeLink:{kind:"none",id:null},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},primaryFailureClass:"lease-conflict",flags:{tool:false,transport:false,environment:false,externalWait:false,scopeChange:false,quota:false},reclassification:{fromTaskClass:null,toTaskClass:null,reasonCodes:["none"],escalated:false}}'
}

append_terminal_event() {
  local attempt=$1 canonical=$2 intake_event privacy event
  intake_event=$(find_intake "$attempt") ||
    die "terminal has no intake row for attempt $attempt in $LEDGER; restore that intake row before this task can be sealed"
  privacy=$(printf '%s' "$intake_event" | jq -cS .privacy)
  event=$(jq -cnS --arg v "$SCHEMA_VERSION" --arg eid "mre_$(new_uuid)" --arg aid "$attempt" --arg at "$(now_rfc3339)" --argjson privacy "$privacy" --argjson terminal "$canonical" \
    '{schemaVersion:$v,eventType:"attempt-terminal",eventId:$eid,attemptId:$aid,recordedAt:$at,privacy:$privacy,terminal:$terminal}')
  validate_event "$event" attempt-terminal
  durable_append "$event"
}

seal_open_attempt() {
  local attempt=$1
  if find_terminal "$attempt" >/dev/null 2>&1; then
    return 0
  fi
  append_terminal_event "$attempt" "$(incomplete_terminal)"
}

resolve_attempt_for_task() {
  local task=$1 attempt_arg=$2 path receipt
  path=$(receipt_path "$task")
  if [ -z "$attempt_arg" ]; then
    receipt=$(load_receipt "$path")
    [ "$(printf '%s' "$receipt" | jq -r .task)" = "$task" ] || die "receipt task conflict"
    printf '%s' "$receipt" | jq -r .attemptId
    return 0
  fi
  require_opaque_id attempt "$attempt_arg"
  if [ -e "$path" ] || [ -L "$path" ]; then
    if receipt=$(load_receipt "$path" 2>/dev/null); then
      if [ "$(printf '%s' "$receipt" | jq -r .task)" != "$task" ] ||
        [ "$(printf '%s' "$receipt" | jq -r .attemptId)" != "$attempt_arg" ]; then
        warn "receipt $path names another attempt; recording against the caller's attempt $attempt_arg"
      fi
    else
      warn "receipt $path is unreadable; recording against the caller's attempt $attempt_arg"
    fi
  fi
  printf '%s\n' "$attempt_arg"
}

seal_command() {
  local task=$1 attempt_arg=${2:-} path attempt status
  require_safe_task_id "$task"
  path=$(receipt_path "$task")
  with_lock_begin
  validate_ledger_for_write
  attempt=$(resolve_attempt_for_task "$task" "$attempt_arg")
  if find_terminal "$attempt" >/dev/null 2>&1; then
    status=duplicate
  else
    status=recorded
  fi
  seal_open_attempt "$attempt"
  rm -f "$path"
  with_lock_end
  jq -cn --arg status "$status" --arg attempt "$attempt" '{status:$status,attemptId:$attempt}'
}

terminal_command() {
  local task=$1 payload=$2 attempt_arg=${3:-} path attempt canonical existing status
  require_safe_task_id "$task"
  canonical=$(canonical_json "$payload")
  validate_terminal "$canonical"
  path=$(receipt_path "$task")
  with_lock_begin
  validate_ledger_for_write
  attempt=$(resolve_attempt_for_task "$task" "$attempt_arg")
  status=recorded
  if existing=$(find_terminal "$attempt"); then
    if [ "$(printf '%s' "$existing" | jq -cS .terminal)" = "$canonical" ]; then
      status=duplicate
    else
      die "terminal-conflict"
    fi
  else
    append_terminal_event "$attempt" "$canonical"
  fi
  rm -f "$path"
  with_lock_end
  jq -cn --arg status "$status" --arg attempt "$attempt" '{status:$status,attemptId:$attempt}'
}

terminal_facts_command() {
  local task=$1 payload=$2 attempt_arg=${3:-} path attempt facts ended wall terminal status usage_source
  require_safe_task_id "$task"
  facts=$(canonical_json "$payload")
  validate_terminal_facts "$facts"
  path=$(receipt_path "$task")
  with_lock_begin
  validate_ledger_for_write
  attempt=$(resolve_attempt_for_task "$task" "$attempt_arg")
  if find_terminal "$attempt" >/dev/null 2>&1; then
    status=duplicate
  else
    find_intake "$attempt" >/dev/null || die "terminal facts have no intake row"
    ended=$(now_rfc3339)
    wall=$(printf '%s' "$facts" | jq -c '.wallSeconds // null')
    usage_source=$(printf '%s' "$facts" | jq -c '.usageSource // null')
    terminal=$(jq -cnS --arg ended "$ended" --argjson wall "$wall" --argjson usageSource "$usage_source" --argjson facts "$facts" '
      ($facts.gate.result) as $result |
      ($facts.gate.stepReruns) as $reruns |
      ({classification:(if $result=="green" then "accepted" elif $result=="failed" then "failed" elif $result=="cancelled" then "cancelled" else "incomplete" end),
       refusalQuality:(if $result=="incomplete" then "unknown" else "not-applicable" end),
       endedAt:$ended,wallSeconds:$wall,
       firstPassAccepted:(if $result=="green" then (if $reruns==null then null else $reruns==0 end) elif $result=="failed" then false else null end),
       correctionCount:$reruns,interventionCount:0,
       evidence:{tests:(if $facts.gate.source=="no-mistakes" and $result=="green" then "pass" elif $facts.gate.source=="no-mistakes" and $result=="failed" then "fail" else "unknown" end),reviewer:(if $facts.gate.source=="no-mistakes" and $result=="green" then "pass" else "unknown" end),oracle:(if $result=="green" then "pass" elif $result=="failed" then "fail" else "not-run" end),refs:(if ($facts.gate.source|IN("task-terminal","teardown")) then [{kind:"transition",id:$facts.gate.source}] else [] end)},
       outcomeLink:$facts.outcomeLink,usage:$facts.usage,
       primaryFailureClass:(if $result=="green" then "none" else ($facts.primaryFailureClass // "unknown") end),
       flags:{tool:false,transport:false,environment:false,externalWait:false,scopeChange:false,quota:false},
       reclassification:{fromTaskClass:null,toTaskClass:null,reasonCodes:["none"],escalated:false},
       gateFacts:($facts.gate | .source=(if (.source|IN("task-terminal","teardown")) then "delivery" else .source end))}
       + (if $usageSource==null then {} else {usageSource:$usageSource} end))')
    validate_terminal "$terminal"
    append_terminal_event "$attempt" "$terminal"
    status=recorded
  fi
  rm -f "$path"
  with_lock_end
  jq -cn --arg status "$status" --arg attempt "$attempt" '{status:$status,attemptId:$attempt}'
}

# A spawn failure is best-effort evidence: it never blocks delivery and carries
# no receipt or recovery contract, because the spawn never produced a model
# attempt. The caller (fm-spawn) wraps this command so a telemetry failure
# cannot change the spawn's own exit code.
spawn_failure_command() {
  local task=$1 payload=$2 canonical event status
  require_safe_task_id "$task"
  canonical=$(canonical_json "$payload")
  validate_spawn_failure "$canonical"
  with_lock_begin
  validate_ledger_for_write
  event=$(jq -cnS --arg v "$SCHEMA_VERSION" --arg eid "mre_$(new_uuid)" --arg at "$(now_rfc3339)" --argjson payload "$canonical" \
    '{schemaVersion:$v,eventType:"spawn-failure",eventId:$eid,recordedAt:$at,privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"},failure:$payload}')
  validate_event "$event" spawn-failure
  durable_append "$event"
  status=recorded
  with_lock_end
  jq -cn --arg status "$status" '{status:$status}'
}

candidate_register_command() {
  local candidate=$1 payload=$2 canonical comparison event recorded window_end
  require_safe_task_id "$candidate"
  canonical=$(canonical_json "$payload")
  validate_candidate_plan "$canonical"
  window_end=$(printf '%s' "$canonical" | jq -r .window.endedAt)
  comparison="mrc_$(new_uuid)"
  with_lock_begin
  validate_ledger_for_write
  ! find_candidate_registration_by_id "$candidate" >/dev/null 2>&1 || die "routing candidate already has a registered transition"
  recorded=$(now_rfc3339)
  [[ "$recorded" < "$window_end" ]] || die "candidate comparison window has already ended"
  event=$(jq -cnS --arg v "$CANDIDATE_SCHEMA_VERSION" --arg eid "mre_$(new_uuid)" \
    --arg comparison "$comparison" --arg candidate "$candidate" --arg at "$recorded" \
    --argjson plan "$canonical" \
    '{schemaVersion:$v,eventType:"routing-candidate-registered",eventId:$eid,comparisonId:$comparison,candidateId:$candidate,recordedAt:$at,privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"},plan:$plan}')
  validate_event "$event" routing-candidate-registered
  validate_candidate_registration "$event"
  durable_append "$event"
  with_lock_end
  jq -cn --arg comparison "$comparison" --arg candidate "$candidate" '{status:"recorded",comparisonId:$comparison,candidateId:$candidate}'
}

candidate_sample() {
  local comparison=$1 plan=$2 max_event=${3:-}
  jq -eRcs --arg v "$SCHEMA_VERSION" --arg cv "$CANDIDATE_SCHEMA_VERSION" --arg comparison "$comparison" --arg maxEvent "$max_event" --argjson plan "$plan" '
    def instant: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      ((try fromdateiso8601 catch null) != null);
    split("\n") | map(select(length>0)|fromjson) | to_entries as $events |
    ($events | map(select(.value.schemaVersion==$cv and .value.eventType=="routing-candidate-registered" and .value.comparisonId==$comparison)) | first) as $registration |
    ($registration.key) as $registered |
    (if $maxEvent=="" then ($events|length) else ($events | map(select(.value.eventId==$maxEvent)) | first.key) end) as $limit |
    [ $plan.taskClasses[] as $class |
      ["candidate","comparator"][] as $arm |
      $plan[$arm] as $tuple |
      ([$events[] |
          select(.key>$registered and .key<$limit and .value.schemaVersion==$v and .value.eventType=="attempt-terminal" and
            (.value.terminal.classification|IN("accepted","rejected","failed","refused","timed-out")) and
            (all([.value.terminal.flags.tool,.value.terminal.flags.transport,.value.terminal.flags.environment,
              .value.terminal.flags.externalWait,.value.terminal.flags.scopeChange,.value.terminal.flags.quota][]; .==false)) and
            (.value.terminal.primaryFailureClass|IN("tool","transport","environment","external-wait","scope-change","quota")|not) and
            ((.value.terminal.classification=="accepted" and (.value.terminal.firstPassAccepted|type)=="boolean") or
              .value.terminal.classification!="accepted") and
            (.value.terminal.endedAt|instant) and
            .value.terminal.endedAt >= $registration.value.recordedAt and
            .value.terminal.endedAt >= $plan.window.startedAt and .value.terminal.endedAt <= $plan.window.endedAt and
            .value.recordedAt >= $plan.window.startedAt and .value.recordedAt <= $plan.window.endedAt) |
          .key as $eventIndex |
          .value as $terminal |
          ($events | map(.value) | map(select(.schemaVersion==$v and .eventType=="attempt-intake" and .attemptId==$terminal.attemptId)) | first) as $intake |
          select($intake!=null and $intake.intake.taskClass==$class and
            ($intake.intake.startedAt|instant) and
            $terminal.terminal.endedAt >= $intake.intake.startedAt and
            $intake.intake.startedAt >= $plan.window.startedAt and $intake.intake.startedAt <= $plan.window.endedAt and
            $intake.intake.tuple.harness==$tuple.harness and $intake.intake.tuple.model==$tuple.model and
            $intake.intake.tuple.modelVersion==$tuple.modelVersion and $intake.intake.tuple.cliVersion==$tuple.cliVersion) |
          {taskRoot:$intake.intake.taskRootId,eventIndex:$eventIndex,
           firstPass:($terminal.terminal.classification=="accepted" and $terminal.terminal.firstPassAccepted==true)}] |
        group_by(.taskRoot) | map(min_by(.eventIndex))) as $observed |
      ($observed | map(select(.firstPass==true)) | length) as $accepted |
      {arm:$arm,harness:$tuple.harness,model:$tuple.model,modelVersion:$tuple.modelVersion,cliVersion:$tuple.cliVersion,
       taskClass:$class,observations:($observed|length),acceptedFirstPass:$accepted,
       acceptedFirstPassRate:(if ($observed|length)==0 then null else $accepted/($observed|length) end)}
    ] as $cells |
    {method:$plan.method,minimumPerModelClass:$plan.minimumPerModelClass,cells:$cells} |
    .minimumPerModelClass as $minimum | select(all(.cells[]; .observations >= $minimum))
  ' "$LEDGER"
}

candidate_verdict_command() {
  local comparison=$1 verdict=$2 rollback=$3 registration plan sample candidate kind evidence_id event
  require_opaque_id comparison "$comparison"
  case "$verdict" in adopted|discarded) ;; *) die "candidate verdict must be adopted or discarded" ;; esac
  kind=${rollback%%:*}
  evidence_id=${rollback#*:}
  [ "$kind" != "$rollback" ] && [ -n "$evidence_id" ] || die "rollback evidence must be tested:<id> or documented:<id>"
  case "$kind" in tested|documented) ;; *) die "rollback evidence must be tested:<id> or documented:<id>" ;; esac
  printf '%s' "$evidence_id" | jq -eR 'length>=1 and length<=96 and test("^[A-Za-z0-9._:-]+$")' >/dev/null || die "unsafe rollback evidence id"
  with_lock_begin
  validate_ledger_for_write
  registration=$(find_candidate_registration "$comparison") || die "candidate comparison is not registered"
  ! find_candidate_verdict "$comparison" >/dev/null 2>&1 || die "candidate comparison already has a verdict"
  plan=$(printf '%s' "$registration" | jq -cS .plan)
  if ! sample=$(candidate_sample "$comparison" "$plan"); then
    die "insufficient sample for every predeclared model and task-class cell"
  fi
  if [ "$verdict" = adopted ] && ! printf '%s' "$sample" | jq -e --argjson threshold "$(printf '%s' "$plan" | jq -c .rollbackCriteria.threshold)" '
      all(.cells[] | select(.arm=="candidate"); .acceptedFirstPassRate >= $threshold)
    ' >/dev/null; then
    die "candidate evidence falls below the predeclared adoption threshold"
  fi
  candidate=$(printf '%s' "$registration" | jq -r .candidateId)
  event=$(jq -cnS --arg v "$CANDIDATE_SCHEMA_VERSION" --arg eid "mre_$(new_uuid)" \
    --arg comparison "$comparison" --arg candidate "$candidate" --arg at "$(now_rfc3339)" \
    --arg verdict "$verdict" --arg kind "$kind" --arg evidence "$evidence_id" --argjson sample "$sample" \
    '{schemaVersion:$v,eventType:"routing-candidate-verdict",eventId:$eid,comparisonId:$comparison,candidateId:$candidate,recordedAt:$at,privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"},verdict:$verdict,rollbackEvidence:{kind:$kind,id:$evidence},sample:$sample}')
  validate_event "$event" routing-candidate-verdict
  validate_candidate_verdict "$event"
  durable_append "$event"
  with_lock_end
  jq -cn --arg comparison "$comparison" --arg candidate "$candidate" --arg verdict "$verdict" --argjson sample "$sample" \
    '{status:"recorded",comparisonId:$comparison,candidateId:$candidate,verdict:$verdict,sample:$sample}'
}

usage_command() {
  local attempt=$1 worktree=$2 intake harness started observation
  require_opaque_id attempt "$attempt"
  case "$worktree" in /*) ;; *) die "--worktree must be absolute" ;; esac
  with_lock_begin
  validate_private_file "$LEDGER" ledger
  intake=$(find_intake "$attempt") || die "usage has no intake row for attempt $attempt"
  harness=$(printf '%s' "$intake" | jq -r .intake.tuple.harness)
  started=$(printf '%s' "$intake" | jq -r .intake.startedAt)
  with_lock_end
  if [ -n "${FM_MODEL_TELEMETRY_TEST_USAGE_OBSERVATION:-}" ]; then
    observation="$FM_MODEL_TELEMETRY_TEST_USAGE_OBSERVATION"
  else
    observation=$(NODE_NO_WARNINGS=1 node "$SCRIPT_DIR/fm-model-usage.mjs" "$harness" "$worktree" "$started") ||
      die "session usage collection failed"
  fi
  printf '%s' "$observation" | jq -e '
    (keys|sort)==["usage","usageSource","wallSeconds"] and
    (.usage|keys|sort)==["cost","currency","inputTokens","outputTokens"] and
    all([.usage.inputTokens,.usage.outputTokens,.usage.cost][]; .==null or (type=="number" and .>=0)) and
    (.usage.currency==null or (.usage.currency|type=="string" and test("^[A-Z]{3}$"))) and
    (.wallSeconds==null or (.wallSeconds | type=="number" and .>=0)) and
    (.usageSource|IN("recorded","session-not-found","session-matched-no-tokens","no-verified-source","unreadable","worktree-missing"))
  ' >/dev/null || die "session usage observation violates the whitelist"
  printf '%s\n' "$observation"
}

sheet_json() {
  [ -e "$LEDGER" ] || { printf '[]\n'; return; }
  jq -Rcs --arg v "$SCHEMA_VERSION" --arg cv "$CANDIDATE_SCHEMA_VERSION" '
    def blank($raw): {recordType:"legacy",schemaVersion:null,attemptId:null,taskId:null,quotaDecision:null,usageSource:null,taskRootId:null,parentAttemptId:null,source:null,attemptClass:null,projectRef:null,taskClass:null,harness:null,provider:null,model:null,modelVersion:null,cliVersion:null,effort:null,exploration:null,machineLoadAverage1m:null,machineLogicalCpuCount:null,state:"legacy",classification:null,quality:null,firstPassAccepted:null,correctionCount:null,stepReruns:null,gateSource:null,primaryFailureClass:null,startedAt:null,endedAt:null,wallSeconds:null,inputTokens:null,outputTokens:null,costReported:false,cost:null,currency:null,costPerAcceptedDelivery:null,legacyRaw:$raw};
    split("\n") | map(select(length>0)|fromjson) as $rows |
    ($rows | map(select(.schemaVersion!=$v and .schemaVersion!=$cv) | blank(.))) +
    ($rows | map(select(.schemaVersion==$v and .eventType=="attempt-intake")) | map(. as $i |
      ($rows | map(select(.schemaVersion==$v and .eventType=="attempt-terminal" and .attemptId==$i.attemptId)) | first) as $t |
      ($t.terminal.classification // null) as $classification |
      ($t.terminal.gateFacts.stepReruns // null) as $reruns |
      ($t.terminal.usage.cost // null) as $cost |
      {recordType:"attempt",schemaVersion:$v,attemptId:$i.attemptId,taskId:($i.taskId // null),quotaDecision:($i.intake.selection.quota.decision // null),usageSource:(if $t==null then null elif $t.terminal.usageSource==null then "absent" else $t.terminal.usageSource end),taskRootId:$i.intake.taskRootId,parentAttemptId:$i.intake.parentAttemptId,source:$i.intake.source,attemptClass:$i.intake.attemptClass,projectRef:$i.intake.projectRef,taskClass:$i.intake.taskClass,harness:$i.intake.tuple.harness,provider:$i.intake.tuple.provider,model:$i.intake.tuple.model,modelVersion:$i.intake.tuple.modelVersion,cliVersion:$i.intake.tuple.cliVersion,effort:$i.intake.tuple.effort,
       exploration:($i.intake.exploration.kind // null),machineLoadAverage1m:($i.intake.exploration.machineCondition.loadAverage1m // null),machineLogicalCpuCount:($i.intake.exploration.machineCondition.logicalCpuCount // null),
       state:(if $t==null then "open" else "terminal" end),classification:$classification,
       quality:(if $t==null then null elif $classification!="accepted" then $classification elif $reruns==null then "accepted-step-reruns-unknown" elif $reruns==0 then "accepted-first-pass" else "accepted-after-step-reruns" end),
       firstPassAccepted:($t.terminal.firstPassAccepted),correctionCount:($t.terminal.correctionCount // null),stepReruns:$reruns,gateSource:($t.terminal.gateFacts.source // null),primaryFailureClass:($t.terminal.primaryFailureClass // null),startedAt:$i.intake.startedAt,endedAt:($t.terminal.endedAt // null),wallSeconds:($t.terminal.wallSeconds // null),inputTokens:($t.terminal.usage.inputTokens // null),outputTokens:($t.terminal.usage.outputTokens // null),
       costReported:($cost|type=="number"),cost:$cost,currency:($t.terminal.usage.currency // null),costPerAcceptedDelivery:(if $classification=="accepted" then $cost else null end),legacyRaw:null}))
  ' "$LEDGER"
}

sheet_command() {
  local format=$1 json
  validate_ledger
  json=$(sheet_json)
  case "$format" in
    json) printf '%s\n' "$json" ;;
    csv)
      printf '%s\n' 'recordType,schemaVersion,attemptId,taskRootId,parentAttemptId,source,attemptClass,projectRef,taskClass,harness,provider,model,effort,exploration,machineLoadAverage1m,machineLogicalCpuCount,state,classification,quality,stepReruns,gateSource,primaryFailureClass,startedAt,endedAt,wallSeconds,inputTokens,outputTokens,costReported,cost,currency,costPerAcceptedDelivery,modelVersion,cliVersion,firstPassAccepted,correctionCount,legacyRaw,taskId,quotaDecision,usageSource'
      printf '%s' "$json" | jq -r '.[] | [.recordType,.schemaVersion,.attemptId,.taskRootId,.parentAttemptId,.source,.attemptClass,.projectRef,.taskClass,.harness,.provider,.model,.effort,.exploration,.machineLoadAverage1m,.machineLogicalCpuCount,.state,.classification,.quality,.stepReruns,.gateSource,.primaryFailureClass,.startedAt,.endedAt,.wallSeconds,.inputTokens,.outputTokens,.costReported,.cost,.currency,.costPerAcceptedDelivery,.modelVersion,.cliVersion,.firstPassAccepted,.correctionCount,(.legacyRaw|if .==null then null else tojson end),.taskId,.quotaDecision,.usageSource] | @csv'
      ;;
    md)
      printf '%s\n' '| type | attempt | root | parent | tuple | CLI | exploration | load | state | quality | first pass | corrections | step reruns | seconds | tokens in/out | cost | cost/accepted | failure | legacy | task | quota | usage |'
      printf '%s\n' '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|'
      printf '%s' "$json" | jq -r '.[] | def esc: if .==null then "" else tostring|gsub("\\|";"\\\\|")|gsub("\\n";" ") end; "| \(.recordType|esc) | \(.attemptId|esc) | \(.taskRootId|esc) | \(.parentAttemptId|esc) | \(([.harness,.model,.modelVersion,.effort]|map(select(.!=null))|join("/"))|esc) | \(.cliVersion|esc) | \(.exploration|esc) | \(([.machineLoadAverage1m,.machineLogicalCpuCount]|map(select(.!=null))|join("/"))|esc) | \(.state|esc) | \(.quality|esc) | \(.firstPassAccepted|esc) | \(.correctionCount|esc) | \(.stepReruns|esc) | \(.wallSeconds|esc) | \(([.inputTokens,.outputTokens]|map(select(.!=null))|join("/"))|esc) | \((if .costReported then ((.currency // "")+" "+(.cost|tostring)) else "absent" end)|esc) | \(.costPerAcceptedDelivery|esc) | \(.primaryFailureClass|esc) | \((.legacyRaw|if .==null then "" else tojson end)|esc) | \(.taskId|esc) | \(.quotaDecision|esc) | \(.usageSource|esc) |"'
      ;;
    *) die "sheet format must be json, csv, or md" ;;
  esac
}

# Per-subscription join of intake+terminal over a bounded window. This is the
# proof that the existing telemetry join answers a subscription-renewal
# question without a dashboard or parallel data path: it groups attempts by
# the axes that distinguish accounts (harness, provider, accountProfile,
# dispatchModelFamily, model) and reports attempts, acceptance, cost, tokens,
# task classes served, quota utilization, and the usageSource breakdown that
# names why any usage is absent. The markdown rendering folds that breakdown
# into recorded/unavailable/absent, where unavailable is every named reason the
# tokens are missing and absent is a legacy row that never named one; json and
# csv carry the per-reason counts. --from/--to bound startedAt to a
# representative window (a UTC RFC3339 timestamp or a bare YYYY-MM-DD date,
# which on --to covers that whole day); omit both for the whole ledger.
subscription_sheet_command() {
  local format=$1 from=$2 to=$3 json
  validate_ledger
  json=$(subscription_sheet_json "$from" "$to")
  case "$format" in
    json) printf '%s\n' "$json" ;;
    csv)
      printf '%s\n' 'subscription,harness,provider,accountProfile,dispatchModelFamily,model,attempts,accepted,rejectedOrFailed,open,cost,currency,inputTokens,outputTokens,taskClasses,quotaSelected,quotaStopped,quotaUnknown,headroomSufficient,headroomTight,headroomExhausted,headroomUnmeasurable,headroomUnknown,usageRecorded,usageNoVerifiedSource,usageSessionNotFound,usageSessionMatchedNoTokens,usageUnreadable,usageWorktreeMissing,usageAbsent'
      printf '%s' "$json" | jq -r '.[] | [.subscription,.harness,(.provider//""),(.accountProfile//""),(.dispatchModelFamily//""),(.model//""),.attempts,.accepted,.rejectedOrFailed,.open,(.cost//""),(.currency//""),(.inputTokens//""),(.outputTokens//""),(.taskClasses|join(";")),.quotaSelected,.quotaStopped,.quotaUnknown,.headroomSufficient,.headroomTight,.headroomExhausted,.headroomUnmeasurable,.headroomUnknown,.usageRecorded,.usageNoVerifiedSource,.usageSessionNotFound,.usageSessionMatchedNoTokens,.usageUnreadable,.usageWorktreeMissing,.usageAbsent] | @csv'
      ;;
    md)
      printf '%s\n' '| subscription | attempts | accepted | rejected/failed | open | cost | tokens in/out | task classes | quota selected/stopped/unknown | headroom sufficient/tight/exhausted | usage recorded/unavailable/absent |'
      printf '%s\n' '|---|---|---|---|---|---|---|---|---|---|---|'
      printf '%s' "$json" | jq -r '.[] | def esc: if .==null then "" else tostring|gsub("\\|";"\\\\|")|gsub("\\n";" ") end; "| \(.subscription|esc) | \(.attempts) | \(.accepted) | \(.rejectedOrFailed) | \(.open) | \((if .cost==null then "absent" else ((.currency // "")+" "+(.cost|tostring)) end)|esc) | \(([.inputTokens,.outputTokens]|map(select(.!=null))|join("/"))|esc) | \(.taskClasses|join(",")) | \(.quotaSelected)/\(.quotaStopped)/\(.quotaUnknown) | \(.headroomSufficient)/\(.headroomTight)/\(.headroomExhausted) | \(.usageRecorded)/\(.usageNoVerifiedSource + .usageSessionNotFound + .usageSessionMatchedNoTokens + .usageUnreadable + .usageWorktreeMissing)/\(.usageAbsent) |"'
      ;;
    *) die "subscription-sheet format must be json, csv, or md" ;;
  esac
}

# Recorded spawn refusals never became model attempts, so they are deliberately
# absent from the attempt projections. This is their own read surface: it groups
# by the pool axes the failure payload already carries and keeps the exact cause
# so a credential or quota-read gap is visible without grepping the raw ledger.
spawn_failures_command() {
  local format=$1 from=$2 to=$3 json
  validate_ledger
  json=$(spawn_failures_json "$from" "$to")
  case "$format" in
    json) printf '%s\n' "$json" ;;
    csv)
      printf '%s\n' 'pool,harness,provider,accountProfile,dispatchModelFamily,model,failures,failureKinds,taskClasses,capability,quotaReader,firstAt,lastAt,lastCause'
      printf '%s' "$json" | jq -r '.[] | [.pool,.harness,(.provider//""),(.accountProfile//""),(.dispatchModelFamily//""),(.model//""),.failures,([.failureKinds|to_entries[]|"\(.key)=\(.value)"]|join(";")),(.taskClasses|join(";")),(.capability|join(";")),(.quotaReader|join(";")),.firstAt,.lastAt,.lastCause] | @csv'
      ;;
    md)
      printf '%s\n' '| pool | failures | kinds | task classes | capability | quota reader | last at | last cause |'
      printf '%s\n' '|---|---|---|---|---|---|---|---|'
      printf '%s' "$json" | jq -r '.[] | def esc: if .==null then "" else tostring|gsub("\\|";"\\\\|")|gsub("\\n";" ") end; "| \(.pool|esc) | \(.failures) | \([.failureKinds|to_entries[]|"\(.key)=\(.value)"]|join(",")|esc) | \(.taskClasses|join(",")|esc) | \(.capability|join(",")|esc) | \(.quotaReader|join(",")|esc) | \(.lastAt|esc) | \(.lastCause|esc) |"'
      ;;
    *) die "spawn-failures format must be json, csv, or md" ;;
  esac
}

spawn_failures_json() {
  local from=$1 to=$2
  [ -e "$LEDGER" ] || { printf '[]\n'; return; }
  jq -Rcs --arg v "$SCHEMA_VERSION" --arg from "$from" --arg to "$to" "$WINDOW_JQ_DEF"'
    split("\n") | map(select(length>0)|fromjson)
    | map(select(.schemaVersion==$v and .eventType=="spawn-failure") | .failure)
    | map(select(in_window(.attemptedAt)))
    | group_by(.tuple.harness + "|" + ((.tuple.provider // "_")|tostring) + "|" + ((.tuple.accountProfile // "_")|tostring) + "|" + ((.dispatchModelFamily // "_")|tostring) + "|" + ((.tuple.model // "_")|tostring))
    | map({
        pool: (.[0].tuple.harness + "/" + ((.[0].tuple.provider // "?")|tostring) + "/" + ((.[0].tuple.accountProfile // "default")|tostring) + "/" + ((.[0].dispatchModelFamily // "?")|tostring) + "/" + ((.[0].tuple.model // "?")|tostring)),
        harness: .[0].tuple.harness,
        provider: .[0].tuple.provider,
        accountProfile: .[0].tuple.accountProfile,
        dispatchModelFamily: .[0].dispatchModelFamily,
        model: .[0].tuple.model,
        failures: length,
        failureKinds: ([.[] | .failureKind] | group_by(.) | map({key: .[0], value: length}) | from_entries),
        taskClasses: ([.[] | .taskClass] | unique),
        capability: ([.[] | .capability] | unique),
        quotaReader: ([.[] | .quotaReader] | unique),
        firstAt: ([.[] | .attemptedAt] | min),
        lastAt: ([.[] | .attemptedAt] | max),
        lastCause: (max_by(.attemptedAt) | .cause)
      })
  ' "$LEDGER"
}

# One owner for the bounded-window contract every projection shares: the same
# predicate over the ledger's own UTC timestamps, where a bare date on --to
# covers that whole day, so two projections can never report a different window
# for the same flags.
# shellcheck disable=SC2016  # $from, $to, and $s are jq variables in a literal program, not shell ones.
WINDOW_JQ_DEF='
    def in_window($s):
      ($from=="" or $s>=$from) and
      ($to=="" or (if ($to|length)==10 then $s[0:10]<=$to else $s<=$to end));
'

# The window bounds are compared lexically against startedAt, which is only
# sound for UTC timestamps in the ledger's own shape. Accept a full RFC3339 Z
# timestamp or a bare calendar date and refuse anything else, so a mistyped or
# offset-bearing bound can never silently produce a wrong renewal window.
require_window_bound() {
  local flag=$1 value=$2
  [ -n "$value" ] || return 0
  printf '%s' "$value" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z)?$' \
    || die "$flag must be a UTC RFC3339 timestamp or a bare YYYY-MM-DD date"
}

# An inverted window selects nothing, so refuse it instead of reporting an empty
# renewal sheet. A bare date on --to means the whole of that day, so only then is
# the lower bound compared by calendar day; two timestamps compare in full.
require_ordered_window() {
  local from=$1 to=$2 lower
  [ -n "$from" ] && [ -n "$to" ] || return 0
  if [ "${#to}" -eq 10 ]; then lower=${from:0:10}; else lower=$from; fi
  [ ! "$to" \< "$lower" ] || die "--from must not be later than --to"
}

# The windowed projections take the same flags under the same rules; parsing
# them once keeps a correction to one command from leaving the other behind.
WINDOW_FORMAT=json
WINDOW_FROM=''
WINDOW_TO=''
parse_window_args() {  # <command> [args...]
  local command=$1 want=''
  shift
  WINDOW_FORMAT=json
  WINDOW_FROM=''
  WINDOW_TO=''
  while [ "$#" -gt 0 ]; do
    if [ -n "$want" ]; then
      case "$want" in from) WINDOW_FROM=$1 ;; to) WINDOW_TO=$1 ;; format) WINDOW_FORMAT=$1 ;; esac
      want=
    else
      case "$1" in
        --from) want=from ;; --to) want=to ;; --format) want=format ;;
        *) die "unknown argument $1" ;;
      esac
    fi
    shift
  done
  [ -z "$want" ] || die "--$want requires a value"
  case "$WINDOW_FORMAT" in json|csv|md) ;; *) die "$command format must be json, csv, or md" ;; esac
  require_window_bound --from "$WINDOW_FROM"
  require_window_bound --to "$WINDOW_TO"
  require_ordered_window "$WINDOW_FROM" "$WINDOW_TO"
}

subscription_sheet_json() {
  local from=$1 to=$2
  [ -e "$LEDGER" ] || { printf '[]\n'; return; }
  jq -Rcs --arg v "$SCHEMA_VERSION" --arg from "$from" --arg to "$to" "$WINDOW_JQ_DEF"'
    split("\n") | map(select(length>0)|fromjson) as $rows |
    ($rows | map(select(.schemaVersion==$v and .eventType=="attempt-intake")) | map(. as $i |
      ($rows | map(select(.schemaVersion==$v and .eventType=="attempt-terminal" and .attemptId==$i.attemptId)) | first) as $t |
      {intake:$i.intake, terminal:($t.terminal // null)})) as $attempts |
    ($attempts | map(select(in_window(.intake.startedAt)))) as $window |
    ($window | group_by(.intake.tuple.harness + "|" + ((.intake.tuple.provider // "_")|tostring) + "|" + ((.intake.tuple.accountProfile // "_")|tostring) + "|" + ((.intake.selection.dispatchModelFamily // "_")|tostring) + "|" + ((.intake.tuple.model // "_")|tostring)) | map({
      subscription: (.[0].intake.tuple.harness + "/" + ((.[0].intake.tuple.provider // "?")|tostring) + "/" + ((.[0].intake.tuple.accountProfile // "default")|tostring) + "/" + ((.[0].intake.selection.dispatchModelFamily // "?")|tostring) + "/" + ((.[0].intake.tuple.model // "?")|tostring)),
      harness: .[0].intake.tuple.harness,
      provider: .[0].intake.tuple.provider,
      accountProfile: .[0].intake.tuple.accountProfile,
      dispatchModelFamily: .[0].intake.selection.dispatchModelFamily,
      model: .[0].intake.tuple.model,
      attempts: length,
      accepted: (map(select(.terminal.classification=="accepted")) | length),
      rejectedOrFailed: (map(select(.terminal.classification!=null and .terminal.classification!="accepted")) | length),
      open: (map(select(.terminal==null)) | length),
      cost: ([.[] | .terminal.usage.cost // empty] | add),
      currency: ([.[] | .terminal.usage.currency // empty] | first),
      inputTokens: ([.[] | .terminal.usage.inputTokens // empty] | add),
      outputTokens: ([.[] | .terminal.usage.outputTokens // empty] | add),
      taskClasses: ([.[] | .intake.taskClass] | unique),
      quotaSelected: (map(select(.intake.selection.quota.decision=="selected")) | length),
      quotaStopped: (map(select(.intake.selection.quota.decision=="stopped")) | length),
      quotaUnknown: (map(select(.intake.selection.quota.decision=="unknown" or .intake.selection.quota.decision=="not-applicable")) | length),
      headroomSufficient: (map(select(.intake.selection.quota.headroom=="sufficient")) | length),
      headroomTight: (map(select(.intake.selection.quota.headroom=="tight")) | length),
      headroomExhausted: (map(select(.intake.selection.quota.headroom=="exhausted")) | length),
      headroomUnmeasurable: (map(select(.intake.selection.quota.headroom=="unmeasurable")) | length),
      headroomUnknown: (map(select(.intake.selection.quota.headroom=="unknown")) | length),
      usageRecorded: (map(select(.terminal.usageSource=="recorded")) | length),
      usageNoVerifiedSource: (map(select(.terminal.usageSource=="no-verified-source")) | length),
      usageSessionNotFound: (map(select(.terminal.usageSource=="session-not-found")) | length),
      usageSessionMatchedNoTokens: (map(select(.terminal.usageSource=="session-matched-no-tokens")) | length),
      usageUnreadable: (map(select(.terminal.usageSource=="unreadable")) | length),
      usageWorktreeMissing: (map(select(.terminal.usageSource=="worktree-missing")) | length),
      usageAbsent: (map(select(.terminal!=null and (.terminal.usageSource==null))) | length)
    }))
  ' "$LEDGER"
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|'') usage; [ -n "$COMMAND" ] || exit 2; exit 0 ;;
esac
shift

case "$COMMAND" in
  intake|terminal|terminal-facts|seal-or-incomplete|spawn-failure)
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    secure_dirs
    task=''
    state_arg=''
    attempt_arg=''
    payload=''
    terminal_payload=''
    want=''
    while [ "$#" -gt 0 ]; do
      if [ -n "$want" ]; then
        case "$want" in state) state_arg=$1 ;; task) task=$1 ;; attempt) attempt_arg=$1 ;; payload) payload=$1 ;; terminal) terminal_payload=$1 ;; esac
        want=
      else
        case "$1" in
          --state) want=state ;; --task) want=task ;; --attempt) want=attempt ;; --payload) want=payload ;; --terminal-payload) want=terminal ;;
          *) die "unknown argument $1" ;;
        esac
      fi
      shift
    done
    [ -z "$want" ] || die "--$want requires a value"
    [ -z "$state_arg" ] || [ "$state_arg" = "$STATE" ] || die "--state must match the effective state directory"
    [ -n "$task" ] || die "--task is required"
    case "$COMMAND" in
      intake) [ -n "$payload" ] || die "--payload is required"; intake_command "$task" "$payload" ;;
      terminal) [ -n "$payload" ] || die "--payload is required"; terminal_command "$task" "$payload" "$attempt_arg" ;;
      terminal-facts) [ -n "$payload" ] || die "--payload is required"; terminal_facts_command "$task" "$payload" "$attempt_arg" ;;
      spawn-failure) [ -n "$payload" ] || die "--payload is required"; spawn_failure_command "$task" "$payload" ;;
      seal-or-incomplete)
        [ -z "$payload" ] || die "seal-or-incomplete uses --terminal-payload"
        if [ -n "$terminal_payload" ]; then
          terminal_command "$task" "$terminal_payload" "$attempt_arg"
        else
          seal_command "$task" "$attempt_arg"
        fi
        ;;
    esac
    ;;
  usage)
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    attempt_arg=''
    worktree=''
    want=''
    while [ "$#" -gt 0 ]; do
      if [ -n "$want" ]; then
        case "$want" in attempt) attempt_arg=$1 ;; worktree) worktree=$1 ;; esac
        want=
      else
        case "$1" in
          --attempt) want=attempt ;;
          --worktree) want=worktree ;;
          *) die "unknown argument $1" ;;
        esac
      fi
      shift
    done
    [ -z "$want" ] || die "--$want requires a value"
    [ -n "$attempt_arg" ] || die "--attempt is required"
    [ -n "$worktree" ] || die "--worktree is required"
    usage_command "$attempt_arg" "$worktree"
    ;;
  candidate-register)
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    secure_dirs
    candidate=''
    payload=''
    want=''
    while [ "$#" -gt 0 ]; do
      if [ -n "$want" ]; then
        case "$want" in candidate) candidate=$1 ;; payload) payload=$1 ;; esac
        want=
      else
        case "$1" in
          --candidate) want=candidate ;;
          --payload) want=payload ;;
          *) die "unknown argument $1" ;;
        esac
      fi
      shift
    done
    [ -z "$want" ] || die "--$want requires a value"
    [ -n "$candidate" ] || die "--candidate is required"
    [ -n "$payload" ] || die "--payload is required"
    candidate_register_command "$candidate" "$payload"
    ;;
  candidate-verdict)
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    secure_dirs
    comparison=''
    verdict=''
    rollback=''
    want=''
    while [ "$#" -gt 0 ]; do
      if [ -n "$want" ]; then
        case "$want" in comparison) comparison=$1 ;; verdict) verdict=$1 ;; rollback) rollback=$1 ;; esac
        want=
      else
        case "$1" in
          --comparison) want=comparison ;;
          --verdict) want=verdict ;;
          --rollback-evidence) want=rollback ;;
          *) die "unknown argument $1" ;;
        esac
      fi
      shift
    done
    [ -z "$want" ] || die "--$want requires a value"
    [ -n "$comparison" ] || die "--comparison is required"
    [ -n "$verdict" ] || die "--verdict is required"
    [ -n "$rollback" ] || die "--rollback-evidence is required"
    candidate_verdict_command "$comparison" "$verdict" "$rollback"
    ;;
  sheet)
    [ ! -L "$DATA" ] || die "data directory is a symlink"
    format=json
    if [ "$#" -gt 0 ]; then
      [ "$1" = --format ] && [ "$#" -eq 2 ] || die "sheet accepts only --format json|csv|md"
      format=$2
    fi
    sheet_command "$format"
    ;;
  spawn-failures)
    [ ! -L "$DATA" ] || die "data directory is a symlink"
    parse_window_args spawn-failures "$@"
    spawn_failures_command "$WINDOW_FORMAT" "$WINDOW_FROM" "$WINDOW_TO"
    ;;
  subscription-sheet)
    [ ! -L "$DATA" ] || die "data directory is a symlink"
    parse_window_args subscription-sheet "$@"
    subscription_sheet_command "$WINDOW_FORMAT" "$WINDOW_FROM" "$WINDOW_TO"
    ;;
  *) die "unknown command $COMMAND" ;;
esac
