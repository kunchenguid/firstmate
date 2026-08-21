#!/usr/bin/env bash
# End-to-end proof that a remote secondmate's code root updates from its own
# CONFIGURED UPSTREAM, not a hardcoded "origin" - the exact remote-fleet shape
# behind AGENTS.md task fm-fleet-follows-fork: a remote code root whose "origin"
# is the public upstream template and whose "fork" is the repository the fleet
# actually develops on (fork-only tooling such as bin/fm-dashboard.sh and
# fm-spawn.sh's --card flag exists only on the fork).
#
# bin/fm-remote-secondmate-control.sh update <id> is exactly what
# bin/fm-update.sh's registry backstop dispatches to a remote host through
# fm-on.sh (bin/fm-update.sh: "remote secondmate $id: updated on $HOST ..."):
# it runs bin/fm-update.sh against the code root, then fast-forwards the
# persistent secondmate home to the code root's new HEAD. This test drives
# that same control script directly against a local fixture standing in for
# the remote host - no SSH simulation needed, since the script's own logic is
# host-agnostic - and proves a fork-only file lands in the secondmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-update-follows-fork)

# Build the fixture: an upstream-template bare repo ("origin", never gains the
# fork-only file) and a fork bare repo ("fork", the repo the fleet actually
# develops on). A remote code root clones from fork, keeps "origin" pointing
# at the template, and tracks fork/main as main's configured upstream - the
# shape AGENTS.md task fm-fleet-follows-fork recommends for the remote code
# root. A persistent secondmate home starts at the same shared baseline.
w="$TMP_ROOT/w"
mkdir -p "$w"

git init -q --bare "$w/origin.git"
git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
git init -q --bare "$w/fork.git"
git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main

git init -q "$w/seed"
git -C "$w/seed" checkout -q -b main
printf 'v1\n' > "$w/seed/AGENTS.md"
mkdir -p "$w/seed/bin"
printf 'echo a\n' > "$w/seed/bin/tool.sh"
git -C "$w/seed" add -A
git -C "$w/seed" commit -qm 'shared baseline'
git -C "$w/seed" remote add origin "$w/origin.git"
git -C "$w/seed" remote add fork "$w/fork.git"
git -C "$w/seed" push -q origin main
git -C "$w/seed" push -q fork main

git clone -q "$w/fork.git" "$w/remote-root"
git -C "$w/remote-root" remote rename origin fork
git -C "$w/remote-root" remote add origin "$w/origin.git"
git -C "$w/remote-root" fetch -q origin
git -C "$w/remote-root" branch --quiet --set-upstream-to=fork/main main

git clone -q "$w/fork.git" "$w/remote-home"
printf 'ios\n' > "$w/remote-home/.fm-secondmate-home"
BASELINE_SHA=$(git -C "$w/remote-home" rev-parse HEAD)

# The fork gains a fork-only file (stands in for bin/fm-dashboard.sh /
# fm-spawn.sh --card) that the upstream template never receives - the exact
# divergence AGENTS.md task fm-fleet-follows-fork describes.
git -C "$w/seed" pull -q fork main >/dev/null 2>&1 || true
printf '#!/usr/bin/env bash\necho fork-only\n' > "$w/seed/bin/fm-dashboard.sh"
git -C "$w/seed" add bin/fm-dashboard.sh
git -C "$w/seed" commit -qm 'feat(dashboard): add the fork-only fleet dashboard'
git -C "$w/seed" push -q fork main

test_remote_update_follows_fork_not_origin() {
  local out card_path
  out=$(FM_ROOT_OVERRIDE="$w/remote-root" FM_HOME="$w/remote-home" "$CONTROL" update ios 2>&1) \
    || fail "remote update failed: $out"

  assert_contains "$out" 'synced:' "remote update did not report a host-local fast-forward: $out"

  card_path="$w/remote-home/bin/fm-dashboard.sh"
  assert_present "$card_path" \
    "fork-only dashboard tooling is missing from the remote secondmate home after update"
  assert_grep 'fork-only' "$card_path" \
    "remote home's fm-dashboard.sh does not carry the fork's content"

  [ "$(git -C "$w/remote-root" rev-parse HEAD)" = "$(git -C "$w/fork.git" rev-parse main)" ] \
    || fail "remote code root did not advance to the fork's tip"
  [ "$(git -C "$w/remote-root" rev-parse HEAD)" != "$(git -C "$w/origin.git" rev-parse main)" ] \
    || fail "fixture did not prove origin and fork diverged (origin gained the dashboard file too)"
  [ "$(git -C "$w/remote-home" rev-parse HEAD)" = "$(git -C "$w/remote-root" rev-parse HEAD)" ] \
    || fail "remote secondmate home did not fast-forward to the code root's new HEAD"
  [ "$(git -C "$w/remote-home" rev-parse HEAD)" != "$BASELINE_SHA" ] \
    || fail "remote secondmate home never advanced past the shared baseline"

  pass "a remote code root tracking a fork updates from it, and the fork-only dashboard tooling reaches the secondmate home"
}

test_remote_update_follows_fork_not_origin

echo "# all fm-remote-update-follows-fork tests passed"
