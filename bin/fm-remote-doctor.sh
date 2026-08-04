#!/usr/bin/env bash
# Report the runtime PATH and tool resolution of a Firstmate remote account.
#
# Usage:
#   bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh
#
# Read-only preflight. Run it through fm-on.sh so the fixed remote entrypoint
# composes and exports the child PATH: this command reports the PATH it inherits
# instead of recomposing it, so the entrypoint stays the single owner of that
# ordering and the two can never drift. Required tools that do not resolve are
# listed and set a non-zero exit status; optional tools are reported either way
# and never fail the check. Nothing on the host is created or modified.
set -eu

REQUIRED_TOOLS=(git)
OPTIONAL_TOOLS=(tmux treehouse no-mistakes tasks-axi herdr claude codex opencode pi grok kimi)

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 0 ] || usage

printf 'path=%s\n' "${PATH:-}"
if [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ "${PATH%%:*}" = "$FM_ROOT_OVERRIDE/bin" ]; then
  printf 'entrypoint=yes\n'
else
  printf 'entrypoint=no\n'
  printf 'note: not launched through the fixed remote entrypoint; the reported PATH is this caller environment.\n' >&2
fi

MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'required %s=%s\n' "$tool" "$resolved"
  else
    printf 'required %s=MISSING\n' "$tool"
    MISSING+=("$tool")
  fi
done
for tool in "${OPTIONAL_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'optional %s=%s\n' "$tool" "$resolved"
  else
    printf 'optional %s=absent\n' "$tool"
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'error: required tools do not resolve on the remote runtime PATH: %s\n' "${MISSING[*]}" >&2
  printf 'fix: install each one where it resolves on the path reported above, or put a wrapper script for it in %s/.local/bin, which is always on that PATH.\n' "${HOME:-~}" >&2
  printf 'fix: tools provided by nvm, asdf, or mise never resolve here because no login or interactive shell runs; see docs/remote-secondmates.md for the wrapper recipe.\n' >&2
  exit 1
fi
printf 'ok: every required tool resolves on the remote runtime PATH\n'
