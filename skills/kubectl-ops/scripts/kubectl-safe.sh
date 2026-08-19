#!/usr/bin/env bash
# kubectl-safe.sh - safe helper for kubectl cluster operations.
#
# Owned by skills/kubectl-ops/SKILL.md. Never prints Secret values.
# Consult `kubectl --help` and subcommand help for flags; this script does not
# memorize CLI syntax beyond what it needs for safe probes, verification, and
# redaction.
#
# Usage:
#   kubectl-safe.sh probe
#   kubectl-safe.sh verify-context <EXPECTED_CONTEXT>
#   kubectl-safe.sh verify-namespace <NAMESPACE>
#   kubectl-safe.sh redact-json
#   kubectl-safe.sh cp-check <SOURCE> <DEST>
#   kubectl-safe.sh has-dry-run -- <command...>
#
# probe prints one sanitized key=value line per fact on stdout:
#   status= unavailable | no_context | ready
#   version=  client version or none
#   current_context=  context name or none
#
# verify-context exits 0 when the current context matches EXPECTED_CONTEXT,
# 1 on mismatch, 3 on kubectl or kubeconfig failure.
#
# verify-namespace exits 0 when the namespace exists, 1 when absent, 3 on
# kubectl failure.
#
# cp-check exits 0 when SOURCE is non-empty and DEST matches its SHA-256 when
# DEST exists; 1 on empty source or checksum mismatch; 2 on usage errors.
#
# has-dry-run exits 0 when the command after -- contains --dry-run, else 1.
set -u

usage() {
  cat <<'EOF'
kubectl-safe.sh - safe helper for kubectl cluster operations

Usage:
  kubectl-safe.sh probe
  kubectl-safe.sh verify-context <EXPECTED_CONTEXT>
  kubectl-safe.sh verify-namespace <NAMESPACE>
  kubectl-safe.sh redact-json
  kubectl-safe.sh cp-check <SOURCE> <DEST>
  kubectl-safe.sh has-dry-run -- <command...>

Never prints Secret values.
EOF
}

die_usage() {
  printf 'kubectl-safe: %s\n' "$1" >&2
  usage >&2
  exit 2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die_usage "jq is required"
}

kubectl_client_version() {
  local output version
  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'none\n'
    return 0
  fi
  if ! output=$(kubectl version --client --output=yaml 2>/dev/null); then
    if ! output=$(kubectl version --client 2>/dev/null); then
      printf 'none\n'
      return 0
    fi
    version=$(awk '/Client Version:/ {print $3; exit}' <<<"$output")
    printf '%s\n' "${version:-none}"
    return 0
  fi
  version=$(awk '/gitVersion:/ {print $2; exit}' <<<"$output" | tr -d '"')
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
  else
    printf 'none\n'
  fi
}

current_context() {
  local context
  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'none\n'
    return 0
  fi
  if ! context=$(kubectl config current-context 2>/dev/null); then
    printf 'none\n'
    return 0
  fi
  if [ -z "$context" ]; then
    printf 'none\n'
  else
    printf '%s\n' "$context"
  fi
}

run_kubectl() {
  # shellcheck disable=SC2068
  kubectl "$@" 2>/dev/null
}

cmd_probe() {
  local version context status
  version=$(kubectl_client_version)
  context=$(current_context)
  if [ "$version" = none ]; then
    status=unavailable
    printf 'status=%s version=%s current_context=%s\n' "$status" "$version" "$context"
    exit 0
  fi
  if [ "$context" = none ]; then
    status=no_context
  else
    status=ready
  fi
  printf 'status=%s version=%s current_context=%s\n' "$status" "$version" "$context"
  exit 0
}

cmd_verify_context() {
  local expected=$1 actual
  [ -n "$expected" ] || die_usage "verify-context requires EXPECTED_CONTEXT"
  if ! command -v kubectl >/dev/null 2>&1; then
    exit 3
  fi
  if ! actual=$(kubectl config current-context 2>/dev/null); then
    exit 3
  fi
  if [ "$actual" = "$expected" ]; then
    exit 0
  fi
  printf 'kubectl-safe: context mismatch: expected=%s actual=%s\n' \
    "$expected" "$actual" >&2
  exit 1
}

cmd_verify_namespace() {
  local namespace=$1 stderr
  [ -n "$namespace" ] || die_usage "verify-namespace requires NAMESPACE"
  if ! command -v kubectl >/dev/null 2>&1; then
    exit 3
  fi
  stderr=$(mktemp)
  chmod 600 "$stderr"
  if kubectl get namespace "$namespace" -o name >/dev/null 2>"$stderr"; then
    rm -f "$stderr"
    exit 0
  fi
  if grep -q 'NotFound' "$stderr"; then
    rm -f "$stderr"
    printf 'kubectl-safe: namespace not found: %s\n' "$namespace" >&2
    exit 1
  fi
  rm -f "$stderr"
  exit 3
}

cmd_redact_json() {
  require_jq
  jq '
    walk(
      if type == "object" then
        (if has("data") and (.data | type) == "object" then
          .data |= with_entries(.value = "[REDACTED]")
        else . end)
        | (if has("stringData") and (.stringData | type) == "object" then
          .stringData |= with_entries(.value = "[REDACTED]")
        else . end)
      else
        .
      end
    )
  '
}

sha256_file() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die_usage "sha256sum or shasum is required for cp-check"
  fi
}

cmd_cp_check() {
  local source=$1 dest=$2 src_sum dest_sum
  [ -n "$source" ] && [ -n "$dest" ] || die_usage "cp-check requires SOURCE and DEST"
  if [ ! -f "$source" ]; then
    printf 'kubectl-safe: source missing: %s\n' "$source" >&2
    exit 1
  fi
  if [ ! -s "$source" ]; then
    printf 'kubectl-safe: source is empty: %s\n' "$source" >&2
    exit 1
  fi
  src_sum=$(sha256_file "$source")
  if [ -f "$dest" ]; then
    dest_sum=$(sha256_file "$dest")
    if [ "$src_sum" != "$dest_sum" ]; then
      printf 'kubectl-safe: checksum mismatch source=%s dest=%s\n' \
        "$src_sum" "$dest_sum" >&2
      exit 1
    fi
  fi
  printf 'checksum=%s bytes=%s\n' "$src_sum" "$(wc -c <"$source" | tr -d ' ')"
  exit 0
}

cmd_has_dry_run() {
  local arg
  if [ "${1:-}" != -- ]; then
    die_usage "has-dry-run requires -- before the command"
  fi
  shift
  [ $# -gt 0 ] || die_usage "has-dry-run requires a command after --"
  for arg in "$@"; do
    case "$arg" in
      --dry-run|--dry-run=*)
        exit 0
        ;;
    esac
  done
  printf 'kubectl-safe: command lacks --dry-run flag\n' >&2
  exit 1
}

CMD=${1:-}
shift || true

case "$CMD" in
  -h|--help|'')
    usage
    [ -n "$CMD" ] || exit 2
    exit 0
    ;;
  probe)
    [ $# -eq 0 ] || die_usage "probe takes no arguments"
    cmd_probe
    ;;
  verify-context)
    [ $# -eq 1 ] || die_usage "verify-context requires EXPECTED_CONTEXT"
    cmd_verify_context "$1"
    ;;
  verify-namespace)
    [ $# -eq 1 ] || die_usage "verify-namespace requires NAMESPACE"
    cmd_verify_namespace "$1"
    ;;
  redact-json)
    [ $# -eq 0 ] || die_usage "redact-json reads stdin and takes no arguments"
    cmd_redact_json
    ;;
  cp-check)
    [ $# -eq 2 ] || die_usage "cp-check requires SOURCE and DEST"
    cmd_cp_check "$1" "$2"
    ;;
  has-dry-run)
    cmd_has_dry_run "$@"
    ;;
  *)
    die_usage "unknown command: $CMD"
    ;;
esac
