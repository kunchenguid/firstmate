#!/usr/bin/env bash
# Verify evidence-publication containment and each independent enforcing boundary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/tests/fm-sovereign-ledger-redundancy.mutation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fixtures='absolute traversal symlink-leaf-data symlink-parent symlink-parent-state resolved-outside hard-link unresolved-parent existing scope-symlink scope-unresolved unsafe-leaf'
killed=0
survived=0
void=0
mutants=0
cells=0

"$SUBJECT" --self-test-evidence-containment

surviving_defender() {
  local mutant=$1 fixture=$2
  case "$mutant:$fixture" in
    P001:symlink-leaf-data|P001:hard-link|P001:existing)
      printf '%s\n' exclusive-create-O_EXCL ;;
    P001:unresolved-parent)
      printf '%s\n' natural-unresolved-parent ;;
    P001:scope-unresolved)
      printf '%s\n' natural-unresolved-parent ;;
    P001:unsafe-leaf)
      printf '%s\n' exclusive-create-O_EXCL ;;
    P002:*)
      printf '%s\n' resolved-path-validator ;;
    P003:symlink-parent-state|P003:resolved-outside)
      printf '%s\n' canonical-structural-containment ;;
    P004:resolved-outside)
      printf '%s\n' final-structural-containment ;;
    P005:absolute)
      printf '%s\n' unsafe-component-guard ;;
    P006:traversal)
      printf '%s\n' canonical-structural-containment ;;
    P007:symlink-leaf-data)
      printf '%s\n' exclusive-create-O_EXCL ;;
    P008:hard-link|P008:existing)
      printf '%s\n' exclusive-create-O_EXCL ;;
    P009:unresolved-parent)
      printf '%s\n' natural-unresolved-parent ;;
    P011:scope-symlink)
      printf '%s\n' canonical-scope-resolution ;;
    P012:scope-unresolved)
      printf '%s\n' canonical-parent-resolution ;;
    P013:unsafe-leaf)
      printf '%s\n' existing-leaf-guard ;;
    *)
      case "$fixture" in
        absolute) printf '%s\n' absolute-path-guard ;;
        traversal) printf '%s\n' unsafe-component-guard ;;
        symlink-leaf-data) printf '%s\n' symlink-leaf-guard ;;
        symlink-parent|symlink-parent-state) printf '%s\n' symlink-component-precheck ;;
        resolved-outside) printf '%s\n' canonical-structural-containment ;;
        hard-link|existing) printf '%s\n' existing-leaf-guard ;;
        unresolved-parent) printf '%s\n' canonical-parent-resolution ;;
        scope-symlink) printf '%s\n' scope-symlink-guard ;;
        scope-unresolved) printf '%s\n' canonical-scope-resolution ;;
        unsafe-leaf) printf '%s\n' unsafe-leaf-guard ;;
      esac ;;
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
publish_mutant P005 absolute-path-guard \
  'case "$relative" in /*) evidence_refuse "absolute evidence destination is forbidden: $relative"; return 1 ;; esac' \
  ':'
publish_mutant P006 unsafe-component-guard \
  "case \"\$component\" in ''|.|..) evidence_refuse \"unsafe evidence destination component: \$relative\"; return 1 ;; esac" \
  ':'
publish_mutant P007 symlink-leaf-guard \
  '[ ! -L "$cursor/$leaf" ]' \
  'true'
publish_mutant P008 existing-leaf-guard \
  '[ ! -e "$cursor/$leaf" ]' \
  'true'
publish_mutant P009 canonical-parent-resolution \
  '|| { evidence_refuse "evidence destination parent is unresolved: $relative"; return 1; }' \
  '|| resolved="$cursor/$component"'
publish_mutant P010 final-structural-containment \
  'case "$cursor/$leaf" in "$scope/"*) ;; *) evidence_refuse "evidence destination is outside its scope: $relative"; return 1 ;; esac' \
  ':'
publish_mutant P011 scope-symlink-guard \
  '[ ! -L "$scope_input" ]' \
  'true'
publish_mutant P012 canonical-scope-resolution \
  '|| { evidence_refuse "evidence scope is unresolved: $scope_input"; return 1; }' \
  '|| scope=$scope_input'
publish_mutant P013 unsafe-leaf-guard \
  "case \"\$leaf\" in ''|.|..) evidence_refuse \"unsafe evidence destination leaf: \$relative\"; return 1 ;; esac" \
  ':'
"$SUBJECT" --self-test-evidence-containment >/dev/null
printf 'PUBLISH MATRIX SUMMARY mechanisms=14 written_boundaries=13 natural_boundaries=1 mutants=%s fixtures=12 cells=%s killed=%s survived=%s void=%s\n' \
  "$mutants" "$cells" "$killed" "$survived" "$void"
[ "$mutants" -eq 13 ]
[ "$cells" -eq 156 ]
[ "$killed" -eq 7 ]
[ "$survived" -eq 149 ]
[ "$void" -eq 0 ]
