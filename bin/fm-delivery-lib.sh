#!/usr/bin/env bash
# Shared results-first delivery lifecycle primitives.
#
# Owned contracts:
#   - schema version: firstmate.delivery-receipt.v1
#   - canonical delivery phases and mode-specific landing substates
#   - atomic, identity-bound, monotonic phase transitions
#   - final receipt prerequisites and validation
#   - hashed write-once evidence manifest helpers
#
# This library does NOT shell-evaluate project commands or run releases; it only
# validates the durable records and identity bindings that prove a phase or a
# final receipt. Project-owned executable contracts are read by
# bin/fm-delivery-contract.sh (post-canary); during the pre-canary cutover a
# task-local delivery specification satisfies the accepted-phase prerequisite.

# shellcheck disable=SC2034
FM_DELIVERY_SCHEMA_VERSION='firstmate.delivery-receipt.v1'

# Canonical delivery phases. A results-first ship task moves monotonically through
# these phases; exceptional states (blocked, paused_external, failed,
# rollback_in_progress) record the prior phase and a reason without advancing it.
# shellcheck disable=SC2034
FM_DELIVERY_PHASES=(accepted implementing validating landing landed released deployed smoke_verified receipt_finalized cleanup_eligible)

# Canonical landing substates per source-landing mode. Every mode converges on
# landed, then the universal phases above continue.
# shellcheck disable=SC2034
FM_DELIVERY_LANDING_SUBSTATES_direct_PR=(pr_open ci_green merged)
# shellcheck disable=SC2034
FM_DELIVERY_LANDING_SUBSTATES_no_mistakes=(pr_open ci_green merged)
# shellcheck disable=SC2034
FM_DELIVERY_LANDING_SUBSTATES_local_only=(branch_ready landing_approved fast_forwarded)

# Print the canonical space-separated phase list.
fm_delivery_phase_list() {
  printf '%s\n' "${FM_DELIVERY_PHASES[*]}"
}

# Print landing substates for a mode, or empty when the mode is unknown.
fm_delivery_landing_substates() {
  local mode=$1 var idx len first
  var="FM_DELIVERY_LANDING_SUBSTATES_${mode//-/_}"
  # Portable array indirect read: use name[@] expansion when bash supports it.
  if [ -n "${!var+x}" ]; then
    len=$(eval "echo \${#${var}[@]}")
    first=1
    for ((idx=0; idx<len; idx++)); do
      val=$(eval "echo \${${var}[$idx]}")
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ' '
      fi
      printf '%s' "$val"
    done
    printf '\n'
  fi
}

# Validate a 40-hex SHA. Returns 0 for valid, 1 otherwise.
fm_delivery_validate_sha() {
  local sha=$1
  [ -n "$sha" ] || return 1
  [ "${#sha}" -eq 40 ] || return 1
  case "$sha" in *[!0-9a-fA-F]*) return 1 ;; esac
  return 0
}

# Normalize a SHA to lowercase.
fm_delivery_sha_lower() {
  printf '%s\n' "$1" | tr 'A-F' 'a-f'
}

# Print a timestamp in RFC3339 UTC.
fm_delivery_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Atomic replace of <dst> with contents of a temp file created by the caller.
# The temp file must be on the same device as dst. Usage:
#   tmp=$(mktemp "$dst.tmp.XXXXXX")
#   ... write "$tmp" ...
#   fm_delivery_atomic_replace "$tmp" "$dst" 0600
# Removes the temp file on failure. Mode is octal without leading 0 if desired.
fm_delivery_atomic_replace() {  # <src-tmp> <dst> [<mode>]
  local src=$1 dst=$2 mode=${3:-0600}
  [ -f "$src" ] || { echo "error: atomic replace source missing: $src" >&2; return 1; }
  case "$mode" in ''|*[!0-7]*) echo "error: invalid mode $mode" >&2; rm -f "$src"; return 1 ;; esac
  chmod "$mode" "$src" || { rm -f "$src"; return 1; }
  # fsync the directory so the rename is durable.
  mv "$src" "$dst" || { rm -f "$src"; return 1; }
  local dir
  dir=$(dirname "$dst")
  [ -d "$dir" ] && { command -v sync >/dev/null 2>&1 && sync "$dir" || true; }
  return 0
}

# Compute SHA-256 manifest of a directory: one line per file
# "sha256  relative/path" sorted by path. Prints the hex digest of the manifest.
fm_delivery_manifest_hash() {  # <dir>
  local dir=$1
  [ -d "$dir" ] || { echo "error: manifest dir missing: $dir" >&2; return 1; }
  local manifest
  manifest=$(cd "$dir" && find . -type f | sort | while IFS= read -r rel; do
    rel=${rel#./}
    [ -n "$rel" ] || continue
    printf '%s  %s\n' "$(fm_delivery_file_hash "$dir/$rel")" "$rel"
  done) || return 1
  [ -n "$manifest" ] || { echo "error: empty manifest for $dir" >&2; return 1; }
  printf '%s\n' "$manifest" | sha256sum | awk '{print $1}'
}

fm_delivery_file_hash() {  # <file>
  local f=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    shasum -a 256 "$f" | awk '{print $1}'
  fi
}

# Lightweight JSON validation using python3 (a system tool, not a project
# dependency). Validates that the document is valid JSON and satisfies the
# firstmate.delivery-receipt.v1 required-field contract.
fm_delivery_validate_receipt() {  # <receipt-json>
  local input_json=$1
  python3 - "$input_json" <<'PYEOF'
import json, sys
try:
    if not sys.argv[1]:
        print("error: empty receipt", file=sys.stderr)
        sys.exit(1)
    doc = json.loads(sys.argv[1])
except Exception as e:
    print(f"error: invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)
required_top = ["schemaVersion", "task", "capability", "source", "phases", "validation", "release", "deployment", "smoke", "rollback", "outcome"]
for k in required_top:
    if k not in doc:
        print(f"error: missing required receipt field: {k}", file=sys.stderr)
        sys.exit(1)
if doc.get("schemaVersion") != "firstmate.delivery-receipt.v1":
    print("error: unsupported schema version", file=sys.stderr)
    sys.exit(1)
task = doc["task"]
for k in ["id", "project", "kind", "lane", "deliveryMode", "yolo"]:
    if k not in task:
        print(f"error: missing task field: {k}", file=sys.stderr)
        sys.exit(1)
src = doc["source"]
for k in ["branch", "candidateSha"]:
    if k not in src or not src[k]:
        print(f"error: missing/empty source field: {k}", file=sys.stderr)
        sys.exit(1)
# At least one landed identity must be present.
if not (src.get("mergeSha") or src.get("localLandedSha")):
    print("error: receipt lacks mergeSha or localLandedSha", file=sys.stderr)
    sys.exit(1)
outcome = doc["outcome"]
if outcome.get("status") != "delivered":
    print("error: outcome.status must be delivered", file=sys.stderr)
    sys.exit(1)
# Phase monotonicity and required evidence are enforced by the caller/phase tool.
sys.exit(0)
PYEOF
}

# Validate a mutable in-flight delivery record (state/<id>.delivery.json).
fm_delivery_validate_inflight() {  # <json>
  local input_json=$1
  python3 - "$input_json" <<'PYEOF'
import json, sys
try:
    if not sys.argv[1]:
        print("error: empty in-flight record", file=sys.stderr)
        sys.exit(1)
    doc = json.loads(sys.argv[1])
except Exception as e:
    print(f"error: invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)
required = ["schemaVersion", "task", "phase", "phases", "updatedAt"]
for k in required:
    if k not in doc:
        print(f"error: missing in-flight field: {k}", file=sys.stderr)
        sys.exit(1)
if doc.get("schemaVersion") != "firstmate.delivery-receipt.v1":
    print("error: unsupported in-flight schema version", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
}

# Validate phase monotonicity: a phase cannot move backwards. Prints nothing,
# returns 0 if allowed.
fm_delivery_validate_phase_transition() {  # <current-phase> <next-phase>
  local current=$1 next=$2
  local idx_current=-1 idx_next=-1 i
  for i in "${!FM_DELIVERY_PHASES[@]}"; do
    [ "${FM_DELIVERY_PHASES[$i]}" = "$current" ] && idx_current=$i
    [ "${FM_DELIVERY_PHASES[$i]}" = "$next" ] && idx_next=$i
  done
  if [ "$idx_current" -lt 0 ] || [ "$idx_next" -lt 0 ]; then
    echo "error: unknown phase in transition: $current -> $next" >&2
    return 1
  fi
  [ "$idx_next" -ge "$idx_current" ]
}

# Redact volatile provider fields from evidence before publication. Refuses if
# percentages, reset times, or dynamic balances are present in the evidence.
fm_delivery_redact_volatile_provider_fields() {  # <file>
  local f=$1
  [ -f "$f" ] || return 0
  if grep -qiE 'percent(Used|Remaining)|reset_time|balance|quota_pct|session_pct|week_pct' "$f"; then
    echo "error: volatile provider percentage/reset/balance fields present in $f" >&2
    return 1
  fi
  return 0
}
