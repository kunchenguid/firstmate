#!/usr/bin/env bash
# Validate, preview, apply, inspect, recover, and safely remove the reviewed
# Firstmate Azure pilot ARM deployment.
#
# This wrapper never registers providers, requests quota, changes the ambient
# Azure CLI default, installs tools, or prints private deployment parameters.
# Every Azure subscription operation carries the exact selected subscription.
# Apply and worker lifecycle mutations are permitted only from a clean commit
# reachable from origin's default branch. Apply and worker-create additionally
# require the live scope/provider/SKU/quota/name/cost gates. The ordinary default
# and every command except apply, worker-create, worker-deallocate, worker-delete,
# and destroy are read-only.
#
# Required environment for cloud commands:
#   FM_AZURE_TENANT_ID FM_AZURE_SUBSCRIPTION_ID FM_AZURE_ADMIN_EMAIL
#   FM_AZURE_ADMIN_USERNAME FM_AZURE_ADMIN_SSH_PUBLIC_KEY
#   FM_AZURE_RUNNER_OPERATOR_OBJECT_ID FM_AZURE_OWNER_TAG
#   FM_AZURE_NAMING_PREFIX FM_AZURE_STORAGE_NAME FM_AZURE_KEY_VAULT_NAME
#   FM_AZURE_DEPLOYMENT_GENERATION FM_AZURE_BUDGET_START_DATE
# Optional:
#   FM_AZURE_CAPACITY_PROFILE=foundation|full|commissioning (default foundation)
#   FM_AZURE_AUTHOR_CAPACITY_MODE=mixed-current|homogeneous-dasv6
#   FM_AZURE_VM_FAMILY=Dasv6|Dasv5       (default Dasv6 supervisor)
#   FM_AZURE_WORKER_SLOTS=1,...,16       (profile/mode default)
#   FM_AZURE_WORKER_SKUS=<matching comma-separated reviewed SKUs>
#   FM_AZURE_RUNNER_VALIDATION_SKU=<reviewed 4-vCPU/16-GiB-or-better SKU>
#   FM_AZURE_PROTECT_DURABLE_STATE=0|1   (default 0; set after acceptance)
#   FM_AZURE_CLEANUP_TIMEOUT_SECONDS=60..3600 (default 900 per Azure call)
#
# Usage:
#   fm-azure-pilot.sh help
#   fm-azure-pilot.sh local-validate
#   fm-azure-pilot.sh validate
#   fm-azure-pilot.sh preview
#   fm-azure-pilot.sh apply --confirm-apply --confirm-subscription <exact-id>
#   fm-azure-pilot.sh status
#   fm-azure-pilot.sh recovery
#   fm-azure-pilot.sh worker-create --slot <1..16> --confirm-create --confirm-subscription <exact-id>
#   fm-azure-pilot.sh worker-deallocate --slot <1..16> --confirm-deallocate --confirm-subscription <exact-id>
#   fm-azure-pilot.sh worker-delete --slot <1..16> --task-state-preserved --confirm-delete --confirm-subscription <exact-id>
#   fm-azure-pilot.sh destroy --confirm-destroy --state-export-confirmed --provider-sessions-revoked --confirm-subscription <exact-id> --delete-retained-disks --confirm-delete-retained-disks
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMPLATE="$ROOT/docs/azure-pilot/main.json"
COMMAND=${1:-help}
if [ "$#" -gt 0 ]; then
  shift
fi

usage() {
  cat <<'USAGE'
Firstmate Azure pilot

Read-only:
  help             Show this help. This is the default.
  local-validate   Parse the template and enforce static safety invariants.
  validate         Run every live gate, then Azure subscription validation.
  preview          Run every live gate, then a sanitized Azure what-if summary.
  status           Show a redacted deployment/resource/power-state summary.
  recovery         Print the ordered recovery and rollback proof contract.

State-changing (never run by default):
  apply --confirm-apply --confirm-subscription <exact-id>
  worker-create --slot <1..16> --confirm-create --confirm-subscription <exact-id>
  worker-deallocate --slot <1..16> --confirm-deallocate --confirm-subscription <exact-id>
  worker-delete --slot <1..16> --task-state-preserved --confirm-delete --confirm-subscription <exact-id>
  destroy --confirm-destroy --state-export-confirmed --provider-sessions-revoked \
    --confirm-subscription <exact-id> --delete-retained-disks --confirm-delete-retained-disks

Cloud commands read private values only from the environment documented in the
script header. They never print those values. Apply and every worker mutation
require a clean tracked revision reachable from origin's default branch.
USAGE
}

refuse() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || refuse "required installed tool is unavailable: $1"
}

run_with_deadline() {
  local seconds=$1 command_pid status tick=0 timed_out=0 max_ticks
  shift
  max_ticks=$((seconds * 20))
  "$@" &
  command_pid=$!
  while kill -0 "$command_pid" 2>/dev/null; do
    if [ "$tick" -ge "$max_ticks" ]; then
      timed_out=1
      kill -TERM "$command_pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$command_pid" 2>/dev/null || true
      break
    fi
    sleep 0.05
    tick=$((tick + 1))
  done
  if wait "$command_pid"; then
    status=0
  else
    status=$?
  fi
  [ "$timed_out" -eq 0 ] || return 124
  return "$status"
}

require_cloud_environment() {
  local name
  for name in \
    FM_AZURE_TENANT_ID \
    FM_AZURE_SUBSCRIPTION_ID \
    FM_AZURE_ADMIN_EMAIL \
    FM_AZURE_ADMIN_USERNAME \
    FM_AZURE_ADMIN_SSH_PUBLIC_KEY \
    FM_AZURE_RUNNER_OPERATOR_OBJECT_ID \
    FM_AZURE_OWNER_TAG \
    FM_AZURE_NAMING_PREFIX \
    FM_AZURE_STORAGE_NAME \
    FM_AZURE_KEY_VAULT_NAME \
    FM_AZURE_DEPLOYMENT_GENERATION \
    FM_AZURE_BUDGET_START_DATE; do
    [ -n "${!name:-}" ] || refuse "$name is required and must be supplied out of band"
  done

  CAPACITY_PROFILE=${FM_AZURE_CAPACITY_PROFILE:-foundation}
  AUTHOR_CAPACITY_MODE=${FM_AZURE_AUTHOR_CAPACITY_MODE:-mixed-current}
  VM_FAMILY=${FM_AZURE_VM_FAMILY:-Dasv6}
  if [ -n "${FM_AZURE_WORKER_SLOTS:-}" ]; then
    WORKER_SLOTS=$FM_AZURE_WORKER_SLOTS
  elif [ "$CAPACITY_PROFILE" = full ]; then
    WORKER_SLOTS=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
  elif [ "$CAPACITY_PROFILE" = commissioning ]; then
    WORKER_SLOTS=1,2
  else
    WORKER_SLOTS=
  fi
  if [ -n "${FM_AZURE_WORKER_SKUS:-}" ]; then
    WORKER_SKUS=$FM_AZURE_WORKER_SKUS
  elif [ "$AUTHOR_CAPACITY_MODE" = homogeneous-dasv6 ] && [ "$CAPACITY_PROFILE" = full ]; then
    WORKER_SKUS=Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v6
  elif [ "$AUTHOR_CAPACITY_MODE" = mixed-current ] && [ "$CAPACITY_PROFILE" = full ]; then
    WORKER_SKUS=Standard_D4as_v6,Standard_D4as_v6,Standard_D4as_v7,Standard_D4as_v7,Standard_D4s_v6,Standard_D4s_v6,Standard_D4ads_v7,Standard_D4ads_v7,Standard_D4ads_v6,Standard_D4ads_v6,Standard_E4as_v7,Standard_E4as_v7,Standard_E4as_v6,Standard_E4as_v6,Standard_D4ds_v6,Standard_D4ds_v6
  elif [ "$CAPACITY_PROFILE" = commissioning ]; then
    WORKER_SKUS=Standard_D4as_v6,Standard_D4as_v6
  else
    WORKER_SKUS=
  fi
  RUNNER_VALIDATION_SKU=${FM_AZURE_RUNNER_VALIDATION_SKU:-Standard_D4as_v6}
  WORKER_HOME_BINDING=${FM_AZURE_WORKER_HOME_BINDING:-unbound}
  WORKER_TASK_BINDING=${FM_AZURE_WORKER_TASK_BINDING:-unbound}
  WORKER_INVOCATION_BINDING=${FM_AZURE_WORKER_INVOCATION_BINDING:-unbound}
  WORKER_SNAPSHOT_DIGEST=${FM_AZURE_WORKER_SNAPSHOT_DIGEST:-unbound}
  WORKER_COST_ATTRIBUTION=${FM_AZURE_WORKER_COST_ATTRIBUTION:-author}
  PROTECT_DURABLE_STATE=${FM_AZURE_PROTECT_DURABLE_STATE:-0}
  INCREMENTAL_WORKER_DEPLOY=0
  RESOURCE_GROUP=${FM_AZURE_RESOURCE_GROUP:-rg-firstmate-pilot-eastus-001}
  REGION=eastus
  REQUIRED_REGIONAL_VCPUS=128
  REQUIRED_AUTHOR_FAMILY_VCPUS=96
  IMMEDIATE_DAV6_VCPUS=10
  RESERVED_LANDING_VCPUS=62
  COMMISSIONING_BUDGET_CEILING_USD=1500
  STEADY_STATE_BUDGET_TARGET_USD=${FM_AZURE_STEADY_STATE_BUDGET_TARGET_USD:-1000}
  WORKER_HOUR_PLANNING_THRESHOLD=${FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD:-3500}
  AZURE_CLEANUP_TIMEOUT_SECONDS=${FM_AZURE_CLEANUP_TIMEOUT_SECONDS:-900}
  DEPLOYMENT_NAME="fm-azure-pilot-${FM_AZURE_DEPLOYMENT_GENERATION}"

  [[ "$FM_AZURE_TENANT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || refuse "tenant input is not a UUID"
  [[ "$FM_AZURE_SUBSCRIPTION_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || refuse "subscription input is not a UUID"
  [[ "$FM_AZURE_RUNNER_OPERATOR_OBJECT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || refuse "runner operator object input is not a UUID"
  [[ "$FM_AZURE_NAMING_PREFIX" =~ ^[a-z0-9]{3,12}$ ]] || refuse "naming prefix must be 3-12 lowercase alphanumeric characters"
  [[ "$FM_AZURE_STORAGE_NAME" =~ ^[a-z0-9]{3,24}$ ]] || refuse "storage name must be 3-24 lowercase alphanumeric characters"
  [[ "$FM_AZURE_KEY_VAULT_NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$ ]] || refuse "Key Vault name does not satisfy the reviewed syntax"
  [[ "$FM_AZURE_DEPLOYMENT_GENERATION" =~ ^[a-zA-Z0-9-]{1,32}$ ]] || refuse "deployment generation contains unsupported characters"
  [[ "$FM_AZURE_BUDGET_START_DATE" =~ ^[0-9]{4}-[0-9]{2}-01$ ]] || refuse "budget start must be the first day of a month (YYYY-MM-01)"
  case "$CAPACITY_PROFILE" in foundation|commissioning|full) ;; *) refuse "capacity profile must be foundation, commissioning, or full" ;; esac
  case "$AUTHOR_CAPACITY_MODE" in mixed-current|homogeneous-dasv6) ;; *) refuse "author capacity mode must be mixed-current or homogeneous-dasv6" ;; esac
  case "$RUNNER_VALIDATION_SKU" in
    Standard_D4as_v6|Standard_D4as_v7|Standard_D4s_v6|Standard_D4ads_v7|Standard_D4ads_v6|Standard_E4as_v7|Standard_E4as_v6|Standard_D4ds_v6) ;;
    *) refuse "runner validation SKU is not reviewed" ;;
  esac
  for binding in "$WORKER_HOME_BINDING" "$WORKER_TASK_BINDING" "$WORKER_INVOCATION_BINDING" "$WORKER_COST_ATTRIBUTION"; do
    [[ "$binding" =~ ^[a-zA-Z0-9._:-]{1,64}$ ]] || refuse "worker binding tags must use 1-64 bounded identifier characters"
  done
  [[ "$WORKER_SNAPSHOT_DIGEST" = unbound || "$WORKER_SNAPSHOT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || refuse "snapshot digest must be unbound or an exact sha256 digest"
  case "$VM_FAMILY" in Dasv6|Dasv5) ;; *) refuse "VM family must be Dasv6 or Dasv5" ;; esac
  case "$PROTECT_DURABLE_STATE" in 0|1) ;; *) refuse "FM_AZURE_PROTECT_DURABLE_STATE must be 0 or 1" ;; esac
  [[ "$STEADY_STATE_BUDGET_TARGET_USD" =~ ^[0-9]+$ ]] && [ "$STEADY_STATE_BUDGET_TARGET_USD" -ge 500 ] && [ "$STEADY_STATE_BUDGET_TARGET_USD" -le 1500 ] || refuse "steady-state budget target must be 500-1500 USD"
  [[ "$WORKER_HOUR_PLANNING_THRESHOLD" =~ ^[0-9]+$ ]] && [ "$WORKER_HOUR_PLANNING_THRESHOLD" -gt 0 ] || refuse "worker-hour planning threshold must be a positive integer"
  [[ "$AZURE_CLEANUP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && [ "$AZURE_CLEANUP_TIMEOUT_SECONDS" -ge 60 ] && [ "$AZURE_CLEANUP_TIMEOUT_SECONDS" -le 3600 ] || refuse "cleanup timeout must be 60-3600 seconds per Azure call"

  WORKER_SLOTS_JSON=$(python3 - "$WORKER_SLOTS" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    slots = [int(value) for value in raw.split(",") if value != ""]
except ValueError:
    raise SystemExit("worker slots must be comma-separated integers")
if len(slots) > 16 or len(slots) != len(set(slots)) or any(slot < 1 or slot > 16 for slot in slots):
    raise SystemExit("worker slots must be unique values from 1 through 16")
print(json.dumps(slots, separators=(",", ":")))
PY
) || refuse "worker slot input is invalid"
  WORKER_SKUS_JSON=$(python3 - "$WORKER_SKUS" <<'PY'
import json
import sys

skus = [value for value in sys.argv[1].split(",") if value]
allowed = {
    "Standard_D4as_v6", "Standard_D4as_v7", "Standard_D4s_v6",
    "Standard_D4ads_v7", "Standard_D4ads_v6", "Standard_E4as_v7",
    "Standard_E4as_v6", "Standard_D4ds_v6",
}
if any(sku not in allowed for sku in skus):
    raise SystemExit("worker plan contains an unreviewed SKU")
print(json.dumps(skus, separators=(",", ":")))
PY
) || refuse "worker SKU input is invalid"
  python3 - "$CAPACITY_PROFILE" "$AUTHOR_CAPACITY_MODE" "$WORKER_SLOTS_JSON" "$WORKER_SKUS_JSON" <<'PY' || refuse "worker slots and SKUs do not match the selected reviewed capacity contract"
import json
import sys

profile, mode = sys.argv[1:3]
slots, skus = map(json.loads, sys.argv[3:5])
expected = {
    1: "Standard_D4as_v6", 2: "Standard_D4as_v6",
    3: "Standard_D4as_v7", 4: "Standard_D4as_v7",
    5: "Standard_D4s_v6", 6: "Standard_D4s_v6",
    7: "Standard_D4ads_v7", 8: "Standard_D4ads_v7",
    9: "Standard_D4ads_v6", 10: "Standard_D4ads_v6",
    11: "Standard_E4as_v7", 12: "Standard_E4as_v7",
    13: "Standard_E4as_v6", 14: "Standard_E4as_v6",
    15: "Standard_D4ds_v6", 16: "Standard_D4ds_v6",
}
if len(slots) != len(skus):
    raise SystemExit(1)
if profile == "commissioning" and (slots != [1, 2] or skus != ["Standard_D4as_v6"] * 2):
    raise SystemExit(1)
if mode == "mixed-current" and any(expected[slot] != sku for slot, sku in zip(slots, skus)):
    raise SystemExit(1)
if mode == "homogeneous-dasv6" and any(sku != "Standard_D4as_v6" for sku in skus):
    raise SystemExit(1)
PY
  if [ "$AUTHOR_CAPACITY_MODE" = mixed-current ] && [ "$VM_FAMILY" != Dasv6 ]; then
    refuse "mixed-current mode requires the reviewed Dasv6 supervisor"
  fi

  if [ "$VM_FAMILY" = Dasv6 ]; then
    FAMILY_QUOTA_NAME=standardDav6Family
    SUPERVISOR_SKU=Standard_D2as_v6
  else
    FAMILY_QUOTA_NAME=standardDASv5Family
    SUPERVISOR_SKU=Standard_D2as_v5
  fi
}

local_validate() {
  require_tool python3
  python3 - "$TEMPLATE" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
text = path.read_text(encoding="utf-8").lower()

required_parameters = {
    "tenantId", "subscriptionId", "administratorNotificationEmail",
    "adminUsername", "adminSshPublicKey", "runnerOperatorPrincipalId", "ownerTag", "deploymentGeneration",
    "namingPrefix", "storageAccountName", "keyVaultName", "capacityProfile",
    "authorCapacityMode", "vmFamily", "workerSkus", "incrementalWorkerDeploy", "runnerValidationSku",
    "workerHomeBinding", "workerTaskBinding", "workerInvocationBinding",
    "workerSnapshotDigest", "workerCostAttribution", "requiredRegionalFreeVcpus", "requiredAuthorFamilyFreeVcpus",
    "reservedLandingVcpus", "workerSlots", "commissioningBudgetCeilingUsd",
    "steadyStateBudgetTargetUsd", "workerHourPlanningThreshold", "workerImageId",
}
missing = sorted(required_parameters - set(data.get("parameters", {})))
if missing:
    raise SystemExit("template parameters missing: " + ", ".join(missing))
if data["parameters"]["workerImageId"].get("defaultValue") != "":
    raise SystemExit("worker image must default to the Canonical marketplace base")
if data["parameters"]["capacityProfile"].get("defaultValue") != "foundation":
    raise SystemExit("foundation must be the immediate deployment profile")
if data["parameters"]["authorCapacityMode"].get("defaultValue") != "mixed-current":
    raise SystemExit("mixed-current must be the no-support capacity default")
if data["parameters"]["workerSlots"].get("defaultValue") != [] or data["parameters"]["workerSkus"].get("defaultValue") != []:
    raise SystemExit("foundation default must create zero author workers")
if data["parameters"]["vmFamily"].get("defaultValue") != "Dasv6":
    raise SystemExit("Dasv6 must be the immediate supervisor and pilot default")
if data["parameters"]["requiredRegionalFreeVcpus"].get("defaultValue") != 128:
    raise SystemExit("128-vCPU regional gate changed")
if data["parameters"]["requiredAuthorFamilyFreeVcpus"].get("defaultValue") != 96:
    raise SystemExit("96-vCPU optional homogeneous-author target changed")
if data["parameters"]["reservedLandingVcpus"].get("defaultValue") != 62:
    raise SystemExit("landing-capacity reserve changed")
if data["parameters"]["commissioningBudgetCeilingUsd"].get("defaultValue") != 1500:
    raise SystemExit("commissioning budget ceiling changed")
if data["parameters"]["steadyStateBudgetTargetUsd"].get("defaultValue") != 1000:
    raise SystemExit("steady-state budget target changed")
if data["parameters"]["workerHourPlanningThreshold"].get("defaultValue") != 3500:
    raise SystemExit("worker-hour planning threshold changed")
if data["parameters"]["runnerValidationSku"].get("defaultValue") != "Standard_D4as_v6":
    raise SystemExit("immediate runner seam must fit the live 10-vCPU Dasv6 allowance")
for forbidden in ("customdata", "publicipaddressconfiguration", "0.0.0.0/0", "allowblobpublicaccess\": true", "allowsharedkeyaccess\": true"):
    if forbidden in text:
        raise SystemExit(f"forbidden template content: {forbidden}")
print("local validation: template JSON and fixed safety inputs are valid")
PY
}

scope_gate() {
  local account
  account=$(run_bounded_az_capture gate-scope account show --subscription "$FM_AZURE_SUBSCRIPTION_ID" --output json --only-show-errors) || \
    refuse "scope gate timed out or failed; retained operation state requires reconciliation"
  jq -e \
    --arg subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --arg tenant "$FM_AZURE_TENANT_ID" \
    '.id == $subscription and .tenantId == $tenant and .state == "Enabled"' \
    >/dev/null <<<"$account" || refuse "selected tenant/subscription is not the reviewed enabled scope"
}

provider_gate() {
  local namespace state
  local namespaces=(
    Microsoft.Authorization
    Microsoft.Compute
    Microsoft.Consumption
    Microsoft.KeyVault
    Microsoft.ManagedIdentity
    Microsoft.Network
    Microsoft.OperationalInsights
    Microsoft.Quota
    Microsoft.Storage
    microsoft.insights
  )
  for namespace in "${namespaces[@]}"; do
    state=$(run_bounded_az_capture "gate-provider-${namespace//./-}" provider show --subscription "$FM_AZURE_SUBSCRIPTION_ID" --namespace "$namespace" --query registrationState --output tsv --only-show-errors) || \
      refuse "provider gate timed out or failed; retained operation state requires reconciliation"
    [ "$state" = Registered ] || refuse "provider is not Registered: $namespace ($state)"
  done
}

sku_gate() {
  local skus selected
  skus=$(run_bounded_az_capture gate-sku vm list-skus \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --location "$REGION" \
    --resource-type virtualMachines \
    --all \
    --output json \
    --only-show-errors) || refuse "SKU gate timed out or failed; retained operation state requires reconciliation"
  selected=$(jq -cn --arg supervisor "$SUPERVISOR_SKU" --arg runner "$RUNNER_VALIDATION_SKU" --argjson workers "$WORKER_SKUS_JSON" '$workers + (if $runner == $supervisor or ($workers | index($runner)) != null then [] else [$runner] end) + [$supervisor] | unique')
  jq -e \
    --arg supervisor "$SUPERVISOR_SKU" \
    --arg runner "$RUNNER_VALIDATION_SKU" \
    --argjson selected "$selected" \
    --argjson workers "$WORKER_SKUS_JSON" '
      def cap($name): ([.capabilities[]? | select(.name == $name) | .value] | first // "");
      [.[] | select(.name as $name | $selected | index($name)) |
        {name, restrictions, zones:(.locationInfo[0].zones // []),
         vcpu:(cap("vCPUsAvailable") | tonumber), memory:(cap("MemoryGB") | tonumber),
         arch:cap("CpuArchitectureType"), generations:cap("HyperVGenerations"),
         trustedLaunchDisabled:cap("TrustedLaunchDisabled"),
         premiumIO:cap("PremiumIO"), encryptionAtHost:cap("EncryptionAtHostSupported")}]
      | . as $available
      | length == ($selected | length)
        and all(.[]; (.restrictions | length) == 0 and .arch == "x64"
          and (.generations | contains("V2")) and .trustedLaunchDisabled != "True"
          and .premiumIO == "True" and .encryptionAtHost == "True" and (.zones | length) == 3)
        and any(.[]; .name == $supervisor and .vcpu == 2 and .memory >= 8)
        and any(.[]; .name == $runner and .vcpu == 4 and .memory >= 16)
        and all($workers[]; . as $worker | any($available[]; .name == $worker and .vcpu == 4 and .memory >= 16))' \
    >/dev/null <<<"$skus" || refuse "selected resource class fails SKU, shape, zone, Trusted Launch, disk, or encryption-at-host gates"
}

quota_gate() {
  local usage regional_free regional_limit worker_count declared_author_vcpus required_regional_free quota_contract requirements worker_family family required family_limit family_free replay_vcpus
  replay_vcpus=0
  if [ "$COMMAND" = worker-create ]; then
    replay_vcpus=$(worker_create_replay_vcpus)
  fi
  usage=$(run_bounded_az_capture gate-quota vm list-usage --subscription "$FM_AZURE_SUBSCRIPTION_ID" --location "$REGION" --output json --only-show-errors) || \
    refuse "quota gate timed out or failed; retained operation state requires reconciliation"
  regional_limit=$(jq -r '[.[] | select(.name.value == "cores")][0].limit // 0 | tonumber' <<<"$usage")
  regional_free=$(jq -r '[.[] | select(.name.value == "cores")][0] | (((.limit // 0) | tonumber) - ((.currentValue // 0) | tonumber))' <<<"$usage")
  worker_count=$(jq 'length' <<<"$WORKER_SLOTS_JSON")
  declared_author_vcpus=$((2 + 4 * worker_count))
  required_regional_free=$((RESERVED_LANDING_VCPUS + declared_author_vcpus))
  quota_contract=$(python3 - "$CAPACITY_PROFILE" "$FAMILY_QUOTA_NAME" "$WORKER_SKUS_JSON" <<'PY'
import collections
import json
import sys

profile = sys.argv[1]
supervisor_family = sys.argv[2]
skus = json.loads(sys.argv[3])
families = {
    "Standard_D4as_v6": "standardDav6Family",
    "Standard_D4as_v7": "StandardDasv7Family",
    "Standard_D4s_v6": "StandardDsv6Family",
    "Standard_D4ads_v7": "StandardDadsv7Family",
    "Standard_D4ads_v6": "standardDadv6Family",
    "Standard_E4as_v7": "StandardEasv7Family",
    "Standard_E4as_v6": "standardEav6Family",
    "Standard_D4ds_v6": "StandardDdsv6Family",
}
required = collections.Counter()
if profile != "foundation":
    required[supervisor_family] = 2
for sku in skus:
    required[families[sku]] += 4
print(json.dumps({
    "requirements": required,
    "worker_family": families[skus[0]] if len(skus) == 1 else "",
}, separators=(",", ":")))
PY
)
  requirements=$(jq -c '.requirements' <<<"$quota_contract")
  worker_family=$(jq -r '.worker_family' <<<"$quota_contract")
  while IFS= read -r family; do
    [ -n "$family" ] || continue
    required=$(jq -r --arg family "$family" '.[$family]' <<<"$requirements")
    if [ "$family" = "$worker_family" ]; then
      required=$((required - replay_vcpus))
    fi
    [ "$required" -ge 0 ] || refuse "worker-create replay capacity delta is invalid"
    family_limit=$(jq -r --arg family "$family" '[.[] | select((.name.value | ascii_downcase) == ($family | ascii_downcase))][0].limit // 0 | tonumber' <<<"$usage")
    family_free=$(jq -r --arg family "$family" '[.[] | select((.name.value | ascii_downcase) == ($family | ascii_downcase))][0] | (((.limit // 0) | tonumber) - ((.currentValue // 0) | tonumber))' <<<"$usage")
    [ "$family_free" -ge "$required" ] || refuse "selected capacity pool lacks its required free family vCPUs"
    if [ "$CAPACITY_PROFILE" = full ] && [ "$AUTHOR_CAPACITY_MODE" = homogeneous-dasv6 ] && [ "$family" = standardDav6Family ]; then
      [ "$family_limit" -ge "$REQUIRED_AUTHOR_FAMILY_VCPUS" ] || refuse "homogeneous full profile requires a 96-vCPU Dasv6 family limit"
    fi
  done < <(jq -r 'keys[]' <<<"$requirements")
  if [ "$COMMAND" = worker-create ]; then
    [ "$worker_count" -eq 1 ] || refuse "worker-create must validate exactly one requested author worker"
  elif [ "$CAPACITY_PROFILE" = foundation ]; then
    [ "$worker_count" -eq 0 ] || refuse "foundation profile must create zero author workers"
  elif [ "$CAPACITY_PROFILE" = commissioning ]; then
    [ "$declared_author_vcpus" -eq "$IMMEDIATE_DAV6_VCPUS" ] || refuse "commissioning profile must declare exactly the live 10-vCPU Dav6 allowance"
    [ "$regional_free" -ge "$IMMEDIATE_DAV6_VCPUS" ] || refuse "commissioning requires at least 10 free East US Total Regional vCPUs"
  else
    [ "$worker_count" -eq 16 ] || refuse "full first-production profile requires all 16 reviewed author slots"
    [ "$regional_limit" -ge "$REQUIRED_REGIONAL_VCPUS" ] && [ "$regional_free" -ge "$required_regional_free" ] || \
      refuse "full profile requires East US Total Regional quota of at least 128 with 66 author and 62 landing vCPUs free"
  fi
}

worker_create_replay_vcpus() {
  local vms matches count expected_id selected_sku
  vms=$(run_bounded_az_capture gate-quota-worker-replay vm list \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --output json \
    --only-show-errors) || \
    refuse "worker-create replay inventory is unreadable; retained operation state requires reconciliation"
  matches=$(jq -c --arg name "$WORKER_NAME" '[.[] | select(.name == $name)]' <<<"$vms") || \
    refuse "worker-create replay inventory is malformed"
  count=$(jq 'length' <<<"$matches")
  [ "$count" -le 1 ] || refuse "worker-create replay inventory contains duplicate slot VMs"
  if [ "$count" -eq 0 ]; then
    printf '0\n'
    return 0
  fi
  selected_sku=$(jq -r '.[0]' <<<"$WORKER_SKUS_JSON")
  expected_id="/subscriptions/$FM_AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachines/$WORKER_NAME"
  jq -e \
    --arg id "$expected_id" \
    --arg sku "$selected_sku" \
    --arg region "$REGION" \
    --arg deployment "$FM_AZURE_DEPLOYMENT_GENERATION" \
    --arg owner "$FM_AZURE_OWNER_TAG" \
    --arg slot "$SLOT" \
    --arg home "$WORKER_HOME_BINDING" \
    --arg task "$WORKER_TASK_BINDING" \
    --arg invocation "$WORKER_INVOCATION_BINDING" \
    --arg snapshot "$WORKER_SNAPSHOT_DIGEST" \
    --arg cost "$WORKER_COST_ATTRIBUTION" \
    'length == 1
      and (.[0].id | ascii_downcase) == ($id | ascii_downcase)
      and (.[0].location | ascii_downcase) == ($region | ascii_downcase)
      and .[0].hardwareProfile.vmSize == $sku
      and .[0].tags.workload == "firstmate"
      and .[0].tags["firstmate-role"] == "worker"
      and .[0].tags["deployment-generation"] == $deployment
      and .[0].tags["cleanup-owner"] == $owner
      and .[0].tags["worker-slot"] == $slot
      and .[0].tags["home-binding"] == $home
      and .[0].tags["task-binding"] == $task
      and .[0].tags["invocation-binding"] == $invocation
      and .[0].tags["snapshot-digest"] == $snapshot
      and .[0].tags["selected-sku"] == $sku
      and .[0].tags["cost-attribution"] == $cost' \
    >/dev/null <<<"$matches" || \
    refuse "existing worker-create replay VM differs from the exact pilot binding"
  printf '4\n'
}

name_gate() {
  local storage vault storage_available vault_available owned
  storage=$(run_bounded_az_capture gate-name-storage-check storage account check-name \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --name "$FM_AZURE_STORAGE_NAME" \
    --output json \
    --only-show-errors) || refuse "storage-name gate timed out or failed; retained operation state requires reconciliation"
  storage_available=$(jq -r '.nameAvailable // .name_available // false' <<<"$storage")
  if [ "$storage_available" != true ]; then
    owned=$(run_bounded_az_capture gate-name-storage-owner storage account show \
      --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
      --resource-group "$RESOURCE_GROUP" \
      --name "$FM_AZURE_STORAGE_NAME" \
      --query 'resourceGroup' \
      --output tsv \
      --only-show-errors 2>/dev/null || true)
    [ "$owned" = "$RESOURCE_GROUP" ] || refuse "storage name is unavailable and is not the reviewed deployment's existing account"
  fi

  vault=$(run_bounded_az_capture gate-name-vault-check rest \
    --method post \
    --url "https://management.azure.com/subscriptions/$FM_AZURE_SUBSCRIPTION_ID/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01" \
    --body "{\"name\":\"$FM_AZURE_KEY_VAULT_NAME\",\"type\":\"Microsoft.KeyVault/vaults\"}" \
    --output json \
    --only-show-errors) || refuse "Key Vault name gate timed out or failed; retained operation state requires reconciliation"
  vault_available=$(jq -r '.nameAvailable // false' <<<"$vault")
  if [ "$vault_available" != true ]; then
    owned=$(run_bounded_az_capture gate-name-vault-owner keyvault show \
      --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
      --resource-group "$RESOURCE_GROUP" \
      --name "$FM_AZURE_KEY_VAULT_NAME" \
      --query 'resourceGroup' \
      --output tsv \
      --only-show-errors 2>/dev/null || true)
    [ "$owned" = "$RESOURCE_GROUP" ] || refuse "Key Vault name is unavailable and is not the reviewed deployment's existing vault"
  fi
}

retail_price() {
  python3 - "$1" <<'PY'
import json
import sys
import urllib.parse
import urllib.request

sku = sys.argv[1]
query = urllib.parse.urlencode({
    "$filter": f"armRegionName eq 'eastus' and armSkuName eq '{sku}' and priceType eq 'Consumption'"
})
with urllib.request.urlopen("https://prices.azure.com/api/retail/prices?" + query, timeout=20) as response:
    data = json.load(response)
prices = [
    float(item["retailPrice"])
    for item in data.get("Items", [])
    if item.get("type") == "Consumption"
    and item.get("unitOfMeasure") == "1 Hour"
    and "windows" not in item.get("productName", "").lower()
    and "spot" not in item.get("meterName", "").lower()
    and "low priority" not in item.get("skuName", "").lower()
]
if not prices:
    raise SystemExit("retail rate unavailable")
print(min(prices))
PY
}

cost_gate() {
  local supervisor_rate sku rate rates result
  supervisor_rate=$(retail_price "$SUPERVISOR_SKU") || refuse "supervisor retail rate is unreadable"
  rates='{}'
  while IFS= read -r sku; do
    [ -n "$sku" ] || continue
    rate=$(retail_price "$sku") || refuse "a selected worker retail rate is unreadable"
    rates=$(jq -c --arg sku "$sku" --argjson rate "$rate" '. + {($sku):$rate}' <<<"$rates")
  done < <(jq -r 'unique[]' <<<"$WORKER_SKUS_JSON")
  result=$(python3 - "$CAPACITY_PROFILE" "$supervisor_rate" "$rates" "$WORKER_SKUS_JSON" "$COMMISSIONING_BUDGET_CEILING_USD" "$WORKER_HOUR_PLANNING_THRESHOLD" <<'PY'
import json
import sys

profile = sys.argv[1]
supervisor = 0.0 if profile == "foundation" else float(sys.argv[2])
rates = json.loads(sys.argv[3])
workers = json.loads(sys.argv[4])
budget = float(sys.argv[5])
worker_hours = float(sys.argv[6])
average_worker = sum(rates[sku] for sku in workers) / len(workers) if workers else 0.0
# NAT + outbound IP uses the reviewed $0.05/hour fixed rate. The $210 reserve
# is intentionally conservative for disks, logs, storage operations, and drift.
planning = supervisor * 730 + average_worker * worker_hours + 0.05 * 730 + 210
continuous = (supervisor + sum(rates[sku] for sku in workers)) * 730 + 0.05 * 730
print(json.dumps({"planning": round(planning, 2), "continuous": round(continuous, 2), "ok": planning <= budget}))
PY
)
  jq -e '.ok == true' >/dev/null <<<"$result" || refuse "current retail rates exceed the reviewed 1500 USD commissioning ceiling"
  printf 'cost gate: profile=%s mode=%s planning projection $%s (1000 USD target, 1500 USD commissioning ceiling); declared workers continuous compute/NAT $%s (not admitted)\n' \
    "$CAPACITY_PROFILE" "$AUTHOR_CAPACITY_MODE" "$(jq -r '.planning' <<<"$result")" "$(jq -r '.continuous' <<<"$result")"
}

live_gates() {
  require_tool az
  require_tool jq
  require_tool python3
  local_validate
  scope_gate
  provider_gate
  sku_gate
  quota_gate
  name_gate
  cost_gate
  printf 'live gates: profile=%s; exact scope, providers, region, SKU, quota, names, and cost are green\n' "$CAPACITY_PROFILE"
}

make_parameters_file() {
  PARAMS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-azure-pilot-params.XXXXXX")
  chmod 600 "$PARAMS_FILE"
  export WORKER_SLOTS_JSON WORKER_SKUS_JSON INCREMENTAL_WORKER_DEPLOY
  python3 - "$PARAMS_FILE" <<'PY'
import json
import os
import sys

values = {
    "tenantId": os.environ["FM_AZURE_TENANT_ID"],
    "subscriptionId": os.environ["FM_AZURE_SUBSCRIPTION_ID"],
    "administratorNotificationEmail": os.environ["FM_AZURE_ADMIN_EMAIL"],
    "adminUsername": os.environ["FM_AZURE_ADMIN_USERNAME"],
    "adminSshPublicKey": os.environ["FM_AZURE_ADMIN_SSH_PUBLIC_KEY"],
    "runnerOperatorPrincipalId": os.environ["FM_AZURE_RUNNER_OPERATOR_OBJECT_ID"],
    "ownerTag": os.environ["FM_AZURE_OWNER_TAG"],
    "deploymentGeneration": os.environ["FM_AZURE_DEPLOYMENT_GENERATION"],
    "capacityProfile": os.environ.get("FM_AZURE_CAPACITY_PROFILE", "foundation"),
    "authorCapacityMode": os.environ.get("FM_AZURE_AUTHOR_CAPACITY_MODE", "mixed-current"),
    "namingPrefix": os.environ["FM_AZURE_NAMING_PREFIX"],
    "resourceGroupName": os.environ.get("FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001"),
    "storageAccountName": os.environ["FM_AZURE_STORAGE_NAME"],
    "keyVaultName": os.environ["FM_AZURE_KEY_VAULT_NAME"],
    "region": "eastus",
    "vmFamily": os.environ.get("FM_AZURE_VM_FAMILY", "Dasv6"),
    "requiredRegionalFreeVcpus": 128,
    "requiredAuthorFamilyFreeVcpus": 96,
    "reservedLandingVcpus": 62,
    "workerSlots": json.loads(os.environ["WORKER_SLOTS_JSON"]),
    "workerSkus": json.loads(os.environ["WORKER_SKUS_JSON"]),
    "incrementalWorkerDeploy": os.environ.get("INCREMENTAL_WORKER_DEPLOY", "0") == "1",
    "commissioningBudgetCeilingUsd": 1500,
    "steadyStateBudgetTargetUsd": int(os.environ.get("FM_AZURE_STEADY_STATE_BUDGET_TARGET_USD", "1000")),
    "workerHourPlanningThreshold": int(os.environ.get("FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD", "3500")),
    "reservedLandingWorkerHours": 400,
    "budgetStartDate": os.environ["FM_AZURE_BUDGET_START_DATE"],
    "runnerValidationSku": os.environ.get("FM_AZURE_RUNNER_VALIDATION_SKU", "Standard_D4as_v6"),
    "operatorDataPlaneIp": os.environ.get("FM_AZURE_OPERATOR_DATA_PLANE_IP", ""),
    "workerHomeBinding": os.environ.get("FM_AZURE_WORKER_HOME_BINDING", "unbound"),
    "workerTaskBinding": os.environ.get("FM_AZURE_WORKER_TASK_BINDING", "unbound"),
    "workerInvocationBinding": os.environ.get("FM_AZURE_WORKER_INVOCATION_BINDING", "unbound"),
    "workerSnapshotDigest": os.environ.get("FM_AZURE_WORKER_SNAPSHOT_DIGEST", "unbound"),
    "workerCostAttribution": os.environ.get("FM_AZURE_WORKER_COST_ATTRIBUTION", "author"),
    "workerImageId": os.environ.get("FM_AZURE_WORKER_IMAGE_ID", ""),
    "protectDurableState": os.environ.get("FM_AZURE_PROTECT_DURABLE_STATE", "0") == "1",
    "herdrRelease": "",
    "herdrArtifactUri": "",
    "herdrArtifactSha256": "",
}
json.dump({"$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#", "contentVersion": "1.0.0.0", "parameters": {key: {"value": value} for key, value in values.items()}}, open(sys.argv[1], "w", encoding="utf-8"), separators=(",", ":"))
PY
}

cleanup_parameters() {
  if [ -n "${PARAMS_FILE:-}" ]; then
    rm -f "$PARAMS_FILE"
  fi
}

require_exact_confirmation() {
  local expected_flag=$1
  shift
  CONFIRM_SUBSCRIPTION=
  EXPLICIT_CONFIRM=0
  SLOT=
  TASK_STATE_PRESERVED=0
  STATE_EXPORT_CONFIRMED=0
  PROVIDER_SESSIONS_REVOKED=0
  DELETE_RETAINED_DISKS=0
  CONFIRM_DELETE_RETAINED_DISKS=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --confirm-subscription)
        [ "$#" -ge 2 ] || refuse "--confirm-subscription needs the exact selected value"
        CONFIRM_SUBSCRIPTION=$2
        shift 2
        ;;
      "$expected_flag") EXPLICIT_CONFIRM=1; shift ;;
      --slot)
        [ "$#" -ge 2 ] || refuse "--slot needs a value"
        SLOT=$2
        shift 2
        ;;
      --task-state-preserved) TASK_STATE_PRESERVED=1; shift ;;
      --state-export-confirmed) STATE_EXPORT_CONFIRMED=1; shift ;;
      --provider-sessions-revoked) PROVIDER_SESSIONS_REVOKED=1; shift ;;
      --delete-retained-disks) DELETE_RETAINED_DISKS=1; shift ;;
      --confirm-delete-retained-disks) CONFIRM_DELETE_RETAINED_DISKS=1; shift ;;
      *) refuse "unrecognized state-changing option: $1" ;;
    esac
  done
  [ "$EXPLICIT_CONFIRM" -eq 1 ] || refuse "$expected_flag is required"
  [ -n "$CONFIRM_SUBSCRIPTION" ] || refuse "--confirm-subscription is required"
  [ "$CONFIRM_SUBSCRIPTION" = "$FM_AZURE_SUBSCRIPTION_ID" ] || refuse "subscription confirmation does not exactly match the selected subscription"
}

require_landed_code() {
  local default_ref head
  [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no -- "$TEMPLATE" "$SCRIPT_DIR/fm-azure-pilot.sh" "$ROOT/docs/azure-pilot" 2>/dev/null)" ] || \
    refuse "apply requires clean tracked Azure deployment files"
  default_ref=$(git -C "$ROOT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  [ -n "$default_ref" ] || refuse "origin default branch is unavailable; refresh the reviewed checkout first"
  head=$(git -C "$ROOT" rev-parse HEAD)
  git -C "$ROOT" merge-base --is-ancestor "$head" "$default_ref" || \
    refuse "apply is allowed only from code already landed on origin's default branch"
}

record_mutation_state() {
  local operation=$1 phase=$2 note=${3:-}
  local state_dir state_file temp
  state_dir=${FM_AZURE_MUTATION_STATE_DIR:-$ROOT/state/azure-pilot}
  mkdir -p "$state_dir" 2>/dev/null || state_dir=${TMPDIR:-/tmp}
  state_file="$state_dir/${operation}.json"
  temp=$(mktemp "$state_dir/.${operation}.XXXXXX")
  chmod 600 "$temp"
  python3 - "$temp" "$operation" "$phase" "$note" "${DEPLOYMENT_NAME:-unknown}" "${RESOURCE_GROUP:-unknown}" <<'PY'
import datetime
import json
import sys
path, operation, phase, note, deployment, resource_group = sys.argv[1:]
json.dump({
    "schema": "fm.azure-pilot-mutation/v1",
    "operation": operation,
    "phase": phase,
    "note": note,
    "deployment": deployment,
    "resourceGroup": resource_group,
    "updatedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}, open(path, "w", encoding="utf-8"), separators=(",", ":"))
PY
  mv "$temp" "$state_file"
}

run_bounded_az() {
  local operation=$1
  shift
  run_bounded_az_capture "$operation" "$@"
}

run_bounded_az_capture() {
  local operation=$1 output status
  shift
  record_mutation_state "$operation" submitted "bounded Azure CLI call started"
  output=$(mktemp "${TMPDIR:-/tmp}/fm-azure-output.XXXXXX")
  chmod 600 "$output"
  if run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az "$@" >"$output"; then
    record_mutation_state "$operation" completed "bounded Azure CLI call completed"
    cat "$output"
    rm -f "$output"
    return 0
  else
    status=$?
  fi
  rm -f "$output"
  record_mutation_state "$operation" retained "Azure CLI call timed out or failed; live state must be reconciled before retry"
  return "$status"
}

run_validate() {
  require_cloud_environment
  live_gates
  make_parameters_file
  trap cleanup_parameters EXIT HUP INT TERM
  run_bounded_az validate deployment sub validate \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --location "$REGION" \
    --name "$DEPLOYMENT_NAME-validate" \
    --template-file "$TEMPLATE" \
    --parameters "@$PARAMS_FILE" \
    --output none \
    --only-show-errors || refuse "Azure validation timed out or failed; retained operation state requires reconciliation"
  printf 'Azure validation: passed without applying resources\n'
}

run_preview() {
  local preview_file
  require_cloud_environment
  live_gates
  make_parameters_file
  preview_file=$(mktemp "${TMPDIR:-/tmp}/fm-azure-pilot-preview.XXXXXX")
  chmod 600 "$preview_file"
  trap 'rm -f "${preview_file:-}"; cleanup_parameters' EXIT HUP INT TERM
  run_bounded_az preview deployment sub what-if \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --location "$REGION" \
    --name "$DEPLOYMENT_NAME-preview" \
    --template-file "$TEMPLATE" \
    --parameters "@$PARAMS_FILE" \
    --result-format FullResourcePayloads \
    --no-pretty-print \
    --output json \
    --only-show-errors >"$preview_file" || refuse "Azure preview timed out or failed; retained operation state requires reconciliation"
  python3 - "$preview_file" <<'PY'
import collections
import json
import sys

changes = json.load(open(sys.argv[1], encoding="utf-8")).get("changes", [])
summary = collections.Counter(change.get("changeType", "Unknown") for change in changes)
print("Azure what-if (private values and resource identifiers suppressed):")
for change_type in sorted(summary):
    print(f"  {change_type}: {summary[change_type]}")
print(f"  total: {len(changes)}")
PY
  printf 'Preview is evidence only. It grants no apply permission.\n'
}

run_apply() {
  require_tool az
  require_tool jq
  require_tool python3
  require_cloud_environment
  require_exact_confirmation --confirm-apply "$@"
  require_landed_code
  live_gates
  make_parameters_file
  trap cleanup_parameters EXIT HUP INT TERM
  run_bounded_az apply deployment sub create \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --location "$REGION" \
    --name "$DEPLOYMENT_NAME" \
    --template-file "$TEMPLATE" \
    --parameters "@$PARAMS_FILE" \
    --output none \
    --only-show-errors || refuse "Azure apply timed out or failed; retained operation state requires live reconciliation before retry"
  printf 'apply completed for profile=%s; cloud default remains blocked until every bounded acceptance leg passes\n' "$CAPACITY_PROFILE"
}

run_status() {
  local exists deployment_state vm_summary budget_count
  require_tool az
  require_tool jq
  require_cloud_environment
  scope_gate
  exists=$(az group exists --subscription "$FM_AZURE_SUBSCRIPTION_ID" --name "$RESOURCE_GROUP" --output tsv --only-show-errors)
  if [ "$exists" != true ]; then
    printf 'status: deployment resource group absent\n'
    return 0
  fi
  deployment_state=$(az deployment sub show \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --name "$DEPLOYMENT_NAME" \
    --query properties.provisioningState \
    --output tsv \
    --only-show-errors 2>/dev/null || printf 'unknown')
  vm_summary=$(az vm list \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --show-details \
    --output json \
    --only-show-errors | jq -c 'group_by(.powerState // "unknown") | map({state:(.[0].powerState // "unknown"),count:length})')
  budget_count=$(az consumption budget list --subscription "$FM_AZURE_SUBSCRIPTION_ID" --query 'length(@)' --output tsv --only-show-errors)
  printf 'status: deployment=%s; VM power-state counts=%s; subscription budgets=%s\n' "$deployment_state" "$vm_summary" "$budget_count"
}

run_recovery() {
  cat <<'RECOVERY'
Recovery proof (read-only instructions):
1. Keep local work as default until exact scope, private access, alerts, and state evidence are re-proved.
2. Rebuild disposable supervisor/worker OS capacity from the landed template; never image or snapshot provider-account disks.
3. Reattach retained LUKS2 task and provider-account disks only after disk/VM/task-generation identity proof.
4. Restore allowlisted durable state through the storage private endpoint and prove its newest point is at most 15 minutes old.
5. Re-enroll the private overlay out of band; no enrollment key belongs in ARM parameters, VM custom data, logs, or state storage.
6. Prove supervisor restart, one clean worker, Herdr end to end, a representative scout, and safe teardown inside two hours.
7. Keep the Mac reachable for 30 days and use it immediately if any acceptance leg fails.
RECOVERY
}

validate_slot() {
  [[ "${SLOT:-}" =~ ^([1-9]|1[0-6])$ ]] || refuse "--slot must be an integer from 1 through 16"
  WORKER_NAME=$(printf 'vm-%s-wkr-%02d' "$FM_AZURE_NAMING_PREFIX" "$SLOT")
}

sku_for_slot() {
  if [ "$AUTHOR_CAPACITY_MODE" = homogeneous-dasv6 ] || [ "$CAPACITY_PROFILE" = commissioning ]; then
    printf 'Standard_D4as_v6\n'
    return 0
  fi
  case "$1" in
    1|2) printf 'Standard_D4as_v6\n' ;;
    3|4) printf 'Standard_D4as_v7\n' ;;
    5|6) printf 'Standard_D4s_v6\n' ;;
    7|8) printf 'Standard_D4ads_v7\n' ;;
    9|10) printf 'Standard_D4ads_v6\n' ;;
    11|12) printf 'Standard_E4as_v7\n' ;;
    13|14) printf 'Standard_E4as_v6\n' ;;
    15|16) printf 'Standard_D4ds_v6\n' ;;
    *) return 1 ;;
  esac
}

run_worker_create() {
  require_tool az
  require_tool jq
  require_tool python3
  require_cloud_environment
  require_exact_confirmation --confirm-create "$@"
  validate_slot
  if [ "$SLOT" -gt 2 ] && [ "$CAPACITY_PROFILE" != full ]; then
    refuse "worker slots above 2 require the explicitly selected full capacity profile"
  fi
  require_landed_code
  WORKER_SLOTS_JSON=$(printf '[%s]' "$SLOT")
  WORKER_SKUS_JSON=$(jq -cn --arg sku "$(sku_for_slot "$SLOT")" '[$sku]')
  INCREMENTAL_WORKER_DEPLOY=1
  live_gates
  make_parameters_file
  trap cleanup_parameters EXIT HUP INT TERM
  run_bounded_az "worker-create-$SLOT" deployment sub create \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --location "$REGION" \
    --name "$DEPLOYMENT_NAME-worker-$SLOT" \
    --template-file "$TEMPLATE" \
    --parameters "@$PARAMS_FILE" \
    --output none \
    --only-show-errors || refuse "worker create timed out or failed; retained operation state requires live reconciliation before retry"
  printf 'worker slot created or reconciled; retained disks require exact task-generation proof before adoption\n'
}

run_worker_deallocate() {
  require_tool az
  require_cloud_environment
  require_exact_confirmation --confirm-deallocate "$@"
  scope_gate
  require_landed_code
  validate_slot
  run_bounded_az "worker-deallocate-$SLOT" vm deallocate \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$WORKER_NAME" \
    --output none \
    --only-show-errors || refuse "worker deallocation timed out or failed; retained operation state requires live reconciliation before retry"
  printf 'worker slot deallocated; retained task/account disks were not deleted\n'
}

run_worker_delete() {
  require_tool az
  require_cloud_environment
  require_exact_confirmation --confirm-delete "$@"
  scope_gate
  require_landed_code
  validate_slot
  [ "$TASK_STATE_PRESERVED" -eq 1 ] || refuse "--task-state-preserved is required before disposable worker deletion"
  run_bounded_az "worker-delete-$SLOT-deallocate" vm deallocate \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$WORKER_NAME" \
    --output none \
    --only-show-errors || refuse "worker delete deallocation timed out or failed; retained operation state requires live reconciliation before retry"
  run_bounded_az "worker-delete-$SLOT-delete" vm delete \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$WORKER_NAME" \
    --yes \
    --output none \
    --only-show-errors || refuse "worker deletion timed out or failed; retained operation state requires live reconciliation before retry"
  printf 'worker compute deleted; task and provider-account disks remain retained and unsnapshotted\n'
}

run_destroy() {
  local vm disk vm_inventory disk_inventory classified_inventory vm_names retained_disks
  require_tool az
  require_cloud_environment
  require_exact_confirmation --confirm-destroy "$@"
  scope_gate
  [ "$STATE_EXPORT_CONFIRMED" -eq 1 ] || refuse "--state-export-confirmed is required"
  [ "$PROVIDER_SESSIONS_REVOKED" -eq 1 ] || refuse "--provider-sessions-revoked is required"
  if [ "$DELETE_RETAINED_DISKS" -eq 1 ] && [ "$CONFIRM_DELETE_RETAINED_DISKS" -ne 1 ]; then
    refuse "--confirm-delete-retained-disks is required with --delete-retained-disks"
  fi
  if [ "$DELETE_RETAINED_DISKS" -ne 1 ]; then
    refuse "full destroy retains encrypted task/account disks by default; pass both retained-disk deletion flags only after their contents are no longer needed"
  fi

  vm_inventory=$(run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az vm list \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --query '[].{name:name,osDisk:storageProfile.osDisk.name}' \
    --output json \
    --only-show-errors) || refuse "VM inventory failed; destroy did not mutate resources"
  disk_inventory=$(run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az disk list \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --query '[].{name:name,purpose:tags."disk-purpose"}' \
    --output json \
    --only-show-errors) || refuse "retained-disk inventory failed; destroy did not mutate resources"

  classified_inventory=$(python3 - "$vm_inventory" "$disk_inventory" <<'PY'
import json
import sys

try:
    vms = json.loads(sys.argv[1])
    disks = json.loads(sys.argv[2])
    if not isinstance(vms, list) or not isinstance(disks, list):
        raise ValueError("inventories must be arrays")
    if len(vms) > 17 or len(disks) > 51:
        raise ValueError("resource inventory exceeds the reviewed bounded fleet")
    vm_names = []
    os_disks = set()
    for vm in vms:
        name = vm.get("name") if isinstance(vm, dict) else None
        os_disk = vm.get("osDisk") if isinstance(vm, dict) else None
        if not isinstance(name, str) or not name or not isinstance(os_disk, str) or not os_disk:
            raise ValueError("VM inventory entry is incomplete")
        vm_names.append(name)
        os_disks.add(os_disk)
    if len(vm_names) != len(set(vm_names)) or len(os_disks) != len(vms):
        raise ValueError("VM inventory contains duplicates")
    disk_names = set()
    retained = []
    for disk in disks:
        name = disk.get("name") if isinstance(disk, dict) else None
        purpose = disk.get("purpose") if isinstance(disk, dict) else None
        if not isinstance(name, str) or not name or name in disk_names:
            raise ValueError("disk inventory entry is incomplete or duplicated")
        disk_names.add(name)
        if name in os_disks:
            continue
        if purpose not in ("provider-account", "task-state"):
            raise ValueError(f"disk {name!r} is not an inventoried VM OS disk or authorized retained disk")
        retained.append(name)
    if not os_disks.issubset(disk_names):
        raise ValueError("an inventoried VM OS disk is missing from the disk inventory")
except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)

print(json.dumps({"vmNames": vm_names, "retainedDisks": retained}, separators=(",", ":")))
PY
  ) || refuse "resource inventory classification failed; destroy did not mutate resources"
  vm_names=$(jq -r '.vmNames[]?' <<<"$classified_inventory") || refuse "classified VM inventory is unreadable; destroy did not mutate resources"
  retained_disks=$(jq -r '.retainedDisks[]?' <<<"$classified_inventory") || refuse "classified retained-disk inventory is unreadable; destroy did not mutate resources"

  while IFS= read -r vm; do
    [ -n "$vm" ] || continue
    run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az vm deallocate --subscription "$FM_AZURE_SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --name "$vm" --output none --only-show-errors || refuse "VM deallocation timed out or failed; destroy stopped"
    run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az vm delete --subscription "$FM_AZURE_SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --name "$vm" --yes --output none --only-show-errors || refuse "VM deletion timed out or failed; destroy stopped"
  done <<<"$vm_names"

  run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az lock delete --subscription "$FM_AZURE_SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --resource-type Microsoft.Storage/storageAccounts --resource-name "$FM_AZURE_STORAGE_NAME" --name state-storage-lock --output none --only-show-errors 2>/dev/null || true
  run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az lock delete --subscription "$FM_AZURE_SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --resource-type Microsoft.KeyVault/vaults --resource-name "$FM_AZURE_KEY_VAULT_NAME" --name key-vault-lock --output none --only-show-errors 2>/dev/null || true

  while IFS= read -r disk; do
    [ -n "$disk" ] || continue
    run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az disk delete --subscription "$FM_AZURE_SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --name "$disk" --yes --output none --only-show-errors || refuse "retained-disk deletion timed out or failed; destroy stopped"
  done <<<"$retained_disks"

  run_with_deadline "$AZURE_CLEANUP_TIMEOUT_SECONDS" az group delete \
    --subscription "$FM_AZURE_SUBSCRIPTION_ID" \
    --name "$RESOURCE_GROUP" \
    --yes \
    --no-wait \
    --output none \
    --only-show-errors || refuse "resource-group deletion submission timed out or failed"
  printf 'destroy submitted after bounded compute quiescence, session revocation, state export, lock removal, and explicit retained-disk deletion; Key Vault purge protection remains in force\n'
}

case "$COMMAND" in
  help|-h|--help) usage ;;
  local-validate)
    [ "$#" -eq 0 ] || refuse "local-validate accepts no arguments"
    local_validate
    ;;
  validate)
    [ "$#" -eq 0 ] || refuse "validate accepts no arguments"
    run_validate
    ;;
  preview)
    [ "$#" -eq 0 ] || refuse "preview accepts no arguments"
    run_preview
    ;;
  apply) run_apply "$@" ;;
  status)
    [ "$#" -eq 0 ] || refuse "status accepts no arguments"
    run_status
    ;;
  recovery)
    [ "$#" -eq 0 ] || refuse "recovery accepts no arguments"
    run_recovery
    ;;
  worker-create) run_worker_create "$@" ;;
  worker-deallocate) run_worker_deallocate "$@" ;;
  worker-delete) run_worker_delete "$@" ;;
  destroy) run_destroy "$@" ;;
  *) refuse "unknown command: $COMMAND (run help)" ;;
esac
