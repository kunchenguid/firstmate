#!/usr/bin/env bash
# tests/fm-secondmate-status.test.sh — unit tests for bin/fm-secondmate-status.sh
#
# These tests build a synthetic firstmate home in $TMP, populate the
# registry + marker + state files in production format, and invoke the
# status script with explicit FM_HOME / FM_DATA_OVERRIDE / etc. overrides
# so no shared state is observed. FM_SECONDMATE_STATUS_FMOD is used to
# stub the fmod binary.
#
# Coverage:
#   - no-arg, no secondmates registered
#   - no-arg, multiple secondmates registered
#   - single-id, found
#   - single-id, not found
#   - home dir missing
#   - marker present / absent
#   - marker id mismatch (safety warning)
#   - in-flight crewmate meta count
#   - orca terminal alive / none
#   - last seen uses data/charter.md mtime when present
set -u

PASS=0
FAIL=0
TESTS_TOTAL=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS="$ROOT/bin/fm-secondmate-status.sh"

TMP_ROOT="$(mktemp -d -t fm-secondmate-status-tests.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Build a synthetic firstmate home. Echoes the home dir on stdout.
fake_home() {
  local case_dir=$1 home
  home="$TMP_ROOT/$case_dir/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/bin"
  printf 'orca\n' > "$home/config/backend"
  printf '%s' "$home" > "$home/.fm-secondmate-home"
  printf '%s' "$home"
}

# Write a registry with the given secondmates. Each arg is:
#   <id>|<summary>|<home>|<scope>|<projects>|<added>
write_registry() {
  local reg=$1
  shift
  cat > "$reg" <<HDR
# Secondmate routing table

One line per secondmate. ABSENT = none registered.
HDR
  local id summary home scope projects added entry
  for entry in "$@"; do
    IFS='|' read -r id summary home scope projects added <<< "$entry"
    printf -- '- %s - %s (home: %s; scope: %s; projects: %s; added %s)\n' \
      "$id" "$summary" "$home" "$scope" "$projects" "$added" >> "$reg"
  done
}

# Build a fake fmod stub that records calls and reports sessions.
make_fmod_stub() {
  local stub_path=$1 sessions=$2
  cat > "$stub_path" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list)
    cat <<JSON
$sessions
JSON
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$stub_path"
}

# Assertions.
assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf 'ok - %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

assert_contains() {
  local label=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) printf 'ok - %s\n' "$label"; PASS=$((PASS + 1)) ;;
    *) printf 'FAIL - %s (missing %q in: %s)\n' "$label" "$needle" "$haystack"; FAIL=$((FAIL + 1)) ;;
  esac
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

assert_not_contains() {
  local label=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) printf 'FAIL - %s (unexpected %q in: %s)\n' "$label" "$needle" "$haystack"; FAIL=$((FAIL + 1)) ;;
    *) printf 'ok - %s\n' "$label"; PASS=$((PASS + 1)) ;;
  esac
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

assert_exit() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf 'ok - %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf 'FAIL - %s (expected exit %s, got %s)\n' "$label" "$expected" "$actual"; FAIL=$((FAIL + 1))
  fi
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

# No-arg, no secondmates registered: should say so and exit 0.
test_no_args_empty_registry() {
  local case_dir=fm-ss-empty
  local home
  home=$(fake_home "$case_dir")
  # Empty registry (just the header)
  cat > "$home/data/secondmates.md" <<HDR
# Secondmate routing table

One line per secondmate. ABSENT = none registered.
HDR
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="/bin/true" "$STATUS" 2>&1)
  ec=$?
  assert_exit "empty no-arg exits 0" 0 "$ec"
  assert_contains "empty no-arg says no secondmates" "no secondmates registered" "$out"
}
test_no_args_empty_registry

# Single secondmate, no-arg: should print a block.
test_no_args_one_secondmate() {
  local case_dir=fm-ss-one
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "alpha" > "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "alpha|alpha summary|$home|alpha scope|falkordb-stak|2026-07-13"
  # Stub fmod to return an empty list.
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" 2>&1)
  ec=$?
  assert_exit "no-arg one secondmate exits 0" 0 "$ec"
  assert_contains "no-arg shows id" "alpha" "$out"
  assert_contains "no-arg shows home" "$home" "$out"
  assert_contains "no-arg shows summary" "alpha summary" "$out"
  assert_contains "no-arg shows scope" "alpha scope" "$out"
  assert_contains "no-arg shows projects" "falkordb-stak" "$out"
  assert_contains "no-arg shows orca none" "orca term:  none" "$out"
}
test_no_args_one_secondmate

# Single-id, found.
test_single_id_found() {
  local case_dir=fm-ss-found
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "beta" > "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "beta|beta summary|$home|beta scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" beta 2>&1)
  ec=$?
  assert_exit "single-id found exits 0" 0 "$ec"
  assert_contains "single-id shows id" "beta" "$out"
  assert_contains "single-id shows home" "$home" "$out"
}
test_single_id_found

# Single-id, not found.
test_single_id_not_found() {
  local case_dir=fm-ss-missing
  local home
  home=$(fake_home "$case_dir")
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "gamma|gamma summary|$home|gamma scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" not-registered 2>&1)
  ec=$?
  assert_exit "single-id not-found exits 1" 1 "$ec"
  assert_contains "single-id not-found says not registered" "not registered" "$out"
}
test_single_id_not_found

# Home dir missing: home (no) shown in output.
test_home_missing() {
  local case_dir=fm-ss-missinghome
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "delta" > "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  # Point the registry at a non-existent home path.
  write_registry "$reg" "delta|delta summary|$TMP_ROOT/$case_dir/does-not-exist|delta scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" delta 2>&1)
  ec=$?
  assert_exit "home missing exits 0" 0 "$ec"
  assert_contains "home missing shows (no)" "(no)" "$out"
}
test_home_missing

# Marker absent: shows "absent" instead of an id.
test_marker_absent() {
  local case_dir=fm-ss-nomarker
  local home
  home=$(fake_home "$case_dir")
  rm -f "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "epsilon|epsilon summary|$home|epsilon scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" epsilon 2>&1)
  ec=$?
  assert_exit "marker absent exits 0" 0 "$ec"
  assert_contains "marker absent shows 'absent'" "marker:     absent" "$out"
}
test_marker_absent

# Marker id mismatch: WARNING line is shown.
test_marker_mismatch() {
  local case_dir=fm-ss-mismatch
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "different-id" > "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "zeta|zeta summary|$home|zeta scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" zeta 2>&1)
  ec=$?
  assert_exit "marker mismatch exits 0" 0 "$ec"
  assert_contains "marker mismatch shows WARNING" "WARNING" "$out"
}
test_marker_mismatch

# In-flight crewmate count: drop meta files in the home's state/.
test_in_flight_count() {
  local case_dir=fm-ss-inflight
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "eta" > "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "eta|eta summary|$home|eta scope|falkordb-stak|2026-07-13"
  # Drop two id-shaped meta files + one arbitrary secondmate-owned task id.
  printf 'backend=orca\n' > "$home/state/eta-scout1.meta"
  printf 'backend=orca\n' > "$home/state/eta-scout2.meta"
  printf 'backend=tmux\n' > "$home/state/unrelated.meta"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" eta 2>&1)
  ec=$?
  assert_exit "in-flight exits 0" 0 "$ec"
  assert_contains "in-flight counts all home state meta" "in-flight:  3 crewmate(s)" "$out"
}
test_in_flight_count

# Orca terminal alive: stub fmod returns a matching session.
test_orca_terminal_alive() {
  local case_dir=fm-ss-orca-alive
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "theta" > "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "theta|theta summary|$home|theta scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  # Compute the canonical id the script will derive from this home's
  # path; the fmod stub returns that exact id so the exact-match path
  # finds it. Mirror fm-secondmate-status.sh's fm_secondmate_status_orca_id
  # formula here so this test can run without sourcing the production
  # script (which would also execute its main dispatch).
  local expected_id real home_hash
  real=$(cd "$home" && pwd -P 2>/dev/null) || real=$home
  home_hash=$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}')
  expected_id="fm-secondmate-theta-$home_hash"
  # make_fmod_stub places the argument inside a JSON heredoc; we need the
  # full array there, so wrap the single session object in `[...]`.
  make_fmod_stub "$fmod_stub" '[{"sessionId":"'"$expected_id"'","cwd":"'"$home"'"}]'
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" theta 2>&1)
  ec=$?
  assert_exit "orca alive exits 0" 0 "$ec"
  assert_contains "orca alive shows terminal" "$expected_id" "$out"
  assert_contains "orca alive shows (alive)" "(alive)" "$out"
}
test_orca_terminal_alive

# Orca terminal none: stub fmod returns empty list.
test_orca_terminal_none() {
  local case_dir=fm-ss-orca-none
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "iota" > "$home/.fm-secondmate-home"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "iota|iota summary|$home|iota scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" iota 2>&1)
  ec=$?
  assert_exit "orca none exits 0" 0 "$ec"
  assert_contains "orca none shows none" "orca term:  none" "$out"
}
test_orca_terminal_none

# Last seen: data/charter.md mtime, when present.
test_last_seen_uses_charter() {
  local case_dir=fm-ss-charter
  local home
  home=$(fake_home "$case_dir")
  printf '%s' "kappa" > "$home/.fm-secondmate-home"
  mkdir -p "$home/data"
  printf 'charter\n' > "$home/data/charter.md"
  local reg="$home/data/secondmates.md"
  write_registry "$reg" "kappa|kappa summary|$home|kappa scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" kappa 2>&1)
  ec=$?
  assert_exit "charter exits 0" 0 "$ec"
  assert_contains "charter shows last seen" "last seen:  2" "$out"
  assert_not_contains "charter does not show unknown" "last seen:  unknown" "$out"
}
test_last_seen_uses_charter

# Two secondmates printed in registry order.
test_no_args_two_secondmates() {
  local case_dir=fm-ss-two
  local home1 home2
  home1=$(fake_home "$case_dir/a")
  home2=$(fake_home "$case_dir/b")
  printf '%s' "first" > "$home1/.fm-secondmate-home"
  printf '%s' "second" > "$home2/.fm-secondmate-home"
  local reg="$TMP_ROOT/$case_dir/home/data/secondmates.md"
  mkdir -p "$(dirname "$reg")"
  write_registry "$reg" \
    "first|first summary|$home1|first scope|falkordb-stak|2026-07-13" \
    "second|second summary|$home2|second scope|falkordb-stak|2026-07-13"
  local fmod_stub="$TMP_ROOT/$case_dir/fmod"
  make_fmod_stub "$fmod_stub" "[]"
  local out ec
  out=$(FM_DATA_OVERRIDE="$(dirname "$reg")" FM_STATE_OVERRIDE="$TMP_ROOT/$case_dir/home/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/$case_dir/home/config" FM_ROOT_OVERRIDE="$TMP_ROOT/$case_dir/home" FM_SECONDMATE_STATUS_FMOD="$fmod_stub" "$STATUS" 2>&1)
  ec=$?
  assert_exit "two secondmates exit 0" 0 "$ec"
  assert_contains "two shows first" "first" "$out"
  assert_contains "two shows second" "second" "$out"
}
test_no_args_two_secondmates

echo
echo "$PASS passed, $FAIL failed ($TESTS_TOTAL total)"
[ "$FAIL" -eq 0 ]
