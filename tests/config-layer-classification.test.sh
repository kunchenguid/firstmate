#!/usr/bin/env bash
# Story fmops-07 §4: the config two-layer split must hold as real git behavior
# and stay consistent with AGENTS.md section 2's per-file layer labels.
#
# The oracle for "is this file ignored" is git itself (`git check-ignore`), the
# public interface, run against a throwaway repo seeded with this repo's real
# .gitignore - not a regex over .gitignore bytes. The test then cross-checks
# each config file AGENTS.md labels SHARED/LOCAL-SECRET against git's actual
# verdict, so a drift in either direction fails loudly.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

AGENTS="$ROOT/AGENTS.md"
[ -f "$ROOT/.gitignore" ] || fail "no .gitignore at repo root"
[ -f "$AGENTS" ] || fail "no AGENTS.md at repo root"

TMP_ROOT=$(fm_test_tmproot config-layer)
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/config"
cp "$ROOT/.gitignore" "$REPO/.gitignore"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t ) \
  || fail "could not init the throwaway repo"

# is_ignored <config-relpath> : true when git ignores config/<name> in the
# seeded repo. Uses git check-ignore, the real ignore-resolution interface.
is_ignored() {  # <name>
  local name=$1
  # Create the file so check-ignore has a real path to resolve.
  : > "$REPO/config/$name"
  ( cd "$REPO" && git check-ignore -q "config/$name" )
}

# --- git actually ignores a would-be secret, and tracks a SHARED file -------

test_secret_is_ignored_by_git() {
  is_ignored ".env" || fail "git does not ignore config/.env"
  is_ignored "cmux-socket-password" || fail "git does not ignore config/cmux-socket-password"
  is_ignored "backend" || fail "git does not ignore config/backend (per-machine)"
  is_ignored "crew-harness" || fail "git does not ignore config/crew-harness (per-machine)"
  # A brand-new, never-classified file must be ignored by default (deny-by-default).
  is_ignored "some-future-secret.token" \
    || fail "deny-by-default broken: an unclassified config file is not ignored"
  pass "git ignores secrets, per-machine choices, and unclassified config files by default"
}

test_shared_is_tracked_by_git() {
  local f
  for f in worker-playbook.md firstmate-playbook.md crew-dispatch.json backlog-backend startup-memory-budget; do
    if is_ignored "$f"; then
      fail "git ignores the SHARED config file config/$f (it must be committable)"
    fi
  done
  pass "git tracks every SHARED config file (worker/firstmate playbooks, crew-dispatch, backlog-backend, startup-memory-budget)"
}

# --- AGENTS.md labels agree with git's actual verdict -----------------------

test_agents_labels_match_git() {
  local line name checked
  checked=0
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | sed -E 's|^config/([A-Za-z0-9._-]+).*|\1|')
    [ -n "$name" ] || continue
    case "$line" in
      *"SHARED, committed"*)
        if is_ignored "$name"; then
          fail "AGENTS.md labels config/$name SHARED, committed but git ignores it"
        fi
        checked=$((checked + 1))
        ;;
      *"LOCAL-SECRET, gitignored"*)
        if ! is_ignored "$name"; then
          fail "AGENTS.md labels config/$name LOCAL-SECRET, gitignored but git does not ignore it"
        fi
        checked=$((checked + 1))
        ;;
    esac
  done < <(grep -E '^config/[A-Za-z0-9._-]+' "$AGENTS")
  [ "$checked" -ge 5 ] \
    || fail "cross-check ran on only $checked config files; AGENTS.md layer labels look missing"
  pass "every AGENTS.md config layer label matches git's actual ignore verdict ($checked files)"
}

test_secret_is_ignored_by_git
test_shared_is_tracked_by_git
test_agents_labels_match_git
