#!/usr/bin/env bash
# Trusted root-side Azure Crosscheck model-compartment payload.
#
# This compartment receives exactly one reviewer credential and no repository.
# The model receives one bounded static exact-head review packet and has no
# repository or command tools. Reviewer-supplied evidence is returned as data;
# the host controller executes and replays it later in fresh credentialless
# `crosscheck-tool` Azure runner invocations.
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
OUTPUT_URL=${output_url:-}
unset review_generation vm_resource_id vm_instance_id guest_digest
unset input_url credential_url output_url
[ -n "$REVIEW_GENERATION" ] && [ -n "$VM_RESOURCE_ID" ] && [ -n "$VM_INSTANCE_ID" ] \
  && [ -n "$GUEST_DIGEST" ] && [ -n "$INPUT_URL" ] && [ -n "$CREDENTIAL_URL" ] \
  && [ -n "$OUTPUT_URL" ] || { echo "model guest: expected seven bound parameters" >&2; exit 125; }

case "$REVIEW_GENERATION" in [0-9a-f][0-9a-f]*) ;; *) echo "model guest: malformed review generation" >&2; exit 125 ;; esac
case "$GUEST_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "model guest: malformed guest digest" >&2; exit 125 ;; esac
[ -n "$VM_RESOURCE_ID" ] && [ -n "$VM_INSTANCE_ID" ] || { echo "model guest: missing VM identity" >&2; exit 125; }
case "$INPUT_URL" in https://*) ;; *) echo "model guest: input capability is not HTTPS" >&2; exit 125 ;; esac
case "$CREDENTIAL_URL" in https://*) ;; *) echo "model guest: credential capability is not HTTPS" >&2; exit 125 ;; esac
case "$OUTPUT_URL" in https://*) ;; *) echo "model guest: output capability is not HTTPS" >&2; exit 125 ;; esac

BASE=/var/lib/fm-crosscheck-model
rm -rf "$BASE"
install -d -m 0700 -o root -g root "$BASE"
INPUT=$BASE/request.json
CREDENTIAL=$BASE/credential.tar.gz
curl --fail --silent --show-error --max-filesize 2097152 --output "$INPUT" "$INPUT_URL"
curl --fail --silent --show-error --max-filesize 131072 --output "$CREDENTIAL" "$CREDENTIAL_URL"
unset INPUT_URL CREDENTIAL_URL

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
    ["submit_crosscheck_verdict"]
    if value.get("reviewer", {}).get("harness") == "pi"
    else []
)
if value.get("tool_protocol", {}).get("model_tools") != expected_tools:
    raise SystemExit("model guest: model tool allowlist mismatch")
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
rm -f "$CREDENTIAL"

export HOME="$HOME_DIR"
export TMPDIR="$BASE/tmp"
export XDG_CACHE_HOME="$BASE/cache"
install -d -m 0700 -o root -g root "$TMPDIR" "$XDG_CACHE_HOME"
export FM_CROSSCHECK_REVIEW_GENERATION="$REVIEW_GENERATION"
unset AZURE_CONFIG_DIR ARM_CLIENT_ID ARM_CLIENT_SECRET AZURE_CLIENT_ID AZURE_CLIENT_SECRET SSH_AUTH_SOCK DOCKER_HOST

RESULT=$BASE/reviewer-result.json
case "$HARNESS" in
  codex)
    export CODEX_HOME="$ACCOUNT"
    codex exec -C "$BASE" --sandbox read-only --ephemeral --strict-config \
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
if not isinstance(review, dict) or not isinstance(review.get("verdict"), dict):
    raise SystemExit("model guest: reviewer omitted its verdict")
harness = request.get("reviewer", {}).get("harness")
expected_evidence_type = list if harness == "pi" else dict
if not isinstance(review.get("evidence_files"), expected_evidence_type):
    raise SystemExit("model guest: reviewer omitted its evidence manifest")
output = {
    "schema": "fm.azure-crosscheck-result/v1",
    **identity,
    "request_digest": request["request_digest"],
    "model_resource_id": sys.argv[4],
    "model_vm_instance_id": sys.argv[5],
    "verdict": review["verdict"],
    "evidence_files": review["evidence_files"],
    "telemetry": review.get("telemetry"),
}
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
