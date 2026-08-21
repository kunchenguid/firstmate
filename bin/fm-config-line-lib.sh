#!/usr/bin/env bash
# The single owner of the "first non-empty, non-comment line" config-file
# convention. Sourced by bin/fm-spawn.sh (config/claude-account) and
# bin/fm-harness.sh (config/secondmate-harness). This file is sourced by
# scripts and has no side effects on source.
#
# Why one owner: both files are documented to operators as the same shape - put
# the value on the first line, blank lines are ignored, a leading # marks a
# comment, surrounding whitespace does not matter. Two independent copies of
# that loop drift the moment one of them learns about a new case (CRLF line
# endings, an inline comment, a different comment marker), and the two config
# files would then disagree about a format their documentation says is one
# format. The cut lives here so a fix reaches both callers at once.
#
# An absent file yields no output and SUCCESS, not a failure: for both callers
# "no file" is the ordinary unconfigured case, and the distinction between an
# absent file and an unreadable one is the caller's to make - fm-spawn.sh
# validates the pin file and its directory itself before reading, because for
# an account pin a misread is silent mis-billing rather than a default.

# fm_config_first_line <file>: print the first non-empty, non-comment line of
# <file> with leading and trailing whitespace trimmed. Prints nothing when the
# file is absent, is not a regular file, or holds only blank and comment lines.
fm_config_first_line() {  # <file>
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$1"
  return 0
}
