#!/usr/bin/env bash
# fm-decision-reconcile.sh - deterministic mechanics for policy-to-task reconciliation.
#
# Semantic policy is owned by .agents/skills/decision-reconciliation/SKILL.md.
# Community-safe policy ids live in policies/operating-policies.toml.
# Bounded package ownership lives in policies/implementation-packages.toml.
#
# Usage:
#   fm-decision-reconcile.sh policy-list
#   fm-decision-reconcile.sh policy-show <policy-id>
#   fm-decision-reconcile.sh package-list
#   fm-decision-reconcile.sh package-show <package-id>
#   fm-decision-reconcile.sh link-policy <task-id> --policy <policy-id>
#   fm-decision-reconcile.sh resolve-hold <hold-id> --policy <policy-id> \
#     [--decision-file <path>]
#   fm-decision-reconcile.sh retire <task-id>... --decision-file <path>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
POLICIES="${FM_POLICIES_FILE:-$FM_ROOT/policies/operating-policies.toml}"
PACKAGES="${FM_PACKAGES_FILE:-$FM_ROOT/policies/implementation-packages.toml}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-reconcile: %s\n' "$*" >&2
  exit 1
}

require_python_toml() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read policy TOML"
  python3 - <<'PY' >/dev/null 2>&1 || fail "python3 with tomllib is required to read policy TOML"
import tomllib
PY
}

policy_lookup() {  # <policy-id> <field>
  local policy_id=$1 field=$2
  require_python_toml
  [ -f "$POLICIES" ] || fail "policy registry missing: $POLICIES"
  python3 - "$POLICIES" "$policy_id" "$field" <<'PY'
import sys, tomllib
path, policy_id, field = sys.argv[1:4]
with open(path, "rb") as handle:
    data = tomllib.load(handle)
key = f"policy.{policy_id}"
entry = data.get("policy", {}).get(policy_id)
if not entry:
    entry = data.get(key)
if not entry:
    sys.exit(2)
value = entry.get(field, "")
if not value:
    sys.exit(3)
print(value, end="")
PY
}

package_lookup() {  # <package-id> <field>
  local package_id=$1 field=$2
  require_python_toml
  [ -f "$PACKAGES" ] || fail "package registry missing: $PACKAGES"
  python3 - "$PACKAGES" "$package_id" "$field" <<'PY'
import sys, tomllib
path, package_id, field = sys.argv[1:4]
with open(path, "rb") as handle:
    data = tomllib.load(handle)
key = f"package.{package_id}"
entry = data.get("package", {}).get(package_id)
if not entry:
    entry = data.get(key)
if not entry:
    sys.exit(2)
value = entry.get(field, "")
if value == "":
    sys.exit(3)
if field == "members" and isinstance(value, list):
    print(",".join(value), end="")
else:
    print(value, end="")
PY
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
}

task_show() {
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

validate_slug() {
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

parse_hold_id() {  # <hold-id> -> sets HOLD_ORIGIN and HOLD_KEY
  local hold_id=$1
  case "$hold_id" in
    *-decision-*)
      HOLD_ORIGIN=${hold_id%%-decision-*}
      HOLD_KEY=${hold_id#*-decision-}
      ;;
    *)
      fail "hold id must match <origin-id>-decision-<decision-key>: $hold_id"
      ;;
  esac
  validate_slug origin-id "$HOLD_ORIGIN"
  validate_slug decision-key "$HOLD_KEY"
}

write_policy_decision() {  # <path> <policy-id>
  local path=$1 policy_id=$2 summary escalation
  summary=$(policy_lookup "$policy_id" summary) || fail "unknown policy id: $policy_id"
  escalation=$(policy_lookup "$policy_id" captain_escalation 2>/dev/null || true)
  {
    printf 'Resolved by operating policy %s.\n' "$policy_id"
    printf '%s\n' "$summary"
    if [ -n "$escalation" ] && [ "$escalation" != none ]; then
      printf 'Captain escalation remains required for: %s.\n' "$escalation"
    fi
  } > "$path"
}

require_policy_auto_close() {  # <policy-id>
  local policy_id=$1 escalation
  escalation=$(policy_lookup "$policy_id" captain_escalation) \
    || fail "unknown policy id: $policy_id"
  [ "$escalation" = none ] \
    || fail "policy $policy_id requires captain escalation ($escalation); hold remains open"
}

command_policy_list() {
  require_python_toml
  [ -f "$POLICIES" ] || fail "policy registry missing: $POLICIES"
  python3 - "$POLICIES" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
for policy_id in sorted(data.get("policy", {})):
    summary = data["policy"][policy_id].get("summary", "")
    print(f"{policy_id}\t{summary}")
PY
}

command_policy_show() {
  local policy_id=${1:-}
  [ -n "$policy_id" ] || { usage >&2; exit 2; }
  validate_slug policy-id "$policy_id"
  policy_lookup "$policy_id" summary >/dev/null || fail "unknown policy id: $policy_id"
  python3 - "$POLICIES" "$policy_id" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
entry = data.get("policy", {}).get(sys.argv[2])
if not entry:
    entry = data.get(f"policy.{sys.argv[2]}")
for key, value in entry.items():
    print(f"{key}={value}")
PY
}

command_package_list() {
  require_python_toml
  [ -f "$PACKAGES" ] || fail "package registry missing: $PACKAGES"
  python3 - "$PACKAGES" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
for package_id in sorted(data.get("package", {})):
    owner = data["package"][package_id].get("owner", "")
    summary = data["package"][package_id].get("summary", "")
    print(f"{package_id}\t{owner}\t{summary}")
PY
}

command_package_show() {
  local package_id=${1:-}
  [ -n "$package_id" ] || { usage >&2; exit 2; }
  validate_slug package-id "$package_id"
  package_lookup "$package_id" owner >/dev/null || fail "unknown package id: $package_id"
  python3 - "$PACKAGES" "$package_id" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
entry = data.get("package", {}).get(sys.argv[2])
if not entry:
    entry = data.get(f"package.{sys.argv[2]}")
print(f"owner={entry.get('owner', '')}")
print(f"summary={entry.get('summary', '')}")
for member in entry.get("members", []):
    print(f"member={member}")
PY
}

command_link_policy() {
  local task_id=${1:-} policy_id='' show body note
  [ -n "$task_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --policy) shift; policy_id=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$task_id"
  validate_slug policy-id "$policy_id"
  policy_lookup "$policy_id" summary >/dev/null || fail "unknown policy id: $policy_id"
  require_tasks_axi
  show=$(task_show "$task_id") || fail "task $task_id is absent from the active backlog"
  body=$(show_field "$show" body)
  note="policy=${policy_id}"
  case "$body" in
    *"policy=${policy_id}"*) printf 'linked: %s already references %s\n' "$task_id" "$policy_id"; return 0 ;;
  esac
  if [ -n "$body" ]; then
    body="${body}"$'\n'"${note}"
  else
    body=$note
  fi
  tasks_axi update "$task_id" --body "$body" >/dev/null \
    || fail "could not link policy $policy_id to $task_id"
  printf 'linked: %s -> %s\n' "$task_id" "$policy_id"
}

command_resolve_hold() {
  local hold_id=${1:-} policy_id='' decision_file='' tmp=''
  [ -n "$hold_id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --policy) shift; policy_id=${1:-} ;;
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug hold-id "$hold_id"
  validate_slug policy-id "$policy_id"
  policy_lookup "$policy_id" summary >/dev/null || fail "unknown policy id: $policy_id"
  require_policy_auto_close "$policy_id"
  parse_hold_id "$hold_id"
  if [ -z "$decision_file" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-policy-decision.XXXXXX") || exit 1
    write_policy_decision "$tmp" "$policy_id"
    decision_file=$tmp
  fi
  "$SCRIPT_DIR/fm-decision-hold.sh" decline "$HOLD_ORIGIN" "$HOLD_KEY" \
    --decision-file "$decision_file"
  command_link_policy "$hold_id" --policy "$policy_id" >/dev/null \
    || fail "resolved hold but could not link policy on $hold_id"
  [ -z "$tmp" ] || rm -f "$tmp"
  printf 'policy-resolved: %s via %s\n' "$hold_id" "$policy_id"
}

command_retire() {
  local decision_file='' ids='' id show body held kind
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --) shift; break ;;
      -*) usage >&2; exit 2 ;;
      *) ids="${ids}${ids:+ }$1" ;;
    esac
    shift
  done
  while [ "$#" -gt 0 ]; do
    ids="${ids}${ids:+ }$1"
    shift
  done
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  [ -n "$ids" ] || fail "at least one task id is required"
  require_tasks_axi
  for id in $ids; do
    validate_slug task-id "$id"
    show=$(task_show "$id") || fail "task $id is absent from the active backlog"
    held=$(show_field "$show" held)
    kind=$(show_field "$show" kind)
    if [ "$kind" = captain ] && [ "$held" = yes ]; then
      case "$id" in
        *-decision-*)
          parse_hold_id "$id"
          require_policy_auto_close career-retired
          "$SCRIPT_DIR/fm-decision-hold.sh" decline "$HOLD_ORIGIN" "$HOLD_KEY" \
            --decision-file "$decision_file" >/dev/null \
            || fail "could not retire active captain hold $id"
          command_link_policy "$id" --policy career-retired >/dev/null \
            || fail "retired hold but could not link career-retired policy on $id"
          printf 'retired: %s\n' "$id"
          continue
          ;;
        *)
          fail "$id is an active captain hold and must remain open for captain resolution"
          ;;
      esac
    fi
    body=$(show_field "$show" body)
    body="${body}"$'\n'"Retired by policy reconciliation."
    tasks_axi update "$id" --body "$body" >/dev/null \
      || fail "could not record retirement on $id"
    tasks_axi done "$id" >/dev/null || fail "could not retire $id"
    printf 'retired: %s\n' "$id"
  done
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || { usage >&2; exit 2; }
  shift
  case "$cmd" in
    policy-list) command_policy_list "$@" ;;
    policy-show) command_policy_show "$@" ;;
    package-list) command_package_list "$@" ;;
    package-show) command_package_show "$@" ;;
    link-policy) command_link_policy "$@" ;;
    resolve-hold) command_resolve_hold "$@" ;;
    retire) command_retire "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
