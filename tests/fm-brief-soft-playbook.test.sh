#!/usr/bin/env bash
# Story fmops-07 §2: bin/fm-brief.sh emits the HARD skeleton and splices the
# SOFT worker playbook from a swappable source - config/worker-playbook.md
# override when present, else docs/worker-playbook.md, with a full-replacement
# override and a loud failure when neither exists.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-soft)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

run_brief() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$BRIEF" "$@"
}

# --- default: docs/worker-playbook.md is spliced ----------------------------

test_default_playbook_spliced_into_scout() {
  local home
  home=$(make_home default-scout)
  run_brief "$home" wp-scout myrepo --scout >/dev/null 2>&1 \
    || fail "scout scaffold failed"
  local brief="$home/data/wp-scout/brief.md"
  grep -qF 'Worker playbook - the delivery spine' "$brief" \
    || fail "default worker playbook was not spliced into the scout brief"
  # HARD skeleton stays present (phase intents + native report path).
  grep -qF '# Definition of done' "$brief" || fail "scout DoD missing"
  # The maintainer HTML-comment preamble must be stripped.
  grep -qF '<!--' "$brief" && fail "the playbook maintainer comment leaked into the brief"
  pass "default docs/worker-playbook.md is spliced into a scout brief, comment stripped"
}

test_default_playbook_spliced_into_ship() {
  local home
  home=$(make_home default-ship)
  run_brief "$home" wp-ship myrepo --mode direct-PR >/dev/null 2>&1 \
    || fail "ship scaffold failed"
  local brief="$home/data/wp-ship/brief.md"
  grep -qF 'Worker playbook - the delivery spine' "$brief" \
    || fail "default worker playbook was not spliced into the ship brief"
  grep -qF 'Delivery contract: mode=direct-PR' "$brief" || fail "ship DoD contract missing"
  pass "default docs/worker-playbook.md is spliced into a ship brief"
}

# --- override: config/worker-playbook.md fully replaces the default ---------

test_override_replaces_default() {
  local home
  home=$(make_home override)
  cat > "$home/config/worker-playbook.md" <<'EOF'
<!-- maintainer note that must be stripped -->
# Custom home playbook
This home uses ONLY ck:* and a single-phase flow.
EOF
  run_brief "$home" wp-ovr myrepo --scout >/dev/null 2>&1 \
    || fail "scaffold with override failed"
  local brief="$home/data/wp-ovr/brief.md"
  grep -qF 'Custom home playbook' "$brief" \
    || fail "override playbook was not spliced"
  grep -qF 'Worker playbook - the delivery spine' "$brief" \
    && fail "the default playbook leaked in alongside the override (not a full replacement)"
  grep -qF 'maintainer note that must be stripped' "$brief" \
    && fail "the override maintainer comment leaked into the brief"
  pass "config/worker-playbook.md fully replaces the default, comment stripped"
}

# --- missing both sources: loud failure -------------------------------------

test_missing_both_fails_loud() {
  local home out rc=0
  home=$(make_home missing)
  # The default playbook resolves from the SCRIPT's own code root (CODE_ROOT =
  # SCRIPT_DIR/..), so to make both sources absent build a throwaway code root:
  # a bin/ that symlinks fm-brief.sh and its sourced libs, and NO docs/ dir.
  local coderoot="$home/coderoot" bin="$home/coderoot/bin" f
  mkdir -p "$bin"
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$bin/$(basename "$f")"
  done
  # config override absent too (fresh $home/config is empty).
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$bin/fm-brief.sh" wp-miss myrepo --scout 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "scaffold succeeded with no playbook source at all"
  case "$out" in
    *"no worker playbook found"*) : ;;
    *) fail "missing-playbook failure was not loud/clear: $out" ;;
  esac
  pass "missing both playbook sources fails loudly before writing a brief"
}

test_default_playbook_spliced_into_scout
test_default_playbook_spliced_into_ship
test_override_replaces_default
test_missing_both_fails_loud
