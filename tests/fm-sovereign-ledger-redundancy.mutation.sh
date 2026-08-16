#!/usr/bin/env bash
# Run the owned mutation population for sovereign-ledger redundancy enforcement.
# Mutation anchors and Markdown code spans intentionally preserve shell expressions as literal data.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/bin/fm-sovereign-ledger-redundancy.sh"
TEST="$ROOT/tests/fm-sovereign-ledger-redundancy.test.sh"
EVIDENCE=
EMIT_EVIDENCE=0
VERIFY_EVIDENCE=0
REFRESH_EVIDENCE=0
MODE=mutation
EVIDENCE_FIXTURE=
EVIDENCE_SWAP_PATH=
EVIDENCE_SWAP_TARGET=
if [ "${1:-}" = --emit-evidence ]; then
  [ "$#" -eq 1 ] || { printf 'usage: %s [--emit-evidence|--refresh-evidence|--verify-evidence|--write-evidence <relative-path>|--self-test-evidence-containment|--self-test-evidence-fixture <id>]\n' "$0" >&2; exit 2; }
  EMIT_EVIDENCE=1
  exec 3>&1
  exec >&2
elif [ "${1:-}" = --refresh-evidence ]; then
  [ "$#" -eq 1 ] || { printf 'usage: %s [--emit-evidence|--refresh-evidence|--verify-evidence|--write-evidence <relative-path>|--self-test-evidence-containment|--self-test-evidence-fixture <id>]\n' "$0" >&2; exit 2; }
  REFRESH_EVIDENCE=1
elif [ "${1:-}" = --verify-evidence ]; then
  [ "$#" -eq 1 ] || { printf 'usage: %s [--emit-evidence|--refresh-evidence|--verify-evidence|--write-evidence <relative-path>|--self-test-evidence-containment|--self-test-evidence-fixture <id>]\n' "$0" >&2; exit 2; }
  VERIFY_EVIDENCE=1
elif [ "${1:-}" = --self-test-evidence-fixture ]; then
  [ "$#" -eq 2 ] || { printf 'usage: %s [--emit-evidence|--refresh-evidence|--verify-evidence|--write-evidence <relative-path>|--self-test-evidence-containment|--self-test-evidence-fixture <id>]\n' "$0" >&2; exit 2; }
  MODE=fixture
  EVIDENCE_FIXTURE=$2
elif [ "${1:-}" = --self-test-evidence-containment ]; then
  [ "$#" -eq 1 ] || { printf 'usage: %s [--emit-evidence|--refresh-evidence|--verify-evidence|--write-evidence <relative-path>|--self-test-evidence-containment|--self-test-evidence-fixture <id>]\n' "$0" >&2; exit 2; }
  MODE=containment
elif [ "${1:-}" = --write-evidence ]; then
  [ "$#" -eq 2 ] || { printf 'usage: %s [--emit-evidence|--refresh-evidence|--verify-evidence|--write-evidence <relative-path>|--self-test-evidence-containment|--self-test-evidence-fixture <id>]\n' "$0" >&2; exit 2; }
  EVIDENCE=$2
elif [ "$#" -ne 0 ]; then
  printf 'usage: %s [--emit-evidence|--refresh-evidence|--verify-evidence|--write-evidence <relative-path>|--self-test-evidence-containment|--self-test-evidence-fixture <id>]\n' "$0" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
RESULTS="$TMP/results.tsv"
killed=0
survived=0
void=0
harness_broken=0
denominator=0

evidence_refuse() {
  printf 'REFUSED: %s\n' "$*" >&2
  return 1
}

canonical_evidence_dir() {
  local path=$1 permit_prechecked_link=${2:-no}
  [ -d "$path" ] || return 1
  [ "$permit_prechecked_link" = yes ] || [ ! -L "$path" ] || return 1
  (
    cd -- "$path" 2>/dev/null
    pwd -P
  )
}

evidence_after_component_precheck() {
  local candidate=$1
  if [ -n "$EVIDENCE_SWAP_PATH" ] && [ "$candidate" = "$EVIDENCE_SWAP_PATH" ]; then
    rmdir -- "$candidate" || return 1
    ln -s "$EVIDENCE_SWAP_TARGET" "$candidate" || return 1
    EVIDENCE_SWAP_PATH=
  fi
}

evidence_validate_destination() {
  local scope_input=$1 relative=$2 scope cursor remaining component resolved leaf
  case "$relative" in /*) evidence_refuse "absolute evidence destination is forbidden: $relative"; return 1 ;; esac
  [ ! -L "$scope_input" ] \
    || { evidence_refuse "evidence scope is symlinked: $scope_input"; return 1; }
  scope=$(canonical_evidence_dir "$scope_input") \
    || { evidence_refuse "evidence scope is unresolved: $scope_input"; return 1; }
  cursor=$scope
  remaining=$relative
  while [[ "$remaining" == */* ]]; do
    component=${remaining%%/*}
    remaining=${remaining#*/}
    case "$component" in ''|.|..) evidence_refuse "unsafe evidence destination component: $relative"; return 1 ;; esac
    [ ! -L "$cursor/$component" ] \
      || { evidence_refuse "evidence destination has a symlinked parent: $relative"; return 1; }
    evidence_after_component_precheck "$cursor/$component" \
      || { evidence_refuse "evidence destination precheck transition failed: $relative"; return 1; }
    resolved=$(canonical_evidence_dir "$cursor/$component" yes) \
      || { evidence_refuse "evidence destination parent is unresolved: $relative"; return 1; }
    case "$resolved/" in "$scope/"*) ;; *) evidence_refuse "evidence destination resolves outside its scope: $relative"; return 1 ;; esac
    cursor=$resolved
  done
  leaf=$remaining
  case "$leaf" in ''|.|..) evidence_refuse "unsafe evidence destination leaf: $relative"; return 1 ;; esac
  [ ! -L "$cursor/$leaf" ] \
    || { evidence_refuse "evidence destination leaf is symlinked: $relative"; return 1; }
  [ ! -e "$cursor/$leaf" ] \
    || { evidence_refuse "evidence destination already exists: $relative"; return 1; }
  case "$cursor/$leaf" in "$scope/"*) ;; *) evidence_refuse "evidence destination is outside its scope: $relative"; return 1 ;; esac
  EVIDENCE_DESTINATION="$cursor/$leaf"
}

publish_evidence() {
  local scope=$1 relative=$2 source=$3 destination
  [ -f "$source" ] && [ ! -L "$source" ] \
    || { evidence_refuse "evidence source is not a regular file"; return 1; }
  case "$relative" in /*) destination=$relative ;; *) destination="$scope/$relative" ;; esac
  EVIDENCE_DESTINATION=$destination
  evidence_validate_destination "$scope" "$relative" "$destination" || return 1
  destination=$EVIDENCE_DESTINATION
  perl -MFcntl=O_WRONLY,O_CREAT,O_EXCL -e '
    use strict;
    use warnings;
    my ($source, $destination) = @ARGV;
    open my $input, "<", $source or die "$source: $!\n";
    binmode $input;
    local $/;
    my $content = <$input>;
    close $input or die "$source: $!\n";
    sysopen my $output, $destination, O_WRONLY | O_CREAT | O_EXCL, 0600
      or die "$destination: $!\n";
    binmode $output;
    my $offset = 0;
    while ($offset < length $content) {
      my $written = syswrite $output, $content, length($content) - $offset, $offset;
      die "$destination: $!\n" unless defined $written;
      $offset += $written;
    }
    close $output or die "$destination: $!\n";
  ' "$source" "$destination" 2>/dev/null \
    || { evidence_refuse "could not exclusively publish evidence: $relative"; return 1; }
  cmp -s "$source" "$destination" \
    || { evidence_refuse "published evidence did not retain exact bytes: $relative"; return 1; }
}

evidence_fixture_ids() {
  printf '%s\n' absolute traversal symlink-leaf-data symlink-parent symlink-parent-state resolved-outside hard-link unresolved-parent existing scope-symlink scope-unresolved unsafe-leaf legitimate
}

evidence_fixture_description() {
  case "$1" in
    absolute) printf '%s\n' 'absolute destination aimed at fake data is refused' ;;
    traversal) printf '%s\n' 'dot-dot traversal aimed at fake data is refused' ;;
    symlink-leaf-data) printf '%s\n' 'symlinked leaf aimed at fake data is refused' ;;
    symlink-parent) printf '%s\n' 'symlinked parent directory is refused' ;;
    symlink-parent-state) printf '%s\n' 'symlinked parent aimed at fake state is refused' ;;
    resolved-outside) printf '%s\n' 'destination resolving outside after parent resolution is refused' ;;
    hard-link) printf '%s\n' 'existing hard-linked destination is refused without mutation' ;;
    unresolved-parent) printf '%s\n' 'unresolved destination parent is refused' ;;
    existing) printf '%s\n' 'existing destination is refused without mutation' ;;
    scope-symlink) printf '%s\n' 'symlinked evidence scope is refused' ;;
    scope-unresolved) printf '%s\n' 'unresolved evidence scope is refused' ;;
    unsafe-leaf) printf '%s\n' 'unsafe destination leaf is refused' ;;
    legitimate) printf '%s\n' 'legitimate in-scope publication remains exact' ;;
    *) return 1 ;;
  esac
}

run_evidence_fixture() {
  local id=$1 lab scope validation_scope safe fake_data fake_state outside source relative forbidden
  evidence_fixture_description "$id" >/dev/null || return 2
  lab="$TMP/evidence-containment/$id"
  scope="$lab/scope"
  safe="$scope/safe"
  fake_data="$lab/fake-data"
  fake_state="$lab/fake-state"
  outside="$lab/fake-outside"
  mkdir -p "$safe/inside-parent" "$fake_data" "$fake_state" "$outside"
  validation_scope=$scope
  source="$lab/evidence.md"
  printf 'bounded evidence\n' > "$source"

  case "$id" in
    absolute)
      relative="$fake_data/absolute.md"; forbidden=$relative ;;
    traversal)
      relative='../fake-data/traversal.md'; forbidden="$fake_data/traversal.md" ;;
    symlink-leaf-data)
      ln -s "$fake_data/symlink-leaf.md" "$safe/symlink-leaf.md"
      relative='safe/symlink-leaf.md'; forbidden="$fake_data/symlink-leaf.md" ;;
    symlink-parent)
      mkdir "$scope/inside-target"
      ln -s "$scope/inside-target" "$safe/symlink-parent"
      relative='safe/symlink-parent/evidence.md'; forbidden="$scope/inside-target/evidence.md" ;;
    symlink-parent-state)
      ln -s "$fake_state" "$scope/state-link"
      relative='state-link/evidence.md'; forbidden="$fake_state/evidence.md" ;;
    resolved-outside)
      mkdir "$safe/canonical-boundary"
      EVIDENCE_SWAP_PATH=$(canonical_evidence_dir "$safe/canonical-boundary")
      EVIDENCE_SWAP_TARGET=$outside
      relative='safe/canonical-boundary/evidence.md'; forbidden="$safe/canonical-boundary/evidence.md" ;;
    hard-link)
      printf 'hard-link sentinel\n' > "$fake_data/hard-target.md"
      ln "$fake_data/hard-target.md" "$safe/hard-link.md"
      publish_evidence "$scope" 'safe/hard-link.md' "$source" >/dev/null 2>&1 && return 1
      [ "$(cat "$fake_data/hard-target.md")" = 'hard-link sentinel' ]
      return ;;
    unresolved-parent)
      relative='missing/evidence.md'; forbidden="$scope/missing/evidence.md" ;;
    existing)
      printf 'existing sentinel\n' > "$safe/existing.md"
      publish_evidence "$scope" 'safe/existing.md' "$source" >/dev/null 2>&1 && return 1
      [ "$(cat "$safe/existing.md")" = 'existing sentinel' ]
      return ;;
    scope-symlink)
      ln -s "$scope" "$lab/scope-link"
      validation_scope="$lab/scope-link"
      relative='safe/scope-symlink.md'; forbidden="$safe/scope-symlink.md" ;;
    scope-unresolved)
      validation_scope="$lab/missing-scope"
      relative='safe/scope-unresolved.md'; forbidden="$lab/missing-scope/safe/scope-unresolved.md" ;;
    unsafe-leaf)
      publish_evidence "$scope" '..' "$source" >/dev/null 2>&1 && return 1
      return 0 ;;
    legitimate)
      publish_evidence "$scope" 'safe/legitimate.md' "$source" >/dev/null 2>&1 \
        && cmp -s "$source" "$safe/legitimate.md"
      return ;;
  esac
  publish_evidence "$validation_scope" "$relative" "$source" >/dev/null 2>&1 && return 1
  [ ! -e "$forbidden" ] && [ ! -L "$forbidden" ]
}

self_test_evidence_containment() {
  local id description pass_count=0 fail_count=0
  while IFS= read -r id; do
    description=$(evidence_fixture_description "$id")
    if run_evidence_fixture "$id"; then
      printf '  PASS  %s\n' "$description"
      pass_count=$((pass_count + 1))
    else
      printf '  FAIL  %s\n' "$description"
      fail_count=$((fail_count + 1))
    fi
  done < <(evidence_fixture_ids)
  printf 'CONTAINMENT FIXTURES passed=%s failed=%s\n' "$pass_count" "$fail_count"
  [ "$pass_count" -eq 13 ] && [ "$fail_count" -eq 0 ]
}

if [ "$MODE" = fixture ]; then
  run_evidence_fixture "$EVIDENCE_FIXTURE"
  exit
fi
if [ "$MODE" = containment ]; then
  self_test_evidence_containment
  exit
fi

apply_mutation() {
  local target=$1 from=$2 to=$3 count_file=$4
  FROM_TEXT=$from TO_TEXT=$to COUNT_FILE=$count_file perl -0pi -e '
    BEGIN {
      $from = $ENV{FROM_TEXT};
      $to = $ENV{TO_TEXT};
      $count_file = $ENV{COUNT_FILE};
    }
    $count = 0;
    $offset = 0;
    while (($found = index($_, $from, $offset)) >= 0) {
      $count++;
      $offset = $found + length($from);
    }
    if ($count == 1) {
      s/\Q$from\E/$to/;
    }
    open(my $fh, ">", $count_file) or die $!;
    print {$fh} "$count\n";
    close($fh) or die $!;
  ' "$target"
}

run_mutation_test() {
  local target=$1 output=$2
  FM_MUTATION_RUN=1 TOOL=$target perl -e '
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
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "${MUTATION_TIMEOUT:-120}" "$TEST" >"$output" 2>&1
}

mutant() {
  local id=$1 anchor=$2 from=$3 to=$4 claim=$5 target count_file count outcome status
  denominator=$((denominator + 1))
  if [ -n "${MUTATION_ONLY:-}" ] && [ "$MUTATION_ONLY" != "$id" ]; then
    return
  fi
  target="$TMP/$id.sh"
  count_file="$TMP/$id.count"
  cp "$SOURCE" "$target"
  apply_mutation "$target" "$from" "$to" "$count_file"
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
    if [ "$status" -eq 124 ] || [ "$status" -eq 126 ] || [ "$status" -eq 127 ] || [ "$status" -ge 128 ]; then
      outcome=HARNESS-BROKEN
      harness_broken=$((harness_broken + 1))
      printf 'HARNESS DETAIL %s status=%s\n' "$id" "$status" >&2
      tail -20 "$TMP/$id.out" >&2
    elif [ "$status" -eq 0 ]; then
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

mutant M001 strict.errexit 'set -euo pipefail' 'set -uo pipefail' 'Shell failures cannot fall through.'
mutant M002 manifest.denominator 'BUNDLE_MEMBER_COUNT=4' 'BUNDLE_MEMBER_COUNT=5' 'The bundle denominator is exactly four.'
mutant M003 canonical.exists '[ -d "$1" ] || die "ledger directory does not exist: $1"' ':' 'Only an existing directory can be canonicalized.'
mutant M004 canonical.physical 'pwd -P' 'pwd -L' 'Admission returns physical canonical paths.'
mutant M005 manifest.tests-member 'CONTRACT.md fm-sovereign-ledger.sh ledger.tsv tests.sh' 'CONTRACT.md fm-sovereign-ledger.sh ledger.tsv tests.missing' 'The exact manifest includes tests.sh.'
mutant M006 enumerate.top-level '-mindepth 1 -maxdepth 1' '-mindepth 2 -maxdepth 2' 'Every real top-level entry name is enumerated.'
mutant M007 enumerate.real-names 'printf "%s\n" "${path##*/}"' 'printf "%s\n" CONTRACT.md fm-sovereign-ledger.sh ledger.tsv tests.sh' 'Enumeration retains real entry names.'
mutant M008 enumerate.exact-set '[ "$entries" = "$required" ]' 'true' 'Real names must equal the manifest byte-for-byte.'
mutant M009 require.no-symlink '[ -L "$dir/$entry" ] && die "ledger bundle contains a symlink: $dir/$entry"' ':' 'Manifest members cannot be symlinks.'
mutant M010 require.regular '[ -f "$dir/$entry" ] || die "ledger bundle contains a non-regular file: $dir/$entry"' ':' 'Manifest members must remain regular files.'
mutant M011 require.executable '[ -x "$dir/fm-sovereign-ledger.sh" ] || die "ledger verifier is not executable: $dir/fm-sovereign-ledger.sh"' ':' 'The verifier remains executable.'
mutant M012 bytes.reject '|| die "replica differs from primary: $entry"' '|| :' 'Compared bytes must match.'
mutant M013 device.bsd-read "stat -f '%d'" "printf '1'" 'BSD st_dev is read from stat.'
mutant M014 device.gnu-read "stat -c '%d'" "printf '1'" 'GNU st_dev is read from stat.'
mutant M015 device.numeric-shape "'^[0-9]+$'" "'.*'" 'Only numeric st_dev identities are accepted.'
mutant M016 containment.distinct '[ "$primary" != "$replica" ] || die "primary and replica directories must differ"' ':' 'Canonical pair paths must differ.'
mutant M017 containment.primary 'case "$primary/" in "$replica/"*) die "primary and replica directories must not contain one another" ;; esac' ':' 'Primary cannot be contained by replica.'
mutant M018 containment.replica 'case "$replica/" in "$primary/"*) die "primary and replica directories must not contain one another" ;; esac' ':' 'Replica cannot be contained by primary.'
mutant M019 device.primary-read 'primary_device=$(portable_device_identity "$primary")' 'primary_device=1' 'Admission reads primary st_dev.'
mutant M020 device.replica-read 'replica_device=$(portable_device_identity "$replica")' 'replica_device=2' 'Admission reads replica st_dev.'
mutant M021 device.inequality '[ "$primary_device" = "$replica_device" ]' 'false' 'Equal st_dev is refused by default.'
mutant M022 device.optout-only '[ "$ALLOW_SAME_VOLUME_WITHOUT_DEVICE_REDUNDANCY" != yes ]' 'true' 'Only the named opt-out waives device inequality.'
mutant M023 verifier.execute 'LEDGER_DIR="$subject" "$primary/fm-sovereign-ledger.sh" verify >/dev/null' ':' 'Primary verifier establishes ledger validity.'
mutant M024 prefix.nonempty '[ "$replica_lines" -gt 0 ]' 'true' 'An empty ledger is not a prefix.'
mutant M025 prefix.shorter '[ "$primary_lines" -gt "$replica_lines" ]' 'true' 'A prefix is strictly shorter.'
mutant M026 prefix.leading 'head -n "$replica_lines"' 'tail -n "$replica_lines"' 'Prefix comparison uses leading records.'
mutant M027 recheck.replica-type $'require_bundle "$primary"\n  require_bundle "$replica"\n  admit_device_pair "$primary" "$replica"\n  admit_independent_bundle_members "$primary" "$replica"\n  compare_files' $'require_bundle "$primary"\n  :\n  admit_device_pair "$primary" "$replica"\n  admit_independent_bundle_members "$primary" "$replica"\n  compare_files' 'Admission reclassifies replica entries after verifier execution.'
mutant M028 directory.canonical-stable '[ "$canonical" = "$path" ] || die "$label directory no longer resolves to its admitted path: $path"' ':' 'A directory path cannot change after admission.'
mutant M029 directory.identity-stable '[ "$identity" = "$expected" ] || die "$label directory changed after admission: $path"' ':' 'A directory object cannot change after admission.'
mutant M030 publish.exclusive-create 'O_WRONLY | O_CREAT | O_EXCL' 'O_WRONLY | O_CREAT' 'Bundle members are created exclusively.'
mutant M031 publish.preserve-mode 'chmod($source_stat[2] & 07777, $output)' 'chmod(0600, $output)' 'Exclusive copy preserves required modes.'
mutant M032 publish.parent-no-symlink '[ ! -L "$parent" ] || die "replica parent directory is symlinked: $parent"' ':' 'Snapshot parent cannot be a symlink.'
mutant M033 publish.safe-leaf "case \"\$base\" in ''|.|..) die \"unsafe replica destination leaf: \$replica_input\" ;; esac" ':' 'Snapshot leaf is safe.'
mutant M034 publish.destination-absent '[ ! -e "$replica" ] && [ ! -L "$replica" ]' 'true' 'Snapshot destination is absent and not symlinked.'
mutant M035 publish.parent-device 'admit_device_pair "$primary" "$parent"' ':' 'Snapshot checks destination-volume st_dev before creation.'
mutant M036 publish.mkdir-exclusive 'mkdir -- "$replica" || die "could not exclusively create replica destination: $replica"' 'mkdir -p -- "$replica"' 'Snapshot claims its final destination exclusively.'
mutant M037 publish.copy-bundle 'copy_bundle "$primary" "$replica"' ':' 'Snapshot populates the admitted destination.'
mutant M038 publish.validate-object 'admit_existing_pair "$primary" "$replica" exact' ':' 'Snapshot validates the object it published.'
mutant M039 refresh.prefix-admission 'admit_pair "$1" "$2" prefix' 'admit_pair "$1" "$2" inspect' 'Refresh proves the prefix before writing.'
mutant M040 refresh.atomic-copy 'copy_ledger_atomically "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA"' ':' 'Refresh publishes the admitted ledger update.'
mutant M041 refresh.post-admission $'  copy_ledger_atomically "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA"\n  admit_pair "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA" exact\n  printf \'REFRESH PASS (replica advanced to primary)\\n\'' $'  copy_ledger_atomically "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA"\n  :\n  printf \'REFRESH PASS (replica advanced to primary)\\n\'' 'Refresh re-admits the published exact pair.'
mutant M042 verify.inspect-admission 'admit_pair "$1" "$2" inspect' 'admit_pair "$1" "$2" exact' 'Verify admits stale pairs before classifying them.'
mutant M043 verify.exact-recheck $'  admit_pair "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA" exact\n  if [ "$ALLOW_SAME_VOLUME_WITHOUT_DEVICE_REDUNDANCY" = yes ]; then' $'  :\n  if [ "$ALLOW_SAME_VOLUME_WITHOUT_DEVICE_REDUNDANCY" = yes ]; then' 'Verify re-admits an exact pair before PASS.'
mutant M044 option.named-flag 'if [ "${1:-}" = --allow-same-volume-without-device-redundancy ]; then' 'if [ "${1:-}" = --allow-same-volume ]; then' 'The opt-out name states the surrendered property.'
mutant M045 dispatch.snapshot 'snapshot) shift; [ "$#" -eq 2 ] || usage; cmd_snapshot "$@"' 'snapshot) shift; [ "$#" -eq 2 ] || usage; :' 'Dispatch cannot bypass snapshot admission.'
mutant M046 dispatch.refresh 'refresh) shift; [ "$#" -eq 2 ] || usage; cmd_refresh "$@"' 'refresh) shift; [ "$#" -eq 2 ] || usage; :' 'Dispatch cannot bypass refresh admission.'
mutant M047 dispatch.verify 'verify) shift; [ "$#" -eq 2 ] || usage; cmd_verify "$@"' 'verify) shift; [ "$#" -eq 2 ] || usage; :' 'Dispatch cannot bypass verify admission.'
mutant M048 identity.member-read $'portable_member_identity() {\n  portable_directory_identity "$1"\n}' $'portable_member_identity() {\n  printf "1:1\\n"\n}' 'Member identity is read from the admitted filesystem object.'
mutant M049 identity.cross-product-disjoint '[ "$primary_identity" != "$replica_identity" ]' 'true' 'Every primary identity must differ from every replica identity.'
mutant M050 identity.cross-product-denominator '[ "$compared" -eq $((BUNDLE_MEMBER_COUNT * BUNDLE_MEMBER_COUNT)) ]' 'true' 'The complete four-by-four member cross-product is proved.'
mutant M051 admission.initial-member-identity $'  admit_device_pair "$primary" "$replica"\n  require_bundle "$primary"\n  require_bundle "$replica"\n  admit_independent_bundle_members "$primary" "$replica"\n  compare_files' $'  admit_device_pair "$primary" "$replica"\n  require_bundle "$primary"\n  require_bundle "$replica"\n  :\n  compare_files' 'Initial pair admission proves member independence before verifier execution.'
mutant M052 admission.final-member-identity $'  require_bundle "$primary"\n  require_bundle "$replica"\n  admit_device_pair "$primary" "$replica"\n  admit_independent_bundle_members "$primary" "$replica"\n  compare_files' $'  require_bundle "$primary"\n  require_bundle "$replica"\n  admit_device_pair "$primary" "$replica"\n  :\n  compare_files' 'Final pair admission re-proves member independence after verifier execution.'
mutant M053 refresh.carried-member-identity '  require_admitted_bundle_members "$primary" "$replica"' '  :' 'Refresh rechecks the admitted member identities before publication.'

[ "$denominator" -eq 53 ] || { printf 'invalid owned denominator: %s\n' "$denominator" >&2; exit 1; }

control="$TMP/CONTROL.sh"
control_count="$TMP/CONTROL.count"
cp "$SOURCE" "$control"
apply_mutation "$control" 'make, advance' 'make, advance' "$control_count"
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

PUBLICATION_MATRIX="$TMP/evidence-publication-matrix.md"
"$ROOT/tests/fm-sovereign-ledger-evidence-publish.mutation.sh" --markdown > "$PUBLICATION_MATRIX"
EVIDENCE_STAGE="$TMP/evidence.md"
{
    printf '# Sovereign ledger redundancy mutation evidence\n\n'
    printf 'Audience: maintainer verification.\n\n'
    printf 'Verified on 2026-08-15 against the R5 sovereign-ledger redundancy chokepoint.\n'
    printf 'The owned denominator spans exact real-name enumeration, the st_dev predicate, the four-by-four member-identity cross-product, both member admission calls, carried-identity refresh recheck, exclusive publication, verification, and all three dispatch entries.\n'
    printf 'Every run copied the implementation under one scoped `mktemp -d`; the live ledger, `data/`, and `state/` were never inputs or targets.\n\n'
    printf '```sh\n'
    printf 'tests/fm-sovereign-ledger-redundancy.mutation.sh --write-evidence sovereign-ledger-redundancy-mutation.candidate.md\n'
    printf '```\n\n'
    printf 'Evidence publication rejects existing destinations, so the candidate is reviewed against this record before replacement rather than overwriting it in place.\n\n'
    printf 'Observed summary: `killed=%s survived=%s void=%s harness_broken=%s denominator=%s`; the intentional no-op control recorded `substitutions=%s status=%s outcome=%s`.\n\n' "$killed" "$survived" "$void" "$harness_broken" "$denominator" "$control_substitutions" "$control_status" "$control_outcome"
    printf '| Mutant | Stable exact clause anchor | Substitutions | Outcome | Status | Unenforced claim when survived |\n'
    printf '| --- | --- | ---: | --- | ---: | --- |\n'
    while IFS=$'\t' read -r id anchor count outcome status claim; do
      if [ "$outcome" != SURVIVED ]; then claim=-; fi
      printf '| `%s` | `%s` | %s | %s | %s | %s |\n' "$id" "$anchor" "$count" "$outcome" "$status" "$claim"
    done < "$RESULTS"
    cat <<'EVIDENCE_PUBLICATION'

## Evidence publication containment

The complete fixture results, cell outcomes, alternate defenders, per-mutant totals, and aggregate denominator below come from one canonical generated stream.
EVIDENCE_PUBLICATION
    printf '\n'
    cat "$PUBLICATION_MATRIX"
} > "$EVIDENCE_STAGE"

printf 'MUTATION SUMMARY killed=%s survived=%s void=%s harness_broken=%s denominator=%s\n' "$killed" "$survived" "$void" "$harness_broken" "$denominator"
[ -s "$EVIDENCE_STAGE" ] || { printf 'REFUSED: generated mutation evidence is empty\n' >&2; exit 1; }
[ "$(wc -l < "$RESULTS" | tr -d '[:space:]')" -eq "$denominator" ] \
  || { printf 'REFUSED: mutation result rows do not match denominator\n' >&2; exit 1; }
awk -F '\t' 'NF != 6 || $3 != 1 || ($4 != "KILLED" && $4 != "SURVIVED") { exit 1 }' "$RESULTS" \
  || { printf 'REFUSED: every mutant must record one substitution and an individual outcome\n' >&2; exit 1; }
[ "$void" -eq 0 ]
[ "$harness_broken" -eq 0 ]
[ "$control_substitutions" -eq 1 ]
[ "$control_outcome" = SURVIVED ]
if [ "$REFRESH_EVIDENCE" -eq 1 ]; then
  maintained="$ROOT/docs/verification/sovereign-ledger-redundancy-mutation.md"
  install_stage=$(mktemp "$ROOT/docs/verification/.sovereign-ledger-redundancy-mutation.XXXXXX") \
    || { printf 'REFUSED: could not stage maintained mutation evidence\n' >&2; exit 1; }
  cp "$EVIDENCE_STAGE" "$install_stage" \
    || { rm -f -- "$install_stage"; printf 'REFUSED: could not copy maintained mutation evidence\n' >&2; exit 1; }
  [ -s "$install_stage" ] && cmp -s "$EVIDENCE_STAGE" "$install_stage" \
    || { rm -f -- "$install_stage"; printf 'REFUSED: staged maintained mutation evidence is empty or differs\n' >&2; exit 1; }
  mv -f -- "$install_stage" "$maintained" \
    || { rm -f -- "$install_stage"; printf 'REFUSED: could not atomically install maintained mutation evidence\n' >&2; exit 1; }
  [ -s "$maintained" ] || { printf 'REFUSED: installed maintained mutation evidence is empty\n' >&2; exit 1; }
elif [ -n "$EVIDENCE" ]; then
  publish_evidence "$ROOT/docs/verification" "$EVIDENCE" "$EVIDENCE_STAGE"
elif [ "$EMIT_EVIDENCE" -eq 1 ]; then
  cat "$EVIDENCE_STAGE" >&3
elif [ "$VERIFY_EVIDENCE" -eq 1 ]; then
  maintained="$ROOT/docs/verification/sovereign-ledger-redundancy-mutation.md"
  [ -s "$maintained" ] || { printf 'REFUSED: maintained mutation evidence is empty\n' >&2; exit 1; }
  cmp -s "$EVIDENCE_STAGE" "$maintained" || {
    diff -u "$maintained" "$EVIDENCE_STAGE" >&2 || true
    exit 1
  }
fi
