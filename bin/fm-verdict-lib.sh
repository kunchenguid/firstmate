#!/usr/bin/env bash
# fm-verdict-lib.sh - the Quarterdeck's append-only verdict channel.
# Spec: docs/specs/2026-07-01-agent-os-council.md (Phase 1).
#
# state/<id>.verdict holds one line per event, same grammar family as
# state/<id>.status: `<kind>: <text>` with kind in approve|reject|escalate|lens.
# approve/reject/escalate are DECISIONS (fm-verify's outcome); lens lines are
# evidence (which foreign lens ran). The gate consumed by fm-merge-local and
# fm-pr-check is fm_verdict_require_approve: the LAST decision line must be
# approve. FM_VERIFY_OVERRIDE=1 is the captain's explicit bypass and prints a
# loud banner so it never happens silently.
#
# Source this; do not execute it.

fm_verdict_file() {  # <state-dir> <id>
  printf '%s/%s.verdict\n' "$1" "$2"
}

fm_verdict_append() {  # <state-dir> <id> <kind> <text>
  local kind=$3
  case "$kind" in
    approve|reject|escalate|lens) : ;;
    *) echo "error: invalid verdict kind '$kind' (approve|reject|escalate|lens)" >&2; return 1 ;;
  esac
  printf '%s: %s\n' "$kind" "$4" >> "$(fm_verdict_file "$1" "$2")"
}

fm_verdict_last() {  # <state-dir> <id> -> kind of last decision line
  local f line
  f=$(fm_verdict_file "$1" "$2")
  [ -f "$f" ] || return 1
  line=$(grep -E '^(approve|reject|escalate):' "$f" | tail -1) || return 1
  printf '%s\n' "${line%%:*}"
}

fm_verdict_reject_count() {  # <state-dir> <id>
  local f
  f=$(fm_verdict_file "$1" "$2")
  [ -f "$f" ] || { echo 0; return 0; }
  grep -c '^reject:' "$f" || true
}

fm_verdict_require_approve() {  # <state-dir> <id> <label>
  local last
  if [ "${FM_VERIFY_OVERRIDE:-}" = 1 ]; then
    {
      echo "==================== QUARTERDECK OVERRIDE ===================="
      echo "WARNING: $3 proceeding for task $2 WITHOUT a verifier approve"
      echo "(FM_VERIFY_OVERRIDE=1 - captain authority; this is logged, not silent)"
      echo "=============================================================="
    } >&2
    return 0
  fi
  last=$(fm_verdict_last "$1" "$2" 2>/dev/null) || last=none
  if [ "$last" != approve ]; then
    {
      echo "======================== QUARTERDECK ========================="
      echo "REFUSED: $3 for task $2 - no verifier approve (last verdict: $last)"
      echo "Run: bin/fm-verify.sh $2"
      echo "Captain bypass (loud, logged): FM_VERIFY_OVERRIDE=1"
      echo "=============================================================="
    } >&2
    return 1
  fi
  return 0
}
