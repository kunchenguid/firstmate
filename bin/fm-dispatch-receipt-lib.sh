#!/usr/bin/env bash
# Dispatch selection-receipt validation shared by fm-spawn and fm-control.
#
# A configured dispatch profile can require a current, primary-authored receipt
# before a worker endpoint, worktree, or backlog state is changed.  This file
# deliberately validates only evidence integrity and identity.  It does not
# infer providers, rank candidates, or choose a route: those remain the
# firstmate seat's quota-array-dispatch judgment.
#
# Receipt schema (version 1):
# {
#   "version": 1,
#   "createdAt": "2026-09-06T15:04:05Z",
#   "task": "task-id", "harness": "codex", "model": "gpt-6-astra",
#   "effort": "high", "taskFit": "why this task fits the choice",
#   "candidates": [{"harness":"...", "model":"...", "effort":"...",
#                   "disposition":"selected|not-selected", "rationale":"..."}],
#   "catalogEvidence": ["authoritative catalog evidence"],
#   "quotaSnapshot": {"path":"/absolute/path/to/snapshot", "sha256":"..."}
# }
#
# FM_DISPATCH_RECEIPT_MAX_AGE_SECONDS bounds receipt age (default 900).  The
# successful validator exports only these shell variables for the caller's
# metadata record: FM_DISPATCH_RECEIPT_PATH, _SHA256, _CREATED_AT, and
# FM_DISPATCH_QUOTA_SNAPSHOT_SHA256.

fm_dispatch_selection_receipt_required() {  # <crew-dispatch.json> <harness> <model>
  local config=$1 harness=$2 model=$3 rc
  [ -f "$config" ] || return 1
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to evaluate a configured selection-receipt requirement" >&2
    return 2
  }
  if jq -e --arg h "$harness" --arg m "$model" '
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    ([(.rules // [])[]? | profiles(.use?)[]?]
      + (if has("default") then profiles(.default) else [] end))
    | any(.[]; .requiresSelectionReceipt == true
        and .harness == $h and .model == $m)
  ' "$config" >/dev/null 2>&1; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] && return 1
  echo "error: config/crew-dispatch.json could not be read while evaluating selection-receipt requirements" >&2
  return 2
}

fm_dispatch_snapshot_generated_at() {  # <TOON or JSON snapshot> -> strict timestamp
  local snapshot=$1 value
  if jq -e . "$snapshot" >/dev/null 2>&1; then
    jq -er '.generatedAt | select(type == "string")' "$snapshot" 2>/dev/null
    return
  fi
  value=$(awk '
    /^generatedAt: "[^"]+"$/ {
      count += 1
      line = $0
      sub(/^generatedAt: "/, "", line)
      sub(/"$/, "", line)
      value = line
    }
    END { if (count == 1) print value; else exit 1 }
  ' "$snapshot") || return 1
  printf '%s\n' "$value"
}

fm_dispatch_receipt_epoch() {  # strict UTC timestamp -> epoch
  local value=$1 normalized fraction
  case "$value" in
    ????-??-??T??:??:??Z) normalized=$value ;;
    ????-??-??T??:??:??.*Z)
      fraction=${value#*.}
      fraction=${fraction%Z}
      case "$fraction" in ''|*[!0-9]*) return 1 ;; esac
      normalized="${value%%.*}Z"
      ;;
    *) return 1 ;;
  esac
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" +%s 2>/dev/null \
    || date -u -d "$normalized" +%s 2>/dev/null
}

fm_dispatch_selection_receipt_validate() {  # <receipt> <task> <harness> <model> <effort>
  local receipt=$1 task=$2 harness=$3 model=$4 effort=$5 max_age now created_at created_epoch
  local snapshot expected actual receipt_digest snapshot_generated_at snapshot_epoch
  FM_DISPATCH_RECEIPT_PATH=
  FM_DISPATCH_RECEIPT_SHA256=
  FM_DISPATCH_RECEIPT_CREATED_AT=
  FM_DISPATCH_QUOTA_SNAPSHOT_SHA256=
  case "$receipt" in
    /*) ;;
    *) echo "error: --selection-receipt must be an absolute path, got '$receipt'" >&2; return 1 ;;
  esac
  case "$receipt" in
    *[[:cntrl:]]*) echo "error: --selection-receipt contains an invalid control byte" >&2; return 1 ;;
  esac
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || {
    echo "error: --selection-receipt must name a readable regular file: $receipt" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to validate --selection-receipt" >&2
    return 1
  }
  jq -e --arg task "$task" --arg harness "$harness" --arg model "$model" --arg effort "$effort" '
    (.version == 1)
    and (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.task == $task) and (.harness == $harness) and (.model == $model) and (.effort == $effort)
    and (.taskFit | type == "string" and length > 0)
    and (.candidates | type == "array" and length > 0
         and all(.[]; type == "object"
           and (.harness | type == "string" and length > 0)
           and (.model | type == "string" and length > 0)
           and (.effort | type == "string" and length > 0)
           and (.disposition == "selected" or .disposition == "not-selected")
           and (.rationale | type == "string" and length > 0)))
    and ([.candidates[] | select(.disposition == "selected")] as $selected
         | ($selected | length) == 1
           and $selected[0].harness == $harness
           and $selected[0].model == $model
           and $selected[0].effort == $effort)
    and (.catalogEvidence | type == "array" and length > 0
         and all(.[]; type == "string" and length > 0))
    and (.quotaSnapshot | type == "object"
         and (.path | type == "string" and test("^/[^[:cntrl:]]*$"))
         and (.sha256 | type == "string" and test("^[a-f0-9]{64}$")))
  ' "$receipt" >/dev/null 2>&1 || {
    echo "error: --selection-receipt is not a valid version 1 primary selection receipt for $harness/$model/$effort task $task" >&2
    return 1
  }
  created_at=$(jq -r '.createdAt' "$receipt")
  created_epoch=$(fm_dispatch_receipt_epoch "$created_at") || {
    echo "error: --selection-receipt has an unreadable createdAt timestamp" >&2
    return 1
  }
  max_age=${FM_DISPATCH_RECEIPT_MAX_AGE_SECONDS:-900}
  case "$max_age" in
    ''|*[!0-9]*|0) echo "error: FM_DISPATCH_RECEIPT_MAX_AGE_SECONDS must be a positive integer" >&2; return 1 ;;
  esac
  now=${FM_DISPATCH_RECEIPT_NOW_EPOCH:-$(date -u +%s)}
  case "$now" in
    ''|*[!0-9]*) echo "error: FM_DISPATCH_RECEIPT_NOW_EPOCH must be an epoch integer" >&2; return 1 ;;
  esac
  if [ "$created_epoch" -gt "$now" ] || [ $((now - created_epoch)) -gt "$max_age" ]; then
    echo "error: --selection-receipt is stale or future-dated (maximum age ${max_age}s); obtain a current primary selection receipt before dispatch" >&2
    return 1
  fi
  snapshot=$(jq -r '.quotaSnapshot.path' "$receipt")
  expected=$(jq -r '.quotaSnapshot.sha256' "$receipt")
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || {
    echo "error: --selection-receipt quota snapshot must be a readable regular file: $snapshot" >&2
    return 1
  }
  actual=$(shasum -a 256 "$snapshot" | awk '{print $1}') || {
    echo "error: --selection-receipt quota snapshot could not be hashed: $snapshot" >&2
    return 1
  }
  [ "$actual" = "$expected" ] || {
    echo "error: --selection-receipt quota snapshot digest does not match; obtain a current primary selection receipt before dispatch" >&2
    return 1
  }
  snapshot_generated_at=$(fm_dispatch_snapshot_generated_at "$snapshot") || {
    echo "error: --selection-receipt quota snapshot has no valid generatedAt timestamp (expected quota-axi TOON or JSON)" >&2
    return 1
  }
  snapshot_epoch=$(fm_dispatch_receipt_epoch "$snapshot_generated_at") || {
    echo "error: --selection-receipt quota snapshot has an unreadable generatedAt timestamp" >&2
    return 1
  }
  if [ "$snapshot_epoch" -gt "$now" ] || [ $((now - snapshot_epoch)) -gt "$max_age" ]; then
    echo "error: --selection-receipt quota snapshot is stale or future-dated (maximum age ${max_age}s); obtain a current primary selection receipt before dispatch" >&2
    return 1
  fi
  receipt_digest=$(shasum -a 256 "$receipt" | awk '{print $1}') || {
    echo "error: --selection-receipt could not be hashed: $receipt" >&2
    return 1
  }
  FM_DISPATCH_RECEIPT_PATH=$receipt
  FM_DISPATCH_RECEIPT_SHA256=$receipt_digest
  FM_DISPATCH_RECEIPT_CREATED_AT=$created_at
  FM_DISPATCH_QUOTA_SNAPSHOT_SHA256=$expected
}
