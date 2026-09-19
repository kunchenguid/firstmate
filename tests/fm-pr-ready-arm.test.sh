#!/usr/bin/env bash
# Tests for fm-pr-ready-arm.sh: writes the per-task PR-readiness shim, its
# .prs sidecar, and binds the shim's bytes through fm-check-register.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-pr-ready-arm.sh"

new_home() {
  local home="$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_rejects_too_few_args() {
  local home
  home=$(new_home "$TMP_ROOT/too-few")
  if out=$(FM_HOME="$home" "$ARM" only-id 2>&1); then
    fail "arm with no PRs must exit nonzero"
  fi
  case "$out" in
    *usage*) pass "missing PRs prints usage" ;;
    *) fail "expected usage message, got: $out" ;;
  esac
}

test_rejects_invalid_id() {
  local home
  home=$(new_home "$TMP_ROOT/bad-id")
  if out=$(FM_HOME="$home" "$ARM" "../escape" 42 2>&1); then
    fail "arm with a path-unsafe id must exit nonzero"
  fi
  case "$out" in
    *"invalid id"*) pass "path-unsafe id is refused" ;;
    *) fail "expected invalid id message, got: $out" ;;
  esac
}

test_arms_shim_and_sidecar() {
  local home
  home=$(new_home "$TMP_ROOT/armed")
  out=$(FM_HOME="$home" "$ARM" watch1 "acme/widgets#7" "acme/widgets#9" 2>&1) \
    || fail "arm with valid id and PRs must exit zero: $out"

  [ -f "$home/state/watch1.check.sh" ] || fail "shim was not written"
  [ -f "$home/state/watch1.prs" ] || fail "sidecar was not written"
  [ -f "$home/state/watch1.check-trust" ] || fail "check was not registered"

  perm=$(stat -c '%a' "$home/state/watch1.check.sh" 2>/dev/null || stat -f '%Lp' "$home/state/watch1.check.sh")
  if [ "$perm" = 700 ]; then
    pass "shim is mode 700"
  else
    fail "shim mode was $perm, expected 700"
  fi

  content=$(cat "$home/state/watch1.prs")
  case "$content" in
    *"acme/widgets#7"*"acme/widgets#9"*) pass "sidecar lists both PRs" ;;
    *) fail "sidecar missing PRs, got: $content" ;;
  esac

  case "$out" in
    *"armed: state/watch1.check.sh watching: acme/widgets#7 acme/widgets#9"*) pass "arm confirms watched PRs" ;;
    *) fail "expected arm confirmation, got: $out" ;;
  esac
}

test_shim_execs_check_with_sidecar_prs() {
  local home
  home=$(new_home "$TMP_ROOT/exec")
  mkdir -p "$home/bin"
  cat > "$home/bin/fm-pr-ready-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'called-with: %s\n' "$*"
SH
  chmod +x "$home/bin/fm-pr-ready-check.sh"
  FM_HOME="$home" "$ARM" watch2 "acme/widgets#3" >/dev/null 2>&1 \
    || fail "arm setup for shim-exec test failed"
  out=$("$home/state/watch2.check.sh" 2>&1)
  case "$out" in
    *"called-with: acme/widgets#3"*) pass "shim execs fm-pr-ready-check.sh with the sidecar's PRs" ;;
    *) fail "expected shim to forward PRs, got: $out" ;;
  esac
}

# Regression for the state-override-loses-sidecar bug AND the follow-on
# snapshot-loses-FM_HOME bug: when FM_STATE_OVERRIDE points somewhere that is
# NOT one level below FM_HOME (the general case; the watcher's real snapshot
# copy lives inside that same directory too, per
# fm_custom_check_snapshot_prepare), the shim must still find both its own
# sidecar and the real fm-pr-ready-check.sh, never a path re-derived from
# where the shim happens to be running from.
test_state_override_sidecar_resolves() {
  local home altstate
  home=$(new_home "$TMP_ROOT/override")
  altstate="$TMP_ROOT/override-external-state"
  mkdir -p "$home/bin" "$altstate"
  cat > "$home/bin/fm-pr-ready-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'called-with: %s\n' "$*"
SH
  chmod +x "$home/bin/fm-pr-ready-check.sh"
  FM_HOME="$home" FM_STATE_OVERRIDE="$altstate" "$ARM" watch4 "acme/widgets#5" >/dev/null 2>&1 \
    || fail "arm with a state override failed"

  [ -f "$altstate/watch4.check.sh" ] || fail "shim was not written under the state override"
  [ -f "$altstate/watch4.prs" ] || fail "sidecar was not written under the state override"
  [ ! -e "$home/state/watch4.prs" ] || fail "sidecar should not land under FM_HOME/state when overridden"

  # Exercise it as a snapshot would: copied to a temp name inside the same
  # (externally located) state directory, same as
  # fm_custom_check_snapshot_prepare's `mktemp "$state/.fm-custom-check.XXXXXX"`.
  snapshot="$altstate/.fm-custom-check.snaptest"
  cp "$altstate/watch4.check.sh" "$snapshot"
  chmod 700 "$snapshot"
  out=$("$snapshot" 2>&1)
  case "$out" in
    *"called-with: acme/widgets#5"*)
      pass "shim run as an externally-rooted snapshot still finds its sidecar and FM_HOME" ;;
    *) fail "expected shim to forward the overridden sidecar's PRs, got: $out" ;;
  esac
}

# Regression for the unquoted-heredoc-reparse bug: FM_HOME and the sidecar
# path are baked into the generated shim through an unquoted heredoc, so a
# raw interpolation would let a $, backtick, or double quote in either path
# reparse as shell when the shim runs - at minimum breaking the path, at
# worst executing an embedded command substitution. Give FM_HOME a name
# containing those characters and prove both that the shim still runs
# correctly and that nothing it names actually executed. (A literal
# backslash is deliberately left out: GNU sha256sum escapes its output line
# for a hashed path containing one, which trips fm-check-lib.sh's unrelated
# hex-hash format check regardless of this fix - a pre-existing, out-of-scope
# limitation of the shared custom-check hashing, not of this shim.)
test_special_chars_in_paths_do_not_reparse() {
  local home canary1 canary2 special
  # shellcheck disable=SC2016  # single quotes are deliberate: this must stay
  # a literal, unexpanded string to become a filesystem path component.
  special='$(touch CANARY1)`touch CANARY2`"quote"'
  home="$TMP_ROOT/weird_${special}"
  mkdir -p "$home/bin" "$home/state"
  cat > "$home/bin/fm-pr-ready-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'called-with: %s\n' "$*"
SH
  chmod +x "$home/bin/fm-pr-ready-check.sh"
  FM_HOME="$home" "$ARM" watch5 "acme/widgets#8" >/dev/null 2>&1 \
    || fail "arm with a special-character FM_HOME failed"

  out=$("$home/state/watch5.check.sh" 2>&1)
  case "$out" in
    *"called-with: acme/widgets#8"*)
      pass "shim with special characters in FM_HOME still runs and forwards PRs" ;;
    *) fail "expected shim to forward PRs despite special chars, got: $out" ;;
  esac

  canary1="$TMP_ROOT/CANARY1"
  canary2="$TMP_ROOT/CANARY2"
  if [ -e "$canary1" ] || [ -e "$canary2" ] || \
     [ -e "$PWD/CANARY1" ] || [ -e "$PWD/CANARY2" ]; then
    fail "a canary file was created: the shim reparsed an embedded command substitution"
  else
    pass "no embedded command substitution executed while arming or running the shim"
  fi
}

test_rearm_replaces_sidecar() {
  local home
  home=$(new_home "$TMP_ROOT/rearm")
  FM_HOME="$home" "$ARM" watch3 "acme/widgets#1" >/dev/null 2>&1 \
    || fail "first arm failed"
  FM_HOME="$home" "$ARM" watch3 "acme/widgets#2" >/dev/null 2>&1 \
    || fail "re-arm failed"
  content=$(cat "$home/state/watch3.prs")
  case "$content" in
    *"acme/widgets#2"*)
      case "$content" in
        *"acme/widgets#1"*) fail "re-arm should replace the sidecar, still has old PR: $content" ;;
        *) pass "re-arming replaces the sidecar's PR list" ;;
      esac
      ;;
    *) fail "re-armed sidecar missing new PR, got: $content" ;;
  esac
}

TMP_ROOT=$(fm_test_tmproot fm-pr-ready-arm)

test_rejects_too_few_args
test_rejects_invalid_id
test_arms_shim_and_sidecar
test_shim_execs_check_with_sidecar_prs
test_state_override_sidecar_resolves
test_special_chars_in_paths_do_not_reparse
test_rearm_replaces_sidecar
