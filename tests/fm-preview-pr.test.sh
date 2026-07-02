#!/usr/bin/env bash
# Focused behavior tests for fm-preview-pr.sh pure helpers and owned-process
# cleanup. The full preview path depends on a live GitHub PR and project dev
# server, so this suite pins the safety-sensitive local logic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREVIEW="$ROOT/bin/fm-preview-pr.sh"
TMP_ROOT=$(fm_test_tmproot fm-preview-pr-tests)

# shellcheck source=bin/fm-preview-pr.sh
FM_PREVIEW_PR_LIB_ONLY=1 . "$PREVIEW"

test_project_name_resolves_under_projects() {
  local home project got
  home="$TMP_ROOT/home-project-name"
  project="$home/projects/myAgenticLife"
  mkdir -p "$project"
  PROJECTS="$home/projects"

  got=$(fm_preview_project_path myAgenticLife)

  [ "$got" = "$project" ] || fail "project name did not resolve under PROJECTS"
  pass "project names resolve under PROJECTS"
}

test_project_path_is_accepted() {
  local project got
  project="$TMP_ROOT/path-project"
  mkdir -p "$project"

  got=$(fm_preview_project_path "$project")

  [ "$got" = "$project" ] || fail "project path did not resolve to itself"
  pass "project paths are accepted"
}

test_meta_get_reads_last_value() {
  local meta got
  meta="$TMP_ROOT/meta"
  printf 'frontend_port=5001\nbackend_port=4001\nfrontend_port=5002\n' > "$meta"

  got=$(fm_preview_meta_get "$meta" frontend_port)

  [ "$got" = 5002 ] || fail "meta parser did not return last value"
  pass "meta parser reads the last key value"
}

test_json_field_reads_piped_json() {
  local got
  got=$(printf '{"headRefName":"feature","headRepositoryOwner":{"login":"alice"}}' | fm_preview_json_field headRepositoryOwner.login)

  [ "$got" = alice ] || fail "json field helper did not read piped JSON"
  pass "json field helper reads piped JSON"
}

test_path_hash_distinguishes_same_basename() {
  local one two one_hash two_hash
  one="$TMP_ROOT/projects-a/app"
  two="$TMP_ROOT/projects-b/app"
  mkdir -p "$one" "$two"

  one_hash=$(fm_preview_path_hash "$one")
  two_hash=$(fm_preview_path_hash "$two")

  [ -n "$one_hash" ] || fail "path hash was empty"
  [ "$one_hash" != "$two_hash" ] || fail "same-basename paths produced the same hash"
  pass "path hash distinguishes same-basename project paths"
}

test_pick_port_skips_occupied_port() {
  local port picked server_pid
  port=$(fm_preview_pick_port 19000)
  python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
  server_pid=$!
  sleep 1

  picked=$(fm_preview_pick_port "$port")

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  [ "$picked" != "$port" ] || fail "port picker reused an occupied port"
  pass "port picker skips occupied ports"
}

test_stop_role_kills_matching_recorded_process() {
  local meta pid pgid sig
  meta="$TMP_ROOT/owned.meta"
  setsid sh -c 'sleep 60' &
  pid=$!
  sleep 1
  pgid=$(ps -p "$pid" -o pgid= | awk '{print $1}')
  sig=$(fm_preview_pid_sig "$pid")
  fm_write_meta "$meta" "backend_pid=$pid" "backend_pgid=$pgid" "backend_pgid_isolated=1" "backend_sig=$sig"

  fm_preview_stop_role "$meta" backend
  sleep 1

  ! kill -0 "$pid" 2>/dev/null || fail "owned process was not stopped"
  pass "stop_role kills a matching recorded process"
}

test_stop_role_without_isolated_pgid_kills_pid_only() {
  local meta pid peer_pid pgid sig
  meta="$TMP_ROOT/nonisolated.meta"
  sleep 60 &
  pid=$!
  sleep 60 &
  peer_pid=$!
  sleep 1
  pgid=$(ps -p "$pid" -o pgid= | awk '{print $1}')
  sig=$(fm_preview_pid_sig "$pid")
  fm_write_meta "$meta" "backend_pid=$pid" "backend_pgid=$pgid" "backend_sig=$sig"

  fm_preview_stop_role "$meta" backend
  sleep 1

  ! kill -0 "$pid" 2>/dev/null || fail "non-isolated recorded pid was not stopped"
  kill -0 "$peer_pid" 2>/dev/null || fail "non-isolated process group peer was stopped"
  kill "$peer_pid" 2>/dev/null || true
  wait "$peer_pid" 2>/dev/null || true
  pass "stop_role without isolated pgid kills only the recorded pid"
}

test_cleanup_started_stops_each_started_role() {
  local meta backend_pid frontend_pid backend_pgid frontend_pgid backend_sig frontend_sig
  meta="$TMP_ROOT/cleanup-started.meta"
  setsid sh -c 'sleep 60' &
  backend_pid=$!
  setsid sh -c 'sleep 60' &
  frontend_pid=$!
  sleep 1
  backend_pgid=$(ps -p "$backend_pid" -o pgid= | awk '{print $1}')
  frontend_pgid=$(ps -p "$frontend_pid" -o pgid= | awk '{print $1}')
  backend_sig=$(fm_preview_pid_sig "$backend_pid")
  frontend_sig=$(fm_preview_pid_sig "$frontend_pid")
  fm_write_meta "$meta" \
    "backend_pid=$backend_pid" "backend_pgid=$backend_pgid" "backend_pgid_isolated=1" "backend_sig=$backend_sig" \
    "frontend_pid=$frontend_pid" "frontend_pgid=$frontend_pgid" "frontend_pgid_isolated=1" "frontend_sig=$frontend_sig"

  fm_preview_cleanup_started "$meta" frontend backend
  sleep 1

  ! kill -0 "$backend_pid" 2>/dev/null || fail "backend was not cleaned up"
  ! kill -0 "$frontend_pid" 2>/dev/null || fail "frontend was not cleaned up"
  pass "cleanup_started stops all started preview roles"
}

test_stop_role_skips_signature_mismatch() {
  local meta pid pgid
  meta="$TMP_ROOT/mismatch.meta"
  setsid sh -c 'sleep 60' &
  pid=$!
  sleep 1
  pgid=$(ps -p "$pid" -o pgid= | awk '{print $1}')
  fm_write_meta "$meta" "backend_pid=$pid" "backend_pgid=$pgid" "backend_sig=not the current signature"

  fm_preview_stop_role "$meta" backend 2>"$TMP_ROOT/mismatch.err"

  kill -0 "$pid" 2>/dev/null || fail "signature mismatch process should not be stopped"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_grep 'is no longer the owned preview process' "$TMP_ROOT/mismatch.err" \
    "signature mismatch did not report a skip"
  pass "stop_role skips processes whose signature no longer matches"
}

test_project_name_resolves_under_projects
test_project_path_is_accepted
test_meta_get_reads_last_value
test_json_field_reads_piped_json
test_path_hash_distinguishes_same_basename
test_pick_port_skips_occupied_port
test_stop_role_kills_matching_recorded_process
test_stop_role_without_isolated_pgid_kills_pid_only
test_cleanup_started_stops_each_started_role
test_stop_role_skips_signature_mismatch
