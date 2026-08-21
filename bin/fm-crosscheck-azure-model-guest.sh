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
# R6 cross-family lane registry, mirroring CROSS_FAMILY_LANES in
# bin/fm-crosscheck.py: model -> (provider slot, pinned chat-completions
# base URL, non-secret executing identity, pinned model-level compat).
CROSS_FAMILY_LANES = {
    "accounts/fireworks/models/glm-5p2": (
        "fireworks-glm",
        "https://api.fireworks.ai/inference/v1",
        "fireworks-glm:api.fireworks.ai/accounts/fireworks/models/glm-5p2",
        {},
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
    slot, allowed_base_url, account, allowed_compat = lane
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
    pi --mode json --provider "$PI_PROVIDER" --model "$MODEL" --thinking "$EFFORT" \
      --no-tools --no-session --no-extensions --no-skills --no-prompt-templates \
      --no-themes --no-context-files --no-approve "$(<"$PROMPT")" >"$BASE/pi-events.jsonl"
    python3 - "$BASE/pi-events.jsonl" "$RESULT" <<'PY'
import json
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])

# BEGIN PI_VERDICT_BODY_CONTRACT
PI_FENCED_BLOCK_RE = re.compile(
    r"```[A-Za-z0-9_+.-]*[ \t]*\r?\n(?P<body>.*?)\r?\n?```",
    re.DOTALL,
)


def pi_verdict_body(final_text: str) -> str:
    """Return the JSON body of a Pi reviewer's final assistant text.

    An UNTERMINATED fence anywhere in the message refuses outright, before the
    block count is even consulted. That ordering is the whole safety property.
    A truncated verdict fence contributes ZERO complete blocks, so a model that
    emitted any complete fence earlier in the same message - a draft, an
    example, a quoted snippet - left the count at exactly one, and this
    returned THAT EARLIER BLOCK as the verdict while silently discarding the
    truncated real one. `stopReason` is `stop` in that shape (the exact live
    condition seen on attempt 3), and the parse SUCCEEDS on the wrong block, so
    nothing else downstream catches it: a superseded draft gets certified as
    the review. That is strictly worse than the failure it replaced, which at
    least failed loudly.
    """

    stripped = final_text.strip()
    # An odd number of fence markers means one was opened and never closed.
    # Refusing on the marker count rather than on "no complete block found"
    # is what makes a preceding complete fence unable to rescue a truncated
    # one; returning the raw text sends it to the parser, which fails.
    if stripped.count("```") % 2:
        return stripped
    blocks = PI_FENCED_BLOCK_RE.findall(stripped)
    if len(blocks) != 1:
        return stripped
    # The block must be the ONLY JSON-bearing content in the message. An even
    # fence count is not enough on its own: a COMPLETE example fence followed
    # by a truncated BARE verdict also counts one block, and unwrapping there
    # would certify the example and discard the real answer. Prose carries no
    # braces, so this still tolerates a wrapper while refusing every shape
    # where a second candidate verdict exists.
    remainder = PI_FENCED_BLOCK_RE.sub("", stripped, count=1)
    if "{" in remainder or "}" in remainder:
        return stripped
    return blocks[0].strip()
# END PI_VERDICT_BODY_CONTRACT


turn_count = 0
attempt_turn_count = 0
agent_ended = False
final_text = None
final_stop_reason = None
final_error = None
for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), start=1):
    if not line.strip():
        continue
    try:
        event = json.loads(line)
    except (json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise SystemExit(
            f"model guest: Pi returned malformed JSON events at line {line_number}: {exc}"
        )
    if not isinstance(event, dict):
        raise SystemExit(
            f"model guest: Pi returned a non-object event at line {line_number}"
        )
    event_type = event.get("type")
    if event_type == "turn_end":
        if agent_ended:
            raise SystemExit("model guest: Pi emitted a turn after agent completion")
        turn_count += 1
        attempt_turn_count += 1
        final_text = None
        final_stop_reason = None
        final_error = None
        message = event.get("message")
        if isinstance(message, dict) and message.get("role") == "assistant":
            stop_reason = message.get("stopReason")
            if isinstance(stop_reason, str):
                final_stop_reason = stop_reason
            error_message = message.get("errorMessage")
            if isinstance(error_message, str) and error_message.strip():
                final_error = error_message.strip()
            content = message.get("content")
            if isinstance(content, str):
                final_text = content
            elif isinstance(content, list):
                text_parts = [
                    part["text"]
                    for part in content
                    if isinstance(part, dict)
                    and part.get("type") == "text"
                    and isinstance(part.get("text"), str)
                ]
                if text_parts:
                    final_text = "".join(text_parts)
    elif event_type == "agent_end":
        if agent_ended:
            raise SystemExit("model guest: Pi emitted duplicate agent completion")
        agent_ended = True
    elif event_type == "auto_retry_start":
        if not agent_ended:
            raise SystemExit(
                "model guest: Pi announced a retry while its agent was still running"
            )
        if attempt_turn_count == 0:
            raise SystemExit(
                "model guest: Pi announced a retry after an attempt that executed no turn"
            )
        if final_stop_reason == "stop":
            raise SystemExit(
                "model guest: Pi announced a retry after a successful assistant turn"
            )
        agent_ended = False
        attempt_turn_count = 0
        final_text = None
        final_stop_reason = None
        final_error = None
if turn_count == 0:
    raise SystemExit("model guest: Pi completed without executing a turn")
if not agent_ended:
    raise SystemExit("model guest: Pi stopped before agent completion")
if attempt_turn_count == 0:
    raise SystemExit("model guest: Pi final attempt completed without executing a turn")
if final_stop_reason != "stop":
    raise SystemExit(
        "model guest: Pi final assistant turn did not stop successfully: "
        f"stopReason={final_stop_reason!r}"
        + (f": {final_error[:500]}" if final_error else "")
    )
if final_text is None or not final_text.strip():
    raise SystemExit("model guest: Pi completed without a verdict artifact")
body = pi_verdict_body(final_text)
try:
    value = json.loads(body)
except (json.JSONDecodeError, ValueError, RecursionError) as exc:
    raise SystemExit(
        f"model guest: Pi returned a malformed verdict artifact: {exc}; "
        f"final assistant text began {body[:240]!r}"
    )
if not isinstance(value, dict):
    raise SystemExit("model guest: Pi verdict artifact must be an object")
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
