#!/usr/bin/env bash
# fm-helm-fleetless-probe.sh - print a normalized transcript of what the five
# helm-gated commands do on a machine that belongs to NO fleet.
#
# This exists to make "a single-machine user sees no change" a checkable claim
# instead of a promise. The transcript was captured from the tree BEFORE the
# helm gate was added (tests/fixtures/fm-helm-fleetless-baseline.txt) and
# tests/fm-helm-single-machine.test.sh re-runs this probe and diffs. A helm
# check that leaks one character, one exit code, or one stray file into a
# fleetless home fails that diff.
#
# It drives fm-spawn, fm-send, fm-teardown, fm-pr-merge, and fm-merge-local
# across both directions that matter: refusals (the gate must not change their
# wording or exit code) and one real success (fm-merge-local's fast-forward -
# the gate must not block work on a machine that never opted into a fleet).
#
# Everything volatile is normalized: the temp root becomes <TMP>, the repo root
# <ROOT>, and any absolute home path <HOME>. Nothing else may vary between runs.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-helm-fleetless.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

# A fakebin whose only job is to prove the gate never reaches for the network.
# bifrost is how every cross-machine call leaves this machine; if the helm check
# ever shells out on a fleetless home, this stub records it.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/bifrost" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/bifrost-calls"
exit 0
SH
chmod +x "$FAKEBIN/bifrost"
PATH="$FAKEBIN:$PATH"
export PATH

# Two classes of line are filtered, and neither is what this probe is about:
# bin/fm-guard.sh's supervision banners (they report on the checkout and watcher
# of whoever runs the probe) and the runtime auto-detection notice (it reports
# the terminal the probe happens to run inside). Both would differ between two
# honest runs on two machines. A bash diagnostic's line number is normalized for
# the same reason: editing a script above it would move it without changing any
# behaviour this probe exists to pin down.
run() {  # <label> <command...>
  local label=$1 out rc=0
  shift
  printf '=== %s ===\n' "$label"
  out=$("$@" 2>&1) || rc=$?
  printf '%s\n' "$out" \
    | grep -v '^●' \
    | grep -v '^WARNING: watcher ' \
    | grep -v '^NOTICE: auto-detected ' \
    | sed -e "s|$TMP|<TMP>|g" -e "s|$ROOT|<ROOT>|g" -e "s|$HOME_DIR|<HOME>|g" \
          -e 's/: line [0-9][0-9]*:/: line <N>:/' \
          -e 's/[0-9a-f]\{7,40\}/<sha>/g'
  printf '[exit %s]\n' "$rc"
}

export FM_HOME="$HOME_DIR"
# Pin the session provider so the transcript does not record whichever terminal
# the probe was run from.
export FM_BACKEND=tmux

# --- fixtures ---------------------------------------------------------------
# One local-only ship task with a real project repo, so fm-merge-local has a
# genuine fast-forward to perform rather than only a refusal to print.
PROJ="$HOME_DIR/projects/alpha"
git init -q "$PROJ"
git -C "$PROJ" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m base
git -C "$PROJ" branch -q -M main
git -C "$PROJ" -c user.name=probe -c user.email=probe@example.invalid \
  commit -q --allow-empty -m work
git -C "$PROJ" branch -q fm/t-merge
git -C "$PROJ" reset -q --hard HEAD~1

cat > "$HOME_DIR/state/t-merge.meta" <<EOF
window=firstmate:fm-t-merge
worktree=$TMP/wt-t-merge
project=$PROJ
harness=claude
kind=ship
mode=local-only
yolo=off
EOF

# --- probes -----------------------------------------------------------------
run 'spawn: no arguments' "$ROOT/bin/fm-spawn.sh"
run 'spawn: invalid task id' "$ROOT/bin/fm-spawn.sh" .hidden "$PROJ"
run 'spawn: project that does not exist' "$ROOT/bin/fm-spawn.sh" t-new "$TMP/no-such-project"
run 'send: task with no metadata' "$ROOT/bin/fm-send.sh" t-absent hello
run 'teardown: task with no metadata' "$ROOT/bin/fm-teardown.sh" t-absent
run 'pr-merge: task with no metadata' \
  "$ROOT/bin/fm-pr-merge.sh" t-absent https://github.com/o/r/pull/1
run 'pr-merge: malformed url' "$ROOT/bin/fm-pr-merge.sh" t-merge not-a-url
run 'merge-local: task with no metadata' "$ROOT/bin/fm-merge-local.sh" t-absent
run 'merge-local: real fast-forward' "$ROOT/bin/fm-merge-local.sh" t-merge
printf '=== merge-local: resulting main ===\n'
git -C "$PROJ" log --oneline --format='%s' main

printf '=== bifrost invocations ===\n'
if [ -f "$TMP/bifrost-calls" ]; then
  cat "$TMP/bifrost-calls"
else
  printf '(none)\n'
fi

printf '=== files written under state/ ===\n'
# .guard-watcher-stale-banner is bin/fm-guard.sh's own episode marker, written
# for the same reason its banner was filtered above.
(cd "$HOME_DIR/state" && find . -type f | grep -v '\.guard-watcher-stale-banner' | LC_ALL=C sort)

printf '=== files written under config/ ===\n'
(cd "$HOME_DIR/config" && find . -type f | LC_ALL=C sort)
printf '(end)\n'
