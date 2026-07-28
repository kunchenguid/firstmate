#!/usr/bin/env bash
# Behavior tests for durable, private, idempotent link-intake records.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-link-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-link-intake)
REAL_MV=$(command -v mv)
REAL_RM=$(command -v rm)
REAL_LN=$(command -v ln)
REAL_READLINK=$(command -v readlink)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

run_intake() {  # <home> <arguments...>
  local home=$1
  shift
  FM_HOME="$home" "$INTAKE" "$@"
}

make_failing_tools() {  # <home>
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ] && [ "${FM_EMULATE_GNU_MV:-}" = 1 ]; then
  printf '%s\n' '  -T, --no-target-directory'
  exit 0
fi
if [ "${1:-}" = -fT ] && [ "${FM_EMULATE_GNU_MV:-}" = 1 ]; then
  if "${FM_REAL_MV:?}" --help 2>&1 | grep -F -q -- '--no-target-directory'; then
    exec "$FM_REAL_MV" "$@"
  fi
  shift
  exec "$FM_REAL_MV" -fh "$@"
fi
destination=
source=
for argument in "$@"; do
  case "$argument" in
    -*) ;;
    *) [ -n "$source" ] || source=$argument ;;
  esac
  destination=$argument
done
if [ "$destination" = "${FM_FAIL_MOVE_DEST:-}" ] && [ ! -e "${FM_FAIL_MOVE_ONCE:?}" ]; then
  : > "$FM_FAIL_MOVE_ONCE"
  exit 1
fi
if [ "$destination" = "${FM_KILL_MOVE_DEST:-}" ] && [ ! -e "${FM_KILL_MOVE_ONCE:?}" ]; then
  : > "$FM_KILL_MOVE_ONCE"
  kill -KILL "$PPID"
  exit 1
fi
if [ "$destination" = "${FM_SIGNAL_MOVE_DEST:-}" ] && [ ! -e "${FM_SIGNAL_MOVE_ONCE:?}" ]; then
  : > "$FM_SIGNAL_MOVE_ONCE"
  "${FM_REAL_MV:?}" "$@"
  status=$?
  kill -TERM "$PPID"
  exit "$status"
fi
if [ "$source" = "${FM_QUARANTINE_SOURCE:-}" ]; then
  case "$destination" in
    "${FM_QUARANTINE_PREFIX:-}"*)
      "${FM_REAL_MV:?}" "$@"
      status=$?
      [ "$status" -ne 0 ] || : > "${FM_QUARANTINE_MARKER:?}"
      exit "$status"
      ;;
  esac
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
destination=
for argument in "$@"; do
  destination=$argument
done
if [ "$destination" = "${FM_GUARDED_REMOVE_DEST:-}" ] && [ ! -e "${FM_QUARANTINE_MARKER:?}" ]; then
  exit 1
fi
if [ -n "${FM_FAIL_REMOVE_PREFIX:-}" ]; then
  case "$destination" in
    "$FM_FAIL_REMOVE_PREFIX"*)
      if [ ! -e "${FM_FAIL_REMOVE_ONCE:?}" ]; then
        : > "$FM_FAIL_REMOVE_ONCE"
        exit 1
      fi
      ;;
  esac
fi
exec "${FM_REAL_RM:?}" "$@"
SH
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
destination=
for argument in "$@"; do
  destination=$argument
done
if [ "$destination" = "${FM_KILL_LINK_DEST:-}" ] && [ ! -e "${FM_KILL_LINK_ONCE:?}" ]; then
  : > "$FM_KILL_LINK_ONCE"
  kill -KILL "$PPID"
  exit 1
fi
exec "${FM_REAL_LN:?}" "$@"
SH
  cat > "$fakebin/readlink" <<'SH'
#!/usr/bin/env bash
set -u
path=
for argument in "$@"; do
  path=$argument
done
if [ "$path" = "${FM_FAIL_READLINK_PATH:-}" ] \
  && [ -e "${FM_FAIL_READLINK_AFTER:-}" ] \
  && [ ! -e "${FM_FAIL_READLINK_ONCE:?}" ]; then
  : > "$FM_FAIL_READLINK_ONCE"
  exit 1
fi
exec "${FM_REAL_READLINK:?}" "$@"
SH
  chmod +x "$fakebin/mv"
  chmod +x "$fakebin/rm"
  chmod +x "$fakebin/ln"
  chmod +x "$fakebin/readlink"
  printf '%s\n' "$fakebin"
}

current_root() {  # <home>
  local home=$1 target
  target=$(readlink "$home/data/link-intake/current") || fail 'current generation link is absent'
  printf '%s/data/link-intake/%s\n' "$home" "$target"
}

test_process_start_identity() {
  TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | awk 'NF { $1=$1; print; exit }'
}

record_for() {  # <home> <url>
  local home=$1 url=$2 result
  result=$(run_intake "$home" validate "$url") || fail 'expected record did not validate'
  printf '%s\n' "${result#valid: }"
}

test_canonical_duplicate_converges_and_preserves_evidence() {
  local home first second record history count
  home=$(make_home duplicate)
  first=$(run_intake "$home" upsert --url 'HTTPS://Example.com:443/watch?b=2#chapter' --source-type web --title 'First title' --summary 'A searchable first summary.' --terms 'first,example' --claim 'First claim.') \
    || fail 'first URL intake failed'
  second=$(run_intake "$home" upsert --url 'https://example.com/watch?b=2' --source-type web --title 'Updated title' --summary 'A newer searchable summary.' --terms 'updated,example' --claim 'Updated claim.') \
    || fail 'duplicate URL intake failed'
  [ "$first" = "$second" ] || fail 'canonical duplicate created a second record path'
  count=$(find "$(current_root "$home")/records" -type f -name '*.md' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail 'canonical duplicate created multiple records'
  record=$second
  assert_grep 'Canonical URL: https://example.com/watch?b=2' "$record" 'canonical URL was not normalized'
  assert_grep '- HTTPS://Example.com:443/watch?b=2#chapter' "$record" 'first original URL was not retained'
  assert_grep '- https://example.com/watch?b=2' "$record" 'second original URL was not retained'
  assert_grep 'Updated title' "$record" 'current title was not updated'
  history=$(find "$(current_root "$home")/history" -type f -name '*.md' | head -1)
  assert_present "$history" 'replaced record did not retain an immutable history snapshot'
  assert_grep 'First title' "$history" 'history snapshot lost prior evidence'
  pass 'canonical duplicate convergence retains original URLs and prior evidence'
}

test_titles_summaries_claims_and_terms_are_searchable() {
  local home record index
  home=$(make_home searchable)
  run_intake "$home" upsert --url 'https://example.org/research' --source-type article --title 'Research Title' --summary 'Concise searchable summary of the research.' --terms 'research,searchable,summary' --claim 'The source makes a testable claim.' >/dev/null \
    || fail 'searchable intake failed'
  record=$(record_for "$home" 'https://example.org/research')
  index="$(current_root "$home")/index.tsv"
  assert_grep 'Title: Research Title' "$record" 'record title is missing'
  assert_grep 'Summary: Concise searchable summary of the research.' "$record" 'record summary is missing'
  assert_grep '- The source makes a testable claim.' "$record" 'record claim is missing'
  assert_grep 'Search terms: research,searchable,summary' "$record" 'record terms are missing'
  assert_grep 'research,searchable,summary' "$index" 'searchable terms are absent from index'
  pass 'titles, summaries, claims, and terms are durably searchable'
}

test_inaccessible_links_remain_visible_and_valid() {
  local home record
  home=$(make_home inaccessible)
  run_intake "$home" upsert --url 'https://private.example.test/item' --source-type document --failure 'HTTP 403 private source' >/dev/null \
    || fail 'inaccessible intake failed'
  record=$(record_for "$home" 'https://private.example.test/item')
  assert_grep 'Retrieval status: inaccessible' "$record" 'inaccessible status is missing'
  assert_grep 'Title: Unavailable' "$record" 'inaccessible record lacks a visible title outcome'
  assert_grep 'Failure: HTTP 403 private source' "$record" 'inaccessible reason is missing'
  assert_grep 'Canonical URL: https://private.example.test/item' "$record" 'inaccessible original was not retained'
  pass 'inaccessible links retain a validated visible failure record'
}

test_video_transcript_metadata_is_durable() {
  local home transcript record transcript_path
  home=$(make_home transcript)
  transcript="$home/source-transcript.txt"
  printf 'A legally accessible transcript.\n' > "$transcript"
  run_intake "$home" upsert --url 'https://video.example.test/watch?v=42' --source-type video --title 'Video title' --summary 'A short video summary.' --terms 'video,transcript' --claim 'The video makes a claim.' --transcript-file "$transcript" >/dev/null \
    || fail 'video transcript intake failed'
  record=$(record_for "$home" 'https://video.example.test/watch?v=42')
  transcript_path=$(sed -n 's/^Transcript: stored at //p' "$record")
  [ -n "$transcript_path" ] || fail 'record did not store transcript metadata'
  assert_present "$(current_root "$home")/$transcript_path" 'durable transcript path is missing'
  assert_grep 'A legally accessible transcript.' "$(current_root "$home")/$transcript_path" 'durable transcript body is wrong'
  rm "$(current_root "$home")/$transcript_path"
  if run_intake "$home" validate 'https://video.example.test/watch?v=42' > "$home/missing-path.out" 2> "$home/missing-path.err"; then
    fail 'validation accepted missing durable transcript content'
  fi
  assert_grep 'record transcript path is absent' "$home/missing-path.err" 'missing transcript path failure was not visible'
  if run_intake "$home" upsert --url 'https://video.example.test/no-transcript' --source-type video --title 'Video without transcript' --summary 'No transcript is accessible.' --terms 'video,unavailable' --claim 'Transcript is unavailable.' > "$home/missing.out" 2> "$home/missing.err"; then
    fail 'video intake accepted missing transcript metadata'
  fi
  assert_grep 'transcript-unavailable reason is required' "$home/missing.err" 'missing transcript failure was not visible'
  pass 'video records retain transcripts and reject silent omissions'
}

test_lock_claim_and_symlink_replacement_are_portable() {
  local home fakebin failure_marker rc=0 owners owner_dir owner_start quarantine_marker
  home=$(make_home portable-lock)
  fakebin=$(make_failing_tools "$home")
  failure_marker="$home/lock-link-killed"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" FM_REAL_RM="$REAL_RM" \
    FM_REAL_LN="$REAL_LN" FM_REAL_READLINK="$REAL_READLINK" \
    FM_KILL_LINK_DEST="$home/data/link-intake/.update-lock" FM_KILL_LINK_ONCE="$failure_marker" \
    "$INTAKE" upsert --url 'https://portable.example.test/page' --source-type web --title 'Killed claim' --summary 'The process dies before exposing its lock.' --terms 'lock,killed' --claim 'The fixed lock is never ownerless.' > "$home/killed.out" 2> "$home/killed.err" || rc=$?
  [ "$rc" = 137 ] || fail "SIGKILL before lock claim should exit 137, got $rc"
  [ ! -e "$home/data/link-intake/.update-lock" ] && [ ! -L "$home/data/link-intake/.update-lock" ] \
    || fail 'SIGKILL exposed an ownerless fixed lock'
  run_intake "$home" upsert --url 'https://portable.example.test/page' --source-type web --title 'Recovered claim' --summary 'A later invocation acquires the lock.' --terms 'lock,recovered' --claim 'The abandoned private claim does not block progress.' >/dev/null \
    || fail 'abandoned private lock claim blocked recovery'
  owners=$(find "$home/data/link-intake" -mindepth 1 -maxdepth 1 -name '.lock-owner.*' | wc -l | tr -d ' ')
  [ "$owners" = 0 ] || fail 'lock recovery left an abandoned owner claim'
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" FM_REAL_RM="$REAL_RM" \
    FM_REAL_LN="$REAL_LN" FM_REAL_READLINK="$REAL_READLINK" FM_EMULATE_GNU_MV=1 \
    "$INTAKE" upsert --url 'https://portable.example.test/page' --source-type web --title 'GNU publication' --summary 'GNU no-target replacement commits the generation.' --terms 'gnu,portable' --claim 'The portable selector uses GNU mv syntax.' >/dev/null \
    || fail 'GNU mv publication path failed'
  assert_grep 'Title: GNU publication' "$(record_for "$home" 'https://portable.example.test/page')" 'GNU mv publication did not commit'
  owner_dir="$home/data/link-intake/.lock-owner.recycled"
  owner_start=$(test_process_start_identity "$$")
  mkdir "$owner_dir"
  printf '%s\n%s\n' "$$" "$owner_start" > "$owner_dir/owner"
  ln -s "${owner_dir##*/}" "$home/data/link-intake/.update-lock"
  if run_intake "$home" validate --all > "$home/live-lock.out" 2> "$home/live-lock.err"; then
    fail 'matching live process identity was reclaimed'
  fi
  assert_grep 'another link-intake update is in progress' "$home/live-lock.err" 'live lock identity did not block a second updater'
  rm "$home/data/link-intake/.update-lock"
  printf '%s\n%s\n' "$$" 'Mon Jan 1 00:00:00 2001' > "$owner_dir/owner"
  ln -s "${owner_dir##*/}" "$home/data/link-intake/.update-lock"
  quarantine_marker="$home/lock-quarantined"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" FM_REAL_RM="$REAL_RM" \
    FM_REAL_LN="$REAL_LN" FM_REAL_READLINK="$REAL_READLINK" \
    FM_QUARANTINE_SOURCE="$home/data/link-intake/.update-lock" \
    FM_QUARANTINE_PREFIX="$home/data/link-intake/.stale-update-lock." \
    FM_QUARANTINE_MARKER="$quarantine_marker" \
    FM_GUARDED_REMOVE_DEST="$home/data/link-intake/.update-lock" \
    "$INTAKE" validate --all >/dev/null \
    || fail 'recycled PID lock recovery failed'
  assert_present "$quarantine_marker" 'stale fixed lock was not atomically quarantined'
  [ ! -e "$owner_dir" ] || fail 'stale owner claim survived quarantine recovery'
  pass 'lock claims use portable replacement, atomic quarantine, and process-start identity'
}

test_lock_identity_is_timezone_stable_and_upgrade_safe() {
  local home owner_dir owner_start
  home=$(make_home lock-identity)
  run_intake "$home" upsert --url 'https://identity.example.test/page' --source-type web --title 'Identity baseline' --summary 'The lock identity has durable baseline state.' --terms 'lock,identity' --claim 'Process ownership remains exclusive.' >/dev/null \
    || fail 'lock identity baseline intake failed'
  owner_dir="$home/data/link-intake/.lock-owner.compatibility"
  owner_start=$(TZ=HST10 test_process_start_identity "$$")
  mkdir "$owner_dir"
  printf '%s\n%s\n' "$$" "$owner_start" > "$owner_dir/owner"
  ln -s "${owner_dir##*/}" "$home/data/link-intake/.update-lock"
  if TZ=JST-9 FM_HOME="$home" "$INTAKE" validate --all > "$home/timezone-lock.out" 2> "$home/timezone-lock.err"; then
    fail 'caller timezone changed a live lock identity'
  fi
  assert_grep 'another link-intake update is in progress' "$home/timezone-lock.err" 'timezone-stable live lock did not block a second updater'
  rm "$home/data/link-intake/.update-lock"
  printf '%s\n' "$$" > "$owner_dir/owner"
  ln -s "${owner_dir##*/}" "$home/data/link-intake/.update-lock"
  if run_intake "$home" validate --all > "$home/live-legacy-lock.out" 2> "$home/live-legacy-lock.err"; then
    fail 'live legacy lock was reclaimed without a process-start identity'
  fi
  assert_grep 'link-intake update lock owner identity is unreadable' "$home/live-legacy-lock.err" 'live legacy lock did not fail closed'
  rm "$home/data/link-intake/.update-lock"
  printf '%s\n' '99999999' > "$owner_dir/owner"
  ln -s "${owner_dir##*/}" "$home/data/link-intake/.update-lock"
  run_intake "$home" validate --all >/dev/null \
    || fail 'dead legacy lock was not reclaimed'
  [ ! -e "$owner_dir" ] || fail 'dead legacy owner survived recovery'
  pass 'lock identity is timezone-stable and legacy recovery is upgrade-safe'
}

test_retrieval_dates_are_real_and_path_safe() {
  local home invalid record history root
  home=$(make_home retrieved-date)
  for invalid in '../.-..-..' '2025-02-29' '2026-04-31' '0000-01-01'; do
    if run_intake "$home" upsert --url 'https://date.example.test/page' --source-type article --title 'Invalid date' --summary 'This record must not publish.' --terms 'date,invalid' --claim 'Invalid dates are rejected.' --retrieved-at "$invalid" > "$home/invalid-date.out" 2> "$home/invalid-date.err"; then
      fail "invalid retrieval date was accepted: $invalid"
    fi
    assert_grep 'retrieved-at must be a real YYYY-MM-DD calendar date' "$home/invalid-date.err" 'invalid retrieval date failure was not visible'
  done
  [ ! -e "$home/data/link-intake/current" ] || fail 'invalid retrieval date published state'
  run_intake "$home" upsert --url 'https://date.example.test/page' --source-type article --title 'Leap date' --summary 'A real leap-day record.' --terms 'date,leap' --claim 'Leap day is valid.' --retrieved-at '2024-02-29' >/dev/null \
    || fail 'real leap-day retrieval date was rejected'
  run_intake "$home" upsert --url 'https://date.example.test/page' --source-type article --title 'Leap date updated' --summary 'A repeated leap-day record.' --terms 'date,history' --claim 'History remains record-local.' --retrieved-at '2024-02-29' >/dev/null \
    || fail 'repeated leap-day intake failed'
  record=$(record_for "$home" 'https://date.example.test/page')
  assert_grep 'Retrieved at: 2024-02-29' "$record" 'valid retrieval date was not retained'
  history=$(find "$(current_root "$home")/history" -type f -name '2024-02-29-*.md' | head -1)
  assert_present "$history" 'valid retrieval date did not produce record-local history'
  root=$(current_root "$home")
  printf 'Unscoped history.\n' > "$root/history/escaped.md"
  if run_intake "$home" validate --all > "$home/escaped-history.out" 2> "$home/escaped-history.err"; then
    fail 'validation accepted history outside a record directory'
  fi
  assert_grep 'unexpected entry in history directory' "$home/escaped-history.err" 'unscoped history failure was not visible'
  rm "$root/history/escaped.md"
  pass 'retrieval dates are real calendar dates and remain path-safe'
}

test_atomic_generation_switch_is_process_crash_safe() {
  local home record index root fakebin before_record before_index before_current after_record after_index failure_marker
  local old_transcript new_transcript retained generations rc=0
  home=$(make_home atomic)
  old_transcript="$home/old-transcript.txt"
  new_transcript="$home/new-transcript.txt"
  printf 'Original durable transcript.\n' > "$old_transcript"
  printf 'New staged transcript.\n' > "$new_transcript"
  run_intake "$home" upsert --url 'https://atomic.example.test/page' --source-type video --title 'Atomic title' --summary 'Initial complete summary.' --terms 'atomic,initial' --claim 'Initial claim.' --transcript-file "$old_transcript" >/dev/null \
    || fail 'initial atomic intake failed'
  record=$(record_for "$home" 'https://atomic.example.test/page')
  root=$(current_root "$home")
  index="$root/index.tsv"
  fakebin=$(make_failing_tools "$home")
  before_record=$(shasum -a 256 "$record" | awk '{print $1}')
  before_index=$(shasum -a 256 "$index" | awk '{print $1}')
  before_current=$(readlink "$home/data/link-intake/current")
  failure_marker="$home/current-move-failed"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" FM_REAL_RM="$REAL_RM" FM_REAL_LN="$REAL_LN" FM_REAL_READLINK="$REAL_READLINK" \
    FM_FAIL_MOVE_DEST="$home/data/link-intake/current" FM_FAIL_MOVE_ONCE="$failure_marker" \
    "$INTAKE" upsert --url 'https://atomic.example.test/page' --source-type video --title 'Switch failure' --summary 'Valid update that cannot publish.' --terms 'atomic,switch' --claim 'The state switch fails.' --transcript-file "$new_transcript" > "$home/switch-failure.out" 2> "$home/switch-failure.err"; then
    fail 'generation publication failure unexpectedly succeeded'
  fi
  after_record=$(shasum -a 256 "$record" | awk '{print $1}')
  after_index=$(shasum -a 256 "$index" | awk '{print $1}')
  [ "$before_current" = "$(readlink "$home/data/link-intake/current")" ] || fail 'failed state switch changed the current generation'
  [ "$before_record" = "$after_record" ] || fail 'failed state switch changed the prior record'
  [ "$before_index" = "$after_index" ] || fail 'failed state switch changed the prior index'
  ! grep -R -F 'New staged transcript.' "$home/data/link-intake/generations" >/dev/null 2>&1 \
    || fail 'failed state switch left an orphaned transcript'
  generations=$(find "$home/data/link-intake/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" = 1 ] || fail 'failed state switch left an abandoned generation'
  failure_marker="$home/current-move-retained"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" FM_REAL_RM="$REAL_RM" FM_REAL_LN="$REAL_LN" FM_REAL_READLINK="$REAL_READLINK" \
    FM_FAIL_MOVE_DEST="$home/data/link-intake/current" FM_FAIL_MOVE_ONCE="$failure_marker" \
    FM_FAIL_REMOVE_PREFIX="$home/data/link-intake/generations/.generation." FM_FAIL_REMOVE_ONCE="$home/remove-failed" \
    "$INTAKE" upsert --url 'https://atomic.example.test/page' --source-type video --title 'Retained candidate' --summary 'A recoverable candidate remains available.' --terms 'atomic,recoverable' --claim 'Cleanup fails visibly.' --transcript-file "$new_transcript" > "$home/retained.out" 2> "$home/retained.err"; then
    fail 'publication with failed candidate cleanup unexpectedly succeeded'
  fi
  retained=$(sed -n 's/^error: recoverable staged generation retained: //p' "$home/retained.err")
  assert_present "$retained" 'failed cleanup did not preserve and report the recoverable generation'
  [ "$before_current" = "$(readlink "$home/data/link-intake/current")" ] || fail 'failed cleanup changed the current generation'
  run_intake "$home" validate --all >/dev/null || fail 'validation did not recover a retained staged generation'
  [ ! -e "$retained" ] || fail 'recovery did not clean the retained staged generation'
  failure_marker="$home/current-move-signaled"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" FM_REAL_RM="$REAL_RM" FM_REAL_LN="$REAL_LN" FM_REAL_READLINK="$REAL_READLINK" \
    FM_SIGNAL_MOVE_DEST="$home/data/link-intake/current" FM_SIGNAL_MOVE_ONCE="$failure_marker" \
    FM_FAIL_READLINK_PATH="$home/data/link-intake/current" FM_FAIL_READLINK_AFTER="$failure_marker" FM_FAIL_READLINK_ONCE="$home/readlink-failed" \
    "$INTAKE" upsert --url 'https://atomic.example.test/page' --source-type video --title 'Interrupted update' --summary 'Valid update interrupted at the commit point.' --terms 'atomic,signal' --claim 'The signal follows the atomic switch.' --transcript-file "$new_transcript" > "$home/signal.out" 2> "$home/signal.err" || rc=$?
  [ "$rc" = 143 ] || fail "TERM during publication should exit 143, got $rc"
  [ ! -d "$home/data/link-intake/.update-lock" ] || fail 'TERM left the update lock held'
  retained=$(sed -n 's/^error: recoverable staged generation retained: //p' "$home/signal.err")
  assert_present "$retained" 'uncertain cleanup did not retain and report the selected generation'
  [ -e "$home/data/link-intake/current/index.tsv" ] || fail 'uncertain cleanup left current state dangling'
  run_intake "$home" validate --all >/dev/null || fail 'state committed before TERM failed validation'
  assert_grep 'Title: Interrupted update' "$(record_for "$home" 'https://atomic.example.test/page')" 'TERM exposed a partial generation'
  before_current=$(readlink "$home/data/link-intake/current")
  failure_marker="$home/current-move-killed"
  rc=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_REAL_MV="$REAL_MV" FM_REAL_RM="$REAL_RM" FM_REAL_LN="$REAL_LN" FM_REAL_READLINK="$REAL_READLINK" \
    FM_KILL_MOVE_DEST="$home/data/link-intake/current" FM_KILL_MOVE_ONCE="$failure_marker" \
    "$INTAKE" upsert --url 'https://atomic.example.test/page' --source-type video --title 'Killed update' --summary 'This update dies before its commit point.' --terms 'atomic,killed' --claim 'SIGKILL precedes the state switch.' --transcript-file "$old_transcript" > "$home/killed.out" 2> "$home/killed.err" || rc=$?
  [ "$rc" = 137 ] || fail "SIGKILL before publication should exit 137, got $rc"
  [ "$before_current" = "$(readlink "$home/data/link-intake/current")" ] || fail 'SIGKILL before the commit point changed current state'
  [ -d "$home/data/link-intake/.update-lock" ] || fail 'SIGKILL fixture did not leave a stale lock'
  run_intake "$home" validate --all >/dev/null || fail 'validation did not recover from a killed updater'
  [ ! -d "$home/data/link-intake/.update-lock" ] || fail 'stale update lock was not reclaimed'
  generations=$(find "$home/data/link-intake/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" = 1 ] || fail 'crash recovery left an abandoned generation'
  assert_grep 'power-loss durability depends on the host filesystem' "$ROOT/docs/link-intake.md" 'operator contract overstates the process-crash guarantee'
  pass 'one process-crash atomic switch survives failures and process death'
}

test_validation_rejects_bidirectional_divergence() {
  local home other record orphan root saved
  home=$(make_home divergence)
  other=$(make_home divergence-other)
  run_intake "$home" upsert --url 'https://consistent.example.test/page' --source-type web --title 'Consistent' --summary 'Initially consistent state.' --terms 'consistent' --claim 'The state starts consistent.' >/dev/null \
    || fail 'consistent intake failed'
  run_intake "$other" upsert --url 'https://orphan.example.test/page' --source-type web --title 'Orphan' --summary 'Record not present in the first index.' --terms 'orphan' --claim 'The copied record is unindexed.' >/dev/null \
    || fail 'orphan fixture intake failed'
  orphan=$(find "$(current_root "$other")/records" -type f -name '*.md' | head -1)
  root=$(current_root "$home")
  cp "$orphan" "$root/records/"
  if run_intake "$home" validate --all > "$home/orphan.out" 2> "$home/orphan.err"; then
    fail 'validation accepted a record absent from the index'
  fi
  assert_grep 'record is absent from index' "$home/orphan.err" 'orphan record failure was not visible'
  rm "$root/records/${orphan##*/}"
  record=$(record_for "$home" 'https://consistent.example.test/page')
  saved="$home/saved-record.md"
  cp "$record" "$saved"
  rm "$record"
  if run_intake "$home" validate --all > "$home/missing-record.out" 2> "$home/missing-record.err"; then
    fail 'validation accepted an index entry without its record'
  fi
  assert_grep 'record is absent' "$home/missing-record.err" 'missing indexed record failure was not visible'
  cp "$saved" "$record"
  mkdir -p "$root/transcripts/orphan"
  printf 'Unreferenced transcript.\n' > "$root/transcripts/orphan/content.txt"
  if run_intake "$home" validate --all > "$home/orphan-transcript.out" 2> "$home/orphan-transcript.err"; then
    fail 'validation accepted a transcript absent from records and history'
  fi
  assert_grep 'transcript is absent from records and history' "$home/orphan-transcript.err" 'orphan transcript failure was not visible'
  pass 'validation rejects record, index, and transcript divergence'
}

test_odd_urls_never_control_filenames_or_shell() {
  local home record files query_record
  home=$(make_home odd-url)
  run_intake "$home" upsert --url 'https://EXAMPLE.test/a/../../%24%28touch%20nope%29?x=%3B%26' --source-type web --title 'Odd URL title' --summary 'Odd but valid URL summary.' --terms 'odd,url' --claim 'Odd URL remains data.' >/dev/null \
    || fail 'odd URL intake failed'
  record=$(record_for "$home" 'https://example.test/a/../../%24%28touch%20nope%29?x=%3B%26')
  files=$(find "$(current_root "$home")/records" -type f -name '*.md' -exec basename {} \;)
  case "$files" in [0-9a-f][0-9a-f]*) ;; *) fail 'record filename is not a deterministic hexadecimal digest' ;; esac
  assert_grep 'Canonical URL: https://example.test/a/../../%24%28touch%20nope%29?x=%3B%26' "$record" 'odd URL was not retained as data'
  if run_intake "$home" upsert --url 'https://example.test/@unsafe' --canonical-url 'file:///tmp/nope' --source-type web --title 'Bad canonical' --summary 'Should reject.' --terms 'bad' --claim 'Bad.' > "$home/bad.out" 2> "$home/bad.err"; then
    fail 'non-HTTP canonical URL was accepted'
  fi
  assert_grep 'URL must use http or https' "$home/bad.err" 'unsafe canonical URL failure was not visible'
  run_intake "$home" upsert --url 'https://Example.test?Token=ABC/Path' --source-type web --title 'Query slash' --summary 'A slash inside a query remains case-sensitive data.' --terms 'query,slash' --claim 'Only the scheme and host are lowercased.' >/dev/null \
    || fail 'query containing a slash was rejected'
  query_record=$(record_for "$home" 'https://example.test?Token=ABC/Path')
  assert_grep 'Canonical URL: https://example.test?Token=ABC/Path' "$query_record" 'query content was lowercased as authority'
  pass 'odd URLs preserve query case and use digest paths'
}

test_agents_trigger_is_concise_and_agent_agnostic() {
  local line
  line=$(grep -F 'Link intake:' "$ROOT/AGENTS.md" || true)
  [ -n "$line" ] || fail 'AGENTS link-intake trigger is absent'
  assert_contains "$line" 'captain sends meaningful URL input' 'trigger does not cover meaningful captain URLs'
  assert_contains "$line" 'bin/fm-link-intake.sh' 'trigger does not name the authoritative helper'
  [ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" = 1 ] || fail 'AGENTS link-intake trigger is not one concise line'
  assert_not_contains "$line" 'Claude' 'trigger is not agent-agnostic'
  pass 'AGENTS has one concise agent-agnostic link-intake trigger'
}

test_canonical_duplicate_converges_and_preserves_evidence
test_titles_summaries_claims_and_terms_are_searchable
test_inaccessible_links_remain_visible_and_valid
test_video_transcript_metadata_is_durable
test_lock_claim_and_symlink_replacement_are_portable
test_lock_identity_is_timezone_stable_and_upgrade_safe
test_retrieval_dates_are_real_and_path_safe
test_atomic_generation_switch_is_process_crash_safe
test_validation_rejects_bidirectional_divergence
test_odd_urls_never_control_filenames_or_shell
test_agents_trigger_is_concise_and_agent_agnostic
