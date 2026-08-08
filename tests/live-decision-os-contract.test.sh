#!/usr/bin/env bash
# Live contract guard for the Decision OS steward transaction. Exercised only
# when FM_LIVE_DECISION_OS=1 (env-gated, self-skipping otherwise, like the
# live-harness-optin family). Runs against the real registered clone and the
# installed br/storage CLIs and fails naming the exact missing contract.
# br reads use --no-auto-flush (and run from inside the clone) so the guard
# never writes the tracked .beads/issues.jsonl export.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_LIVE_DECISION_OS:-0}" != 1 ]; then
  echo "skip: FM_LIVE_DECISION_OS not set (live Decision OS contract guard)"
  exit 0
fi

REPO="${FM_REFILL_PROJECT:-/home/holu/decision-os}"
[ -d "$REPO/.beads" ] || fail "registered clone missing: $REPO"
[ -x "$REPO/scripts/br_worktree_storage.py" ] || fail "storage script missing"
command -v br >/dev/null || fail "br not installed"

test_verify_session_contract() {
  local out
  out=$(cd "$REPO" && PYTHONPATH=src .venv/bin/python scripts/br_worktree_storage.py \
    verify-session --repo "$REPO" --agent "${BR_AGENT_NAME:-live-guard}" 2>&1)
  case "$out" in
    *"verify-session: OK"*) pass "verify-session --repo --agent works" ;;
    *) fail "verify-session contract failed: $out" ;;
  esac
}

test_br_show_is_array_shaped() {
  local out
  # br discovers .beads/*.db from the current directory, so the reads run
  # inside the clone; --no-auto-flush keeps the tracked JSONL untouched
  out=$(cd "$REPO" && br show --json --no-auto-flush \
    "$(br ready --json --no-auto-flush | jq -r '.[0].id // empty')" 2>/dev/null | jq -r 'type')
  [ "$out" = array ] || fail "br show --json is not array-shaped: $out"
  pass "br show --json returns an array"
}

test_br_comments_has_list_not_show() {
  br comments list --help >/dev/null 2>&1 || fail "br comments list missing"
  # no --help: an unknown subcommand exits nonzero, while --help would print
  # the parent help and exit 0
  br comments show >/dev/null 2>&1 && fail "br comments show exists (contract changed)"
  pass "br comments list exists and comments show does not"
}

test_preflight_requires_full_args() {
  local tmp
  tmp=$(mktemp -d)
  (cd "$REPO" && PYTHONPATH=src .venv/bin/python scripts/br_worktree_storage.py \
    preflight --repo "$REPO" --status-out "$tmp/status.json" --br-bin "$(command -v br)") \
    || fail "preflight --repo --status-out --br-bin failed"
  rm -rf "$tmp"
  pass "preflight requires and accepts --repo --status-out --br-bin"
}

test_verify_session_contract
test_br_show_is_array_shaped
test_br_comments_has_list_not_show
test_preflight_requires_full_args
