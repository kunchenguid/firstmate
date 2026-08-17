# shellcheck shell=bash
# Shared owner of the autonomy-grant vocabulary for the scripts that record a
# task's routine approval authority (bin/fm-spawn.sh, bin/fm-promote.sh).
# Usage: . bin/fm-grants-lib.sh
#
# A task's grants are a canonically ordered comma list drawn from a closed set,
# or "none". They are INDEPENDENT: holding one never implies another.
#   findings      answer no-mistakes ask-user/review findings
#   merge         merge a green PR
#   local-merge   approve a local-only branch for the guarded local merge
#
# bin/fm-project-mode.sh owns the REGISTRY grammar (`+yolo`, `+yolo:<g>[,<g>]`)
# and resolves a project's standing posture. This file owns the same closed set
# where it crosses a task-recording script's command line, so the two consumers
# below cannot drift apart in what they accept or how they order it. Anything
# unrecognised is refused rather than dropped, so a typo can never widen
# authority.

# Canonicalise and validate a grant list. Order-normalising so the value written
# into state/<id>.meta is byte-stable however firstmate spelled it on the command
# line, which keeps a relaunch's recorded posture comparable.
fm_canonical_grants() {  # <list> -> canonical list on stdout, or non-zero
  local raw=$1 one rest g_findings=0 g_merge=0 g_local=0 out=""
  case "$raw" in
    none)
      printf 'none'
      return 0
      ;;
  esac
  rest=$raw
  while [ -n "$rest" ]; do
    one=${rest%%,*}
    if [ "$one" = "$rest" ]; then rest=""; else rest=${rest#*,}; fi
    case "$one" in
      findings) g_findings=1 ;;
      merge) g_merge=1 ;;
      local-merge) g_local=1 ;;
      "") echo "error: --grants has an empty entry in \"$raw\"; use none or a comma list of findings, merge, local-merge" >&2; return 1 ;;
      *) echo "error: unknown autonomy grant \"$one\"; expected findings, merge, or local-merge" >&2; return 1 ;;
    esac
  done
  [ "$g_findings" -eq 0 ] || out="findings"
  [ "$g_merge" -eq 0 ] || out="${out:+$out,}merge"
  [ "$g_local" -eq 0 ] || out="${out:+$out,}local-merge"
  printf '%s' "${out:-none}"
}

# Map the retired --yolo spelling to the grants it used to mean, so a caller or a
# task recorded before the split keeps exactly the authority it had: on granted
# every routine approval, off granted none. This mirrors the registry's own
# `+yolo` compatibility in bin/fm-project-mode.sh, so an in-flight task and its
# project line agree across the upgrade.
fm_grants_from_legacy_yolo() {  # <on|off> -> grants list on stdout, or non-zero
  case "$1" in
    on) printf 'findings,merge,local-merge' ;;
    off) printf 'none' ;;
    *) echo "error: --yolo must be on or off (got \"$1\"); prefer --grants <none|findings[,merge][,local-merge]>" >&2; return 1 ;;
  esac
}
