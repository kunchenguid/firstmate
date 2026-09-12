#!/usr/bin/env bash
# Condition script for the D5 pipeline-state watch.
set -u
FAIL=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/bin/fm-nm-state-condition.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

check() {  # <name> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then
    echo "ok - $1"
  else
    echo "FAIL - $1 (expected exit $2, got $3)"; FAIL=1
  fi
}

# A fake `no-mistakes` on PATH whose TOON output this test controls.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/no-mistakes" <<'STUB'
#!/usr/bin/env bash
cat "$NM_STUB_OUT"
STUB
chmod +x "$TMP/bin/no-mistakes"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/wt"
git -C "$TMP/wt" init -q
git -C "$TMP/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

printf 'status: running\nstep: review\nround: 1\nelapsed: 12s\n' > "$TMP/a.toon"
printf 'status: running\nstep: review\nround: 1\nelapsed: 999s\n' > "$TMP/b.toon"
printf 'status: parked\nstep: review\nround: 2\nelapsed: 4s\n' > "$TMP/c.toon"

SNAP="$TMP/snap"

NM_STUB_OUT="$TMP/a.toon" bash "$SCRIPT" "$TMP/wt" "$SNAP"
check "first call writes the snapshot and does not fire" 1 "$?"
if [ -s "$SNAP" ]; then echo "ok - snapshot written"; else echo "FAIL - no snapshot"; FAIL=1; fi

NM_STUB_OUT="$TMP/b.toon" bash "$SCRIPT" "$TMP/wt" "$SNAP"
check "elapsed churn alone does not fire" 1 "$?"

NM_STUB_OUT="$TMP/c.toon" bash "$SCRIPT" "$TMP/wt" "$SNAP"
check "a real state change fires" 0 "$?"

NM_STUB_OUT="$TMP/c.toon" bash "$SCRIPT" "$TMP/wt" "$SNAP"
check "the same state twice does not fire again" 1 "$?"

cat > "$TMP/bin/no-mistakes" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
chmod +x "$TMP/bin/no-mistakes"
NM_STUB_OUT=/dev/null bash "$SCRIPT" "$TMP/wt" "$SNAP"
check "a failing probe is an error, never a true" 2 "$?"

bash "$SCRIPT" --projection "$TMP/wt" >/dev/null 2>&1
echo "ok - projection mode runs"

exit "$FAIL"
