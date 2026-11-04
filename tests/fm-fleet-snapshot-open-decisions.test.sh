#!/usr/bin/env bash
# tests/fm-fleet-snapshot-open-decisions.test.sh - the fleet snapshot's
# open-decision set must stay identical to the whole-file fold while paying only
# for status-log bytes appended since the cursor bin/fm-wake-drain.sh keeps
# current, and must never write that cursor itself. Drives the real snapshot and
# the real summary producer, so every assertion is consumer-visible: a published
# hints.open_decisions / decisions_open set, or a read-byte probe proving the
# fold stayed bounded. Cursor states covered: absent, current, truncated,
# replaced, ahead, corrupt in four shapes, and a concurrent cursor advance. Task
# generations covered: a task respawned before its observations are captured,
# one respawned after that capture but before it is published, and one
# respawned inside its own fold.
# A fold that cannot serve the live log - it was retired or truncated under the
# run, or a read failed - falls back to the capture this run already made, so it
# publishes that capture's set: never an empty one, never the stale cursor set,
# and never bytes appended after the capture.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-open-decisions)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
# A fixture can respawn the second task while the first one is being read: this
# endpoint read is the only external call the snapshot makes between capturing
# one task's observations and capturing the next task's.
if [ -n "${FM_TEST_TMUX_HOOK:-}" ] && [ -x "${FM_TEST_TMUX_HOOK}" ] \
   && [ ! -e "${FM_TEST_TMUX_HOOK}.ran" ]; then
  : > "${FM_TEST_TMUX_HOOK}.ran"
  "$FM_TEST_TMUX_HOOK"
fi
case "${1:-}" in
  list-windows) ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

# A home with one secondmate task. Secondmate kind keeps the snapshot's
# lifecycle reconciliation out of the comparison, so the fold is the only thing
# the assertion measures.
make_home() {  # <name> <id> [<kind>]
  local name=$1 id=$2 kind=${3:-secondmate} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/$id"
  printf '# fixture home\n' > "$home/AGENTS.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/$id" \
    "project=alpha" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "yolo=off"
  printf '%s\n' "$home"
}

# Two tasks whose metadata carries a spawn generation, so a fixture can respawn
# b2 while a1 is being read. a1 sorts first, so the snapshot captures a1,
# captures b2, and only then folds a1 before folding b2. Each log carries a
# drain cursor behind an appended decision, so each fold reads a live span.
make_two_task_home() {  # <name>
  local home
  home=$(make_home "$1" a1 secondmate)
  printf 'spawn_gen=1\n' >> "$home/state/a1.meta"
  mkdir -p "$home/projects/b2"
  fm_write_meta "$home/state/b2.meta" \
    "window=firstmate:fm-b2" \
    "worktree=$home/projects/b2" \
    "project=alpha" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "spawn_gen=1"
  printf 'working: a1 is mid task\n' > "$home/state/a1.status"
  printf 'working: b2 generation one\n' > "$home/state/b2.status"
  seed_cursor "$home/state" "$home/state/a1.status" secondmate
  seed_cursor "$home/state" "$home/state/b2.status" secondmate
  printf 'needs-decision [key=a1-open]: waiting\n' >> "$home/state/a1.status"
  printf 'needs-decision [key=oldgen]: waiting on the captain\n' >> "$home/state/b2.status"
  printf '%s\n' "$home"
}


# The oracle: the whole-file fold's own output, normalized the same way the
# snapshot projects it.
oracle_json() {  # <status-file> <kind>
  local tsv
  tsv=$(bash -c '. "$1"; status_open_decisions "$2" "$3"' _ "$CLASSIFY" "$1" "$2")
  printf '%s' "$tsv" | jq -R -s -c '
    [ splits("\n") | select(length > 0)
      | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
      | select(. != null) ] | sort_by(.key)'
}

snapshot_set() {  # <home> <id>
  FM_HOME="$1" PATH="$FAKEBIN:$PATH" "$SNAPSHOT" --json \
    | jq -c --arg id "$2" \
      '[ .tasks[] | select(.id == $id) | .hints.open_decisions[] ] | sort_by(.key)'
}

assert_snapshot_matches_whole_file_fold() {  # <label> <home> <id> <kind>
  local label=$1 home=$2 id=$3 kind=$4 want got
  want=$(oracle_json "$home/state/$id.status" "$kind")
  got=$(snapshot_set "$home" "$id") || fail "$label: the snapshot failed to run"
  [ "$got" = "$want" ] \
    || fail "$label: open set differs from the whole-file fold want=$want got=$got"
}

cursor_sum() {  # <cursor-file>
  [ -e "$1" ] || { printf 'absent\n'; return 0; }
  LC_ALL=C cksum "$1" | cut -d' ' -f1-2
}

# Fold once through the writing path, which is what bin/fm-wake-drain.sh does,
# so the fixture starts from a cursor the snapshot cannot have written.
seed_cursor() {  # <state-dir> <status-file> <kind>
  bash -c '. "$1"; status_open_decisions_incremental "$2" "" "" "$3" >/dev/null' \
    _ "$CLASSIFY" "$2" "$3"
}

last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

file_bytes() {
  LC_ALL=C wc -c < "$1" | tr -d '[:space:]'
}

write_mixed_log() {  # <file>
  {
    printf 'working: starting the task\n'
    printf 'needs-decision [key=api-shape]: pick REST or RPC\n'
    printf 'working: another line\n'
    printf 'blocked [key=quota]: provider quota exhausted\n'
    printf 'resolved [key=quota]: quota restored\n'
    printf 'needs-decision: unkeyed question from the worker\n'
    printf 'needs-decision [key=pending-reply-abc]: unrelated wording\n'
    printf 'needs-decision [key=pending-reply-abc]: pending-reply-abc: real escalation\n'
    printf 'needs-decision [key=reopened]: first ask\n'
    printf 'resolved [key=reopened]: answered\n'
    printf 'blocked [key=reopened]: asked again as a blocker\n'
    printf 'working: closing out\n'
  } > "$1"
}

test_absent_cursor_folds_everything_and_writes_nothing() {
  local home state cursor
  home=$(make_home absent-cursor task1)
  state="$home/state"
  write_mixed_log "$state/task1.status"
  cursor="$state/.task1.open-decisions-cursor"

  assert_snapshot_matches_whole_file_fold "absent cursor" "$home" task1 secondmate
  [ ! -e "$cursor" ] \
    || fail "the snapshot created a cursor the drain owns: $cursor"
  [ -n "$(snapshot_set "$home" task1)" ] \
    || fail "the absent-cursor fold published an empty open set"

  pass "an absent cursor folds the whole log and the snapshot writes no cursor"
}

test_current_cursor_folds_only_appends_and_stays_untouched() {
  local home state cursor probe before want got bytes
  home=$(make_home current-cursor task1)
  state="$home/state"
  probe="$home/probe.tsv"
  : > "$probe"
  write_mixed_log "$state/task1.status"
  seed_cursor "$state" "$state/task1.status" secondmate
  cursor="$state/.task1.open-decisions-cursor"
  [ -s "$cursor" ] || fail "the seeded cursor is empty"
  before=$(cursor_sum "$cursor")

  printf 'needs-decision [key=chosen-shape]: captain picked graphql\n' >> "$state/task1.status"
  printf 'working: routine append\n' >> "$state/task1.status"
  bytes=$(printf 'needs-decision [key=chosen-shape]: captain picked graphql\nworking: routine append\n' | wc -c | tr -d '[:space:]')

  got=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" snapshot_set "$home" task1) \
    || fail "the snapshot failed on a current cursor"
  want=$(oracle_json "$state/task1.status" secondmate)
  [ "$got" = "$want" ] \
    || fail "a current cursor changed the published open set want=$want got=$got"
  case "$want" in
    *chosen-shape*) ;;
    *) fail "the appended decision never reached the published set: $want" ;;
  esac
  [ "$(last_probe_bytes "$probe" "$state/task1.status")" = "$bytes" ] \
    || fail "the fold read $(last_probe_bytes "$probe" "$state/task1.status") bytes, expected the $bytes appended"
  [ "$(cursor_sum "$cursor")" = "$before" ] \
    || fail "the snapshot rewrote the cursor the drain owns"
  [ "$(last_probe_bytes "$probe" "$state/task1.status")" -lt "$(file_bytes "$state/task1.status")" ] \
    || fail "the fold re-read the whole log instead of the appended tail"

  pass "a current cursor folds only appended bytes and the snapshot leaves it untouched"
}

test_stale_replaced_and_ahead_cursors_refold_read_only() {
  local home state cursor before
  home=$(make_home stale-cursor task1)
  state="$home/state"
  cursor="$state/.task1.open-decisions-cursor"
  write_mixed_log "$state/task1.status"
  seed_cursor "$state" "$state/task1.status" secondmate
  before=$(cursor_sum "$cursor")

  # Truncated: the log shrinks under a cursor that recorded a larger offset.
  {
    printf 'working: rewritten short log\n'
    printf 'needs-decision [key=after-truncate]: still open\n'
  } > "$state/task1.status"
  assert_snapshot_matches_whole_file_fold "truncated cursor" "$home" task1 secondmate
  [ "$(cursor_sum "$cursor")" = "$before" ] \
    || fail "a truncated log made the snapshot rewrite the cursor"

  # Replaced: a different file of the same byte size at the same path, which
  # only a device+inode identity check can catch. The write must land on a new
  # inode (a same-inode in-place rewrite is the documented accepted gap).
  seed_cursor "$state" "$state/task1.status" secondmate
  before=$(cursor_sum "$cursor")
  size=$(file_bytes "$state/task1.status")
  printf 'needs-decision [key=after-replace]: replacement\n' > "$home/replacement.pad"
  while [ "$(file_bytes "$home/replacement.pad")" -lt "$size" ]; do
    printf 'working: pad\n' >> "$home/replacement.pad"
  done
  head -c "$size" "$home/replacement.pad" > "$home/replacement.sized"
  mv -f "$home/replacement.sized" "$state/task1.status"
  assert_snapshot_matches_whole_file_fold "replaced cursor" "$home" task1 secondmate
  [ "$(cursor_sum "$cursor")" = "$before" ] \
    || fail "a replaced log made the snapshot rewrite the cursor"

  # Ahead: a cursor whose offset is past the end of the file.
  sed 's/^offset=.*/offset=999999/' "$cursor" > "$home/ahead.cursor"
  cp "$home/ahead.cursor" "$cursor"
  before=$(cursor_sum "$cursor")
  assert_snapshot_matches_whole_file_fold "ahead cursor" "$home" task1 secondmate
  [ "$(cursor_sum "$cursor")" = "$before" ] \
    || fail "an ahead cursor made the snapshot rewrite the cursor"

  pass "stale, replaced, and ahead cursors refold read-only and match the whole-file fold"
}

# With no usable cursor the per-line incremental refold is far slower than the
# whole-file fold, so the snapshot must fold its capture with the latter and
# never run the incremental span fold at all.
test_unusable_cursor_skips_the_incremental_refold() {
  local home state cursor probe
  home=$(make_home cold-cursor task1)
  state="$home/state"
  cursor="$state/.task1.open-decisions-cursor"
  probe="$home/probe.tsv"
  write_mixed_log "$state/task1.status"

  : > "$probe"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" assert_snapshot_matches_whole_file_fold \
    "cold cursor" "$home" task1 secondmate
  [ -z "$(last_probe_bytes "$probe" "$state/task1.status")" ] \
    || fail "an absent cursor ran the incremental refold from byte 0"

  printf 'not a cursor at all\n' > "$cursor"
  : > "$probe"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" assert_snapshot_matches_whole_file_fold \
    "corrupt cursor" "$home" task1 secondmate
  [ -z "$(last_probe_bytes "$probe" "$state/task1.status")" ] \
    || fail "a corrupt cursor ran the incremental refold from byte 0"

  pass "an unusable cursor folds the capture instead of refolding incrementally"
}

test_corrupt_cursor_shapes_refold_read_only() {
  local home state cursor shape ident before
  home=$(make_home corrupt-cursor task1)
  state="$home/state"
  cursor="$state/.task1.open-decisions-cursor"
  write_mixed_log "$state/task1.status"
  seed_cursor "$state" "$state/task1.status" secondmate
  ident=$(sed -n 's/^ident=//p' "$cursor")

  for shape in garbage pre-version-offset missing-ident empty-file; do
    case "$shape" in
      garbage) printf 'not a cursor at all\n' > "$cursor" ;;
      pre-version-offset) printf 'version=3\noffset=1\nident=%s\n' "$ident" > "$cursor" ;;
      missing-ident) printf 'version=9:secondmate\noffset=0\n' > "$cursor" ;;
      empty-file) : > "$cursor" ;;
    esac
    before=$(cursor_sum "$cursor")
    assert_snapshot_matches_whole_file_fold "corrupt cursor ($shape)" "$home" task1 secondmate
    [ "$(cursor_sum "$cursor")" = "$before" ] \
      || fail "a corrupt cursor ($shape) was rewritten by the snapshot"
  done

  pass "every corrupt cursor shape refolds read-only and matches the whole-file fold"
}

test_invalid_bytes_and_reserved_keys_match_the_whole_file_fold() {
  local home state
  home=$(make_home invalid-bytes task1)
  state="$home/state"
  write_mixed_log "$state/task1.status"
  printf 'needs-decision [key=raw-byte]: caf\351 latin-1 continuation\n' >> "$state/task1.status"
  printf 'working: raw \377\376 filler\n' >> "$state/task1.status"

  assert_snapshot_matches_whole_file_fold "invalid bytes" "$home" task1 secondmate
  case "$(snapshot_set "$home" task1)" in
    *raw-byte*) ;;
    *) fail "a decision line carrying invalid UTF-8 was lost" ;;
  esac
  case "$(snapshot_set "$home" task1)" in
    *pending-reply-abc*) ;;
    *) fail "the reserved-namespace transition never surfaced" ;;
  esac

  pass "invalid UTF-8 and reserved-key lines match the whole-file fold"
}

# A read failure inside the read-only fold does not publish the cursor's stale
# set: the row falls back to folding the capture this run already made, which
# holds the bytes the failed span could not read.
test_unreadable_span_falls_back_to_the_capture() {
  local home state cursor before got want
  home=$(make_home unreadable-span task1)
  state="$home/state"
  cursor="$state/.task1.open-decisions-cursor"
  printf 'needs-decision [key=trusted]: still waiting on the captain\n' > "$state/task1.status"
  seed_cursor "$state" "$state/task1.status" secondmate
  before=$(cursor_sum "$cursor")
  printf 'resolved [key=trusted]: answered\n' >> "$state/task1.status"
  printf 'needs-decision [key=unread]: appended but unreadable\n' >> "$state/task1.status"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fail-reader"
  chmod +x "$home/fail-reader"

  got=$(FM_STATUS_SPAN_READER="$home/fail-reader" snapshot_set "$home" task1) \
    || fail "the snapshot failed instead of folding the capture"
  want=$(oracle_json "$state/task1.status" secondmate)
  [ "$got" = "$want" ] \
    || fail "a failed span read did not fall back to the capture want=$want got=$got"
  case "$got" in
    *unread*) ;;
    *) fail "the capture's decision was dropped on a failed span read: $got" ;;
  esac
  [ "$(cursor_sum "$cursor")" = "$before" ] \
    || fail "an unreadable span made the snapshot rewrite the cursor"

  pass "an unreadable span falls back to the capture instead of publishing the stale set"
}

test_concurrent_cursor_advance_does_not_disturb_the_reader() {
  local home state cursor saved racer got want before
  home=$(make_home cursor-race task1)
  state="$home/state"
  cursor="$state/.task1.open-decisions-cursor"
  racer="$home/racing-reader"
  printf 'needs-decision [key=first]: waiting\n' > "$state/task1.status"
  seed_cursor "$state" "$state/task1.status" secondmate
  cp "$cursor" "$home/old.cursor"
  printf 'resolved [key=first]: answered\n' >> "$state/task1.status"
  printf 'needs-decision [key=second]: asked later\n' >> "$state/task1.status"
  seed_cursor "$state" "$state/task1.status" secondmate
  saved="$home/new.cursor"
  cp "$cursor" "$saved"
  cp "$home/old.cursor" "$cursor"
  before=$(cursor_sum "$saved")

  # A second writer (the real drain shape) persists a newer cursor while the
  # snapshot is already folding from the older one it read.
  cat > "$racer" <<SH
#!/usr/bin/env bash
cp "$saved" "$cursor"
exec perl -MFcntl=:DEFAULT -e '
  my (\$path, \$start, \$length) = @ARGV;
  sysopen(my \$file, \$path, O_RDONLY | O_NOFOLLOW) or exit 1;
  sysseek(\$file, \$start, 0) == \$start or exit 1;
  while (\$length > 0) {
    my \$want = \$length > 65536 ? 65536 : \$length;
    my \$read = sysread(\$file, my \$chunk, \$want);
    defined(\$read) && \$read > 0 or exit 1;
    print \$chunk or exit 1;
    \$length -= \$read;
  }
' "\$1" "\$2" "\$3"
SH
  chmod +x "$racer"

  got=$(FM_STATUS_SPAN_READER="$racer" snapshot_set "$home" task1) \
    || fail "the snapshot failed while a second writer advanced the cursor"
  want=$(oracle_json "$state/task1.status" secondmate)
  [ "$got" = "$want" ] \
    || fail "a concurrent cursor advance changed the published set want=$want got=$got"
  [ "$(cursor_sum "$cursor")" = "$before" ] \
    || fail "the snapshot overwrote the newer cursor another writer persisted"

  pass "a concurrent cursor advance leaves the reader's set correct and the newer cursor in place"
}

test_producer_publishes_the_same_set_from_a_bounded_fold() {
  local home state probe cursor bytes i want got
  home=$(make_home producer task1)
  state="$home/state"
  probe="$home/probe.tsv"
  : > "$probe"
  write_mixed_log "$state/task1.status"
  i=0
  while [ "$i" -lt 400 ]; do
    printf 'working: filler line %03d keeping the log long lived\n' "$i" >> "$state/task1.status"
    i=$((i + 1))
  done
  seed_cursor "$state" "$state/task1.status" secondmate
  cursor="$state/.task1.open-decisions-cursor"
  printf 'needs-decision [key=published]: surfaced through the producer\n' >> "$state/task1.status"
  bytes=$(printf 'needs-decision [key=published]: surfaced through the producer\n' | wc -c | tr -d '[:space:]')

  FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_HOME="$home" \
    PATH="$FAKEBIN:$PATH" FM_HOME_SUMMARY_TIMEOUT=60 "$WRITER" \
    || fail "the summary producer failed on a home carrying a long status log"
  [ -s "$state/home-summary.json" ] || fail "the producer published no ledger"
  got=$(jq -c '[.decisions_open[] | {key,verb}] | sort_by(.key)' "$state/home-summary.json")
  want=$(oracle_json "$state/task1.status" secondmate \
    | jq -c '[ .[] | {key,verb} ] | sort_by(.key)')
  [ "$got" = "$want" ] \
    || fail "the published decision set differs from the whole-file fold want=$want got=$got"
  case "$got" in
    *published*) ;;
    *) fail "the appended decision never reached the published ledger: $got" ;;
  esac
  [ "$(last_probe_bytes "$probe" "$state/task1.status")" = "$bytes" ] \
    || fail "the producer folded $(last_probe_bytes "$probe" "$state/task1.status") bytes, expected the $bytes appended"
  [ "$(file_bytes "$state/task1.status")" -gt 1000 ] \
    || fail "the fixture log is too small to prove a bounded fold"

  pass "the summary producer publishes the whole-file set from a bounded fold"
}

# A row is published under the generation captured in the manifest. The status
# log is only appended to within a generation, so a respawn is a metadata
# generation change plus a fresh log at the same path.
test_generation_change_before_capture_publishes_no_foreign_decision() {
  local home breaker got
  home=$(make_two_task_home gen-before-capture)
  breaker="$home/respawn-hook"
  cat > "$breaker" <<SH
#!/usr/bin/env bash
sed 's/^spawn_gen=.*/spawn_gen=2/' "$home/state/b2.meta" > "$home/state/b2.meta.next" \\
  && mv -f "$home/state/b2.meta.next" "$home/state/b2.meta"
printf 'working: b2 generation two\nneeds-decision [key=newgen]: asked after the respawn\n' \\
  > "$home/state/b2.status.next"
mv -f "$home/state/b2.status.next" "$home/state/b2.status"
SH
  chmod +x "$breaker"

  got=$(FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 FM_TEST_TMUX_HOOK="$breaker" \
    snapshot_set "$home" b2) \
    || fail "the snapshot failed while a task was respawned before it was captured"
  [ -e "$breaker.ran" ] || fail "the respawn hook never fired, so the race was never exercised"
  [ "$got" = '[]' ] \
    || fail "a row captured before its respawn published the next generation's decision: $got"

  pass "a task respawned before its capture publishes no foreign-generation decision"
}

test_generation_change_after_capture_keeps_the_captured_set() {
  local home reader got
  home=$(make_two_task_home gen-after-capture)
  reader="$home/respawn-reader"
  cat > "$reader" <<SH
#!/usr/bin/env bash
# The span read of the first task's fold happens after both tasks were
# captured and before the second task is folded.
if [ ! -e "$home/respawned" ]; then
  : > "$home/respawned"
  sed 's/^spawn_gen=.*/spawn_gen=2/' "$home/state/b2.meta" > "$home/state/b2.meta.next" \\
    && mv -f "$home/state/b2.meta.next" "$home/state/b2.meta"
  printf 'working: b2 generation two\nneeds-decision [key=newgen]: asked after the respawn\n' \\
    > "$home/state/b2.status.next"
  mv -f "$home/state/b2.status.next" "$home/state/b2.status"
fi
exec perl -MFcntl=:DEFAULT -e '
  my (\$path, \$start, \$length) = @ARGV;
  sysopen(my \$file, \$path, O_RDONLY | O_NOFOLLOW) or exit 1;
  sysseek(\$file, \$start, 0) == \$start or exit 1;
  while (\$length > 0) {
    my \$want = \$length > 65536 ? 65536 : \$length;
    my \$read = sysread(\$file, my \$chunk, \$want);
    defined(\$read) && \$read > 0 or exit 1;
    print \$chunk or exit 1;
    \$length -= \$read;
  }
' "\$1" "\$2" "\$3"
SH
  chmod +x "$reader"

  got=$(FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 FM_STATUS_SPAN_READER="$reader" \
    snapshot_set "$home" b2) \
    || fail "the snapshot failed while a captured task was respawned mid-read"
  [ -e "$home/respawned" ] || fail "the respawn hook never fired, so the race was never exercised"
  case "$got" in
    *oldgen*) ;;
    *) fail "the captured generation's decision was lost: $got" ;;
  esac
  case "$got" in
    *newgen*) fail "the row published a decision from the generation that replaced it: $got" ;;
  esac

  pass "a task respawned after its capture still publishes the captured generation's set"
}

# The composition-time generation check already passed, so a respawn can only
# land inside the fold itself. The identity seam runs on the live path just
# before the span read, which is exactly that window: the fold sees the new
# log, and the recheck after it must still publish the captured generation.
test_respawn_inside_the_fold_publishes_the_captured_set() {
  local home ident got want
  home=$(make_two_task_home gen-inside-fold)
  cp "$home/state/b2.status" "$home/captured-b2.status"
  ident="$home/respawn-identity"
  cat > "$ident" <<SH
#!/usr/bin/env bash
case "\$1" in
  */b2.status)
    if [ ! -e "$home/respawned" ]; then
      : > "$home/respawned"
      sed 's/^spawn_gen=.*/spawn_gen=2/' "$home/state/b2.meta" > "$home/state/b2.meta.next" \\
        && mv -f "$home/state/b2.meta.next" "$home/state/b2.meta"
      printf 'working: b2 generation two\nneeds-decision [key=newgen]: asked after the respawn\n' \\
        > "$home/state/b2.status.next"
      mv -f "$home/state/b2.status.next" "$home/state/b2.status"
    fi
    ;;
esac
out=\$(LC_ALL=C stat -c '%d:%i' "\$1" 2>/dev/null) || out=\$(LC_ALL=C stat -f '%d:%i' "\$1")
printf 'weak:%s\n' "\$out"
SH
  chmod +x "$ident"

  got=$(FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 FM_STATUS_IDENTITY_READER="$ident" \
    snapshot_set "$home" b2) \
    || fail "the snapshot failed while a task was respawned inside its fold"
  [ -e "$home/respawned" ] || fail "the respawn hook never fired, so the race was never exercised"
  want=$(oracle_json "$home/captured-b2.status" secondmate)
  [ "$got" = "$want" ] \
    || fail "a respawn inside the fold changed the published set want=$want got=$got"
  case "$got" in
    *newgen*) fail "the row published the generation that replaced it: $got" ;;
  esac

  pass "a task respawned inside its fold still publishes the captured generation's set"
}

# Teardown retires a task's status log before its metadata, so the generation
# still matches while the live log is already gone.
test_retired_log_falls_back_to_the_capture() {
  local home reader got want
  home=$(make_two_task_home retired-log)
  cp "$home/state/b2.status" "$home/captured-b2.status"
  reader="$home/retire-reader"
  cat > "$reader" <<SH
#!/usr/bin/env bash
# The first task's span read runs after both captures, so retiring the second
# task's log here lands between its capture and its fold.
case "\$1" in
  */a1.status)
    if [ ! -e "$home/retired" ]; then
      : > "$home/retired"
      mv "$home/state/b2.status" "$home/state/b2.status.retired"
    fi
    ;;
esac
exec perl -MFcntl=:DEFAULT -e '
  my (\$path, \$start, \$length) = @ARGV;
  sysopen(my \$file, \$path, O_RDONLY | O_NOFOLLOW) or exit 1;
  sysseek(\$file, \$start, 0) == \$start or exit 1;
  while (\$length > 0) {
    my \$want = \$length > 65536 ? 65536 : \$length;
    my \$read = sysread(\$file, my \$chunk, \$want);
    defined(\$read) && \$read > 0 or exit 1;
    print \$chunk or exit 1;
    \$length -= \$read;
  }
' "\$1" "\$2" "\$3"
SH
  chmod +x "$reader"

  got=$(FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 FM_STATUS_SPAN_READER="$reader" \
    snapshot_set "$home" b2) \
    || fail "the snapshot failed while a captured task's log was retired"
  [ -e "$home/retired" ] || fail "the retire hook never fired, so the window was never exercised"
  want=$(oracle_json "$home/captured-b2.status" secondmate)
  [ "$got" = "$want" ] \
    || fail "a retired log did not fall back to the capture want=$want got=$got"
  [ -n "$got" ] || fail "a retired log published an empty set while the capture held a decision"

  pass "a log retired after its capture still publishes the captured set"
}

# With no cursor at all, a failed read has no set of its own to report.
test_failed_read_without_a_cursor_falls_back_to_the_capture() {
  local home state got want
  home=$(make_home unreadable-no-cursor task1)
  state="$home/state"
  printf 'needs-decision [key=captured-only]: asked before the run\n' > "$state/task1.status"
  printf 'working: routine line\n' >> "$state/task1.status"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fail-reader"
  chmod +x "$home/fail-reader"

  got=$(FM_STATUS_SPAN_READER="$home/fail-reader" snapshot_set "$home" task1) \
    || fail "the snapshot failed instead of folding the capture"
  want=$(oracle_json "$state/task1.status" secondmate)
  [ "$got" = "$want" ] \
    || fail "a failed read without a cursor published want=$want got=$got"
  case "$got" in
    *captured-only*) ;;
    *) fail "a failed read without a cursor dropped the capture's decision: $got" ;;
  esac
  [ ! -e "$state/.task1.open-decisions-cursor" ] \
    || fail "a read-only fallback wrote a cursor the drain owns"

  pass "a failed read with no cursor falls back to the capture"
}

# The drain's cursor is behind the capture, so only the capture bound can keep
# bytes appended after the capture out of the published set.
test_bytes_appended_after_the_capture_stay_out() {
  local home reader got want
  home=$(make_two_task_home append-after-capture)
  cp "$home/state/b2.status" "$home/captured-b2.status"
  reader="$home/append-reader"
  cat > "$reader" <<SH
#!/usr/bin/env bash
case "\$1" in
  */a1.status)
    if [ ! -e "$home/appended" ]; then
      : > "$home/appended"
      { cat "$home/captured-b2.status"; printf 'needs-decision [key=later]: appended after the capture\n'; } \\
        > "$home/state/b2.status.next"
      mv -f "$home/state/b2.status.next" "$home/state/b2.status"
    fi
    ;;
esac
exec perl -MFcntl=:DEFAULT -e '
  my (\$path, \$start, \$length) = @ARGV;
  sysopen(my \$file, \$path, O_RDONLY | O_NOFOLLOW) or exit 1;
  sysseek(\$file, \$start, 0) == \$start or exit 1;
  while (\$length > 0) {
    my \$want = \$length > 65536 ? 65536 : \$length;
    my \$read = sysread(\$file, my \$chunk, \$want);
    defined(\$read) && \$read > 0 or exit 1;
    print \$chunk or exit 1;
    \$length -= \$read;
  }
' "\$1" "\$2" "\$3"
SH
  chmod +x "$reader"

  got=$(FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 FM_STATUS_SPAN_READER="$reader" \
    snapshot_set "$home" b2) \
    || fail "the snapshot failed while bytes were appended after the capture"
  [ -e "$home/appended" ] || fail "the append hook never fired, so the bound was never exercised"
  want=$(oracle_json "$home/captured-b2.status" secondmate)
  [ "$got" = "$want" ] \
    || fail "bytes appended after the capture reached the published set want=$want got=$got"
  case "$got" in
    *later*) fail "the fold read past the capture bound: $got" ;;
  esac

  pass "bytes appended after the capture stay out of the published set"
}

fm_test_run \
  test_absent_cursor_folds_everything_and_writes_nothing \
  test_current_cursor_folds_only_appends_and_stays_untouched \
  test_stale_replaced_and_ahead_cursors_refold_read_only \
  test_unusable_cursor_skips_the_incremental_refold \
  test_corrupt_cursor_shapes_refold_read_only \
  test_invalid_bytes_and_reserved_keys_match_the_whole_file_fold \
  test_unreadable_span_falls_back_to_the_capture \
  test_concurrent_cursor_advance_does_not_disturb_the_reader \
  test_producer_publishes_the_same_set_from_a_bounded_fold \
  test_generation_change_before_capture_publishes_no_foreign_decision \
  test_generation_change_after_capture_keeps_the_captured_set \
  test_respawn_inside_the_fold_publishes_the_captured_set \
  test_retired_log_falls_back_to_the_capture \
  test_failed_read_without_a_cursor_falls_back_to_the_capture \
  test_bytes_appended_after_the_capture_stay_out
