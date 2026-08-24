#!/usr/bin/env bash
# fm-decision-register-lib.sh - firstmate-private storage for captain-held
# decisions that no work item gates.
#
# A captain call is one of two things.
# When a real story-task already exists to gate on, the captain-hold lives on
# that task in the backlog (tasks-axi, unchanged).
# When there is no work item to hold - the classic scout-minted decision
# question, `<origin>-decision-<key>` - the call lives HERE, in a per-home
# private register under `state/decisions/`, so it never floods the backlog
# with rows that are not stories (captain, 2026-08-24; story fmops-07 §5;
# invariant "backlog task == story").
#
# Storage layout (one file per open decision):
#
#   state/decisions/<id>.md    schema-tagged frontmatter + body
#   state/decisions/<id>.lock  advisory single-writer lock (flock)
#
# The file uses the same field names tasks-axi's `show --full` output uses,
# so fm-captain-hold.sh's `show_field` / `show_field_value` helpers read them
# without special casing.
# `fm_decision_register_show` renders the on-disk file into the exact shape
# `tasks-axi show --full` prints, so every downstream reader in
# `bin/fm-captain-hold.sh` (`verify_hold_durable`, `resolve_entry`,
# `command_answer`, `command_answers`, `command_verify`, `command_diverged`)
# works transparently.
#
# All writes are atomic: `mktemp` sibling file + `mv -f`.
# A closed decision keeps its file so recovery, replay, and legacy-shape
# checks stay lossless; only the `state: done` field flips.
# A retired decision is one whose file is removed (the `retire` operation),
# reserved for post-teardown cleanup after `complete` / `verify` have run.
#
# This lib is sourced by `bin/fm-captain-hold.sh` and covered end-to-end by
# `tests/fm-decision-register-lib.test.sh` plus the register cases in
# `tests/fm-captain-hold-lifecycle.test.sh`.

# Idempotent-source guard: fm-captain-hold.sh sources this beside other libs.
if [ -n "${FM_DECISION_REGISTER_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_DECISION_REGISTER_LIB_SOURCED=1

FM_DECISION_REGISTER_SCHEMA=fm-decision-register.v1

# The register lives under this home's state dir. Resolved lazily so the
# caller (fm-captain-hold.sh) can set STATE from FM_STATE_OVERRIDE first.
fm_decision_register_dir() {
  printf '%s/decisions\n' "${STATE:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"
}

fm_decision_register_path() {  # <id>
  printf '%s/%s.md\n' "$(fm_decision_register_dir)" "$1"
}

# Fail closed on an unsafe path, mirroring the pattern in fm-captain-hold's
# binding_path / read_binding.
fm_decision_register_assert_safe() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
}

fm_decision_register_exists() {  # <id>
  local path
  path=$(fm_decision_register_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ]
}

# Sanitize a field value: strip newlines (they break the tag=value grammar),
# strip non-printable control bytes, cap at 8192 bytes.
fm_decision_register_sanitize_line() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-8192
}

# ISO-8601 UTC timestamp; FM_DECISION_REGISTER_NOW overrides for tests.
fm_decision_register_now() {
  if [ -n "${FM_DECISION_REGISTER_NOW:-}" ]; then
    printf '%s' "$FM_DECISION_REGISTER_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Read one frontmatter field from the register file. Fields are `key: value`
# lines above a lone `---` body separator. Missing field prints empty.
fm_decision_register_field() {  # <id> <field>
  local path field=$2
  path=$(fm_decision_register_path "$1")
  [ -f "$path" ] || return 1
  awk -v k="$field" '
    /^---$/ { if (seen_head) exit; seen_head=1; next }
    seen_head && $0 ~ "^"k": " { sub("^"k": ", ""); print; exit }
  ' "$path"
}

# The body: everything after the second `---` separator.
fm_decision_register_body() {  # <id>
  local path
  path=$(fm_decision_register_path "$1")
  [ -f "$path" ] || return 1
  awk '
    /^---$/ { seen++; next }
    seen >= 2 { print }
  ' "$path"
}

# Write a fresh register entry.
# Idempotent: an exact repeat with identical reason/until/body is a no-op.
# A change to reason or until on an already-open entry rewrites the fields
# but keeps `state`, `created`, and any resolution block in the body.
fm_decision_register_open() {  # <id> <reason> <origin> <until> <title> <repo> <body>
  local id=$1 reason=$2 origin=$3 until=$4 title=$5 repo=$6 body=$7
  local dir path tmp created state prev_reason prev_until prev_body
  dir=$(fm_decision_register_dir)
  path=$(fm_decision_register_path "$id")
  (umask 077; mkdir -p "$dir") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1

  if [ -f "$path" ]; then
    fm_decision_register_assert_safe "$path" || return 1
    state=$(fm_decision_register_field "$id" state)
    [ "$state" != "done" ] || return 2   # closed; re-holding a done register entry is refused
    created=$(fm_decision_register_field "$id" created)
    prev_reason=$(fm_decision_register_field "$id" hold_reason)
    prev_until=$(fm_decision_register_field "$id" hold_until)
    prev_body=$(fm_decision_register_body "$id")
    if [ "$prev_reason" = "$reason" ] && [ "$prev_until" = "$until" ] && [ "$prev_body" = "$body" ]; then
      return 0
    fi
  else
    created=$(fm_decision_register_now)
  fi

  reason=$(fm_decision_register_sanitize_line "$reason")
  origin=$(fm_decision_register_sanitize_line "$origin")
  until=$(fm_decision_register_sanitize_line "$until")
  title=$(fm_decision_register_sanitize_line "$title")
  repo=$(fm_decision_register_sanitize_line "$repo")

  tmp=$(umask 077; mktemp "$dir/.$id.XXXXXX") || return 1
  {
    printf -- '---\n'
    printf 'schema: %s\n' "$FM_DECISION_REGISTER_SCHEMA"
    printf 'id: %s\n' "$id"
    printf 'title: %s\n' "$title"
    printf 'repo: %s\n' "$repo"
    printf 'state: queued\n'
    printf 'hold_kind: captain\n'
    printf 'hold_reason: %s\n' "$reason"
    printf 'hold_until: %s\n' "$until"
    printf 'origin: %s\n' "$origin"
    printf 'created: %s\n' "$created"
    printf -- '---\n'
    printf '%s\n' "$body"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Render the register file into the shape `tasks-axi show --full` prints, so
# fm-captain-hold.sh's show_field / show_field_value read it unchanged.
# Body is JSON-encoded when multi-line (single quoted line with \n escapes),
# to match tasks-axi's own show format that decode_shown_value already handles.
fm_decision_register_show() {  # <id>
  local id=$1 path title state hold_kind hold_reason hold_until body encoded
  path=$(fm_decision_register_path "$id")
  [ -f "$path" ] || return 1
  title=$(fm_decision_register_field "$id" title)
  state=$(fm_decision_register_field "$id" state)
  hold_kind=$(fm_decision_register_field "$id" hold_kind)
  hold_reason=$(fm_decision_register_field "$id" hold_reason)
  hold_until=$(fm_decision_register_field "$id" hold_until)
  body=$(fm_decision_register_body "$id")
  printf '  id: %s\n' "$id"
  printf '  title: %s\n' "$title"
  printf '  state: %s\n' "$state"
  printf '  hold_kind: %s\n' "$hold_kind"
  printf '  hold_reason: %s\n' "${hold_reason:--}"
  printf '  hold_until: %s\n' "${hold_until:--}"
  # Encode the body the same way tasks-axi does: a multi-line body prints as
  # one JSON-quoted line, a single-line body prints raw. That makes
  # decode_shown_value's `case \"*\"` branch fire on multi-line only.
  case "$body" in
    *$'\n'*)
      encoded=$(printf '%s' "$body" | perl -MJSON::PP -e '
        local $/;
        my $t = <STDIN>;
        binmode STDOUT, ":raw";
        print encode_json($t);
      ') || return 1
      printf '  body: %s\n' "$encoded"
      ;;
    '')
      printf '  body: -\n'
      ;;
    *)
      printf '  body: %s\n' "$body"
      ;;
  esac
}

# Write a resolution record onto the body and flip state to done.
# Preserves the previous body (matches tasks-axi update --body-file behavior).
# Mode is answered|released|repaired, exactly what fm-captain-hold.sh already
# writes onto a tasks-axi task body via write_resolution_record.
fm_decision_register_answer() {  # <id> <mode> <decision-text> <decision-digest>
  local id=$1 mode=$2 text=$3 digest=$4
  local path tmp block prev new_body
  path=$(fm_decision_register_path "$id")
  [ -f "$path" ] || return 1
  fm_decision_register_assert_safe "$path" || return 1
  block=$(printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n' \
    "$digest" "$mode" "$text")
  prev=$(fm_decision_register_body "$id")
  if [ -n "$prev" ]; then
    new_body=$(printf '%s\n\n%s' "$block" "$prev")
  else
    new_body=$block
  fi
  # Rewrite in place: same frontmatter with state flipped, then the new body.
  tmp=$(umask 077; mktemp "$(dirname "$path")/.$(basename "$path" .md).XXXXXX") || return 1
  {
    awk '
      /^---$/ { seen++; if (seen == 2) { print; exit } }
      seen == 1 && /^state: / { print "state: done"; next }
      { print }
    ' "$path"
    printf '%s\n' "$new_body"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Release a captain-held register entry: state stays open, hold_kind clears.
# Symmetry with tasks-axi's `unhold` on a captain-held task that gates work -
# though for register entries there is no gated work, so this is rare in
# practice and is provided for parity with the tasks-axi close path.
fm_decision_register_release() {  # <id>
  local id=$1 path tmp
  path=$(fm_decision_register_path "$id")
  [ -f "$path" ] || return 1
  fm_decision_register_assert_safe "$path" || return 1
  tmp=$(umask 077; mktemp "$(dirname "$path")/.$(basename "$path" .md).XXXXXX") || return 1
  awk '
    /^---$/ { seen++ }
    seen == 1 && /^hold_kind: / { print "hold_kind: -"; next }
    { print }
  ' "$path" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Enumerate register ids, one per line. Filter by state (queued|done|all).
fm_decision_register_list() {  # <filter=all|queued|done>
  local dir filter=${1:-all} path id state
  dir=$(fm_decision_register_dir)
  [ -d "$dir" ] || return 0
  for path in "$dir"/*.md; do
    [ -f "$path" ] || continue
    [ ! -L "$path" ] || continue
    id=$(basename "$path" .md)
    case "$id" in .*) continue ;; esac
    if [ "$filter" != all ]; then
      state=$(fm_decision_register_field "$id" state)
      [ "$state" = "$filter" ] || continue
    fi
    printf '%s\n' "$id"
  done
}

# Remove the register file. Reserved for post-teardown cleanup after complete
# and verify have run and the enclosing task is gone.
fm_decision_register_retire() {  # <id>
  local path
  path=$(fm_decision_register_path "$1")
  [ -f "$path" ] || return 0
  rm -f -- "$path" || return 1
  return 0
}
