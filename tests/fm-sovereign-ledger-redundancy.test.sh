#!/usr/bin/env bash
# Verify a complete independent replica, append-only refresh, and source-loss recovery through public commands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL=${TOOL:-"$ROOT/bin/fm-sovereign-ledger-redundancy.sh"}
FIXTURE="$ROOT/tests/fixtures/sovereign-ledger-redundancy"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

check_ok() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi
}

check_fails() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then bad "$description (it SUCCEEDED - guard absent)"; else ok "$description"; fi
}

check_fails_with() {
  local description=$1 expected=$2 output task_rc
  shift 2
  set +e
  output=$("$@" 2>&1)
  task_rc=$?
  set -e
  if [ "$task_rc" -ne 0 ] && printf '%s\n' "$output" | grep -Fq "$expected"; then
    ok "$description"
  else
    bad "$description (missing expected refusal: $expected)"
  fi
}

add_ruling() {
  local dir=$1 source_dir=$2 number=$3 source text
  source="$source_dir/ruling-$number.md"
  printf '%s\n' "# ruling-$number" '' '**Decided by:** the captain' '' "Exact ruling-$number text." > "$source"
  text=$(base64 < "$source" | tr -d '\n')
  printf 'ruling-%s\t%s\t%s\n' "$number" "$source" "$text" >> "$dir/ledger.tsv"
}

make_bundle() {
  local dir=$1 source_dir=$2 number
  mkdir -p "$dir" "$source_dir"
  cp "$FIXTURE/CONTRACT.md" "$dir/CONTRACT.md"
  cp "$FIXTURE/fm-sovereign-ledger.sh" "$dir/fm-sovereign-ledger.sh"
  cp "$FIXTURE/tests.sh" "$dir/tests.sh"
  chmod +x "$dir/fm-sovereign-ledger.sh" "$dir/tests.sh"
  : > "$dir/ledger.tsv"
  for number in 1 2 3 4; do add_ruling "$dir" "$source_dir" "$number"; done
}

PRIMARY="$TMP/primary"
REPLICA="$TMP/replica"
make_bundle "$PRIMARY" "$TMP/sources"

echo 'T1 complete, independent bundle preconditions'
mkdir -p "$TMP/missing-primary"
check_fails_with 'snapshot REFUSES an incomplete primary bundle' 'ledger bundle is incomplete' "$TOOL" snapshot "$TMP/missing-primary" "$TMP/missing-replica"
MISSING_CONTRACT="$TMP/missing-contract"
mkdir -p "$MISSING_CONTRACT"
cp "$PRIMARY/ledger.tsv" "$MISSING_CONTRACT/ledger.tsv"
cp "$PRIMARY/fm-sovereign-ledger.sh" "$MISSING_CONTRACT/fm-sovereign-ledger.sh"
check_fails_with 'snapshot REFUSES a primary bundle without its contract' 'ledger bundle is incomplete' "$TOOL" snapshot "$MISSING_CONTRACT" "$TMP/missing-contract-replica"
check_fails_with 'snapshot REFUSES the same primary and replica directory' 'primary and replica directories must differ' "$TOOL" snapshot "$PRIMARY" "$PRIMARY"
check_ok 'snapshot atomically CREATES the complete second ledger bundle' "$TOOL" snapshot "$PRIMARY" "$REPLICA"
check_ok 'verify PASSES for the exact independent replica' "$TOOL" verify "$PRIMARY" "$REPLICA"

EXECUTABLE="$TMP/non-executable-replica"
check_ok 'snapshot CREATES an executable-bit fixture bundle' "$TOOL" snapshot "$PRIMARY" "$EXECUTABLE"
chmod -x "$EXECUTABLE/fm-sovereign-ledger.sh"
check_fails_with 'verify REFUSES a non-executable replica verifier' 'ledger verifier is not executable' "$TOOL" verify "$PRIMARY" "$EXECUTABLE"
chmod +x "$EXECUTABLE/fm-sovereign-ledger.sh"

echo 'T2 staleness is loud and refresh accepts only an append-only prefix'
add_ruling "$PRIMARY" "$TMP/sources" 5
check_fails_with 'verify names a verified stale replica and its refresh remedy' 'replica is a verified stale prefix; run refresh' "$TOOL" verify "$PRIMARY" "$REPLICA"
check_ok 'refresh advances the verified append-only replica' "$TOOL" refresh "$PRIMARY" "$REPLICA"
check_ok 'verify PASSES after refresh' "$TOOL" verify "$PRIMARY" "$REPLICA"
NONPREFIX="$TMP/non-prefix-replica"
check_ok 'snapshot CREATES a non-prefix refresh fixture' "$TOOL" snapshot "$PRIMARY" "$NONPREFIX"
{ sed -n '2p' "$NONPREFIX/ledger.tsv"; sed -n '1p' "$NONPREFIX/ledger.tsv"; sed -n '3,$p' "$NONPREFIX/ledger.tsv"; } > "$NONPREFIX/reordered-ledger.tsv"
mv "$NONPREFIX/reordered-ledger.tsv" "$NONPREFIX/ledger.tsv"
check_fails_with 'refresh REFUSES a verifying replica that is not a byte-exact prefix' 'replica is not a verified byte-exact append-only prefix of primary' "$TOOL" refresh "$PRIMARY" "$NONPREFIX"

echo 'T3 source loss leaves the four required fixture rulings provable'
for number in 1 2 3 4; do unlink "$TMP/sources/ruling-$number.md"; done
set +e
recheck_output=$(LEDGER_DIR="$PRIMARY" "$PRIMARY/fm-sovereign-ledger.sh" recheck 2>&1)
recheck_status=$?
set -e
if [ "$recheck_status" -ne 0 ] && [ "$(printf '%s\n' "$recheck_output" | grep -c '^SOURCE_GONE')" -eq 4 ] && printf '%s\n' "$recheck_output" | grep -q '^recheck: 5 entries, 4 divergent$'; then
  ok 'fixture recheck reports all four removed sources as SOURCE_GONE'
else
  bad 'fixture recheck did not expose all four removed sources'
fi
check_ok 'redundancy verify PASSES after the four sources are gone' "$TOOL" verify "$PRIMARY" "$REPLICA"
for number in 1 2 3 4; do
  expected="$TMP/ruling-$number.expected"
  base64 -d < <(awk -F '\t' -v key="ruling-$number" '$1 == key { print $3 }' "$PRIMARY/ledger.tsv") > "$expected"
  if diff -q <(LEDGER_DIR="$REPLICA" "$REPLICA/fm-sovereign-ledger.sh" text "ruling-$number") "$expected" >/dev/null 2>&1; then
    ok "replica returns exact ruling-$number text after source loss"
  else
    bad "replica did not return exact ruling-$number text after source loss"
  fi
done

echo 'T4 every bundle-file symlink is refused before it can masquerade as a copy'
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  symlink_replica="$TMP/symlink-$entry"
  check_ok "snapshot CREATES a $entry symlink fixture" "$TOOL" snapshot "$PRIMARY" "$symlink_replica"
  unlink "$symlink_replica/$entry"
  ln -s "$PRIMARY/$entry" "$symlink_replica/$entry"
  check_fails_with "verify REFUSES a symlinked $entry" 'ledger bundle contains a symlink' "$TOOL" verify "$PRIMARY" "$symlink_replica"
done

echo 'T5 non-regular bundle members are refused before comparison or execution'
NONREGULAR="$TMP/non-regular-replica"
check_ok 'snapshot CREATES a non-regular member fixture bundle' "$TOOL" snapshot "$PRIMARY" "$NONREGULAR"
unlink "$NONREGULAR/tests.sh"
mkfifo "$NONREGULAR/tests.sh"
check_fails_with 'verify REFUSES a FIFO bundle member' 'ledger bundle contains a non-regular file' "$TOOL" verify "$PRIMARY" "$NONREGULAR"

echo 'T6 replica bytes are compared before replica-controlled code can execute'
ORDERING="$TMP/ordering-replica"
ORDERING_PROOF="$TMP/replica-code-ran"
check_ok 'snapshot CREATES an ordering fixture bundle' "$TOOL" snapshot "$PRIMARY" "$ORDERING"
printf '%s\n' '#!/usr/bin/env bash' "touch '$ORDERING_PROOF'" 'exit 0' > "$ORDERING/fm-sovereign-ledger.sh"
chmod +x "$ORDERING/fm-sovereign-ledger.sh"
check_fails 'verify REFUSES a changed replica verifier' "$TOOL" verify "$PRIMARY" "$ORDERING"
if [ ! -e "$ORDERING_PROOF" ]; then ok 'changed replica verifier never executed'; else bad 'changed replica verifier executed before byte comparison'; fi

echo 'T7 divergence and extra files are detected and never repaired'
printf 'tamper\n' >> "$REPLICA/CONTRACT.md"
check_fails 'verify FAILS when replica contract bytes diverge' "$TOOL" verify "$PRIMARY" "$REPLICA"
check_fails 'snapshot REFUSES to overwrite a divergent replica' "$TOOL" snapshot "$PRIMARY" "$REPLICA"
cp "$PRIMARY/CONTRACT.md" "$REPLICA/CONTRACT.md"
printf 'planted\n' > "$REPLICA/EXTRA-CONTRACT.md"
check_fails_with 'verify REFUSES an unexpected replica file' 'replica bundle layout differs from primary' "$TOOL" verify "$PRIMARY" "$REPLICA"
unlink "$REPLICA/EXTRA-CONTRACT.md"
check_ok 'verify PASSES after fixture restore' "$TOOL" verify "$PRIMARY" "$REPLICA"

echo 'T8 an invalid primary is never copied'
INVALID="$TMP/invalid-primary"
mkdir -p "$INVALID"
cp "$PRIMARY"/* "$INVALID/"
sed -i.bak '1s/ruling-1/not-a-ruling/' "$INVALID/ledger.tsv"
unlink "$INVALID/ledger.tsv.bak"
INVALID_REPLICA="$TMP/invalid-replica"
check_fails 'snapshot REFUSES a primary rejected by its own verifier' "$TOOL" snapshot "$INVALID" "$INVALID_REPLICA"
if [ ! -e "$INVALID_REPLICA" ]; then ok 'rejected primary leaves no replica directory behind'; else bad 'rejected primary wrote a replica directory'; fi

echo 'T9 each identity check fires independently'
IDENTITY_PRIMARY="$TMP/identity-primary"
IDENTITY_REPLICA="$TMP/identity-replica"
IDENTITY_STAT_BIN="$TMP/identity-stat-bin"
check_ok 'snapshot CREATES an identity-check fixture bundle' "$TOOL" snapshot "$PRIMARY" "$IDENTITY_PRIMARY"
check_ok 'snapshot CREATES an identity-check replica bundle' "$TOOL" snapshot "$PRIMARY" "$IDENTITY_REPLICA"
mkdir "$IDENTITY_STAT_BIN"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'target="${!#}"' \
  'follow=false' \
  'for argument in "$@"; do if [ "$argument" = "-L" ]; then follow=true; fi; done' \
  'case "$target" in' \
  '  *identity-primary/*) side=primary ;;' \
  '  *identity-replica/*) side=replica ;;' \
  '  *) exit 70 ;;' \
  'esac' \
  'case "${IDENTITY_MODE}:${follow}" in' \
  '  lstat:false|stat:true) printf "shared:identity\\n" ;;' \
  '  *) printf "%s:identity\\n" "$side" ;;' \
  'esac' > "$IDENTITY_STAT_BIN/stat"
chmod +x "$IDENTITY_STAT_BIN/stat"
check_fails_with 'verify REFUSES a shared lstat identity even when stat identities differ' 'replica CONTRACT.md shares the primary lstat identity' env PATH="$IDENTITY_STAT_BIN:$PATH" IDENTITY_MODE=lstat IDENTITY_PRIMARY="$IDENTITY_PRIMARY" IDENTITY_REPLICA="$IDENTITY_REPLICA" "$TOOL" verify "$IDENTITY_PRIMARY" "$IDENTITY_REPLICA"
check_fails_with 'verify REFUSES a shared stat identity even when lstat identities differ' 'replica CONTRACT.md resolves to the primary object' env PATH="$IDENTITY_STAT_BIN:$PATH" IDENTITY_MODE=stat IDENTITY_PRIMARY="$IDENTITY_PRIMARY" IDENTITY_REPLICA="$IDENTITY_REPLICA" "$TOOL" verify "$IDENTITY_PRIMARY" "$IDENTITY_REPLICA"

echo 'T10 every bundle member must have separate lstat and stat identities'
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  hardlink_replica="$TMP/hardlink-$entry"
  check_ok "snapshot CREATES a $entry hard-link fixture" "$TOOL" snapshot "$PRIMARY" "$hardlink_replica"
  unlink "$hardlink_replica/$entry"
  ln "$PRIMARY/$entry" "$hardlink_replica/$entry"
  check_fails_with "verify REFUSES a hard-linked $entry by lstat identity" "replica $entry shares the primary lstat identity" "$TOOL" verify "$PRIMARY" "$hardlink_replica"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
