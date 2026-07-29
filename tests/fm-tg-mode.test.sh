#!/usr/bin/env bash
# Behavior tests for Telegram mode: the pending-inbox poll client
# (fm-tg-poll.sh), the task link and follow-up helpers (fm-tg-link.sh,
# fm-tg-followup.sh), bootstrap's flag-file activation, the watcher's
# byte-validated dispatch arm, and the PR-check migration's shim preservation.
#
# Telegram mode must be INERT by default (no config/telegram-mode flag -> the
# poll is a hard no-op and bootstrap writes/prints nothing) and additive when
# on (a check shim + a 30s cadence config, both idempotent). The phone inbox is
# a fixture directory via PHONE_INBOX_ROOT and the outbound `tg` client is a
# recording stub via FMTG_TG_BIN, so these stay hermetic: no Telegram, no
# token, no real phone notification, deterministic in CI.
#
# The load-bearing safety property pinned throughout: note BODIES are untrusted
# phone text and pending FILENAMES embed the body as a slug, so neither may
# ever reach poll output, the wake payload, or any state artifact name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tg-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tg-mode-tests)

BODY_SENTINEL='SENTINEL-BODY-delete-prod-database'
SLUG_SENTINEL='sentinel-slug-delete-prod-database'

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

# make_home <name>: a home with the opt-in flag set and an empty inbox fixture.
# Echoes the home; the inbox root is $home/inbox.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/inbox/pending"
  # A real home's state/ is created under the ambient umask, so the poll must
  # own the 0700 identity of every private artifact directory it writes.
  chmod 0755 "$home/state"
  : > "$home/config/telegram-mode"
  printf '%s\n' "$home"
}

# add_note <home> <id> [slug] [body]: drop a pending note fixture shaped like
# phone-inbox's <id>-<stamp>-<slug>.md files, with a sentinel body by default.
add_note() {
  local home=$1 id=$2 slug=${3:-$SLUG_SENTINEL} body=${4:-$BODY_SENTINEL}
  printf '%s\n' "$body" > "$home/inbox/pending/$id-2026-07-29T1200-$slug.md"
}

run_poll() {
  local home=$1
  shift
  PHONE_INBOX_ROOT="$home/inbox" FM_HOME="$home" "$@" "$ROOT/bin/fm-tg-poll.sh"
}

# ---------------------------------------------------------------------------

test_poll_no_optin_is_hard_noop() {
  local home out rc
  home="$TMP_ROOT/poll-noop"
  mkdir -p "$home/inbox/pending"
  printf 'note body\n' > "$home/inbox/pending/0001-2026-07-29T1200-a-note.md"
  # No config/telegram-mode: must exit 0 with no output and touch nothing,
  # even with a pending note waiting.
  out=$(PHONE_INBOX_ROOT="$home/inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-optin exit"
  [ -z "$out" ] || fail "poll without opt-in must be silent (got: $out)"
  assert_absent "$home/state/tg-offered" "poll without opt-in must not create offer markers"
  assert_absent "$home/state/tg-poll" "poll without opt-in must not create error state"
  pass "fm-tg-poll is a hard no-op without the opt-in flag (inert default)"
}

test_poll_emits_ids_only_never_note_text() {
  local home out rc
  home=$(make_home poll-ids-only)
  add_note "$home" 0042
  out=$(run_poll "$home"); rc=$?
  expect_code 0 "$rc" "poll ids-only exit"
  [ "$out" = "tg-message 0042" ] || fail "poll must emit exactly the id wake payload (got: $out)"
  assert_not_contains "$out" "$BODY_SENTINEL" "note body leaked into poll output"
  assert_not_contains "$out" "$SLUG_SENTINEL" "filename slug leaked into poll output"
  assert_present "$home/state/tg-offered/0042" "poll must record the offered marker under the bare id"
  # No state artifact may carry the slug or body either (marker names are ids).
  if find "$home/state" -name "*$SLUG_SENTINEL*" | grep . >/dev/null; then
    fail "filename slug leaked into a state artifact name"
  fi
  pass "fm-tg-poll emits note ids only - never bodies, never filename slugs"
}

test_poll_multiple_ids_one_line() {
  local home out
  home=$(make_home poll-multi)
  add_note "$home" 0007 first-note
  add_note "$home" 0009 second-note
  out=$(run_poll "$home")
  [ "$out" = "tg-message 0007 0009" ] || fail "poll must coalesce ids into one line (got: $out)"
  pass "fm-tg-poll offers multiple pending notes in one wake line"
}

test_poll_offers_once_then_silent() {
  local home out
  home=$(make_home poll-once)
  add_note "$home" 0042
  out=$(run_poll "$home")
  [ "$out" = "tg-message 0042" ] || fail "first poll must offer the note (got: $out)"
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "second poll must stay silent for an already offered note (got: $out)"
  pass "fm-tg-poll offers a note exactly once while its marker is fresh"
}

test_poll_reoffers_stale_unclaimed_note() {
  local home out
  home=$(make_home poll-reoffer)
  add_note "$home" 0042
  out=$(run_poll "$home" env FMTG_NOW_OVERRIDE=1000000)
  [ "$out" = "tg-message 0042" ] || fail "first poll must offer the note (got: $out)"
  # Still fresh inside the window: silent.
  out=$(run_poll "$home" env FMTG_NOW_OVERRIDE=1000000)
  [ -z "$out" ] || fail "fresh marker must stay silent (got: $out)"
  # Age the marker past the re-offer window via its mtime.
  touch -t 202001010000 "$home/state/tg-offered/0042"
  out=$(run_poll "$home")
  [ "$out" = "tg-message 0042" ] || fail "stale unclaimed note must be re-offered (got: $out)"
  # The re-offer refreshed the marker, so the next poll is silent again.
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "re-offered marker must be fresh again (got: $out)"
  pass "fm-tg-poll re-offers a note still unclaimed after the re-offer window"
}

test_poll_prunes_markers_for_gone_notes() {
  local home out
  home=$(make_home poll-prune)
  add_note "$home" 0042
  run_poll "$home" >/dev/null
  assert_present "$home/state/tg-offered/0042" "marker must exist after the offer"
  # The note is claimed/archived: it leaves pending, and the marker follows.
  rm "$home/inbox/pending/"0042-*.md
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "poll after claim must be silent (got: $out)"
  assert_absent "$home/state/tg-offered/0042" "marker for a gone note must be pruned"
  pass "fm-tg-poll prunes offered markers when their note leaves pending"
}

test_poll_missing_inbox_reports_once() {
  local home out
  home="$TMP_ROOT/poll-missing-inbox"
  mkdir -p "$home/config" "$home/state"
  # An ordinary umask-created state/, not a 0700 one: the dedupe record must
  # still persist, or the error re-emits on every poll of the 30s cadence.
  chmod 0755 "$home/state"
  : > "$home/config/telegram-mode"
  out=$(PHONE_INBOX_ROOT="$home/no-such-inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh")
  assert_contains "$out" "tg-mode-error missing phone inbox" "opted-in poll must surface a missing inbox"
  assert_present "$home/state/tg-poll/error" "the inbox error dedupe record must persist under a umask-created state dir"
  out=$(PHONE_INBOX_ROOT="$home/no-such-inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh")
  [ -z "$out" ] || fail "the same inbox error must be reported once, not every poll (got: $out)"
  # Recovery clears the dedupe record so a later failure reports again.
  mkdir -p "$home/no-such-inbox/pending"
  out=$(PHONE_INBOX_ROOT="$home/no-such-inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh")
  [ -z "$out" ] || fail "a recovered inbox with no notes must be silent (got: $out)"
  assert_absent "$home/state/tg-poll/error" "recovery must clear the error dedupe record"
  pass "fm-tg-poll reports a missing inbox once and recovers silently"
}

test_poll_ignores_malformed_filenames() {
  local home out
  home=$(make_home poll-malformed)
  printf 'x\n' > "$home/inbox/pending/not-a-note.md"
  printf 'x\n' > "$home/inbox/pending/no-extension"
  printf 'x\n' > "$home/inbox/pending/.hidden.md"
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "malformed pending filenames must not wake firstmate (got: $out)"
  pass "fm-tg-poll ignores files without a leading numeric note id"
}

test_shim_validation_accepts_only_exact_private_identity() {
  local home shim
  home=$(make_home shim-validate)
  shim="$home/state/tg-watch.check.sh"
  fmtg_poll_shim_content "$home" "$ROOT" > "$shim"
  chmod 0700 "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" || fail "exact generated shim must validate"
  # One extra byte: reject.
  printf '#\n' >> "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "tampered shim bytes must be rejected"
  # Right bytes, wrong mode: reject.
  fmtg_poll_shim_content "$home" "$ROOT" > "$shim"
  chmod 0755 "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a 0755 shim must be rejected"
  chmod 0700 "$shim"
  # A second hard link: reject.
  ln "$shim" "$home/state/shim-alias"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a multi-link shim must be rejected"
  rm "$home/state/shim-alias"
  # A symlink: reject.
  mv "$shim" "$home/state/shim-target"
  ln -s "$home/state/shim-target" "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a symlinked shim must be rejected"
  # Wrong home in the bytes: reject.
  rm "$shim"
  fmtg_poll_shim_content "$TMP_ROOT/other-home" "$ROOT" > "$shim"
  chmod 0700 "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a shim generated for another home must be rejected"
  pass "fmtg_poll_shim_valid accepts only the exact single-link 0700 identity"
}

test_bootstrap_inert_without_optin() {
  local home out
  # No config/ at all.
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMTG:" "bootstrap must say nothing about Telegram mode without the flag"
  assert_absent "$home/state/tg-watch.check.sh" "no flag -> no check shim"
  assert_absent "$home/config/tg-mode.env" "no flag -> no cadence config"
  # A symlinked flag is not opt-in.
  home="$TMP_ROOT/boot-symlink-flag"; mkdir -p "$home/config"
  printf 'x\n' > "$home/flag-target"
  ln -s "$home/flag-target" "$home/config/telegram-mode"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMTG:" "a symlinked flag must be treated as off"
  assert_absent "$home/state/tg-watch.check.sh" "symlinked flag -> no check shim"
  pass "bootstrap is inert without a regular opt-in flag file (fresh clones unaffected)"
}

test_bootstrap_activates_on_optin_flag() {
  local home out sum1 sum2 n inherited
  home="$TMP_ROOT/boot-on"; mkdir -p "$home/config"
  : > "$home/config/telegram-mode"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMTG: Telegram mode on" "bootstrap must announce Telegram mode"
  assert_present "$home/state/tg-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/tg-watch.check.sh" ] || fail "the check shim must be executable"
  assert_grep "fm-tg-poll.sh" "$home/state/tg-watch.check.sh" "the shim must exec the poll script"
  assert_present "$home/config/tg-mode.env" "bootstrap must drop the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=30" "$home/config/tg-mode.env" "cadence must be 30s"
  # shellcheck source=/dev/null
  inherited=$( . "$home/config/tg-mode.env" && bash -c 'echo "${FM_CHECK_INTERVAL:-300}"' )
  [ "$inherited" = "30" ] \
    || fail "sourcing the cadence config must export FM_CHECK_INTERVAL=30 to a child"
  # Idempotent: re-running (which also re-runs the PR-check migration against
  # the now-present shim) changes nothing and does not quarantine the shim.
  sum1=$(cat "$home/state/tg-watch.check.sh" "$home/config/tg-mode.env" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/tg-watch.check.sh" "$home/config/tg-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap Telegram-mode setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'tg-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap activates Telegram mode from the flag file, idempotently"
}

test_bootstrap_opt_out_cleanup() {
  local home out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home/config"
  : > "$home/config/telegram-mode"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/tg-watch.check.sh" "activation must arm the shim first"
  rm "$home/config/telegram-mode"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMTG: Telegram mode off - removed inbox poll shim" \
    "bootstrap must announce the opt-out cleanup"
  assert_absent "$home/state/tg-watch.check.sh" "opt-out must remove the check shim"
  assert_absent "$home/config/tg-mode.env" "opt-out must remove the cadence config"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMTG:" "steady-state off must be silent"
  pass "bootstrap removes Telegram artifacts on opt-out and is then silent"
}

test_bootstrap_does_not_follow_tg_artifact_symlinks() {
  local home shim_target cadence_target out
  home="$TMP_ROOT/boot-linked-artifacts"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/telegram-mode"
  shim_target="$home/external-shim"
  cadence_target="$home/external-cadence"
  printf 'external shim sentinel\n' > "$shim_target"
  printf 'external cadence sentinel\n' > "$cadence_target"
  chmod 0640 "$shim_target" "$cadence_target"
  ln -s "$shim_target" "$home/state/tg-watch.check.sh"
  ln -s "$cadence_target" "$home/config/tg-mode.env"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FMTG: Telegram mode off - failed to arm inbox poll shim or 30s cadence" \
    "bootstrap must reject linked Telegram-mode destinations"
  assert_not_contains "$out" "FMTG: Telegram mode on" \
    "bootstrap must not announce Telegram mode after rejecting linked destinations"
  [ "$(cat "$shim_target")" = 'external shim sentinel' ] \
    || fail "bootstrap changed the linked shim target"
  [ "$(cat "$cadence_target")" = 'external cadence sentinel' ] \
    || fail "bootstrap changed the linked cadence target"
  [ "$(path_mode "$shim_target")" = 640 ] \
    || fail "bootstrap changed the linked shim target mode"
  assert_absent "$home/state/tg-watch.check.sh" "bootstrap must remove the rejected shim link"
  assert_absent "$home/config/tg-mode.env" "bootstrap must remove the rejected cadence link"
  pass "bootstrap rejects linked Telegram artifacts without touching their targets"
}

test_migration_preserves_valid_tg_shim() {
  local home shim
  home=$(make_home migrate-preserve)
  shim="$home/state/tg-watch.check.sh"
  fmtg_poll_shim_content "$home" "$ROOT" > "$shim"
  chmod 0700 "$shim"
  FM_HOME="$home" "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 \
    || fail "migration failed with a valid Telegram shim armed"
  assert_present "$shim" "migration must not quarantine a byte-valid Telegram shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" \
    || fail "migration changed the valid Telegram shim"
  ! find "$home/state/.pr-check-quarantine" -name 'tg-watch.check.*' -type f 2>/dev/null | grep . >/dev/null \
    || fail "valid Telegram shim was quarantined"
  # And the --checks-safe watcher gate accepts the armed home.
  FM_HOME="$home" "$ROOT/bin/fm-pr-check-migrate.sh" --checks-safe >/dev/null 2>&1 \
    || fail "--checks-safe rejected a home with only a valid Telegram shim"
  pass "the PR-check migration preserves a byte-valid Telegram shim"
}

test_migration_neutralizes_tampered_tg_shim() {
  local home shim executed
  home=$(make_home migrate-tampered)
  shim="$home/state/tg-watch.check.sh"
  executed="$home/tampered-executed"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'touch %s\n' "$executed"
  } > "$shim"
  chmod 0700 "$shim"
  FM_HOME="$home" "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 || true
  [ ! -e "$executed" ] || fail "migration executed a tampered Telegram shim"
  assert_absent "$shim" "a tampered Telegram shim must not remain armed"
  pass "the PR-check migration neutralizes a tampered Telegram shim without executing it"
}

# Run the real watcher, bounded, against a home whose only check is the tg shim.
run_watcher_bounded() {
  local home=$1 inbox=$2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" PHONE_INBOX_ROOT="$inbox" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "$ROOT/bin/fm-watch.sh"
}

test_watcher_dispatches_valid_tg_shim_end_to_end() {
  local home out rc
  home=$(make_home watch-dispatch)
  add_note "$home" 0042
  fmtg_poll_shim_content "$home" "$ROOT" > "$home/state/tg-watch.check.sh"
  chmod 0700 "$home/state/tg-watch.check.sh"
  out=$(run_watcher_bounded "$home" "$home/inbox" 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher never woke for a pending note"
  assert_contains "$out" "tg-message 0042" "watcher wake must carry the note id"
  assert_not_contains "$out" "$BODY_SENTINEL" "note body leaked into the watcher wake"
  assert_not_contains "$out" "$SLUG_SENTINEL" "filename slug leaked into the watcher wake"
  assert_grep "tg-message 0042" "$home/state/.wake-queue" "durable wake record must carry the id"
  assert_no_grep "$BODY_SENTINEL" "$home/state/.wake-queue" "note body leaked into the durable wake queue"
  assert_no_grep "$SLUG_SENTINEL" "$home/state/.wake-queue" "filename slug leaked into the durable wake queue"
  pass "the real watcher dispatches the valid Telegram shim and wakes with ids only"
}

test_watcher_rejects_tampered_tg_shim() {
  local home out rc executed
  home=$(make_home watch-reject)
  add_note "$home" 0042
  executed="$home/tampered-executed"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'touch %s\n' "$executed"
  } > "$home/state/tg-watch.check.sh"
  chmod 0700 "$home/state/tg-watch.check.sh"
  out=$(run_watcher_bounded "$home" "$home/inbox" 2>/dev/null)
  rc=$?
  [ "$rc" -ge 0 ] || fail "watcher run failed to return"
  [ ! -e "$executed" ] || fail "watcher executed a tampered Telegram shim"
  assert_not_contains "$out" "tg-message" "a tampered shim must never produce a note wake"
  pass "the real watcher never executes a tampered Telegram shim"
}

test_link_records_note_and_timestamp() {
  local home meta out
  home="$TMP_ROOT/link-basic"; mkdir -p "$home/state"
  meta="$home/state/task-a.meta"
  fm_write_meta "$meta" "window=w" "project=p"
  out=$(FM_HOME="$home" FMTG_NOW_OVERRIDE=1234 "$ROOT/bin/fm-tg-link.sh" task-a 0042)
  assert_contains "$out" "linked task-a to telegram note 0042" "link must confirm"
  assert_grep "tg_note=0042" "$meta" "link must record the note id"
  assert_grep "tg_note_ts=1234" "$meta" "link must record the timestamp"
  assert_grep "tg_followups=0" "$meta" "a fresh link must start the counter at 0"
  assert_grep "window=w" "$meta" "link must preserve other meta lines"
  # Relink with carry preserves budget and window.
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 0042 --carry-count 2 --carry-ts 999 >/dev/null
  assert_grep "tg_followups=2" "$meta" "carry must preserve the consumed count"
  assert_grep "tg_note_ts=999" "$meta" "carry must preserve the original window"
  pass "fm-tg-link records and carries the note link in task meta"
}

test_link_rejects_unsafe_and_missing() {
  local home rc
  home="$TMP_ROOT/link-unsafe"; mkdir -p "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" '../evil' 0042 2>/dev/null; rc=$?
  expect_code 2 "$rc" "unsafe task id"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 'evil/../id' 2>/dev/null; rc=$?
  expect_code 2 "$rc" "unsafe note id"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 0042 2>/dev/null; rc=$?
  expect_code 1 "$rc" "missing meta"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 0042 --carry-count 1 2>/dev/null; rc=$?
  expect_code 2 "$rc" "carry-count without carry-ts"
  pass "fm-tg-link rejects unsafe ids, missing tasks, and unpaired carry flags"
}

make_fake_tg() {
  local dir=$1
  cat > "$dir/tg" <<SH
#!/usr/bin/env bash
cat >> '$dir/tg-sent.log'
printf '\n---\n' >> '$dir/tg-sent.log'
exit "\${FAKE_TG_EXIT:-0}"
SH
  chmod +x "$dir/tg"
  printf '%s\n' "$dir/tg"
}

test_followup_lifecycle() {
  local home meta tg out rc
  home="$TMP_ROOT/followup"; mkdir -p "$home/state"
  meta="$home/state/task-a.meta"
  tg=$(make_fake_tg "$home")

  # Unlinked task: --check is a silent exit-1 no-op.
  fm_write_meta "$meta" "window=w"
  FM_HOME="$home" "$ROOT/bin/fm-tg-followup.sh" --check task-a >/dev/null; rc=$?
  expect_code 1 "$rc" "unlinked check"

  # Linked and fresh: check prints the note id.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 >/dev/null
  out=$(FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 "$ROOT/bin/fm-tg-followup.sh" --check task-a)
  [ "$out" = "0042" ] || fail "due check must print the note id (got: $out)"

  # A send reads stdin/file only and pipes the text to tg on stdin.
  printf 'first milestone update' > "$home/reply.txt"
  FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a --text-file "$home/reply.txt" >/dev/null \
    || fail "first follow-up send failed"
  assert_grep "first milestone update" "$home/tg-sent.log" "tg must receive the text on stdin"
  assert_grep "tg_followups=1" "$meta" "a successful send must increment the counter"

  # A failed send leaves the counter and link untouched.
  printf 'failing update' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" FAKE_TG_EXIT=1 \
    "$ROOT/bin/fm-tg-followup.sh" task-a - >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed tg send must exit non-zero"
  assert_grep "tg_followups=1" "$meta" "a failed send must not increment the counter"
  assert_grep "tg_note=0042" "$meta" "a failed send must keep the link"

  # --final always clears the link.
  printf 'done: shipped' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a --final - >/dev/null \
    || fail "final follow-up send failed"
  assert_no_grep "tg_note=" "$meta" "--final must clear the link"

  # Reaching the cap clears the link after the send.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 --carry-count 2 --carry-ts 1000 >/dev/null
  printf 'third update' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a - >/dev/null || fail "cap-reaching send failed"
  assert_no_grep "tg_note=" "$meta" "reaching the cap must clear the link"

  # An expired window prunes on check without sending.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 >/dev/null
  FM_HOME="$home" FMTG_NOW_OVERRIDE=99999999 "$ROOT/bin/fm-tg-followup.sh" --check task-a >/dev/null; rc=$?
  expect_code 1 "$rc" "expired check"
  assert_no_grep "tg_note=" "$meta" "an expired link must be pruned"

  # An empty follow-up is refused before reaching tg.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 >/dev/null
  printf '   ' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "empty follow-up refusal"
  pass "fm-tg-followup enforces the stdin-only, cap, window, and final-clear contract"
}

test_supervision_needed_by_tg_shim() {
  local home
  home="$TMP_ROOT/sup-needed"; mkdir -p "$home/state"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_status "$home/state"
  [ "$FM_SUP_NEEDED" = false ] || fail "an empty home must not need supervision"
  : > "$home/state/tg-watch.check.sh"
  fm_supervision_status "$home/state"
  [ "$FM_SUP_NEEDED" = true ] || fail "a Telegram-armed home must need supervision with no fleet work"
  pass "fm_supervision_status counts the Telegram poll as supervision-needed"
}

test_supervision_instructions_carry_tg_cadence() {
  local home out
  home="$TMP_ROOT/sup-instructions"; mkdir -p "$home/config"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/tg-mode.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude 2>/dev/null)
  assert_contains "$out" "Telegram mode: active; source $home/config/tg-mode.env" \
    "the operating block must name the Telegram cadence file"
  # X mode being off must not contradict the Telegram 30s cadence one line down.
  assert_not_contains "$out" "default watcher cadence" \
    "an inactive X mode must not claim the default cadence while Telegram mode is active"
  assert_not_contains "$out" "Watcher cadence: default" \
    "the block must not claim the default cadence while Telegram mode is active"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line 2>/dev/null)
  assert_contains "$out" "source '$home/config/tg-mode.env' first" \
    "the repair line must source the Telegram cadence file"
  # Without the file the current-state block does not claim the mode is active.
  rm "$home/config/tg-mode.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude 2>/dev/null)
  assert_not_contains "$out" "- Telegram mode: active" \
    "a non-opted-in home must not report Telegram mode active"
  assert_contains "$out" "- Telegram mode: inactive." \
    "the block must report Telegram mode inactive symmetrically with X mode"
  assert_contains "$out" "Watcher cadence: default" \
    "with both modes off the block must state the default cadence once"
  pass "supervision instructions carry the Telegram cadence exactly when armed"
}

test_poll_no_optin_is_hard_noop
test_poll_emits_ids_only_never_note_text
test_poll_multiple_ids_one_line
test_poll_offers_once_then_silent
test_poll_reoffers_stale_unclaimed_note
test_poll_prunes_markers_for_gone_notes
test_poll_missing_inbox_reports_once
test_poll_ignores_malformed_filenames
test_shim_validation_accepts_only_exact_private_identity
test_bootstrap_inert_without_optin
test_bootstrap_activates_on_optin_flag
test_bootstrap_opt_out_cleanup
test_bootstrap_does_not_follow_tg_artifact_symlinks
test_migration_preserves_valid_tg_shim
test_migration_neutralizes_tampered_tg_shim
test_watcher_dispatches_valid_tg_shim_end_to_end
test_watcher_rejects_tampered_tg_shim
test_link_records_note_and_timestamp
test_link_rejects_unsafe_and_missing
test_followup_lifecycle
test_supervision_needed_by_tg_shim
test_supervision_instructions_carry_tg_cadence

printf 'fm-tg-mode: all tests passed\n'
