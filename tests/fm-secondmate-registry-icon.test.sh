#!/usr/bin/env bash
# The optional `icon: <glyph>;` field of a data/secondmates.md record, through
# the bash grammar that owns the format (bin/fm-secondmate-registry-lib.sh),
# the fleet snapshot's jq copy of it, and the local seed writer that rewrites
# an already-registered id's line and must carry the icon across.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-registry-icon)

test_grammar_parses_icon_in_both_forms() {
  local line
  line='- writer - Writes (the chapters) (home: /h/w; scope: writing; projects: book, notes; icon: 🎙️; added 2026-10-07)'
  secondmate_registry_parse_line "$line" || fail "local line with icon did not parse"
  assert_equals writer "$SECONDMATE_REGISTRY_ID" "local id"
  assert_equals 'Writes (the chapters)' "$SECONDMATE_REGISTRY_SUMMARY" "local summary"
  assert_equals /h/w "$SECONDMATE_REGISTRY_HOME" "local home"
  assert_equals writing "$SECONDMATE_REGISTRY_SCOPE" "local scope"
  assert_equals 'book, notes' "$SECONDMATE_REGISTRY_PROJECTS" "local projects"
  assert_equals '🎙️' "$SECONDMATE_REGISTRY_ICON" "local icon"
  assert_equals 2026-10-07 "$SECONDMATE_REGISTRY_ADDED" "local added"
  assert_equals 0 "$SECONDMATE_REGISTRY_REMOTE" "local form is not remote"

  line='- lab - Far (host: build-mac; root: /r; home: /h/r; scope: far; projects: y; icon: 🔬; added 2026-10-08)'
  secondmate_registry_parse_line "$line" || fail "remote line with icon did not parse"
  assert_equals lab "$SECONDMATE_REGISTRY_ID" "remote id"
  assert_equals build-mac "$SECONDMATE_REGISTRY_HOST" "remote host"
  assert_equals /r "$SECONDMATE_REGISTRY_ROOT" "remote root"
  assert_equals /h/r "$SECONDMATE_REGISTRY_HOME" "remote home"
  assert_equals y "$SECONDMATE_REGISTRY_PROJECTS" "remote projects"
  assert_equals '🔬' "$SECONDMATE_REGISTRY_ICON" "remote icon"
  assert_equals 2026-10-08 "$SECONDMATE_REGISTRY_ADDED" "remote added"
  assert_equals 1 "$SECONDMATE_REGISTRY_REMOTE" "remote form is remote"

  line='- plain - Plain (home: /h/p; scope: plain; projects: x; added 2026-10-09)'
  secondmate_registry_parse_line "$line" || fail "icon-less local line did not parse"
  assert_equals '' "$SECONDMATE_REGISTRY_ICON" "icon-less local icon is empty"
  assert_equals x "$SECONDMATE_REGISTRY_PROJECTS" "icon-less local projects"
  assert_equals 2026-10-09 "$SECONDMATE_REGISTRY_ADDED" "icon-less local added"

  line='- plainr - Plain (host: h; root: /r; home: /h/q; scope: plain; projects: z; added 2026-10-10)'
  secondmate_registry_parse_line "$line" || fail "icon-less remote line did not parse"
  assert_equals '' "$SECONDMATE_REGISTRY_ICON" "icon-less remote icon is empty"
  assert_equals /h/q "$SECONDMATE_REGISTRY_HOME" "icon-less remote home"
  assert_equals 2026-10-10 "$SECONDMATE_REGISTRY_ADDED" "icon-less remote added"

  line='- bad - Bad (home: /h/b; scope: s; projects: x; icon: ; added 2026-10-11)'
  secondmate_registry_parse_line "$line" || fail "empty icon field did not parse"
  assert_equals '' "$SECONDMATE_REGISTRY_ICON" "empty icon field reads as no icon"

  cat > "$TMP_ROOT/field-registry.md" <<'REG'
- writer - Writes (home: /h/w; scope: writing; projects: book; icon: 🎙️; added 2026-10-07)
- lab - Far (host: build-mac; root: /r; home: /h/r; scope: far; projects: y; icon: 🔬; added 2026-10-08)
- plain - Plain (home: /h/p; scope: plain; projects: x; added 2026-10-09)
REG
  assert_equals '🎙️' "$(secondmate_registry_field "$TMP_ROOT/field-registry.md" writer icon)" "field icon (local)"
  assert_equals '🔬' "$(secondmate_registry_field "$TMP_ROOT/field-registry.md" lab icon)" "field icon (remote)"
  assert_equals '' "$(secondmate_registry_field "$TMP_ROOT/field-registry.md" plain icon)" "field icon (none)"
  assert_equals /h/r "$(secondmate_registry_field "$TMP_ROOT/field-registry.md" lab home)" "field home beside an icon"
  pass "registry grammar reads the optional icon field in both forms"
}

test_fleet_snapshot_reads_routes_around_the_icon() {
  local home out
  home="$TMP_ROOT/snapshot-home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$home/data/secondmates.md" <<'REG'
- writer - Writes (home: /h/w; scope: writing; projects: book; icon: 🎙️; added 2026-10-07)
- lab - Far (host: build-mac; root: /r; home: /h/r; scope: far; projects: y; icon: 🔬; added 2026-10-08)
- plain - Plain (home: /h/p; scope: plain; projects: x; added 2026-10-09)
REG
  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-10-07T18:00:00Z FM_SNAPSHOT_NOW_EPOCH=1791396000 \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed on an icon-bearing registry"
  printf '%s' "$out" | jq -e '
    .secondmate_current.registry
    | .available == true and .complete == true
      and ([.records[] | select(.id == "writer")][0]
        | .home == "/h/w" and .remote == false and .registry_error == null)
      and ([.records[] | select(.id == "lab")][0]
        | .home == "/h/r" and .host == "build-mac" and .root == "/r" and .remote == true and .registry_error == null)
      and ([.records[] | select(.id == "plain")][0]
        | .home == "/h/p" and .remote == false and .registry_error == null)
  ' >/dev/null || fail "fleet snapshot misread icon-bearing registry routes: $out"
  pass "fleet snapshot resolves local and remote routes around the icon field"
}

test_local_reseed_keeps_the_icon() {
  local parent child line
  parent="$TMP_ROOT/reseed-parent"
  child="$TMP_ROOT/reseed-child"
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$parent/projects"
  FM_SECONDMATE_CHARTER='Icon re-seed charter.' FM_HOME="$parent" \
    "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
    || fail "first local seed failed"
  secondmate_registry_line_for_id "$parent/data/secondmates.md" mate || fail "first seed left no registry line"
  assert_equals '' "$SECONDMATE_REGISTRY_ICON" "a fresh seed registers no icon"
  line=$SECONDMATE_REGISTRY_LINE
  printf '%s\n' "${line%added *}icon: 🧪; added ${line##*added }" > "$parent/data/secondmates.md"
  secondmate_registry_line_for_id "$parent/data/secondmates.md" mate || fail "hand-edited icon line did not parse"
  assert_equals '🧪' "$SECONDMATE_REGISTRY_ICON" "hand-edited icon is in place"
  FM_SECONDMATE_CHARTER='Icon re-seed charter.' FM_HOME="$parent" \
    "$ROOT/bin/fm-home-seed.sh" mate "$child" --no-projects >/dev/null \
    || fail "same-placement local re-seed failed"
  assert_equals 1 "$(grep -c '^- mate ' "$parent/data/secondmates.md")" "re-seed keeps exactly one line for the id"
  secondmate_registry_line_for_id "$parent/data/secondmates.md" mate || fail "re-seeded line did not parse"
  assert_equals '🧪' "$SECONDMATE_REGISTRY_ICON" "re-seed must carry the existing icon across"
  assert_equals "$(cd "$child" && pwd -P)" "$SECONDMATE_REGISTRY_HOME" "re-seed keeps the home"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation failed after re-seed"
  pass "local same-placement re-seed preserves the registered icon"
}

test_grammar_parses_icon_in_both_forms
test_fleet_snapshot_reads_routes_around_the_icon
test_local_reseed_keeps_the_icon
