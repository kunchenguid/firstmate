#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Regression coverage for the declarative Azure pilot safety and mutation gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-azure-pilot.sh"
TEMPLATE="$ROOT/docs/azure-pilot/main.json"
WORKER_PROVIDER="$ROOT/bin/fm-azure-worker-provider.py"
WORKER_LIFECYCLE="$ROOT/bin/fm-worker-lifecycle.py"
WORKER_TEMPLATE="$ROOT/docs/azure-pilot/main.json"
DOC="$ROOT/docs/azure-pilot.md"

run_static_template_checks() {
  if ! python3 - "$TEMPLATE" <<'PY'
import json
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
text = path.read_text(encoding="utf-8")
lower = text.lower()

assert data["parameters"]["capacityProfile"]["defaultValue"] == "foundation"
assert data["parameters"]["authorCapacityMode"]["defaultValue"] == "mixed-current"
assert data["parameters"]["vmFamily"]["defaultValue"] == "Dasv6"
assert data["parameters"]["workerSlots"]["defaultValue"] == []
assert data["parameters"]["workerSkus"]["defaultValue"] == []
assert data["parameters"]["incrementalWorkerDeploy"]["defaultValue"] is False
assert "incrementalWorkerDeploy" in data["variables"]["capacityMatches"]
assert "equals(length(parameters('workerSlots')), 1)" in data["variables"]["capacityMatches"]
assert data["parameters"]["requiredRegionalFreeVcpus"]["defaultValue"] == 128
assert data["parameters"]["requiredAuthorFamilyFreeVcpus"]["defaultValue"] == 96
assert "Future homogeneous" in data["parameters"]["requiredAuthorFamilyFreeVcpus"]["metadata"]["description"]
assert data["parameters"]["reservedLandingVcpus"]["defaultValue"] == 62
assert data["parameters"]["commissioningBudgetCeilingUsd"]["defaultValue"] == 1500
assert data["parameters"]["steadyStateBudgetTargetUsd"]["defaultValue"] == 1000
assert data["parameters"]["runnerValidationSku"]["defaultValue"] == "Standard_D4as_v6"

# Worker runtime image: opt-in gallery image for author workers only, inert
# by default, threaded through the nested deployment, and never applied to
# the supervisor's own image reference.
assert data["parameters"]["workerImageId"]["defaultValue"] == ""
assert data["variables"]["resourcesDeploymentName"] == "[format('firstmate-pilot-resources-{0}', uniqueString(deployment().name))]"
nested = next(
    item for item in data["resources"]
    if item["type"] == "Microsoft.Resources/deployments"
    and item["name"] == "[variables('resourcesDeploymentName')]"
)
assert nested["name"] == "[variables('resourcesDeploymentName')]"
assert data["outputs"]["blobPrivateEndpointNicId"]["value"] == "[reference(variables('resourcesDeploymentName')).outputs.blobPrivateEndpointNicId.value]"
assert data["outputs"]["blobPrivateEndpointNicResourceGuid"]["value"] == "[reference(variables('resourcesDeploymentName')).outputs.blobPrivateEndpointNicResourceGuid.value]"
inner = nested["properties"]["template"]
assert inner["parameters"]["workerImageId"]["defaultValue"] == ""
assert nested["properties"]["parameters"]["workerImageId"] == {"value": "[parameters('workerImageId')]"}
def inner_vms(resources):
    for item in resources:
        if item.get("type") == "Microsoft.Compute/virtualMachines":
            yield item
        yield from inner_vms(item.get("resources", []))
supervisor_vm = next(
    item for item in inner_vms(inner["resources"]) if "supervisorVmName" in json.dumps(item["name"])
)
worker_vm = next(
    item for item in inner_vms(inner["resources"]) if "-wkr-" in json.dumps(item["name"])
)
supervisor_ref = supervisor_vm["properties"]["storageProfile"]["imageReference"]
assert supervisor_ref["publisher"] == "Canonical", "the supervisor image must stay marketplace-pinned"
worker_ref = worker_vm["properties"]["storageProfile"]["imageReference"]
assert isinstance(worker_ref, str)
assert "if(equals(parameters('workerImageId'), '')" in worker_ref
assert "'publisher', 'Canonical'" in worker_ref
assert "createObject('id', parameters('workerImageId'))" in worker_ref
reviewed_worker_skus = {
    "Standard_D4as_v6", "Standard_D4as_v7", "Standard_D4s_v6",
    "Standard_D4ads_v7", "Standard_D4ads_v6", "Standard_E4as_v7",
    "Standard_E4as_v6", "Standard_D4ds_v6",
}
assert set(data["parameters"]["runnerValidationSku"]["allowedValues"]) == reviewed_worker_skus
assert "defaultValue" not in data["parameters"]["runnerOperatorPrincipalId"]

# No private identifiers or notification values may be committed.
assert "defaultValue" not in json.dumps(data["parameters"]["tenantId"])
assert "defaultValue" not in json.dumps(data["parameters"]["subscriptionId"])
assert "defaultValue" not in json.dumps(data["parameters"]["administratorNotificationEmail"])
assert data["parameters"]["adminSshPublicKey"]["type"] == "secureString"
assert "defaultValue" not in data["parameters"]["adminSshPublicKey"]
assert not re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", text)
assert "stfm7c799deus01" not in lower
assert "kv-fm-7c799d-eus" not in lower
assert "customdata" not in lower
assert "0.0.0.0/0" not in text
assert "spot" not in lower

nested = next(resource for resource in data["resources"] if resource["type"] == "Microsoft.Resources/deployments")
resources = nested["properties"]["template"]["resources"]

supervisor_condition = "[and(not(parameters('incrementalWorkerDeploy')), not(equals(parameters('capacityProfile'), 'foundation')))]"
supervisor_resource_names = {
    "[variables('supervisorIdentityName')]",
    "[variables('supervisorAccountDiskName')]",
    "[variables('supervisorTaskDiskName')]",
    "[variables('supervisorNicName')]",
    "[variables('supervisorVmName')]",
    "[format('{0}/AzureMonitorLinuxAgent', variables('supervisorVmName'))]",
    "[format('alert-{0}-supervisor-heartbeat', parameters('namingPrefix'))]",
    "[format('{0}/default/supervisor-state/Microsoft.Authorization/{1}', parameters('storageAccountName'), guid(resourceGroup().id, 'supervisor-state-writer'))]",
    "[format('{0}/default/artifacts/Microsoft.Authorization/{1}', parameters('storageAccountName'), guid(resourceGroup().id, 'artifact-writer'))]",
}
supervisor_resources = [
    resource for resource in resources
    if resource.get("name") in supervisor_resource_names
    or resource.get("scope") == "[format('Microsoft.Compute/virtualMachines/{0}', variables('supervisorVmName'))]"
]
assert len(supervisor_resources) == 10
for resource in supervisor_resources:
    assert resource.get("condition") == supervisor_condition, (resource["type"], resource["name"])

nics = [resource for resource in resources if resource["type"] == "Microsoft.Network/networkInterfaces"]
assert nics
for nic in nics:
    serialized = json.dumps(nic["properties"]).lower()
    assert "publicipaddress" not in serialized

nsgs = [resource for resource in resources if resource["type"] == "Microsoft.Network/networkSecurityGroups"]
assert nsgs
for nsg in nsgs:
    for rule in nsg["properties"]["securityRules"]:
        props = rule["properties"]
        if props["direction"] == "Inbound" and props["sourceAddressPrefix"] in ("Internet", "*"):
            assert props["access"] == "Deny"
        if props["direction"] == "Inbound" and props["access"] == "Allow":
            assert props["sourceAddressPrefix"] not in ("Internet", "*")
            assert props.get("destinationPortRange") != "22"

storage = next(resource for resource in resources if resource["type"] == "Microsoft.Storage/storageAccounts" and resource["name"] == "[parameters('storageAccountName')]")
props = storage["properties"]
assert props["allowBlobPublicAccess"] is False
assert props["allowSharedKeyAccess"] is False
assert props["supportsHttpsTrafficOnly"] is True
assert props["publicNetworkAccess"] == "[if(empty(parameters('operatorDataPlaneIp')), 'Disabled', 'Enabled')]"
assert "operatorDataPlaneIp" in str(props["networkAcls"].get("ipRules"))
control = next(resource for resource in resources if resource["type"] == "Microsoft.Storage/storageAccounts" and resource["name"] == "[variables('runnerControlStorageName')]")
assert control["sku"]["name"] == "Standard_LRS"
assert control["properties"]["allowBlobPublicAccess"] is False
assert control["properties"]["allowSharedKeyAccess"] is False
assert control["properties"]["publicNetworkAccess"] == "[if(empty(parameters('operatorDataPlaneIp')), 'Disabled', 'Enabled')]"
control_container = next(resource for resource in resources if resource["type"] == "Microsoft.Storage/storageAccounts/blobServices/containers" and "runner-control" in resource["name"])
assert control_container["properties"]["publicAccess"] == "None"
assert control_container["properties"]["metadata"] == {"schema": "fm-azure-runner-control-v1", "deploymentgeneration": "[parameters('deploymentGeneration')]"}
controller_role = next(resource for resource in resources if resource["type"] == "Microsoft.Storage/storageAccounts/blobServices/containers/providers/roleAssignments" and "runner-private-controller-validation-shards" in resource["name"])
assert "validation-shards" in controller_role["name"]
assert "validationShardIdentityName" in json.dumps(controller_role)

blob_endpoint = next(resource for resource in resources if resource["type"] == "Microsoft.Network/privateEndpoints")
assert blob_endpoint["properties"]["customNetworkInterfaceName"] == "[variables('blobPrivateEndpointNicName')]"
nested_outputs = nested["properties"]["template"]["outputs"]
assert "blobPrivateEndpointNicId" in nested_outputs
assert "blobPrivateEndpointNicResourceGuid" in nested_outputs
assert data["outputs"]["blobPrivateEndpointNicId"]["value"].endswith(".value]")
assert data["outputs"]["blobPrivateEndpointNicResourceGuid"]["value"].endswith(".value]")

# Private DNS zones have a stricter Azure limit than the ordinary 50-tag
# resource ceiling. Keep their exact ownership/generation identity within it.
private_dns_tags = nested["properties"]["template"]["variables"]["privateDnsZoneTags"]
required_private_dns_tags = {
    "workload", "environment", "managed-by", "region", "cleanup-owner",
    "deployment-generation", "capacity-profile", "author-capacity-mode",
    "data-classification", "activation-policy", "steady-state-cost-target",
    "commissioning-cost-ceiling",
}
assert len(private_dns_tags) <= 15
assert required_private_dns_tags <= set(private_dns_tags)
private_dns_zones = [resource for resource in resources if resource["type"] == "Microsoft.Network/privateDnsZones"]
assert len(private_dns_zones) == 2
assert all(resource["tags"] == "[variables('privateDnsZoneTags')]" for resource in private_dns_zones)

vms = [resource for resource in resources if resource["type"] == "Microsoft.Compute/virtualMachines"]
assert len(vms) == 2  # supervisor plus one copied worker declaration
for vm in vms:
    security = vm["properties"]["securityProfile"]
    assert security["securityType"] == "TrustedLaunch"
    assert security["uefiSettings"]["secureBootEnabled"] is True
    assert security["uefiSettings"]["vTpmEnabled"] is True
    assert security["encryptionAtHost"] is True
    os_profile = vm["properties"].get("osProfile", {})
    assert "customData" not in os_profile
    linux = os_profile["linuxConfiguration"]
    assert linux["disablePasswordAuthentication"] is True
    public_keys = linux["ssh"]["publicKeys"]
    assert len(public_keys) == 1
    assert public_keys[0]["path"] == "[format('/home/{0}/.ssh/authorized_keys', parameters('adminUsername'))]"
    assert public_keys[0]["keyData"] == "[parameters('adminSshPublicKey')]"
    for disk in vm["properties"]["storageProfile"]["dataDisks"]:
        assert disk["deleteOption"] == "Detach"

worker_vm = next(vm for vm in vms if "workerVms" == vm.get("copy", {}).get("name"))
assert worker_vm["properties"]["hardwareProfile"]["vmSize"] == "[parameters('workerSkus')[copyIndex()]]"
worker_tags = worker_vm["tags"]
for marker in ("one-task-scoped-crewmate", "secondmate-placement", "home-binding", "task-binding", "invocation-binding", "snapshot-digest", "cost-attribution"):
    assert marker in worker_tags

# Separate landing seams exist without always-on validation/review/browser VMs.
for marker in ("snet-validation", "snet-validation-shards", "snet-policy-review", "snet-crosscheck-tools", "snet-networkless-verifier", "validation-evidence", "validation-shards", "crosscheck-evidence", "networkless-verifier"):
    assert marker in text
assert all("validation" not in vm["name"].lower() and "review" not in vm["name"].lower() and "browser" not in vm["name"].lower() for vm in vms)

vnet = next(resource for resource in resources if resource["type"] == "Microsoft.Network/virtualNetworks")
verifier_subnet = next(subnet for subnet in vnet["properties"]["subnets"] if subnet["name"] == "snet-networkless-verifier")
assert "verifierNsgName" in verifier_subnet["properties"]["networkSecurityGroup"]["id"]
assert "natGateway" not in verifier_subnet["properties"]
assert verifier_subnet["properties"]["defaultOutboundAccess"] is False
verifier_nsg = next(resource for resource in nsgs if "verifierNsgName" in resource["name"])
verifier_rules = verifier_nsg["properties"]["securityRules"]
assert any(rule["name"] == "deny-all-outbound" and rule["properties"]["direction"] == "Outbound" and rule["properties"]["access"] == "Deny" and rule["properties"]["destinationAddressPrefix"] == "*" for rule in verifier_rules)

alerts = [resource for resource in resources if resource["type"] == "Microsoft.Insights/scheduledQueryRules"]
worker_alert = next(alert for alert in alerts if "worker-heartbeat" in alert["name"])
worker_criterion = worker_alert["properties"]["criteria"]["allOf"][0]
assert "workerCount" in worker_alert["condition"]
assert worker_criterion["operator"] == "LessThan"
assert "workerCount" in worker_criterion["threshold"]
assert "ago(" not in worker_criterion["query"]
sync_alert = next(alert for alert in alerts if "sync-age" in alert["name"])
sync_criterion = sync_alert["properties"]["criteria"]["allOf"][0]
assert sync_criterion["query"] == "FMStateSync_CL"
assert sync_criterion["operator"] == "LessThan"
assert sync_criterion["threshold"] == 1

role_assignments = [resource for resource in resources if resource["type"].endswith("providers/roleAssignments")]
runner_delegator = next(resource for resource in role_assignments if "runner-user-delegation" in resource["name"])
runner_staging = next(resource for resource in role_assignments if "runner-validation-shards" in resource["name"])
assert "blobDelegatorRoleId" in runner_delegator["properties"]["roleDefinitionId"]
assert "blobDataContributorRoleId" in runner_staging["properties"]["roleDefinitionId"]
assert "validation-shards" in runner_staging["name"]
assert runner_delegator["properties"]["principalId"] == "[parameters('runnerOperatorPrincipalId')]"
assert runner_staging["properties"]["principalId"] == "[parameters('runnerOperatorPrincipalId')]"
PY
  then
    fail "Azure template static invariants failed"
  fi
  pass "Azure template preserves capacity, secret, network, storage, compute, and topology invariants"
}

run_explicit_mutation_gate_checks() {
  local tmp fakebin output status sub tenant wrong
  tmp=$(mktemp -d)
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  cat >"$fakebin/az" <<'SH'
#!/usr/bin/env bash
echo "az must not run before explicit local gates" >&2
exit 99
SH
  chmod +x "$fakebin/az"
  sub=$(python3 -c 'import uuid; print(uuid.uuid4())')
  tenant=$(python3 -c 'import uuid; print(uuid.uuid4())')
  wrong=$(python3 -c 'import uuid; print(uuid.uuid4())')

  run_gated() {
    env \
      PATH="$fakebin:$PATH" \
      FM_AZURE_TENANT_ID="$tenant" \
      FM_AZURE_SUBSCRIPTION_ID="$sub" \
      FM_AZURE_ADMIN_EMAIL=private-notification \
      FM_AZURE_ADMIN_USERNAME=privateadmin \
      FM_AZURE_ADMIN_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyPrivateOverlayKey' \
      FM_AZURE_RUNNER_OPERATOR_OBJECT_ID="$tenant" \
      FM_AZURE_OWNER_TAG=owner \
      FM_AZURE_NAMING_PREFIX=fmtest \
      FM_AZURE_STORAGE_NAME=fmteststorage0001 \
      FM_AZURE_KEY_VAULT_NAME=fm-test-vault-001 \
      FM_AZURE_DEPLOYMENT_GENERATION=test-generation \
      FM_AZURE_BUDGET_START_DATE=2026-08-01 \
      "$SCRIPT" "$@"
  }

  set +e
  output=$(run_gated apply 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "apply without explicit confirmation returned $status"
  assert_contains "$output" "--confirm-apply is required" "apply did not require its explicit flag"
  assert_not_contains "$output" "az must not run" "apply touched Azure before explicit confirmation"

  set +e
  output=$(run_gated apply --confirm-apply --confirm-subscription "$wrong" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "apply with the wrong subscription confirmation returned $status"
  assert_contains "$output" "does not exactly match" "apply did not bind the exact subscription"
  assert_not_contains "$output" "az must not run" "apply touched Azure before exact-subscription confirmation"

  set +e
  output=$(run_gated destroy --confirm-subscription "$sub" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "destroy without explicit confirmation returned $status"
  assert_contains "$output" "--confirm-destroy is required" "destroy did not require its explicit flag"
  assert_not_contains "$output" "az must not run" "destroy touched Azure before explicit confirmation"

  rm -rf "$tmp"
  pass "apply and destroy refuse before Azure without explicit flags and exact scope confirmation"
}

run_safe_cleanup_order_check() {
  python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
destroy = text.split("run_destroy() {", 1)[1].split("\n}\n\ncase ", 1)[0]
steps = [
    'az vm deallocate',
    'az vm delete',
    'az lock delete',
    'az disk delete',
    'az group delete',
]
positions = [destroy.index(step) for step in steps]
assert positions == sorted(positions), positions
assert '--state-export-confirmed' in destroy
assert '--provider-sessions-revoked' in destroy
assert '--confirm-delete-retained-disks' in destroy
PY
  pass "destroy cleanup order quiesces compute and protects retained state before group deletion"
}

write_sourceable_script() {
  python3 - "$SCRIPT" "$1" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "XXXXXX.json" not in text
marker = '\ncase "$COMMAND" in\n'
assert marker in text
Path(sys.argv[2]).write_text(text.split(marker, 1)[0] + "\n", encoding="utf-8")
PY
}

run_worker_create_plan_gate_check() {
  local sourceable output status
  sourceable=$(mktemp)
  write_sourceable_script "$sourceable"
  set +e
  # Assignments below intentionally stay inside the isolated runtime-test subshell.
  # shellcheck disable=SC2030
  output=$(
    (
      set --
      # shellcheck source=bin/fm-azure-pilot.sh
      . "$sourceable"
      export FM_AZURE_TENANT_ID FM_AZURE_SUBSCRIPTION_ID FM_AZURE_ADMIN_EMAIL
      export FM_AZURE_ADMIN_USERNAME FM_AZURE_ADMIN_SSH_PUBLIC_KEY FM_AZURE_RUNNER_OPERATOR_OBJECT_ID
      export FM_AZURE_OWNER_TAG FM_AZURE_NAMING_PREFIX
      export FM_AZURE_STORAGE_NAME FM_AZURE_KEY_VAULT_NAME FM_AZURE_DEPLOYMENT_GENERATION
      export FM_AZURE_BUDGET_START_DATE FM_AZURE_CAPACITY_PROFILE FM_AZURE_AUTHOR_CAPACITY_MODE
      FM_AZURE_TENANT_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_SUBSCRIPTION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_ADMIN_EMAIL=private-notification
      FM_AZURE_ADMIN_USERNAME=privateadmin
      FM_AZURE_ADMIN_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyPrivateOverlayKey'
      FM_AZURE_RUNNER_OPERATOR_OBJECT_ID=$FM_AZURE_TENANT_ID
      FM_AZURE_OWNER_TAG=owner
      FM_AZURE_NAMING_PREFIX=fmtest
      FM_AZURE_STORAGE_NAME=fmteststorage0001
      FM_AZURE_KEY_VAULT_NAME=fm-test-vault-001
      FM_AZURE_DEPLOYMENT_GENERATION=test-generation
      FM_AZURE_BUDGET_START_DATE=2026-08-01
      FM_AZURE_CAPACITY_PROFILE=foundation
      FM_AZURE_AUTHOR_CAPACITY_MODE=mixed-current
      require_cloud_environment
      [ "$WORKER_SLOTS_JSON" = '[]' ]
      [ "$WORKER_SKUS_JSON" = '[]' ]
      WORKER_SLOTS_JSON='[3]'
      WORKER_SKUS_JSON='["Standard_D4as_v7"]'
      INCREMENTAL_WORKER_DEPLOY=1
      require_tool() { :; }
      local_validate() { :; }
      scope_gate() { :; }
      provider_gate() { :; }
      sku_gate() {
        [ "$WORKER_SKUS_JSON" = '["Standard_D4as_v7"]' ]
      }
      quota_gate() {
        [ "$WORKER_SLOTS_JSON" = '[3]' ]
      }
      name_gate() { :; }
      cost_gate() {
        [ "$INCREMENTAL_WORKER_DEPLOY" -eq 1 ]
      }
      live_gates >/dev/null
      make_parameters_file
      python3 - "$PARAMS_FILE" <<'PY'
import json
import sys

parameters = json.load(open(sys.argv[1], encoding="utf-8"))["parameters"]
assert parameters["workerSlots"]["value"] == [3]
assert parameters["workerSkus"]["value"] == ["Standard_D4as_v7"]
assert parameters["incrementalWorkerDeploy"]["value"] is True
assert parameters["adminSshPublicKey"]["value"].startswith("ssh-ed25519 ")
PY
      cleanup_parameters
    ) 2>&1
  )
  status=$?
  set -e
  rm -f "$sourceable"
  [ "$status" -eq 0 ] || fail "worker-create singleton plan was reset or rejected: $output"
  pass "worker-create executes live gates and parameters with its exact singleton plan"
}

run_destroy_inventory_failure_checks() {
  local sourceable mode call_log calls output status
  sourceable=$(mktemp)
  write_sourceable_script "$sourceable"
  for mode in vm disk; do
    call_log=$(mktemp)
    set +e
    # Assignments below intentionally stay inside the isolated runtime-test subshell.
    # shellcheck disable=SC2030
    output=$(
      (
        set --
        # shellcheck source=bin/fm-azure-pilot.sh
        . "$sourceable"
        require_tool() { :; }
        require_cloud_environment() {
          FM_AZURE_SUBSCRIPTION_ID=private-subscription
          RESOURCE_GROUP=private-resource-group
          FM_AZURE_STORAGE_NAME=private-storage
          FM_AZURE_KEY_VAULT_NAME=private-vault
          AZURE_CLEANUP_TIMEOUT_SECONDS=60
        }
        require_exact_confirmation() {
          STATE_EXPORT_CONFIRMED=1
          PROVIDER_SESSIONS_REVOKED=1
          DELETE_RETAINED_DISKS=1
          CONFIRM_DELETE_RETAINED_DISKS=1
        }
        scope_gate() { :; }
        # Invoked indirectly by run_with_deadline in the sourced script.
        # shellcheck disable=SC2329
        az() {
          printf '%s\n' "$*" >>"$call_log"
          if [ "$1 $2 $mode" = "vm list vm" ]; then
            return 42
          fi
          if [ "$1 $2 $mode" = "disk list disk" ]; then
            return 43
          fi
          if [ "$1 $2" = "vm list" ]; then
            printf '[{"name":"worker-one","osDisk":"worker-one-os"}]\n'
          elif [ "$1 $2" = "disk list" ]; then
            printf '[{"name":"worker-one-os","purpose":null},{"name":"disk-one","purpose":"task-state"}]\n'
          fi
        }
        run_destroy
      ) 2>&1
    )
    status=$?
    set -e
    calls=$(<"$call_log")
    rm -f "$call_log"
    [ "$status" -eq 2 ] || fail "destroy did not refuse a failed $mode inventory (status $status): $output"
    assert_not_contains "$calls" "vm deallocate" "destroy mutated compute after a failed $mode inventory"
    assert_not_contains "$calls" "lock delete" "destroy removed locks after a failed $mode inventory"
    assert_not_contains "$calls" "disk delete" "destroy deleted disks after a failed $mode inventory"
    assert_not_contains "$calls" "group delete" "destroy deleted the resource group after a failed $mode inventory"
  done
  rm -f "$sourceable"
  pass "destroy preflights VM and retained-disk inventories before every mutation"
}

run_destroy_unknown_disk_check() {
  local sourceable call_log calls output status
  sourceable=$(mktemp)
  call_log=$(mktemp)
  write_sourceable_script "$sourceable"
  set +e
  # Assignments below intentionally stay inside the isolated runtime-test subshell.
  # shellcheck disable=SC2030
  output=$(
    (
      set --
      # shellcheck source=bin/fm-azure-pilot.sh
      . "$sourceable"
      require_tool() { :; }
      require_cloud_environment() {
        FM_AZURE_SUBSCRIPTION_ID=private-subscription
        RESOURCE_GROUP=private-resource-group
        FM_AZURE_STORAGE_NAME=private-storage
        FM_AZURE_KEY_VAULT_NAME=private-vault
        AZURE_CLEANUP_TIMEOUT_SECONDS=60
      }
      require_exact_confirmation() {
        STATE_EXPORT_CONFIRMED=1
        PROVIDER_SESSIONS_REVOKED=1
        DELETE_RETAINED_DISKS=1
        CONFIRM_DELETE_RETAINED_DISKS=1
      }
      scope_gate() { :; }
      # Invoked indirectly by run_with_deadline in the sourced script.
      # shellcheck disable=SC2329
      az() {
        printf '%s\n' "$*" >>"$call_log"
        if [ "$1 $2" = "vm list" ]; then
          printf '[{"name":"worker-one","osDisk":"worker-one-os"}]\n'
        elif [ "$1 $2" = "disk list" ]; then
          printf '[{"name":"worker-one-os","purpose":null},{"name":"unexpected","purpose":null}]\n'
        fi
      }
      run_destroy
    ) 2>&1
  )
  status=$?
  set -e
  calls=$(<"$call_log")
  rm -f "$sourceable" "$call_log"
  [ "$status" -eq 2 ] || fail "destroy did not refuse an unexpected disk (status $status): $output"
  assert_not_contains "$calls" "vm deallocate" "destroy mutated compute after an unexpected disk"
  assert_not_contains "$calls" "lock delete" "destroy removed locks after an unexpected disk"
  assert_not_contains "$calls" "disk delete" "destroy deleted disks after an unexpected disk"
  assert_not_contains "$calls" "group delete" "destroy deleted the resource group after an unexpected disk"
  pass "destroy inventories every disk and refuses an unexpected disk before every mutation"
}

run_destroy_deadline_check() {
  local sourceable call_log calls output status
  sourceable=$(mktemp)
  call_log=$(mktemp)
  write_sourceable_script "$sourceable"
  set +e
  # Assignments below intentionally stay inside the isolated runtime-test subshell.
  # shellcheck disable=SC2030
  output=$(
    (
      set --
      # shellcheck source=bin/fm-azure-pilot.sh
      . "$sourceable"
      require_tool() { :; }
      require_cloud_environment() {
        FM_AZURE_SUBSCRIPTION_ID=private-subscription
        RESOURCE_GROUP=private-resource-group
        FM_AZURE_STORAGE_NAME=private-storage
        FM_AZURE_KEY_VAULT_NAME=private-vault
        AZURE_CLEANUP_TIMEOUT_SECONDS=1
      }
      require_exact_confirmation() {
        STATE_EXPORT_CONFIRMED=1
        PROVIDER_SESSIONS_REVOKED=1
        DELETE_RETAINED_DISKS=1
        CONFIRM_DELETE_RETAINED_DISKS=1
      }
      scope_gate() { :; }
      # Invoked indirectly by run_with_deadline in the sourced script.
      # shellcheck disable=SC2329
      az() {
        printf '%s\n' "$*" >>"$call_log"
        if [ "$1 $2" = "vm list" ]; then
          printf '[{"name":"worker-one","osDisk":"worker-one-os"}]\n'
        elif [ "$1 $2" = "disk list" ]; then
          printf '[{"name":"worker-one-os","purpose":null}]\n'
        elif [ "$1 $2" = "vm deallocate" ]; then
          while :; do :; done
        fi
      }
      run_destroy
    ) 2>&1
  )
  status=$?
  set -e
  calls=$(<"$call_log")
  rm -f "$sourceable" "$call_log"
  [ "$status" -eq 2 ] || fail "destroy did not refuse a timed-out cleanup call (status $status): $output"
  assert_contains "$output" "timed out or failed" "destroy did not classify the bounded cleanup failure"
  assert_not_contains "$calls" "vm delete" "destroy continued after a timed-out VM deallocation"
  assert_not_contains "$calls" "lock delete" "destroy removed locks after a timed-out VM deallocation"
  assert_not_contains "$calls" "group delete" "destroy deleted the resource group after a timed-out VM deallocation"
  pass "destroy bounds Azure cleanup calls and stops on timeout"
}

run_bounded_mutation_deadline_checks() {
  local sourceable state_dir output status
  sourceable=$(mktemp)
  state_dir=$(mktemp -d)
  write_sourceable_script "$sourceable"
  set +e
  output=$(
    (
      set -- help "$state_dir"
      # shellcheck source=bin/fm-azure-pilot.sh
      . "$sourceable"
      ROOT="$1"
      # Assignments intentionally configure only this timeout-fixture subshell.
      # shellcheck disable=SC2030
      FM_AZURE_MUTATION_STATE_DIR="$1"
      AZURE_CLEANUP_TIMEOUT_SECONDS=1
      DEPLOYMENT_NAME=test-deployment
      RESOURCE_GROUP=test-group
      # Invoked indirectly by run_bounded_az.
      # shellcheck disable=SC2329
      az() { while :; do :; done; }
      run_bounded_az apply deployment sub create
    ) 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "bounded Azure mutation accepted a hung CLI"
  # shellcheck disable=SC2031
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["phase"])' "$state_dir/apply.json")" = retained ] || fail "timed-out mutation did not retain exact operation state"
  python3 - "$SCRIPT" <<'PY' || fail "foundation mutating Azure calls bypass bounded state owner"
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
for function in ("run_validate", "run_preview", "run_apply", "run_worker_create", "run_worker_deallocate", "run_worker_delete"):
    body = text.split(function + "() {", 1)[1].split("\n}\n", 1)[0]
    assert "run_bounded_az" in body, function
    assert not any(line.lstrip().startswith("az ") for line in body.splitlines()), function
for function in ("scope_gate", "provider_gate", "sku_gate", "quota_gate", "name_gate"):
    body = text.split(function + "() {", 1)[1].split("\n}\n", 1)[0]
    assert "run_bounded_az_capture" in body, function
    assert not any("$(az " in line or line.lstrip().startswith("az ") for line in body.splitlines()), function
PY
  rm -f "$sourceable"
  # shellcheck disable=SC2031
  rm -rf "$state_dir"
  pass "all live gates and validate/preview/apply/worker mutations share bounded Azure CLI ownership and retained state"
}

run_subscription_deployment_cli_shape_check() {
  python3 - "$SCRIPT" <<'PY' || fail "subscription deployment create CLI shape is invalid"
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for function in ("run_apply", "run_worker_create"):
    body = text.split(function + "() {", 1)[1].split("\n}\n", 1)[0]
    assert body.count("deployment sub create") == 1, function
    call = body.split("deployment sub create", 1)[1].split("|| refuse", 1)[0]
    expected = (
        "--subscription", "--location", "--name", "--template-file",
        "--parameters", "--output none", "--only-show-errors",
    )
    positions = [call.index(argument) for argument in expected]
    assert positions == sorted(positions), function
    assert "--mode" not in call, function
PY
  pass "subscription deployment creates use the exact valid Azure CLI shape"
}

run_capacity_contract_checks() {
  local sourceable output status
  sourceable=$(mktemp)
  write_sourceable_script "$sourceable"
  set +e
  # These exports intentionally reset names assigned in earlier isolated runtime-test subshells.
  # shellcheck disable=SC2031
  output=$(
    (
      set --
      # shellcheck source=bin/fm-azure-pilot.sh
      . "$sourceable"
      export FM_AZURE_TENANT_ID FM_AZURE_SUBSCRIPTION_ID FM_AZURE_ADMIN_EMAIL
      export FM_AZURE_ADMIN_USERNAME FM_AZURE_ADMIN_SSH_PUBLIC_KEY FM_AZURE_RUNNER_OPERATOR_OBJECT_ID
      export FM_AZURE_OWNER_TAG FM_AZURE_NAMING_PREFIX FM_AZURE_STORAGE_NAME FM_AZURE_KEY_VAULT_NAME
      export FM_AZURE_DEPLOYMENT_GENERATION FM_AZURE_BUDGET_START_DATE
      FM_AZURE_TENANT_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_SUBSCRIPTION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_ADMIN_EMAIL=private-notification
      FM_AZURE_ADMIN_USERNAME=privateadmin
      FM_AZURE_ADMIN_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyPrivateOverlayKey'
      FM_AZURE_RUNNER_OPERATOR_OBJECT_ID=$FM_AZURE_TENANT_ID
      FM_AZURE_OWNER_TAG=owner
      FM_AZURE_NAMING_PREFIX=fmtest
      FM_AZURE_STORAGE_NAME=fmteststorage0001
      FM_AZURE_KEY_VAULT_NAME=fm-test-vault-001
      FM_AZURE_DEPLOYMENT_GENERATION=test-generation
      FM_AZURE_BUDGET_START_DATE=2026-08-01
      fake_usage=$(python3 - <<'PY'
import json

families = [
    "standardDav6Family",
    "StandardDasv7Family",
    "StandardDsv6Family",
    "StandardDadsv7Family",
    "standardDadv6Family",
    "StandardEasv7Family",
    "standardEav6Family",
    "StandardDdsv6Family",
]
rows = [{"name": {"value": "cores"}, "currentValue": 0, "limit": 128}]
rows.extend({"name": {"value": family}, "currentValue": 0, "limit": 10} for family in families)
print(json.dumps(rows, separators=(",", ":")))
PY
)
      # Called by quota_gate in the sourced script.
      # shellcheck disable=SC2329
      az() {
        [ "$1 $2" = "vm list-usage" ] || return 99
        printf '%s\n' "$fake_usage"
      }

      FM_AZURE_CAPACITY_PROFILE=commissioning
      FM_AZURE_AUTHOR_CAPACITY_MODE=mixed-current
      require_cloud_environment
      [ "$RUNNER_VALIDATION_SKU" = Standard_D4as_v6 ]
      [ "$(jq -c . <<<"$WORKER_SKUS_JSON")" = '["Standard_D4as_v6","Standard_D4as_v6"]' ]
      quota_gate

      FM_AZURE_CAPACITY_PROFILE=full
      FM_AZURE_AUTHOR_CAPACITY_MODE=mixed-current
      require_cloud_environment
      [ "$(jq -r 'unique | length' <<<"$WORKER_SKUS_JSON")" -eq 8 ]
      [ "$(jq -r 'length' <<<"$WORKER_SKUS_JSON")" -eq 16 ]
      quota_gate

      set +e
      homogeneous_output=$(
        (
          FM_AZURE_CAPACITY_PROFILE=full
          FM_AZURE_AUTHOR_CAPACITY_MODE=homogeneous-dasv6
          require_cloud_environment
          quota_gate
        ) 2>&1
      )
      homogeneous_status=$?
      set -e
      [ "$homogeneous_status" -eq 2 ]
      [[ "$homogeneous_output" == *"lacks its required free family vCPUs"* ]]
    ) 2>&1
  )
  status=$?
  set -e
  rm -f "$sourceable"
  [ "$status" -eq 0 ] || fail "capacity profiles do not differentiate immediate, mixed, and unavailable homogeneous capacity: $output"
  pass "10-vCPU Dav6 commissioning and 128-vCPU mixed production pass while unavailable homogeneous full capacity refuses"
}

run_worker_create_replay_quota_checks() {
  local sourceable output status
  sourceable=$(mktemp)
  write_sourceable_script "$sourceable"
  set +e
  output=$(
    (
      set --
      # shellcheck source=bin/fm-azure-pilot.sh
      . "$sourceable"
      export FM_AZURE_TENANT_ID FM_AZURE_SUBSCRIPTION_ID FM_AZURE_ADMIN_EMAIL
      export FM_AZURE_ADMIN_USERNAME FM_AZURE_ADMIN_SSH_PUBLIC_KEY FM_AZURE_RUNNER_OPERATOR_OBJECT_ID
      export FM_AZURE_OWNER_TAG FM_AZURE_NAMING_PREFIX FM_AZURE_STORAGE_NAME FM_AZURE_KEY_VAULT_NAME
      export FM_AZURE_DEPLOYMENT_GENERATION FM_AZURE_BUDGET_START_DATE
      FM_AZURE_TENANT_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_SUBSCRIPTION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_ADMIN_EMAIL=private-notification
      FM_AZURE_ADMIN_USERNAME=privateadmin
      FM_AZURE_ADMIN_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyPrivateOverlayKey'
      FM_AZURE_RUNNER_OPERATOR_OBJECT_ID=$FM_AZURE_TENANT_ID
      FM_AZURE_OWNER_TAG=owner
      FM_AZURE_NAMING_PREFIX=fmtest
      FM_AZURE_STORAGE_NAME=fmteststorage0001
      FM_AZURE_KEY_VAULT_NAME=fm-test-vault-001
      FM_AZURE_DEPLOYMENT_GENERATION=test-generation
      FM_AZURE_BUDGET_START_DATE=2026-08-01
      FM_AZURE_CAPACITY_PROFILE=full
      FM_AZURE_AUTHOR_CAPACITY_MODE=mixed-current
      FM_AZURE_WORKER_HOME_BINDING='home-binding'
      FM_AZURE_WORKER_TASK_BINDING='task-binding'
      FM_AZURE_WORKER_INVOCATION_BINDING='assignment-binding'
      FM_AZURE_WORKER_SNAPSHOT_DIGEST=unbound
      FM_AZURE_WORKER_COST_ATTRIBUTION=author
      require_cloud_environment
      COMMAND=worker-create
      SLOT=5
      validate_slot
      WORKER_SLOTS_JSON='[5]'
      WORKER_SKUS_JSON='["Standard_D4s_v6"]'
      fake_usage='[{"name":{"value":"cores"},"currentValue":68,"limit":262},{"name":{"value":"standardDav6Family"},"currentValue":0,"limit":2},{"name":{"value":"StandardDsv6Family"},"currentValue":8,"limit":10}]'
      expected_id="/subscriptions/$FM_AZURE_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachines/$WORKER_NAME"
      exact_vms=$(jq -cn \
        --arg id "$expected_id" --arg name "$WORKER_NAME" \
        --arg deployment "$FM_AZURE_DEPLOYMENT_GENERATION" --arg owner "$FM_AZURE_OWNER_TAG" \
        --arg slot "$SLOT" --arg home "$WORKER_HOME_BINDING" --arg task "$WORKER_TASK_BINDING" \
        --arg invocation "$WORKER_INVOCATION_BINDING" --arg snapshot "$WORKER_SNAPSHOT_DIGEST" \
        '[{id:$id,name:$name,location:"eastus",powerState:"VM deallocated",hardwareProfile:{vmSize:"Standard_D4s_v6"},tags:{
          workload:"firstmate","firstmate-role":"worker","deployment-generation":$deployment,
          "cleanup-owner":$owner,"worker-slot":$slot,"home-binding":$home,
          "task-binding":$task,"invocation-binding":$invocation,"snapshot-digest":$snapshot,
          "selected-sku":"Standard_D4s_v6","cost-attribution":"author"}}]')
      fake_vms='[]'
      replay_read_fails=0
      # shellcheck disable=SC2329
      run_bounded_az_capture() {
        local operation=$1
        shift
        if [ "$operation" = gate-quota ]; then
          printf '%s\n' "$fake_usage"
        elif [ "$operation" = gate-quota-worker-replay ]; then
          [ "$replay_read_fails" -eq 0 ] || return 1
          printf '%s\n' "$fake_vms"
        else
          return 99
        fi
      }

      set +e
      absent_output=$( (quota_gate) 2>&1 )
      absent_status=$?
      set -e
      [ "$absent_status" -eq 2 ]
      [[ "$absent_output" == *"lacks its required free family vCPUs"* ]]

      fake_vms=$exact_vms
      quota_gate

      fake_vms=$(jq '.[0].tags["invocation-binding"] = "foreign"' <<<"$exact_vms")
      set +e
      foreign_output=$( (quota_gate) 2>&1 )
      foreign_status=$?
      set -e
      [ "$foreign_status" -eq 2 ]
      [[ "$foreign_output" == *"differs from the exact pilot binding"* ]]

      fake_vms=$(jq '.[0].location = "westus"' <<<"$exact_vms")
      set +e
      wrong_region_output=$( (quota_gate) 2>&1 )
      wrong_region_status=$?
      set -e
      [ "$wrong_region_status" -eq 2 ]
      [[ "$wrong_region_output" == *"differs from the exact pilot binding"* ]]

      fake_vms=$exact_vms
      replay_read_fails=1
      set +e
      unreadable_output=$( (quota_gate) 2>&1 )
      unreadable_status=$?
      set -e
      [ "$unreadable_status" -eq 2 ]
      [[ "$unreadable_output" == *"replay inventory is unreadable"* ]]
    ) 2>&1
  )
  status=$?
  set -e
  rm -f "$sourceable"
  [ "$status" -eq 0 ] || fail "worker-create replay quota accounting is not exact: $output"
  pass "worker-create replay charges zero new family cores only for the exact landed slot VM"
}

run_documentation_contract_checks() {
  assert_grep 'https://portal.azure.com' "$DOC" "portal-only quota fallback URL is missing"
  assert_grep 'InvalidSupportPlan' "$DOC" "support API blocker is missing"
  assert_grep 'Herdr is the required primary' "$DOC" "Herdr primary boundary is missing"
  assert_grep 'tmux exists only as a recovery fallback' "$DOC" "tmux recovery-only boundary is missing"
  assert_grep 'downloaded self-contained form artifact' "$DOC" "Lavish file contract is missing"
  assert_grep 'complete Azure no-mistakes run' "$DOC" "isolated no-mistakes acceptance gate is missing"
  assert_grep 'policy-grade Azure Crosscheck' "$DOC" "isolated Crosscheck acceptance gate is missing"
  assert_grep 'existing 10-vCPU Dasv6 allowance' "$DOC" "immediate runner and pilot quota contract is missing"
  assert_grep 'currently unavailable because its live family limit is 10' "$DOC" "unavailable homogeneous capacity is not explicit"
  assert_grep 'may instead select one of the foundation' "$DOC" "mixed-family runner selection contract is missing"
  assert_grep 'routes every scope, provider, SKU, quota, name, validation, preview, apply, worker, and cleanup Azure CLI call' "$DOC" "bounded Azure CLI contract is missing"
  assert_no_grep 'seven-day canary' "$DOC" "superseded time-based canary remains documented"
  pass "operator documentation preserves activation, interface, review, and file-transfer contracts"
}

"$SCRIPT" local-validate >/dev/null || fail "script local validation failed"
pass "fm-azure-pilot local-validate executes"
run_static_template_checks
run_explicit_mutation_gate_checks
run_safe_cleanup_order_check
run_worker_create_plan_gate_check
run_destroy_inventory_failure_checks
run_destroy_unknown_disk_check
run_destroy_deadline_check
run_bounded_mutation_deadline_checks
run_subscription_deployment_cli_shape_check
run_capacity_contract_checks
run_worker_create_replay_quota_checks
run_documentation_contract_checks

run_guest_run_bound_check() {
  # The one az call that blocks until the guest script finishes ran under the
  # ordinary 300-second CLI bound while --wall-seconds accepts 21600, so no
  # crewmate task longer than about five minutes could ever return a result.
  # Driven through the REAL mutate_execute so the bound is proved at its call
  # site, not at the constant.
  local tmp out
  fm_test_tmproot_into tmp fm-azure-guest-run-bound
  cat >"$tmp/driver.py" <<'GUESTBOUND'
import importlib.util
import json
import re
import sys
from pathlib import Path

def load_module(name, path):
    module_spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


provider_path, lifecycle_path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_provider", provider_path)
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
lifecycle_spec = importlib.util.spec_from_file_location("fm_lifecycle", lifecycle_path)
lifecycle = importlib.util.module_from_spec(lifecycle_spec)
lifecycle_spec.loader.exec_module(lifecycle)

root = Path(tmp)
controller = {
    "subscription": "00000000-0000-0000-0000-000000000000",
    "resource_group": "rg-test", "prefix": "fmtest", "owner": "owner",
    "deployment_generation": "dep-one", "home_binding": "a" * 64,
}
bindings = {
    "home_binding": "a" * 64, "task": "task-one", "task_generation": "gen-1",
    "assignment_generation": "asg-00000001", "account_binding": "b" * 64,
    "worktree_binding": "c" * 64, "repository_binding": "d" * 64,
    "repository_generation": "repo-gen",
}
request = dict(bindings)
request.update({
    "schema": "fm.worker-execution/v1", "cloud_instance_id": "vm-instance",
    "argv": ["/usr/bin/true"], "wall_seconds": 3600,
})
payload_dir = root / "payload"
account_dir = root / "account"
payload_dir.mkdir(parents=True, exist_ok=True)
account_dir.mkdir(parents=True, exist_ok=True)
(payload_dir / "repo.bundle").write_bytes(b"bundle fixture")
(payload_dir / "brief.md").write_text("brief\n")
(account_dir / "auth.json").write_text("{}\n")


def manifest(directory):
    entries = {}
    for entry in sorted(directory.iterdir()):
        blob = entry.read_bytes()
        entries[entry.name] = {
            "sha256": provider.hashlib.sha256(blob).hexdigest(), "bytes": len(blob),
        }
    return entries


# A real execute carries a payload, so protected parameters are built and the
# guest bound's position relative to that nargs-many flag actually matters.
request["payload_files"] = manifest(payload_dir)
request["account_files"] = manifest(account_dir)
request["request_digest"] = "f" * 64
action = {
    "type": "execute", "slot": 1, "cloud_instance_id": "vm-instance",
    "bindings": bindings, "request": request,
    "request_digest": request["request_digest"], "idempotency_key": "e" * 64,
    "payload_dir": str(payload_dir), "account_dir": str(account_dir),
    "resources": {"staging-result": {"immutable_id": "assignment-result-etag"}},
}
execution = {
    "schema": "fm.worker-execution-result/v1",
    "request_digest": request["request_digest"], "task": "task-one",
    "task_generation": "gen-1", "assignment_generation": "asg-00000001",
    "cloud_instance_id": "vm-instance", "repository_binding": "d" * 64,
    "repository_generation": "repo-gen", "exit_code": 0, "timed_out": False,
    "stdout_sha256": "0" * 64, "stderr_sha256": "1" * 64,
    "stdout_truncated": False, "stderr_truncated": False,
}
execution["result_digest"] = provider.hashlib.sha256(
    provider.canonical_bytes(execution)
).hexdigest()

worker = {"slot": 1, "resources": {"vm": {"power_state": "VM running"}}}
provider.inventory = lambda controller, include_metrics=True: {"workers": [worker]}
provider.worker_by_slot = lambda snapshot, slot: worker
provider.recorded_exact = lambda action, worker, **kwargs: worker["resources"]
provider.action_tags = lambda controller, action: {}
provider.upload_json_blob = lambda *a, **k: "0" * 64
provider.run_command_instance_view = lambda controller, vm, name: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(execution, sort_keys=True, separators=(",", ":")),
    "error": "",
}
seen = {}

# Substitute run(), NOT az(): monkeypatching provider.az leaves the whole az ->
# run plumbing untested, so dropping the timeout parameter from az() (a
# TypeError on every real execute) stayed green. This drives the real az().
class _Result:
    returncode = 0
    stderr = b""

    def __init__(self, payload):
        self.stdout = payload


def fake_run(command, check=True, input_bytes=None, timeout=provider.AZ_TIMEOUT_SECONDS, env=None):
    if "run-command" in command and "update" in command:
        seen["timeout"] = timeout
        seen["command"] = list(command)
    if "generate-sas" in command:
        # az --full-uri renders a bare JSON string.
        return _Result(b'"https://fixture.invalid/staging?sig=fake"')
    return _Result(b"{}")


provider.run = fake_run  # restored below
provider.mutate_execute(controller, action)

# The blocking call must clear the wall by far more than the ordinary
# control-plane bound. An absolute floor, not the constant under test: a
# comparison against GUEST_RUN_SLACK_SECONDS would pass with it set to zero.
assert seen.get("timeout") is not None, "the run-command update carried no explicit bound"
assert seen["timeout"] >= request["wall_seconds"] + 1800, (
    "the blocking run-command bound does not cover a whole guest run", seen["timeout"],
)

# The guest side needs its own bound or Azure applies its default while the
# client waits out the whole wall.
command = seen.get("command") or []
assert "--timeout-in-seconds" in command, ("the run command carries no guest bound", command)
# The call is only blocking because of this, and an async execute returns
# immediately with the instance view still Running.
assert "--async-execution" in command, command
assert command[command.index("--async-execution") + 1] == "false", (
    "the execute stopped waiting for the guest", command,
)
# --protected-parameters is nargs-many, so anything after it is swallowed and
# the guest bound is silently lost.
assert "--protected-parameters" in command, (
    "the fixture built no protected parameters, so the ordering below proves nothing", command,
)
assert command.index("--timeout-in-seconds") < command.index("--protected-parameters"), (
    "the guest bound sits after --protected-parameters and would be swallowed", command,
)
guest_bound = int(command[command.index("--timeout-in-seconds") + 1])
# The floor comes from the supervisor MODULE, not from GUEST_RUN_SLACK_SECONDS
# and not from a scan of the supervisor's source text. Asserting against the
# constant under test certifies whatever it holds; scanning the text silently
# UNDER-counts the moment a literal becomes a named constant, which is the
# direction that kills a run. fm-worker-supervisor.py sums its own per-step
# bounds into NON_WALL_BUDGET_SECONDS at the same names its call sites use, so
# growing a step grows this floor.
supervisor = load_module("fm_supervisor", str(Path(sys.argv[1]).with_name("fm-worker-supervisor.py")))
collection_floor = supervisor.NON_WALL_BUDGET_SECONDS
assert collection_floor > 0, collection_floor
# An Azure kill is not catchable, so undershooting this does not merely lose the
# outcome: no executed marker is written and the next dispatch rmtrees the
# staged repository, deleting the commits the killed run had already made.
assert guest_bound >= request["wall_seconds"] + collection_floor, (
    "the guest run-command bound is under the supervisor's own non-wall budget, so a slow "
    "collection is killed and its commits are destroyed on redispatch",
    guest_bound, request["wall_seconds"], collection_floor,
)

# The controller bounds the whole provider process, which does a full inventory
# sweep, archive builds, uploads and SAS mints BEFORE the blocking call and
# another inventory sweep plus a result upload AFTER it. If its bound is not
# strictly greater than the provider's own, it kills the provider during result
# collection and the task runs a second time.
controller_bound = lifecycle.provider_action_timeout(action)
# A bare `>` is not the property: the controller supervises the WHOLE provider
# subprocess, so it must outlast the client wait plus everything the provider
# does around it. Those budgets are named in the provider next to the bounds
# they are summed from, so this reads them rather than restating a number - a
# one-second margin used to satisfy the old assertion while the controller
# killed the provider mid-download.
provider_whole_run = (
    seen["timeout"]
    + provider.PRE_GUEST_CALL_BUDGET_SECONDS
    + provider.POST_GUEST_CALL_BUDGET_SECONDS
)
assert controller_bound >= provider_whole_run, (
    "the controller bound does not cover the provider's work around the blocking call, so a "
    "long task returning a large outcome is killed during collection and re-runs",
    controller_bound, seen["timeout"], provider_whole_run,
)
assert seen["timeout"] > guest_bound, (
    "the client hangs up at or before the guest bound it set, so a guest timeout races",
    seen["timeout"], guest_bound,
)
print("OK")
GUESTBOUND
  # NOT `|| true`: that makes the compound status unconditionally 0, so the
  # expect_code below can never fail and only assert_contains still guards.
  if out=$(python3 "$tmp/driver.py" "$WORKER_PROVIDER" "$WORKER_LIFECYCLE" "$tmp" 2>&1); then status=0; else status=$?; fi
  expect_code 0 "$status" "the blocking execute call must cover a whole guest run: $out"
  assert_contains "$out" "OK" "the guest-run bound driver did not complete: $out"
  pass "the blocking worker execute call is bounded by the whole guest run"
}

run_worker_os_disk_image_check() {
  # A captured golden image carries its own OS disk size and Azure refuses any
  # smaller pin outright, failing the whole deployment. The first version of
  # this check was string surgery and stayed green when the condition was
  # INVERTED, which reproduces that failure verbatim, so it now parses the
  # expression and evaluates both branches.
  python3 - "$WORKER_TEMPLATE" <<'OSDISK' || fail "the worker OS disk expression is not exact"
import json
import re
import sys

body = open(sys.argv[1], encoding="utf-8").read()
json.loads(body)
lines = [line for line in body.splitlines() if '"osDisk"' in line and "wkr-{1}-os" in line]
assert len(lines) == 1, lines
expression = lines[0].split('"osDisk": "', 1)[1].rsplit('",', 1)[0]

assert expression.startswith("[if(equals(parameters('workerImageId'), '')"), (
    "the branch condition is not the exact empty-image test", expression[:80],
)
assert expression.count("(") == expression.count(")"), "unbalanced parentheses"


def split_args(text):
    parts, depth, current, quoted = [], 0, [], False
    for ch in text:
        if ch == "'":
            quoted = not quoted
        if not quoted:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                parts.append("".join(current).strip())
                current = []
                continue
        current.append(ch)
    parts.append("".join(current).strip())
    return parts


inner = expression[len("[if("):-2]
args = split_args(inner)
assert len(args) == 3, ("if() arity", len(args))
condition, default_branch, custom_branch = args
assert "workerImageId" in condition and "equals(" in condition, condition

def keys_of(branch):
    assert branch.startswith("createObject("), branch[:40]
    items = split_args(branch[len("createObject("):-1])
    assert len(items) % 2 == 0, ("createObject arity is odd", len(items))
    return {items[i].strip("'"): items[i + 1] for i in range(0, len(items), 2)}

# The EMPTY-image branch keeps the explicit size; the custom-image branch must
# not pin one. Inverting the condition swaps these and fails here.
default_keys = keys_of(default_branch)
custom_keys = keys_of(custom_branch)
assert "diskSizeGB" in default_keys, ("the Canonical branch lost its size", sorted(default_keys))
assert "diskSizeGB" not in custom_keys, ("the custom-image branch pins a size", sorted(custom_keys))

required = {"name", "createOption", "deleteOption", "managedDisk"}
for label, keys in (("default", default_keys), ("custom", custom_keys)):
    missing = required - set(keys)
    assert not missing, (label + " branch is missing properties", sorted(missing))
    assert keys["createOption"] == "'FromImage'", (label, keys["createOption"])
    # Detach leaks an OS disk on every VM delete and breaks the absence proofs.
    assert keys["deleteOption"] == "'Delete'", (label, keys["deleteOption"])
    assert keys["managedDisk"] == "createObject('storageAccountType', 'StandardSSD_LRS')", (
        label, keys["managedDisk"],
    )

# The size is the whole point of the branch, so pin the value, not its presence.
assert default_keys["diskSizeGB"] == "64", ("the Canonical OS disk size changed", default_keys["diskSizeGB"])

# The lifecycle matches resources by exact name, so both branches must produce
# the identical disk name.
assert default_keys["name"] == custom_keys["name"], (
    "the two branches build different OS disk names",
    default_keys["name"], custom_keys["name"],
)
assert "disk-{0}-wkr-{1}-os" in default_keys["name"], default_keys["name"]
OSDISK
  pass "the worker OS disk expression branches correctly and names one disk"
}

run_worker_power_gate_check() {
  # The power gate itself, driven directly. Asserting only "a start happens
  # before the run command" left the read, its query, its sentinel and both of
  # its error paths completely unpinned: the whole gate could be reduced to an
  # unconditional `az vm start` and stay green.
  local tmp out status
  fm_test_tmproot_into tmp fm-azure-worker-power
  cat >"$tmp/driver.py" <<'POWERGATE'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_provider", sys.argv[1])
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
provider.VM_POWER_POLL_SECONDS = 0

controller = {"resource_group": "rg-test", "subscription": "s", "prefix": "fmtest"}


def make_az(states, fail_read=False, fail_start=False):
    calls = []

    def fake_az(controller, args, check=True, timeout=None):
        calls.append(list(args))
        if args[:2] == ["vm", "get-instance-view"]:
            if fail_read:
                return None, 1, "read boom"
            return [states.pop(0)] if states else ["PowerState/running"], 0, ""
        if args[:2] == ["vm", "start"]:
            if fail_start:
                return None, 1, "start boom"
            return {}, 0, ""
        return {}, 0, ""

    return fake_az, calls


# An ALREADY RUNNING worker must not be started. Nothing asserted this, so
# deleting the power read entirely and starting unconditionally stayed green.
provider.az, calls = make_az(["PowerState/running"])
assert provider.ensure_worker_running(controller, "vm-x") is False
assert not [c for c in calls if c[:2] == ["vm", "start"]], calls

# The read has to actually ask for PowerState, or a renamed/broken query
# silently returns nothing and every worker looks stopped.
query = calls[0][calls[0].index("--query") + 1]
assert "PowerState" in query, query

# A deallocated worker is started, and the function only returns once the state
# it reads back is running.
provider.az, calls = make_az(["PowerState/deallocated", "PowerState/running"])
assert provider.ensure_worker_running(controller, "vm-x") is True
assert [c for c in calls if c[:2] == ["vm", "start"]], calls

# Transitional states are WAITED OUT, not raced. The TTL schedule fires daily,
# so a create meeting an in-flight deallocate is ordinary; issuing a start
# against one earns an ARM 409 instead of a running VM.
for transitional in ("PowerState/deallocating", "PowerState/stopping"):
    provider.az, calls = make_az([transitional, "PowerState/running"])
    provider.ensure_worker_running(controller, "vm-x")
    starts = [i for i, c in enumerate(calls) if c[:2] == ["vm", "start"]]
    assert not starts, (transitional, calls)

# Both error paths must fail closed rather than report a running worker.
provider.az, _ = make_az(["PowerState/deallocated"], fail_read=True)
try:
    provider.ensure_worker_running(controller, "vm-x")
    raise AssertionError("an unreadable power state was treated as running")
except provider.ProviderError as exc:
    assert "unreadable" in str(exc), exc

provider.az, _ = make_az(["PowerState/deallocated", "PowerState/deallocated"], fail_start=True)
try:
    provider.ensure_worker_running(controller, "vm-x")
    raise AssertionError("a failed start was reported as success")
except provider.ProviderError as exc:
    assert "could not be started" in str(exc), exc

# A create that fails AFTER this provider started the worker must put it back.
# Otherwise it leaves billable compute the controller never records and the
# reconcile loop never reclaims: it only deallocates a worker holding a release
# proof, and a failed create holds none.
deallocated = []


def failing_build(controller, action):
    raise provider.ProviderError("bootstrap exploded")


provider.az, calls = make_az(["PowerState/deallocated", "PowerState/running"])
provider.build_lifecycle_children = failing_build
provider.expected_names = lambda controller, slot: {"vm": "vm-x"}
try:
    provider.create_lifecycle_children(controller, {"slot": 1})
    raise AssertionError("the create swallowed its failure")
except provider.ProviderError as exc:
    assert "bootstrap exploded" in str(exc), exc
assert [c for c in calls if c[:2] == ["vm", "deallocate"]], (
    "a create that failed after starting the worker left it running", calls,
)

# THE CONVERGED EARLY RETURN. create_or_resume hands back an already-built
# worker without ever reaching create_lifecycle_children, and the TTL schedule
# deallocates idle workers daily, so this is the common shape, not the rare one.
# Returning one as-is reports success while the controller marks the task
# assigned; the NEXT action, execute, then hard-refuses deallocated compute, and
# nothing recovers it because classify_worker only reports "deallocated" for a
# worker holding a release proof. Guarding only the create path leaves exactly
# the case the change exists for unguarded.
existing_worker = {"slot": 1, "resources": {"vm": {"tags": {}}}}
provider.az, calls = make_az(["PowerState/deallocated", "PowerState/running"])
provider.inventory = lambda controller, include_metrics=True: {
    "conflicts": [], "workers": [existing_worker],
}
provider.worker_by_slot = lambda snapshot, slot: existing_worker
provider.recorded_exact = lambda action, existing: existing
provider.expected_names = lambda controller, slot: {"vm": "vm-x"}
provider.create_or_resume(controller, {"slot": 1, "bindings": {}})
assert [c for c in calls if c[:2] == ["vm", "start"]], (
    "a converged worker was returned while still deallocated, so the execute after it "
    "refuses and nothing ever starts it", calls,
)

# And a create that did NOT start the worker must not deallocate it: that would
# stop compute someone else is using.
provider.az, calls = make_az(["PowerState/running"])
try:
    provider.create_lifecycle_children(controller, {"slot": 1})
except provider.ProviderError:
    pass
assert not [c for c in calls if c[:2] == ["vm", "deallocate"]], (
    "a create deallocated a worker it never started", calls,
)
print("OK")
POWERGATE
  if out=$(python3 "$tmp/driver.py" "$WORKER_PROVIDER" 2>&1); then status=0; else status=$?; fi
  expect_code 0 "$status" "the worker power gate must hold: $out"
  assert_contains "$out" "OK" "the power-gate driver did not complete: $out"
  pass "the worker power gate reads, waits, starts and unwinds exactly once each"
}

run_guest_run_bound_check
run_worker_os_disk_image_check

run_create_replay_idempotence_check() {
  # A create whose response was lost or timed out replays. Its create-once
  # blobs already exist, so without content-equal convergence the lane wedges
  # permanently: observed live as "The specified blob already exists" on the
  # very first real worker creation.
  local tmp out
  fm_test_tmproot_into tmp fm-azure-create-replay
  cat >"$tmp/driver.py" <<'CREATEREPLAY'
import importlib.util
import sys
from pathlib import Path

provider_path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_provider", provider_path)
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)

controller = {
    "subscription": "00000000-0000-0000-0000-000000000000",
    "resource_group": "rg-test", "prefix": "fmtest", "owner": "owner",
    "deployment_generation": "dep-one", "home_binding": "a" * 64,
}
value = {"schema": "fm.worker-global-reservation/v1", "slot": 1}
digest = provider.hashlib.sha256(provider.canonical_bytes(value) + b"\n").hexdigest()
calls = []


def make_az(existing_digest):
    def fake_az(controller, args, check=True, timeout=provider.AZ_TIMEOUT_SECONDS):
        calls.append(list(args))
        if "upload" in args:
            return None, 1, "ERROR: The specified blob already exists.\nErrorCode:BlobAlreadyExists"
        if "show" in args:
            return existing_digest, 0, ""
        return {}, 0, ""
    return fake_az


# Replay of the same action: the blob already holds exactly these bytes, so the
# create must converge instead of wedging the lane forever.
provider.az = make_az(digest)
landed = provider.upload_json_blob(
    controller, "acct", "runner-control", "worker/01/reservation.json", value, {},
)
assert landed == digest, landed
assert any("show" in call for call in calls), "the replay never checked the existing content"

# A DIFFERENT reservation under the same name is a foreign or newer assignment
# and must still refuse: create-once safety is not weakened.
calls.clear()
provider.az = make_az("f" * 64)
try:
    provider.upload_json_blob(
        controller, "acct", "runner-control", "worker/01/reservation.json", value, {},
    )
    raise AssertionError("a conflicting create-once blob was accepted")
except provider.ProviderError as exc:
    assert "different content" in str(exc), exc
# The check above drives upload_json_blob with a hand-written value, which
# cannot see a REAL caller whose payload is not byte-stable across attempts.
# create_lifecycle_children recomputes a TTL deadline from now() on every call,
# so replaying it minutes later must still converge.
store = {}
now_calls = []


def replay_az(controller, args, check=True, timeout=provider.AZ_TIMEOUT_SECONDS):
    if "upload" in args:
        name = args[args.index("--name") + 1]
        meta = {}
        for item in args[args.index("--metadata") + 1:]:
            if "=" in item:
                key, _, item_value = item.partition("=")
                meta[key] = item_value
        if name in store:
            return None, 1, "ErrorCode:BlobAlreadyExists"
        store[name] = meta
        return {}, 0, ""
    if "show" in args:
        name = args[args.index("--name") + 1]
        query = args[args.index("--query") + 1].split(".")[-1]
        return store.get(name, {}).get(query), 0, ""
    return {}, 0, ""


provider.az = replay_az
reservation_name = "worker/01/reservation.json"


def reservation_payload(deadline_hours):
    return {
        "schema": "fm.worker-global-reservation/v1", "slot": 1,
        "assignment_generation": "asg-00000001", "sku": "Standard_D4as_v6",
        "sku_family": "standardDav6Family", "reservation_usd": 1.0,
        # Deliberately no supervisor_sha256: the real reservation carries none,
        # and a fixture richer than its producer proves nothing about it.
        "ttl_deadline": "2026-08-17T{:02d}:00:00Z".format(deadline_hours),
    }


provider.upload_json_blob(
    controller, "acct", "runner-control", reservation_name,
    reservation_payload(18), {}, volatile_fields=provider.RESERVATION_VOLATILE_FIELDS,
)
# The replay recomputes a LATER deadline, exactly as create_lifecycle_children
# does. It must still converge: the deadline is not what identifies the slot.
provider.upload_json_blob(
    controller, "acct", "runner-control", reservation_name,
    reservation_payload(21), {}, volatile_fields=provider.RESERVATION_VOLATILE_FIELDS,
)

# A different SLOT ASSIGNMENT under the same name is still refused.
conflicting = reservation_payload(21)
conflicting["assignment_generation"] = "asg-00000002"
try:
    provider.upload_json_blob(
        controller, "acct", "runner-control", reservation_name,
        conflicting, {}, volatile_fields=provider.RESERVATION_VOLATILE_FIELDS,
    )
    raise AssertionError("a different assignment converged onto an existing reservation")
except provider.ProviderError as exc:
    assert "different content" in str(exc), exc
# A blob written by an older build carries no identity_digest. Converging on
# that would accept bytes nothing has vouched for.
store.pop(reservation_name)
provider.az = lambda controller, args, check=True, timeout=None: (
    (None, 1, "ErrorCode:BlobAlreadyExists") if "upload" in args else (None, 0, "")
)
try:
    provider.upload_json_blob(
        controller, "acct", "runner-control", reservation_name,
        reservation_payload(18), {}, volatile_fields=provider.RESERVATION_VOLATILE_FIELDS,
    )
    raise AssertionError("a blob with no recorded identity was converged onto")
except provider.ProviderError as exc:
    assert "different content" in str(exc), exc

# Convergence is a create-once affordance. An overwrite upload that somehow
# reports the blob exists must still fail rather than silently accept it.
try:
    provider.upload_json_blob(
        controller, "acct", "runner-control", reservation_name,
        reservation_payload(18), {}, overwrite=True,
    )
    raise AssertionError("an overwrite upload took the create-once convergence path")
except provider.ProviderError as exc:
    assert "staging upload failed" in str(exc), exc
# The checks above drive upload_json_blob directly and so cannot see the REAL
# caller dropping volatile_fields, which is what made S1 revertible with a
# green suite. Capture what create_lifecycle_children actually passes.
create_bindings = {
    "home_binding": "a" * 64, "task": "task-one", "task_generation": "gen-1",
    "assignment_generation": "asg-00000001", "account_binding": "b" * 64,
    "worktree_binding": "c" * 64, "repository_binding": "d" * 64,
    "repository_generation": "repo-gen",
}
captured_uploads = []
_real_upload = provider.upload_json_blob


def recording_upload(controller, account, container, name, value, tags, **kwargs):
    captured_uploads.append(
        (name, kwargs.get("volatile_fields", ()), kwargs.get("overwrite", False), value)
    )
    return "0" * 64


provider.upload_json_blob = recording_upload
# Record every az call the REAL create makes, so the bootstrap run command's
# bounds are asserted from the call site rather than from a fixture.
captured_az = []


# The worker this create converges onto is DEALLOCATED, which is the ordinary
# state of a worker whose TTL schedule has fired. The fixture MODELS THE
# TRANSITION: a real `az vm start` makes the next power read report running, and
# a fixture that keeps saying deallocated is not a stand-in for Azure, it is a
# different machine that never boots.
power_state = {"code": "PowerState/deallocated"}


def recording_az(controller, args, check=True, timeout=None):
    captured_az.append((list(args), timeout))
    if args[:2] == ["vm", "get-instance-view"]:
        return [power_state["code"]], 0, ""
    if args[:2] == ["vm", "start"]:
        power_state["code"] = "PowerState/running"
        return {}, 0, ""
    return {}, 0, ""


# No real waiting in a hermetic test; the polling interval is production's
# concern, not this case's.
provider.VM_POWER_POLL_SECONDS = 0


provider.az = recording_az
provider.run_command_instance_view = lambda *a, **k: {"executionState": "Succeeded", "output": "", "error": ""}
# The real key set, so a rename in expected_names surfaces here rather than
# being papered over by a short fixture.
provider.expected_names = lambda controller, slot: {
    key: key for key in (
        "vm", "nic", "os-disk", "task-disk", "account-disk", "identity",
        "state-container", "monitor-extension", "bootstrap-command",
        "task-command", "ttl-schedule", "global-reservation",
        "staging-request", "staging-result",
    )
}
provider.action_tags = lambda controller, action: {}
try:
    provider.create_lifecycle_children(controller, {
        "slot": 1, "sku": "Standard_D4as_v6", "sku_family": "standardDav6Family",
        "reservation_usd": 1.0, "bindings": create_bindings,
        "cloud_instance_id": "vm-instance", "idempotency_key": "e" * 64,
    })
except Exception as exc:  # noqa: BLE001 - the uploads are what this asserts on
    creation_error = "{}: {}".format(type(exc).__name__, exc)
finally:
    provider.upload_json_blob = _real_upload

# The bootstrap run command BLOCKS on the guest exactly like the execute does:
# it waits up to 60s per data disk for the device node, then runs mkfs and the
# mounts. Left on the ordinary control-plane bound the CLI hangs up while the
# guest carries on, and the controller records a failed create for a VM that is
# alive - which is the failure PROVIDER_CREATE_TIMEOUT_SECONDS is supposed to
# prevent and cannot, from the outside, if the inner bound fires first.
# Azure refuses run commands against stopped compute outright, and nothing else
# in this provider can start a VM, so a create that does not start the worker it
# converged onto wedges the slot with no owned way out.
az_order = [args for args, _ in captured_az]
start_indexes = [i for i, args in enumerate(az_order) if args[:2] == ["vm", "start"]]
assert start_indexes, (
    "the create never starts the deallocated worker it converged onto, so the bootstrap "
    "below fails with OperationNotAllowed", [" ".join(a[:3]) for a in az_order],
)
guest_indexes = [
    i for i, args in enumerate(az_order)
    if args[:3] == ["vm", "run-command", "create"] or args[:3] == ["vm", "run-command", "update"]
]
assert guest_indexes and min(start_indexes) < min(guest_indexes), (
    "the worker is started AFTER the first guest-facing call, which is the call that fails",
    [" ".join(a[:3]) for a in az_order],
)
start_timeout = [timeout for args, timeout in captured_az if args[:2] == ["vm", "start"]][0]
assert start_timeout is not None and start_timeout > provider.AZ_TIMEOUT_SECONDS, (
    "starting a VM is an ARM power operation in minutes and cannot take the ordinary "
    "control-plane bound", start_timeout,
)

run_commands = [
    (args, timeout) for args, timeout in captured_az
    if args[:3] == ["vm", "run-command", "create"]
]
assert len(run_commands) == 2, ("the create no longer issues the bootstrap and the task stub, "
                                "so the split below is wrong", [a for a, _ in run_commands])
# Select by what actually matters - whether the call BLOCKS on the guest -
# rather than by name, so a renamed command cannot quietly skip these bounds.
blocking = [
    (args, timeout) for args, timeout in run_commands
    if args[args.index("--async-execution") + 1] == "false"
]
non_blocking = [
    (args, timeout) for args, timeout in run_commands
    if args[args.index("--async-execution") + 1] == "true"
]
assert len(blocking) == 1 and len(non_blocking) == 1, (
    "the blocking/non-blocking split of the create's run commands changed",
    [(a[a.index("--name") + 1], a[a.index("--async-execution") + 1]) for a, _ in run_commands],
)
bootstrap_args, bootstrap_client_timeout = blocking[0]
# The fire-and-forget stub returns immediately and correctly stays on the
# ordinary control-plane bound; pinning that keeps this case honest about
# which call the bounds below are for.
stub_args, stub_timeout = non_blocking[0]
assert stub_timeout in (None, provider.AZ_TIMEOUT_SECONDS), (
    "a non-blocking run command took a long bound it does not need", stub_timeout,
)
assert "--timeout-in-seconds" in bootstrap_args, (
    "the blocking bootstrap carries no guest bound, so Azure applies its own default while "
    "the CLI waits", bootstrap_args,
)
bootstrap_guest = int(bootstrap_args[bootstrap_args.index("--timeout-in-seconds") + 1])
assert bootstrap_client_timeout is not None and bootstrap_client_timeout > bootstrap_guest, (
    "the client hangs up at or before the guest bound it set, so a bootstrap timeout races",
    bootstrap_client_timeout, bootstrap_guest,
)
assert bootstrap_client_timeout > provider.AZ_TIMEOUT_SECONDS, (
    "the bootstrap is still on the ordinary control-plane bound",
    bootstrap_client_timeout, provider.AZ_TIMEOUT_SECONDS,
)
# --tags is nargs-many: anything after it is swallowed as another tag, so the
# guest bound has to be placed before it or it is silently lost.
assert "--tags" in bootstrap_args, ("the fixture built no tags, so the ordering below proves "
                                    "nothing", bootstrap_args)
assert bootstrap_args.index("--timeout-in-seconds") < bootstrap_args.index("--tags"), (
    "the bootstrap guest bound sits after --tags and would be swallowed", bootstrap_args,
)

reservation_uploads = [item for item in captured_uploads if "reservation" in item[0]]
assert reservation_uploads, (
    "create_lifecycle_children uploaded no reservation",
    captured_uploads, locals().get("creation_error"),
)
assert "ttl_deadline" in reservation_uploads[0][1], (
    "the real caller does not declare its recomputed deadline volatile, so a replay "
    "will never converge", reservation_uploads[0],
)
# Stronger than declaring it volatile: the digest is not in the reservation at
# all, so it can neither wedge a replay nor rot into a stale record. A
# converging replay never rewrites the blob, so any copy kept here would be
# guaranteed wrong after exactly the event it was kept for.
assert "supervisor_sha256" not in reservation_uploads[0][3], (
    "the reservation carries the supervisor digest again, which either wedges a replay when "
    "bin/fm-worker-supervisor.py changes or records a digest the worker is not running",
    reservation_uploads[0][3],
)
# It still has to be recorded somewhere live, and staging-request is rewritten
# on every attempt, so that is where it belongs.
assert any(
    "staging-request" in item[0] and "supervisor_sha256" in item[3] for item in captured_uploads
), ("nothing records the supervisor digest any more", [item[0] for item in captured_uploads])
assert reservation_uploads[0][2] is False, (
    "the reservation stopped being create-once, so it no longer arbitrates slot ownership",
    reservation_uploads[0],
)
# The staging pair is per-assignment working state that mutate_execute already
# overwrites. Leaving it create-once makes a resume after the first execute find
# an execution body where an assignment belongs and refuse forever.
# The reservation is what refuses a foreign or newer assignment, and it is
# create-once. That refusal only protects the staging pair because it happens
# FIRST: reorder these and an overwrite-mode staging write clobbers a live
# assignment before anything checks who owns the slot.
upload_order = [item[0] for item in captured_uploads]
reservation_index = next(i for i, name in enumerate(upload_order) if "reservation" in name)
staging_indexes = [i for i, name in enumerate(upload_order) if "staging" in name]
assert staging_indexes and reservation_index < min(staging_indexes), (
    "a staging blob is written before the create-once reservation that arbitrates the slot, "
    "so a foreign assignment overwrites a live one before it is refused", upload_order,
)

staging_uploads = [item for item in captured_uploads if "staging" in item[0]]
assert len(staging_uploads) == 2, ("the create no longer writes the staging pair",
                                   captured_uploads)
for item in staging_uploads:
    assert item[2] is True, (
        "a staging blob is still create-once, so a replay or resume cannot refresh it",
        item,
    )
print("OK")
CREATEREPLAY
  if out=$(python3 "$tmp/driver.py" "$WORKER_PROVIDER" "$tmp" 2>&1); then status=0; else status=$?; fi
  expect_code 0 "$status" "a create replay must converge on identical content: $out"
  assert_contains "$out" "OK" "the create-replay driver did not complete: $out"
  pass "a create-once staging blob converges on replay and still refuses different content"
}

run_provider_action_bound_check() {
  # The controller bounds the provider subprocess. A flat bound hangs the
  # controller up mid-deployment while Azure carries on, leaving live resources
  # the controller never recorded: observed live on the first worker creation.
  local tmp out
  fm_test_tmproot_into tmp fm-azure-provider-bound
  cat >"$tmp/driver.py" <<'PROVIDERBOUND'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_lifecycle", sys.argv[1])
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
# The provider module supplies the INNER bounds this file's floors are
# measured against, so they never restate a lifecycle constant.
provider_spec = importlib.util.spec_from_file_location("fm_provider", sys.argv[2])
provider = importlib.util.module_from_spec(provider_spec)
provider_spec.loader.exec_module(provider)

# A VM create is an ARM deployment measured in minutes and an execute blocks
# for the whole guest run; neither fits the ordinary control-plane bound.
# Absolute floors, not the constants under test.
# The provider's own worker-create step allows 3600s for the ARM deployment
# ALONE, and a create then runs the blocking bootstrap plus two inventory
# sweeps. A controller bound below that reproduces the failure this exists to
# stop, so the floor is the inner budget, not a round number.
create = lifecycle.provider_action_timeout({"type": "create"})
assert create >= (provider.PILOT_CREATE_DEPLOY_TIMEOUT_SECONDS
                  + provider.CREATE_LIFECYCLE_BUDGET_SECONDS), (
    "the controller create bound does not cover the provider's deployment budget plus its "
    "blocking bootstrap and lifecycle children, so raising an inner bound just moved the "
    "same failure one level out",
    create, provider.PILOT_CREATE_DEPLOY_TIMEOUT_SECONDS,
    provider.CREATE_LIFECYCLE_BUDGET_SECONDS,
)
assert create >= 3600 + 1800, (
    "a create leaves no headroom over the provider's own 3600s deployment budget for the "
    "bootstrap run command, the TTL schedule, three uploads and two inventory sweeps", create,
)

# resume runs through the IDENTICAL provider path (mutate routes create and
# resume to create_or_resume), and it is the recovery path, so leaving it on
# the ordinary bound strands a half-built replacement exactly when things have
# already gone wrong.
for action_type in ("resume", "reset", "delete-compute", "deallocate"):
    bound = lifecycle.provider_action_timeout({"type": action_type})
    assert bound == create, (action_type + " is not bounded like the create it shares a path with", bound)

execute = lifecycle.provider_action_timeout(
    {"type": "execute", "request": {"wall_seconds": 3600}}
)
assert execute >= 3600 + 1800, ("an execute is bounded below its own guest run", execute)

# A steer is not an ordinary read: the provider runs a full inventory sweep,
# then a BLOCKING run-command invoke at its own bound, then another sweep. A
# controller bound merely EQUAL to that inner invoke kills the steer whenever
# the sweeps cost anything, and reports a missed deadline for a steer that may
# already have landed in the guest. The floor is the provider's inner bound
# read from the provider module, never the lifecycle constant under test.
steer = lifecycle.provider_action_timeout({"type": "steer"})
# Not `> AZ_TIMEOUT_SECONDS`: a one-second margin satisfied that while the steer
# was still bracketed by two full inventory sweeps. The provider names its own
# steer budget next to the bounds it is summed from.
assert steer > provider.STEER_BUDGET_SECONDS, (
    "the controller bound for a steer does not outlast the blocking invoke plus the two "
    "inventory sweeps around it", steer, provider.STEER_BUDGET_SECONDS,
)
assert provider.STEER_CLIENT_TIMEOUT_SECONDS > provider.AZ_TIMEOUT_SECONDS, (
    "the blocking steer invoke is still on the ordinary control-plane bound",
    provider.STEER_CLIENT_TIMEOUT_SECONDS,
)
# An ordinary read stays on the ordinary bound.
assert lifecycle.provider_action_timeout(None) == lifecycle.PROVIDER_TIMEOUT_SECONDS
# A malformed wall must not produce a shorter bound than a bare guest run.
assert lifecycle.provider_action_timeout({"type": "execute", "request": {}}) >= 1800
# The bound above is only real if provider_call USES it. Drive the real
# provider_call and capture what it actually passes to subprocess.run:
# asserting the helper alone stays green with the call site reverted.
import json as _json
import subprocess as _subprocess

captured = {}
_real_run = lifecycle.subprocess.run


class _Completed:
    returncode = 0
    stderr = b""

    def __init__(self, payload):
        self.stdout = payload


def _fake_run(argv, input=None, stdout=None, stderr=None, timeout=None):
    captured["timeout"] = timeout
    body = _json.loads(input.decode("utf-8"))
    response = {
        "schema": "fm.worker-provider-response/v1",
        "operation": body["operation"],
        "controller": body["controller"],
        "result": {"idempotency_key": "k"},
    }
    return _Completed(_json.dumps(response).encode("utf-8"))


lifecycle.subprocess.run = _fake_run
env = {
    "home_binding": "a" * 64, "subscription": "sub", "deployment_generation": "dep",
    "owner": "owner", "prefix": "fmtest", "resource_group": "rg",
    "provider_argv": ["/usr/bin/true"],
}
try:
    # provider_call refuses "mutate" outright under the lock discipline; the
    # subprocess bound under test lives on the raw path every mutate reaches
    # through provider_mutate.
    banned = None
    try:
        lifecycle.provider_call(env, "mutate", {"type": "create"})
    except lifecycle.LifecycleError as exc:
        banned = exc
    assert banned is not None and "slot lease" in str(banned), banned
    lifecycle._provider_call_raw(env, "mutate", {"type": "create"})
    create_timeout = captured["timeout"]
    lifecycle._provider_call_raw(
        env, "mutate", {"type": "execute", "request": {"wall_seconds": 3600}}
    )
    execute_timeout = captured["timeout"]
finally:
    lifecycle.subprocess.run = _real_run

assert create_timeout >= 900, ("the raw provider path did not bound a create by its action", create_timeout)
assert execute_timeout >= 3600 + 1800, (
    "the raw provider path did not bound an execute by its guest run", execute_timeout,
)
print("OK")
PROVIDERBOUND
  if out=$(python3 "$tmp/driver.py" "$WORKER_LIFECYCLE" "$WORKER_PROVIDER" 2>&1); then status=0; else status=$?; fi
  expect_code 0 "$status" "the provider subprocess bound must cover its action: $out"
  assert_contains "$out" "OK" "the provider-bound driver did not complete: $out"
  pass "the provider subprocess bound covers the action it runs"
}

run_create_replay_idempotence_check
run_provider_action_bound_check
run_worker_power_gate_check

echo "# fm-azure-pilot.test.sh: all assertions passed"
