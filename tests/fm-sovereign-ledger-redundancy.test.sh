#!/usr/bin/env bash
# Verify a complete independent replica, append-only refresh, and source-loss recovery through public commands.
# Generated fixture scripts intentionally keep shell expressions literal.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL=${TOOL:-"$ROOT/bin/fm-sovereign-ledger-redundancy.sh"}
FIXTURE="$ROOT/tests/fixtures/sovereign-ledger-redundancy"
TMP="$(mktemp -d)"
bind_mount_active=0
bind_mount_target=
directory_hardlink_active=0
directory_hardlink_target=
cleanup() {
  local cleanup_failed=0
  if [ "$bind_mount_active" -eq 1 ]; then
    if ! umount "$bind_mount_target" >/dev/null 2>&1; then
      printf '  FAIL  cleanup could not detach fixture bind mount; retained scratch at %s\n' "$TMP" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$directory_hardlink_active" -eq 1 ]; then
    if ! unlink "$directory_hardlink_target" >/dev/null 2>&1; then
      printf '  FAIL  cleanup could not unlink fixture directory hard link; retained scratch at %s\n' "$TMP" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$cleanup_failed" -eq 0 ]; then
    rm -rf "$TMP"
  fi
  return "$cleanup_failed"
}
trap cleanup EXIT
SAME_VOLUME_TOOL="$TMP/fm-sovereign-ledger-same-volume"
export TOOL
printf '%s\n' '#!/usr/bin/env bash' 'exec "$TOOL" --allow-same-volume-without-device-redundancy "$@"' > "$SAME_VOLUME_TOOL"
chmod +x "$SAME_VOLUME_TOOL"
pass=0
fail=0
not_verifiable=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
not_verifiable() {
  printf '  NOT_VERIFIABLE  %s\n' "$1"
  not_verifiable=$((not_verifiable + 1))
}

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
    bad "$description (missing expected refusal: $expected; output: ${output//$'\n'/ | })"
  fi
}

check_refuses_promptly_with() {
  local description=$1 expected=$2 timeout=$3 output_file task_rc output
  shift 3
  output_file="$TMP/bounded-command-$pass-$fail.out"
  set +e
  perl -e '
    my $timeout = shift;
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.1;
      kill "KILL", -$pid;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $timeout;
    waitpid $pid, 0;
    alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$timeout" "$@" > "$output_file" 2>&1
  task_rc=$?
  set -e
  output=$(cat "$output_file")
  if [ "$task_rc" -ne 0 ] && [ "$task_rc" -ne 124 ] && printf '%s\n' "$output" | grep -Fq "$expected"; then
    ok "$description"
  elif [ "$task_rc" -eq 124 ]; then
    bad "$description (timed out without the observed refusal: $expected)"
  else
    bad "$description (missing expected refusal: $expected; output: ${output//$'\n'/ | })"
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
check_fails_with 'verify REFUSES a nonexistent ledger directory' 'ledger directory does not exist' "$SAME_VOLUME_TOOL" verify "$TMP/absent-primary" "$TMP/absent-replica"
mkdir -p "$TMP/missing-primary"
check_fails_with 'snapshot REFUSES an incomplete primary bundle' 'ledger bundle manifest differs from the exact required names' "$SAME_VOLUME_TOOL" snapshot "$TMP/missing-primary" "$TMP/missing-replica"
MISSING_CONTRACT="$TMP/missing-contract"
mkdir -p "$MISSING_CONTRACT"
cp "$PRIMARY/ledger.tsv" "$MISSING_CONTRACT/ledger.tsv"
cp "$PRIMARY/fm-sovereign-ledger.sh" "$MISSING_CONTRACT/fm-sovereign-ledger.sh"
check_fails_with 'snapshot REFUSES a primary bundle without its contract' 'ledger bundle manifest differs from the exact required names' "$SAME_VOLUME_TOOL" snapshot "$MISSING_CONTRACT" "$TMP/missing-contract-replica"
check_fails_with 'snapshot REFUSES the same primary and replica directory' 'primary and replica directories must differ' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$PRIMARY"
check_ok 'snapshot atomically CREATES the complete second ledger bundle' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$REPLICA"
check_ok 'verify PASSES for the exact independent replica' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"

EXECUTABLE="$TMP/non-executable-replica"
check_ok 'snapshot CREATES an executable-bit fixture bundle' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$EXECUTABLE"
chmod -x "$EXECUTABLE/fm-sovereign-ledger.sh"
check_fails_with 'verify REFUSES a non-executable replica verifier' 'ledger verifier is not executable' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$EXECUTABLE"
chmod +x "$EXECUTABLE/fm-sovereign-ledger.sh"
FAILING_FIND_BIN="$TMP/failing-find-bin"
mkdir "$FAILING_FIND_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 71' > "$FAILING_FIND_BIN/find"
chmod +x "$FAILING_FIND_BIN/find"
check_fails_with 'verify REFUSES when exact bundle enumeration fails' 'could not enumerate ledger bundle' env PATH="$FAILING_FIND_BIN:$PATH" "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"

echo 'T2 staleness is loud and refresh accepts only an append-only prefix'
add_ruling "$PRIMARY" "$TMP/sources" 5
check_fails_with 'verify names a verified stale replica and its refresh remedy' 'replica is a verified stale prefix; run refresh' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"
check_ok 'refresh advances the verified append-only replica' "$SAME_VOLUME_TOOL" refresh "$PRIMARY" "$REPLICA"
check_ok 'verify PASSES after refresh' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"
check_fails_with 'refresh REFUSES an equal-length replica rather than treating it as stale' 'replica is not a verified byte-exact append-only prefix of primary' "$SAME_VOLUME_TOOL" refresh "$PRIMARY" "$REPLICA"
NONPREFIX="$TMP/non-prefix-replica"
check_ok 'snapshot CREATES a non-prefix refresh fixture' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$NONPREFIX"
{ sed -n '2p' "$NONPREFIX/ledger.tsv"; sed -n '1p' "$NONPREFIX/ledger.tsv"; sed -n '3,$p' "$NONPREFIX/ledger.tsv"; } > "$NONPREFIX/reordered-ledger.tsv"
mv "$NONPREFIX/reordered-ledger.tsv" "$NONPREFIX/ledger.tsv"
check_fails_with 'refresh REFUSES a verifying replica that is not a byte-exact prefix' 'replica is not a verified byte-exact append-only prefix of primary' "$SAME_VOLUME_TOOL" refresh "$PRIMARY" "$NONPREFIX"
SHORT_NONPREFIX="$TMP/short-non-prefix-replica"
check_ok 'snapshot CREATES a shorter non-prefix refresh fixture' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$SHORT_NONPREFIX"
{ sed -n '2p' "$SHORT_NONPREFIX/ledger.tsv"; sed -n '1p' "$SHORT_NONPREFIX/ledger.tsv"; sed -n '3,4p' "$SHORT_NONPREFIX/ledger.tsv"; } > "$SHORT_NONPREFIX/reordered-ledger.tsv"
mv "$SHORT_NONPREFIX/reordered-ledger.tsv" "$SHORT_NONPREFIX/ledger.tsv"
check_fails_with 'refresh REFUSES a shorter verifying replica that is not byte-exact' 'replica is not a verified byte-exact append-only prefix of primary' "$SAME_VOLUME_TOOL" refresh "$PRIMARY" "$SHORT_NONPREFIX"
EMPTY_PREFIX_PRIMARY="$TMP/empty-prefix-primary"
EMPTY_PREFIX_REPLICA="$TMP/empty-prefix-replica"
make_bundle "$EMPTY_PREFIX_PRIMARY" "$TMP/empty-prefix-sources"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$EMPTY_PREFIX_PRIMARY/fm-sovereign-ledger.sh"
chmod +x "$EMPTY_PREFIX_PRIMARY/fm-sovereign-ledger.sh"
check_ok 'snapshot CREATES an empty-prefix guard fixture' "$SAME_VOLUME_TOOL" snapshot "$EMPTY_PREFIX_PRIMARY" "$EMPTY_PREFIX_REPLICA"
: > "$EMPTY_PREFIX_REPLICA/ledger.tsv"
GNU_HEAD_BIN="$TMP/gnu-head-bin"
mkdir "$GNU_HEAD_BIN"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'if [ "${1:-}" = -n ] && [ "${2:-}" = 0 ]; then exit 0; fi' 'exec /usr/bin/head "$@"' > "$GNU_HEAD_BIN/head"
chmod +x "$GNU_HEAD_BIN/head"
check_refuses_promptly_with 'refresh promptly REFUSES an empty replica ledger under GNU head semantics even when the fixture verifier accepts it' 'replica is not a verified byte-exact append-only prefix of primary' 3 env PATH="$GNU_HEAD_BIN:$PATH" "$SAME_VOLUME_TOOL" refresh "$EMPTY_PREFIX_PRIMARY" "$EMPTY_PREFIX_REPLICA"

if [ "${FM_MUTATION_RUN:-0}" != 1 ]; then
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
check_ok 'redundancy verify PASSES after the four sources are gone' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"
for number in 1 2 3 4; do
  expected="$TMP/ruling-$number.expected"
  base64 -d < <(awk -F '\t' -v key="ruling-$number" '$1 == key { print $3 }' "$PRIMARY/ledger.tsv") > "$expected"
  if diff -q <(LEDGER_DIR="$REPLICA" "$REPLICA/fm-sovereign-ledger.sh" text "ruling-$number") "$expected" >/dev/null 2>&1; then
    ok "replica returns exact ruling-$number text after source loss"
  else
    bad "replica did not return exact ruling-$number text after source loss"
  fi
done
fi

echo 'T4 every bundle-file symlink is refused before it can masquerade as a copy'
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  symlink_replica="$TMP/symlink-$entry"
  check_ok "snapshot CREATES a $entry symlink fixture" "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$symlink_replica"
  unlink "$symlink_replica/$entry"
  ln -s "$PRIMARY/$entry" "$symlink_replica/$entry"
  check_fails_with "verify REFUSES a symlinked $entry" 'ledger bundle contains a symlink' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$symlink_replica"
done

echo 'T5 non-regular bundle members are refused before comparison or execution'
NONREGULAR="$TMP/non-regular-replica"
check_ok 'snapshot CREATES a non-regular member fixture bundle' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$NONREGULAR"
unlink "$NONREGULAR/tests.sh"
mkfifo "$NONREGULAR/tests.sh"
check_refuses_promptly_with 'verify promptly REFUSES a FIFO bundle member' 'ledger bundle contains a non-regular file' 3 "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$NONREGULAR"

echo 'T6 replica bytes are compared before replica-controlled code can execute'
ORDERING="$TMP/ordering-replica"
ORDERING_PROOF="$TMP/replica-code-ran"
check_ok 'snapshot CREATES an ordering fixture bundle' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$ORDERING"
printf '%s\n' '#!/usr/bin/env bash' "touch '$ORDERING_PROOF'" 'exit 0' > "$ORDERING/fm-sovereign-ledger.sh"
chmod +x "$ORDERING/fm-sovereign-ledger.sh"
check_fails 'verify REFUSES a changed replica verifier' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$ORDERING"
if [ ! -e "$ORDERING_PROOF" ]; then ok 'changed replica verifier never executed'; else bad 'changed replica verifier executed before byte comparison'; fi

echo 'T7 divergence and extra files are detected and never repaired'
printf 'tamper\n' >> "$REPLICA/CONTRACT.md"
check_fails 'verify FAILS when replica contract bytes diverge' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"
check_fails 'snapshot REFUSES to overwrite a divergent replica' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$REPLICA"
cp "$PRIMARY/CONTRACT.md" "$REPLICA/CONTRACT.md"
printf 'planted\n' > "$REPLICA/EXTRA-CONTRACT.md"
check_fails_with 'verify REFUSES an unexpected replica file' 'ledger bundle manifest differs from the exact required names' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"
unlink "$REPLICA/EXTRA-CONTRACT.md"
check_ok 'verify PASSES after fixture restore' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$REPLICA"

echo 'T8 an invalid primary is never copied'
INVALID="$TMP/invalid-primary"
mkdir -p "$INVALID"
cp "$PRIMARY"/* "$INVALID/"
sed -i.bak '1s/ruling-1/not-a-ruling/' "$INVALID/ledger.tsv"
unlink "$INVALID/ledger.tsv.bak"
INVALID_REPLICA="$TMP/invalid-replica"
check_fails 'snapshot REFUSES a primary rejected by its own verifier' "$SAME_VOLUME_TOOL" snapshot "$INVALID" "$INVALID_REPLICA"
if [ ! -e "$INVALID_REPLICA" ]; then ok 'rejected primary leaves no replica directory behind'; else bad 'rejected primary wrote a replica directory'; fi

echo 'T9 the st_dev predicate is portable and fail-closed'
IDENTITY_PRIMARY="$TMP/identity-primary"
IDENTITY_REPLICA="$TMP/identity-replica"
IDENTITY_STAT_BIN="$TMP/identity-stat-bin"
check_ok 'snapshot CREATES an identity-check fixture bundle' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$IDENTITY_PRIMARY"
check_ok 'snapshot CREATES an identity-check replica bundle' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$IDENTITY_REPLICA"
mkdir "$IDENTITY_STAT_BIN"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'target="${!#}"' \
  'case "$target" in' \
  '  *identity-primary|*identity-primary/*) side=primary ;;' \
  '  *identity-replica|*identity-replica/*) side=replica ;;' \
  '  *) exit 70 ;;' \
  'esac' \
  'case "$*" in' \
  '  *%d:%i*) if [ "$side" = primary ]; then printf "1:101\\n"; else printf "2:202\\n"; fi ;;' \
  '  *%d*)' \
  '    case "${IDENTITY_MODE:-}" in' \
  '      same) printf "1\\n" ;;' \
  '      distinct) if [ "$side" = primary ]; then printf "1\\n"; else printf "2\\n"; fi ;;' \
  '      invalid) printf "not-a-device\\n" ;;' \
  '      *) exit 71 ;;' \
  '    esac ;;' \
  '  *) exit 72 ;;' \
  'esac' > "$IDENTITY_STAT_BIN/stat"
chmod +x "$IDENTITY_STAT_BIN/stat"
check_fails_with 'verify REFUSES equal numeric st_dev identities' 'primary and replica must be on different devices' env PATH="$IDENTITY_STAT_BIN:$PATH" IDENTITY_MODE=same "$TOOL" verify "$IDENTITY_PRIMARY" "$IDENTITY_REPLICA"
check_ok 'verify ACCEPTS distinct numeric st_dev identities' env PATH="$IDENTITY_STAT_BIN:$PATH" IDENTITY_MODE=distinct "$TOOL" verify "$IDENTITY_PRIMARY" "$IDENTITY_REPLICA"
check_fails_with 'verify REFUSES a nonnumeric st_dev identity' 'could not establish primary st_dev identity' env PATH="$IDENTITY_STAT_BIN:$PATH" IDENTITY_MODE=invalid "$TOOL" verify "$IDENTITY_PRIMARY" "$IDENTITY_REPLICA"

echo 'T10 hard links fall to the one device predicate by default'
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  hardlink_replica="$TMP/hardlink-$entry"
  check_ok "snapshot CREATES a $entry hard-link fixture" "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$hardlink_replica"
  unlink "$hardlink_replica/$entry"
  ln "$PRIMARY/$entry" "$hardlink_replica/$entry"
  check_fails_with "verify REFUSES a same-device pair containing hard-linked $entry" 'primary and replica must be on different devices' "$TOOL" verify "$PRIMARY" "$hardlink_replica"
done

if [ "${FM_MUTATION_RUN:-0}" != 1 ]; then
echo 'T11 adversarial ledger paths certify real copies that survive primary destruction'
exercise_destruction_shape() {
  local label=$1 component=$2 root primary replica sources expected member number all_members all_rulings
  root="$TMP/adversarial-paths/$component"
  primary="$root/primary"
  replica="$root/replica"
  sources="$TMP/adversarial-sources/$label"
  expected="$TMP/adversarial-expected/$label"
  make_bundle "$primary" "$sources"
  mkdir -p "$expected"
  for member in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
    cp -p "$primary/$member" "$expected/$member"
  done
  check_ok "snapshot CREATES an independent replica under a $label path" "$SAME_VOLUME_TOOL" snapshot "$primary" "$replica"
  check_ok "verify CERTIFIES the independent replica under a $label path" "$SAME_VOLUME_TOOL" verify "$primary" "$replica"
  rm -rf -- "$primary"
  all_members=true
  for member in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
    if ! cmp -s "$expected/$member" "$replica/$member"; then all_members=false; fi
  done
  if "$all_members"; then
    ok "all four bundle members survive primary destruction under a $label path"
  else
    bad "a bundle member did not survive primary destruction under a $label path"
  fi
  all_rulings=true
  for number in 1 2 3 4; do
    if ! diff -q <(LEDGER_DIR="$replica" "$replica/fm-sovereign-ledger.sh" text "ruling-$number") "$sources/ruling-$number.md" >/dev/null 2>&1; then
      all_rulings=false
    fi
  done
  if "$all_rulings"; then
    ok "all four rulings remain byte-exact under a $label path"
  else
    bad "a ruling was not byte-exact after primary destruction under a $label path"
  fi
}

exercise_destruction_shape 'hash' 'Ledger #1'
exercise_destruction_shape 'unterminated bracket' 'Ledger [1'
exercise_destruction_shape 'space' 'Ledger space'
exercise_destruction_shape 'newline' $'Ledger\nnewline'
exercise_destruction_shape 'unicode' 'Ledger-船长-⚓'
fi

echo 'T12 the instrument distinguishes independent and non-independent replicas'
CONTROL_ROOT="$TMP/control #ledger"
CONTROL_PRIMARY="$CONTROL_ROOT/primary"
CONTROL_REPLICA="$CONTROL_ROOT/replica"
make_bundle "$CONTROL_PRIMARY" "$CONTROL_ROOT/sources"
mkdir -p "$CONTROL_REPLICA"
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  ln -s "$CONTROL_PRIMARY/$entry" "$CONTROL_REPLICA/$entry"
done
check_fails_with 'positive control REFUSES a fully symlinked replica under a hash path' 'ledger bundle contains a symlink' "$SAME_VOLUME_TOOL" verify "$CONTROL_PRIMARY" "$CONTROL_REPLICA"

echo 'T13 containment is an explicit property'
CONTAINED_PRIMARY="$TMP/containment-primary"
CONTAINED_REPLICA="$CONTAINED_PRIMARY/replica"
make_bundle "$CONTAINED_PRIMARY" "$TMP/containment-sources"
mkdir -p "$CONTAINED_REPLICA"
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  cp -p "$CONTAINED_PRIMARY/$entry" "$CONTAINED_REPLICA/$entry"
done
check_fails_with 'verify REFUSES a replica contained by the primary explicitly' 'primary and replica directories must not contain one another' "$SAME_VOLUME_TOOL" verify "$CONTAINED_PRIMARY" "$CONTAINED_REPLICA"
rm -rf -- "$CONTAINED_REPLICA"
check_fails_with 'snapshot REFUSES a replica target contained by the primary explicitly' 'primary and replica directories must not contain one another' "$SAME_VOLUME_TOOL" snapshot "$CONTAINED_PRIMARY" "$CONTAINED_REPLICA"
OUTER_REPLICA="$TMP/outer-replica"
INNER_PRIMARY="$OUTER_REPLICA/primary"
make_bundle "$OUTER_REPLICA" "$TMP/outer-sources"
make_bundle "$INNER_PRIMARY" "$TMP/inner-sources"
check_fails_with 'verify REFUSES a primary contained by the replica explicitly' 'primary and replica directories must not contain one another' "$SAME_VOLUME_TOOL" verify "$INNER_PRIMARY" "$OUTER_REPLICA"

echo 'T14 st_dev reads are fail-closed under BSD and GNU stat semantics'
DIALECT_PRIMARY="$TMP/dialect-primary"
DIALECT_REPLICA="$TMP/dialect-replica"
DIALECT_STAT_BIN="$TMP/dialect-stat-bin"
check_ok 'snapshot CREATES a stat-dialect primary fixture' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$DIALECT_PRIMARY"
check_ok 'snapshot CREATES a stat-dialect replica fixture' "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$DIALECT_REPLICA"
mkdir "$DIALECT_STAT_BIN"
cat > "$DIALECT_STAT_BIN/stat" <<'STAT_STUB'
#!/usr/bin/env bash
set -euo pipefail
emit_identity() {
  local format=$1 target=$2 device inode
  case "$target" in
    *dialect-primary|*dialect-primary/*) device=11; inode=101 ;;
    *dialect-replica|*dialect-replica/*) device=22; inode=202 ;;
    *) exit 70 ;;
  esac
  case "$format" in
    %d) printf '%s\n' "$device" ;;
    %d:%i) printf '%s:%s\n' "$device" "$inode" ;;
    *) exit 71 ;;
  esac
}
case "${STAT_FLAVOUR:-}" in
  bsd)
    if [ "$#" -eq 3 ] && [ "$1" = -f ]; then
      emit_identity "$2" "$3"
    elif [ "$#" -eq 4 ] && [ "$1" = -L ] && [ "$2" = -f ]; then
      emit_identity "$3" "$4"
    else
      exit 64
    fi
    ;;
  gnu)
    if { [ "$#" -eq 3 ] && [ "$1" = -f ]; } || { [ "$#" -eq 4 ] && [ "$1" = -L ] && [ "$2" = -f ]; }; then
      printf '  File: "%s"\n' "${!#}"
      exit 1
    elif [ "$#" -eq 3 ] && [ "$1" = -c ]; then
      emit_identity "$2" "$3"
    elif [ "$#" -eq 4 ] && [ "$1" = -L ] && [ "$2" = -c ]; then
      emit_identity "$3" "$4"
    else
      exit 64
    fi
    ;;
  invalid)
    printf 'identity unavailable for %s\n' "${!#}"
    ;;
  *) exit 65 ;;
esac
STAT_STUB
chmod +x "$DIALECT_STAT_BIN/stat"
for flavour in bsd gnu; do
  check_ok "verify PASSES distinct st_dev identities with $flavour stat semantics" env PATH="$DIALECT_STAT_BIN:$PATH" STAT_FLAVOUR="$flavour" "$TOOL" verify "$DIALECT_PRIMARY" "$DIALECT_REPLICA"
done
check_fails_with 'verify REFUSES when stat cannot establish a numeric st_dev identity' 'could not establish primary st_dev identity' env PATH="$DIALECT_STAT_BIN:$PATH" STAT_FLAVOUR=invalid "$TOOL" verify "$DIALECT_PRIMARY" "$DIALECT_REPLICA"

echo 'T15 the complete replica and primary device sets must be disjoint'
CROSS_PRIMARY="$TMP/cross-primary"
CROSS_REPLICA="$TMP/cross-replica"
make_bundle "$CROSS_PRIMARY" "$TMP/cross-sources"
cp "$CROSS_PRIMARY/CONTRACT.md" "$CROSS_PRIMARY/tests.sh"
chmod +x "$CROSS_PRIMARY/tests.sh"
check_ok 'snapshot CREATES a cross-member identity fixture' "$SAME_VOLUME_TOOL" snapshot "$CROSS_PRIMARY" "$CROSS_REPLICA"
unlink "$CROSS_REPLICA/CONTRACT.md"
ln "$CROSS_PRIMARY/tests.sh" "$CROSS_REPLICA/CONTRACT.md"
check_fails_with 'verify REFUSES cross-member shared storage by the device predicate' 'primary and replica must be on different devices' "$TOOL" verify "$CROSS_PRIMARY" "$CROSS_REPLICA"

echo 'T16 round 5 attacks replace the independence predicate rather than extending it'
R5_PRIMARY="$TMP/r5-primary"
R5_COPY="$TMP/r5-copy"
make_bundle "$R5_PRIMARY" "$TMP/r5-sources"
mkdir "$R5_COPY"
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  cp -p "$R5_PRIMARY/$entry" "$R5_COPY/$entry"
done
check_fails_with 'verify REFUSES a same-volume real copy by default' 'primary and replica must be on different devices' "$TOOL" verify "$R5_PRIMARY" "$R5_COPY"
check_ok 'verify explicit opt-out ACCEPTS a same-volume real copy' "$TOOL" --allow-same-volume-without-device-redundancy verify "$R5_PRIMARY" "$R5_COPY"

if cp -c "$R5_PRIMARY/CONTRACT.md" "$TMP/r5-clone-probe" 2>/dev/null; then
  R5_CLONE="$TMP/r5-clone"
  mkdir "$R5_CLONE"
  for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
    cp -c "$R5_PRIMARY/$entry" "$R5_CLONE/$entry"
  done
  check_fails_with 'verify REFUSES an APFS clone bundle by the device predicate' 'primary and replica must be on different devices' "$TOOL" verify "$R5_PRIMARY" "$R5_CLONE"
else
  not_verifiable 'APFS clone attack: cp -c is unavailable on this filesystem; no nearby copy case substituted'
fi

R5_BIND_TARGET="$TMP/r5-bind-target"
mkdir "$R5_BIND_TARGET"
bind_mount_target=$R5_BIND_TARGET
if mount --bind "$R5_PRIMARY" "$R5_BIND_TARGET" >/dev/null 2>&1 \
  || mount -t nullfs "$R5_PRIMARY" "$R5_BIND_TARGET" >/dev/null 2>&1; then
  bind_mount_active=1
  check_fails_with 'verify REFUSES a bind-mounted replica by the admitted identity set' 'shares storage with primary' \
    "$TOOL" --allow-same-volume-without-device-redundancy verify "$R5_PRIMARY" "$R5_BIND_TARGET"
  if umount "$R5_BIND_TARGET" >/dev/null 2>&1; then
    bind_mount_active=0
  else
    bad 'bind-mount fixture could not be detached; scratch will be retained without recursive deletion'
  fi
else
  not_verifiable 'bind-mount attack: this host grants no unprivileged bind or nullfs mount; no nearby mount case substituted'
fi

R5_DIRECTORY_HARDLINK="$TMP/r5-directory-hardlink"
if ln "$R5_PRIMARY" "$R5_DIRECTORY_HARDLINK" >/dev/null 2>&1; then
  directory_hardlink_active=1
  directory_hardlink_target=$R5_DIRECTORY_HARDLINK
  check_fails_with 'verify REFUSES a directory hard link by the admitted directory identity' 'primary and replica directories must differ' \
    "$TOOL" --allow-same-volume-without-device-redundancy verify "$R5_PRIMARY" "$R5_DIRECTORY_HARDLINK"
  if unlink "$R5_DIRECTORY_HARDLINK" >/dev/null 2>&1; then
    directory_hardlink_active=0
  else
    bad 'directory-hard-link fixture could not be unlinked; scratch will be retained without recursive deletion'
  fi
else
  not_verifiable 'directory-hard-link attack: this host refuses unprivileged directory hard-link creation; no symlink case substituted'
fi

not_verifiable 'firmlink attack: this host exposes no unprivileged fixture-creation API for OS-managed firmlinks; no symlink case substituted'

R5_CASE="$TMP/r5-case"
mkdir "$R5_CASE"
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  cp -p "$R5_PRIMARY/$entry" "$R5_CASE/$entry"
done
mv "$R5_CASE/CONTRACT.md" "$R5_CASE/contract.md"
check_fails_with 'verify REFUSES a case-folded manifest collision by its real entry name' 'ledger bundle manifest differs from the exact required names' "$TOOL" --allow-same-volume-without-device-redundancy verify "$R5_PRIMARY" "$R5_CASE"

R5_TRAVERSAL="$R5_PRIMARY/../r5-primary"
check_fails_with 'verify REFUSES dot-dot traversal that resolves to the primary itself' 'primary and replica directories must differ' "$TOOL" --allow-same-volume-without-device-redundancy verify "$R5_PRIMARY" "$R5_TRAVERSAL"
R5_PARENT_ALIAS="$TMP/r5-primary-parent-alias"
ln -s "$TMP" "$R5_PARENT_ALIAS"
check_fails_with 'verify REFUSES a replica path symlinked to the primary parent' 'primary and replica directories must not contain one another' "$TOOL" --allow-same-volume-without-device-redundancy verify "$R5_PRIMARY" "$R5_PARENT_ALIAS"

R5_REFRESH="$TMP/r5-refresh"
mkdir "$R5_REFRESH"
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  cp -p "$R5_PRIMARY/$entry" "$R5_REFRESH/$entry"
done
head -n 3 "$R5_PRIMARY/ledger.tsv" > "$R5_REFRESH/ledger.tsv"
unlink "$R5_REFRESH/tests.sh"
ln "$R5_PRIMARY/tests.sh" "$R5_REFRESH/tests.sh"
R5_REFRESH_BEFORE=$(cat "$R5_REFRESH/ledger.tsv")
check_fails_with 'refresh REFUSES a same-device pair before publication' 'primary and replica must be on different devices' "$TOOL" refresh "$R5_PRIMARY" "$R5_REFRESH"
if [ "$(cat "$R5_REFRESH/ledger.tsv")" = "$R5_REFRESH_BEFORE" ]; then
  ok 'refresh refusal leaves the rejected replica byte-exactly unchanged'
else
  bad 'refresh wrote ledger.tsv before refusing the pair'
fi

R5_NONREGULAR="$TMP/r5-nonregular-after-classification"
mkdir "$R5_NONREGULAR"
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  cp -p "$R5_PRIMARY/$entry" "$R5_NONREGULAR/$entry"
done
R5_FIND_BIN="$TMP/r5-find-bin"
mkdir "$R5_FIND_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '  /usr/bin/find "$@"' \
  'case "$1" in' \
  '*/r5-nonregular-after-classification)' \
  '  if [ ! -e "$R5_SWAP_MARKER" ]; then' \
  '    : > "$R5_SWAP_MARKER"' \
  '    rm -f "$R5_SWAP_DIR/tests.sh"' \
  '    mkdir "$R5_SWAP_DIR/tests.sh"' \
  '  fi ;;' \
  'esac' > "$R5_FIND_BIN/find"
chmod +x "$R5_FIND_BIN/find"
check_fails_with 'verify reclassifies a non-regular member appearing after enumeration' 'ledger bundle contains a non-regular file' env PATH="$R5_FIND_BIN:$PATH" R5_SWAP_DIR="$R5_NONREGULAR" R5_SWAP_MARKER="$TMP/r5-swap-done" "$TOOL" --allow-same-volume-without-device-redundancy verify "$R5_PRIMARY" "$R5_NONREGULAR"

echo 'T17 snapshot publication is bound to the destination created exclusively by admission'
R5_TOC_PRIMARY="$TMP/r5-toc-primary"
R5_TOC_DEST="$TMP/r5-toc-destination"
R5_TOC_OUTSIDE="$TMP/r5-toc-outside"
R5_TOC_READY="$TMP/r5-toc-ready"
R5_TOC_COUNT="$TMP/r5-toc-count"
R5_TOC_REAL="$TMP/r5-toc-real-verifier"
R5_TOC_OUTPUT="$TMP/r5-toc-output"
make_bundle "$R5_TOC_PRIMARY" "$TMP/r5-toc-sources"
mkdir "$R5_TOC_OUTSIDE"
cp -p "$R5_TOC_PRIMARY/fm-sovereign-ledger.sh" "$R5_TOC_REAL"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'count=0' \
  '[ ! -e "$R5_TOC_COUNT" ] || count=$(cat "$R5_TOC_COUNT")' \
  'count=$((count + 1))' \
  'printf "%s\\n" "$count" > "$R5_TOC_COUNT"' \
  'if [ "$count" -eq 2 ]; then' \
  '  : > "$R5_TOC_READY"' \
  '  sleep 1' \
  'fi' \
  'exec "$R5_TOC_REAL" "$@"' > "$R5_TOC_PRIMARY/fm-sovereign-ledger.sh"
chmod +x "$R5_TOC_PRIMARY/fm-sovereign-ledger.sh"
set +e
env R5_TOC_COUNT="$R5_TOC_COUNT" R5_TOC_READY="$R5_TOC_READY" R5_TOC_REAL="$R5_TOC_REAL" \
  "$TOOL" --allow-same-volume-without-device-redundancy snapshot "$R5_TOC_PRIMARY" "$R5_TOC_DEST" > "$R5_TOC_OUTPUT" 2>&1 &
R5_TOC_PID=$!
set -e
R5_TOC_ATTEMPT=0
while [ ! -e "$R5_TOC_READY" ] && [ "$R5_TOC_ATTEMPT" -lt 100 ]; do
  sleep 0.02
  R5_TOC_ATTEMPT=$((R5_TOC_ATTEMPT + 1))
done
if [ ! -e "$R5_TOC_DEST" ] && [ ! -L "$R5_TOC_DEST" ]; then
  ln -s "$R5_TOC_OUTSIDE" "$R5_TOC_DEST"
fi
set +e
wait "$R5_TOC_PID"
R5_TOC_STATUS=$?
set -e
if [ "$R5_TOC_STATUS" -eq 0 ] && [ -d "$R5_TOC_DEST" ] && [ ! -L "$R5_TOC_DEST" ] \
  && [ -f "$R5_TOC_DEST/ledger.tsv" ] && [ -z "$(find "$R5_TOC_OUTSIDE" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  ok 'snapshot race cannot redirect publication outside its admitted destination'
else
  R5_TOC_DIAGNOSTIC=$(cat "$R5_TOC_OUTPUT")
  bad "snapshot publication race escaped admission (status=$R5_TOC_STATUS; output: ${R5_TOC_DIAGNOSTIC//$'\n'/ | })"
fi

echo 'T18 same-volume waiver preserves member independence and snapshot failure boundaries'
for entry in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh tests.sh; do
  waived_hardlink_replica="$TMP/waived-hardlink-$entry"
  check_ok "snapshot CREATES a waived $entry hard-link fixture" "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$waived_hardlink_replica"
  unlink "$waived_hardlink_replica/$entry"
  ln "$PRIMARY/$entry" "$waived_hardlink_replica/$entry"
  check_fails_with "same-volume waiver REFUSES a hard-linked $entry" 'shares storage with primary' "$SAME_VOLUME_TOOL" verify "$PRIMARY" "$waived_hardlink_replica"
done

WAIVED_CROSS_PRIMARY="$TMP/waived-cross-primary"
WAIVED_CROSS_REPLICA="$TMP/waived-cross-replica"
make_bundle "$WAIVED_CROSS_PRIMARY" "$TMP/waived-cross-sources"
cp "$WAIVED_CROSS_PRIMARY/CONTRACT.md" "$WAIVED_CROSS_PRIMARY/tests.sh"
chmod +x "$WAIVED_CROSS_PRIMARY/tests.sh"
check_ok 'snapshot CREATES a waived cross-member fixture' "$SAME_VOLUME_TOOL" snapshot "$WAIVED_CROSS_PRIMARY" "$WAIVED_CROSS_REPLICA"
unlink "$WAIVED_CROSS_REPLICA/CONTRACT.md"
ln "$WAIVED_CROSS_PRIMARY/tests.sh" "$WAIVED_CROSS_REPLICA/CONTRACT.md"
check_fails_with 'same-volume waiver REFUSES cross-member shared storage' 'replica CONTRACT.md shares storage with primary tests.sh' "$SAME_VOLUME_TOOL" verify "$WAIVED_CROSS_PRIMARY" "$WAIVED_CROSS_REPLICA"

PREFLIGHT_STAT_BIN="$TMP/preflight-stat-bin"
PREFLIGHT_DEST="$TMP/preflight-stat-replica"
mkdir "$PREFLIGHT_STAT_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  *%d:%i*) exit 75 ;;' \
  '  *%d*) printf "1\\n" ;;' \
  '  *) exit 76 ;;' \
  'esac' > "$PREFLIGHT_STAT_BIN/stat"
chmod +x "$PREFLIGHT_STAT_BIN/stat"
check_fails_with 'snapshot REFUSES unsupported directory identity before destination creation' 'could not establish replica parent directory identity before creation' env PATH="$PREFLIGHT_STAT_BIN:$PATH" "$TOOL" --allow-same-volume-without-device-redundancy snapshot "$PRIMARY" "$PREFLIGHT_DEST"
if [ ! -e "$PREFLIGHT_DEST" ] && [ ! -L "$PREFLIGHT_DEST" ]; then
  ok 'directory identity preflight leaves no replica destination'
else
  bad 'directory identity preflight created a replica destination'
fi

PARTIAL_PERL_BIN="$TMP/partial-perl-bin"
PARTIAL_DEST="$TMP/retained-partial-replica"
mkdir "$PARTIAL_PERL_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 77' > "$PARTIAL_PERL_BIN/perl"
chmod +x "$PARTIAL_PERL_BIN/perl"
check_fails_with 'snapshot identifies a retained partial after post-creation copy failure' 'partial replica retained without deletion' env PATH="$PARTIAL_PERL_BIN:$PATH" "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$PARTIAL_DEST"
if [ -d "$PARTIAL_DEST" ] && [ ! -L "$PARTIAL_DEST" ]; then
  ok 'post-creation failure retains the partial replica directory'
else
  bad 'post-creation failure deleted or replaced the partial replica directory'
fi

SIGNAL_MKDIR_BIN="$TMP/signal-mkdir-bin"
SIGNAL_DEST="$TMP/signal-partial-replica"
SIGNAL_READY="$TMP/signal-mkdir-ready"
SIGNAL_OUTPUT="$TMP/signal-output"
REAL_MKDIR=$(command -v mkdir)
mkdir "$SIGNAL_MKDIR_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '"$REAL_MKDIR" "$@"' \
  ': > "$SIGNAL_READY"' \
  'sleep 0.1' > "$SIGNAL_MKDIR_BIN/mkdir"
chmod +x "$SIGNAL_MKDIR_BIN/mkdir"
set +e
env PATH="$SIGNAL_MKDIR_BIN:$PATH" REAL_MKDIR="$REAL_MKDIR" SIGNAL_READY="$SIGNAL_READY" \
  "$SAME_VOLUME_TOOL" snapshot "$PRIMARY" "$SIGNAL_DEST" > "$SIGNAL_OUTPUT" 2>&1 &
SIGNAL_PID=$!
set -e
SIGNAL_ATTEMPT=0
while [ ! -e "$SIGNAL_READY" ] && [ "$SIGNAL_ATTEMPT" -lt 100 ]; do
  sleep 0.02
  SIGNAL_ATTEMPT=$((SIGNAL_ATTEMPT + 1))
done
if [ -e "$SIGNAL_READY" ]; then kill -TERM "$SIGNAL_PID"; fi
set +e
wait "$SIGNAL_PID"
SIGNAL_STATUS=$?
set -e
if [ "$SIGNAL_STATUS" -eq 143 ] \
  && grep -Fq 'partial replica retained or may exist without deletion' "$SIGNAL_OUTPUT"; then
  ok 'TERM reports the retained or possibly-created replica destination'
else
  SIGNAL_DIAGNOSTIC=$(cat "$SIGNAL_OUTPUT")
  bad "TERM did not report its non-deleting snapshot boundary (status=$SIGNAL_STATUS; output: ${SIGNAL_DIAGNOSTIC//$'\n'/ | })"
fi
if [ -d "$SIGNAL_DEST" ] && [ ! -L "$SIGNAL_DEST" ]; then
  ok 'TERM leaves the created partial replica directory in place'
else
  bad 'TERM deleted or replaced the created partial replica directory'
fi

printf '\n%s passed, %s failed, %s not verifiable\n' "$pass" "$fail" "$not_verifiable"
[ "$fail" -eq 0 ]
