#!/usr/bin/env bash
# Verify a local replica is complete, byte-identical, independently stored, and useful after source loss.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL=${TOOL:-"$ROOT/bin/fm-sovereign-ledger-redundancy.sh"}
FIXTURE="$ROOT/tests/fixtures/sovereign-ledger-redundancy"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() {
  printf '  PASS  %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf '  FAIL  %s\n' "$1"
  fail=$((fail + 1))
}

check_ok() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$description"
  else
    bad "$description"
  fi
}

check_fails() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    bad "$description (it SUCCEEDED - guard absent)"
  else
    ok "$description"
  fi
}

check_fails_with() {
  local description=$1 expected=$2 output status
  shift 2
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -Fq "$expected"; then
    ok "$description"
  else
    bad "$description (missing expected refusal: $expected)"
  fi
}

make_bundle() {
  local dir=$1 source_dir=$2 key source text
  mkdir -p "$dir" "$source_dir"
  cp "$FIXTURE/CONTRACT.md" "$dir/CONTRACT.md"
  cp "$FIXTURE/fm-sovereign-ledger.sh" "$dir/fm-sovereign-ledger.sh"
  chmod +x "$dir/fm-sovereign-ledger.sh"
  : > "$dir/ledger.tsv"
  for key in ruling-1 ruling-2 ruling-3 ruling-4; do
    source="$source_dir/$key.md"
    printf '%s\n' "# $key" '' '**Decided by:** the captain' '' "Exact $key text." > "$source"
    text=$(base64 < "$source" | tr -d '\n')
    printf '%s\t%s\t%s\n' "$key" "$source" "$text" >> "$dir/ledger.tsv"
  done
}

PRIMARY="$TMP/primary"
REPLICA="$TMP/replica"
make_bundle "$PRIMARY" "$TMP/sources"

echo 'T1 snapshot preconditions and independent storage'
mkdir -p "$TMP/missing-primary" "$TMP/missing-replica"
check_fails_with 'snapshot REFUSES an incomplete primary bundle' 'ledger bundle is incomplete' "$TOOL" snapshot "$TMP/missing-primary" "$TMP/missing-replica"
MISSING_CONTRACT="$TMP/missing-contract"
mkdir -p "$MISSING_CONTRACT"
cp "$PRIMARY/ledger.tsv" "$MISSING_CONTRACT/ledger.tsv"
cp "$PRIMARY/fm-sovereign-ledger.sh" "$MISSING_CONTRACT/fm-sovereign-ledger.sh"
check_fails_with 'snapshot REFUSES a primary bundle without its contract' 'ledger bundle is incomplete' "$TOOL" snapshot "$MISSING_CONTRACT" "$TMP/missing-contract-replica"
check_fails_with 'snapshot REFUSES the same primary and replica directory' 'primary and replica directories must differ' "$TOOL" snapshot "$PRIMARY" "$PRIMARY"
check_ok 'snapshot CREATES a verified second ledger bundle' "$TOOL" snapshot "$PRIMARY" "$REPLICA"
check_ok 'verify PASSES for the exact independent replica' "$TOOL" verify "$PRIMARY" "$REPLICA"

echo 'T2 source loss leaves four fixture rulings provable'
for source in "$TMP/sources"/*.md; do
  unlink "$source"
done
set +e
recheck_output=$(LEDGER_DIR="$PRIMARY" "$PRIMARY/fm-sovereign-ledger.sh" recheck 2>&1)
recheck_status=$?
set -e
if [ "$recheck_status" -ne 0 ] && [ "$(printf '%s\n' "$recheck_output" | grep -c '^SOURCE_GONE')" -eq 4 ] && printf '%s\n' "$recheck_output" | grep -q '^recheck: 4 entries, 4 divergent$'; then
  ok 'fixture recheck reports all four removed sources as SOURCE_GONE'
else
  bad 'fixture recheck did not expose all four removed sources'
fi
check_ok 'redundancy verify PASSES after all four sources are gone' "$TOOL" verify "$PRIMARY" "$REPLICA"
for key in ruling-1 ruling-2 ruling-3 ruling-4; do
  expected="$TMP/$key.expected"
  base64 -d < <(awk -F '\t' -v key="$key" '$1 == key { print $3 }' "$PRIMARY/ledger.tsv") > "$expected"
  if diff -q <(LEDGER_DIR="$REPLICA" "$REPLICA/fm-sovereign-ledger.sh" text "$key") "$expected" >/dev/null 2>&1; then
    ok "replica returns exact $key text after source loss"
  else
    bad "replica did not return exact $key text after source loss"
  fi
done

echo 'T3 divergence is detected and never repaired'
printf 'tamper\n' >> "$REPLICA/CONTRACT.md"
check_fails 'verify FAILS when replica contract bytes diverge' "$TOOL" verify "$PRIMARY" "$REPLICA"
check_fails 'snapshot REFUSES to overwrite a divergent replica' "$TOOL" snapshot "$PRIMARY" "$REPLICA"
cp "$PRIMARY/CONTRACT.md" "$REPLICA/CONTRACT.md"
check_ok 'verify PASSES after fixture restore' "$TOOL" verify "$PRIMARY" "$REPLICA"

echo 'T4 an invalid primary is never copied'
INVALID="$TMP/invalid-primary"
mkdir -p "$INVALID"
cp "$PRIMARY/CONTRACT.md" "$INVALID/CONTRACT.md"
cp "$PRIMARY/fm-sovereign-ledger.sh" "$INVALID/fm-sovereign-ledger.sh"
cp "$PRIMARY/ledger.tsv" "$INVALID/ledger.tsv"
sed -i.bak '1s/ruling-1/not-a-ruling/' "$INVALID/ledger.tsv"
unlink "$INVALID/ledger.tsv.bak"
INVALID_REPLICA="$TMP/invalid-replica"
mkdir -p "$INVALID_REPLICA"
check_fails 'snapshot REFUSES a primary rejected by its own verifier' "$TOOL" snapshot "$INVALID" "$INVALID_REPLICA"
if [ ! -e "$INVALID_REPLICA/ledger.tsv" ]; then
  ok 'rejected primary leaves no replica ledger behind'
else
  bad 'rejected primary wrote a replica ledger'
fi

echo 'T5 a hard link is not accepted as redundancy'
HARDLINK="$TMP/hardlink-replica"
mkdir -p "$HARDLINK"
check_ok 'snapshot CREATES a separate hard-link fixture bundle' "$TOOL" snapshot "$PRIMARY" "$HARDLINK"
unlink "$HARDLINK/ledger.tsv"
ln "$PRIMARY/ledger.tsv" "$HARDLINK/ledger.tsv"
check_fails 'verify FAILS when replica ledger.tsv is hard-linked to primary' "$TOOL" verify "$PRIMARY" "$HARDLINK"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
