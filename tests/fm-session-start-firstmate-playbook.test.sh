#!/usr/bin/env bash
# Story fmops-07 §2/§7b: bin/fm-session-start.sh loads the firstmate SOFT
# dispatch grammar into the context digest - config/firstmate-playbook.md
# override when present, else docs/firstmate-playbook.md, comment-stripped,
# and after AGENTS.md so it can never relax the HARD contract.
#
# The digest's print_firstmate_playbook helper is defined in-flight in the
# script; exercise it in isolation (running the full session-start needs a
# lock, backend, and network stage this unit test should not drive).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ss-playbook)

# Extract just print_firstmate_playbook (a multi-line function block) and run
# it with a stub subsection() so the label + body reach stdout the same way the
# digest prints them.
extract_helper() {
  awk '
    /^print_firstmate_playbook\(\) \{/ { grab=1 }
    grab { print }
    grab && /^\}$/ { grab=0 }
  ' "$ROOT/bin/fm-session-start.sh"
}

run_helper() {  # <code_root> <config_dir>
  local code_root=$1 config=$2
  CODE_ROOT="$code_root" CONFIG="$config" bash -c "
    subsection() { printf '\n%s\n' \"\$1\"; }
    $(extract_helper)
    print_firstmate_playbook
  "
}

# --- default: docs/firstmate-playbook.md loaded -----------------------------

test_default_playbook_loaded() {
  local config="$TMP_ROOT/default-config"
  mkdir -p "$config"
  local out
  out=$(run_helper "$ROOT" "$config")
  case "$out" in
    *'Firstmate playbook - the orchestrator dispatch grammar'*) : ;;
    *) fail "default docs/firstmate-playbook.md was not loaded: $out" ;;
  esac
  case "$out" in
    *'docs/firstmate-playbook.md'*) : ;;
    *) fail "the digest label did not name the default source" ;;
  esac
  case "$out" in
    *'<!--'*) fail "the playbook maintainer comment leaked into the digest" ;;
  esac
  pass "default docs/firstmate-playbook.md is loaded into the digest, comment stripped"
}

# --- override: config/firstmate-playbook.md fully replaces the default ------

test_override_replaces_default() {
  local config="$TMP_ROOT/override-config"
  mkdir -p "$config"
  cat > "$config/firstmate-playbook.md" <<'EOF'
<!-- maintainer note stripped -->
# Custom home dispatch grammar
This home routes everything through a single reviewer.
EOF
  local out
  out=$(run_helper "$ROOT" "$config")
  case "$out" in
    *'Custom home dispatch grammar'*) : ;;
    *) fail "override firstmate playbook was not loaded" ;;
  esac
  case "$out" in
    *'Firstmate playbook - the orchestrator dispatch grammar'*)
      fail "the default leaked in alongside the override (not a full replacement)" ;;
  esac
  case "$out" in
    *'config/firstmate-playbook.md'*) : ;;
    *) fail "the digest label did not name the override source" ;;
  esac
  case "$out" in
    *'maintainer note stripped'*) fail "the override maintainer comment leaked into the digest" ;;
  esac
  pass "config/firstmate-playbook.md fully replaces the default, comment stripped"
}

# --- absent both: explicit ABSENT marker, never a silent empty --------------

test_absent_both_marks_absent() {
  local fakeroot="$TMP_ROOT/fakeroot" config="$TMP_ROOT/absent-config"
  mkdir -p "$fakeroot/docs" "$config"   # docs exists but no firstmate-playbook.md
  local out
  out=$(run_helper "$fakeroot" "$config")
  case "$out" in
    *ABSENT*) : ;;
    *) fail "absent playbook did not print an explicit ABSENT marker: $out" ;;
  esac
  pass "absent firstmate playbook prints an explicit ABSENT marker"
}

test_default_playbook_loaded
test_override_replaces_default
test_absent_both_marks_absent
