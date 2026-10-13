#!/usr/bin/env bash
# fm-ask-mai-redacted.sh - privacy-redacting front end for bin/fm-ask-mai.sh.
#
# Enforces the privacy tiers from docs/configuration.md "MAI routing" before a
# prompt leaves the machine for the stage gateway:
#   - rewrites full GitHub PR URLs to #<number>
#   - strips /Users/<x>/Git and ~/Git path prefixes to basenames
#   - strips any path with a /state/ component to its basename
#   - strips remaining absolute home paths (/Users/<x>/...) to basenames
# Refuses (does NOT redact-and-forward) input carrying tier-1/tier-4 material:
#   - lines marked @captain, @private, or @secret
#   - references to data/captain*.md, data/captain-shared.md,
#     data/learnings.md, data/*/brief.md, or .env - their bodies are
#     captain-private or captain-verbatim and must never reach MAI-Pro
# Refusal is fail-closed: exit 2, nothing is sent.
#
# The prompt is the single argument, or stdin when no argument is given.
# All remaining behaviour (fixed model, retries, exit codes) is the shim's.
set -euo pipefail
shim="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-ask-mai.sh"

if [ $# -gt 0 ]; then
  prompt=$1
else
  prompt=$(cat)
fi
[ -n "$prompt" ] || { printf 'fm-ask-mai-redacted: refuse: prompt required (arg or stdin)\n' >&2; exit 2; }

refuse() { printf 'fm-ask-mai-redacted: refuse: %s\n' "$1" >&2; exit 2; }

case "$prompt" in
  *@captain*|*@Captain*|*@CAPTAIN*|*@private*|*@Private*|*@PRIVATE*|*@secret*|*@Secret*|*@SECRET*)
    refuse "@captain/@private/@secret marker present" ;;
esac
printf '%s' "$prompt" | grep -qE 'data/captain[^[:space:]]*\.md|data/learnings\.md|data/[^[:space:]]+/brief\.md|(^|[[:space:]])[^[:space:]]*\.env([[:space:]]|$)' \
  && refuse "private-file reference present (data/captain*, data/learnings, brief, .env)"

redacted=$(printf '%s' "$prompt" | sed -E \
  -e 's#https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/([0-9]+)[^[:space:]]*#\#\1#g' \
  -e 's#(^|[[:space:]])(~/|/Users/[A-Za-z0-9._-]+/)Git/[^[:space:]]*/([^/[:space:]]+)#\1\3#g' \
  -e 's#(^|[[:space:]])[^[:space:]]*/state/([A-Za-z0-9._-]+)#\1\2#g' \
  -e 's#(^|[[:space:]])/Users/[A-Za-z0-9._-]+/[^[:space:]]*/([A-Za-z0-9._-]+)#\1\2#g')
exec "$shim" "$redacted"
