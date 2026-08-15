#!/usr/bin/env bash
# Run the owned mutation population for sovereign-ledger redundancy enforcement.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/bin/fm-sovereign-ledger-redundancy.sh"
TEST="$ROOT/tests/fm-sovereign-ledger-redundancy.test.sh"
EVIDENCE=
if [ "${1:-}" = --write-evidence ]; then
  [ "$#" -eq 2 ] || { printf 'usage: %s [--write-evidence <path>]\n' "$0" >&2; exit 2; }
  EVIDENCE=$2
elif [ "$#" -ne 0 ]; then
  printf 'usage: %s [--write-evidence <path>]\n' "$0" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
RESULTS="$TMP/results.tsv"
killed=0
survived=0
void=0
denominator=0

apply_mutation() {
  local target=$1 line=$2 from=$3 to=$4 count_file=$5
  LINE_NUMBER=$line FROM_TEXT=$from TO_TEXT=$to COUNT_FILE=$count_file perl -0pi -e '
    BEGIN {
      $line_number = $ENV{LINE_NUMBER};
      $from = $ENV{FROM_TEXT};
      $to = $ENV{TO_TEXT};
      $count_file = $ENV{COUNT_FILE};
    }
    @lines = split(/(?<=\n)/, $_, -1);
    $line = $lines[$line_number - 1] // "";
    $count = 0;
    $offset = 0;
    while (($found = index($line, $from, $offset)) >= 0) {
      $count++;
      $offset = $found + length($from);
    }
    if ($count == 1) {
      $line =~ s/\Q$from\E/$to/;
      $lines[$line_number - 1] = $line;
      $_ = join("", @lines);
    }
    open(my $fh, ">", $count_file) or die $!;
    print {$fh} "$count\n";
    close($fh) or die $!;
  ' "$target"
}

run_mutation_test() {
  local target=$1 output=$2
  TOOL=$target perl -e '
    my $timeout = shift;
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $timeout;
    waitpid $pid, 0;
    alarm 0;
    exit($? >> 8);
  ' 30 "$TEST" >"$output" 2>&1
}

mutant() {
  local id=$1 anchor=$2 line=$3 from=$4 to=$5 claim=$6 target count_file count outcome status
  denominator=$((denominator + 1))
  target="$TMP/$id.sh"
  count_file="$TMP/$id.count"
  cp "$SOURCE" "$target"
  apply_mutation "$target" "$line" "$from" "$to" "$count_file"
  count=$(cat "$count_file")
  if [ "$count" -ne 1 ]; then
    outcome=VOID
    status=-
    void=$((void + 1))
  else
    set +e
    run_mutation_test "$target" "$TMP/$id.out"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      outcome=SURVIVED
      survived=$((survived + 1))
    else
      outcome=KILLED
      killed=$((killed + 1))
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$anchor" "$count" "$outcome" "$status" "$claim" >> "$RESULTS"
  printf '%s %s substitutions=%s status=%s\n' "$id" "$outcome" "$count" "$status"
}

mutant M001 strict-mode.errexit 14 'set -euo pipefail' 'set -uo pipefail' 'Shell failures are not allowed to fall through.'
mutant M002 manifest.denominator 16 'BUNDLE_MEMBER_COUNT=4' 'BUNDLE_MEMBER_COUNT=5' 'The owned bundle denominator is exactly four.'
mutant M003 canonical.directory-exists 30 '|| die "ledger directory does not exist: $1"' '|| :' 'Only an existing ledger directory can be canonicalized.'
mutant M004 canonical.physical-path 33 'pwd -P' 'pwd -L' 'Containment uses physical directory paths.'
mutant M005 manifest.fourth-member 38 'tests.sh' 'tests.missing' 'tests.sh is a required manifest member.'
mutant M006 enumeration.minimum-depth 43 '-mindepth 1' '-mindepth 2' 'Every top-level member is counted.'
mutant M007 enumeration.maximum-depth 43 '-maxdepth 1' '-maxdepth 2' 'Only top-level members are counted.'
mutant M008 enumeration.record-per-entry 44 'printf "x\n"' ':' 'Enumeration records every discovered entry.'
mutant M009 enumeration.line-denominator 45 'wc -l' 'wc -c' 'Enumeration counts records rather than bytes.'
mutant M010 enumeration.exact-count 49 'die "ledger bundle must contain exactly $BUNDLE_MEMBER_COUNT manifest members, found $count: $dir"' ':' 'Enumeration accepts only the owned denominator.'
mutant M011 enumeration.known-manifest 50 'BUNDLE_ENTRIES=$(bundle_manifest)' 'BUNDLE_ENTRIES=' 'Enumeration resets to the exact known manifest.'
mutant M012 require.known-manifest 55 'BUNDLE_ENTRIES=$(bundle_manifest)' 'BUNDLE_ENTRIES=' 'Bundle validation starts from the known manifest.'
mutant M013 require.member-exists 57 '|| die "ledger bundle is incomplete: missing $dir/$entry"' '|| :' 'Every known manifest member must exist.'
mutant M014 require.no-symlink 58 '&& die "ledger bundle contains a symlink: $dir/$entry"' '&& :' 'A manifest member cannot be a symlink.'
mutant M015 require.regular-file 59 '|| die "ledger bundle contains a non-regular file: $dir/$entry"' '|| :' 'Every manifest member must be a regular file.'
mutant M016 require.read-denominator 60 '+ 1' '+ 0' 'Every manifest member contributes to the read denominator.'
mutant M017 require.enumerates-directory 62 'collect_bundle_entries "$dir"' ':' 'Bundle validation independently enumerates the directory.'
mutant M018 require.exact-read-count 64 'die "ledger bundle manifest check read $checked of $BUNDLE_MEMBER_COUNT members: $dir"' ':' 'The manifest read count must equal four.'
mutant M019 require.executable-verifier 65 '|| die "ledger verifier is not executable: $dir/fm-sovereign-ledger.sh"' '|| :' 'The ledger verifier must be executable.'
mutant M020 layout.enumerate-primary 70 'collect_bundle_entries "$primary"' ':' 'Layout comparison enumerates the primary independently.'
mutant M021 layout.capture-primary 71 'primary_entries=$BUNDLE_ENTRIES' 'primary_entries=' 'Layout comparison retains the primary manifest.'
mutant M022 layout.enumerate-replica 72 'collect_bundle_entries "$replica"' ':' 'Layout comparison enumerates the replica independently.'
mutant M023 layout.capture-replica 73 'replica_entries=$BUNDLE_ENTRIES' 'replica_entries=' 'Layout comparison retains the replica manifest.'
mutant M024 layout.equal-manifests 74 '|| die "replica bundle layout differs from primary"' '|| :' 'Primary and replica layouts must match.'
mutant M025 bytes.enumerate-primary 79 'collect_bundle_entries "$primary"' ':' 'Byte comparison owns a fresh manifest enumeration.'
mutant M026 bytes.skip-denominator 80 '- 1' '- 0' 'Skipping ledger.tsv reduces the required read denominator once.'
mutant M027 bytes.skip-only-selected 82 '&&' '||' 'Only the explicitly skipped member bypasses comparison.'
mutant M028 bytes.quiet-compare 83 'cmp -s' 'cmp' 'Member comparison uses cmp status as its verdict.'
mutant M029 bytes.reject-difference 84 'die "replica differs from primary: $entry"' ':' 'Any compared member byte difference is refused.'
mutant M030 bytes.read-denominator 85 '+ 1' '+ 0' 'Each compared member contributes to the read denominator.'
mutant M031 bytes.exact-read-count 88 'die "byte comparison read $compared of $expected required bundle members"' ':' 'The byte-read count must equal its owned denominator.'
mutant M032 identity.follow-selection 93 '= true' '= false' 'Followed and non-followed identity reads select distinct stat modes.'
mutant M033 identity.bsd-follow 94 'stat -L -f' 'stat -f' 'BSD followed identity uses stat -L.'
mutant M034 identity.gnu-follow 96 'stat -L -c' 'stat -c' 'GNU followed identity uses stat -L.'
mutant M035 identity.bsd-lstat 101 'stat -f' 'stat -L -f' 'BSD non-followed identity uses lstat semantics.'
mutant M036 identity.gnu-lstat 103 'stat -c' 'stat -L -c' 'GNU non-followed identity uses lstat semantics.'
mutant M037 identity.numeric-shape 108 "'^[0-9]+:[0-9]+$'" "'.*'" 'Only a numeric device and inode pair is accepted.'
mutant M038 identity.lstat-wrapper 113 'false' 'true' 'The lstat wrapper requests non-followed identity.'
mutant M039 identity.stat-wrapper 117 'true' 'false' 'The stat wrapper requests followed identity.'
mutant M040 identity.enumerate-primary 124 'collect_bundle_entries "$primary"' ':' 'Identity verification enumerates the owned manifest independently.'
mutant M041 identity.primary-lstat-read 127 'file_lstat_identity' 'file_stat_identity' 'Every primary member has a non-followed identity read.'
mutant M042 identity.replica-lstat-read 129 'file_lstat_identity' 'file_stat_identity' 'Every replica member has a non-followed identity read.'
mutant M043 identity.primary-stat-read 131 'file_stat_identity' 'file_lstat_identity' 'Every primary member has a followed identity read.'
mutant M044 identity.replica-stat-read 133 'file_stat_identity' 'file_lstat_identity' 'Every replica member has a followed identity read.'
mutant M045 identity.read-denominator 139 '+ 1' '+ 0' 'Each identity-read member contributes to the denominator.'
mutant M046 identity.exact-read-count 142 'die "identity verification read $index of $BUNDLE_MEMBER_COUNT required bundle members"' ':' 'Identity reads must cover exactly four members.'
mutant M047 identity.replica-cross-product 143 '< BUNDLE_MEMBER_COUNT' '< 1' 'Every replica inode participates in the cross-product.'
mutant M048 identity.primary-cross-product 144 '< BUNDLE_MEMBER_COUNT' '< 1' 'Every primary inode participates in the cross-product.'
mutant M049 identity.lstat-disjoint 145 'if [ "${replica_lstats[$replica_index]}" = "${primary_lstats[$primary_index]}" ]; then' 'if false; then' 'No replica lstat identity may overlap a primary identity.'
mutant M050 identity.lstat-member-attribution 146 'if [ "${entries[$replica_index]}" = "${entries[$primary_index]}" ]; then' 'if false; then' 'Same-member lstat overlap is attributed precisely.'
mutant M051 identity.stat-disjoint 151 'if [ "${replica_stats[$replica_index]}" = "${primary_stats[$primary_index]}" ]; then' 'if false; then' 'No replica stat identity may overlap a primary identity.'
mutant M052 identity.stat-member-attribution 152 'if [ "${entries[$replica_index]}" = "${entries[$primary_index]}" ]; then' 'if false; then' 'Same-member stat overlap is attributed precisely.'
mutant M053 containment.distinct-paths 163 '[ "$primary" != "$replica" ] || die "primary and replica directories must differ"' ':' 'Primary and replica paths must differ.'
mutant M054 containment.primary-outside-replica 164 '"$replica/"*' '"$replica/never/"*' 'The primary cannot be contained by the replica.'
mutant M055 containment.replica-outside-primary 165 '"$primary/"*' '"$primary/never/"*' 'The replica cannot be contained by the primary.'
mutant M056 verifier.public-verify-command 170 'LEDGER_DIR="$subject" "$primary/fm-sovereign-ledger.sh" verify >/dev/null' ':' 'Bundle validity is established through the primary verifier.'
mutant M057 prefix.primary-line-count 176 'wc -l' 'wc -c' 'Prefix comparison measures primary ledger records.'
mutant M058 prefix.replica-line-count 177 'wc -l' 'wc -c' 'Prefix comparison measures replica ledger records.'
mutant M059 prefix.nonempty-replica 178 '[ "$replica_lines" -gt 0 ]' 'true' 'An empty replica is never an append-only prefix.'
mutant M060 prefix.strictly-shorter 179 '[ "$primary_lines" -gt "$replica_lines" ]' 'true' 'A prefix replica must be strictly shorter than primary.'
mutant M061 prefix.leading-bytes 180 'head -n' 'tail -n' 'Prefix comparison uses the leading primary records.'
mutant M062 preflight.require-primary 185 'require_bundle "$primary"' ':' 'Pair preflight validates the primary bundle.'
mutant M063 preflight.layout 187 'compare_layout "$primary" "$replica"' ':' 'Pair preflight compares the exact layouts.'
mutant M064 preflight.nonledger-bytes 188 'compare_files "$primary" "$replica" ledger.tsv' ':' 'Pair preflight compares replica-controlled code before execution.'
mutant M065 exact.all-bytes 194 'compare_files "$primary" "$replica"' 'compare_files "$primary" "$replica" ledger.tsv' 'Exact verification compares all four members.'
mutant M066 exact.disjoint-identities 195 'require_independent_bundle_files "$primary" "$replica"' ':' 'Exact verification requires disjoint inode sets.'
mutant M067 exact.verify-primary 196 'verify_with_primary "$primary" "$primary"' ':' 'Exact verification validates the primary ledger.'
mutant M068 exact.verify-replica 197 'verify_with_primary "$primary" "$replica"' ':' 'Exact verification validates replica ledger data.'
mutant M069 copy.enumerate-primary 203 'collect_bundle_entries "$primary"' ':' 'Copying starts from an independently enumerated manifest.'
mutant M070 copy.preserve-mode 205 'cp -p' 'cp' 'Bundle copying preserves required executable modes.'
mutant M071 copy.private-umask 202 'umask 077' 'umask 022' 'Bundle staging uses a private creation mask.'
mutant M072 copy.exact-read-count 209 'die "bundle copy read $copied of $BUNDLE_MEMBER_COUNT required members"' ':' 'Copying must cover exactly four members.'

[ "$denominator" -eq 72 ] || { printf 'invalid owned denominator: %s\n' "$denominator" >&2; exit 1; }

control="$TMP/CONTROL.sh"
control_count="$TMP/CONTROL.count"
cp "$SOURCE" "$control"
apply_mutation "$control" 2 'make, advance' 'make, advance' "$control_count"
control_substitutions=$(cat "$control_count")
set +e
run_mutation_test "$control" "$TMP/CONTROL.out"
control_status=$?
set -e
if [ "$control_substitutions" -eq 1 ] && [ "$control_status" -eq 0 ]; then
  control_outcome=SURVIVED
else
  control_outcome=FAILED
fi
printf 'CONTROL %s substitutions=%s status=%s\n' "$control_outcome" "$control_substitutions" "$control_status"

if [ -n "$EVIDENCE" ]; then
  case "$EVIDENCE" in /*) ;; *) EVIDENCE="$PWD/$EVIDENCE" ;; esac
  case "$EVIDENCE" in "$ROOT"/*) ;; *) printf 'evidence path must stay under %s\n' "$ROOT" >&2; exit 2 ;; esac
  {
    printf '# Sovereign ledger redundancy mutation evidence\n\n'
    printf 'Audience: maintainer verification.\n\n'
    printf 'Verified on 2026-08-15 against the R4 sovereign-ledger redundancy implementation.\n'
    printf 'The owned denominator is 72 enforcing clauses, ten more than round 3\047s 62 attempted mutants because R4 added exact enumeration and read denominators, portable BSD/GNU identity selection, containment rejection, and full cross-member inode-set enforcement.\n'
    printf 'Every run copied the implementation under one scoped `mktemp -d`; the live ledger, `data/`, and `state/` were never inputs or targets.\n\n'
    printf '```sh\n'
    printf 'tests/fm-sovereign-ledger-redundancy.mutation.sh --write-evidence docs/verification/sovereign-ledger-redundancy-mutation.md\n'
    printf '```\n\n'
    printf 'Observed summary: `killed=%s survived=%s void=%s denominator=%s`; the intentional no-op control recorded `substitutions=%s status=%s outcome=%s`.\n\n' "$killed" "$survived" "$void" "$denominator" "$control_substitutions" "$control_status" "$control_outcome"
    printf '| Mutant | Stable exact clause anchor | Substitutions | Outcome | Status | Unenforced claim when survived |\n'
    printf '| --- | --- | ---: | --- | ---: | --- |\n'
    while IFS=$'\t' read -r id anchor count outcome status claim; do
      if [ "$outcome" != SURVIVED ]; then claim=-; fi
      printf '| `%s` | `%s` | %s | %s | %s | %s |\n' "$id" "$anchor" "$count" "$outcome" "$status" "$claim"
    done < "$RESULTS"
  } > "$EVIDENCE"
fi

printf 'MUTATION SUMMARY killed=%s survived=%s void=%s denominator=%s\n' "$killed" "$survived" "$void" "$denominator"
[ "$void" -eq 0 ]
[ "$killed" -eq 47 ]
[ "$survived" -eq 25 ]
[ "$control_substitutions" -eq 1 ]
[ "$control_outcome" = SURVIVED ]
