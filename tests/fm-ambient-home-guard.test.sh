#!/usr/bin/env bash
# Regression coverage for the ambient-home poison guard in tests/lib.sh.
#
# Incident: a test fixture invoked a publisher script (the fm-inactive-reconcile.sh
# ledger-first parent delivery covered by tests/fm-inactive-reconcile.test.sh)
# without an explicit FM_HOME override. That script's own fallback,
# `${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}`, resolved FM_HOME to the checkout the
# script physically lives in - the operator's real, live firstmate home when the
# suite runs there, as it normally does. The fixture's fabricated `done: PR
# https://github.com/example/repo/pull/1 ...` child ledger line was then
# delivered for real onto a live secondmate's parent channel
# (bin/fm-parent-channel-lib.sh).
#
# tests/lib.sh now pins FM_HOME to a fresh, empty, per-process directory at
# source time, so that fallback chain resolves there instead of $ROOT whenever a
# fixture forgets its own override. This file proves three things: the pin is
# actually in place, the hazard it closes is real (reproduced against a private
# fixture copy, never against $ROOT or any real home), and a representative slice
# of the real fixture suite never touches a sentinel standing in for a live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-ambient-home-guard)

# --- shared fixture builder --------------------------------------------------
#
# Mirrors tests/fm-inactive-reconcile.test.sh's make_world/bind_secondmate/
# write_child/write_mate_meta shape: a MAIN home with a secondmate MATE bound to
# it, and MATE holding one aged ship child whose ledger already ends in a `done:
# PR ...` line. Scanning MATE delivers that child's ledger line onto MATE's
# parent channel, which is MAIN's state/mate.status - the live secondmate parent
# channel the incident corrupted.

age_file() { # <path>
  local now stamp
  now=$(( $(date +%s) - 120 ))
  if stamp=$(date -r "$now" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$1"
  else
    stamp=$(date -d "@$now" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$1"
  fi
}

fm_dir_fingerprint() { # <dir>
  if command -v shasum >/dev/null 2>&1; then
    ( cd "$1" && find . -type f -exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort )
  else
    ( cd "$1" && find . -type f -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort )
  fi
}

build_sentinel() { # <root>
  local root=$1 main mate fake
  main="$root/main"; mate="$root/mate"; fake="$root/fakebin"
  mkdir -p "$main"/{state,data,config,projects} "$mate"/{state,data,config,projects,bin} "$fake"
  : > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$main
EOF
  fm_write_secondmate_meta "$main/state/mate.meta" "$mate"
  printf 'working: delegated scope\n' > "$main/state/mate.status"
  age_file "$main/state/mate.meta"
  age_file "$main/state/mate.status"

  fm_write_meta "$mate/state/leak-child.meta" \
    "window=firstmate:fm-leak-child" "worktree=$mate/projects/leak-child" "project=alpha" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=s1" 'pr=https://github.com/example/repo/pull/1'
  printf 'done: PR https://github.com/example/repo/pull/1 checks green\n' > "$mate/state/leak-child.status"
  : > "$mate/state/leak-child.turn-ended"
  age_file "$mate/state/leak-child.meta"
  age_file "$mate/state/leak-child.status"
  age_file "$mate/state/leak-child.turn-ended"

  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: done (fake) · source: fake\n'
SH
  local tool
  for tool in gh gh-axi curl tmux; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
exit 97
SH
  done
  chmod +x "$fake"/*
}

# --- the guard is actually in place ------------------------------------------

test_lib_pins_fm_home_away_from_root() {
  [ -n "${FM_HOME:-}" ] || fail "tests/lib.sh must export a non-empty FM_HOME"
  [ "$FM_HOME" != "$ROOT" ] || fail "FM_HOME must never default to the firstmate checkout itself"
  [ -d "$FM_HOME" ] || fail "the pinned FM_HOME must exist: $FM_HOME"
  assert_present "$FM_HOME/.fm-ambient-guard" "the pinned FM_HOME must carry its own marker"
  [ ! -e "$FM_HOME/state" ] || fail "the pinned FM_HOME must seed no state a forgotten call could exploit"
  pass "tests/lib.sh pins FM_HOME to an empty, non-root directory"
}

# --- the hazard is real when the guard is bypassed ---------------------------
#
# Explicitly unsets FM_HOME (undoing tests/lib.sh's pin for this one subshell
# only) and sets FM_ROOT_OVERRIDE to a PRIVATE fixture copy standing in for a
# live home - never $ROOT and never any real operator data - so the reproduction
# proves the mechanism without ever touching a real checkout.

test_bypassing_the_guard_reproduces_the_incident() {
  local root before after
  root="$TMP_ROOT/bypass"
  mkdir -p "$root"
  build_sentinel "$root"
  before=$(fm_dir_fingerprint "$root")

  (
    unset FM_HOME
    PATH="$root/fakebin:$PATH" FM_ROOT_OVERRIDE="$root/mate" FM_INACTIVE_RECONCILE_SECS=60 \
      FM_INACTIVE_CREW_STATE_BIN="$root/fakebin/fm-crew-state.sh" \
      "$RECON" scan >/dev/null 2>&1
  )

  after=$(fm_dir_fingerprint "$root")
  [ "$before" != "$after" ] \
    || fail "reproduction did not change the fixture; the scenario no longer exercises the hazard"
  assert_grep 'child leak-child done' "$root/main/state/mate.status" \
    "the reproduction must show the fabricated PR line landing on the parent channel"
  pass "unsetting FM_HOME reproduces the incident against a private fixture (never against \$ROOT)"
}

# --- the guard closes it ------------------------------------------------------
#
# Same fixture, same missing FM_HOME override on the scan call itself, but this
# time FM_HOME stays exactly what tests/lib.sh pinned it to (nothing unsets it).
# FM_ROOT_OVERRIDE still points at the real code root, while the private
# sentinel remains available to prove that the fixture suite does not write
# outside its isolated home.

test_forgotten_home_lands_in_the_guard_not_the_sentinel() {
  local root before after
  root="$TMP_ROOT/guarded"
  mkdir -p "$root"
  build_sentinel "$root"
  before=$(fm_dir_fingerprint "$root")

  PATH="$root/fakebin:$PATH" FM_ROOT_OVERRIDE="$root/mate" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$root/fakebin/fm-crew-state.sh" \
    "$RECON" scan >/dev/null 2>&1

  after=$(fm_dir_fingerprint "$root")
  [ "$before" = "$after" ] \
    || fail "a forgotten FM_HOME override still reached the sentinel live home"
  assert_no_grep 'leak-child' "$root/main/state/mate.status" \
    "the sentinel parent channel must show no trace of the fabricated child"
  pass "a forgotten FM_HOME override lands in the pinned guard directory, not the sentinel"
}

# --- a representative slice of the real suite never touches a live sentinel --

test_real_fixture_suite_leaves_sentinel_byte_identical() {
  local sentinel before after script rc out
  sentinel="$TMP_ROOT/live-suite-run"
  mkdir -p "$sentinel/state" "$sentinel/data" "$sentinel/config" "$sentinel/projects"
  printf 'operator-real-backlog-marker\n' > "$sentinel/data/backlog.md"
  printf 'working: real captain work, do not touch\n' > "$sentinel/state/real-secondmate.status"
  before=$(fm_dir_fingerprint "$sentinel")

  for script in \
    fm-inactive-reconcile.test.sh \
    fm-pr-merge.test.sh \
    fm-send-strict.test.sh; do
    out=$(FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/tests/$script" 2>&1)
    rc=$?
    [ "$rc" -eq 0 ] || fail "$script failed while the ambient sentinel was present: $out"
    ! printf '%s\n' "$out" | grep -Fq 'not ok' || fail "$script reported a failing case: $out"
  done

  after=$(fm_dir_fingerprint "$sentinel")
  [ "$before" = "$after" ] \
    || fail "the real fixture suite modified the sentinel standing in for a live operator home"
  pass "a representative slice of the real fixture suite leaves an ambient sentinel byte-identical"
}

test_lib_pins_fm_home_away_from_root
test_bypassing_the_guard_reproduces_the_incident
test_forgotten_home_lands_in_the_guard_not_the_sentinel
test_real_fixture_suite_leaves_sentinel_byte_identical
