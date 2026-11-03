#!/usr/bin/env bash
# Select only the installed Herdr Codex SessionStart hook for one task session.
#
# Usage:
#   fm-codex-herdr-hooks.sh review <task-cwd>
#   fm-codex-herdr-hooks.sh check <review.json> <task-cwd>
#   fm-codex-herdr-hooks.sh exec <review.json> -- <codex-arguments...>
#
# review prints a candidate opt-in JSON document, never writes settings or trust.
# The operator must inspect the installed script and its /hooks definition in
# Codex, trust that exact hook through Codex if needed, then save the reviewed
# document as config/codex-herdr-hooks.json. Remove that file to disable.
# Its exact fields are mode (herdr-only), codexVersion, hookKey, hookHash,
# integrationPath, and integrationSha256; changed or extra fields are refused.
# check validates the review and uses two read-only, thread-free app-server
# inventories to prove session flag selection. exec repeats check in the actual
# task cwd and execs Codex with those flags, preserving all supplied arguments.
#
# Supported contract: codex-cli 0.164.0, installed Herdr integration v10, Python 3.
# Unknown versions, managed hooks/policy, discovery warnings/errors, unknown or
# duplicate sources, changed reviewed content, and untrusted Herdr are refused.
# Every unrelated discovered key is disabled only with session flags. No trust
# hash is written or passed; CODEX_HOME, global settings and primary launches
# stay intact. Do not edit hook/config/plugin sources while a worker is running:
# selection is a startup inventory, not a policy for future hot-loaded sources.
# No Herdr API or lifecycle command is called here; the official hook owns identity.
# A private Codex process avoids reusing another session's daemon configuration.
set -eu
case "${1:-}" in
  -h|--help) sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
esac
exec python3 "$(dirname "${BASH_SOURCE[0]}")/fm-codex-herdr-hooks.py" "$@"
