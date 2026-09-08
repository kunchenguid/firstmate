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
test_rearm_replaces_sidecar
