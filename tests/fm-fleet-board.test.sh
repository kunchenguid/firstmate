#!/usr/bin/env bash
# Behavior tests for bin/fm-fleet-board.sh - the read-only HTML fleet board.
#
# The board renders data/backlog.md + each state/<id>.meta + per-task live state
# (from a crew-state command, faked here so the suite is hermetic) into one
# self-contained dark HTML file. These cases pin the contract:
#   (a) in-flight / queued / done rows render with the right id, chips, and detail
#   (b) live crew-state feeds the in-flight state chip and "Now" activity line
#   (c) full https PR urls and scout report paths surface in Done detail
#   (d) HTML special characters in descriptions are escaped
#   (e) the file is self-contained: inline <style>, no external asset references
#   (f) empty sections and a missing backlog degrade without crashing
#   (g) an in-flight task with no meta still renders (unknown state)
#   (h) the run is READ-ONLY: no state/data file is created or modified
#   (i) the default output path is $FM_HOME/.lavish/fleet-board.html
#   (j) shellcheck passes on the script when shellcheck is installed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-fleet-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-board)
mkdir -p "$TMP_ROOT"

# A fake crew-state command: echoes a working run-step line for taskone and an
# unknown line for anything else, mirroring fm-crew-state.sh's output contract.
FAKE_CS="$TMP_ROOT/fakecs"
cat > "$FAKE_CS" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  taskone) printf 'state: working · source: run-step · validating (running)\n' ;;
  *)       printf 'state: unknown · source: none · no current-state source available\n' ;;
esac
SH
chmod +x "$FAKE_CS"

# A populated fixture home with all three backlog sections and one in-flight meta.
make_home() {  # <home>
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] taskone - Build a widget with "quotes" & <angles> (repo: alpha) (kind: ship) (since 2026-07-08)

## Queued
- [ ] tasktwo - A follow up that waits blocked-by: taskone (repo: alpha) (kind: ship) (since 2026-07-08)

## Done
- [x] taskdone - Landed change - https://github.com/acme/alpha/pull/42 (merged 2026-07-08) (repo: alpha) (kind: ship)
- [x] scoutdone - Investigation write-up data/scoutdone/report.md (repo: alpha) (kind: scout) (reported 2026-07-08)
EOF
  fm_write_meta "$home/state/taskone.meta" \
    "window=firstmate:fm-taskone" \
    "worktree=$home/nowt" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "model=claude-opus-4-8" \
    "effort=high"
}

# Fingerprint every file under the given dirs (path + content hash), so a
# before/after comparison proves the render mutated nothing.
tree_fingerprint() {  # <dir>...
  local d
  for d in "$@"; do
    [ -d "$d" ] || continue
    find "$d" -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null
  done
}

# --- (a)-(e) full render over the populated fixture -------------------------

HOME1="$TMP_ROOT/home1"
make_home "$HOME1"
OUT1="$TMP_ROOT/board1.html"

before=$(tree_fingerprint "$HOME1/data" "$HOME1/state")
printed=$(FM_HOME="$HOME1" FM_CREW_STATE_CMD="$FAKE_CS" "$BOARD" --out "$OUT1")
after=$(tree_fingerprint "$HOME1/data" "$HOME1/state")

[ "$printed" = "$OUT1" ] || fail "script must print the output path (got: $printed)"
[ -f "$OUT1" ] || fail "expected board HTML at $OUT1"
html=$(cat "$OUT1")

# (a) rows and section grouping
assert_contains "$html" '<div class="group">In flight' "in-flight group header present"
assert_contains "$html" '<div class="group">Queued'    "queued group header present"
assert_contains "$html" '<div class="group">Done'      "done group header present"
assert_contains "$html" '<span class="id">taskone</span>'  "taskone row present"
assert_contains "$html" '<span class="id">tasktwo</span>'  "tasktwo row present"
assert_contains "$html" '<span class="id">taskdone</span>' "taskdone row present"
assert_contains "$html" '<span class="id">scoutdone</span>' "scoutdone row present"

# (b) live crew-state drives the in-flight chip and activity line
assert_contains "$html" '<span class="chip st-work">working</span>' "in-flight working chip from crew-state"
assert_contains "$html" 'validating (running)' "in-flight Now line from crew-state detail"
assert_contains "$html" 'claude · claude-opus-4-8 · high effort · firstmate:fm-taskone' "agent line from meta"

# queued blocked-by chip and done chips
assert_contains "$html" '<span class="chip st-queue">blocked-by: taskone</span>' "queued blocked-by chip"
assert_contains "$html" '<span class="chip st-done">merged</span>' "done ship merged chip"
assert_contains "$html" '<span class="chip st-done">done</span>'   "done scout chip"

# (c) full https PR url and scout report path
assert_contains "$html" 'href="https://github.com/acme/alpha/pull/42"' "full PR url link in Done detail"
assert_contains "$html" 'data/scoutdone/report.md' "scout report path in Done detail"

# (d) HTML escaping of description special characters
assert_contains "$html" '&quot;quotes&quot; &amp; &lt;angles&gt;' "description special chars escaped"
assert_not_contains "$html" '"quotes" & <angles>' "raw unescaped description must not appear"

# (e) self-contained: inline style, no external asset references
assert_contains "$html" '<style>' "inline stylesheet present"
assert_not_contains "$html" 'rel="stylesheet"' "no external stylesheet link"
assert_not_contains "$html" '<script' "no external or inline script tags"
assert_not_contains "$html" 'src="http' "no external image/script src"

# (h) read-only: nothing under data/ or state/ changed
[ "$before" = "$after" ] || fail "render mutated fixture state (data/ or state/ changed)"$'\n'"before:"$'\n'"$before"$'\n'"after:"$'\n'"$after"
assert_absent "$HOME1/state/board.status" "render must not create status files"

pass "populated fleet renders all sections, chips, links, escaping; read-only"

# --- (f) empty sections and a missing backlog -------------------------------

HOME2="$TMP_ROOT/home2"
mkdir -p "$HOME2/data" "$HOME2/state"
cat > "$HOME2/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
EOF
OUT2="$TMP_ROOT/board2.html"
FM_HOME="$HOME2" FM_CREW_STATE_CMD="$FAKE_CS" "$BOARD" --out "$OUT2" >/dev/null || fail "empty-section render exited non-zero"
empty_html=$(cat "$OUT2")
assert_contains "$empty_html" 'In flight · 0 task(s)' "empty in-flight group shows zero count"
assert_contains "$empty_html" 'nothing here' "empty section shows placeholder"

# missing backlog file entirely
HOME3="$TMP_ROOT/home3"
mkdir -p "$HOME3"
OUT3="$TMP_ROOT/board3.html"
FM_HOME="$HOME3" "$BOARD" --out "$OUT3" >/dev/null || fail "missing-backlog render exited non-zero"
[ -f "$OUT3" ] || fail "missing-backlog render must still produce an HTML file"

pass "empty sections and a missing backlog degrade without crashing"

# --- (g) in-flight task with no meta ----------------------------------------

HOME4="$TMP_ROOT/home4"
mkdir -p "$HOME4/data" "$HOME4/state"
printf '## In flight\n- [ ] ghost - orphan task (repo: alpha) (kind: ship)\n' > "$HOME4/data/backlog.md"
OUT4="$TMP_ROOT/board4.html"
FM_HOME="$HOME4" FM_CREW_STATE_CMD="$FAKE_CS" "$BOARD" --out "$OUT4" >/dev/null || fail "no-meta render exited non-zero"
ghost_html=$(cat "$OUT4")
assert_contains "$ghost_html" '<span class="id">ghost</span>' "no-meta task still renders its row"
assert_contains "$ghost_html" '<span class="chip st-idle">unknown</span>' "no-meta task renders unknown state"

pass "in-flight task with no meta renders with unknown state"

# --- (i) default output path ------------------------------------------------

HOME5="$TMP_ROOT/home5"
make_home "$HOME5"
default_out=$(FM_HOME="$HOME5" FM_CREW_STATE_CMD="$FAKE_CS" "$BOARD")
[ "$default_out" = "$HOME5/.lavish/fleet-board.html" ] || fail "default out must be \$FM_HOME/.lavish/fleet-board.html (got: $default_out)"
[ -f "$default_out" ] || fail "default output file not written"

pass "default output path is \$FM_HOME/.lavish/fleet-board.html"

# --- (j) shellcheck ---------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$BOARD" || fail "shellcheck reported problems in fm-fleet-board.sh"
  pass "shellcheck clean"
else
  pass "shellcheck not installed - skipping lint assertion"
fi
