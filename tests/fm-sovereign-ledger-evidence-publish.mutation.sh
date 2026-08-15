#!/usr/bin/env bash
# Verify evidence-publication containment and its enforcing chokepoint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/tests/fm-sovereign-ledger-redundancy.mutation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
killed=0
survived=0
void=0
denominator=0

"$SUBJECT" --self-test-evidence-containment

publish_mutant() {
  local id=$1 from=$2 to=$3 mutant count_file substitutions outcome
  denominator=$((denominator + 1))
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
  if [ "$substitutions" -ne 1 ]; then
    outcome=VOID
    void=$((void + 1))
  elif "$mutant" --self-test-evidence-containment > "$TMP/$id.out" 2>&1; then
    outcome=SURVIVED
    survived=$((survived + 1))
  else
    outcome=KILLED
    killed=$((killed + 1))
  fi
  printf 'PUBLISH MUTANT %s %s substitutions=%s\n' "$id" "$outcome" "$substitutions"
}

publish_mutant P001 \
  'evidence_validate_destination "$scope" "$relative" "$destination" || return 1' \
  ':'
"$SUBJECT" --self-test-evidence-containment >/dev/null
printf 'PUBLISH MUTATION SUMMARY enforcing_lines=1 killed=%s survived=%s void=%s denominator=%s\n' "$killed" "$survived" "$void" "$denominator"
[ "$denominator" -eq 1 ]
[ "$killed" -eq 1 ]
[ "$survived" -eq 0 ]
[ "$void" -eq 0 ]
