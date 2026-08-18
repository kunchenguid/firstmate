#!/usr/bin/env bash
# sops-safe.sh - safe helper for Mozilla SOPS and age.
#
# Owned by skills/sops-age/SKILL.md. Never prints age private keys or decrypted
# secret values. Consult `sops --help` and `age --help` for flags; this script
# does not memorize CLI syntax beyond probes and key injection.
#
# Usage:
#   sops-safe.sh probe
#   sops-safe.sh detect-age-identity
#   sops-safe.sh with-age-key bws <PROJECT_ID> -- <command...>
#   sops-safe.sh with-age-key file <KEY_FILE> -- <command...>
#
# probe prints one sanitized key=value line per fact on stdout:
#   status= ready | sops_absent | age_absent | unavailable
#   sops_version= version or none
#   age_version= version or none
#
# detect-age-identity never prints key material; exit 0 when present, 1 when absent.
#
# with-age-key runs the child with SOPS age identity available only inside the
# child process, then unsets SOPS_AGE_KEY and SOPS_AGE_KEY_FILE before exit.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

AGE_KEY_PATTERN='AGE-SECRET-KEY-[A-Z0-9]+'

usage() {
  cat <<'EOF'
sops-safe.sh - safe helper for Mozilla SOPS and age

Usage:
  sops-safe.sh probe
  sops-safe.sh detect-age-identity
  sops-safe.sh with-age-key bws <PROJECT_ID> -- <command...>
  sops-safe.sh with-age-key file <KEY_FILE> -- <command...>

Never prints age private keys or decrypted secret values.
EOF
}

die_usage() {
  printf 'sops-safe: %s\n' "$1" >&2
  usage >&2
  exit 2
}

tool_version() {
  local tool=$1
  local output version
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'none\n'
    return 0
  fi
  if ! output=$("$tool" --version 2>/dev/null); then
    printf 'none\n'
    return 0
  fi
  version=$(awk 'NF >= 2 {print $2; exit}' <<<"$output")
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
  else
    printf 'none\n'
  fi
}

cmd_probe() {
  local sops_version age_version status
  sops_version=$(tool_version sops)
  age_version=$(tool_version age)
  if [ "$sops_version" = none ]; then
    status=sops_absent
  elif [ "$age_version" = none ]; then
    status=age_absent
  else
    status=ready
  fi
  printf 'status=%s sops_version=%s age_version=%s\n' "$status" "$sops_version" "$age_version"
  exit 0
}

age_identity_present() {
  if [ -n "${SOPS_AGE_KEY:-}" ]; then
    printf 'yes\n'
    return 0
  fi
  if [ -n "${SOPS_AGE_KEY_FILE:-}" ] && [ -r "${SOPS_AGE_KEY_FILE}" ]; then
    printf 'yes\n'
    return 0
  fi
  printf 'no\n'
}

age_identity_source() {
  if [ -n "${SOPS_AGE_KEY:-}" ]; then
    printf 'env\n'
    return 0
  fi
  if [ -n "${SOPS_AGE_KEY_FILE:-}" ] && [ -r "${SOPS_AGE_KEY_FILE}" ]; then
    printf 'file\n'
    return 0
  fi
  printf 'none\n'
}

cmd_detect_age_identity() {
  local present source
  present=$(age_identity_present)
  source=$(age_identity_source)
  printf 'age_identity_present=%s source=%s\n' "$present" "$source"
  if [ "$present" = yes ]; then
    exit 0
  fi
  exit 1
}

unset_age_identity() {
  unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE
}

assert_no_key_in_args() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" =~ $AGE_KEY_PATTERN ]]; then
      die_usage "refusing command with age private key in arguments"
    fi
  done
}

cmd_with_age_key() {
  local mode=${1:-}
  shift || true
  case "$mode" in
    bws)
      local project_id=${1:-}
      shift || true
      [ -n "$project_id" ] || die_usage "with-age-key bws requires PROJECT_ID"
      [ "${1:-}" = -- ] || die_usage "with-age-key bws requires -- before command"
      shift
      [ $# -gt 0 ] || die_usage "with-age-key bws requires a command after --"
      assert_no_key_in_args "$project_id" "$@"
      command -v bws >/dev/null 2>&1 || die_usage "bws is required for with-age-key bws"
      unset_age_identity
      bws run --project-id "$project_id" -- "$@"
      local rc=$?
      unset_age_identity
      return "$rc"
      ;;
    file)
      local key_file=${1:-}
      shift || true
      [ -n "$key_file" ] || die_usage "with-age-key file requires KEY_FILE"
      [ "${1:-}" = -- ] || die_usage "with-age-key file requires -- before command"
      shift
      [ $# -gt 0 ] || die_usage "with-age-key file requires a command after --"
      assert_no_key_in_args "$key_file" "$@"
      [ -r "$key_file" ] || die_usage "KEY_FILE is not readable"
      unset_age_identity
      SOPS_AGE_KEY_FILE=$key_file "$@"
      local rc=$?
      unset_age_identity
      return "$rc"
      ;;
    *)
      die_usage "with-age-key mode must be bws or file"
      ;;
  esac
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
  detect-age-identity)
    [ $# -eq 0 ] || die_usage "detect-age-identity takes no arguments"
    cmd_detect_age_identity
    ;;
  with-age-key)
    cmd_with_age_key "$@"
    ;;
  *)
    die_usage "unknown command: $CMD"
    ;;
esac
