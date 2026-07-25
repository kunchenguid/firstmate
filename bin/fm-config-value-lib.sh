#!/usr/bin/env bash
# fm-config-value-lib.sh - the single-value config-file reader shared by the
# knobs whose file holds ONE value on ONE line.
#
# A firstmate config knob of this shape is edited by hand, so an editor-added
# leading newline must not silently blank it and a `#` note above the value must
# not become the value. `fm_config_first_value` is that reader: the FIRST
# non-empty, non-comment line, leading/trailing whitespace trimmed. It was
# extracted verbatim from bin/fm-harness.sh's config/secondmate-harness reader,
# which had been copied into bin/fm-spawn.sh for config/crew-config-dir; one
# implementation keeps the two knobs from diverging on a later change (`;`
# comments, BOM handling) and gives that behavior one test surface.
#
# Note this is NOT what config/backend uses: fm_backend_name in bin/fm-backend.sh
# takes the first line that is non-empty after stripping ALL whitespace and has
# no comment case at all, so a `#` line there resolves to a backend name. Do not
# cite it as a precedent for this reader.
#
# No side effects on source. set -u / set -e safe.

# fm_config_first_value <file>: print the first non-empty, non-comment line of
# <file>, trimmed. Prints nothing (exit 0) when the file is absent or holds only
# blank and comment lines, so an absent knob and a value-less knob behave alike.
fm_config_first_value() {
  local file=$1 line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$file"
}
