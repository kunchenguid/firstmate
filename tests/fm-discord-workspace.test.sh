#!/usr/bin/env bash
# Behavior tests for private Discord workspace planning, receipts, and artifacts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-workspace-tests)
HOME1="$TMP_ROOT/home"
mkdir -p "$HOME1/state" "$HOME1/data" "$HOME1/config" "$HOME1/projects"
CFG="$HOME1/config/discord-workspace.json"
FM_HOME="$HOME1" "$ROOT/bin/fm-discord-workspace.sh" sample-config > "$CFG"
python3 - "$CFG" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["proapplis"]["thread_ids"]["exchange"]=["888888888888888881"]
data["profiles"]["proapplis"]["thread_ids"]["artifacts"]=["888888888888888882"]
data["transcription"]["provider"]="fake"
data["transcription"]["fake_transcripts"]={"999999999999999998":"transcribed voice fixture"}
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY

fw() { FM_HOME="$HOME1" "$ROOT/bin/fm-discord-workspace.sh" "$@"; }
request_id='discord:111111111111111111:888888888888888881:999999999999999999'
thread_request_id='discord:111111111111111111:888888888888888881:999999999999999997'

out=$(fw config-check --config "$CFG")
assert_contains "$out" "config ok" "valid config passes"
assert_contains "$out" "ProApplis: exchange threads 1" "thread allowlist is reported"
pass "valid non-secret config is accepted"

for invalid_expiry in '' 0d forever; do
  INVALID_EXPIRY="$TMP_ROOT/invalid-expiry-${invalid_expiry:-empty}.json"
  python3 - "$CFG" "$INVALID_EXPIRY" "$invalid_expiry" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["artifacts"]["default_expiry"] = sys.argv[3]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_expiry_status=0
  invalid_expiry_out=$(fw config-check --config "$INVALID_EXPIRY" 2>&1) || invalid_expiry_status=$?
  [ "$invalid_expiry_status" -ne 0 ] || fail "invalid default artifact expiry was accepted: $invalid_expiry"
  assert_contains "$invalid_expiry_out" "positive duration" "invalid default artifact expiry is refused"
done
for invalid_audio_bytes in 0 -1; do
  INVALID_AUDIO_BYTES="$TMP_ROOT/invalid-audio-bytes-$invalid_audio_bytes.json"
  python3 - "$CFG" "$INVALID_AUDIO_BYTES" "$invalid_audio_bytes" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["audio"]["max_bytes"] = int(sys.argv[3])
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_audio_bytes_status=0
  invalid_audio_bytes_out=$(fw config-check --config "$INVALID_AUDIO_BYTES" 2>&1) || invalid_audio_bytes_status=$?
  [ "$invalid_audio_bytes_status" -ne 0 ] || fail "non-positive audio byte limit was accepted: $invalid_audio_bytes"
  assert_contains "$invalid_audio_bytes_out" "positive JSON integer" "non-positive audio byte limit is refused"
done
for byte_field in direct audio; do
  for invalid_type in boolean string fraction; do
    INVALID_BYTE_TYPE="$TMP_ROOT/invalid-$byte_field-$invalid_type.json"
    python3 - "$CFG" "$INVALID_BYTE_TYPE" "$byte_field" "$invalid_type" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
value = {"boolean": True, "string": "1024", "fraction": 1024.5}[sys.argv[4]]
if sys.argv[3] == "direct":
    data["artifacts"]["direct_attachment_max_bytes"] = value
else:
    data["audio"]["max_bytes"] = value
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
    invalid_byte_status=0
    invalid_byte_out=$(fw config-check --config "$INVALID_BYTE_TYPE" 2>&1) || invalid_byte_status=$?
    [ "$invalid_byte_status" -ne 0 ] || fail "$byte_field byte limit accepted $invalid_type JSON"
    assert_contains "$invalid_byte_out" "positive JSON integer" "$byte_field byte limit rejects invalid JSON type"
  done
done
pass "config validates artifact expiry and byte limit types"

for invalid_root_case in empty whitespace boolean numeric list object dot traversal; do
  INVALID_ROOT_CFG="$TMP_ROOT/invalid-root-$invalid_root_case.json"
  python3 - "$CFG" "$INVALID_ROOT_CFG" "$invalid_root_case" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
value = {
    "empty": "",
    "whitespace": "   ",
    "boolean": True,
    "numeric": 7,
    "list": ["data"],
    "object": {"root": "data"},
    "dot": ".",
    "traversal": "../outside",
}[sys.argv[3]]
data["artifacts"]["allowed_roots"] = [value]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_root_status=0
  invalid_root_out=$(fw config-check --config "$INVALID_ROOT_CFG" 2>&1) || invalid_root_status=$?
  [ "$invalid_root_status" -ne 0 ] || fail "invalid artifact root was accepted: $invalid_root_case"
  assert_contains "$invalid_root_out" "artifacts.allowed_roots[0]" "invalid artifact root identifies its config item"
done
for valid_root_case in relative absolute; do
  VALID_ROOT_CFG="$TMP_ROOT/valid-root-$valid_root_case.json"
  python3 - "$CFG" "$VALID_ROOT_CFG" "$valid_root_case" "$HOME1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["artifacts"]["allowed_roots"] = [
    "data/custom-artifacts" if sys.argv[3] == "relative" else f"{sys.argv[4]}/data/custom-artifacts"
]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  valid_root_out=$(fw config-check --config "$VALID_ROOT_CFG")
  assert_contains "$valid_root_out" "config ok" "valid $valid_root_case custom artifact root remains supported"
done
pass "artifact roots require explicit non-empty string forms"

for invalid_provider_case in unknown boolean numeric list object null; do
  INVALID_PROVIDER_CFG="$TMP_ROOT/invalid-provider-$invalid_provider_case.json"
  python3 - "$CFG" "$INVALID_PROVIDER_CFG" "$invalid_provider_case" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["transcription"]["provider"] = {
    "unknown": "fakse",
    "boolean": True,
    "numeric": 1,
    "list": ["fake"],
    "object": {"name": "fake"},
    "null": None,
}[sys.argv[3]]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_provider_status=0
  invalid_provider_out=$(fw config-check --config "$INVALID_PROVIDER_CFG" 2>&1) || invalid_provider_status=$?
  [ "$invalid_provider_status" -ne 0 ] || fail "invalid transcription provider was accepted: $invalid_provider_case"
  assert_contains "$invalid_provider_out" "transcription.provider must be disabled, fake, or groq" "invalid transcription provider is rejected at config load"
done
for valid_provider in disabled fake groq; do
  VALID_PROVIDER_CFG="$TMP_ROOT/valid-provider-$valid_provider.json"
  python3 - "$CFG" "$VALID_PROVIDER_CFG" "$valid_provider" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["transcription"]["provider"] = sys.argv[3]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  valid_provider_out=$(fw config-check --config "$VALID_PROVIDER_CFG")
  assert_contains "$valid_provider_out" "config ok" "supported $valid_provider transcription provider remains valid"
done
pass "transcription providers enforce supported JSON strings"

for invalid_cdn_case in empty whitespace boolean numeric list object scheme port path wildcard trailing-dot uppercase duplicate; do
  INVALID_CDN_CFG="$TMP_ROOT/invalid-cdn-$invalid_cdn_case.json"
  python3 - "$CFG" "$INVALID_CDN_CFG" "$invalid_cdn_case" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
value = {
    "empty": "",
    "whitespace": "   ",
    "boolean": True,
    "numeric": 7,
    "list": ["cdn.discordapp.com"],
    "object": {"host": "cdn.discordapp.com"},
    "scheme": "https://cdn.discordapp.com",
    "port": "cdn.discordapp.com:443",
    "path": "cdn.discordapp.com/audio",
    "wildcard": "*.discordapp.com",
    "trailing-dot": "cdn.discordapp.com.",
    "uppercase": "CDN.DISCORDAPP.COM",
    "duplicate": "cdn.discordapp.com",
}[sys.argv[3]]
data["audio"]["allowed_cdn_hosts"] = (
    ["cdn.discordapp.com", value] if sys.argv[3] == "duplicate" else [value]
)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_cdn_status=0
  invalid_cdn_out=$(fw config-check --config "$INVALID_CDN_CFG" 2>&1) || invalid_cdn_status=$?
  [ "$invalid_cdn_status" -ne 0 ] || fail "invalid CDN hostname was accepted: $invalid_cdn_case"
  assert_contains "$invalid_cdn_out" "audio.allowed_cdn_hosts" "invalid CDN hostname identifies its config item"
done
VALID_CDN_CFG="$TMP_ROOT/valid-cdn-hosts.json"
python3 - "$CFG" "$VALID_CDN_CFG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["audio"]["allowed_cdn_hosts"] = ["cdn.discordapp.com", "media.discordapp.net"]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
valid_cdn_out=$(fw config-check --config "$VALID_CDN_CFG")
assert_contains "$valid_cdn_out" "config ok" "safe Discord CDN hostname defaults remain valid"
pass "audio CDN policy requires unique normalized hostnames"

for policy_alias in host live-host approvals-host artifact-access artifact-access-mode; do
  for invalid_policy_type in boolean numeric list object null; do
    INVALID_POLICY_ALIAS_CFG="$TMP_ROOT/invalid-$policy_alias-$invalid_policy_type.json"
    python3 - "$CFG" "$INVALID_POLICY_ALIAS_CFG" "$policy_alias" "$invalid_policy_type" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
value = {
    "boolean": False,
    "numeric": 0,
    "list": ["disabled"],
    "object": {"value": "disabled"},
    "null": None,
}[sys.argv[4]]
alias = sys.argv[3]
if alias == "host":
    data["host"] = value
elif alias == "live-host":
    data["live"]["host"] = value
elif alias == "approvals-host":
    data["approvals"]["host"] = value
elif alias == "artifact-access":
    data["artifacts"]["access"] = value
else:
    data["artifacts"]["access_mode"] = value
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
    invalid_policy_alias_status=0
    invalid_policy_alias_out=$(fw config-check --config "$INVALID_POLICY_ALIAS_CFG" 2>&1) || invalid_policy_alias_status=$?
    [ "$invalid_policy_alias_status" -ne 0 ] \
      || fail "$policy_alias accepted $invalid_policy_type JSON"
    case "$policy_alias" in
      artifact-*) assert_contains "$invalid_policy_alias_out" "artifacts." "invalid artifact access alias identifies its config path" ;;
      *) assert_contains "$invalid_policy_alias_out" "host must be" "invalid host alias identifies its config path" ;;
    esac
  done
done
for valid_policy_alias in root-host approvals-host access-mode; do
  VALID_POLICY_ALIAS_CFG="$TMP_ROOT/valid-policy-$valid_policy_alias.json"
  python3 - "$CFG" "$VALID_POLICY_ALIAS_CFG" "$valid_policy_alias" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
case = sys.argv[3]
if case == "root-host":
    data["host"] = "omarchy"
elif case == "approvals-host":
    data["approvals"]["host"] = "vps"
else:
    data["artifacts"].pop("access", None)
    data["artifacts"]["access_mode"] = "tailnet"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  valid_policy_alias_out=$(fw config-check --config "$VALID_POLICY_ALIAS_CFG")
  assert_contains "$valid_policy_alias_out" "config ok" "supported $valid_policy_alias remains valid"
done
pass "host and artifact access aliases enforce enum strings"

for policy_section in guild bot tags approvals live outbound artifacts audio transcription poll; do
  INVALID_SECTION="$TMP_ROOT/invalid-section-$policy_section.json"
  python3 - "$CFG" "$INVALID_SECTION" "$policy_section" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data[sys.argv[3]] = []
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_section_status=0
  invalid_section_out=$(fw config-check --config "$INVALID_SECTION" 2>&1) || invalid_section_status=$?
  [ "$invalid_section_status" -ne 0 ] || fail "$policy_section policy section accepted a non-object"
  assert_contains "$invalid_section_out" "$policy_section must be a JSON object" "$policy_section policy section enforces its type"
done
for invalid_duration_type in boolean string; do
  INVALID_DURATION_TYPE="$TMP_ROOT/invalid-duration-type-$invalid_duration_type.json"
  python3 - "$CFG" "$INVALID_DURATION_TYPE" "$invalid_duration_type" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["audio"]["max_duration_secs"] = {"boolean": True, "string": "12"}[sys.argv[3]]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  invalid_duration_type_status=0
  invalid_duration_type_out=$(fw config-check --config "$INVALID_DURATION_TYPE" 2>&1) || invalid_duration_type_status=$?
  [ "$invalid_duration_type_status" -ne 0 ] || fail "audio duration accepted $invalid_duration_type JSON"
  assert_contains "$invalid_duration_type_out" "encoded as a JSON number" "audio duration rejects $invalid_duration_type JSON"
done
VALID_FRACTIONAL_DURATION="$TMP_ROOT/valid-fractional-duration.json"
python3 - "$CFG" "$VALID_FRACTIONAL_DURATION" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["audio"]["max_duration_secs"] = 12.5
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
fractional_duration_out=$(fw config-check --config "$VALID_FRACTIONAL_DURATION")
assert_contains "$fractional_duration_out" "config ok" "positive fractional JSON duration remains valid"
pass "config enforces policy object and duration types"

INVALID_THREAD_IDS="$TMP_ROOT/invalid-thread-ids.json"
python3 - "$CFG" "$INVALID_THREAD_IDS" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["profiles"]["proapplis"]["thread_ids"] = []
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
invalid_thread_ids_status=0
invalid_thread_ids_out=$(fw config-check --config "$INVALID_THREAD_IDS" 2>&1) || invalid_thread_ids_status=$?
[ "$invalid_thread_ids_status" -ne 0 ] || fail "thread_ids accepted a non-object container"
assert_contains "$invalid_thread_ids_out" "thread_ids must be a JSON object" "thread_ids container enforces its type"
pass "profile thread allowlists reject malformed containers"

DUP="$TMP_ROOT/duplicate.json"
cp "$CFG" "$DUP"
python3 - "$DUP" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["folium"]["exchange_forum_id"]=data["profiles"]["proapplis"]["exchange_forum_id"]
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
dup_status=0
dup_out=$(fw config-check --config "$DUP" 2>&1) || dup_status=$?
[ "$dup_status" -ne 0 ] || fail "duplicate forum id was accepted"
assert_contains "$dup_out" "duplicate Discord id" "duplicate forum id refusal is explicit"

PLACEHOLDER="$TMP_ROOT/placeholder.json"
cp "$CFG" "$PLACEHOLDER"
python3 - "$PLACEHOLDER" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["example-client"]={"enabled": False}
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
placeholder_status=0
placeholder_out=$(fw config-check --config "$PLACEHOLDER" 2>&1) || placeholder_status=$?
[ "$placeholder_status" -ne 0 ] || fail "dormant profile placeholder was accepted"
assert_contains "$placeholder_out" "unsupported profile(s): example-client" "profile placeholder refusal is explicit"

SECRET="$TMP_ROOT/secret.json"
cp "$CFG" "$SECRET"
python3 - "$SECRET" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["bot_token"]="do-not-print-this-value"
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
secret_status=0
secret_out=$(fw config-check --config "$SECRET" 2>&1) || secret_status=$?
[ "$secret_status" -ne 0 ] || fail "inline secret-looking config was accepted"
assert_contains "$secret_out" "inline secret" "inline secret refusal is explicit"
assert_not_contains "$secret_out" "do-not-print-this-value" "secret-looking value is not printed"
for secret_key in access_token discord_token groq_password service_credential client-secret vendor_api_key; do
  SECRET_VARIANT="$TMP_ROOT/secret-variant-${secret_key//_/-}.json"
  python3 - "$CFG" "$SECRET_VARIANT" "$secret_key" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["nested"] = {sys.argv[3]: "fixture-value"}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  secret_variant_status=0
  secret_variant_out=$(fw config-check --config "$SECRET_VARIANT" 2>&1) || secret_variant_status=$?
  [ "$secret_variant_status" -ne 0 ] || fail "secret-shaped key was accepted: $secret_key"
  assert_contains "$secret_variant_out" "inline secret" "secret-shaped key is rejected recursively"
  assert_not_contains "$secret_variant_out" "fixture-value" "secret-shaped field value is not echoed"
done
for secret_field in discord_bot_token_key transcription.api_key; do
  SECRET_REF="$TMP_ROOT/secret-ref-${secret_field//./-}.json"
  python3 - "$CFG" "$SECRET_REF" "$secret_field" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
if sys.argv[3] == "discord_bot_token_key":
    data["discord_bot_token_key"] = "actual.token-looking-value"
else:
    data["transcription"]["api_key"] = "gsk_actual_token_value"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  secret_ref_status=0
  secret_ref_out=$(fw health --secrets --config "$SECRET_REF" 2>&1) || secret_ref_status=$?
  [ "$secret_ref_status" -ne 0 ] || fail "inline-looking secret reference was accepted: $secret_field"
  assert_contains "$secret_ref_out" "uppercase secret reference name" "invalid secret reference is refused"
  assert_not_contains "$secret_ref_out" "actual.token-looking-value" "Discord token value is not echoed"
  assert_not_contains "$secret_ref_out" "gsk_actual_token_value" "transcription token value is not echoed"
done
pass "config rejects profile placeholders, inline secrets, and invalid references"

mkdir -p "$HOME1/data/reference-store"
ln -s "$HOME1/data/reference-store" "$HOME1/config/reference-link"
for invalid_reference in '/config/reference.sops.yaml' 'config/../reference.sops.yaml' 'config//reference.sops.yaml' 'config/reference.yaml' 'config/reference-link/reference.sops.yaml'; do
  SECRET_PATH_CFG="$TMP_ROOT/invalid-secret-path-$(printf '%s' "$invalid_reference" | tr '/.' '--').json"
  python3 - "$CFG" "$SECRET_PATH_CFG" "$invalid_reference" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["transcription"]["secret_file"] = sys.argv[3]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  secret_path_status=0
  secret_path_out=$(fw config-check --config "$SECRET_PATH_CFG" 2>&1) || secret_path_status=$?
  [ "$secret_path_status" -ne 0 ] || fail "invalid secret file reference was accepted: $invalid_reference"
  assert_contains "$secret_path_out" "secret file reference" "invalid secret file path is refused without disclosure"
  assert_not_contains "$secret_path_out" "$invalid_reference" "invalid secret file value is not echoed"
done
pass "secret file references stay normalized beneath config"

out=$(fw setup --dry-run --config "$CFG")
assert_contains "$out" "no network" "setup dry-run says it is offline"
assert_contains "$out" "temporary setup permission integer" "setup dry-run prints setup permissions"
assert_contains "$out" "steady-state permission integer" "setup dry-run prints steady permissions"
assert_contains "$out" "profile System / Firstmate" "setup dry-run names the system category"
assert_contains "$out" "profile ProApplis" "setup dry-run names the ProApplis category"
assert_contains "$out" "profile Folium" "setup dry-run names the Folium category"
assert_contains "$out" "exchanges forum" "setup dry-run names exchange forums"
assert_contains "$out" "artifacts forum" "setup dry-run names artifact forums"
assert_contains "$out" "request, decision, work, status, blocked, done" "setup dry-run prints exchange tags"
assert_contains "$out" "report, board, document, image, audio, draft, final, expired" "setup dry-run prints artifact tags"
assert_contains "$out" "remaining unapproved live choices" "setup dry-run reports inactive live choices"
apply_status=0
apply_out=$(fw setup --apply --config "$CFG" 2>&1) || apply_status=$?
[ "$apply_status" -ne 0 ] || fail "setup --apply was accepted"
assert_contains "$apply_out" "not available" "setup --apply refuses in phase one"

LIVECHOICES="$TMP_ROOT/live-choices.json"
cp "$CFG" "$LIVECHOICES"
python3 - "$LIVECHOICES" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["approvals"]["message_content"]=True
data["approvals"]["temporary_setup_permissions"]=True
data["approvals"]["hosted_groq"]=True
data["approvals"]["community_mode_required"]=True
data["live"]={"polling": True, "posting": True, "host": "omarchy"}
data["outbound"]["live_posting"]=True
data["artifacts"]["access"]="tailnet"
data["artifacts"]["default_expiry"]="3d"
data["transcription"]["provider"]="groq"
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
out=$(fw setup --dry-run --config "$LIVECHOICES")
assert_contains "$out" "Discord MESSAGE_CONTENT is configured but inactive" "message content remains inert when configured"
assert_contains "$out" "host omarchy is configured but not activated" "host choice remains inert when configured"
assert_contains "$out" "hosted Groq transcription is configured but inactive" "hosted Groq remains inert when configured"
assert_contains "$out" "artifact access tailnet with expiry 3d is configured but inactive" "artifact access remains inert when configured"
assert_contains "$out" "temporary setup permissions are configured but unusable" "temporary setup permissions remain inert when configured"
assert_contains "$out" "live posting is configured but refused" "live posting remains inert when configured"
assert_contains "$out" "live process-event polling is configured but refused" "live polling remains inert when configured"
pass "setup planning is explicit, live choices stay inert, and apply mode refuses"

THREAD_PERMISSION_PLAN="$TMP_ROOT/thread-permissions.txt"
NO_THREAD_PERMISSION_PLAN="$TMP_ROOT/no-thread-permissions.txt"
fw setup --dry-run --config "$CFG" > "$THREAD_PERMISSION_PLAN"
NO_THREADS_CFG="$TMP_ROOT/no-threads.json"
python3 - "$CFG" "$NO_THREADS_CFG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
for profile in data["profiles"].values():
    profile["thread_ids"] = {"exchange": [], "artifacts": []}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
fw setup --dry-run --config "$NO_THREADS_CFG" > "$NO_THREAD_PERMISSION_PLAN"
python3 - "$THREAD_PERMISSION_PLAN" "$NO_THREAD_PERMISSION_PLAN" <<'PY'
import re, sys
required = 1 << 14
excluded = (1 << 3) | (1 << 13) | (1 << 20) | (1 << 21) | (1 << 29)
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    values = [int(value) for value in re.findall(r"permission integer: ([0-9]+)", text)]
    if len(values) != 2:
        raise SystemExit("permission plan did not expose setup and steady integers")
    for value in values:
        if not value & required:
            raise SystemExit("permission plan omitted EMBED_LINKS")
        if value & excluded:
            raise SystemExit("permission plan included an excluded permission")
PY
pass "setup permission plans include embeds without privileged permissions"

health_status=0
health_out=$(FMX_PAIRING_TOKEN='do-not-print-this-value' fw health --secrets --config "$CFG" 2>&1) || health_status=$?
[ "$health_status" -ne 0 ] || fail "live secret health unexpectedly succeeded"
assert_contains "$health_out" "no secret was decrypted or printed" "secret health reports the privacy boundary"
assert_contains "$health_out" "Discord bot token reference: configured" "secret health reports the bot reference generically"
assert_contains "$health_out" "transcription key reference: configured" "secret health reports the transcription reference generically"
assert_contains "$health_out" "secret file reference: configured" "secret health reports a configured file reference"
assert_not_contains "$health_out" "FIRSTMATE_DISCORD_BOT_TOKEN" "secret health does not print the bot reference name"
assert_not_contains "$health_out" "FIRSTMATE_DISCORD_GROQ_API_KEY" "secret health does not print the transcription reference name"
assert_not_contains "$health_out" "discord-workspace.secrets.sops.yaml" "secret health does not print the file reference value"
assert_not_contains "$health_out" "do-not-print-this-value" "secret health never prints ambient secrets"
discord_status=0
discord_out=$(fw health --discord --config "$CFG" 2>&1) || discord_status=$?
[ "$discord_status" -ne 0 ] || fail "live Discord health unexpectedly succeeded"
assert_contains "$discord_out" "no network call" "Discord health refuses without network"
pass "health checks stay dry-run only"

SYMLINK_HOME="$TMP_ROOT/symlink-state-home"
mkdir -p "$SYMLINK_HOME/state" "$SYMLINK_HOME/data/redirected-state" "$SYMLINK_HOME/config"
cp "$CFG" "$SYMLINK_HOME/config/discord-workspace.json"
ln -s "$SYMLINK_HOME/data/redirected-state" "$SYMLINK_HOME/state/discord-workspace"
SYMLINK_TEXT="$TMP_ROOT/symlink-state-reply.txt"
printf 'State root safety check.\n' > "$SYMLINK_TEXT"
symlink_state_status=0
symlink_state_out=$(FM_HOME="$SYMLINK_HOME" "$ROOT/bin/fm-discord-workspace.sh" reply \
  --config "$SYMLINK_HOME/config/discord-workspace.json" --request-id "$request_id" \
  --text-file "$SYMLINK_TEXT" --record-discord-message-id 123456789012345677 2>&1) || symlink_state_status=$?
[ "$symlink_state_status" -ne 0 ] || fail "receipt write followed a symlinked Discord state root"
assert_contains "$symlink_state_out" "Discord state root is unsafe" "symlinked Discord state root is refused"
[ -z "$(find "$SYMLINK_HOME/data/redirected-state" -mindepth 1 -print -quit)" ] \
  || fail "symlinked Discord state root received state files"
pass "Discord state access rejects symlinked roots"

CHILD_SYMLINK_HOME="$TMP_ROOT/child-symlink-state-home"
mkdir -p "$CHILD_SYMLINK_HOME/state/discord-workspace" "$CHILD_SYMLINK_HOME/data/redirected-requests" "$CHILD_SYMLINK_HOME/config"
cp "$CFG" "$CHILD_SYMLINK_HOME/config/discord-workspace.json"
ln -s "$CHILD_SYMLINK_HOME/data/redirected-requests" "$CHILD_SYMLINK_HOME/state/discord-workspace/requests"
child_symlink_status=0
child_symlink_out=$(FM_HOME="$CHILD_SYMLINK_HOME" "$ROOT/bin/fm-discord-workspace.sh" link-task child-symlink-task \
  --config "$CHILD_SYMLINK_HOME/config/discord-workspace.json" --request-id "$request_id" 2>&1) || child_symlink_status=$?
[ "$child_symlink_status" -ne 0 ] || fail "task linking followed a symlinked Discord state child"
assert_contains "$child_symlink_out" "symlink component" "symlinked Discord state child is refused"
[ -z "$(find "$CHILD_SYMLINK_HOME/data/redirected-requests" -mindepth 1 -print -quit)" ] \
  || fail "symlinked Discord state child received request records"
pass "Discord state access rejects symlinked child directories"

PATH_ESCAPE_HOME="$TMP_ROOT/path-escape-state-home"
mkdir -p "$PATH_ESCAPE_HOME/state" "$PATH_ESCAPE_HOME/config"
for unsafe_profile in . ../../../config; do
  PATH_ESCAPE_RESULT="$TMP_ROOT/path-escape-$(printf '%s' "$unsafe_profile" | tr '/.' '--').json"
  python3 - "$PATH_ESCAPE_RESULT" "$unsafe_profile" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({
        "schema": "fm-discord-workspace-event.v1",
        "kind": "ignored",
        "profile": sys.argv[2],
        "channel_id": "888888888888888881",
        "message_id": "999999999999999999",
    }, stream)
PY
  path_escape_status=0
  path_escape_out=$(FM_HOME="$PATH_ESCAPE_HOME" "$ROOT/bin/fm-procevent-discord-workspace.sh" \
    autohandle discord-workspace 1 "$PATH_ESCAPE_RESULT" 2>&1) || path_escape_status=$?
  [ "$path_escape_status" -ne 0 ] || fail "Discord state accepted dot path profile: $unsafe_profile"
  assert_contains "$path_escape_out" "dot component" "Discord state rejects dot path components"
done
[ -z "$(find "$PATH_ESCAPE_HOME/config" -mindepth 1 -print -quit)" ] \
  || fail "Discord state traversal wrote outside its state root"
pass "Discord state paths reject dot components and traversal"

TEXT="$TMP_ROOT/reply.txt"
printf 'Reply text for Discord.\n' > "$TEXT"
TEXT_FIFO="$TMP_ROOT/reply-fifo.txt"
mkfifo "$TEXT_FIFO"
text_fifo_status=0
fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT_FIFO" \
  > "$TMP_ROOT/text-fifo.out" 2>&1 &
text_fifo_pid=$!
for _ in $(seq 1 100); do
  kill -0 "$text_fifo_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$text_fifo_pid" 2>/dev/null; then
  kill "$text_fifo_pid" 2>/dev/null || true
  wait "$text_fifo_pid" 2>/dev/null || true
  fail "Discord text intake blocked on a FIFO"
fi
wait "$text_fifo_pid" || text_fifo_status=$?
[ "$text_fifo_status" -ne 0 ] || fail "Discord text intake accepted a FIFO"
assert_contains "$(cat "$TMP_ROOT/text-fifo.out")" "refusing unsafe text file" "Discord text intake rejects non-regular descriptors"
TEXT_OVERSIZED="$TMP_ROOT/reply-oversized.txt"
python3 - "$TEXT_OVERSIZED" <<'PY'
import sys
with open(sys.argv[1], "wb") as stream:
    stream.write(b"x" * 4001)
PY
text_oversized_status=0
text_oversized_out=$(fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT_OVERSIZED" 2>&1) || text_oversized_status=$?
[ "$text_oversized_status" -ne 0 ] || fail "Discord text intake accepted an oversized file"
assert_contains "$text_oversized_out" "text file is too large" "Discord text intake enforces its descriptor byte bound"
pass "Discord text intake bounds one regular-file descriptor"
out=$(fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT")
assert_contains "$out" "Discord reply plan" "reply renders a dry-run plan"
assert_contains "$out" '"parse": []' "reply disables mentions"
assert_contains "$out" "no Discord post was made" "reply dry-run avoids posting"
out=$(fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT" --record-discord-message-id 123456789012345678)
assert_contains "$out" "receipt recorded" "reply receipt is recorded"
out=$(fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT" --record-discord-message-id 123456789012345678)
assert_contains "$out" "receipt exists" "reply receipt deduplicates retries"
receipt_count=$(find "$HOME1/state/discord-workspace/receipts" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$receipt_count" = 1 ] || fail "receipt retry created duplicate receipts"
pass "outbound reply receipts are idempotent"

concurrent_request_a='discord:111111111111111111:888888888888888881:999999999999999995'
concurrent_request_b='discord:111111111111111111:888888888888888881:999999999999999996'
fw link-task concurrent-task --config "$CFG" --request-id "$concurrent_request_a" >"$TMP_ROOT/link-a.out" 2>&1 &
link_a_pid=$!
fw link-task concurrent-task --config "$CFG" --request-id "$concurrent_request_b" >"$TMP_ROOT/link-b.out" 2>&1 &
link_b_pid=$!
link_a_status=0
link_b_status=0
wait "$link_a_pid" || link_a_status=$?
wait "$link_b_pid" || link_b_status=$?
[ $((link_a_status == 0 ? 1 : 0)) -ne $((link_b_status == 0 ? 1 : 0)) ] || fail "concurrent task links did not produce exactly one winner"
python3 - "$HOME1/state/discord-workspace/task-links/concurrent-task.json" "$HOME1/state/discord-workspace/pending-followups/concurrent-task.json" <<'PY'
import json, sys
link = json.load(open(sys.argv[1]))
pending = json.load(open(sys.argv[2]))
if link["request_id"] != pending["request_id"] or link["profile"] != pending["profile"]:
    raise SystemExit("task link and pending follow-up disagree")
PY
request_count=$(find "$HOME1/state/discord-workspace/requests" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$request_count" = 1 ] || fail "losing task-link conflict published an unlinked request record"
rm -f "$HOME1/state/discord-workspace/task-links/concurrent-task.json" "$HOME1/state/discord-workspace/pending-followups/concurrent-task.json"
pass "task linking serializes its complete persistent transition"

out=$(fw link-task discord-task --config "$CFG" --request-id "$thread_request_id")
assert_contains "$out" "request record written" "link-task writes the request record"
assert_contains "$out" "task link written" "link-task writes the task link"
assert_contains "$out" "pending final follow-up written" "link-task writes a pending final follow-up"
TASK_LINK="$HOME1/state/discord-workspace/task-links/discord-task.json"
TASK_LINK_BACKUP="$TMP_ROOT/discord-task-link.json"
cp "$TASK_LINK" "$TASK_LINK_BACKUP"
for link_fault in schema task request policy; do
  python3 - "$TASK_LINK_BACKUP" "$TASK_LINK" "$link_fault" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
if sys.argv[3] == "schema":
    data["schema"] = "unknown"
elif sys.argv[3] == "task":
    data["task_id"] = "another-task"
elif sys.argv[3] == "request":
    data["request_id"] = "not-a-request"
else:
    data["final_followup_required"] = "yes"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
  bad_link_status=0
  bad_link_out=$(fw followup discord-task --config "$CFG" --text-file "$TEXT" 2>&1) || bad_link_status=$?
  [ "$bad_link_status" -ne 0 ] || fail "follow-up accepted a task link with invalid $link_fault"
  assert_contains "$bad_link_out" "task link" "follow-up rejects invalid task-link $link_fault"
done
cp "$TASK_LINK_BACKUP" "$TASK_LINK"
REASSIGNED_CFG="$TMP_ROOT/reassigned-thread.json"
python3 - "$CFG" "$REASSIGNED_CFG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["profiles"]["proapplis"]["thread_ids"]["exchange"] = []
data["profiles"]["folium"]["thread_ids"]["exchange"] = ["888888888888888881"]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
reassigned_status=0
reassigned_out=$(fw followup discord-task --config "$REASSIGNED_CFG" --text-file "$TEXT" 2>&1) || reassigned_status=$?
[ "$reassigned_status" -ne 0 ] || fail "follow-up accepted a reassigned task-link profile"
assert_contains "$reassigned_out" "profile no longer matches" "follow-up preserves the stored profile binding"
pass "follow-up validates the complete persistent task link"
guard_status=0
guard_out=$(fw guard-work discord-task 2>&1) || guard_status=$?
[ "$guard_status" -ne 0 ] || fail "guard-work allowed a pending final reply"
assert_contains "$guard_out" "still owes" "guard-work names the pending final reply"
out=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT")
assert_contains "$out" "pending final follow-up: present" "dry-run final follow-up sees the pending record"
assert_contains "$out" "remains unresolved" "dry-run final follow-up does not clear the promise"
out=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT" --record-discord-message-id 123456789012345679)
assert_contains "$out" "pending final follow-up delivered" "recorded final follow-up clears the pending state"
exact_final_replay=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT" --record-discord-message-id 123456789012345679)
assert_contains "$exact_final_replay" "receipt exists" "exact final follow-up replay reuses its receipt"
assert_contains "$exact_final_replay" "already delivered" "exact final follow-up replay preserves delivered state"
fw guard-work discord-task >/dev/null || fail "guard-work refused after final delivery"
out=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT")
assert_contains "$out" "final follow-up already delivered" "dry-run final follow-up after delivery reports delivered status"
assert_contains "$out" "was already delivered" "dry-run final follow-up after delivery does not claim it is unresolved"
assert_not_contains "$out" "pending final follow-up: present" "dry-run final follow-up after delivery does not claim it is pending"
assert_not_contains "$out" "remains unresolved" "dry-run final follow-up after delivery does not claim it remains unresolved"
link_replay_out=$(fw link-task discord-task --config "$CFG" --request-id "$thread_request_id")
assert_contains "$link_replay_out" "task link exists" "link-task replay keeps the existing task link"
assert_contains "$link_replay_out" "already delivered" "link-task replay recognizes completed final delivery"
fw guard-work discord-task >/dev/null || fail "link-task replay replaced delivered final evidence"
second_final_status=0
second_final_out=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT" --record-discord-message-id 123456789012345688 2>&1) || second_final_status=$?
[ "$second_final_status" -ne 0 ] || fail "a second recorded final follow-up was accepted"
assert_contains "$second_final_out" "refusing to record a second final" "second final recording is refused explicitly"
DIFFERENT_FINAL="$TMP_ROOT/different-final.txt"
printf 'Different final payload.\n' > "$DIFFERENT_FINAL"
different_final_status=0
different_final_out=$(fw followup discord-task --config "$CFG" --final --text-file "$DIFFERENT_FINAL" --record-discord-message-id 123456789012345679 2>&1) || different_final_status=$?
[ "$different_final_status" -ne 0 ] || fail "different final payload replay was accepted"
assert_contains "$different_final_out" "refusing to record a second final" "different final payload evidence is refused"
pass "request links preserve idempotent final delivery evidence"

mkdir -p "$HOME1/state/discord-workspace/pending-followups"
for bad_task in malformed-followup wrong-task-followup unknown-followup; do
  case "$bad_task" in
    malformed-followup) printf '{}\n' > "$HOME1/state/discord-workspace/pending-followups/$bad_task.json" ;;
    wrong-task-followup) printf '{"schema":"fm-discord-workspace-pending-followup.v1","task_id":"another-task","status":"pending"}\n' > "$HOME1/state/discord-workspace/pending-followups/$bad_task.json" ;;
    unknown-followup) printf '{"schema":"fm-discord-workspace-pending-followup.v1","task_id":"unknown-followup","status":"mystery"}\n' > "$HOME1/state/discord-workspace/pending-followups/$bad_task.json" ;;
  esac
  bad_guard_status=0
  fw guard-work "$bad_task" >/dev/null 2>&1 || bad_guard_status=$?
  [ "$bad_guard_status" -ne 0 ] || fail "guard-work accepted unsafe follow-up state for $bad_task"
done
bad_retire_status=0
fw retire --config "$CFG" >/dev/null 2>&1 || bad_retire_status=$?
[ "$bad_retire_status" -ne 0 ] || fail "retirement accepted unsafe follow-up records"
rm -f "$HOME1/state/discord-workspace/pending-followups/"{malformed-followup,wrong-task-followup,unknown-followup}.json
pass "follow-up guards fail closed for malformed persistent state"

RECEIPT_A="$TMP_ROOT/receipt-a.txt"
RECEIPT_B="$TMP_ROOT/receipt-b.txt"
printf 'Concurrent receipt A.\n' > "$RECEIPT_A"
printf 'Concurrent receipt B.\n' > "$RECEIPT_B"
fw reply --config "$CFG" --request-id "$request_id" --text-file "$RECEIPT_A" --nonce shared-concurrent-nonce --record-discord-message-id 123456789012345690 >"$TMP_ROOT/receipt-a.out" 2>&1 &
receipt_a_pid=$!
fw reply --config "$CFG" --request-id "$request_id" --text-file "$RECEIPT_B" --nonce shared-concurrent-nonce --record-discord-message-id 123456789012345691 >"$TMP_ROOT/receipt-b.out" 2>&1 &
receipt_b_pid=$!
receipt_a_status=0
receipt_b_status=0
wait "$receipt_a_pid" || receipt_a_status=$?
wait "$receipt_b_pid" || receipt_b_status=$?
[ $((receipt_a_status == 0 ? 1 : 0)) -ne $((receipt_b_status == 0 ? 1 : 0)) ] || fail "concurrent conflicting receipts did not produce exactly one winner"
pass "receipt compare-and-write is serialized"

CONFLICT_REPORT="$HOME1/data/conflict-report.md"
printf '# Conflicting artifact receipt\n' > "$CONFLICT_REPORT"
conflict_plan=$(fw artifact --config "$CFG" --profile proapplis --file "$CONFLICT_REPORT" --purpose report --request-id "$request_id")
conflict_artifact_id=$(printf '%s\n' "$conflict_plan" | awk '/^artifact id: / { print $3 }')
conflict_digest=$(python3 - "$CONFLICT_REPORT" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as stream:
    print(hashlib.sha256(stream.read()).hexdigest())
PY
)
fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT" --nonce artifact-conflict-nonce --record-discord-message-id 123456789012345694 >/dev/null
artifact_conflict_status=0
artifact_conflict_out=$(fw artifact --config "$CFG" --profile proapplis --file "$CONFLICT_REPORT" --purpose report --request-id "$request_id" --nonce artifact-conflict-nonce --record-discord-message-id 123456789012345695 2>&1) || artifact_conflict_status=$?
[ "$artifact_conflict_status" -ne 0 ] || fail "artifact delivery accepted a conflicting receipt nonce"
assert_contains "$artifact_conflict_out" "different Discord outbound receipt" "artifact receipt conflict is explicit"
assert_absent "$HOME1/state/discord-workspace/artifacts/$conflict_artifact_id.json" "receipt conflict does not publish an artifact record"
assert_absent "$HOME1/state/discord-workspace/artifact-source-index/$conflict_digest.json" "receipt conflict does not publish a source index"
pass "artifact delivery preflights all persistent records"

REPORT="$HOME1/data/report.md"
printf '# Report\n\nSafe report.\n' > "$REPORT"
out=$(fw artifact --config "$CFG" --profile proapplis --file "$REPORT" --purpose report --request-id "$request_id")
assert_contains "$out" "canonical post forum" "artifact plan names the canonical artifact forum"
assert_contains "$out" "exchange summary includes a card and link only" "artifact plan avoids duplicate binaries"
assert_contains "$out" "direct attachment in the artifacts forum only" "small artifact plan uses one direct attachment"
ln -s report.md "$HOME1/data/relative-report.md"
relative_symlink_status=0
relative_symlink_out=$(cd "$HOME1/data" && fw artifact --config "$CFG" --profile proapplis --file relative-report.md --purpose report 2>&1) || relative_symlink_status=$?
[ "$relative_symlink_status" -ne 0 ] || fail "relative artifact symlink was accepted"
assert_contains "$relative_symlink_out" "unsafe artifact path" "relative artifact symlink refusal names the safety boundary"
mkdir -p "$HOME1/data/real-artifacts"
printf '# Nested report\n' > "$HOME1/data/real-artifacts/report.md"
ln -s real-artifacts "$HOME1/data/alias-artifacts"
parent_symlink_status=0
parent_symlink_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/data/alias-artifacts/report.md" --purpose report 2>&1) || parent_symlink_status=$?
[ "$parent_symlink_status" -ne 0 ] || fail "artifact beneath a symlinked parent was accepted"
assert_contains "$parent_symlink_out" "unsafe artifact path" "symlinked artifact parent refusal names the safety boundary"
out=$(fw artifact --config "$CFG" --profile proapplis --file "$REPORT" --purpose report --request-id "$request_id" --record-discord-message-id 123456789012345680)
assert_contains "$out" "artifact record written" "recorded artifact writes its artifact record"
assert_contains "$out" "receipt recorded" "recorded artifact writes a receipt"
duplicate_artifact_status=0
duplicate_artifact_out=$(fw artifact --config "$CFG" --profile proapplis --file "$REPORT" --purpose final --request-id "$request_id" --record-discord-message-id 123456789012345681 2>&1) || duplicate_artifact_status=$?
[ "$duplicate_artifact_status" -ne 0 ] || fail "duplicate canonical artifact source was accepted"
assert_contains "$duplicate_artifact_out" "already has a canonical artifact" "canonical artifact source cannot be posted twice"

CONCURRENT_REPORT="$HOME1/data/concurrent-report.md"
printf '# Concurrent report\n\nOne canonical source.\n' > "$CONCURRENT_REPORT"
fw artifact --config "$CFG" --profile proapplis --file "$CONCURRENT_REPORT" --purpose report --record-discord-message-id 123456789012345692 >"$TMP_ROOT/artifact-a.out" 2>&1 &
artifact_a_pid=$!
fw artifact --config "$CFG" --profile proapplis --file "$CONCURRENT_REPORT" --purpose final --record-discord-message-id 123456789012345693 >"$TMP_ROOT/artifact-b.out" 2>&1 &
artifact_b_pid=$!
artifact_a_status=0
artifact_b_status=0
wait "$artifact_a_pid" || artifact_a_status=$?
wait "$artifact_b_pid" || artifact_b_status=$?
[ $((artifact_a_status == 0 ? 1 : 0)) -ne $((artifact_b_status == 0 ? 1 : 0)) ] || fail "concurrent canonical artifact writes did not produce exactly one winner"
concurrent_digest=$(python3 - "$CONCURRENT_REPORT" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)
concurrent_artifact=$(python3 - "$HOME1/state/discord-workspace/artifact-source-index/$concurrent_digest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["artifact_id"])
PY
)
assert_present "$HOME1/state/discord-workspace/artifacts/$concurrent_artifact.json" "canonical index names a published artifact record"
pass "canonical artifact index and record publication are serialized"

mkdir -p "$HOME1/projects/client"
printf '# Project report\n' > "$HOME1/projects/client/report.md"
project_status=0
project_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/projects/client/report.md" --purpose report 2>&1) || project_status=$?
[ "$project_status" -ne 0 ] || fail "project path artifact was accepted"
assert_contains "$project_out" "under projects" "project artifact refusal names the path class"

ARTIFACT_FIFO="$HOME1/data/artifact.pdf"
mkfifo "$ARTIFACT_FIFO"
artifact_fifo_status=0
fw artifact --config "$CFG" --profile proapplis --file "$ARTIFACT_FIFO" --purpose document \
  > "$TMP_ROOT/artifact-fifo.out" 2>&1 &
artifact_fifo_pid=$!
for _ in $(seq 1 100); do
  kill -0 "$artifact_fifo_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$artifact_fifo_pid" 2>/dev/null; then
  kill "$artifact_fifo_pid" 2>/dev/null || true
  wait "$artifact_fifo_pid" 2>/dev/null || true
  fail "artifact validation blocked on a FIFO"
fi
wait "$artifact_fifo_pid" || artifact_fifo_status=$?
[ "$artifact_fifo_status" -ne 0 ] || fail "artifact validation accepted a FIFO"
assert_contains "$(cat "$TMP_ROOT/artifact-fifo.out")" "refusing unsafe artifact path" "artifact validation rejects non-regular descriptors"
pass "artifact validation opens only regular descriptors"

printf 'not really an image\n' > "$HOME1/data/bad.png"
mime_status=0
mime_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/data/bad.png" --purpose image 2>&1) || mime_status=$?
[ "$mime_status" -ne 0 ] || fail "MIME mismatch was accepted"
assert_contains "$mime_out" "PNG extension" "MIME mismatch refusal names the mismatch"

printf 'archive bytes\n' > "$HOME1/data/archive.zip"
archive_status=0
archive_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/data/archive.zip" --purpose document 2>&1) || archive_status=$?
[ "$archive_status" -ne 0 ] || fail "archive artifact was accepted"
assert_contains "$archive_out" "blocked" "archive refusal reports the default block"

printf 'secret bytes\n' > "$HOME1/data/api-token.txt"
secret_artifact_status=0
secret_artifact_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/data/api-token.txt" --purpose document 2>&1) || secret_artifact_status=$?
[ "$secret_artifact_status" -ne 0 ] || fail "secret-looking artifact was accepted"
assert_contains "$secret_artifact_out" "blocked" "secret-looking artifact refusal reports the default block"

BIG="$HOME1/data/big.txt"
python3 - "$BIG" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"a" * (8 * 1024 * 1024 + 1))
PY
big_status=0
big_out=$(fw artifact --config "$CFG" --profile proapplis --file "$BIG" --purpose document 2>&1) || big_status=$?
[ "$big_status" -ne 0 ] || fail "oversized direct artifact was accepted"
assert_contains "$big_out" "exceeds the direct attachment cap" "oversized artifact points to private publishing"
EARLY_BIG="$HOME1/data/early-big.txt"
python3 - "$EARLY_BIG" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as stream:
    stream.write(b"\x00")
    stream.truncate(8 * 1024 * 1024 + 1)
PY
early_big_status=0
early_big_out=$(fw artifact --config "$CFG" --profile proapplis --file "$EARLY_BIG" --purpose document 2>&1) || early_big_status=$?
[ "$early_big_status" -ne 0 ] || fail "oversized invalid text artifact was accepted"
assert_contains "$early_big_out" "exceeds the direct attachment cap" "oversized direct input is rejected before content scanning"
assert_not_contains "$early_big_out" "NUL byte" "oversized direct input was scanned before cap rejection"
BOARD="$HOME1/data/board.html"
printf '<!doctype html><html><body>Safe board.</body></html>\n' > "$BOARD"
direct_html_status=0
direct_html_out=$(fw artifact --config "$CFG" --profile proapplis --file "$BOARD" --purpose board 2>&1) || direct_html_status=$?
[ "$direct_html_status" -ne 0 ] || fail "HTML was accepted as a direct Discord attachment"
assert_contains "$direct_html_out" "unsupported artifact type" "direct HTML refusal names the unsupported type"
protected_html_out=$(fw publish-artifact --config "$CFG" --profile proapplis --file "$BOARD" --purpose board --url 'https://private.example.invalid/capability/board-abcdefghijklmnopqrstuvwxyz' --access tailnet --expires 7d --record)
assert_contains "$protected_html_out" "Private artifact link plan" "protected publication accepts validated HTML"
BAD_HTML="$HOME1/data/bad-board.html"
printf 'not an HTML document\n' > "$BAD_HTML"
bad_html_status=0
bad_html_out=$(fw publish-artifact --config "$CFG" --profile proapplis --file "$BAD_HTML" --purpose board --url 'https://private.example.invalid/capability/bad-board-abcdefghijklmnopqrstuvwxyz' --access tailnet --expires 7d 2>&1) || bad_html_status=$?
[ "$bad_html_status" -ne 0 ] || fail "mismatched HTML artifact was accepted"
assert_contains "$bad_html_out" "HTML extension does not match" "protected HTML enforces MIME matching"
bypass_status=0
bypass_out=$(fw artifact --config "$CFG" --profile proapplis --file "$BIG" --purpose document --private-url 'https://public.example.invalid/capability/abcdefghijklmnopqrstuvwxyz' 2>&1) || bypass_status=$?
[ "$bypass_status" -ne 0 ] || fail "removed private URL artifact bypass was accepted"
assert_contains "$bypass_out" "unrecognized arguments: --private-url" "artifact CLI rejects the removed private URL bypass"
protected_big_out=$(fw publish-artifact --config "$CFG" --profile proapplis --file "$BIG" --purpose document --url 'https://private.example.invalid/capability/large-abcdefghijklmnopqrstuvwxyz' --access cloudflare-access --expires 24h --record)
big_digest=$(python3 - "$BIG" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as stream:
    print(hashlib.sha256(stream.read()).hexdigest())
PY
)
protected_big_id=$(printf '%s\n' "$protected_big_out" | awk '/^artifact id: / { print $3 }')
protected_big_digest=$(python3 - "$HOME1/state/discord-workspace/artifacts/$protected_big_id.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["source"]["sha256"])
PY
)
[ "$protected_big_digest" = "$big_digest" ] || fail "protected artifact record did not hash the accepted descriptor bytes"
assert_contains "$protected_big_out" "access: cloudflare-access" "protected oversized publication records access mode"
assert_contains "$protected_big_out" "expires: 24h" "protected oversized publication records expiry"
pass "artifact planning blocks unsafe inputs and routes oversized publication through controls"

DOCUMENT="$HOME1/data/document.md"
printf '# Document\n\nSafe document.\n' > "$DOCUMENT"
DEFAULT_EXPIRY_CFG="$TMP_ROOT/default-expiry.json"
python3 - "$CFG" "$DEFAULT_EXPIRY_CFG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["artifacts"]["default_expiry"] = "1d"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
out=$(fw publish-artifact --config "$DEFAULT_EXPIRY_CFG" --profile proapplis --file "$DOCUMENT" --purpose document --url 'https://private.example.invalid/capability/abcdefghijklmnopqrstuvwxyz' --access tailnet --record)
assert_contains "$out" "expires: 1d" "protected publication uses the configured default expiry"
assert_contains "$out" "Private artifact link plan" "private artifact publishing renders a plan"
assert_contains "$out" "artifact record" "private artifact publishing records metadata when asked"
pass "larger private artifact interface records expiring link metadata"

retire_status=0
retire_out=$(fw retire --config "$CFG" 2>&1) || retire_status=$?
[ "$retire_status" -eq 0 ] || fail "retire refused after pending final was delivered: $retire_out"
assert_contains "$retire_out" "retirement dry-run" "retirement stays dry-run"
pass "safe retirement preserves state and refuses no live action"

HOME2="$TMP_ROOT/home-link-failure"
mkdir -p "$HOME2/state/discord-workspace" "$HOME2/data" "$HOME2/config"
cp "$CFG" "$HOME2/config/discord-workspace.json"
printf 'blocks task-link directory creation\n' > "$HOME2/state/discord-workspace/task-links"
link_failure_status=0
FM_HOME="$HOME2" "$ROOT/bin/fm-discord-workspace.sh" link-task guarded-partial \
  --config "$HOME2/config/discord-workspace.json" --request-id "$request_id" >/dev/null 2>&1 || link_failure_status=$?
[ "$link_failure_status" -ne 0 ] || fail "task-link publication failure unexpectedly succeeded"
assert_present "$HOME2/state/discord-workspace/pending-followups/guarded-partial.json" "task-link failure preserves its pending-final guard"
partial_guard_status=0
FM_HOME="$HOME2" "$ROOT/bin/fm-discord-workspace.sh" guard-work guarded-partial >/dev/null 2>&1 || partial_guard_status=$?
[ "$partial_guard_status" -ne 0 ] || fail "task-link partial state bypassed the final-follow-up guard"
pass "task-link publication failures remain guarded"
