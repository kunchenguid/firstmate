#!/usr/bin/env bash
# fm-claude-project-memory-lib.sh - the claudeMdExcludes patterns that keep a
# Firstmate home's cloned projects' instruction files out of a Claude session
# rooted at that home. Sourced by bin/fm-spawn.sh for a Claude secondmate's
# --settings file and by tests/fm-claude-project-memory-live.test.sh.
#
# Sourced, never executed. docs/configuration.md "Claude and cloned projects'
# instructions" owns the operator contract and the primary's settings snippet;
# the Claude harness reference owns the vendor facts.
#
# A home keeps its clones in <home>/projects inside the session root, and Claude
# Code loads a clone's CLAUDE.md, its imports, and its .claude/rules as nested
# memory whenever the session reads a file there, although a supervisor never
# changes a project. claudeMdExcludes matches absolute paths with picomatch and
# resolves no relative path, ~, or variable, and a bare **/projects/** would
# also exclude the CLAUDE.md of a home that itself sits under a projects
# directory, so every pattern is anchored to the home's physical projects path.

# fm_claude_project_memory_excludes <home>
#   Prints the compact JSON array of patterns for <home>/projects, resolved to
#   its physical path. Returns 1 and prints nothing when <home> cannot be
#   resolved or its path holds a control character or a character picomatch
#   reads as a pattern, so a caller never writes a pattern that could match
#   other files.
fm_claude_project_memory_excludes() {  # <home>
  local home projects
  home=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  projects="$home/projects"
  case $projects in
  *[[:cntrl:]]* | *[\*\?\[\]\{\}\(\)\\]*) return 1 ;;
  esac
  projects=$(printf '%s' "$projects" | sed 's/"/\\"/g')
  printf '["%s/**/CLAUDE*.md","%s/**/AGENTS.md","%s/**/.claude/rules/**"]\n' \
    "$projects" "$projects" "$projects"
}
