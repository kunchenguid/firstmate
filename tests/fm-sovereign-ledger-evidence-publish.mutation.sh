#!/usr/bin/env bash
# Verify evidence-publication containment and each independent enforcing boundary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/tests/fm-sovereign-ledger-redundancy.mutation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fixtures='absolute traversal symlink-leaf-data symlink-parent symlink-parent-state resolved-outside hard-link unresolved-parent existing'
killed=0
survived=0
void=0
mutants=0
cells=0

"$SUBJECT" --self-test-evidence-containment

surviving_defender() {
  case "$1:$2" in
    P001:symlink-leaf-data|P001:hard-link|P001:existing)
      printf '%s\n' exclusive-create-O_EXCL ;;
    P001:unresolved-parent)
      printf '%s\n' natural-unresolved-parent ;;
    P002:*)
      printf '%s\n' resolved-path-validator ;;
    P003:absolute|P004:absolute)
      printf '%s\n' absolute-path-validator ;;
    P003:traversal|P004:traversal)
      printf '%s\n' path-component-validator ;;
    P003:symlink-leaf-data|P004:symlink-leaf-data)
      printf '%s\n' symlink-leaf-validator ;;
    P003:symlink-parent-state|P003:resolved-outside)
      printf '%s\n' canonical-structural-containment ;;
    P004:symlink-parent|P004:symlink-parent-state)
      printf '%s\n' symlink-component-precheck ;;
    P003:hard-link|P003:existing|P004:hard-link|P004:existing)
      printf '%s\n' existing-leaf-validator ;;
    P003:unresolved-parent|P004:unresolved-parent)
      printf '%s\n' canonical-parent-resolution ;;
    *)
      printf '%s\n' - ;;
  esac
}

publish_mutant() {
  local id=$1 anchor=$2 from=$3 to=$4 mutant count_file substitutions
  local fixture outcome defender mutant_killed=0 mutant_survived=0 mutant_void=0
  mutants=$((mutants + 1))
  mutant="$TMP/$id.sh"
  count_file="$TMP/$id.substitutions"
  cp "$SUBJECT" "$mutant"
  chmod +x "$mutant"
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
    s/\Q$from\E/$to/ if $count == 1;
    open(my $fh, ">", $count_file) or die $!;
    print {$fh} "$count\n";
    close($fh) or die $!;
  ' "$mutant"
  substitutions=$(cat "$count_file")
  for fixture in $fixtures; do
    cells=$((cells + 1))
    if [ "$substitutions" -ne 1 ]; then
      outcome=VOID
      defender=-
      void=$((void + 1))
      mutant_void=$((mutant_void + 1))
    elif "$mutant" --self-test-evidence-fixture "$fixture" > "$TMP/$id-$fixture.out" 2>&1; then
      outcome=SURVIVED
      defender=$(surviving_defender "$id" "$fixture")
      survived=$((survived + 1))
      mutant_survived=$((mutant_survived + 1))
    else
      outcome=KILLED
      defender=-
      killed=$((killed + 1))
      mutant_killed=$((mutant_killed + 1))
    fi
    printf 'PUBLISH CELL mutant=%s anchor=%s substitutions=%s fixture=%s outcome=%s defender=%s\n' \
      "$id" "$anchor" "$substitutions" "$fixture" "$outcome" "$defender"
  done
  printf 'PUBLISH MUTANT %s anchor=%s substitutions=%s killed=%s survived=%s void=%s\n' \
    "$id" "$anchor" "$substitutions" "$mutant_killed" "$mutant_survived" "$mutant_void"
}

publish_mutant P001 resolved-path-validator-call \
  'evidence_validate_destination "$scope" "$relative" "$destination" || return 1' \
  ':'
publish_mutant P002 exclusive-create-flag \
  'O_WRONLY | O_CREAT | O_EXCL' \
  'O_WRONLY | O_CREAT'
publish_mutant P003 symlink-component-precheck \
  '[ ! -L "$cursor/$component" ]' \
  'true'
publish_mutant P004 canonical-structural-containment \
  'case "$resolved/" in "$scope/"*) ;; *) evidence_refuse "evidence destination resolves outside its scope: $relative"; return 1 ;; esac' \
  ':'
"$SUBJECT" --self-test-evidence-containment >/dev/null
printf 'PUBLISH MATRIX SUMMARY mechanisms=5 written_boundaries=4 natural_boundaries=1 mutants=%s fixtures=9 cells=%s killed=%s survived=%s void=%s\n' \
  "$mutants" "$cells" "$killed" "$survived" "$void"
[ "$mutants" -eq 4 ]
[ "$cells" -eq 36 ]
[ "$killed" -eq 7 ]
[ "$survived" -eq 29 ]
[ "$void" -eq 0 ]
