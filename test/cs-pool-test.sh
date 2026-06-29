#!/usr/bin/env bash
# Offline test for fm-cs-pool.sh orchestration (acquire/release), with the
# gh-backed primitives stubbed so the control flow + lease transitions are
# verified without codespace auth. Run: test/cs-pool-test.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FM_CS_LEASES_OVERRIDE="$TMP/leases.json"
export FM_CS_TOKEN_FILE_OVERRIDE="$TMP/none.env"
export FM_CS_HARNESS_FILE_OVERRIDE="$TMP/none"
# Avoid running the real setup script over SSH.
export FM_CS_SETUP_RUN='echo "stub setup $cs $harness"; true'

# shellcheck source=bin/fm-cs-lib.sh
. "$ROOT/bin/fm-cs-lib.sh"
# shellcheck source=bin/fm-cs-pool.sh
. "$ROOT/bin/fm-cs-pool.sh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: expected [$3] got [$2]"; fi; }

# --- fake fleet state, mutated by stubbed primitives ---
FLEET="$TMP/fleet"   # lines: name<TAB>displayName<TAB>repository<TAB>state
cat > "$FLEET" <<EOF
cs-pool1	pool-vscode-01 FREE	rfeltis/vscode	Shutdown
cs-busy	pool-vscode-02 BUSY other	rfeltis/vscode	Available
EOF
ACTIONS="$TMP/actions"; : > "$ACTIONS"

# stub primitives (override the lib's gh-backed ones)
cs_pool_free_entry() { local repo=$1; awk -F'\t' -v r="$repo" '$3==r && $2 ~ /(^| )pool-[a-z0-9-]+ FREE($| )/ {print $1"\t"$2; exit}' "$FLEET"; }
cs_set_label() { local cs=$1 label=$2; awk -F'\t' -v c="$cs" -v l="$label" 'BEGIN{OFS="\t"} {if($1==c)$2=l; print}' "$FLEET" > "$FLEET.t" && mv "$FLEET.t" "$FLEET"; echo "label $cs => $label" >> "$ACTIONS"; }
cs_display_of() { awk -F'\t' -v c="$1" '$1==c{print $2; exit}' "$FLEET"; }
cs_default_branch() { echo main; }
cs_create() { local repo=$1 branch=$2 display=$3; local n="created-$(echo "$display" | tr -dc 'a-z0-9')"; printf '%s\t%s\t%s\t%s\n' "$n" "$display" "$repo" "Available" >> "$FLEET"; echo "create $repo@$branch => $n" >> "$ACTIONS"; printf '%s\n' "$n"; }
cs_stop()   { echo "stop $1" >> "$ACTIONS"; }
cs_delete() { local c=$1; awk -F'\t' -v c="$c" '$1!=c' "$FLEET" > "$FLEET.t" && mv "$FLEET.t" "$FLEET"; echo "delete $c" >> "$ACTIONS"; }
cs_harness() { echo copilot; }

# --- 1. acquire reuses the FREE pool machine ---
CS=$(cs_pool_acquire rfeltis/vscode fix-login-k3)
ok "acquire pool name"  "$CS" "cs-pool1"
ok "lease source pool"  "$(cs_lease_get cs-pool1 source)" "pool"
ok "lease task"         "$(cs_lease_get cs-pool1 task)" "fix-login-k3"
ok "labeled BUSY"       "$(cs_display_of cs-pool1)" "pool-vscode-01 BUSY fix-login-k3"
ok "setup ran"          "$(grep -c 'stub setup cs-pool1' "$ACTIONS"; true)" "0"

# --- 2. acquire when no FREE machine -> cold-create ---
# (only FREE one is now BUSY) acquire for a repo with no free pool machine
CS2=$(cs_pool_acquire rfeltis/vscode add-tests-q7)
ok "acquire created src" "$(cs_lease_get "$CS2" source)" "created"
ok "create recorded"     "$(grep -c 'create rfeltis/vscode@main' "$ACTIONS"; true)" "1"

# --- 3. release pooled -> stop + relabel FREE + drop lease ---
cs_pool_release cs-pool1
ok "pooled stopped"     "$(grep -c 'stop cs-pool1' "$ACTIONS"; true)" "1"
ok "pooled back FREE"   "$(cs_display_of cs-pool1)" "pool-vscode-01 FREE"
ok "pooled lease gone"  "$(cs_lease_get cs-pool1 source)" ""

# --- 4. release created -> delete + drop lease ---
cs_pool_release "$CS2"
ok "created deleted"    "$(grep -c "delete $CS2" "$ACTIONS"; true)" "1"
ok "created lease gone" "$(cs_lease_get "$CS2" source)" ""
ok "created cs removed" "$(awk -F'\t' -v c="$CS2" '$1==c' "$FLEET" | wc -l | tr -d ' ')" "0"

echo "----"; echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
