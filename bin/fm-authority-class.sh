#!/usr/bin/env bash
# Classify a named decision before creating a captain hold.
# Usage: fm-authority-class.sh <class>
# Output: owner=<firstmate|captain> guard=<none|landed-clean-proof|captain-word>
# An unknown class fails closed; absence at older hold call sites is handled by
# fm-captain-hold.sh for backward compatibility. This classifier grants no
# mutation authority: non-forced fm-teardown.sh remains the cleanup proof.
set -eu
case "${1:-}" in
  capacity-reclaim|completed-copy-cleanup)
    [ "$#" -eq 1 ] || exit 2
    printf 'owner=firstmate guard=landed-clean-proof\n' ;;
  sequencing|retry|tie-break|monitor-retirement|worker-routing|model-routing)
    [ "$#" -eq 1 ] || exit 2
    printf 'owner=firstmate guard=none\n' ;;
  generated-file-cleanup)
    [ "$#" -eq 1 ] || exit 2
    printf 'owner=firstmate guard=landed-clean-proof\n' ;;
  engineering)
    [ "$#" -eq 1 ] || exit 2
    printf 'owner=firstmate guard=none\n' ;;
  product|security|destructive|irreversible|credential|merge|empty-commit-discard)
    [ "$#" -eq 1 ] || exit 2
    printf 'owner=captain guard=captain-word\n' ;;
  --help|-h)
    printf 'Usage: fm-authority-class.sh <capacity-reclaim|completed-copy-cleanup|sequencing|retry|tie-break|monitor-retirement|worker-routing|model-routing|generated-file-cleanup|empty-commit-discard|engineering|product|security|destructive|irreversible|credential|merge>\n' ;;
  *) printf 'fm-authority-class: unknown decision class: %s\n' "${1:-<empty>}" >&2; exit 2 ;;
esac
