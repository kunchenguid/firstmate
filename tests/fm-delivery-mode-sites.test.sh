#!/usr/bin/env bash
# Structural regression tests for the delivery-mode closed-set site registry
# (bin/fm-delivery-mode-sites.json) and its bidirectional drift guard
# (bin/fm-delivery-mode-check.sh).
#
# AGENTS.md section 7's three ship delivery modes, plus the registry-only
# no-mistakes-prod-only policy, are validated independently by six scripts so
# each can refuse an invalid mode without depending on another script having
# run first. That necessary duplication is exactly the drift risk the registry
# exists to police: these tests prove the guard passes on the real repo today,
# then mutate a fixture repo in both directions - a registered site whose code
# no longer matches what is declared, and a new closed-set site the registry
# never learned about - and prove each mutation turns the guard red.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-delivery-mode-check.sh"
REGISTRY="$ROOT/bin/fm-delivery-mode-sites.json"
TMP_ROOT=$(fm_test_tmproot fm-delivery-mode-sites)

run_expect_failure() {  # <expected-substring> <check-args...>
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

# A minimal fixture repo mirroring the shape of the six real sites, small
# enough to mutate cheaply. Each script's case arm is copied verbatim from the
# real file so the fixture stays honest about what the guard actually parses.
write_fixture_repo() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-brief.sh" <<'EOF'
#!/usr/bin/env bash
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) exit 1 ;;
esac
EOF
  cat > "$dir/bin/fm-spawn.sh" <<'EOF'
#!/usr/bin/env bash
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) exit 1 ;;
esac
EOF
  cat > "$dir/bin/fm-promote.sh" <<'EOF'
#!/usr/bin/env bash
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) exit 1 ;;
esac
EOF
  cat > "$dir/bin/fm-project-mode.sh" <<'EOF'
#!/usr/bin/env bash
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) exit 1 ;;
esac
EOF
  cat > "$dir/bin/fm-remote-home-provision.sh" <<'EOF'
#!/usr/bin/env bash
case "$MODE" in no-mistakes|direct-PR) ;; *) exit 1 ;; esac
EOF
  cat > "$dir/bin/fm-remote-home-seed.sh" <<'EOF'
#!/usr/bin/env bash
case "$mode" in
  no-mistakes|direct-PR) ;;
  *) exit 1 ;;
esac
EOF
  cp "$REGISTRY" "$dir/bin/fm-delivery-mode-sites.json"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture
}

test_registry_matches_the_real_repo() {
  local out
  out=$("$CHECK") || fail "the shipped registry does not match the real bin/ scripts"
  assert_contains "$out" "fm-delivery-mode-check: ok sites=" \
    "checker did not report a site count on success"
  pass "fm-delivery-mode-check: the shipped registry matches every real closed-set site"
}

# Direction A: a registered site's own case arm drifts away from what the
# registry declares (the "9 of 11" failure class in data/learnings.md - a
# closed-set guard that quietly stopped covering one of its declared sites).
test_drifted_site_is_caught() {
  local dir="$TMP_ROOT/drifted"
  write_fixture_repo "$dir"
  "$CHECK" --root "$dir" >/dev/null || fail "fixture did not pass before mutation"

  cat > "$dir/bin/fm-promote.sh" <<'EOF'
#!/usr/bin/env bash
case "$MODE" in
  no-mistakes|direct-PR) ;;
  *) exit 1 ;;
esac
EOF
  run_expect_failure "bin/fm-promote.sh: registry declares" "$CHECK" --root "$dir"
  run_expect_failure "actually accepts {direct-PR|no-mistakes}" "$CHECK" --root "$dir"
  pass "fm-delivery-mode-check: a registered site whose code silently narrowed its accepted modes goes red"
}

# Direction B: a new closed-set case arm appears in a file the registry never
# mentions - the mirror image of the same failure class.
test_unregistered_site_is_caught() {
  local dir="$TMP_ROOT/unregistered"
  write_fixture_repo "$dir"
  "$CHECK" --root "$dir" >/dev/null || fail "fixture did not pass before mutation"

  cat > "$dir/bin/fm-new-site.sh" <<'EOF'
#!/usr/bin/env bash
case "$MODE" in
  no-mistakes|direct-PR) ;;
  *) exit 1 ;;
esac
EOF
  git -C "$dir" add bin/fm-new-site.sh
  run_expect_failure "closed-set case arm found in a file the registry does not mention" \
    "$CHECK" --root "$dir"
  run_expect_failure "bin/fm-new-site.sh declares {direct-PR|no-mistakes}" "$CHECK" --root "$dir"
  pass "fm-delivery-mode-check: an unregistered new closed-set site goes red"
}

# A registered site whose file has no closed-set arm at all (not merely a
# narrowed one) must fail the same way, not be silently skipped.
test_site_with_no_matching_arm_is_caught() {
  local dir="$TMP_ROOT/no-arm"
  write_fixture_repo "$dir"
  "$CHECK" --root "$dir" >/dev/null || fail "fixture did not pass before mutation"

  cat > "$dir/bin/fm-remote-home-seed.sh" <<'EOF'
#!/usr/bin/env bash
echo "mode validation removed"
EOF
  run_expect_failure "bin/fm-remote-home-seed.sh: registry declares" "$CHECK" --root "$dir"
  run_expect_failure "no matching case arm exists in the file" "$CHECK" --root "$dir"
  pass "fm-delivery-mode-check: a registered site that lost its case arm entirely goes red"
}

test_registry_schema_failures() {
  local dir="$TMP_ROOT/schema"
  write_fixture_repo "$dir"

  python3 - "$dir/bin/fm-delivery-mode-sites.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text())
data["sites"].append(dict(data["sites"][0]))
p.write_text(json.dumps(data, indent=2) + "\n")
PY
  run_expect_failure "declared as a site more than once" "$CHECK" --root "$dir"

  python3 - "$dir/bin/fm-delivery-mode-sites.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text())
data["sites"][0]["accepts"] = ["not-a-real-mode"]
p.write_text(json.dumps(data, indent=2) + "\n")
PY
  run_expect_failure "accepts an unregistered mode" "$CHECK" --root "$dir"
  pass "fm-delivery-mode-check: a malformed registry fails structurally instead of passing vacuously"
}

test_registry_matches_the_real_repo
test_drifted_site_is_caught
test_unregistered_site_is_caught
test_site_with_no_matching_arm_is_caught
test_registry_schema_failures
echo "# all fm-delivery-mode-sites tests passed"
