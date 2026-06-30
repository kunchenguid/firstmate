#!/usr/bin/env bash
# Tests for the secondmate-vs-crewmate harness split and the primary->secondmate
# inheritable-config propagation.
#
# Two capabilities are under test:
#   A) Harness split. config/secondmate-harness sets the harness the PRIMARY uses
#      to launch SECONDMATE agents, independent of config/crew-harness (the
#      crewmate harness). fm-harness.sh secondmate resolves the fallback chain
#      config/secondmate-harness -> config/crew-harness -> own; an absent or
#      "default" secondmate-harness behaves exactly as the crew harness did before
#      this knob existed (full backward-compat). fm-spawn.sh resolves a secondmate
#      launch through that mode, durably (every respawn re-resolves), while an
#      explicit per-spawn harness arg still wins.
#   B) Inheritance. The primary pushes a declared, extensible set of LOCAL
#      (gitignored) config items - config/crew-dispatch.json, config/crew-harness,
#      and config/backlog-backend - down into each secondmate home's config/, so
#      the secondmate's OWN crewmates, dispatch profiles, and backlog backend
#      inherit the primary's settings. It is primary-authoritative (re-pushed at
#      secondmate spawn, on the bootstrap secondmate sweep, and by config push).
#      config/secondmate-harness is deliberately NOT inherited (secondmates do
#      not spawn secondmates).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-harness)

# ===========================================================================
# A) fm-harness.sh secondmate resolution + fallback (deterministic detect_own)
# ===========================================================================
# detect_own is pinned to claude via CLAUDECODE=1 so the "fall through to own"
# cases are reproducible. Each row sets crew-harness / secondmate-harness in a
# fresh config dir (a literal '-' means leave the file absent) and asserts BOTH
# the secondmate resolution AND that crew resolution is unchanged (backward-compat).
#   <label>^<crew-harness>^<secondmate-harness>^<expect-secondmate>^<expect-crew>
test_harness_resolution() {
  local label crew sm exp_sm exp_crew case_dir cfg got_sm got_crew n
  n=0
  while IFS='^' read -r label crew sm exp_sm exp_crew; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/harness-$n"
    cfg="$case_dir/config"
    mkdir -p "$cfg"
    [ "$crew" = "-" ] || printf '%s\n' "$crew" > "$cfg/crew-harness"
    [ "$sm" = "-" ] || printf '%s\n' "$sm" > "$cfg/secondmate-harness"
    got_sm=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate)
    got_crew=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" crew)
    [ "$got_sm" = "$exp_sm" ] || fail "$label: secondmate resolved '$got_sm', expected '$exp_sm'"
    [ "$got_crew" = "$exp_crew" ] || fail "$label: crew resolved '$got_crew', expected '$exp_crew'"
  done <<'ROWS'
both absent -> own (backward-compat)^-^-^claude^claude
crew set, secondmate absent -> crew (backward-compat)^codex^-^codex^codex
crew set, secondmate set -> secondmate wins, crew untouched^codex^grok^grok^codex
crew absent, secondmate set -> secondmate value, crew own^-^grok^grok^claude
secondmate=default defers to crew^codex^default^codex^codex
crew=default resolves to own, secondmate follows^default^-^claude^claude
secondmate=default with crew absent -> own^-^default^claude^claude
ROWS
  pass "A1 fm-harness.sh secondmate resolves the fallback chain; crew mode unchanged"
}

# ===========================================================================
# B) propagate_inheritable_config unit behavior
# ===========================================================================
test_propagate_lib() {
  local d src dest m1 m2 outside stdout stderr guard_repo err_text
  d="$TMP_ROOT/prop-lib"
  src="$d/src"
  dest="$d/dest"
  mkdir -p "$src" "$dest"

  # 1. present source is copied
  printf '{"default":{"harness":"codex"}}\n' > "$src/crew-dispatch.json"
  printf 'codex\n' > "$src/crew-harness"
  printf 'manual\n' > "$src/backlog-backend"
  stdout="$d/clean-copy.out"
  stderr="$d/clean-copy.err"
  propagate_inheritable_config "$src" "$dest" >"$stdout" 2>"$stderr" || fail "propagate returned non-zero"
  [ ! -s "$stdout" ] || fail "clean copy wrote to stdout"
  [ ! -s "$stderr" ] || fail "clean copy wrote to stderr"
  [ "$(cat "$dest/crew-dispatch.json")" = '{"default":{"harness":"codex"}}' ] || fail "crew-dispatch.json not propagated"
  [ "$(cat "$dest/crew-harness")" = codex ] || fail "crew-harness not propagated"
  [ "$(cat "$dest/backlog-backend")" = manual ] || fail "backlog-backend not propagated"

  # 2. idempotent: an unchanged re-run does not churn the mtime
  m1=$(date -r "$dest/crew-harness" +%s 2>/dev/null || stat -c %Y "$dest/crew-harness")
  sleep 1
  stdout="$d/unchanged.out"
  stderr="$d/unchanged.err"
  propagate_inheritable_config "$src" "$dest" >"$stdout" 2>"$stderr"
  [ ! -s "$stdout" ] || fail "unchanged propagation wrote to stdout"
  [ ! -s "$stderr" ] || fail "unchanged propagation wrote to stderr"
  m2=$(date -r "$dest/crew-harness" +%s 2>/dev/null || stat -c %Y "$dest/crew-harness")
  [ "$m1" = "$m2" ] || fail "idempotent re-run churned mtime ($m1 -> $m2)"

  # 3. a changed source value converges downstream
  printf '{"default":{"harness":"claude"}}\n' > "$src/crew-dispatch.json"
  printf 'claude\n' > "$src/crew-harness"
  printf 'tasks-axi\n' > "$src/backlog-backend"
  propagate_inheritable_config "$src" "$dest"
  [ "$(cat "$dest/crew-dispatch.json")" = '{"default":{"harness":"claude"}}' ] || fail "changed dispatch profile did not converge"
  [ "$(cat "$dest/crew-harness")" = claude ] || fail "changed value did not converge"
  [ "$(cat "$dest/backlog-backend")" = tasks-axi ] || fail "changed backlog backend did not converge"

  outside="$d/outside-target"
  rm -f "$dest/crew-harness" "$outside"
  printf 'outside\n' > "$outside"
  ln -s "$outside" "$dest/crew-harness"
  printf 'pi\n' > "$src/crew-harness"
  propagate_inheritable_config "$src" "$dest"
  [ ! -L "$dest/crew-harness" ] || fail "destination symlink was not replaced"
  [ "$(cat "$dest/crew-harness")" = pi ] || fail "destination symlink replacement has wrong content"
  [ "$(cat "$outside")" = outside ] || fail "destination symlink target was overwritten"

  # 4. removing the source mirrors absence downstream (primary-authoritative)
  rm -f "$src/crew-dispatch.json" "$src/crew-harness" "$src/backlog-backend"
  propagate_inheritable_config "$src" "$dest"
  [ -e "$dest/crew-dispatch.json" ] && fail "dispatch profile absence not mirrored downstream"
  [ -e "$dest/crew-harness" ] && fail "absence not mirrored downstream"
  [ -e "$dest/backlog-backend" ] && fail "backlog-backend absence not mirrored downstream"

  rm -f "$dest/crew-harness"
  ln -s "$d/missing-target" "$dest/crew-harness"
  propagate_inheritable_config "$src" "$dest"
  [ -L "$dest/crew-harness" ] && fail "broken destination symlink not removed on absence mirror"

  mkdir -p "$dest/crew-harness"
  stderr="$d/remove-error.err"
  if propagate_inheritable_config "$src" "$dest" 2>"$stderr"; then
    fail "failed absence mirror returned success"
  fi
  assert_contains "$(cat "$stderr")" "fm-config-inherit: error: failed to remove crew-harness" \
    "remove error did not emit a stderr diagnostic"
  [ -d "$dest/crew-harness" ] || fail "failed absence mirror removed the wrong path"
  rm -rf "$dest/crew-harness"

  # 5. secondmate-harness is never inherited
  printf 'grok\n' > "$src/secondmate-harness"
  printf '{"default":{"harness":"codex"}}\n' > "$src/crew-dispatch.json"
  printf 'codex\n' > "$src/crew-harness"
  printf 'manual\n' > "$src/backlog-backend"
  rm -rf "$d/dest2"
  mkdir -p "$d/dest2"
  propagate_inheritable_config "$src" "$d/dest2"
  [ -e "$d/dest2/secondmate-harness" ] && fail "secondmate-harness was inherited (must not be)"
  [ "$(cat "$d/dest2/crew-dispatch.json")" = '{"default":{"harness":"codex"}}' ] || fail "crew-dispatch.json not propagated alongside"
  [ "$(cat "$d/dest2/crew-harness")" = codex ] || fail "crew-harness not propagated alongside"
  [ "$(cat "$d/dest2/backlog-backend")" = manual ] || fail "backlog-backend not propagated alongside"

  # 6. nothing to propagate -> destination dir is never created (a true no-op)
  rm -rf "$d/src3" "$d/dest3"
  mkdir -p "$d/src3"
  propagate_inheritable_config "$d/src3" "$d/dest3/config"
  [ -e "$d/dest3/config" ] && fail "empty-source propagation created a destination dir"

  # 7. a git worktree that does not ignore an inherited item gets a visible
  # stderr warning and a skip, not a silent miss.
  guard_repo="$d/guard-repo"
  git init -q -b main "$guard_repo"
  printf 'config/crew-harness\nconfig/backlog-backend\n' > "$guard_repo/.gitignore"
  printf 'guard\n' > "$guard_repo/README.md"
  git -C "$guard_repo" add -A
  git -C "$guard_repo" commit -qm guard
  printf '{"default":{"harness":"grok"}}\n' > "$src/crew-dispatch.json"
  stdout="$d/guard-skip.out"
  stderr="$d/guard-skip.err"
  FM_INHERITABLE_CONFIG=crew-dispatch.json propagate_inheritable_config "$src" "$guard_repo/config" >"$stdout" 2>"$stderr" \
    || fail "guard skip should not make propagation fail"
  [ ! -s "$stdout" ] || fail "guard skip wrote to stdout"
  err_text=$(cat "$stderr")
  assert_contains "$err_text" "fm-config-inherit: warning: skipped crew-dispatch.json" \
    "guard skip did not emit a stderr warning"
  [ ! -e "$guard_repo/config/crew-dispatch.json" ] || fail "guard skip still copied the unignored item"

  pass "B1 propagate_inheritable_config: copy, idempotence, convergence, absence-mirror, exclusion, no-op, skip diagnostics"
}

# ===========================================================================
# B/A integration: a secondmate spawn resolves the secondmate harness and
# propagates the crew harness into the home's config.
# ===========================================================================

# A tmux stub that accepts every subcommand and prints nothing, so no window
# pre-exists and the spawn proceeds to write its meta. Echoes the fakebin dir.
make_noop_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# A minimal seeded secondmate home (validate_firstmate_home_for_spawn needs the
# seed marker, AGENTS.md, bin/, and a charter to launch). config/ is intentionally
# left absent so the spawn's propagation is what creates it.
make_seeded_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

# spawn_secondmate <world> <id> <home> [explicit-harness]
# Runs fm-spawn.sh in secondmate mode. FM_ROOT is the real repo (so fm-harness.sh
# resolves), the primary config dir is <world>/home/config, and CLAUDECODE pins
# detect_own. stderr is discarded (the local-HEAD ff sync harmlessly skips a
# non-worktree home). Inspect <world>/home/state/<id>.meta and <home>/config after.
spawn_secondmate() {
  local world=$1 id=$2 home=$3 harness=${4:-} fakebin
  mkdir -p "$world/home/state" "$world/home/data"
  fakebin=$(make_noop_tmux "$world/tmux-$id")
  # An empty harness must contribute zero args, not an empty positional; build the
  # arg list explicitly so the optional harness is omitted cleanly.
  local spawn_args=("$id" "$home")
  [ -n "$harness" ] && spawn_args+=("$harness")
  spawn_args+=(--secondmate)
  PATH="$fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "${spawn_args[@]}" >/dev/null 2>&1 || true
}

meta_harness() { grep '^harness=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

# Split active: crew-harness=claude + secondmate-harness=codex. The secondmate
# AGENT launches on codex; its own crewmates inherit claude; secondmate-harness
# does not flow into the home.
test_spawn_split_and_inherit() {
  local w sm meta
  w="$TMP_ROOT/spawn-split"
  sm="$w/sm"
  mkdir -p "$w/home/config"
  printf '{"default":{"harness":"claude","model":"haiku","effort":"low"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'claude\n' > "$w/home/config/crew-harness"
  printf 'codex\n' > "$w/home/config/secondmate-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm"

  meta="$w/home/state/sm.meta"
  [ -f "$meta" ] || fail "split: no meta written"
  [ "$(meta_harness "$meta")" = codex ] \
    || fail "split: secondmate launched on '$(meta_harness "$meta")', expected codex"
  [ "$(cat "$sm/config/crew-harness" 2>/dev/null)" = claude ] \
    || fail "split: home crew-harness not inherited as claude (got '$(cat "$sm/config/crew-harness" 2>/dev/null)')"
  [ "$(cat "$sm/config/crew-dispatch.json" 2>/dev/null)" = '{"default":{"harness":"claude","model":"haiku","effort":"low"}}' ] \
    || fail "split: home crew-dispatch.json not inherited"
  [ "$(cat "$sm/config/backlog-backend" 2>/dev/null)" = manual ] \
    || fail "split: home backlog-backend not inherited as manual"
  [ -e "$sm/config/secondmate-harness" ] \
    && fail "split: secondmate-harness leaked into the secondmate home"
  pass "B2 spawn: secondmate runs the secondmate harness; its home inherits declared config"
}

# Backward-compat: secondmate-harness absent -> the secondmate launches on the
# crew harness, exactly as before this knob existed, and that crew value is the
# one inherited.
test_spawn_backward_compat_crew_fallback() {
  local w sm meta
  w="$TMP_ROOT/spawn-compat"
  sm="$w/sm"
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm"

  meta="$w/home/state/sm.meta"
  [ "$(meta_harness "$meta")" = codex ] \
    || fail "compat: secondmate launched on '$(meta_harness "$meta")', expected the crew harness codex"
  [ "$(cat "$sm/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "compat: home crew-harness not inherited as codex"
  pass "B3 spawn: an absent secondmate-harness falls back to the crew harness (backward-compat)"
}

# Bare backward-compat: no config at all. The secondmate falls through to its own
# harness (claude here), and with no inheritable file the home is left untouched -
# no config/ side effects.
test_spawn_bare_backward_compat() {
  local w sm meta
  w="$TMP_ROOT/spawn-bare"
  sm="$w/sm"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm"

  meta="$w/home/state/sm.meta"
  [ "$(meta_harness "$meta")" = claude ] \
    || fail "bare: secondmate launched on '$(meta_harness "$meta")', expected own harness claude"
  [ -e "$sm/config/crew-dispatch.json" ] && fail "bare: an unset primary still created a home crew-dispatch.json"
  [ -e "$sm/config/crew-harness" ] && fail "bare: an unset primary still created a home crew-harness"
  pass "B4 spawn: no config at all -> own harness and no propagation side effects"
}

# An explicit per-spawn harness arg wins over config/secondmate-harness.
test_spawn_explicit_harness_wins() {
  local w sm meta
  w="$TMP_ROOT/spawn-explicit"
  sm="$w/sm"
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm" claude

  meta="$w/home/state/sm.meta"
  [ "$(meta_harness "$meta")" = claude ] \
    || fail "explicit: launched on '$(meta_harness "$meta")', expected explicit claude over config codex"
  pass "B5 spawn: an explicit per-spawn harness arg overrides config/secondmate-harness"
}

# The unverified-adapter guard holds on the resolved secondmate path: an unknown
# config/secondmate-harness aborts the spawn (no meta written) and names the source.
test_spawn_unverified_secondmate_harness_refused() {
  local w sm fakebin err rc
  w="$TMP_ROOT/spawn-unverified"
  sm="$w/sm"
  mkdir -p "$w/home/config" "$w/home/state"
  printf 'bogus\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm
  fakebin=$(make_noop_tmux "$w/tmux")
  err="$w/spawn.err"
  rc=0
  PATH="$fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$sm" --secondmate >/dev/null 2>"$err" || rc=$?

  [ "$rc" -ne 0 ] || fail "unverified: spawn should have failed"
  assert_contains "$(cat "$err")" "no launch template for harness 'bogus'" \
    "unverified: error names the rejected harness"
  assert_contains "$(cat "$err")" "config/secondmate-harness" \
    "unverified: error names the secondmate-harness source"
  [ -e "$w/home/state/sm.meta" ] && fail "unverified: a meta was written despite the abort"
  pass "B6 spawn: an unverified resolved secondmate harness is refused (guard intact)"
}

# ===========================================================================
# B integration: spawn, bootstrap, and config push propagate inheritable config
# and keep it converged on the primary (independent of tracked-file ff status).
# ===========================================================================

# A PRIMARY firstmate repo on main with one commit + a home dir, mirroring the
# real gitignore (config/crew-harness ignored, so a propagated value never dirties
# the secondmate worktree on a later sweep). Echoes the world dir.
new_world() {
  local name=$1 dispatch_ignore=${2:-yes} w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  git init -q -b main "$w/main"
  {
    printf 'projects/\nstate/\ndata/\n.no-mistakes/\n'
    [ "$dispatch_ignore" = no ] || printf 'config/crew-dispatch.json\n'
    printf 'config/crew-harness\nconfig/secondmate-harness\nconfig/backlog-backend\n'
  } > "$w/main/.gitignore"
  printf 'v1\n' > "$w/main/AGENTS.md"
  printf 'r1\n' > "$w/main/README.md"
  mkdir -p "$w/main/bin"
  printf 'echo a\n' > "$w/main/bin/tool.sh"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c1
  printf '%s\n' "$w"
}

# A live secondmate home as a DETACHED worktree of the primary at <commit>, with
# its seed marker and a live kind=secondmate meta.
add_sm_worktree() {
  local w=$1 id=$2 commit=$3
  git -C "$w/main" worktree add -q --detach "$w/$id" "$commit"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
}

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  local w=$1 fakebin
  fakebin=$(make_fake_toolchain "$w")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

run_config_push() {
  local w=$1
  PATH="$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    "$ROOT/bin/fm-config-push.sh"
}

# The sweep pushes the primary's inheritable config into a live home, re-converges
# it when the primary changes it, and mirrors absence when the primary clears it -
# all while never inheriting secondmate-harness.
test_bootstrap_sweep_propagates_and_reconverges() {
  local w c1
  w=$(new_world boot-prop)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"

  # Initial push: primary crew-harness=codex, secondmate-harness=grok (must NOT flow).
  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  printf 'grok\n' > "$w/home/config/secondmate-harness"
  run_bootstrap "$w" >/dev/null
  [ "$(cat "$w/sm/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "sweep: crew-harness not pushed into the live home"
  [ "$(cat "$w/sm/config/crew-dispatch.json" 2>/dev/null)" = '{"default":{"harness":"codex"}}' ] \
    || fail "sweep: crew-dispatch.json not pushed into the live home"
  [ "$(cat "$w/sm/config/backlog-backend" 2>/dev/null)" = manual ] \
    || fail "sweep: backlog-backend not pushed into the live home"
  [ -e "$w/sm/config/secondmate-harness" ] \
    && fail "sweep: secondmate-harness was inherited (must not be)"

  # Re-converge: primary changes inheritable values; the home follows on the next sweep.
  printf '{"default":{"harness":"claude"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'claude\n' > "$w/home/config/crew-harness"
  printf 'tasks-axi\n' > "$w/home/config/backlog-backend"
  run_bootstrap "$w" >/dev/null
  [ "$(cat "$w/sm/config/crew-harness" 2>/dev/null)" = claude ] \
    || fail "sweep: home did not re-converge to the primary's new crew-harness"
  [ "$(cat "$w/sm/config/crew-dispatch.json" 2>/dev/null)" = '{"default":{"harness":"claude"}}' ] \
    || fail "sweep: home did not re-converge to the primary's new crew-dispatch.json"
  [ "$(cat "$w/sm/config/backlog-backend" 2>/dev/null)" = tasks-axi ] \
    || fail "sweep: home did not re-converge to the primary's new backlog-backend"

  # Mirror absence: primary clears inheritable config; the home's copies are removed.
  rm -f "$w/home/config/crew-dispatch.json" "$w/home/config/crew-harness" "$w/home/config/backlog-backend"
  run_bootstrap "$w" >/dev/null
  [ -e "$w/sm/config/crew-dispatch.json" ] \
    && fail "sweep: home crew-dispatch.json not removed after the primary cleared it"
  [ -e "$w/sm/config/crew-harness" ] \
    && fail "sweep: home crew-harness not removed after the primary cleared it"
  [ -e "$w/sm/config/backlog-backend" ] \
    && fail "sweep: home backlog-backend not removed after the primary cleared it"
  pass "B7 bootstrap sweep pushes, re-converges, and mirrors absence; never inherits secondmate-harness"
}

# Convergence is independent of the tracked-files fast-forward: a home already
# current on tracked files still receives a config change.
test_bootstrap_sweep_propagates_when_tracked_current() {
  local w head
  w=$(new_world boot-prop-current)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"   # already on the primary's HEAD (ff is a no-op)

  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  run_bootstrap "$w" >/dev/null
  [ "$(cat "$w/sm/config/crew-dispatch.json" 2>/dev/null)" = '{"default":{"harness":"codex"}}' ] \
    || fail "crew-dispatch.json did not propagate to a tracked-current home"
  [ "$(cat "$w/sm/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "config did not propagate to a tracked-current home"
  [ "$(cat "$w/sm/config/backlog-backend" 2>/dev/null)" = manual ] \
    || fail "backlog-backend did not propagate to a tracked-current home"
  pass "B8 bootstrap sweep propagates config even when the home's tracked files are already current"
}

test_bootstrap_sweep_defers_dispatch_on_stale_unignored_home() {
  local w out status
  w=$(new_world boot-stale-dispatch no)
  add_sm_worktree "$w" sm "$(git -C "$w/main" rev-parse HEAD)"
  printf 'local divergence\n' >> "$w/sm/README.md"
  git -C "$w/sm" add README.md
  git -C "$w/sm" commit -qm local
  printf 'config/crew-dispatch.json\n' >> "$w/main/.gitignore"
  git -C "$w/main" add .gitignore
  git -C "$w/main" commit -qm c2

  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  out=$(run_bootstrap "$w")

  assert_contains "$out" "SECONDMATE_SYNC: secondmate sm: skipped: diverged from" \
    "stale dispatch: expected fast-forward skip"
  [ ! -e "$w/sm/config/crew-dispatch.json" ] \
    || fail "stale dispatch: crew-dispatch.json was copied before the home ignored it"
  [ "$(cat "$w/sm/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "stale dispatch: existing ignored config stopped propagating"
  [ "$(cat "$w/sm/config/backlog-backend" 2>/dev/null)" = manual ] \
    || fail "stale dispatch: backlog backend stopped propagating"
  status=$(git -C "$w/sm" status --porcelain -- config/crew-dispatch.json)
  [ -z "$status" ] || fail "stale dispatch: crew-dispatch.json dirtied the home: $status"
  pass "B9 bootstrap sweep defers new inherited config until the home ignores it"
}

# Backward-compat: with no inheritable config set, the sweep is a no-op for the
# home's config/ - exactly as before this feature - and ordinary sweep behavior
# (fast-forward) is unaffected.
test_bootstrap_sweep_no_inheritance_is_noop() {
  local w c1
  w=$(new_world boot-noop)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"
  # Advance the primary so the sweep has a real fast-forward to perform.
  printf 'v2\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c2
  local head
  head=$(git -C "$w/main" rev-parse HEAD)

  run_bootstrap "$w" >/dev/null

  [ -e "$w/sm/config/crew-dispatch.json" ] && fail "no-inheritance sweep created a home crew-dispatch.json"
  [ -e "$w/sm/config/crew-harness" ] && fail "no-inheritance sweep created a home crew-harness"
  [ -e "$w/sm/config" ] && fail "no-inheritance sweep created a home config/ dir"
  [ "$(git -C "$w/sm" rev-parse HEAD)" = "$head" ] \
    || fail "no-inheritance sweep did not still fast-forward the tracked files"
  pass "B10 bootstrap sweep with no inheritable config is a config no-op and still fast-forwards"
}

test_bootstrap_sweep_surfaces_config_propagation_failure() {
  local w c1 out fail_line
  w=$(new_world boot-prop-fail)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"
  mkdir -p "$w/sm/config/crew-harness"

  out=$(run_bootstrap "$w")

  fail_line=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate sm: skipped: config inheritance failed' || true)
  [ -n "$fail_line" ] || fail "bootstrap did not surface config propagation failure (got: $out)"
  [ -d "$w/sm/config/crew-harness" ] || fail "failed propagation removed the wrong path"
  pass "B11 bootstrap sweep surfaces config propagation failures"
}

test_config_push_propagates_reports_without_ff_or_nudge() {
  local w c1 sm_real old_head out err status out2 tmp
  w=$(new_world config-push-basic)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"
  sm_real=$(cd "$w/sm" && pwd -P)
  printf -- '- sm - config push target (home: %s; scope: config; projects: alpha; added 2026-06-30)\n' "$sm_real" > "$w/home/data/secondmates.md"
  tmp="$w/home/state/sm.meta.tmp"
  grep -v '^home=' "$w/home/state/sm.meta" > "$tmp"
  mv "$tmp" "$w/home/state/sm.meta"

  printf 'v2\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add AGENTS.md
  git -C "$w/main" commit -qm c2
  old_head=$(git -C "$w/sm" rev-parse HEAD)

  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  err="$w/config-push-basic.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 0 "$status" "config push should succeed"
  assert_contains "$out" "config-push: $w/home/config -> live secondmate homes" \
    "config push lacked the header"
  assert_contains "$out" "secondmate sm ($sm_real):" \
    "config push did not discover the live secondmate through registry fallback"
  assert_contains "$out" "crew-dispatch.json: pushed" \
    "config push did not report crew-dispatch as pushed"
  assert_contains "$out" "crew-harness: pushed" \
    "config push did not report crew-harness as pushed"
  assert_contains "$out" "backlog-backend: pushed" \
    "config push did not report backlog-backend as pushed"
  assert_not_contains "$out" "NUDGE_SECONDMATES" \
    "config push must not nudge secondmates"
  [ "$(git -C "$w/sm" rev-parse HEAD)" = "$old_head" ] \
    || fail "config push fast-forwarded tracked files"
  [ ! -s "$err" ] || fail "clean config push wrote unexpected stderr: $(cat "$err")"

  out2=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "idempotent config push should succeed"
  assert_contains "$out2" "crew-dispatch.json: unchanged" \
    "idempotent config push did not report crew-dispatch as unchanged"
  assert_contains "$out2" "crew-harness: unchanged" \
    "idempotent config push did not report crew-harness as unchanged"
  assert_contains "$out2" "backlog-backend: unchanged" \
    "idempotent config push did not report backlog-backend as unchanged"
  pass "B12 config-push propagates via shared live discovery, reports items, and does not fast-forward or nudge"
}

test_config_push_reports_skips_dirty_and_invalid_home() {
  local w head out err status stale_real dirty_real bad_home err_text tmp
  w=$(new_world config-push-warnings)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" dirty "$head"
  add_sm_worktree "$w" stale "$head"
  dirty_real=$(cd "$w/dirty" && pwd -P)
  stale_real=$(cd "$w/stale" && pwd -P)

  printf 'local edit\n' >> "$w/dirty/README.md"
  tmp="$w/stale/.gitignore.tmp"
  grep -v '^config/crew-dispatch.json$' "$w/stale/.gitignore" > "$tmp"
  mv "$tmp" "$w/stale/.gitignore"

  bad_home="$w/not-secondmate"
  mkdir -p "$bad_home"
  {
    printf 'window=firstmate:fm-bad\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$bad_home"
  } > "$w/home/state/bad.meta"

  printf '{"default":{"harness":"codex"}}\n' > "$w/home/config/crew-dispatch.json"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  err="$w/config-push-warnings.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 0 "$status" "warnings-only config push should exit zero"
  assert_contains "$out" "secondmate dirty ($dirty_real):" \
    "config push did not report dirty home"
  assert_contains "$out" "home: dirty working tree - config-only push continuing" \
    "config push did not surface dirty state"
  assert_contains "$out" "secondmate stale ($stale_real):" \
    "config push did not report stale home"
  assert_contains "$out" "crew-dispatch.json: skipped - destination does not allow inherited item" \
    "config push did not report non-allowing item skip"
  assert_contains "$out" "secondmate bad ($bad_home): skipped - unsafe home: not a seeded secondmate home" \
    "config push did not report invalid secondmate home"
  err_text=$(cat "$err")
  assert_contains "$err_text" "fm-config-inherit: warning: skipped crew-dispatch.json" \
    "config push did not inherit the lib's skip stderr warning"
  pass "B13 config-push reports dirty, non-allowing, and invalid homes without failing warnings-only runs"
}

test_config_push_exits_nonzero_on_copy_error() {
  local w head out err status sm_real err_text
  w=$(new_world config-push-error)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  sm_real=$(cd "$w/sm" && pwd -P)
  printf 'codex\n' > "$w/home/config/crew-harness"
  mkdir -p "$w/sm/config/crew-harness"

  err="$w/config-push-error.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 1 "$status" "copy-error config push should exit non-zero"
  assert_contains "$out" "secondmate sm ($sm_real):" \
    "config push error output missed the home"
  assert_contains "$out" "crew-harness: error - failed to copy" \
    "config push did not report the per-item copy error"
  err_text=$(cat "$err")
  assert_contains "$err_text" "fm-config-inherit: error: failed to copy crew-harness" \
    "copy error did not emit a stderr diagnostic"
  pass "B14 config-push exits nonzero on real propagation errors"
}

test_harness_resolution
test_propagate_lib
test_spawn_split_and_inherit
test_spawn_backward_compat_crew_fallback
test_spawn_bare_backward_compat
test_spawn_explicit_harness_wins
test_spawn_unverified_secondmate_harness_refused
test_bootstrap_sweep_propagates_and_reconverges
test_bootstrap_sweep_propagates_when_tracked_current
test_bootstrap_sweep_defers_dispatch_on_stale_unignored_home
test_bootstrap_sweep_no_inheritance_is_noop
test_bootstrap_sweep_surfaces_config_propagation_failure
test_config_push_propagates_reports_without_ff_or_nudge
test_config_push_reports_skips_dirty_and_invalid_home
test_config_push_exits_nonzero_on_copy_error

echo "# all fm-secondmate-harness tests passed"
