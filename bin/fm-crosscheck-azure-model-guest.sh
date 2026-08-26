#!/usr/bin/env bash
# Trusted root-side Azure Crosscheck model-compartment payload.
#
# This compartment receives exactly one reviewer credential and one read-only
# exact-head snapshot. The reviewer has bounded read/search and verdict tools,
# but no generic command or cloud interface.
set -euo pipefail
umask 077

# Managed Run Command delivers parameters as environment variables, never as
# positional arguments (the same contract the validation guest proved live).
[ "$#" -eq 0 ] || { echo "model guest: positional parameters are forbidden" >&2; exit 125; }
REVIEW_GENERATION=${review_generation:-}
VM_RESOURCE_ID=${vm_resource_id:-}
VM_INSTANCE_ID=${vm_instance_id:-}
GUEST_DIGEST=${guest_digest:-}
INPUT_URL=${input_url:-}
CREDENTIAL_URL=${credential_url:-}
SNAPSHOT_URL=${snapshot_url:-}
OUTPUT_URL=${output_url:-}
unset review_generation vm_resource_id vm_instance_id guest_digest
unset input_url credential_url snapshot_url output_url
[ -n "$REVIEW_GENERATION" ] && [ -n "$VM_RESOURCE_ID" ] && [ -n "$VM_INSTANCE_ID" ] \
  && [ -n "$GUEST_DIGEST" ] && [ -n "$INPUT_URL" ] && [ -n "$CREDENTIAL_URL" ] \
  && [ -n "$SNAPSHOT_URL" ] && [ -n "$OUTPUT_URL" ] || { echo "model guest: expected eight bound parameters" >&2; exit 125; }

[[ "$REVIEW_GENERATION" =~ ^[0-9a-f]{24}$ ]] || { echo "model guest: malformed review generation" >&2; exit 125; }
case "$GUEST_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "model guest: malformed guest digest" >&2; exit 125 ;; esac
[ -n "$VM_RESOURCE_ID" ] && [ -n "$VM_INSTANCE_ID" ] || { echo "model guest: missing VM identity" >&2; exit 125; }
case "$INPUT_URL" in https://*) ;; *) echo "model guest: input capability is not HTTPS" >&2; exit 125 ;; esac
case "$CREDENTIAL_URL" in https://*) ;; *) echo "model guest: credential capability is not HTTPS" >&2; exit 125 ;; esac
case "$SNAPSHOT_URL" in https://*) ;; *) echo "model guest: snapshot capability is not HTTPS" >&2; exit 125 ;; esac
case "$OUTPUT_URL" in https://*) ;; *) echo "model guest: output capability is not HTTPS" >&2; exit 125 ;; esac

ROOT=/var/lib/fm-crosscheck-model
BASE=$ROOT/$REVIEW_GENERATION
install -d -m 0700 -o root -g root "$ROOT"
[ ! -e "$BASE" ] || { echo "model guest: review generation already exists" >&2; exit 125; }
install -d -m 0700 -o root -g root "$BASE"
trap 'rm -rf "$BASE"' EXIT
INPUT=$BASE/request.json
CREDENTIAL=$BASE/credential.tar.gz
SNAPSHOT=$BASE/repository-snapshot.tar.gz
curl --fail --silent --show-error --max-filesize 2097152 --output "$INPUT" "$INPUT_URL"
curl --fail --silent --show-error --max-filesize 131072 --output "$CREDENTIAL" "$CREDENTIAL_URL"
curl --fail --silent --show-error --max-filesize 134217728 --output "$SNAPSHOT" "$SNAPSHOT_URL"
unset INPUT_URL CREDENTIAL_URL SNAPSHOT_URL

VERDICT_EXTENSION=$BASE/verdict-extension.mjs
PI_REVIEWER_RUNTIME=$BASE/pi-reviewer.py
python3 - "$INPUT" "$REVIEW_GENERATION" "$GUEST_DIGEST" "$VERDICT_EXTENSION" "$PI_REVIEWER_RUNTIME" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
generation = sys.argv[2]
guest_digest = sys.argv[3]
if path.stat().st_size > 2 * 1024 * 1024:
    raise SystemExit("model guest: request exceeds byte bound")
value = json.loads(path.read_text(encoding="utf-8"))
if value.get("schema") != "fm.azure-crosscheck/v1":
    raise SystemExit("model guest: request schema mismatch")
unsigned = dict(value)
supplied = unsigned.pop("request_digest", None)
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if supplied != "sha256:" + hashlib.sha256(canonical).hexdigest():
    raise SystemExit("model guest: request digest mismatch")
if value.get("identity", {}).get("review_generation") != generation:
    raise SystemExit("model guest: review generation mismatch")
if value.get("protocol", {}).get("model_guest_digest") != guest_digest:
    raise SystemExit("model guest: guest digest mismatch")
extension = value.get("verdict_extension")
source = extension.get("source") if isinstance(extension, dict) else None
digest = extension.get("sha256") if isinstance(extension, dict) else None
if not isinstance(source, str) or digest != "sha256:" + hashlib.sha256(source.encode()).hexdigest():
    raise SystemExit("model guest: verdict extension digest mismatch")
if value.get("protocol", {}).get("verdict_extension_digest") != digest:
    raise SystemExit("model guest: verdict extension protocol mismatch")
pathlib.Path(sys.argv[4]).write_text(source, encoding="utf-8")
if value.get("tool_protocol", {}).get("network_bytes") != 0:
    raise SystemExit("model guest: repository tool contract is not networkless")
expected_tools = (
    [
        "repo_search", "repo_read",
        "report_finding", "report_suspicion", "update_finding",
        "request_lookup", "finish_review",
    ]
    if value.get("reviewer", {}).get("harness") == "pi"
    else []
)
if value.get("tool_protocol", {}).get("model_tools") != expected_tools:
    raise SystemExit("model guest: model tool allowlist mismatch")
if not isinstance(value.get("tool_protocol", {}).get("lookup_allowed"), bool):
    raise SystemExit("model guest: lookup allowance is malformed")
runtime = value.get("pi_reviewer_runtime")
runtime_source = runtime.get("source") if isinstance(runtime, dict) else None
runtime_digest = runtime.get("sha256") if isinstance(runtime, dict) else None
if (
    not isinstance(runtime_source, str)
    or runtime_digest != "sha256:" + hashlib.sha256(runtime_source.encode()).hexdigest()
):
    raise SystemExit("model guest: Pi reviewer runtime digest mismatch")
if value.get("protocol", {}).get("pi_reviewer_runtime_digest") != runtime_digest:
    raise SystemExit("model guest: Pi reviewer runtime protocol mismatch")
pathlib.Path(sys.argv[5]).write_text(runtime_source, encoding="utf-8")
snapshot = value.get("repository_snapshot")
required_snapshot = {
    "schema", "digest", "manifest_digest", "head_sha", "base_sha",
    "compressed_bytes", "uncompressed_bytes", "file_count", "excluded_count",
}
if not isinstance(snapshot, dict) or set(snapshot) != required_snapshot:
    raise SystemExit("model guest: repository snapshot request is malformed")
if snapshot.get("schema") != "fm.azure-crosscheck-snapshot/v1":
    raise SystemExit("model guest: repository snapshot schema mismatch")
if snapshot.get("head_sha") != value.get("identity", {}).get("repository_snapshot_head_sha"):
    raise SystemExit("model guest: repository snapshot head identity mismatch")
if snapshot.get("base_sha") != value.get("identity", {}).get("repository_snapshot_base_sha"):
    raise SystemExit("model guest: repository snapshot base identity mismatch")
for request_key, identity_key in (
    ("digest", "repository_snapshot_digest"),
    ("manifest_digest", "repository_snapshot_manifest_digest"),
    ("compressed_bytes", "repository_snapshot_compressed_bytes"),
    ("uncompressed_bytes", "repository_snapshot_uncompressed_bytes"),
    ("file_count", "repository_snapshot_file_count"),
    ("excluded_count", "repository_snapshot_excluded_count"),
):
    observed = snapshot.get(request_key)
    expected = value.get("identity", {}).get(identity_key)
    if str(observed) != expected:
        raise SystemExit("model guest: repository snapshot request identity mismatch")
PY

# The pinned image owns only the reviewer CLI closure needed in this
# credentialed compartment. No Azure CLI, repository helper, shell tool, tool
# socket, container client, or generic command interface is exposed to the
# reviewer process.
command -v jq >/dev/null 2>&1 || { echo "model guest: jq is absent from pinned image" >&2; exit 125; }

HARNESS=$(jq -r '.reviewer.harness' "$INPUT")
MODEL=$(jq -r '.reviewer.model' "$INPUT")
EFFORT=$(jq -r '.reviewer.effort' "$INPUT")
PROMPT=$BASE/prompt.txt
SCHEMA=$BASE/schema.json
jq -r '.prompt' "$INPUT" >"$PROMPT"
jq -c '.review_schema' "$INPUT" >"$SCHEMA"

ACCOUNT=$BASE/account
HOME_DIR=$BASE/home
install -d -m 0700 -o root -g root "$ACCOUNT" "$HOME_DIR"
python3 - "$CREDENTIAL" "$ACCOUNT" "$INPUT" <<'PY'
import hashlib
import json
import pathlib
import sys
import tarfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
request = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
reviewer = request["reviewer"]
identity = request["identity"]
if "sha256:" + hashlib.sha256(source.read_bytes()).hexdigest() != identity["credential_archive_digest"]:
    raise SystemExit("model guest: credential archive digest mismatch")
# R6 cross-family lane registry, mirroring CROSS_FAMILY_LANES in
# bin/fm-crosscheck.py: model -> (provider slot, pinned chat-completions
# base URL, non-secret executing identity, pinned model-level compat).
CROSS_FAMILY_LANES = {
    "accounts/fireworks/models/glm-5p2": (
        "fireworks-glm",
        "https://api.fireworks.ai/inference/v1",
        "fireworks-glm:api.fireworks.ai/accounts/fireworks/models/glm-5p2",
        {
            "supportsStrictMode": True,
            "sendSessionAffinityHeaders": True,
            "sessionAffinityFormat": "openai",
        },
        {"input": 1.40, "cacheRead": 0.14, "cacheWrite": 1.40, "output": 4.40},
    ),
}
lane = (
    CROSS_FAMILY_LANES.get(reviewer["model"])
    if reviewer["harness"] == "pi"
    else None
)
if lane is not None:
    expected_name = "models.json"
elif reviewer["harness"] in {"codex", "pi"}:
    expected_name = "auth.json"
else:
    raise SystemExit("model guest: unsupported reviewer harness")
with tarfile.open(source, "r:gz") as archive:
    members = archive.getmembers()
    names = {member.name for member in members}
    if names != {"manifest.json", expected_name} or len(members) != 2:
        raise SystemExit("model guest: credential archive shape mismatch")
    for member in members:
        if not member.isfile() or member.issym() or member.islnk() or member.isdev() or member.size > 64 * 1024:
            raise SystemExit("model guest: unsafe credential archive member")
    manifest_bytes = archive.extractfile("manifest.json").read()
    credential_bytes = archive.extractfile(expected_name).read()
manifest = json.loads(manifest_bytes)
expected = {
    "schema": request["schema"],
    "review_generation": request["identity"]["review_generation"],
    "harness": reviewer["harness"],
    "model": reviewer["model"],
    "effort": reviewer["effort"],
    "credential_name": expected_name,
    "credential_digest": "sha256:" + hashlib.sha256(credential_bytes).hexdigest(),
}
if manifest != expected or manifest["credential_digest"] != identity["credential_digest"]:
    raise SystemExit("model guest: credential manifest identity mismatch")
credential = json.loads(credential_bytes)
if lane is not None:
    # R6 cross-family lane: the api-key credential must stay inside that
    # lane's pinned chat-completions endpoint allowlist, and the executing
    # identity is the non-secret provider host/model binding.
    slot, allowed_base_url, account, allowed_compat, allowed_cost = lane
    providers = credential.get("providers") if isinstance(credential, dict) else None
    entry = (
        providers.get(slot)
        if isinstance(providers, dict) and set(providers) == {slot}
        else None
    )
    base_url = entry.get("baseUrl") if isinstance(entry, dict) else None
    if base_url != allowed_base_url:
        raise SystemExit("model guest: cross-family credential endpoint allowlist mismatch")
    # pi composes provider-level compat/headers and a modelOverrides layer into
    # the effective model, so the provider's keys are allowlisted rather than
    # individually refused.
    if set(entry) - {"baseUrl", "api", "apiKey", "models"}:
        raise SystemExit("model guest: cross-family credential provider-level field override")
    # pi gives model-level baseUrl/api precedence over the provider level,
    # so any model entry carrying either field escapes the provider pin.
    models = entry.get("models") if isinstance(entry, dict) else None
    for model_entry in (models if isinstance(models, list) else []):
        if isinstance(model_entry, dict) and ("baseUrl" in model_entry or "api" in model_entry):
            raise SystemExit("model guest: cross-family credential model-level endpoint override")
        # `compat` keys change how pi frames the request and reads the
        # response, so the lane owns them exactly.
        if isinstance(model_entry, dict) and model_entry.get("compat", {}) != allowed_compat:
            raise SystemExit("model guest: cross-family credential model-level compat override")
        if (
            isinstance(model_entry, dict)
            and model_entry.get("id") == reviewer["model"]
            and model_entry.get("cost") != allowed_cost
        ):
            raise SystemExit("model guest: cross-family credential model-level pricing mismatch")
elif reviewer["harness"] == "codex":
    # The PREFIXED identity, byte-identical to
    # `account_identity_from_credential` on the host. This is the third place
    # that derivation exists (host reader, host archive gate, and here), and
    # it is the one that cannot import the others because the guest ships as a
    # self-contained script onto a VM. It disagreed by exactly this prefix
    # once already: the host digests `codex:<id>` while this derived the bare
    # `<id>`, so the comparison below could never be equal and the refusal
    # fired INSIDE a booted, paid VM instead of during staging. Any change to
    # the host rule must be mirrored here, and
    # `model_guest_executing_account_unit` in tests/fm-crosscheck-azure.test.sh
    # executes this exact block against the host readers to prove they agree.
    tokens = credential.get("tokens") if isinstance(credential, dict) else None
    raw = tokens.get("account_id") if isinstance(tokens, dict) else None
    account = "codex:" + raw.strip() if isinstance(raw, str) and raw.strip() else None
else:
    entry = credential.get("openai-codex") if isinstance(credential, dict) else None
    raw = entry.get("accountId") if isinstance(entry, dict) else None
    account = (
        "openai-codex:" + raw.strip() if isinstance(raw, str) and raw.strip() else None
    )
if not isinstance(account, str) or "sha256:" + hashlib.sha256(account.encode()).hexdigest() != identity["reviewer_account_digest"]:
    raise SystemExit("model guest: credential executing account mismatch")
path = destination / expected_name
path.write_bytes(credential_bytes)
path.chmod(0o600)
PY
rm -f "$CREDENTIAL"

REPOSITORY=$BASE/repository
python3 - "$SNAPSHOT" "$REPOSITORY" "$INPUT" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
import tarfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
request = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
declared = request["repository_snapshot"]
identity = request["identity"]
if source.stat().st_size > 128 * 1024 * 1024:
    raise SystemExit("model guest: repository snapshot exceeds compressed bound")
if "sha256:" + hashlib.sha256(source.read_bytes()).hexdigest() != identity["repository_snapshot_digest"]:
    raise SystemExit("model guest: repository snapshot digest mismatch")

def safe_path(raw):
    if not isinstance(raw, str) or not raw or len(raw.encode("utf-8")) > 512:
        raise SystemExit("model guest: unsafe repository snapshot path")
    path = pathlib.PurePosixPath(raw)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts) or ".git" in path.parts:
        raise SystemExit("model guest: unsafe repository snapshot path")
    return path

def safe_link(path, target):
    if not isinstance(target, str) or not target or len(target.encode("utf-8")) > 512:
        raise SystemExit("model guest: unsafe repository snapshot symlink")
    target_path = pathlib.PurePosixPath(target)
    if target_path.is_absolute():
        raise SystemExit("model guest: unsafe repository snapshot symlink")
    stack = list(path.parent.parts)
    for part in target_path.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not stack:
                raise SystemExit("model guest: repository snapshot symlink escapes root")
            stack.pop()
        else:
            stack.append(part)
    if ".git" in stack:
        raise SystemExit("model guest: repository snapshot symlink reaches metadata")

manifest_name = "repository/.crosscheck-snapshot/manifest.json"
with tarfile.open(source, "r:gz") as archive:
    members = archive.getmembers()
    if len(members) > 15001:
        raise SystemExit("model guest: repository snapshot exceeds member bound")
    names = [member.name for member in members]
    if len(names) != len(set(names)) or manifest_name not in names:
        raise SystemExit("model guest: repository snapshot member set is malformed")
    for member in members:
        path = safe_path(member.name)
        if path.parts[0] != "repository" or member.islnk() or member.isdev() or member.isdir():
            raise SystemExit("model guest: unsafe repository snapshot member")
        if not member.isfile() and not member.issym():
            raise SystemExit("model guest: unsupported repository snapshot member")
    manifest_member = archive.getmember(manifest_name)
    if not manifest_member.isfile() or manifest_member.size > 4 * 1024 * 1024:
        raise SystemExit("model guest: repository snapshot manifest is unsafe")
    manifest_bytes = archive.extractfile(manifest_member).read()
    if "sha256:" + hashlib.sha256(manifest_bytes).hexdigest() != identity["repository_snapshot_manifest_digest"]:
        raise SystemExit("model guest: repository snapshot manifest digest mismatch")
    manifest = json.loads(manifest_bytes)
    if (
        manifest.get("schema") != "fm.azure-crosscheck-snapshot/v1"
        or manifest.get("head_sha") != declared["head_sha"]
        or manifest.get("base_sha") != declared["base_sha"]
    ):
        raise SystemExit("model guest: repository snapshot manifest identity mismatch")
    included = manifest.get("included")
    exclusions = manifest.get("exclusions")
    if not isinstance(included, list) or not isinstance(exclusions, list):
        raise SystemExit("model guest: repository snapshot manifest shape mismatch")
    if (
        len(included) != declared["file_count"]
        or len(exclusions) != declared["excluded_count"]
        or manifest.get("tracked_file_count") != len(included) + len(exclusions)
        or manifest["tracked_file_count"] > 15000
    ):
        raise SystemExit("model guest: repository snapshot manifest counts mismatch")
    expected_names = {manifest_name}
    symlinks = set()
    total = len(manifest_bytes)
    records = {}
    for record in included:
        if not isinstance(record, dict) or set(record) != {
            "path", "blob_id", "size", "kind", "changed", "content_sha256"
        }:
            raise SystemExit("model guest: repository snapshot file record is malformed")
        path = safe_path(record["path"])
        if path.parts[0] == ".crosscheck-snapshot":
            raise SystemExit("model guest: repository snapshot uses reserved metadata path")
        if record["kind"] not in {"file", "executable", "symlink"}:
            raise SystemExit("model guest: repository snapshot file kind is invalid")
        if not isinstance(record["size"], int) or record["size"] < 0:
            raise SystemExit("model guest: repository snapshot file size is invalid")
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", str(record["blob_id"])):
            raise SystemExit("model guest: repository snapshot blob identity is invalid")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(record["content_sha256"])):
            raise SystemExit("model guest: repository snapshot content digest is invalid")
        limit = 8 * 1024 * 1024 if record["changed"] else 2 * 1024 * 1024
        if record["size"] > limit:
            raise SystemExit("model guest: repository snapshot file exceeds its bound")
        name = "repository/" + record["path"]
        expected_names.add(name)
        records[name] = record
        total += record["size"]
        if record["kind"] == "symlink":
            symlinks.add(path)
    for exclusion in exclusions:
        if not isinstance(exclusion, dict) or set(exclusion) != {"path", "blob_id", "size", "reason"}:
            raise SystemExit("model guest: repository snapshot exclusion is malformed")
        safe_path(exclusion["path"])
        if exclusion["reason"] not in {"binary", "oversized", "oversized-changed"}:
            raise SystemExit("model guest: repository snapshot exclusion reason is invalid")
        if not isinstance(exclusion["size"], int) or exclusion["size"] < 0:
            raise SystemExit("model guest: repository snapshot exclusion size is invalid")
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", str(exclusion["blob_id"])):
            raise SystemExit("model guest: repository snapshot exclusion blob identity is invalid")
    if set(names) != expected_names or total != declared["uncompressed_bytes"] or total > 384 * 1024 * 1024:
        raise SystemExit("model guest: repository snapshot contents mismatch manifest")
    for path in (pathlib.PurePosixPath(record["path"]) for record in included):
        if any(pathlib.PurePosixPath(*path.parts[:index]) in symlinks for index in range(1, len(path.parts))):
            raise SystemExit("model guest: repository snapshot path traverses a symlink")
    destination.mkdir(mode=0o700)
    for name in sorted(expected_names):
        member = archive.getmember(name)
        relative = pathlib.PurePosixPath(name).relative_to("repository")
        output = destination.joinpath(*relative.parts)
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if name == manifest_name:
            content = manifest_bytes
            output.write_bytes(content)
            output.chmod(0o444)
            continue
        record = records[name]
        if record["kind"] == "symlink":
            if not member.issym() or member.size != 0:
                raise SystemExit("model guest: repository snapshot symlink member mismatch")
            safe_link(pathlib.PurePosixPath(record["path"]), member.linkname)
            content = member.linkname.encode("utf-8")
            if len(content) != record["size"]:
                raise SystemExit("model guest: repository snapshot symlink size mismatch")
            os.symlink(member.linkname, output)
        else:
            if not member.isfile() or member.size != record["size"]:
                raise SystemExit("model guest: repository snapshot file member mismatch")
            content = archive.extractfile(member).read(record["size"] + 1)
            if len(content) != record["size"]:
                raise SystemExit("model guest: repository snapshot file length mismatch")
            with output.open("xb") as handle:
                handle.write(content)
            output.chmod(0o555 if record["kind"] == "executable" else 0o444)
        if "sha256:" + hashlib.sha256(content).hexdigest() != record["content_sha256"]:
            raise SystemExit("model guest: repository snapshot content digest mismatch")
for directory in sorted((path for path in destination.rglob("*") if path.is_dir()), key=lambda path: len(path.parts), reverse=True):
    directory.chmod(0o555)
destination.chmod(0o555)
PY
rm -f "$SNAPSHOT"

export HOME="$HOME_DIR"
export TMPDIR="$BASE/tmp"
export XDG_CACHE_HOME="$BASE/cache"
install -d -m 0700 -o root -g root "$TMPDIR" "$XDG_CACHE_HOME"
export FM_CROSSCHECK_REVIEW_GENERATION="$REVIEW_GENERATION"
export FM_CROSSCHECK_REPOSITORY="$REPOSITORY"
export FM_CROSSCHECK_HEAD_SHA
FM_CROSSCHECK_HEAD_SHA=$(jq -r '.identity.head_sha' "$INPUT")
export FM_CROSSCHECK_BASE_SHA
FM_CROSSCHECK_BASE_SHA=$(jq -r '.identity.base_sha' "$INPUT")
export FM_CROSSCHECK_FINDING_IDS
FM_CROSSCHECK_FINDING_IDS=$(jq -c '.tool_protocol.known_finding_ids' "$INPUT")
export FM_CROSSCHECK_ELIGIBLE_EQUIVALENT_IDS
FM_CROSSCHECK_ELIGIBLE_EQUIVALENT_IDS=$(jq -c '.tool_protocol.eligible_equivalent_ids' "$INPUT")
export FM_CROSSCHECK_ACTIVE_FINDING_IDS
FM_CROSSCHECK_ACTIVE_FINDING_IDS=$(jq -c '.tool_protocol.active_finding_ids' "$INPUT")
export FM_CROSSCHECK_LOOKUP_ALLOWED
FM_CROSSCHECK_LOOKUP_ALLOWED=$(jq -r 'if .tool_protocol.lookup_allowed then "1" else "0" end' "$INPUT")
export FM_CROSSCHECK_TRUST_SNAPSHOT_MANIFEST=1
export FM_CROSSCHECK_EXECUTING_ACCOUNT_HOME="$ACCOUNT"
export FM_CROSSCHECK_EXECUTION_HOME="$HOME_DIR"
unset AZURE_CONFIG_DIR ARM_CLIENT_ID ARM_CLIENT_SECRET AZURE_CLIENT_ID AZURE_CLIENT_SECRET SSH_AUTH_SOCK DOCKER_HOST

RESULT=$BASE/reviewer-result.json
cd "$REPOSITORY"
case "$HARNESS" in
  codex)
    export CODEX_HOME="$ACCOUNT"
    codex exec -C "$REPOSITORY" --sandbox read-only --ephemeral --strict-config \
      --ignore-user-config --ignore-rules --skip-git-repo-check \
      --disable shell_tool --disable unified_exec --disable code_mode_host \
      -c project_doc_max_bytes=0 --model "$MODEL" \
      -c "model_reasoning_effort=\"$EFFORT\"" \
      --color never --output-schema "$SCHEMA" --output-last-message "$RESULT" - <"$PROMPT"
    ;;
  pi)
    export PI_CODING_AGENT_DIR="$ACCOUNT"
    # The model decides the provider slot (R6): each cross-family deployment
    # runs on its own provider slot, the gpt fallback family stays on
    # openai-codex, and an unmapped model refuses rather than guessing.
    case "$MODEL" in
      accounts/fireworks/models/glm-5p2) PI_PROVIDER=fireworks-glm ;;
      gpt-5.6-sol) PI_PROVIDER=openai-codex ;;
      *) echo "model guest: no Pi provider mapping for model $MODEL" >&2; exit 125 ;;
    esac
    python3 "$PI_REVIEWER_RUNTIME" "$ACCOUNT" "$MODEL" "$EFFORT" \
      "$PI_PROVIDER" "$VERDICT_EXTENSION" "$PROMPT" "$SCHEMA" "$RESULT"
    ;;
  *)
    echo "model guest: unsupported reviewer harness" >&2
    exit 125
    ;;
esac

[ -s "$RESULT" ] || { echo "model guest: reviewer produced no verdict" >&2; exit 125; }
rm -rf "$ACCOUNT"
[ ! -e "$ACCOUNT" ] && [ ! -e "$CREDENTIAL" ] || { echo "model guest: reviewer credential cleanup failed" >&2; exit 125; }

python3 - "$INPUT" "$RESULT" "$BASE/output.json" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID" <<'PY'
import json
import pathlib
import sys

request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
review = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
identity = request["identity"]
if not isinstance(review, dict):
    raise SystemExit("model guest: reviewer result is malformed")
harness = request.get("reviewer", {}).get("harness")
if harness == "pi" and not isinstance(review.get("tool_events"), list):
    raise SystemExit("model guest: reviewer omitted its replayable tool events")
output = {
    "schema": "fm.azure-crosscheck-result/v1",
    **identity,
    "request_digest": request["request_digest"],
    "model_resource_id": sys.argv[4],
    "model_vm_instance_id": sys.argv[5],
    **({"tool_events": review["tool_events"]} if harness == "pi" else {}),
    "telemetry": review.get("telemetry"),
}
lookup = review.get("lookup_request")
if lookup is not None:
    if harness != "pi" or not isinstance(lookup, list) or not lookup:
        raise SystemExit("model guest: lookup request is malformed")
    if "verdict" in review:
        raise SystemExit("model guest: provisional lookup carried authority")
    output["lookup_request"] = lookup
else:
    if not isinstance(review.get("verdict"), dict):
        raise SystemExit("model guest: reviewer omitted its verdict")
    output["verdict"] = review["verdict"]
path = pathlib.Path(sys.argv[3])
path.write_text(json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

OUTPUT=$BASE/output.json
DIGEST=sha256:$(sha256sum "$OUTPUT" | awk '{print $1}')
printf 'url = "%s"\nfail\nsilent\nshow-error\nrequest = "PUT"\nheader = "x-ms-blob-type: BlockBlob"\nupload-file = "%s"\n' "$OUTPUT_URL" "$OUTPUT" >"$BASE/curl-output.conf"
unset OUTPUT_URL
curl --config "$BASE/curl-output.conf"
rm -f "$BASE/curl-output.conf"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
printf 'FM_AZURE_CROSSCHECK_RESULT %s boot=%s\n' "$DIGEST" "$BOOT_ID"
