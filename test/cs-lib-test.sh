#!/usr/bin/env bash
# Offline unit tests for fm-cs-lib.sh pure-local helpers (no codespace auth).
# Run: test/cs-lib-test.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FM_CS_LEASES_OVERRIDE="$TMP/leases.json"
export FM_CS_TOKEN_FILE_OVERRIDE="$TMP/no-such-token.env"
export FM_CS_HARNESS_FILE_OVERRIDE="$TMP/no-such-harness"
# Keep any ambient GH_TOKEN out of the token-loader assertion path.
# shellcheck source=bin/fm-cs-lib.sh
. "$ROOT/bin/fm-cs-lib.sh"

pass=0; fail=0
ok()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: expected [$3] got [$2]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: [$2] is missing [$3]"; fi; }

# --- repo resolution / URL normalization ---
ok "https url"      "$(cs_repo_from_url https://github.com/owner/repo.git)" "owner/repo"
ok "https no .git"  "$(cs_repo_from_url https://github.com/owner/repo)"     "owner/repo"
ok "ssh url"        "$(cs_repo_from_url git@github.com:owner/repo.git)"     "owner/repo"
ok "ssh proto url"  "$(cs_repo_from_url ssh://git@github.com/owner/repo.git)" "owner/repo"
cs_repo_from_url "https://gitlab.com/owner/repo.git" >/dev/null 2>&1; ok "non-github rc" "$?" "1"

# --- label composition / parsing ---
ok "label free"     "$(cs_label pool-vscode-01 FREE)"              "pool-vscode-01 FREE"
ok "label busy"     "$(cs_label pool-vscode-01 BUSY fix-login-k3)" "pool-vscode-01 BUSY fix-login-k3"
LONG="$(cs_label pool-vscode-01 BUSY a-very-long-task-id-that-overflows-the-limit-xx)"
ok "label cap len"  "${#LONG}" "48"
ok "state from dn"  "$(cs_label_state 'pool-vscode-01 BUSY fix-k3')" "BUSY"
ok "state free"     "$(cs_label_state 'pool-gh-02 FREE')"           "FREE"
ok "state none"     "$(cs_label_state 'random name')"               ""
ok "slot from dn"   "$(cs_pool_slot_from_display 'pool-vscode-03 DIRTY cleanup')" "pool-vscode-03"

# --- pool FREE detection against canned gh JSON ---
read -r -d '' JSON <<'EOF'
[
 {"name":"cs-a","displayName":"pool-vscode-01 BUSY x","repository":"rfeltis/vscode","state":"Available"},
 {"name":"cs-b","displayName":"pool-vscode-02 FREE","repository":"rfeltis/vscode","state":"Shutdown"},
 {"name":"cs-c","displayName":"pool-gh-01 FREE","repository":"github/github","state":"Shutdown"},
 {"name":"cs-d","displayName":"config-service-exp","repository":"rfeltis/vscode","state":"Available"}
]
EOF
ok "free vscode"  "$(printf '%s' "$JSON" | cs_pool_free_from_json rfeltis/vscode)" "cs-b"
ok "free gh"      "$(printf '%s' "$JSON" | cs_pool_free_from_json github/github)"  "cs-c"
ok "free none"    "$(printf '%s' "$JSON" | cs_pool_free_from_json owner/none)"     ""

# --- lease registry CRUD ---
cs_lease_record cs-x rfeltis/vscode fix-login-k3 pool fm/fix-login-k3 "pool-vscode-02 BUSY fix-login-k3"
ok "lease repo"   "$(cs_lease_get cs-x repository)" "rfeltis/vscode"
ok "lease task"   "$(cs_lease_get cs-x task)"       "fix-login-k3"
ok "lease source" "$(cs_lease_get cs-x source)"     "pool"
ok "lease branch" "$(cs_lease_get cs-x branch)"     "fm/fix-login-k3"
ok "find by task" "$(cs_lease_for_task fix-login-k3)" "cs-x"
LEASED_AT=$(cs_lease_get cs-x leasedAt)
# update preserves leasedAt
sleep 1
cs_lease_record cs-x rfeltis/vscode fix-login-k3 pool fm/fix-login-k3 "pool-vscode-02 BUSY fix-login-k3 v2"
ok "leasedAt kept" "$(cs_lease_get cs-x leasedAt)" "$LEASED_AT"
cs_lease_record cs-y github/github add-tests-q7 created fm/add-tests-q7 "add-tests"
ok "list count"   "$(cs_lease_list | wc -l | tr -d ' ')" "2"
cs_lease_release cs-x
ok "released"     "$(cs_lease_get cs-x repository)" ""
ok "list after rm" "$(cs_lease_list | wc -l | tr -d ' ')" "1"

# --- harness default ---
ok "harness default" "$(cs_harness)" "copilot"
printf 'codex\n' > "$TMP/cs-harness"; FM_CS_HARNESS_FILE="$TMP/cs-harness"
ok "harness override" "$(cs_harness)" "codex"

# --- spawn helpers: session id, pane launch, steer (pure-local string shapes) ---
SID="$(cs_session_id)"
if [[ "$SID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: session id not a uuid: [$SID]"; fi

PANE="$(cs_pane_launch_cmd 'mycs-z' 'fix-login-k3' copilot)"
has "pane strips token"  "$PANE" "env -u GITHUB_TOKEN gh codespace ssh -c 'mycs-z'"
has "pane login shell"   "$PANE" 'bash -lc'
has "pane runs driver"   "$PANE" '/.fm/fix-login-k3.run.sh'
has "pane home unexpanded" "$PANE" '\$HOME/.fm/fix-login-k3.run.sh'
cs_pane_launch_cmd c i claude >/dev/null 2>&1; ok "pane rejects non-copilot" "$?" "1"
cs_push_driver c i d s claude >/dev/null 2>&1; ok "driver rejects non-copilot" "$?" "1"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
