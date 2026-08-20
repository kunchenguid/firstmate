#!/usr/bin/env bash
# Characterization coverage for fm-backlog-receive.sh's successful receipt contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backlog-receive)
HOME_FIXTURE="$TMP_ROOT/home"
DELIVERED="$HOME_FIXTURE/state/handoff/ios.outbox.md"
GENERATION_FILE="$HOME_FIXTURE/state/handoff/.ios.upload-generation"
mkdir -p "$HOME_FIXTURE/bin" "$HOME_FIXTURE/data" "$(dirname "$DELIVERED")"
printf 'fixture\n' > "$HOME_FIXTURE/AGENTS.md"
printf 'ios\n' > "$HOME_FIXTURE/.fm-secondmate-home"
cat > "$DELIVERED" <<'EOF'
## In flight

## Queued
- [ ] ios-task - received remotely (repo: alpha)

## Done
EOF

bytes=$(LC_ALL=C wc -c < "$DELIVERED" | tr -d ' ')
hash=$(shasum -a 256 "$DELIVERED" | awk '{print $1}')
printf '7\n%s\n%s\n' "$bytes" "$hash" > "$GENERATION_FILE"

out=$(FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-backlog-receive.sh" state/handoff/ios.outbox.md "$bytes" "$hash" 7)
assert_contains "$out" 'received: ios moved=1 already=0' \
  "successful receipt must report the moved item count"
assert_grep 'ios-task' "$HOME_FIXTURE/data/backlog.md" \
  "successful receipt must move the queued item into the destination backlog"
assert_absent "$DELIVERED" \
  "successful receipt must remove the delivered scratch file"
pass "fm-backlog-receive.sh receives one committed queued item"
