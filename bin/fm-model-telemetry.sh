#!/usr/bin/env bash
# Own the private append-only model-attempt ledger and its recovery receipts.
#
# Usage:
#   fm-model-telemetry.sh intake --state <dir> --task <id> --payload <json>
#   fm-model-telemetry.sh terminal --state <dir> --task <id> [--attempt <mra_uuid>] --payload <json>
#   fm-model-telemetry.sh terminal-facts --state <dir> --task <id> [--attempt <mra_uuid>] --payload <json>
#   fm-model-telemetry.sh seal-or-incomplete --state <dir> --task <id> [--attempt <mra_uuid>] [--terminal-payload <json>]
#   fm-model-telemetry.sh sheet [--format json|csv|md]
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
# terminal-facts accepts only observable gate facts, outcome identity, and
# directly reported usage. It derives classification, first-pass acceptance,
# correction count, end time, and wall time at the immutable terminal seal.
# gate.stepReruns is how many delivery-gate steps ran a round beyond their
# first, counted once per extra round of a step. It is NOT a count of
# correction cycles: one review fix whose follow-up also re-runs `document` is
# two step reruns. The V1 correctionCount field mirrors it on this mechanical
# path, but the sheet's stepReruns column reads gateFacts.stepReruns and nothing
# else, because correctionCount also carries a caller-authored correction count
# on the explicit terminal path and a hardcoded 0 on the incomplete seal. A row
# with no observed gate therefore reports stepReruns absent, never 0, so a
# superseded or caller-sealed attempt never reads like a clean first pass.
# A green gate whose step-rerun count could not be read stays accepted with a
# null correctionCount rather than being downgraded to incomplete; the sheet
# reports that, and any accepted row with no gate-sourced count, as
# accepted-step-reruns-unknown.
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
    def sha: type=="string" and test("^[0-9a-f]{64}$");
    def dt: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
    def tuple:
      keys_are(["harness","provider","model","effort","modelVersion","cliVersion"]) and
      (.harness|safeid) and (.provider==null or (.provider|type=="string" and length<=96)) and
      (.model==null or (.model|type=="string" and length<=160)) and
      (.effort|oneof(["low","medium","high","xhigh","max","default",null])) and
      (.modelVersion==null or (.modelVersion|type=="string" and length<=160)) and
      (.cliVersion==null or (.cliVersion|type=="string" and length<=160));
    def selection:
      keys_are(["matchedRule","configSha256","fitReasons","candidateAssessments","quota"]) and
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
        (.observedAt==null or (.observedAt|dt)));
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

validate_terminal() {
  printf '%s' "$1" | jq -e '
    def keys_are($a): (keys|sort)==($a|sort);
    def oneof($a): . as $v | ($a|index($v))!=null;
    def safeid: type=="string" and length>=1 and length<=96 and test("^[A-Za-z0-9._:-]+$");
    def dt: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
    ((keys_are(["classification","refusalQuality","endedAt","wallSeconds","firstPassAccepted","correctionCount","interventionCount","evidence","outcomeLink","usage","primaryFailureClass","flags","reclassification"])) or
     (keys_are(["classification","refusalQuality","endedAt","wallSeconds","firstPassAccepted","correctionCount","interventionCount","evidence","outcomeLink","usage","primaryFailureClass","flags","reclassification","gateFacts"]))) and
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
    (.primaryFailureClass|oneof(["none","capability","refusal","timeout","quota","tool","transport","environment","external-wait","scope-change","integrity","unknown"])) and
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
    keys_are(["gate","outcomeLink","usage"]) and
    (.gate|keys_are(["source","result","stepReruns"]) and
      (.source|oneof(["no-mistakes","delivery"])) and
      (.result|oneof(["green","failed","cancelled","incomplete"])) and
      (.stepReruns==null or (.stepReruns|type=="number" and floor==. and .>=0))) and
    (.outcomeLink|keys_are(["kind","id"]) and
      (.kind|oneof(["none","commit","pull-request","report","spec-kit-outcome"])) and
      (.id==null or (.id|safeid))) and
    (.usage|keys_are(["inputTokens","outputTokens","cost","currency"]) and
      all([.inputTokens,.outputTokens,.cost][]; .==null or (type=="number" and .>=0)) and
      (.currency==null or (.currency|type=="string" and test("^[A-Z]{3}$"))))
  ' >/dev/null || die "terminal facts payload violates the whitelist"
}

validate_event() {
  local event=$1 expected=$2
  [ "$(printf '%s' "$event" | LC_ALL=C wc -c | tr -d ' ')" -le "$MAX_EVENT_BYTES" ] || die "event exceeds 64 KiB"
  printf '%s' "$event" | jq -e --arg version "$SCHEMA_VERSION" --arg type "$expected" '
    (.schemaVersion==$version) and (.eventType==$type) and
    (.eventId|type=="string" and test("^mre_[0-9a-f-]{36}$")) and
    (.attemptId|type=="string" and test("^mra_[0-9a-f-]{36}$")) and
    (.recordedAt|type=="string") and
    (if $type=="attempt-intake" then (keys|sort)==(["schemaVersion","eventType","eventId","attemptId","recordedAt","privacy","intake"]|sort)
     else (keys|sort)==(["schemaVersion","eventType","eventId","attemptId","recordedAt","privacy","terminal"]|sort) end)
  ' >/dev/null 2>&1 || die "generated event violates the envelope whitelist"
}

validate_ledger() {
  local line compact event_type payload lineno=0
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
        *) die "ledger contains an unknown event type" ;;
      esac
    fi
    DIAG_CONTEXT=
  done < "$LEDGER"
  DIAG_CONTEXT="$LEDGER"
  jq -eRcs --arg v "$SCHEMA_VERSION" '
    split("\n") | map(select(length>0)|fromjson) | map(select(.schemaVersion==$v)) as $events |
    ($events | map(select(.eventType=="attempt-intake")) | group_by(.attemptId) | all(.[]; length==1)) and
    ($events | map(select(.eventType=="attempt-terminal")) | group_by(.attemptId) | all(.[]; length<=1)) and
    (all($events[] | select(.eventType=="attempt-terminal"); .attemptId as $a | any($events[]; .eventType=="attempt-intake" and .attemptId==$a))) and
    (all($events[] | select(.eventType=="attempt-intake" and .intake.parentAttemptId!=null);
      .intake.parentAttemptId as $p | .intake.taskRootId as $r |
      any($events[]; .eventType=="attempt-intake" and .attemptId==$p and .intake.taskRootId==$r)))
  ' "$LEDGER" >/dev/null || die "ledger violates attempt identity or sealing invariants"
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
    event=$(jq -cnS --arg v "$SCHEMA_VERSION" --arg eid "mre_$(new_uuid)" --arg aid "$attempt" --arg at "$(now_rfc3339)" --arg root "$root" --argjson payload "$canonical" \
      '{schemaVersion:$v,eventType:"attempt-intake",eventId:$eid,attemptId:$aid,recordedAt:$at,privacy:$payload.privacy,intake:($payload|del(.privacy)|.taskRootId=$root)}')
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

incomplete_terminal() {
  jq -cn '{classification:"incomplete",refusalQuality:"unknown",endedAt:null,wallSeconds:null,firstPassAccepted:null,correctionCount:0,interventionCount:0,evidence:{tests:"unknown",reviewer:"unknown",oracle:"unknown",refs:[]},outcomeLink:{kind:"none",id:null},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},primaryFailureClass:"unknown",flags:{tool:false,transport:false,environment:false,externalWait:false,scopeChange:false,quota:false},reclassification:{fromTaskClass:null,toTaskClass:null,reasonCodes:["none"],escalated:false}}'
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
  local task=$1 payload=$2 attempt_arg=${3:-} path attempt facts intake started ended wall terminal status
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
    intake=$(find_intake "$attempt") || die "terminal facts have no intake row"
    started=$(printf '%s' "$intake" | jq -r .intake.startedAt)
    ended=$(now_rfc3339)
    wall=$(node -e 'const a=Date.parse(process.argv[1]),b=Date.parse(process.argv[2]);if(!Number.isFinite(a)||!Number.isFinite(b)||b<a)process.exit(1);process.stdout.write(String((b-a)/1000));' "$started" "$ended") || die "could not derive wall time from intake and terminal timestamps"
    terminal=$(jq -cnS --arg ended "$ended" --argjson wall "$wall" --argjson facts "$facts" '
      ($facts.gate.result) as $result |
      ($facts.gate.stepReruns) as $reruns |
      {classification:(if $result=="green" then "accepted" elif $result=="failed" then "failed" elif $result=="cancelled" then "cancelled" else "incomplete" end),
       refusalQuality:(if $result=="incomplete" then "unknown" else "not-applicable" end),
       endedAt:$ended,wallSeconds:$wall,
       firstPassAccepted:(if $result=="green" then (if $reruns==null then null else $reruns==0 end) elif $result=="failed" then false else null end),
       correctionCount:$reruns,interventionCount:0,
       evidence:{tests:(if $facts.gate.source=="no-mistakes" and $result=="green" then "pass" elif $facts.gate.source=="no-mistakes" and $result=="failed" then "fail" else "unknown" end),reviewer:(if $facts.gate.source=="no-mistakes" and $result=="green" then "pass" else "unknown" end),oracle:"not-run",refs:[]},
       outcomeLink:$facts.outcomeLink,usage:$facts.usage,
       primaryFailureClass:(if $result=="green" then "none" else "unknown" end),
       flags:{tool:false,transport:false,environment:false,externalWait:false,scopeChange:false,quota:false},
       reclassification:{fromTaskClass:null,toTaskClass:null,reasonCodes:["none"],escalated:false},
       gateFacts:$facts.gate}')
    validate_terminal "$terminal"
    append_terminal_event "$attempt" "$terminal"
    status=recorded
  fi
  rm -f "$path"
  with_lock_end
  jq -cn --arg status "$status" --arg attempt "$attempt" '{status:$status,attemptId:$attempt}'
}

sheet_json() {
  [ -e "$LEDGER" ] || { printf '[]\n'; return; }
  jq -Rcs --arg v "$SCHEMA_VERSION" '
    def blank($raw): {recordType:"legacy",schemaVersion:null,attemptId:null,taskRootId:null,parentAttemptId:null,source:null,attemptClass:null,projectRef:null,taskClass:null,harness:null,provider:null,model:null,effort:null,exploration:null,machineLoadAverage1m:null,machineLogicalCpuCount:null,state:"legacy",classification:null,quality:null,stepReruns:null,gateSource:null,primaryFailureClass:null,startedAt:null,endedAt:null,wallSeconds:null,costReported:false,cost:null,currency:null,costPerAcceptedDelivery:null,legacyRaw:$raw};
    split("\n") | map(select(length>0)|fromjson) as $rows |
    ($rows | map(select(.schemaVersion!=$v) | blank(.))) +
    ($rows | map(select(.schemaVersion==$v and .eventType=="attempt-intake")) | map(. as $i |
      ($rows | map(select(.schemaVersion==$v and .eventType=="attempt-terminal" and .attemptId==$i.attemptId)) | first) as $t |
      ($t.terminal.classification // null) as $classification |
      ($t.terminal.gateFacts.stepReruns // null) as $reruns |
      ($t.terminal.usage.cost // null) as $cost |
      {recordType:"attempt",schemaVersion:$v,attemptId:$i.attemptId,taskRootId:$i.intake.taskRootId,parentAttemptId:$i.intake.parentAttemptId,source:$i.intake.source,attemptClass:$i.intake.attemptClass,projectRef:$i.intake.projectRef,taskClass:$i.intake.taskClass,harness:$i.intake.tuple.harness,provider:$i.intake.tuple.provider,model:$i.intake.tuple.model,effort:$i.intake.tuple.effort,
       exploration:($i.intake.exploration.kind // null),machineLoadAverage1m:($i.intake.exploration.machineCondition.loadAverage1m // null),machineLogicalCpuCount:($i.intake.exploration.machineCondition.logicalCpuCount // null),
       state:(if $t==null then "open" else "terminal" end),classification:$classification,
       quality:(if $t==null then null elif $classification!="accepted" then $classification elif $reruns==null then "accepted-step-reruns-unknown" elif $reruns==0 then "accepted-first-pass" else "accepted-after-step-reruns" end),
       stepReruns:$reruns,gateSource:($t.terminal.gateFacts.source // null),primaryFailureClass:($t.terminal.primaryFailureClass // null),startedAt:$i.intake.startedAt,endedAt:($t.terminal.endedAt // null),wallSeconds:($t.terminal.wallSeconds // null),
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
      printf '%s\n' 'recordType,schemaVersion,attemptId,taskRootId,parentAttemptId,source,attemptClass,projectRef,taskClass,harness,provider,model,effort,exploration,machineLoadAverage1m,machineLogicalCpuCount,state,classification,quality,stepReruns,gateSource,primaryFailureClass,startedAt,endedAt,wallSeconds,costReported,cost,currency,costPerAcceptedDelivery,legacyRaw'
      printf '%s' "$json" | jq -r '.[] | [.recordType,.schemaVersion,.attemptId,.taskRootId,.parentAttemptId,.source,.attemptClass,.projectRef,.taskClass,.harness,.provider,.model,.effort,.exploration,.machineLoadAverage1m,.machineLogicalCpuCount,.state,.classification,.quality,.stepReruns,.gateSource,.primaryFailureClass,.startedAt,.endedAt,.wallSeconds,.costReported,.cost,.currency,.costPerAcceptedDelivery,(.legacyRaw|if .==null then null else tojson end)] | @csv'
      ;;
    md)
      printf '%s\n' '| type | attempt | root | parent | tuple | exploration | load | state | quality | step reruns | seconds | cost | cost/accepted | failure | legacy |'
      printf '%s\n' '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|'
      printf '%s' "$json" | jq -r '.[] | def esc: if .==null then "" else tostring|gsub("\\|";"\\\\|")|gsub("\\n";" ") end; "| \(.recordType|esc) | \(.attemptId|esc) | \(.taskRootId|esc) | \(.parentAttemptId|esc) | \(([.harness,.model,.effort]|map(select(.!=null))|join("/"))|esc) | \(.exploration|esc) | \(([.machineLoadAverage1m,.machineLogicalCpuCount]|map(select(.!=null))|join("/"))|esc) | \(.state|esc) | \(.quality|esc) | \(.stepReruns|esc) | \(.wallSeconds|esc) | \((if .costReported then ((.currency // "")+" "+(.cost|tostring)) else "absent" end)|esc) | \(.costPerAcceptedDelivery|esc) | \(.primaryFailureClass|esc) | \((.legacyRaw|if .==null then "" else tojson end)|esc) |"'
      ;;
    *) die "sheet format must be json, csv, or md" ;;
  esac
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|'') usage; [ -n "$COMMAND" ] || exit 2; exit 0 ;;
esac
shift

case "$COMMAND" in
  intake|terminal|terminal-facts|seal-or-incomplete)
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
  sheet)
    [ ! -L "$DATA" ] || die "data directory is a symlink"
    format=json
    if [ "$#" -gt 0 ]; then
      [ "$1" = --format ] && [ "$#" -eq 2 ] || die "sheet accepts only --format json|csv|md"
      format=$2
    fi
    sheet_command "$format"
    ;;
  *) die "unknown command $COMMAND" ;;
esac
