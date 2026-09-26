#!/usr/bin/env bash
# Self-check for herdr-checklist.sh: fingerprint change detection, file-path
# resolution, renderer selection, and the starter skeleton.
# Run: ./herdr-checklist.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=herdr-checklist.sh disable=SC1091
source "$DIR/herdr-checklist.sh"

fail=0
check() {
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: expected %q got %q\n' "$1" "$3" "$2"
    fail=1
  fi
}

# Renderer: fall back to cat, honor first-found ordering, honor override.
check renderer-fallback "$(pick_renderer definitely-not-real-xyz)" cat
check renderer-first-found "$(pick_renderer sh cat)" sh
check renderer-override "$(HERDR_CHECKLIST_RENDERER=glow pick_renderer nope)" glow

# Fingerprint is content-based: a same-length edit (which whole-second mtime
# would miss) must change it, and a missing file reads "missing".
tmp=$(mktemp)
printf 'AAAA' >"$tmp"; fp1=$(fingerprint "$tmp")
printf 'BBBB' >"$tmp"; fp2=$(fingerprint "$tmp")  # same length, different bytes
if [ "$fp1" != "$fp2" ]; then check fingerprint-content-change changed changed
else check fingerprint-content-change "$fp1==$fp2" changed; fi
rm -f "$tmp"
check fingerprint-missing "$(fingerprint /no/such/file/here)" missing

# Path resolution: env override wins; otherwise state dir, then config dir.
check resolve-env-override "$(HERDR_CHECKLIST_FILE=/x/y.md resolve_file)" /x/y.md
check resolve-state-dir "$(unset HERDR_CHECKLIST_FILE; HERDR_PLUGIN_STATE_DIR=/s resolve_file)" /s/CHECKLIST.md

# Starter carries the owner and all four sections.
out=$(starter Cynthia)
for marker in "CHECKLIST — Cynthia" "🔴 ACT NOW" "🔵 IN FLIGHT" "🟡 WAITING" "🟢 RECENTLY DONE"; do
  case $out in
    *"$marker"*) printf 'ok   starter-has %s\n' "$marker" ;;
    *) printf 'FAIL starter-missing %s\n' "$marker"; fail=1 ;;
  esac
done

poll_tmp=$(mktemp -d)
trap 'rm -rf "$poll_tmp"' EXIT
for failure in copy fingerprint render disappear-before-render disappear-after-render truncate-before-render hangup interrupt terminate; do
  mkdir -p "$poll_tmp/$failure/snapshots"
  printf 'initial\n' >"$poll_tmp/$failure/checklist.md"
  (
    export CHECKLIST_TEST_DIR="$poll_tmp/$failure" CHECKLIST_TEST_FAILURE="$failure"
    export HERDR_CHECKLIST_FILE="$poll_tmp/$failure/checklist.md"
    export HERDR_CHECKLIST_RENDERER=checklist_test_renderer
    export TMPDIR="$CHECKLIST_TEST_DIR/snapshots"
    cp() {
      if [ "$CHECKLIST_TEST_FAILURE" = copy ] && [ ! -f "$CHECKLIST_TEST_DIR/failed" ]; then
        touch "$CHECKLIST_TEST_DIR/failed"
        printf 'partial\n' >"$2"
        return 1
      fi
      command cp "$@"
    }
    cksum() {
      if [ "$CHECKLIST_TEST_FAILURE" = fingerprint ] && [ ! -f "$CHECKLIST_TEST_DIR/failed" ]; then
        touch "$CHECKLIST_TEST_DIR/failed"
        return 1
      fi
      command cksum "$@" || return
      if [ "$CHECKLIST_TEST_FAILURE" = disappear-before-render ] && [ ! -f "$CHECKLIST_TEST_DIR/failed" ]; then
        touch "$CHECKLIST_TEST_DIR/failed"
        mv "$HERDR_CHECKLIST_FILE" "$CHECKLIST_TEST_DIR/moved"
      fi
      if [ "$CHECKLIST_TEST_FAILURE" = truncate-before-render ] && [ ! -f "$CHECKLIST_TEST_DIR/failed" ]; then
        touch "$CHECKLIST_TEST_DIR/failed"
        command cp "$HERDR_CHECKLIST_FILE" "$CHECKLIST_TEST_DIR/moved"
        : >"$HERDR_CHECKLIST_FILE"
      fi
    }
    checklist_test_renderer() {
      if [ "$CHECKLIST_TEST_FAILURE" = render ] && [ ! -f "$CHECKLIST_TEST_DIR/failed" ]; then
        touch "$CHECKLIST_TEST_DIR/failed"
        return 1
      fi
      command cat "$@" >>"$CHECKLIST_TEST_DIR/rendered"
    }
    sleep() {
      checklist_test_polls=$((${checklist_test_polls:-0} + 1))
      if [ -f "$CHECKLIST_TEST_DIR/moved" ]; then
        mv "$CHECKLIST_TEST_DIR/moved" "$HERDR_CHECKLIST_FILE"
      fi
      case $checklist_test_polls in
        1)
          if [ "$CHECKLIST_TEST_FAILURE" = disappear-after-render ]; then
            command cp "$CHECKLIST_TEST_DIR/output" "$CHECKLIST_TEST_DIR/frame"
            mv "$HERDR_CHECKLIST_FILE" "$CHECKLIST_TEST_DIR/moved"
          fi
          ;;
        2)
          if [ "$CHECKLIST_TEST_FAILURE" = disappear-after-render ]; then
            cmp -s "$CHECKLIST_TEST_DIR/frame" "$CHECKLIST_TEST_DIR/output" || return 78
          fi
          ;;
        3) printf 'updated\n' >"$HERDR_CHECKLIST_FILE" ;;
        4)
          case $CHECKLIST_TEST_FAILURE in
            hangup) kill -HUP "$$" ;;
            interrupt) kill -INT "$$" ;;
            terminate) kill -TERM "$$" ;;
            *) return 77 ;;
          esac
          ;;
      esac
    }
    export -f cp cksum checklist_test_renderer sleep
    bash "$DIR/herdr-checklist.sh" view
  ) >"$poll_tmp/$failure/output" 2>&1
  view_status=$?
  expected_status=77
  case $failure in
    hangup) expected_status=129 ;;
    interrupt) expected_status=130 ;;
    terminate) expected_status=143 ;;
  esac
  check "view-$failure-keeps-polling" "$view_status" "$expected_status"
  check "view-$failure-retries-and-refreshes" "$(cat "$poll_tmp/$failure/rendered" 2>/dev/null)" $'initial\nupdated'
  check "view-$failure-snapshot-cleaned" "$(ls -A "$poll_tmp/$failure/snapshots")" ""
done

exit "$fail"
