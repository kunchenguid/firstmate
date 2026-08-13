#!/usr/bin/env bash
# Bounded command owner for the Crosscheck model-image build contract and the
# role-specific network policy.
#
# The tracked declarations live in docs/azure-crosscheck/model-image.json and
# docs/azure-crosscheck/network-policy.json. Plan legs are read-only; the two
# mutation legs are billable/security-sensitive, require exact confirmation
# flags plus the exact subscription, run only from a clean checkout whose HEAD
# is reachable from the freshly fetched public default branch, and never
# change the ambient Azure CLI subscription, register providers, request
# quota, or touch resources outside the named resource group.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
IMAGE_TEMPLATE="$ROOT/docs/azure-crosscheck/model-image.json"
POLICY_TEMPLATE="$ROOT/docs/azure-crosscheck/network-policy.json"

usage() {
  cat <<'EOF'
usage:
  fm-crosscheck-azure-image.sh image-plan   --subscription <id> --resource-group <name> --parameters <file>
  fm-crosscheck-azure-image.sh image-build  --subscription <id> --resource-group <name> --parameters <file> --confirm-build --confirm-subscription <id>
  fm-crosscheck-azure-image.sh policy-plan  --subscription <id> --resource-group <name> --parameters <file>
  fm-crosscheck-azure-image.sh policy-apply --subscription <id> --resource-group <name> --parameters <file> --confirm-apply --confirm-subscription <id>

Plan legs validate and what-if only. Build/apply legs additionally require the
exact confirmation flag pair and a clean landed checkout.
EOF
}

fail() { printf 'CROSSCHECK IMAGE REFUSED: %s\n' "$1" >&2; exit 2; }

require_landed_clean() {
  [ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ] \
    || fail "mutation requires a clean checkout"
  git -C "$ROOT" fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main' \
    || fail "mutation requires fresh public main"
  git -C "$ROOT" merge-base --is-ancestor HEAD refs/remotes/origin/main \
    || fail "mutation requires a HEAD already landed on public main"
}

command=${1:-}
[ -n "$command" ] || { usage; exit 2; }
shift

subscription="" resource_group="" parameters="" confirm_build=0 confirm_apply=0 confirm_subscription=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subscription) subscription=${2:?}; shift 2 ;;
    --resource-group) resource_group=${2:?}; shift 2 ;;
    --parameters) parameters=${2:?}; shift 2 ;;
    --confirm-build) confirm_build=1; shift ;;
    --confirm-apply) confirm_apply=1; shift ;;
    --confirm-subscription) confirm_subscription=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$subscription" ] && [ -n "$resource_group" ] && [ -n "$parameters" ] \
  || fail "--subscription, --resource-group, and --parameters are required"
[ -f "$parameters" ] || fail "parameters file is absent"

case "$command" in
  image-plan|image-build) template=$IMAGE_TEMPLATE; deployment=fm-crosscheck-model-image ;;
  policy-plan|policy-apply) template=$POLICY_TEMPLATE; deployment=fm-crosscheck-network-policy ;;
  *) usage; exit 2 ;;
esac
python3 -m json.tool "$template" >/dev/null || fail "tracked template is not valid JSON"
if grep -Eq '"version"[[:space:]]*:[[:space:]]*"latest"' "$parameters"; then
  fail "an exact marketplace image version is required; latest is refused"
fi

case "$command" in
  image-plan|policy-plan)
    az deployment group validate --subscription "$subscription" \
      --resource-group "$resource_group" --template-file "$template" \
      --parameters "@$parameters" >/dev/null || fail "template validation failed"
    az deployment group what-if --subscription "$subscription" \
      --resource-group "$resource_group" --template-file "$template" \
      --parameters "@$parameters" --no-pretty-print
    ;;
  image-build)
    [ "$confirm_build" = 1 ] || fail "image-build requires --confirm-build"
    [ "$confirm_subscription" = "$subscription" ] || fail "--confirm-subscription must exactly match --subscription"
    require_landed_clean
    az deployment group create --subscription "$subscription" \
      --resource-group "$resource_group" --name "$deployment" \
      --template-file "$template" --parameters "@$parameters" >/dev/null \
      || fail "image template deployment failed"
    template_name=$(az deployment group show --subscription "$subscription" \
      --resource-group "$resource_group" --name "$deployment" \
      --query properties.outputs.imageTemplateName.value --output tsv)
    az image builder run --subscription "$subscription" \
      --resource-group "$resource_group" --name "$template_name" \
      || fail "image build run failed"
    printf 'image build complete: %s\n' "$template_name"
    ;;
  policy-apply)
    [ "$confirm_apply" = 1 ] || fail "policy-apply requires --confirm-apply"
    [ "$confirm_subscription" = "$subscription" ] || fail "--confirm-subscription must exactly match --subscription"
    require_landed_clean
    az deployment group create --subscription "$subscription" \
      --resource-group "$resource_group" --name "$deployment" \
      --template-file "$template" --parameters "@$parameters" >/dev/null \
      || fail "network policy deployment failed"
    printf 'network policy applied\n'
    ;;
esac
