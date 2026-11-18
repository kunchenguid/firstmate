#!/usr/bin/env bash
# tests/fm-classify-fold-equivalence.test.sh - the open-decisions fold rewritten
# to run a log in one shell (bin/fm-classify-lib.sh _fm_decision_fold_file,
# _fm_decision_classify_line) must stay byte-identical to the per-line text fold
# it replaced. The reference below is a frozen copy of that older fold: the
# command-substitution readers, _fm_decision_drop's line walk, and
# _fm_decision_fold_line's per-line rule. Every case folds the same generated
# log through the reference and through the real library and compares the sets,
# in the plain and timed views, for every task kind, and through the
# cursor-backed fold split at arbitrary byte boundaries.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-fold-equivalence-tests)

# --- frozen reference: the fold as it was before the stream fold -------------
ref_key_at_note_head() {
  local rest
  case "$1" in
    *:*) rest=${1#*:} ;;
    *) return 1 ;;
  esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \[key=*\]*) rest=${rest#\[key=}; printf '%s' "${rest%%\]*}" ;;
    *) return 1 ;;
  esac
}
ref_status_line_note() {
  local n k unstamped
  _fm_status_unstamped "$1" unstamped
  case "$unstamped" in
    *:*) n=${unstamped#*:}; n=${n#"${n%%[![:space:]]*}"} ;;
    *) printf '%s' "$unstamped"; return 0 ;;
  esac
  if ! _fm_key_before_colon "$unstamped" && k=$(ref_key_at_note_head "$unstamped") \
    && _fm_decision_slug_ok "$k"; then
    n=${n#"[key=$k]"}
    n=${n#"${n%%[![:space:]]*}"}
  fi
  printf '%s' "$n"
}
ref_decision_key() {
  local k unstamped
  _fm_status_unstamped "$1" unstamped
  if _fm_key_before_colon "$unstamped"; then
    k=${unstamped%%:*}
    k=${k#*\[key=}
    k=${k%%\]*}
  else
    k=$(ref_key_at_note_head "$unstamped") || { printf '%s' "${2-default}"; return 0; }
  fi
  _fm_decision_slug_ok "$k" || return 1
  printf '%s' "$k"
}
ref_decision_drop() {
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
ref_fold_line() {  # <open-set> <status-line> <resolve> <held> <kind> [timed]
  local open=$1 line=$2 resolve=$3 held=$4 kind=$5 verb key note unstamped
  local timed=${6:-} epoch
  _fm_status_unstamped "$line" unstamped
  case "$unstamped" in
    *:*|*\[key=*\]*) ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  status_line_verb "$line" verb
  case "$unstamped" in
    *:*) case "$verb:$kind" in done:ship|done:scout|failed:ship|failed:scout) return 0 ;; esac ;;
  esac
  case "$verb" in
    needs-decision|blocked|"$resolve"|"$held") ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  key=$(ref_decision_key "$line") || { printf '%s' "$open"; return 0; }
  _fm_decision_key_transition_allowed "$key" "$(ref_status_line_note "$line")" \
    || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      note=$(ref_status_line_note "$line")
      if [ "$timed" = timed ]; then
        epoch=unknown
        if [ -n "$(ref_decision_key "$line" '')" ]; then
          _fm_status_at_epoch "$line" epoch || epoch=unknown
        fi
        note="$epoch"$'\t'"$note"
      fi
      open=$(ref_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    "$resolve"|"$held")
      open=$(ref_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      ;;
  esac
  printf '%s' "$open"
}
ref_fold_file() {  # <seed> <file> <kind> [timed]
  local open=$1 file=$2 kind=$3 timed=${4:-} line
  local resolve=$FM_CLASSIFY_RESOLVE_VERB_DEFAULT held=$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(ref_fold_line "$open" "$line" "$resolve" "$held" "$kind" "$timed")
  done < "$file"
  printf '%s' "$open"
}

# --- deterministic log generator --------------------------------------------
# Few keys and many openings, resolutions and terminals, so keys are reopened
# and closed over and over; the templates cover every shape the readers accept
# or must refuse.
gen_log() {  # <seed> <lines> -> log on stdout
  local seed=$1 count=$2 i=0 k n
  local -a keys=(a b c default k.1 k-2 k_3 api-shape pending-reply-x imposed-hold-y captain-hold-z 'bad key' 'x]y')
  RANDOM=$seed
  while [ "$i" -lt "$count" ]; do
    k=${keys[RANDOM % ${#keys[@]}]}
    n=$((RANDOM % 1000))
    case $((RANDOM % 32)) in
      0|1|2) printf 'needs-decision [key=%s]: question %s\n' "$k" "$n" ;;
      3|4) printf 'blocked [key=%s]: obstacle %s\n' "$k" "$n" ;;
      5) printf 'needs-decision: [key=%s] colon first %s\n' "$k" "$n" ;;
      6) printf 'needs-decision: keyless %s\n' "$n" ;;
      7|8) printf 'resolved [key=%s]: answered %s\n' "$k" "$n" ;;
      9) printf 'resolved: closes default %s\n' "$n" ;;
      10) printf 'captain-held [key=%s]: moved %s\n' "$k" "$n" ;;
      11) printf 'done: shipped %s\n' "$n" ;;
      12) printf 'failed [key=%s]: gave up %s\n' "$k" "$n" ;;
      13) printf 'working [at=%s]: routine %s\n' "$((1700000000 + n))" "$n" ;;
      14) printf 'needs-decision [key=%s] [at=%s]: stamped %s\n' "$k" "$((1700000000 + n))" "$n" ;;
      15) printf 'needs-decision [at=10:%02d] [key=%s]: readable time %s\n' "$((n % 60))" "$k" "$n" ;;
      16) printf 'blocked [at=%s] [key=%s]: stamp first %s\n' "$((1700000000 + n))" "$k" "$n" ;;
      17) printf 'needs-decision corr=0123456789abcdef [key=%s]: corr token %s\n' "$k" "$n" ;;
      18) printf 'resolved corr=0123456789abcdef [key=%s]: corr close %s\n' "$k" "$n" ;;
      19) printf 'needs-decision [key=%s] [at=%s] [at=%s]: duplicate stamp %s\n' "$k" "$n" "$n" "$n" ;;
      20) printf 'working: prose mentioning [key=%s] deeper in the note %s\n' "$k" "$n" ;;
      21) printf 'needs-decision [key=%s]\n' "$k" ;;
      22) printf 'continuation prose with no verb at all %s\n' "$n" ;;
      23) printf '\n' ;;
      24) printf 'pending-reply-x: pending-reply-missed: note %s\n' "$n" ;;
      25) printf 'needs-decision [key=pending-reply-x]: pending-reply-missed: real %s\n' "$n" ;;
      26) printf 'resolved [key=pending-reply-x]: pending-reply-resolved: close %s\n' "$n" ;;
      27) printf 'needs-decision [key=a]: tab\there %s\n' "$n" ;;
      28) printf 'resolved x=1 [key=%s]: not a transition %s\n' "$k" "$n" ;;
      29) printf '   needs-decision   [key=%s]  :   spaced %s\n' "$k" "$n" ;;
      30) printf 'blocked [key=%s]: line without newline at the end %s' "$k" "$n"; printf '\n' ;;
      31) printf 'done [key=%s]: later keyed done %s\n' "$k" "$n" ;;
    esac
    i=$((i + 1))
  done
}

test_stream_fold_matches_reference_for_every_kind_and_view() {
  local seed kind timed log want got lines=300
  for seed in 1 2 3 4 5 6; do
    log="$TMP_ROOT/log-$seed.status"
    gen_log "$seed" "$lines" > "$log"
    for kind in ship scout secondmate unknown; do
      for timed in '' timed; do
        want=$(ref_fold_file '' "$log" "$kind" "$timed"; printf x); want=${want%x}
        got=$(_fm_decision_fold_file '' "$log" "$FM_CLASSIFY_RESOLVE_VERB_DEFAULT" \
          "$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT" "$kind" "$timed"; printf x)
        got=${got%x}
        [ "$got" = "$want" ] \
          || fail "seed $seed kind $kind view '${timed:-plain}': stream fold differs from the reference
want: $want
got:  $got"
      done
    done
  done
  # The generator must exercise a non-trivial open set, or the comparison is empty.
  [ -n "$(ref_fold_file '' "$TMP_ROOT/log-1.status" secondmate)" ] \
    || fail "generated log folds to an empty set, so the comparison proves nothing"
  pass "the stream fold equals the per-line reference over generated logs, every kind, plain and timed"
}

test_status_open_decisions_matches_reference() {
  local seed log want got
  for seed in 7 8 9; do
    log="$TMP_ROOT/whole-$seed.status"
    gen_log "$seed" 400 > "$log"
    printf 'kind=secondmate\n' > "$TMP_ROOT/whole-$seed.meta"
    want=$(ref_fold_file '' "$log" secondmate; printf x); want=${want%x}
    got=$(status_open_decisions "$log"; printf x); got=${got%x}
    [ "$got" = "$want" ] || fail "seed $seed: status_open_decisions differs from the reference"
    want=$(ref_fold_file '' "$log" ship; printf x); want=${want%x}
    got=$(status_open_decisions "$log" ship; printf x); got=${got%x}
    [ "$got" = "$want" ] || fail "seed $seed: ship-kind status_open_decisions differs from the reference"
  done
  pass "status_open_decisions equals the reference for the meta kind and an explicit kind"
}

test_incremental_fold_matches_reference_split_at_any_boundary() {
  local seed log cut total step want got part cursor dir
  for seed in 11 12; do
    dir="$TMP_ROOT/inc-$seed"; mkdir -p "$dir"
    log="$dir/task.status"
    printf 'kind=secondmate\n' > "$dir/task.meta"
    gen_log "$seed" 300 > "$TMP_ROOT/inc-$seed.full"
    total=$(wc -l < "$TMP_ROOT/inc-$seed.full")
    : > "$log"
    cut=0
    for step in 37 53 11 97 3 200; do
      part=$((cut + step)); [ "$part" -le "$total" ] || part=$total
      sed -n "$((cut + 1)),${part}p" "$TMP_ROOT/inc-$seed.full" >> "$log"
      cut=$part
      got=$(status_open_decisions_incremental "$log"; printf x); got=${got%x}
      want=$(ref_fold_file '' "$log" secondmate; printf x); want=${want%x}
      [ "$got" = "$want" ] \
        || fail "seed $seed after $cut lines: cursor-backed fold differs from the reference"
      got=$(status_open_decisions_incremental "$log" '' timed; printf x); got=${got%x}
      want=$(ref_fold_file '' "$log" secondmate timed; printf x); want=${want%x}
      [ "$got" = "$want" ] \
        || fail "seed $seed after $cut lines: timed cursor-backed fold differs from the reference"
    done
  done
  pass "the cursor-backed fold equals the reference after every append, plain and timed"
}

test_drop_matches_reference_on_every_set_shape() {
  local set key want got
  local -a sets=(
    ''
    $'a\tneeds-decision\tq\n'
    $'a\tneeds-decision\tq\nb\tblocked\tr\n'
    $'a\tneeds-decision\tq\nb\tblocked\tr\nc\tneeds-decision\ts\n'
    $'a.b\tneeds-decision\tq\nab\tblocked\tr\n'
    $'a\tneeds-decision\tq\na\tblocked\tdup\nb\tblocked\tr\n'
    $'ab\tneeds-decision\tq\nb\tblocked\ta\tb\n'
    $'a\tneeds-decision\tq'
    $'a\tneeds-decision\tq\n\nb\tblocked\tr\n'
    $'\na\tneeds-decision\tq\n'
    $'a\tneeds-decision\tnote with\ttabs\n'
  )
  for set in "${sets[@]}"; do
    for key in a b c ab a.b zz; do
      want=$(ref_decision_drop "$set" "$key"; printf x); want=${want%x}
      got=$(_fm_decision_drop "$set" "$key"; printf x); got=${got%x}
      [ "$got" = "$want" ] || fail "drop of '$key' from [$set] differs
want: $want
got:  $got"
    done
  done
  pass "_fm_decision_drop equals the line walk on empty, single, duplicate, blank-line and unterminated sets"
}

test_fold_line_matches_reference_line_by_line() {
  local seed line open_new='' open_ref='' kind resolve held timed
  resolve=$FM_CLASSIFY_RESOLVE_VERB_DEFAULT held=$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT
  for kind in ship secondmate; do
    for timed in '' timed; do
      open_new='' open_ref=''
      while IFS= read -r line || [ -n "$line" ]; do
        open_ref=$(ref_fold_line "$open_ref" "$line" "$resolve" "$held" "$kind" "$timed")
        open_new=$(_fm_decision_fold_line "$open_new" "$line" "$resolve" "$held" "$kind" "$timed")
        [ "$open_new" = "$open_ref" ] || fail "kind $kind '${timed:-plain}': fold_line diverged on: $line"
      done < "$TMP_ROOT/log-2.status"
    done
  done
  pass "_fm_decision_fold_line equals the reference after every single line"
}

test_a_seed_with_odd_keys_survives_until_a_terminal_clears_it() {
  local seed got want f="$TMP_ROOT/seed.status"
  seed=$'weird key\tneeds-decision\tq\na\tneeds-decision\tq\n'
  printf 'working: routine\nresolved [key=a]: closed\n' > "$f"
  got=$(_fm_decision_fold_file "$seed" "$f" "$FM_CLASSIFY_RESOLVE_VERB_DEFAULT" "$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT" ship; printf x); got=${got%x}
  want=$'weird key\tneeds-decision\tq'
  [ "$got" = "$want" ] || fail "seeded fold kept the wrong records: $got"
  printf 'done: shipped\n' >> "$f"
  got=$(_fm_decision_fold_file "$seed" "$f" "$FM_CLASSIFY_RESOLVE_VERB_DEFAULT" "$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT" ship; printf x); got=${got%x}
  [ -z "$got" ] || fail "a ship terminal did not clear the seeded set: $got"
  pass "a seeded set keeps unnameable records, loses a closed key, and a ship terminal clears it"
}

fm_test_run \
  test_stream_fold_matches_reference_for_every_kind_and_view \
  test_status_open_decisions_matches_reference \
  test_incremental_fold_matches_reference_split_at_any_boundary \
  test_drop_matches_reference_on_every_set_shape \
  test_fold_line_matches_reference_line_by_line \
  test_a_seed_with_odd_keys_survives_until_a_terminal_clears_it
