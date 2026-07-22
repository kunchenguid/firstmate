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
  case "$1" in
    direct-PR|no-mistakes) printf '%s\n' 'pr_open ci_green merged' ;;
    local-only) printf '%s\n' 'branch_ready landing_approved fast_forwarded' ;;
  esac
}

# Validate an identifier used as one path component.
fm_delivery_validate_id() {
  local value=$1
  [ -n "$value" ] || return 1
  [ "$value" != . ] && [ "$value" != .. ] || return 1
  printf '%s' "$value" | grep -qxE '[A-Za-z0-9][A-Za-z0-9._-]*'
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
  # Re-assert the mode on the destination explicitly: when src and dst are on
  # different filesystems (common in containerized CI where TMPDIR is a
  # separate tmpfs mount from the destination tree), `mv` falls back to a
  # copy + unlink instead of a same-device rename(2). That fallback is not
  # guaranteed to preserve the exact mode bits set on src (the umask in
  # effect at copy time can leak in), so make the destination mode explicit
  # here too rather than relying on rename semantics alone.
  chmod "$mode" "$dst" || return 1
  local dir
  dir=$(dirname "$dst")
  [ -d "$dir" ] && { command -v sync >/dev/null 2>&1 && sync "$dir" || true; }
  return 0
}

# Write a deterministic manifest for every regular file except the manifest
# itself, then print the digest of the exact manifest bytes.
fm_delivery_write_manifest() {  # <dir> <manifest-path>
  local dir=$1 manifest=$2
  [ -d "$dir" ] || { echo "error: manifest dir missing: $dir" >&2; return 1; }
  python3 - "$dir" "$manifest" <<'PYEOF'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
manifest = pathlib.Path(sys.argv[2]).resolve()
files = [path for path in root.rglob("*") if path.is_file() and path.resolve() != manifest]
files.sort(key=lambda path: path.relative_to(root).as_posix().encode())
if not files:
    print(f"error: empty manifest for {root}", file=sys.stderr)
    sys.exit(1)
lines = []
for path in files:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    lines.append(f"{digest}  {path.relative_to(root).as_posix()}\n")
data = "".join(lines).encode()
manifest.write_bytes(data)
print(hashlib.sha256(data).hexdigest())
PYEOF
}

# Compute the digest of the canonical manifest without retaining it.
fm_delivery_manifest_hash() {  # <dir>
  local dir=$1 tmp digest
  [ -d "$dir" ] || { echo "error: manifest dir missing: $dir" >&2; return 1; }
  tmp=$(mktemp "$dir/.manifest.XXXXXX") || return 1
  digest=$(fm_delivery_write_manifest "$dir" "$tmp") || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$digest"
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
fm_delivery_validate_receipt() {  # <receipt-json> [<expected-task-id> <expected-mode> <expected-candidate-sha>]
  local input_json=$1 expected_id=${2:-} expected_mode=${3:-} expected_candidate=${4:-}
  python3 - "$input_json" "$expected_id" "$expected_mode" "$expected_candidate" <<'PYEOF'
import json, sys
try:
    if not sys.argv[1]:
        raise ValueError("empty receipt")
    doc = json.loads(sys.argv[1])
except Exception as error:
    print(f"error: invalid JSON: {error}", file=sys.stderr)
    sys.exit(1)
required_top = ["schemaVersion", "task", "capability", "source", "phases", "validation", "release", "deployment", "smoke", "rollback", "outcome"]
for key in required_top:
    if key not in doc:
        print(f"error: missing required receipt field: {key}", file=sys.stderr)
        sys.exit(1)
if doc.get("schemaVersion") != "firstmate.delivery-receipt.v1":
    print("error: unsupported schema version", file=sys.stderr)
    sys.exit(1)
task = doc["task"]
for key in ["id", "project", "kind", "lane", "deliveryMode", "yolo"]:
    if key not in task:
        print(f"error: missing task field: {key}", file=sys.stderr)
        sys.exit(1)
expected_id, expected_mode, expected_candidate = sys.argv[2:5]
if expected_id and task.get("id") != expected_id:
    print("error: receipt task id does not match expected task", file=sys.stderr)
    sys.exit(1)
if expected_mode and task.get("deliveryMode") != expected_mode:
    print("error: receipt delivery mode does not match task metadata", file=sys.stderr)
    sys.exit(1)
source = doc["source"]
for key in ["branch", "candidateSha"]:
    if key not in source or not source[key]:
        print(f"error: missing/empty source field: {key}", file=sys.stderr)
        sys.exit(1)
def valid_sha(value):
    return isinstance(value, str) and len(value) == 40 and all(char in "0123456789abcdef" for char in value)
if not valid_sha(source.get("candidateSha")):
    print("error: invalid candidateSha", file=sys.stderr)
    sys.exit(1)
if expected_candidate and source.get("candidateSha") != expected_candidate.lower():
    print("error: receipt candidateSha does not match exact task head", file=sys.stderr)
    sys.exit(1)
mode = task.get("deliveryMode")
if mode in {"direct-PR", "no-mistakes"}:
    if not valid_sha(source.get("mergeSha")) or source.get("localLandedSha"):
        print("error: PR delivery requires only a valid mergeSha", file=sys.stderr)
        sys.exit(1)
elif mode == "local-only":
    if not valid_sha(source.get("localLandedSha")) or source.get("mergeSha"):
        print("error: local-only delivery requires only a valid localLandedSha", file=sys.stderr)
        sys.exit(1)
else:
    print("error: unsupported delivery mode", file=sys.stderr)
    sys.exit(1)
required_phases = ["accepted", "implementing", "validating", "landing", "landed", "released", "deployed", "smoke_verified", "receipt_finalized"]
phases = doc.get("phases")
if not isinstance(phases, list) or [phase.get("name") for phase in phases] != required_phases:
    print("error: receipt phases are not contiguous through receipt_finalized", file=sys.stderr)
    sys.exit(1)
for phase in phases:
    name = phase.get("name")
    if not phase.get("startedAt") or not phase.get("completedAt"):
        print(f"error: incomplete phase {name}", file=sys.stderr)
        sys.exit(1)
    if phase.get("result") not in {"passed", "not_applicable"}:
        print(f"error: unsuccessful phase {name}", file=sys.stderr)
        sys.exit(1)
    evidence = phase.get("evidence")
    if not isinstance(evidence, list) or any(not isinstance(value, str) or len(value) != 64 or any(char not in "0123456789abcdef" for char in value) for value in evidence):
        print(f"error: invalid evidence digest for {name}", file=sys.stderr)
        sys.exit(1)
    if name in {"validating", "released", "deployed", "smoke_verified"} and phase.get("result") == "passed" and not evidence:
        print(f"error: passed phase {name} lacks evidence", file=sys.stderr)
        sys.exit(1)
if next(phase for phase in phases if phase.get("name") == "validating").get("result") != "passed":
    print("error: validating phase must pass", file=sys.stderr)
    sys.exit(1)
if doc.get("outcome", {}).get("status") != "delivered":
    print("error: outcome.status must be delivered", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Verify every evidence digest against one contained bundle, including the exact
# manifest bytes, every listed file, and the candidate identity in meta.json.
fm_delivery_verify_receipt_evidence() {  # <receipt-json> <data-root> <task-id>
  local input_json=$1 data_root=$2 task_id=$3
  python3 - "$input_json" "$data_root" "$task_id" <<'PYEOF'
import hashlib, json, pathlib, re, sys
doc = json.loads(sys.argv[1])
root = pathlib.Path(sys.argv[2]) / sys.argv[3] / "evidence"
candidate = doc.get("source", {}).get("candidateSha")
digests = []
for phase in doc.get("phases", []):
    digests.extend(phase.get("evidence", []))
rollback = doc.get("rollback", {}).get("receipt")
if rollback:
    digests.append(rollback)
for expected in sorted(set(digests)):
    matched = False
    manifests = root.glob("*/MANIFEST.sha256") if root.is_dir() else []
    for manifest in manifests:
        raw = manifest.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            continue
        bundle = manifest.parent.resolve()
        listed = set()
        for line in raw.decode().splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            if not match:
                raise SystemExit(f"error: malformed evidence manifest {manifest}")
            digest, rel = match.groups()
            rel_path = pathlib.PurePosixPath(rel)
            if rel_path.is_absolute() or ".." in rel_path.parts or rel in listed:
                raise SystemExit(f"error: unsafe evidence manifest path {rel}")
            path = (bundle / rel).resolve()
            if bundle not in path.parents or not path.is_file():
                raise SystemExit(f"error: missing evidence file {rel}")
            if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise SystemExit(f"error: evidence hash mismatch for {rel}")
            listed.add(rel)
        actual = {path.relative_to(bundle).as_posix() for path in bundle.rglob("*") if path.is_file() and path.name != "MANIFEST.sha256"}
        if listed != actual:
            raise SystemExit(f"error: evidence manifest file set mismatch in {bundle}")
        meta = json.loads((bundle / "meta.json").read_text())
        if meta.get("candidateSha") != candidate:
            raise SystemExit("error: evidence candidateSha does not match receipt")
        matched = True
        break
    if not matched:
        raise SystemExit(f"error: receipt evidence digest not found: {expected}")
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
phases = ["accepted", "implementing", "validating", "landing", "landed", "released", "deployed", "smoke_verified", "receipt_finalized", "cleanup_eligible"]
if doc.get("phase") not in phases:
    print("error: unknown delivery phase", file=sys.stderr)
    sys.exit(1)
if not isinstance(doc.get("phases"), list):
    print("error: phases must be an array", file=sys.stderr)
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
  [ "$idx_next" -eq $((idx_current + 1)) ]
}

# Redact volatile provider fields from evidence before publication. Refuses if
# percentages, reset times, or dynamic balances are present in the evidence.
fm_delivery_redact_volatile_provider_fields() {  # <file>
  local f=$1
  [ -f "$f" ] || return 0
  if grep -qiE 'percent(Used|Remaining)|reset_time|(^|[^[:alnum:]_])(balance|quota_pct|session_pct|week_pct)([^[:alnum:]_]|$)' "$f"; then
    echo "error: volatile provider percentage/reset/balance fields present in $f" >&2
    return 1
  fi
  if grep -qiE '(^|[^[:alnum:]_])(api[_-]?key|access[_-]?token|password|secret)[[:space:]]*[:=]' "$f"; then
    echo "error: secret assignment present in $f" >&2
    return 1
  fi
  return 0
}
