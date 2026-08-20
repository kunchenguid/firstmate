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

python3 - "$INPUT" "$REVIEW_GENERATION" "$GUEST_DIGEST" <<'PY'
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
if value.get("tool_protocol", {}).get("network_bytes") != 0:
    raise SystemExit("model guest: repository tool contract is not networkless")
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
if reviewer["harness"] == "pi" and reviewer["model"] == "FW-GLM-5.2":
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
if reviewer["harness"] == "pi" and reviewer["model"] == "FW-GLM-5.2":
    # R6 GLM lane: the api-key credential must stay inside the pinned
    # chat-completions endpoint allowlist, and the executing identity is
    # the non-secret Foundry resource/deployment binding.
    providers = credential.get("providers") if isinstance(credential, dict) else None
    entry = (
        providers.get("azure-glm")
        if isinstance(providers, dict) and set(providers) == {"azure-glm"}
        else None
    )
    base_url = entry.get("baseUrl") if isinstance(entry, dict) else None
    if base_url != "https://aif-fm7c799d-eus01.cognitiveservices.azure.com/openai/v1":
        raise SystemExit("model guest: GLM credential endpoint allowlist mismatch")
    # pi gives model-level baseUrl/api precedence over the provider level,
    # so any model entry carrying either field escapes the provider pin.
    models = entry.get("models") if isinstance(entry, dict) else None
    for model_entry in (models if isinstance(models, list) else []):
        if isinstance(model_entry, dict) and ("baseUrl" in model_entry or "api" in model_entry):
            raise SystemExit("model guest: GLM credential model-level endpoint override")
    account = "azure-glm:aif-fm7c799d-eus01/FW-GLM-5.2"
elif reviewer["harness"] == "codex":
    tokens = credential.get("tokens") if isinstance(credential, dict) else None
    account = tokens.get("account_id") if isinstance(tokens, dict) else None
else:
    entry = credential.get("openai-codex") if isinstance(credential, dict) else None
    account = entry.get("accountId") if isinstance(entry, dict) else None
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
    # The model decides the provider slot (R6): the GLM deployment runs on
    # the azure-glm Foundry provider, the gpt fallback family stays on
    # openai-codex, and an unmapped model refuses rather than guessing.
    case "$MODEL" in
      FW-GLM-5.2) PI_PROVIDER=azure-glm ;;
      gpt-5.6-sol) PI_PROVIDER=openai-codex ;;
      *) echo "model guest: no Pi provider mapping for model $MODEL" >&2; exit 125 ;;
    esac
    pi --mode json --provider "$PI_PROVIDER" --model "$MODEL" --thinking "$EFFORT" \
      --no-tools --no-session --no-extensions --no-skills --no-prompt-templates \
      --no-themes --no-context-files --no-approve "$(<"$PROMPT")" >"$BASE/pi-events.jsonl"
    python3 - "$BASE/pi-events.jsonl" "$RESULT" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
final = None
ended = False
for line in source.read_text(encoding="utf-8").splitlines():
    event = json.loads(line)
    if event.get("type") == "turn_end":
        message = event.get("message") or {}
        if message.get("role") == "assistant" and message.get("stopReason") == "stop":
            content = message.get("content")
            if isinstance(content, str):
                final = content
            elif isinstance(content, list):
                final = "".join(part.get("text", "") for part in content if isinstance(part, dict))
    elif event.get("type") == "agent_end":
        ended = True
if not ended or not final:
    raise SystemExit("model guest: Pi stopped without a successful verdict")
value = json.loads(final)
destination.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
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
if not isinstance(review.get("evidence_files"), dict):
    raise SystemExit("model guest: reviewer omitted its evidence manifest")
output = {
    "schema": "fm.azure-crosscheck-result/v1",
    **identity,
    "request_digest": request["request_digest"],
    "model_resource_id": sys.argv[4],
    "model_vm_instance_id": sys.argv[5],
    "verdict": review["verdict"],
    "evidence_files": review["evidence_files"],
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
