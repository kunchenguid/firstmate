#!/usr/bin/env bash
# Tests for bin/fm-evidence-run.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EV="$ROOT/bin/fm-evidence-run.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data/t1" "$HOME_DIR/state"
cat > "$HOME_DIR/state/t1.meta" <<'EOF'
candidateSha=6815f216a8d24bce20a2c2fe6245fe3d270c64da
EOF

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# --- successful evidence run ---
out=$(FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 1 deterministic-local-validation '["printf","hello"]')
path=$(printf '%s\n' "$out" | head -1)
hash=$(printf '%s\n' "$out" | grep '^manifestSha256=' | cut -d= -f2-)
[ -d "$path" ] || fail "evidence dir not created: $path"
[ -f "$path/stdout.txt" ] || fail "stdout missing"
[ -f "$path/stderr.txt" ] || fail "stderr missing"
[ -f "$path/meta.json" ] || fail "meta.json missing"
[ -f "$path/MANIFEST.sha256" ] || fail "manifest missing"
[ "$(cat "$path/stdout.txt")" = "hello" ] || fail "stdout content mismatch"
[ "${#hash}" -eq 64 ] || fail "manifest hash length wrong"
actual_hash=$(python3 - "$path/MANIFEST.sha256" <<'PYEOF'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PYEOF
)
[ "$actual_hash" = "$hash" ] || fail "reported manifest digest does not hash manifest bytes"
(cd "$path" && while read -r digest rel; do
  rel=${rel# }
  [ "$(shasum -a 256 "$rel" | awk '{print $1}')" = "$digest" ] || exit 1
done < MANIFEST.sha256) || fail "manifest does not verify published files"
pass "successful evidence run creates hashed write-once record"

# --- refuses overwrite ---
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 1 deterministic-local-validation '["true"]' 2>/dev/null && fail "overwrite allowed"
pass "evidence sequence refuses overwrite"

# --- failed command records exit code ---
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 2 deterministic-local-validation '["false"]' 2>/dev/null; code=$?
[ "$code" -ne 0 ] || fail "failed command should return non-zero"
[ -f "$HOME_DIR/data/t1/evidence/2-deterministic-local-validation/meta.json" ] || fail "meta missing for failed run"
grep -q '"exitCode": 1' "$HOME_DIR/data/t1/evidence/2-deterministic-local-validation/meta.json" || fail "exitCode not recorded as 1"
pass "failed command records non-zero exit code"

# --- volatile provider fields refused ---
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 3 deterministic-local-validation '["printf","session_pct=50"]' 2>/dev/null && fail "volatile provider field allowed"
pass "volatile provider percentage fields are refused"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 4 deterministic-local-validation '["printf","LoadBalancer healthy"]' >/dev/null || fail "legitimate load balancer output rejected"
pass "volatile-field filter does not reject load balancer text"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 5 '../escape' '["true"]' 2>/dev/null && fail "adapter traversal allowed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run .. implementing 5 deterministic-local-validation '["true"]' 2>/dev/null && fail "dot task id allowed"
pass "task and adapter paths remain contained"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 6 deterministic-local-validation 'not-json' 2>/dev/null && fail "invalid argv accepted"
[ ! -e "$HOME_DIR/data/t1/evidence/6-deterministic-local-validation" ] || fail "failed publication burned evidence sequence"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 6 deterministic-local-validation '["true"]' >/dev/null || fail "sequence was not reusable after failed staging"
pass "failed staging cleans up without burning sequence"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 7 deterministic-local-validation '["bash","-c","true"]' 2>/dev/null && fail "shell interpreter accepted"
pass "evidence commands cannot reintroduce shell evaluation"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 8 deterministic-local-validation '["printf","api_key=do-not-retain"]' 2>/dev/null && fail "secret assignment published"
[ ! -e "$HOME_DIR/data/t1/evidence/8-deterministic-local-validation" ] || fail "refused secret left a published bundle"
pass "obvious secret assignments are refused before publication"

pass "all fm-evidence-run tests passed"
