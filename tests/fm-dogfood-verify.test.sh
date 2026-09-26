#!/usr/bin/env bash
# Behavior tests for bin/fm-dogfood-verify.sh.
#
# These exercise the two primitives through the real CLI: pin (immutable copy of
# an exact commit + recorded manifest) and verify (live PASS or a specific named
# drift). No project code and no live installed app are involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-dogfood-verify.sh"

TMP_ROOT=$(fm_test_tmproot fm-dogfood-verify)
fm_git_identity

# Extra teardown: reap any serve process a test left running, then run the
# registered temp-dir cleanup from tests/lib.sh.
SERVE_PID=''
dogfood_cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap dogfood_cleanup EXIT
trap 'dogfood_cleanup; exit 130' INT
trap 'dogfood_cleanup; exit 143' TERM

# build_src <dir> <content>: a repo with ui/index.html + ui/main.js, one commit.
build_src() {
  local d=$1 content=$2
  mkdir -p "$d/ui"
  printf '%s\n' "$content" > "$d/ui/index.html"
  printf 'js-%s\n' "$content" > "$d/ui/main.js"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" commit -qm "ui $content"
}

# vout <args...>: run verify, capture combined output in OUT and status in RC.
# Uses global writes (not command substitution) so RC survives to the caller.
OUT=''
RC=0
vout() {
  OUT=$("$SCRIPT" verify "$@" 2>&1)
  RC=$?
}

test_pin_copies_exact_commit_not_shared_worktree() {
  local case_dir src pin rec link sha head target src_phys
  case_dir="$TMP_ROOT/copies"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  mkdir -p "$case_dir/live"
  link="$case_dir/live/ui"
  build_src "$src" v1
  sha=$(git -C "$src" rev-parse HEAD)

  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui --link "$link" >/dev/null \
    || fail "pin failed for a clean activation"

  head=$(git -C "$pin" rev-parse HEAD)
  [ "$head" = "$sha" ] || fail "pinned copy HEAD ($head) is not the activated commit ($sha)"
  assert_grep "sha=$sha" "$rec/pin.env" "pin.env did not record the exact sha"
  assert_present "$rec/manifest.tsv" "no manifest was written"
  [ -s "$rec/manifest.tsv" ] || fail "manifest is empty"

  # The live symlink must point at the dedicated pin copy, never inside the
  # shared source worktree that other tasks keep committing to.
  [ -L "$link" ] || fail "live symlink was not created"
  target=$(readlink "$link")
  case "$target" in
    */pin/ui) : ;;
    *) fail "live symlink points at $target, not the dedicated pin copy" ;;
  esac
  src_phys=$(cd "$src" && pwd -P)
  case "$target" in
    "$src_phys"|"$src_phys"/*) fail "live symlink points INSIDE the shared source worktree: $target" ;;
  esac
  pass "pin: copies the exact commit into a dedicated pin, symlink not in the shared worktree"
}

test_later_source_commit_does_not_change_pin() {
  local case_dir src pin rec sha1 sha2
  case_dir="$TMP_ROOT/isolation"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  build_src "$src" orig
  sha1=$(git -C "$src" rev-parse HEAD)
  "$SCRIPT" pin --source "$src" --sha "$sha1" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui >/dev/null || fail "pin failed"

  # A later, unrelated commit on the ORIGINAL source worktree/branch.
  printf 'CHANGED-BY-LATER-TASK\n' > "$src/ui/index.html"
  git -C "$src" add -A
  git -C "$src" commit -qm later
  sha2=$(git -C "$src" rev-parse HEAD)
  [ "$sha1" != "$sha2" ] || fail "fixture did not advance the source"

  [ "$(git -C "$pin" rev-parse HEAD)" = "$sha1" ] \
    || fail "the pinned copy moved when the source advanced"
  [ "$(cat "$pin/ui/index.html")" = orig ] \
    || fail "the pinned copy now serves the later commit's content"

  vout --skip-serve "$rec"
  [ "$RC" -eq 0 ] || fail "verify should PASS on an untouched pin after the source advanced: $OUT"
  assert_contains "$OUT" "PASS" "verify did not report PASS after the source advanced"
  pass "pin: a later commit on the source does not change what the pinned copy serves"
}

test_verify_pass_and_named_drifts() {
  local case_dir src pin rec link reg sha other served
  case_dir="$TMP_ROOT/drift"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  mkdir -p "$case_dir/live"
  link="$case_dir/live/ui"
  reg="$case_dir/registry.json"
  build_src "$src" base
  sha=$(git -C "$src" rev-parse HEAD)
  printf 'reg-v1\n' > "$reg"
  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui --link "$link" --invariant registry="$reg" >/dev/null \
    || fail "pin failed"
  # The authoritative served target pin recorded (physical path); restore to it.
  served=$(sed -n 's/^served_root=//p' "$rec/pin.env")

  # A second commit exists so we can push the pinned worktree off its pin.
  printf 'v2\n' > "$src/ui/index.html"
  git -C "$src" add -A
  git -C "$src" commit -qm v2
  other=$(git -C "$src" rev-parse HEAD)

  vout --skip-serve "$rec"
  [ "$RC" -eq 0 ] || fail "verify should PASS on the untouched pin: $OUT"
  assert_contains "$OUT" "PASS" "untouched pin did not PASS"

  # (1) symlink drift
  ln -sfn "$case_dir" "$link"
  vout --skip-serve "$rec"
  [ "$RC" -eq 1 ] || fail "symlink drift should exit 1, got $RC"
  assert_contains "$OUT" "symlink-drift" "symlink drift was not named"
  ln -sfn "$served" "$link"

  # (2) HEAD drift: advance the pinned worktree itself
  git -C "$pin" checkout -q "$other"
  vout --skip-serve "$rec"
  [ "$RC" -eq 1 ] || fail "head drift should exit 1, got $RC"
  assert_contains "$OUT" "head-drift" "head drift was not named"
  git -C "$pin" checkout -q "$sha"

  # (3) content drift: tamper a served file without moving HEAD
  printf 'tampered\n' > "$pin/ui/index.html"
  vout --skip-serve "$rec"
  [ "$RC" -eq 1 ] || fail "content drift should exit 1, got $RC"
  assert_contains "$OUT" "content-drift" "content drift was not named"
  assert_not_contains "$OUT" "head-drift" "content-only drift wrongly reported head drift"
  git -C "$pin" checkout -q -- ui/index.html

  # (4) invariant drift
  printf 'reg-v2\n' > "$reg"
  vout --skip-serve "$rec"
  [ "$RC" -eq 1 ] || fail "invariant drift should exit 1, got $RC"
  assert_contains "$OUT" "invariant-drift" "invariant drift was not named"
  printf 'reg-v1\n' > "$reg"

  # Restored -> PASS again
  vout --skip-serve "$rec"
  [ "$RC" -eq 0 ] || fail "verify should PASS again after restore: $OUT"
  assert_contains "$OUT" "PASS" "restored pin did not PASS"
  pass "verify: PASS on an untouched pin, specific named FAIL for symlink/HEAD/content/invariant drift"
}

test_verify_is_read_only() {
  local case_dir src pin rec link sha before after sentinel s_before list_before list_after
  case_dir="$TMP_ROOT/readonly"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  mkdir -p "$case_dir/live"
  link="$case_dir/live/ui"
  build_src "$src" ro
  sha=$(git -C "$src" rev-parse HEAD)
  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui --link "$link" >/dev/null || fail "pin failed"
  local served
  served=$(sed -n 's/^served_root=//p' "$rec/pin.env")

  sentinel="$case_dir/sentinel"
  printf 'do-not-touch\n' > "$sentinel"
  s_before=$(cat "$sentinel")
  before=$(cat "$rec/pin.env" "$rec/manifest.tsv" "$rec/invariants.tsv" | sha256_of_stdin)
  list_before=$(cd "$rec" && find . -maxdepth 1 | LC_ALL=C sort)

  # A passing verify.
  vout --skip-serve "$rec"
  # A failing verify (drifted symlink) must also mutate nothing.
  ln -sfn "$case_dir" "$link"
  vout --skip-serve "$rec"
  ln -sfn "$served" "$link"

  after=$(cat "$rec/pin.env" "$rec/manifest.tsv" "$rec/invariants.tsv" | sha256_of_stdin)
  list_after=$(cd "$rec" && find . -maxdepth 1 | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "verify mutated the recorded activation files"
  [ "$list_before" = "$list_after" ] || fail "verify added or removed files in the record dir"
  assert_present "$sentinel" "verify deleted an unrelated file"
  [ "$(cat "$sentinel")" = "$s_before" ] || fail "verify modified an unrelated file"
  pass "verify: never deletes or mutates unrelated data (PASS or FAIL)"
}

# sha256_of_stdin: portable stdin hash used only by the read-only test.
sha256_of_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}';
  else sha256sum | awk '{print $1}'; fi
}

test_serve_process_up_and_down() {
  local case_dir src pin rec sha marker out
  if ! command -v pgrep >/dev/null 2>&1; then
    pass "verify: serve-process check (skipped: pgrep not available)"
    return 0
  fi
  case_dir="$TMP_ROOT/serve"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  build_src "$src" serve
  sha=$(git -C "$src" rev-parse HEAD)
  marker="$case_dir/fmdogfood-serve-marker-$$"
  mkdir -p "$case_dir"

  # A real process whose argv[0] is the unique marker, so pgrep -f matches it.
  ( exec -a "$marker" sleep 120 ) &
  SERVE_PID=$!
  sleep 0.2

  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui --process-pattern "$marker" >/dev/null || fail "pin failed"

  out=$("$SCRIPT" verify "$rec" 2>&1); RC=$?
  [ "$RC" -eq 0 ] || fail "verify should PASS while the serve process is up: $out"
  assert_contains "$out" "PASS" "serve-up verify did not PASS"

  kill "$SERVE_PID" 2>/dev/null || true
  wait "$SERVE_PID" 2>/dev/null || true
  SERVE_PID=''

  out=$("$SCRIPT" verify "$rec" 2>&1); RC=$?
  [ "$RC" -eq 1 ] || fail "verify should FAIL once the serve process is gone, got $RC"
  assert_contains "$out" "serve-process-down" "process-down drift was not named"
  pass "verify: reports serve-process-down when the recorded process is gone"
}

test_pin_safety_and_reuse() {
  local case_dir src pin rec sha out realdir
  case_dir="$TMP_ROOT/safety"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  build_src "$src" safe
  sha=$(git -C "$src" rev-parse HEAD)

  # pin-dir inside the source worktree is refused.
  out=$("$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$src/inside" \
    --record "$case_dir/rec-inside" --serve-subdir ui 2>&1); RC=$?
  [ "$RC" -eq 2 ] || fail "pin-dir inside source should be refused (exit 2), got $RC"
  assert_contains "$out" "inside the source worktree" "refusal did not explain the reason"
  assert_absent "$src/inside" "a pin copy was created inside the source worktree"

  # A clean pin, then a byte-identical reuse of the same commit + pin-dir.
  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui >/dev/null || fail "first pin failed"
  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$case_dir/rec2" \
    --serve-subdir ui >/dev/null || fail "idempotent reuse of the same pin failed"

  # Refuse to clobber a real (non-symlink) path at --link.
  realdir="$case_dir/realdir"
  mkdir -p "$realdir"
  out=$("$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$case_dir/rec3" \
    --serve-subdir ui --link "$realdir" 2>&1); RC=$?
  [ "$RC" -eq 2 ] || fail "clobbering a non-symlink --link should be refused, got $RC"
  assert_contains "$out" "non-symlink" "clobber refusal did not name the hazard"
  assert_present "$realdir" "the real directory at --link was disturbed"
  [ ! -L "$realdir" ] || fail "the real directory at --link was replaced by a symlink"
  pass "pin: refuses pin-dir inside source, refuses non-symlink clobber, reuses an identical pin"
}

test_repin_over_existing_symlink() {
  local case_dir src pin1 pin2 rec1 rec2 link sha1 sha2 target stray
  case_dir="$TMP_ROOT/repin"
  src="$case_dir/src"; pin1="$case_dir/pin1"; pin2="$case_dir/pin2"
  rec1="$case_dir/rec1"; rec2="$case_dir/rec2"
  mkdir -p "$case_dir/live"
  link="$case_dir/live/ui"
  build_src "$src" first
  sha1=$(git -C "$src" rev-parse HEAD)

  # First activation creates the live symlink (link did not exist before).
  "$SCRIPT" pin --source "$src" --sha "$sha1" --pin-dir "$pin1" --record "$rec1" \
    --serve-subdir ui --link "$link" >/dev/null || fail "first pin failed"
  [ -L "$link" ] || fail "first pin did not create the live symlink"

  # A second commit, activated at the SAME live link into a DIFFERENT pin dir.
  # This is the normal re-activation case: the link already exists as a
  # symlink-to-directory and must be repointed, not dereferenced.
  printf 'CHANGED\n' > "$src/ui/index.html"
  git -C "$src" add -A
  git -C "$src" commit -qm second
  sha2=$(git -C "$src" rev-parse HEAD)
  [ "$sha1" != "$sha2" ] || fail "fixture did not advance the source"

  "$SCRIPT" pin --source "$src" --sha "$sha2" --pin-dir "$pin2" --record "$rec2" \
    --serve-subdir ui --link "$link" >/dev/null \
    || fail "re-pin onto an existing symlink-to-dir failed"

  [ -L "$link" ] || fail "re-pin left the live path as a non-symlink"
  target=$(readlink "$link")
  case "$target" in
    */pin2/ui) : ;;
    *) fail "live symlink still resolves to $target, not the NEW pin copy" ;;
  esac

  # The old served directory must not have a stray staged symlink deposited in
  # it (the dereference symptom).
  stray=$(cd "$pin1/ui" && find . -maxdepth 1 -name 'ui.fmpin.*' -print 2>/dev/null)
  [ -z "$stray" ] || fail "re-pin deposited a stray staged symlink inside the old copy: $stray"

  # verify agrees the recorded activation is live and correct.
  vout --skip-serve "$rec2"
  [ "$RC" -eq 0 ] || fail "verify should PASS on the re-pinned activation: $OUT"
  assert_contains "$OUT" "PASS" "re-pinned activation did not verify PASS"
  pass "pin: re-pinning a different commit onto an existing symlink-to-dir repoints the link"
}

test_serve_subdir_escape_is_refused() {
  local case_dir src pin rec sha out
  case_dir="$TMP_ROOT/escape"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  build_src "$src" esc
  sha=$(git -C "$src" rev-parse HEAD)

  # A --serve-subdir with parent components would otherwise resolve the served
  # root OUTSIDE the pinned worktree, making the app serve content that is not
  # part of the pinned commit. Give it a real existing sibling dir to escape to.
  mkdir -p "$case_dir/outside"
  printf 'not-in-the-pin\n' > "$case_dir/outside/index.html"

  out=$("$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" \
    --record "$rec" --serve-subdir '../outside' 2>&1); RC=$?
  [ "$RC" -eq 2 ] || fail "a --serve-subdir that escapes the pin should be refused (exit 2), got $RC"
  assert_contains "$out" "escapes the pinned worktree" "escape refusal was not named"
  assert_absent "$rec/pin.env" "a pin record was written for an escaping served root"
  pass "pin: refuses a --serve-subdir that escapes the pinned worktree"
}

test_explicit_file_escape_is_refused() {
  local case_dir src pin rec sha out secret
  case_dir="$TMP_ROOT/fileescape"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  build_src "$src" fesc
  sha=$(git -C "$src" rev-parse HEAD)

  # Mutable external content the activation must NOT be able to record/serve.
  mkdir -p "$case_dir/outside"
  secret="$case_dir/outside/secret.txt"
  printf 'external-and-mutable\n' > "$secret"

  # (1) A --file with parent components resolving outside the pinned worktree.
  out=$("$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" \
    --record "$rec" --serve-subdir ui --file '../../outside/secret.txt' 2>&1); RC=$?
  [ "$RC" -eq 2 ] || fail "a --file escaping the pin should be refused (exit 2), got $RC"
  assert_contains "$out" "escapes the pinned worktree" "file-escape refusal was not named"
  assert_absent "$rec/pin.env" "a pin record was written for an escaping --file"
  assert_absent "$rec/manifest.tsv" "a manifest was written for an escaping --file"

  # (2) A served file that is a SYMLINK pointing outside the pinned worktree.
  # It lives at a valid relative path inside served_root, but its target is the
  # mutable external file, which must be refused just the same.
  ln -s "$secret" "$pin/ui/leak.html"
  out=$("$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" \
    --record "$case_dir/rec2" --serve-subdir ui --file leak.html 2>&1); RC=$?
  rm -f "$pin/ui/leak.html"
  [ "$RC" -eq 2 ] || fail "a --file symlink escaping the pin should be refused (exit 2), got $RC"
  assert_contains "$out" "escapes the pinned worktree" "symlink file-escape refusal was not named"
  assert_absent "$case_dir/rec2/manifest.tsv" "a manifest was written for an escaping symlink --file"

  # The external file was never touched by the refused pins.
  [ "$(cat "$secret")" = 'external-and-mutable' ] || fail "the external file was disturbed"
  pass "pin: refuses an explicit --file (parent path or escaping symlink) outside the pinned worktree"
}

test_default_enumeration_rejects_escaping_symlink() {
  local case_dir src pin rec sha out secret
  case_dir="$TMP_ROOT/autoescape"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  build_src "$src" autoesc
  sha=$(git -C "$src" rev-parse HEAD)

  # Mutable external content that lives OUTSIDE the pinned worktree.
  mkdir -p "$case_dir/outside"
  secret="$case_dir/outside/secret.txt"
  printf 'external-and-mutable\n' > "$secret"

  # A clean default-enumeration pin (no --file) succeeds and materializes the
  # dedicated worktree copy.
  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui >/dev/null || fail "clean default-enumeration pin failed"

  # Now a served entry becomes a SYMLINK to that external mutable content. A plain
  # `find -type f` sweep would omit it, so pin/verify would report success while
  # the app serves un-pinned bytes. Default enumeration must instead NAME the
  # escape and refuse, exactly like the explicit --file branch.
  ln -s "$secret" "$pin/ui/leak.html"
  out=$("$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" \
    --record "$case_dir/rec2" --serve-subdir ui 2>&1); RC=$?
  rm -f "$pin/ui/leak.html"
  [ "$RC" -eq 2 ] || fail "default enumeration must refuse an escaping served symlink (exit 2), got $RC"
  assert_contains "$out" "escapes the pinned worktree" "the escaping served symlink was not named"
  assert_absent "$case_dir/rec2/manifest.tsv" "a manifest was written despite an escaping served symlink"
  [ "$(cat "$secret")" = 'external-and-mutable' ] || fail "the external file was disturbed"
  pass "pin: default enumeration refuses (does not omit) a served symlink that escapes the pin"
}

test_verify_names_live_containment_escape() {
  local case_dir src pin rec sha served outside
  case_dir="$TMP_ROOT/liveescape"
  src="$case_dir/src"; pin="$case_dir/pin"; rec="$case_dir/rec"
  build_src "$src" esc2
  sha=$(git -C "$src" rev-parse HEAD)
  "$SCRIPT" pin --source "$src" --sha "$sha" --pin-dir "$pin" --record "$rec" \
    --serve-subdir ui >/dev/null || fail "pin failed"
  served=$(sed -n 's/^served_root=//p' "$rec/pin.env")

  # Baseline: the untouched pin PASSes.
  vout --skip-serve "$rec"
  [ "$RC" -eq 0 ] || fail "verify should PASS on the untouched pin: $OUT"

  # pin enforced containment at activation time. AFTER activation, a served file
  # is replaced by a symlink to mutable content OUTSIDE the pin whose bytes match
  # the recorded hash. Content hashing alone still matches, so only a live
  # containment re-check catches that the app no longer serves the pinned copy.
  outside="$case_dir/outside"
  mkdir -p "$outside"
  cp "$served/index.html" "$outside/index.html"   # byte-identical to the manifest
  rm -f "$served/index.html"
  ln -s "$outside/index.html" "$served/index.html"

  vout --skip-serve "$rec"
  [ "$RC" -eq 1 ] || fail "verify should FAIL when a served path escapes the pin after activation, got $RC: $OUT"
  assert_contains "$OUT" "content-escape" "the live containment escape was not named"

  # Restore the real file inside the pin -> PASS again (verify itself changed
  # nothing; the escape, not verify, was the mutation).
  rm -f "$served/index.html"
  cp "$outside/index.html" "$served/index.html"
  vout --skip-serve "$rec"
  [ "$RC" -eq 0 ] || fail "verify should PASS after the escaped file is restored: $OUT"
  pass "verify: names a live containment escape when a served path leaves the pin after activation"
}

test_usage_errors() {
  local out
  out=$("$SCRIPT" bogus 2>&1); RC=$?
  [ "$RC" -eq 2 ] || fail "an unknown subcommand should exit 2, got $RC"

  out=$("$SCRIPT" verify 2>&1); RC=$?
  [ "$RC" -eq 2 ] || fail "verify with no record path should exit 2, got $RC"
  assert_contains "$out" "required" "missing-arg verify did not explain the requirement"

  out=$("$SCRIPT" pin --source "$TMP_ROOT" 2>&1); RC=$?
  [ "$RC" -eq 2 ] || fail "pin without required args should exit 2, got $RC"
  pass "usage: unknown subcommand and missing required arguments exit 2"
}

test_pin_copies_exact_commit_not_shared_worktree
test_later_source_commit_does_not_change_pin
test_verify_pass_and_named_drifts
test_verify_is_read_only
test_serve_process_up_and_down
test_pin_safety_and_reuse
test_repin_over_existing_symlink
test_serve_subdir_escape_is_refused
test_explicit_file_escape_is_refused
test_default_enumeration_rejects_escaping_symlink
test_verify_names_live_containment_escape
test_usage_errors
