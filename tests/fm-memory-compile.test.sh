#!/usr/bin/env bash
# Behavioral coverage for the compiled, capped startup working-memory bundle and
# for the mechanical split of data/learnings.md into atomic notes.
#
# Every assertion here goes through bin/fm-memory-compile.sh or
# bin/fm-memory-migrate.sh and reads their real output or the real files they
# leave on disk.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-compile)
# A literal backtick, so a quoted assertion never has to carry one.
BACKTICK=$(printf '\140')
COMPILE="$ROOT/bin/fm-memory-compile.sh"
MIGRATE="$ROOT/bin/fm-memory-migrate.sh"

# new_home <name> [budget]: a home with the budget published and nothing else,
# so each test states exactly the memory it is exercising.
new_home() {
  local budget=${2:-7500} home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/data/memory"
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
  printf '%s\n' "$home"
}

# write_note <home> <slug> <title> <triggers> <updated> [padding-lines]
write_note() {
  local home=$1 slug=$2 title=$3 triggers=$4 updated=$5 pad=${6:-0} i
  mkdir -p "$home/data/memory/notes"
  {
    printf -- '---\n'
    printf 'title: %s\n' "$title"
    printf 'triggers: %s\n' "$triggers"
    printf 'updated: %s\n' "$updated"
    printf -- '---\n\n'
    printf 'BODY-OF-%s\n' "$slug"
    i=0
    while [ "$i" -lt "$pad" ]; do
      printf 'padding line %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
      i=$((i + 1))
    done
  } > "$home/data/memory/notes/$slug.md"
}

compile() {
  local home=$1
  shift
  FM_HOME="$home" "$COMPILE" compile "$@"
}

# accounting_field <output> <name>: one value from the MEMORY_ACCOUNTING line.
accounting_field() {
  printf '%s\n' "$1" | awk -v key="$2" '
    /^MEMORY_ACCOUNTING:/ {
      for (i = 2; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == key) { print kv[2]; exit }
      }
    }'
}

# --- bundle shape -----------------------------------------------------------

test_bundle_is_core_catalog_and_matched_notes_only() {
  local home out
  home=$(new_home bundle-shape)
  mkdir -p "$home/data/memory/notes" "$home/data/memory/drop"
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  printf 'CAPTAIN-FILE-TEXT\n' > "$home/data/captain.md"
  printf -- '- healthlog [no-mistakes] - a project\n' > "$home/data/projects.md"
  write_note "$home" matched 'A matched claim' 'healthlog' 2026-08-18
  write_note "$home" unmatched 'An unmatched claim' 'penguin' 2026-08-01
  printf 'DROP-TRAY-CANDIDATE\n' > "$home/data/memory/drop/candidate.md"

  out=$(compile "$home")

  assert_contains "$out" 'STANDING-CORE-TEXT' 'core.md body was not injected'
  assert_not_contains "$out" 'CAPTAIN-FILE-TEXT' \
    'captain.md was injected even though data/memory/core.md exists'
  assert_contains "$out" 'A matched claim' 'catalog did not list the matched note'
  assert_contains "$out" 'An unmatched claim' \
    'catalog omitted a note that exists - the catalog must list every note'
  assert_contains "$out" 'BODY-OF-matched' 'trigger-matched note body was not injected'
  assert_not_contains "$out" 'BODY-OF-unmatched' \
    'a note whose triggers did not match was injected anyway'
  assert_not_contains "$out" 'DROP-TRAY-CANDIDATE' \
    'the drop tray was injected; the compiler must ignore it'
  [ "$(accounting_field "$out" status)" = within-budget ] \
    || fail "an unconstrained compile did not report within-budget: $out"
  [ "$(accounting_field "$out" hot_notes)" = 1 ] \
    || fail "expected exactly one hot note: $out"
  [ "$(accounting_field "$out" notes_total)" = 2 ] \
    || fail "accounting did not count every note on disk: $out"
  pass 'the bundle is core plus a catalog of every note plus only the matched note bodies'
}

test_core_falls_back_to_captain_then_reports_absence() {
  local home out
  home=$(new_home core-fallback)
  mkdir -p "$home/data/memory/notes"
  printf 'CAPTAIN-FILE-TEXT\n' > "$home/data/captain.md"

  out=$(compile "$home")
  assert_contains "$out" 'CAPTAIN-FILE-TEXT' \
    'captain.md was not used as the core while data/memory/core.md is absent'
  assert_contains "$out" 'data/memory/core.md is ABSENT' \
    'the bundle did not say which file was standing in as the core'

  rm -f "$home/data/captain.md"
  out=$(compile "$home")
  assert_contains "$out" 'MEMORY_NOTICE: no core memory' \
    'a home with no core at all did not say so'
  [ "$(accounting_field "$out" core)" = 0 ] || fail "absent core was not accounted as 0: $out"
  pass 'the core is core.md, then captain.md, and its total absence is reported'
}

# --- trigger matching -------------------------------------------------------

test_triggers_match_whole_words_case_insensitively() {
  local home out
  home=$(new_home triggers)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" boundary 'Bounded claim' 'lint' 2026-08-18
  write_note "$home" untriggered 'Claim with no triggers' '' 2026-08-18
  write_note "$home" multiword 'Multi word claim' 'host clock' 2026-08-18

  out=$(compile "$home" --no-auto-context --context 'the repo left commands.lint unset')
  assert_contains "$out" 'BODY-OF-boundary' \
    'trigger "lint" did not match "commands.lint", where a dot is a word boundary'

  out=$(compile "$home" --no-auto-context --context 'we spent the day linting')
  assert_not_contains "$out" 'BODY-OF-boundary' \
    'trigger "lint" matched inside the word "linting"'

  out=$(compile "$home" --no-auto-context --context 'Commands.LINT is unset')
  assert_contains "$out" 'BODY-OF-boundary' 'trigger matching was case sensitive'

  out=$(compile "$home" --no-auto-context --context 'the HOST CLOCK stepped backwards')
  assert_contains "$out" 'BODY-OF-multiword' 'a multi-word trigger did not match'

  out=$(compile "$home" --no-auto-context --context 'claim with no triggers lint host clock'
)
  assert_not_contains "$out" 'BODY-OF-untriggered' \
    'a note with no triggers became hot; only the catalog should carry it'
  assert_contains "$out" 'Claim with no triggers' \
    'a note with no triggers fell out of the catalog too'
  pass 'triggers match on word boundaries, ignore case, allow several words, and are required'
}

test_auto_context_reads_live_fleet_work() {
  local home out
  home=$(new_home auto-context)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" fromproject 'Project claim' 'healthlog' 2026-08-18
  write_note "$home" frombacklog 'Backlog claim' 'voicemaster' 2026-08-18
  write_note "$home" frommeta 'Runtime claim' 'opencode' 2026-08-18
  write_note "$home" fromnowhere 'Unrelated claim' 'penguin' 2026-08-18

  printf -- '- healthlog [no-mistakes] - a project\n' > "$home/data/projects.md"
  printf '## In flight\n\n- fix the voicemaster suite\n' > "$home/data/backlog.md"
  printf 'harness=opencode\nwindow=firstmate:x\n' > "$home/state/x.meta"

  out=$(compile "$home")
  assert_contains "$out" 'BODY-OF-fromproject' 'a project name did not pull its note hot'
  assert_contains "$out" 'BODY-OF-frombacklog' 'a backlog title did not pull its note hot'
  assert_contains "$out" 'BODY-OF-frommeta' 'live task metadata did not pull its note hot'
  assert_not_contains "$out" 'BODY-OF-fromnowhere' 'an unrelated note was pulled hot'

  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'BODY-OF-fromproject' \
    '--no-auto-context still read the fleet for match terms'
  pass 'auto context is the project registry, the backlog, and live task metadata'
}

# --- budget cap -------------------------------------------------------------

test_budget_cap_drops_notes_first_then_the_catalog_and_never_the_core() {
  local home out full core_tokens catalog_tokens small_tokens budget
  home=$(new_home budget 1000000)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_note "$home" big 'Big claim' 'bigtrig' 2026-08-18 200
  write_note "$home" small 'Small claim' 'smalltrig' 2026-08-17 1

  full=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  [ "$(accounting_field "$full" hot_notes)" = 2 ] \
    || fail "an unconstrained compile did not take both matched notes: $full"
  core_tokens=$(accounting_field "$full" core)
  catalog_tokens=$(accounting_field "$full" catalog)
  small_tokens=$(accounting_field "$(compile "$home" --no-auto-context --context smalltrig)" hot_notes_tokens)

  # Exactly enough room for the core, the catalog, and the small note - and the
  # big note is offered FIRST, because it is the newer of the two.
  budget=$((core_tokens + catalog_tokens + small_tokens))
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
  out=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'the core was dropped under budget pressure'
  assert_contains "$out" 'Big claim' 'a dropped note left the catalog'
  assert_contains "$out" 'BODY-OF-small' \
    'a large note that did not fit starved the small note behind it'
  assert_not_contains "$out" 'BODY-OF-big' 'a note that did not fit was injected anyway'
  assert_contains "$out" 'MEMORY_BUDGET_NOTICE:' 'dropping a note was silent'
  [ "$(accounting_field "$out" status)" = capped ] \
    || fail "dropping a note was not reported as capped: $out"
  [ "$(accounting_field "$out" hot_dropped)" = 1 ] || fail "hot_dropped was wrong: $out"
  [ "$(accounting_field "$out" injected_total)" -le "$budget" ] \
    || fail "the injected total exceeded the budget: $out"

  # Room for the core but not the catalog: the catalog goes, and loudly.
  printf '%s\n' "$((core_tokens + 1))" > "$home/config/startup-memory-budget"
  out=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'the core was dropped to fit the catalog'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING:' 'dropping the catalog was silent'
  assert_not_contains "$out" 'Big claim' 'the catalog was printed after being accounted as dropped'
  [ "$(accounting_field "$out" catalog)" = 0 ] || fail "a dropped catalog was still accounted: $out"

  # Not even room for the core: it is still printed, in full, and alone.
  printf '1\n' > "$home/config/startup-memory-budget"
  out=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'an over-budget core was truncated or dropped'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING: the core alone is' \
    'an over-budget core did not produce an explicit warning'
  assert_not_contains "$out" 'Big claim' 'notes were listed under an over-budget core'
  assert_not_contains "$out" 'BODY-OF-small' 'a note was injected under an over-budget core'
  [ "$(accounting_field "$out" status)" = over-budget ] \
    || fail "an over-budget core did not report over-budget: $out"
  expect_code 0 "$(compile "$home" --no-auto-context >/dev/null 2>&1; echo $?)" \
    'an over-budget core must warn without failing the session'
  pass 'the cap drops notes first, then the catalog, and never the core'
}

test_an_unreadable_budget_is_a_hard_error() {
  local home out rc
  home=$(new_home unreadable-budget)
  printf 'CORE\n' > "$home/data/memory/core.md"
  printf 'not-a-number\n' > "$home/config/startup-memory-budget"
  set +e
  out=$(compile "$home" --no-auto-context 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'an unreadable budget must not compile a silently uncapped bundle'
  assert_contains "$out" 'value must be one positive decimal integer' \
    'the budget failure did not name what was wrong'
  pass 'a budget that cannot be read stops the compile instead of being assumed'
}

# --- degradation ------------------------------------------------------------

test_missing_memory_still_produces_a_bundle() {
  local home out
  home=$(new_home missing)
  printf 'CAPTAIN-FILE-TEXT\n' > "$home/data/captain.md"

  out=$(compile "$home" --no-auto-context)
  assert_contains "$out" 'CAPTAIN-FILE-TEXT' 'a home with no data/memory/ produced no core'
  assert_contains "$out" 'No notes filed yet' 'an empty note set was not stated plainly'
  assert_contains "$out" 'data/memory/catalog.md is ABSENT' 'an absent catalog file was not reported'

  printf 'OLD-LEARNINGS-TEXT\n' > "$home/data/learnings.md"
  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'OLD-LEARNINGS-TEXT' \
    'data/learnings.md was injected; only migrated notes belong in the bundle'
  assert_contains "$out" 'data/learnings.md is still present' \
    'an unmigrated data/learnings.md was dropped without a word'
  pass 'a home missing memory files still compiles a bundle and names what is missing'
}

test_a_symlinked_note_is_skipped_not_followed() {
  local home out outside
  home=$(new_home symlink-note)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" real 'Real claim' 'trigger' 2026-08-18
  outside="$TMP_ROOT/outside-note.md"
  printf 'OUTSIDE-SECRET\n' > "$outside"
  ln -s "$outside" "$home/data/memory/notes/linked.md"

  out=$(compile "$home" --no-auto-context --context trigger)
  assert_contains "$out" 'BODY-OF-real' 'the ordinary note was lost'
  assert_not_contains "$out" 'OUTSIDE-SECRET' 'a symlinked note was read out of the memory directory'
  [ "$(accounting_field "$out" notes_total)" = 1 ] || fail "a symlinked note was counted: $out"
  pass 'a symlinked note is skipped rather than followed out of data/memory/notes'
}

# --- catalog publication ----------------------------------------------------

test_catalog_publishes_and_reports_its_own_staleness() {
  local home out
  home=$(new_home catalog)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" one 'First claim' 'alpha' 2026-08-18

  FM_HOME="$home" "$COMPILE" catalog >/dev/null || fail 'catalog publication failed'
  assert_contains "$(<"$home/data/memory/catalog.md")" 'First claim' \
    'the published catalog did not list the note'
  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'catalog.md on disk is stale' \
    'a freshly published catalog was called stale'

  write_note "$home" two 'Second claim' 'beta' 2026-08-19
  out=$(compile "$home" --no-auto-context)
  assert_contains "$out" 'Second claim' \
    'the injected catalog was read from the stale file instead of the notes'
  assert_contains "$out" 'catalog.md on disk is stale' 'a stale catalog file was not reported'

  FM_HOME="$home" "$COMPILE" catalog >/dev/null
  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'catalog.md on disk is stale' 'republishing did not clear the staleness'
  pass 'the catalog is published on demand, rendered fresh on every compile, and reports staleness'
}

# --- migration --------------------------------------------------------------

seed_learnings() {
  local home=$1
  cat > "$home/data/learnings.md" <<'LEARN'
<!-- memory tiers: see the stow skill -->

## An unset `commands.lint` sends the pipeline agent scanning the whole disk <!--a:2026-08-18-->

FIRST-BODY line one.
FIRST-BODY line two.

## 2026-08-15 - a conflicted PR silently gets NO checks at all <!--g-->

SECOND-BODY line.

## Healthlog browser tests cannot run two at a time (2026-08-13)

THIRD-BODY line.
LEARN
}

test_migration_splits_learnings_into_atomic_cited_notes() {
  local home out note
  home=$(new_home migrate)
  printf 'CAPTAIN\n' > "$home/data/captain.md"
  seed_learnings "$home"

  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") \
    || fail "migration failed: $out"
  assert_contains "$out" '3 note(s) created' 'the migration did not create one note per heading'

  note="$home/data/memory/notes/an-unset-commands-lint-sends-the-pipeline-agent-scanning-the.md"
  [ -f "$note" ] || fail "expected note file missing: $(ls "$home/data/memory/notes")"
  assert_contains "$(<"$note")" "title: An unset ${BACKTICK}commands.lint${BACKTICK} sends the pipeline agent scanning the whole disk" \
    'the note title was not the heading with its tier marker stripped'
  assert_contains "$(<"$note")" 'updated: 2026-08-18' 'the tier marker date did not become the updated date'
  assert_contains "$(<"$note")" 'tier: <!--a:2026-08-18-->' 'the raw tier marker was not preserved'
  assert_contains "$(<"$note")" 'source: data/learnings.md' 'the note carried no provenance'
  assert_contains "$(<"$note")" 'commands.lint' 'a backticked identifier did not become a trigger'
  assert_contains "$(<"$note")" 'FIRST-BODY line two.' 'the note body was truncated'

  assert_contains "$(cat "$home"/data/memory/notes/*conflicted*)" 'updated: 2026-08-15' \
    'a leading heading date did not become the updated date'
  assert_contains "$(cat "$home"/data/memory/notes/*two-at-a-time*)" 'updated: 2026-08-13' \
    'a trailing heading date did not become the updated date'
  assert_contains "$(cat "$home"/data/memory/notes/*two-at-a-time*)" 'healthlog' \
    'a proper noun in the heading did not become a trigger'

  assert_contains "$(<"$home/data/memory/catalog.md")" 'a conflicted PR silently gets NO checks' \
    'the migration did not publish a catalog covering every note'
  [ -d "$home/data/memory/drop" ] || fail 'the migration did not create the drop tray'
  pass 'migration turns each learnings heading into one cited, dated, triggered note'
}

test_migration_freezes_and_archives_before_removing_the_original() {
  local home original out
  home=$(new_home migrate-history)
  seed_learnings "$home"
  original=$(<"$home/data/learnings.md")
  printf '# archive\n' > "$home/data/memory-archive.md"

  FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" >/dev/null \
    || fail 'migration failed'

  [ ! -e "$home/data/learnings.md" ] || fail 'the original was left in place by default'
  [ "$(<"$home/data/memory/raw/learnings-2026-08-20.md")" = "$original" ] \
    || fail 'the frozen copy is not byte-identical to the original'
  assert_contains "$(<"$home/data/memory-archive.md")" 'FIRST-BODY line one.' \
    'the original was not appended to the archive'
  assert_contains "$(<"$home/data/memory-archive.md")" 'archived from data/learnings.md' \
    'the archive append carried no dated banner'
  assert_contains "$(<"$home/data/memory-archive.md")" '# archive' \
    'the archive append replaced existing history instead of adding to it'

  # A second run must not duplicate history and must not lose the notes.
  seed_learnings "$home"
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") || fail 'rerun failed'
  assert_contains "$out" '0 note(s) created, 3 already present' \
    'rerunning the migration rewrote notes that already existed'
  [ "$(grep -c 'archived from data/learnings.md' "$home/data/memory-archive.md")" = 1 ] \
    || fail 'rerunning the migration duplicated the archive banner'
  pass 'the original is frozen and archived, verified, and only then removed'
}

test_migration_dry_run_and_keep_learnings_write_nothing_away() {
  local home out
  home=$(new_home migrate-safe)
  seed_learnings "$home"

  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" --dry-run) \
    || fail 'dry run failed'
  assert_contains "$out" 'created notes/' 'the dry run did not report what it would create'
  assert_contains "$out" 'nothing was written' 'the dry run did not say it wrote nothing'
  [ ! -d "$home/data/memory/notes" ] || fail 'the dry run created notes'
  [ -f "$home/data/learnings.md" ] || fail 'the dry run removed the original'

  FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" --keep-learnings >/dev/null \
    || fail 'keep-learnings run failed'
  [ -f "$home/data/learnings.md" ] || fail '--keep-learnings removed the original anyway'
  [ -f "$home/data/memory/raw/learnings-2026-08-20.md" ] \
    || fail '--keep-learnings skipped freezing the original'
  pass '--dry-run writes nothing and --keep-learnings leaves the original in place'
}

test_migration_refuses_to_remove_history_it_could_not_archive() {
  local home out rc
  home=$(new_home migrate-refuse)
  seed_learnings "$home"
  mkdir -p "$home/data/memory-archive.md"

  set +e
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'an unusable archive must stop the migration'
  assert_contains "$out" 'data/memory-archive.md is not an ordinary regular file' \
    'the archive failure did not name the problem'
  [ -f "$home/data/learnings.md" ] || fail 'the original was removed despite an unusable archive'
  pass 'the migration refuses to remove the original when it cannot archive it'
}

test_migration_on_a_home_with_no_learnings_still_builds_the_layout() {
  local home out
  home=$(new_home migrate-empty)
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") || fail 'migration failed'
  assert_contains "$out" 'nothing to split' 'an absent learnings file was not reported plainly'
  [ -d "$home/data/memory/notes" ] || fail 'the notes directory was not created'
  [ -d "$home/data/memory/drop" ] || fail 'the drop tray was not created'
  pass 'a home with no learnings file still gets a compilable data/memory/ layout'
}

test_bundle_is_core_catalog_and_matched_notes_only
test_core_falls_back_to_captain_then_reports_absence
test_triggers_match_whole_words_case_insensitively
test_auto_context_reads_live_fleet_work
test_budget_cap_drops_notes_first_then_the_catalog_and_never_the_core
test_an_unreadable_budget_is_a_hard_error
test_missing_memory_still_produces_a_bundle
test_a_symlinked_note_is_skipped_not_followed
test_catalog_publishes_and_reports_its_own_staleness
test_migration_splits_learnings_into_atomic_cited_notes
test_migration_freezes_and_archives_before_removing_the_original
test_migration_dry_run_and_keep_learnings_write_nothing_away
test_migration_refuses_to_remove_history_it_could_not_archive
test_migration_on_a_home_with_no_learnings_still_builds_the_layout

echo '# all fm-memory-compile tests passed'
