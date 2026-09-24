#!/usr/bin/env bash
# tests/fm-lavish-board-guard-live-e2e.test.sh - live drift guard for the
# vendor-emitted surface bin/fm-lavish-board-guard.sh resolves boards through.
#
# Why this file exists: the guard turns a board URL - the only handle a status
# log carries - into an artifact file by reading the session inventory that
# bare `lavish-axi` publishes. That header is a surface the vendor changes
# without notice, and a stub can only confirm the assumption already written
# into the stub. Resolving a URL to the WRONG file would make the guard report
# the wrong board, so the parse asserts the four fields it depends on and
# refuses anything else; this proves the installed build still satisfies it.
#
# 0.1.77 appended a `listener` column, which the parse absorbs. That column is
# deliberately NOT used as a verdict, and this guard records why: on 2026-09-22
# it read `none` for a board that had a live `lavish-axi poll` attached, so it
# cannot be trusted to say who is listening. Attendance comes from firstmate's
# own process-event registration instead, which needs no live Lavish server and
# is pinned in tests/fm-lavish-board-guard.test.sh.
#
# OPT-IN ON PURPOSE, and this is the reason. Opening a session is the only way
# to put a row in the listing this guard reads, and `lavish-axi <html-file>`
# raises a real review window on the operator's desktop. The published
# interface exposes no documented way to suppress that - no `--no-open`,
# `--no-browser`, or headless flag appears in `lavish-axi --help` as of 0.1.77,
# and the file-existence check runs before flag parsing, so an undocumented
# flag cannot even be probed without creating the session it would suppress.
# A guard that hijacks a human's screen must not fire on its own, so this one
# runs only when FM_LAVISH_BOARD_LIVE=1 or FM_LIVE=1 asks for it: deliberately,
# after a lavish-axi upgrade, by someone who expects the window. If the vendor
# later publishes a suppression flag, use it and move this back to default-on.
#
# Standard CI has no lavish-axi, so this reports a capability skip there.
#
# Everything it touches is its own: a scratch artifact in a temporary directory
# and the one session it opens, which it ends again on every exit path,
# including failure. It never reads, ends, arms, or polls a session it did not
# create.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_LAVISH_BOARD_LIVE lavish-axi

note() { printf '# %s\n' "$1"; }

LAB=''
cleanup() {
  [ -z "$LAB" ] || {
    [ ! -f "$LAB/board.html" ] \
      || lavish-axi end "$LAB/board.html" >/dev/null 2>&1 || true
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lavish-board-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data" "$LAB/fakebin"
BOARD="$LAB/board.html"
cat > "$BOARD" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Board guard lab</title></head>
<body><h1>Board guard lab</h1><p>Scratch artifact for a live drift guard.</p></body></html>
HTML

# Endpoint liveness is the one thing this guard stubs: it is a tmux fact, not a
# Lavish one, and tests/fm-lavish-board-guard.test.sh already pins it.
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1-}" in display-message) printf '%%1\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$LAB/fakebin/tmux"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  http://*/session/*) ;;
  *) fail "could not open a guard lab session: $url" ;;
esac

# THE SURFACE UNDER GUARD: the published inventory still resolves this URL to
# this file, through the exact command the scan uses.
listing=$("$ROOT/bin/fm-procevent-lavish.sh" sessions) \
  || fail "lavish-axi ${VERSION:-version-unknown} session listing could not be read; bin/fm-procevent-lavish.sh sessions must be revisited"
printf '%s\n' "$listing" | grep -Fq "$(printf 'open\t%s\t%s' "$url" "$BOARD")" \
  || fail "lavish-axi ${VERSION:-version-unknown} no longer resolves $url to $BOARD as an open session; bin/fm-procevent-lavish.sh sessions must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} resolves a live board URL to its artifact file"

# THE BEHAVIOR UNDER GUARD: an open board this home never armed is reported,
# end to end, against the real server.
printf 'window=firstmate:fm-live\nworktree=%s\nproject=alpha\nharness=codex\nkind=scout\n' "$LAB/wt" \
  > "$LAB/state/live.meta"
printf 'needs-decision [key=board-review]: review the board at %s\n' "$url" \
  > "$LAB/state/live.status"

run_scan() {
  PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" \
    FM_LAVISH_BOARD_GRACE_SECS=60 "$ROOT/bin/fm-lavish-board-guard.sh" scan
}

run_scan >/dev/null || fail "the first scan failed against the real server"
FM_LIVE_GUARD_EPOCH=$(( $(date +%s) - 600 ))
export FM_LIVE_GUARD_EPOCH
for record in "$LAB/state/".lavish-board-unarmed-*; do
  [ -f "$record" ] || fail "the first scan recorded no unarmed board"
  perl -i -pe 's/^first_unarmed=.*/first_unarmed=$ENV{FM_LIVE_GUARD_EPOCH}/' "$record"
done
out=$(run_scan) || fail "the grace-expired scan failed"
case "$out" in
  *"url=$url"*"file=$BOARD"*) ;;
  *) fail "an open board this home never armed was not reported: ${out:-<nothing>}" ;;
esac
grep -Fq 'lavish-board-unarmed:live:' "$LAB/state/.wake-queue" \
  || fail "the unarmed board queued no durable wake"
pass "an open board with no registration is reported once against real lavish-axi"

lavish-axi end "$BOARD" >/dev/null 2>&1 || true
echo "all live lavish board guard checks passed"
