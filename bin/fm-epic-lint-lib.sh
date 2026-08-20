#!/usr/bin/env bash
# fm-epic-lint-lib.sh - shared, side-effect-free helpers for reading epic/story
# frontmatter and the home's project registry.
#
# This is the ONE parser for the epic/story contract. bin/fm-epic-lint.sh is the
# single owner of "is this epic valid" and uses these helpers to read the fields;
# bin/fm-umbrella-promote.sh sources the same helpers for its seed/branch parse so
# there is no second, drifting copy of frontmatter parsing. Every function here is
# pure (reads files/strings, writes nothing) and takes its inputs as arguments so
# it carries no global state. Source it; do not execute it.

# fm_frontmatter_get <file> <key>: value of `key:` inside the leading --- ... ---
# YAML frontmatter, trimmed. Empty (rc 0) when the key is absent OR present with
# an empty value; use fm_frontmatter_has to tell those apart.
fm_frontmatter_get() {
  awk -v key="$2" '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm {
      line=$0
      if (sub("^" key "[[:space:]]*:[[:space:]]*", "", line)) {
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$1"
}

# fm_frontmatter_has <file> <key>: 0 if a `key:` line exists in the frontmatter,
# regardless of whether its value is empty. Distinguishes "missing key" from
# "present but empty" (e.g. `depends:` vs `depends: []`).
fm_frontmatter_has() {
  awk -v key="$2" '
    NR==1 && $0!="---" { exit 1 }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit 1 }
    infm && $0 ~ "^" key "[[:space:]]*:" { exit 0 }
  ' "$1"
}

# fm_frontmatter_keys <file>: print every frontmatter key (one per line), in file
# order. Used to reject ad-hoc keys (story:, phase:, ...) and detect missing ones.
fm_frontmatter_keys() {
  awk '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm && match($0, /^[A-Za-z0-9_-]+[[:space:]]*:/) {
      k=$0; sub(/[[:space:]]*:.*/, "", k); print k
    }
  ' "$1"
}

# fm_heading_of <file>: first `# ` ATX heading text (the `# ` stripped), or empty.
fm_heading_of() {
  awk '/^#[[:space:]]+/ { sub(/^#[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$1"
}

# fm_plan_pointer <file>: the first backtick-quoted token inside the story's
# `## Implementation plan` section (its plan/brief pointer), or empty when there
# is no such section or no pointer in it.
fm_plan_pointer() {
  awk '
    tolower($0) ~ /^##[[:space:]]+implementation plan([[:space:]]|$)/ { inpl=1; next }
    inpl && /^##[[:space:]]/ { exit }
    inpl && match($0, /`[^`]+`/) {
      print substr($0, RSTART+1, RLENGTH-2); exit
    }
  ' "$1"
}

# fm_lower <string>: lowercase, for case-insensitive id comparison.
fm_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# fm_lower_kebab <string>: 0 if the string is lower-kebab (a-z0-9 groups joined by
# single dashes, no leading/trailing/double dash, no uppercase or other chars).
# The character class is enumerated rather than written as a range so it does not
# depend on the locale's collation, under which [a-z] can also match A-Z.
fm_lower_kebab() {
  case "${1-}" in
    '' | -* | *- | *--*) return 1 ;;
    *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_repo_registered <registry-file> <name>: 0 if <registry-file> lists a
# `- <name> ...` project line. A missing registry means nothing is registered
# (fail-closed).
fm_repo_registered() {
  [ -f "$1" ] || return 1
  awk -v n="$2" '$1=="-" && $2==n { found=1; exit } END { exit !found }' "$1"
}
