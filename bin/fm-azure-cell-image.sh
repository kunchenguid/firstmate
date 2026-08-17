#!/usr/bin/env bash
# Golden-image bake for Azure cell and runner VMs.
#
# Boots one builder VM from the same Canonical Ubuntu 24.04 base the
# templates use, installs the union of the cell and runner bootstrap
# package sets, stages the pinned tool closure (ShellCheck, uv) plus the
# interpreter closure (nodesource node 22, deadsnakes python3.11) under
# /opt/fm-tools with recorded digests, then generalizes and captures a
# managed image in the resource group. Guests re-verify every staged
# archive digest at boot before trusting it, so the image is a cache of
# the provenance chain, never a replacement for it.
#
# usage:
#   fm-azure-cell-image.sh bake --confirm-bake --confirm-subscription <id>
#
# Prints the managed image resource id on success. Point
# FM_AZURE_VM_IMAGE_ID at it to make cells and runners boot from it.
set -euo pipefail

SHELLCHECK_URL=https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz
SHELLCHECK_BYTES=2559196
SHELLCHECK_DIGEST=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
UV_URL=https://github.com/astral-sh/uv/releases/download/0.9.10/uv-x86_64-unknown-linux-gnu.tar.gz
UV_BYTES=21427164
UV_DIGEST=440c4215b171e64061d65d16a23753dd25c29a7f7b1b0446c9e9aed0fa372f27
# Crewmate runtime closure: the pi coding agent, installed globally from its
# digest-pinned registry tarball at bake time. Dependencies resolve through
# npm's own integrity metadata; --ignore-scripts keeps every dependency's
# lifecycle script out of the bake (pi 0.84.1 ships prebuilt natives and
# declares no install scripts of its own).
PI_URL=https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-0.84.1.tgz
PI_BYTES=5103866
PI_DIGEST=a69a18596017e91955fd0fd677be69fab5b6ea01d5b06207bcee34ee1522bc20

command=${1:-}
shift || true
confirm_bake=0
confirm_subscription=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm-bake) confirm_bake=1; shift ;;
    --confirm-subscription) confirm_subscription=${2:?}; shift 2 ;;
    *) echo "fm-azure-cell-image: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ "$command" = bake ] || { echo "usage: fm-azure-cell-image.sh bake --confirm-bake --confirm-subscription <id>" >&2; exit 2; }
SUBSCRIPTION=${FM_AZURE_SUBSCRIPTION_ID:?FM_AZURE_SUBSCRIPTION_ID is required}
RESOURCE_GROUP=${FM_AZURE_RESOURCE_GROUP:?FM_AZURE_RESOURCE_GROUP is required}
[ "$confirm_bake" = 1 ] && [ "$confirm_subscription" = "$SUBSCRIPTION" ] \
  || { echo "fm-azure-cell-image: bake requires --confirm-bake and the exact subscription" >&2; exit 2; }

STAMP=$(date -u +%Y%m%d%H%M%S)
BUILDER=vm-fmimg-builder-$STAMP
IMAGE=img-fm-cell-$STAMP
az() { command az "$@" --subscription "$SUBSCRIPTION" --only-show-errors; }

echo "fm-azure-cell-image: creating builder $BUILDER" >&2
KEYDIR=$(mktemp -d)
trap 'rm -rf "$KEYDIR"' EXIT
ssh-keygen -t ed25519 -N "" -q -f "$KEYDIR/throwaway"
az vm create --resource-group "$RESOURCE_GROUP" --name "$BUILDER" \
  --image Canonical:ubuntu-24_04-lts:server:latest --size Standard_D4as_v6 \
  --os-disk-size-gb 96 --storage-sku StandardSSD_LRS \
  --admin-username fmbake --ssh-key-values "$KEYDIR/throwaway.pub" \
  --public-ip-address "" --nsg "" --output none

BAKE=$(mktemp)
trap 'rm -f "$BAKE"; rm -rf "$KEYDIR"' EXIT
cat >"$BAKE" <<EOF
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl git python3 python3-venv e2fsprogs util-linux passwd \
  systemd tmux jq xz-utils ripgrep cryptsetup-bin tar software-properties-common gnupg
# Interpreter closure: node 22 (module-detecting) and python 3.11.
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
add-apt-repository -y ppa:deadsnakes/ppa
apt-get install -y python3.11 python3.11-venv
# Staged pinned tool closure with recorded digests for boot re-verification.
install -d -m 0755 /opt/fm-tools
curl -fsSL --max-filesize $SHELLCHECK_BYTES -o /opt/fm-tools/shellcheck.tar.xz "$SHELLCHECK_URL"
echo "$SHELLCHECK_DIGEST  /opt/fm-tools/shellcheck.tar.xz" | sha256sum -c -
curl -fsSL --max-filesize $UV_BYTES -o /opt/fm-tools/uv.tar.gz "$UV_URL"
echo "$UV_DIGEST  /opt/fm-tools/uv.tar.gz" | sha256sum -c -
# Crewmate runtime: pi from the digest-pinned tarball onto the system node 22.
curl -fsSL --max-filesize $PI_BYTES -o /opt/fm-tools/pi-coding-agent.tgz "$PI_URL"
echo "$PI_DIGEST  /opt/fm-tools/pi-coding-agent.tgz" | sha256sum -c -
npm install -g --ignore-scripts /opt/fm-tools/pi-coding-agent.tgz
test -x "\$(command -v pi)"
installed=\$(node -p "require('/usr/lib/node_modules/@earendil-works/pi-coding-agent/package.json').version")
test "\$installed" = 0.84.1
apt-get clean
waagent -deprovision+user -force
echo FM-BAKE-COMPLETE
EOF
echo "fm-azure-cell-image: baking (packages + closure)" >&2
# The invoke returns rc 0 regardless of the guest script's exit; the
# terminal marker is the only proof the whole bake actually ran.
BAKE_MESSAGE=$(az vm run-command invoke --resource-group "$RESOURCE_GROUP" --name "$BUILDER" \
  --command-id RunShellScript --scripts @"$BAKE" --query "value[0].message" -o tsv)
case "$BAKE_MESSAGE" in
  *FM-BAKE-COMPLETE*) ;;
  *)
    printf '%s\n' "$BAKE_MESSAGE" | tail -40 >&2
    echo "fm-azure-cell-image: guest bake script did not complete; refusing to capture" >&2
    exit 1
    ;;
esac

echo "fm-azure-cell-image: capturing image $IMAGE" >&2
az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$BUILDER" --output none
az vm generalize --resource-group "$RESOURCE_GROUP" --name "$BUILDER" --output none
az image create --resource-group "$RESOURCE_GROUP" --name "$IMAGE" \
  --source "$BUILDER" --hyper-v-generation V2 --output none
MANAGED_ID=$(az image show --resource-group "$RESOURCE_GROUP" --name "$IMAGE" --query id -o tsv)

# The v6 SKU families are NVMe-only and a plain managed image cannot carry
# the DiskControllerTypes capability (generation 053 ground truth: every
# dispatch refused with "cannot boot with OS image or disk"), so the
# bootable artifact is a Compute Gallery image version whose definition
# declares SCSI+NVMe and TrustedLaunchSupported.
az sig create --resource-group "$RESOURCE_GROUP" --gallery-name fmcellgallery --output none
az sig image-definition show --resource-group "$RESOURCE_GROUP" --gallery-name fmcellgallery \
  --gallery-image-definition fm-cell --output none 2>/dev/null || \
az sig image-definition create --resource-group "$RESOURCE_GROUP" --gallery-name fmcellgallery \
  --gallery-image-definition fm-cell --publisher firstmate --offer fm-cell --sku fm-cell \
  --os-type Linux --os-state Generalized --hyper-v-generation V2 \
  --features "DiskControllerTypes=SCSI,NVMe SecurityType=TrustedLaunchSupported" --output none
VERSION=1.0.$(date -u +%s)
az sig image-version create --resource-group "$RESOURCE_GROUP" --gallery-name fmcellgallery \
  --gallery-image-definition fm-cell --gallery-image-version "$VERSION" \
  --managed-image "$MANAGED_ID" --target-regions eastus --replica-count 1 --output none
IMAGE_ID=$(az sig image-version show --resource-group "$RESOURCE_GROUP" --gallery-name fmcellgallery \
  --gallery-image-definition fm-cell --gallery-image-version "$VERSION" --query id -o tsv)

echo "fm-azure-cell-image: deleting builder" >&2
az vm delete --resource-group "$RESOURCE_GROUP" --name "$BUILDER" --yes --output none
for id in $(az resource list --resource-group "$RESOURCE_GROUP" \
  --query "[?contains(name, '$BUILDER')].id" -o tsv); do
  az resource delete --ids "$id" --output none || true
done

printf 'FM_AZURE_CELL_IMAGE %s\n' "$IMAGE_ID"
