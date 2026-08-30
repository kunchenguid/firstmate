#!/usr/bin/env bash
# Expect gh-axi in the tool shim log, not bare gh.
grep -q 'gh-axi' "${CALLS_LOG:?}" || exit 1
grep -qE '(^| )gh( |$)' "${CALLS_LOG}" && exit 1 || true
exit 0
