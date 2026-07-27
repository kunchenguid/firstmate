#!/usr/bin/env bash
# Behavior tests for the live fleet dashboard (wave 1: D1 lifecycle, D2 snapshot
# API, D4 shell presence). Covers start/stop/status, supervisor restart after
# kill, stop/status without a Rust toolchain, FM_HOME shape refusal, bind safety
# (no 0.0.0.0 and no IPv4-mapped wildcard; honors override), bearer auth,
# malformed unlock bodies, open /healthz, and snapshot JSON shape + stable keys.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)
# Unique high ports per case to avoid collisions under parallel-ish local runs.
PORT_BASE=$((18000 + ($$ % 1000)))
PORT_SEQ=0

next_port() {
  PORT_SEQ=$((PORT_SEQ + 1))
  printf '%s\n' "$((PORT_BASE + PORT_SEQ))"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  # firstmate-shaped marker, with one captain-actionable hold so the decision
  # half of the stable-key contract is actually exercised.
  {
    printf '# backlog\n\n## In flight\n\n## Queued\n\n'
    printf -- '- [ ] demo-decision - Choose the demo route (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)\n'
    printf '\n## Done\n'
  } >"$home/data/backlog.md"
  printf '# Firstmate fixture\n' >"$home/AGENTS.md"
  printf '%s\n' "$home"
}

cleanup_dash() {
  local home=$1
  FM_HOME="$home" "$DASH" stop >/dev/null 2>&1 || true
}

# Always stop any dashboard left under the temp root on exit.
_fm_dashboard_exit() {
  local h
  for h in "$TMP_ROOT"/*; do
    [ -d "$h/state" ] || continue
    FM_HOME="$h" "$DASH" stop >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap _fm_dashboard_exit EXIT

wait_http() {  # <url> <seconds>
  local url=$1 seconds=${2:-5} i
  i=0
  while [ "$i" -lt $((seconds * 10)) ]; do
    if curl -sS -o /dev/null --connect-timeout 0.2 --max-time 1 "$url" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

http_code() {  # <url> [extra curl args...]
  local url=$1
  shift
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 5 "$@" "$url"
}

http_body() {  # <url> [extra curl args...]
  local url=$1
  shift
  curl -sS --connect-timeout 1 --max-time 15 "$@" "$url"
}

# --- FM_HOME validation ----------------------------------------------------

test_refuses_missing_home_shape() {
  local bad out status
  bad=$TMP_ROOT/not-a-home
  mkdir -p "$bad"
  out=$(FM_HOME="$bad" "$DASH" start 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "start should refuse a non-shaped home"
  assert_contains "$out" "not firstmate-shaped" "missing shape diagnostic"
  pass "start refuses a non-firstmate-shaped FM_HOME"
}

test_refuses_unset_home_when_root_not_home() {
  # When FM_HOME is unset, resolve_home falls back to FM_ROOT. Override root to
  # an empty dir so the script refuses rather than using the real repo.
  local empty out status
  empty=$TMP_ROOT/empty-root
  mkdir -p "$empty/bin"
  # Point FM_ROOT_OVERRIDE at empty so default home is not the real repo.
  # The script still needs its own bin path - invoke via absolute DASH which
  # embeds SCRIPT_DIR from its real location; FM_ROOT_OVERRIDE only changes
  # the default home / snapshot path. For this test we set FM_HOME to empty.
  out=$(FM_HOME="$empty" "$DASH" status 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "status should refuse empty home"
  assert_contains "$out" "not firstmate-shaped" "empty home diagnostic"
  pass "commands refuse FM_HOME without state/data markers"
}

# --- bind safety -----------------------------------------------------------

test_refuses_wildcard_bind() {
  local home out status port
  home=$(make_home bind-wild)
  port=$(next_port)
  printf '0.0.0.0:%s\n' "$port" >"$home/config/dashboard-bind"
  out=$(FM_HOME="$home" "$DASH" start 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "start should refuse 0.0.0.0"
  assert_contains "$out" "wildcard" "wildcard refuse message" || assert_contains "$out" "0.0.0.0" "wildcard refuse message"
  cleanup_dash "$home"
  pass "start refuses 0.0.0.0 bind"
}

test_refuses_ipv6_any_bind() {
  local home out status
  home=$(make_home bind-v6)
  printf '::\n' >"$home/config/dashboard-bind"
  out=$(FM_HOME="$home" "$DASH" start 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "start should refuse ::"
  assert_contains "$out" "wildcard" "ipv6 any refuse message"
  cleanup_dash "$home"
  pass "start refuses :: bind"
}

# An IPv4-mapped unspecified address is an INADDR_ANY bind on a dual-stack host,
# so it must be refused as hard as a bare 0.0.0.0.
test_refuses_ipv4_mapped_wildcard_bind() {
  local home out status port addr
  home=$(make_home bind-mapped)
  port=$(next_port)
  for addr in "[::ffff:0.0.0.0]:$port" "[0:0:0:0:0:ffff:0:0]:$port" "[::ffff:0:0]:$port"; do
    printf '%s\n' "$addr" >"$home/config/dashboard-bind"
    out=$(FM_HOME="$home" "$DASH" start 2>&1) && status=0 || status=$?
    [ "$status" -ne 0 ] || fail "start should refuse IPv4-mapped wildcard $addr"
    assert_contains "$out" "wildcard" "IPv4-mapped wildcard refuse message for $addr"
    cleanup_dash "$home"
  done
  pass "start refuses IPv4-mapped wildcard binds"
}

test_honors_bind_override() {
  local home port out status code token body
  home=$(make_home bind-ok)
  port=$(next_port)
  printf '127.0.0.1:%s\n' "$port" >"$home/config/dashboard-bind"
  out=$(FM_HOME="$home" "$DASH" start 2>&1) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "start failed: $out"
  assert_contains "$out" "127.0.0.1:$port" "status bind line"
  wait_http "http://127.0.0.1:$port/healthz" 5 || fail "server did not become ready: $out"
  code=$(http_code "http://127.0.0.1:$port/healthz")
  [ "$code" = "200" ] || fail "healthz expected 200 got $code"
  body=$(http_body "http://127.0.0.1:$port/healthz")
  assert_contains "$body" '"ok":true' "healthz body ok"
  assert_contains "$body" 'uptime_s' "healthz uptime"
  # Must not leak fleet data on healthz.
  assert_not_contains "$body" 'tasks' "healthz must not include tasks"
  assert_not_contains "$body" 'backlog' "healthz must not include backlog"
  token=$(tr -d '[:space:]' <"$home/config/dashboard-token")
  [ -n "$token" ] || fail "token was not created"
  [ "$(stat -c '%a' "$home/config/dashboard-token" 2>/dev/null || stat -f '%OLp' "$home/config/dashboard-token")" = "600" ] ||
    fail "token mode is not 600"
  cleanup_dash "$home"
  pass "honors config/dashboard-bind and serves /healthz without auth"
}

# --- auth ------------------------------------------------------------------

test_auth_and_snapshot_shape() {
  local home port token code body
  home=$(make_home auth)
  port=$(next_port)
  printf '127.0.0.1:%s\n' "$port" >"$home/config/dashboard-bind"
  # Seed a live task so the snapshot has structure.
  fm_write_meta "$home/state/ship-a.meta" \
    "kind=ship" "harness=claude" "backend=tmux" "project=firstmate" "window=fm-ship-a"
  printf 'working: building\n' >"$home/state/ship-a.status"
  mkdir -p "$home/data/scout-z"
  printf '# Scout report\n\nfindings\n' >"$home/data/scout-z/report.md"

  FM_HOME="$home" "$DASH" start >/dev/null || fail "start failed"
  wait_http "http://127.0.0.1:$port/healthz" 5 || fail "not ready"
  token=$(tr -d '[:space:]' <"$home/config/dashboard-token")

  code=$(http_code "http://127.0.0.1:$port/")
  [ "$code" = "401" ] || fail "unauthenticated / expected 401 got $code"

  code=$(http_code "http://127.0.0.1:$port/api/v1/snapshot")
  [ "$code" = "401" ] || fail "unauthenticated snapshot expected 401 got $code"

  code=$(http_code "http://127.0.0.1:$port/" -H "Authorization: Bearer $token")
  [ "$code" = "200" ] || fail "authenticated / expected 200 got $code"

  body=$(http_body "http://127.0.0.1:$port/api/v1/snapshot" -H "Authorization: Bearer $token")
  assert_contains "$body" '"schema":"fm-dashboard-snapshot.v1"' "snapshot schema"
  assert_contains "$body" '"generated"' "snapshot generated"
  assert_contains "$body" '"sources"' "snapshot sources"
  assert_contains "$body" '"fleet"' "snapshot fleet"
  assert_contains "$body" '"decisions"' "snapshot decisions"
  assert_contains "$body" '"sections"' "snapshot section anchors"
  # fleet payload should include tasks or composed fallback
  python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
assert d.get("schema")=="fm-dashboard-snapshot.v1"
assert "generated" in d
assert isinstance(d.get("sources"), list) and d["sources"]
assert isinstance(d.get("fleet"), dict)
assert "tasks" in d["fleet"] or d["fleet"].get("schema")=="fm-fleet-snapshot.v1"
assert isinstance(d.get("decisions"), list)
assert isinstance(d.get("sections"), list) and d["sections"]
assert all(s.get("key","").startswith("section:") for s in d["sections"])
# tasks carry stable keys when present
for t in (d.get("fleet") or {}).get("tasks") or []:
    assert t.get("key","").startswith("task:"), t
# the seeded captain hold must reach the board whenever the backlog was parsed
primary = next((s for s in d["sources"] if s.get("id") == "fleet-snapshot"), None)
if primary and primary.get("ok"):
    assert d["decisions"], "seeded captain hold produced no decision"
    assert any(dec.get("hold_id") == "demo-decision" for dec in d["decisions"]), d["decisions"]
# decisions carry board key + hold_id
for dec in d.get("decisions") or []:
    assert dec.get("key","").startswith("decision:"), dec
    assert dec.get("key") == "decision:" + dec.get("hold_id",""), dec
# side sources deferred honestly
ids={s.get("id") for s in d["sources"]}
assert "quota" in ids or any(s.get("deferred") for s in d["sources"])
' <<<"$body" || fail "snapshot JSON shape validation failed: $body"

  # healthz still open
  code=$(http_code "http://127.0.0.1:$port/healthz")
  [ "$code" = "200" ] || fail "healthz should stay open, got $code"

  cleanup_dash "$home"
  pass "auth 401/200 and snapshot shape"
}

# --- lifecycle + restart ---------------------------------------------------

test_lifecycle_start_stop_status_restart() {
  local home port out status server_pid new_pid i code
  home=$(make_home life)
  port=$(next_port)
  printf '127.0.0.1:%s\n' "$port" >"$home/config/dashboard-bind"

  out=$(FM_HOME="$home" "$DASH" status 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "status should be non-zero when stopped"
  assert_contains "$out" "stopped" "status stopped"

  out=$(FM_HOME="$home" "$DASH" start 2>&1) || fail "start failed: $out"
  assert_contains "$out" "started" "start message"
  wait_http "http://127.0.0.1:$port/healthz" 5 || fail "not ready after start"

  out=$(FM_HOME="$home" "$DASH" status 2>&1) || fail "status failed while running"
  assert_contains "$out" "running" "status running"
  assert_contains "$out" "127.0.0.1:$port" "status bind"

  server_pid=$(tr -d '[:space:]' <"$home/state/dashboard/server.pid")
  [ -n "$server_pid" ] || fail "server.pid missing"
  kill -9 "$server_pid" || fail "could not kill server pid $server_pid"

  # Supervisor must restart within 10s.
  new_pid=""
  for i in $(seq 1 100); do
    if [ -f "$home/state/dashboard/server.pid" ]; then
      new_pid=$(tr -d '[:space:]' <"$home/state/dashboard/server.pid")
      if [ -n "$new_pid" ] && [ "$new_pid" != "$server_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
        break
      fi
    fi
    sleep 0.1
  done
  [ -n "$new_pid" ] && [ "$new_pid" != "$server_pid" ] ||
    fail "server was not restarted within 10s (old=$server_pid new=$new_pid)"
  wait_http "http://127.0.0.1:$port/healthz" 5 || fail "healthz dead after restart"
  code=$(http_code "http://127.0.0.1:$port/healthz")
  [ "$code" = "200" ] || fail "healthz after restart expected 200 got $code"

  # Double-start is idempotent.
  out=$(FM_HOME="$home" "$DASH" start 2>&1) || fail "second start failed: $out"
  assert_contains "$out" "already running" "idempotent start"

  out=$(FM_HOME="$home" "$DASH" stop 2>&1) || fail "stop failed: $out"
  assert_contains "$out" "stopped" "stop message"
  # Port should close.
  if wait_http "http://127.0.0.1:$port/healthz" 1; then
    # brief race; try once more after short wait
    sleep 0.5
    if curl -sS -o /dev/null --connect-timeout 0.2 --max-time 0.5 "http://127.0.0.1:$port/healthz" 2>/dev/null; then
      fail "server still listening after stop"
    fi
  fi
  out=$(FM_HOME="$home" "$DASH" status 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "status should be stopped after stop"
  assert_contains "$out" "stopped" "status after stop"

  pass "lifecycle start/stop/status and restart-after-kill"
}

test_static_ui_present() {
  local html=$ROOT/bin/fm-dashboard-static/index.html
  local js=$ROOT/bin/fm-dashboard-static/app.js
  assert_present "$html" "index.html present"
  assert_present "$js" "app.js present"
  assert_grep "Your call" "$html" "section label Your call"
  assert_grep "Since you looked" "$html" "section label Since you looked"
  assert_grep "Ready for you" "$html" "section label Ready for you"
  assert_grep "Fleet now" "$html" "section label Fleet now"
  assert_grep "The trains" "$html" "section label trains"
  assert_grep "Meters" "$html" "section label Meters"
  assert_grep "Production" "$html" "section label Production"
  assert_grep "prefers-color-scheme" "$html" "dual theme via prefers-color-scheme"
  # Universal stable keys for wave 3 annotation / tick / dismiss / snooze.
  assert_grep "data-key" "$html" "sections carry data-key in HTML"
  assert_grep 'data-key="section:your-call"' "$html" "your-call section key"
  assert_grep 'data-key="section:fleet-now"' "$html" "fleet-now section key"
  assert_grep 'data-key="section:production"' "$html" "production section key"
  assert_grep "data-key" "$js" "cards set data-key in JS"
  assert_grep "data-decision-key" "$js" "decision hold-id alias"
  assert_grep "setKey" "$js" "setKey helper"
  assert_grep "decision:" "$js" "decision key prefix"
  assert_grep "task:" "$js" "task key prefix"
  assert_grep "empty:" "$js" "empty-state key prefix"
  assert_grep "wired in wave 2" "$js" "honest empty states"
  assert_grep "Answer" "$js" "answer action scaffold"
  assert_grep "Dismiss" "$js" "dismiss action scaffold"
  assert_grep "Snooze" "$js" "snooze action scaffold"
  pass "UI shell has required sections, themes, and universal data-key architecture"
}

server_bin() {
  local bin="$ROOT/dashboard/target/release/fm-dashboard-server"
  if [ ! -x "$bin" ]; then
    (cd "$ROOT/dashboard" && cargo build --release) >/dev/null 2>&1 ||
      return 1
  fi
  printf '%s\n' "$bin"
}

test_server_refuses_wildcard_env() {
  local out status bin home host
  home=$(make_home env-wild)
  bin=$(server_bin) || fail "could not build fm-dashboard-server for wildcard env test"
  for host in 0.0.0.0 :: '[::]' '[::ffff:0.0.0.0]' '[0:0:0:0:0:ffff:0:0]'; do
    out=$(
      FM_HOME="$home" \
      FM_DASHBOARD_BIND_HOST="$host" \
      FM_DASHBOARD_BIND_PORT=$(next_port) \
      FM_DASHBOARD_TOKEN=testtoken \
      FM_DASHBOARD_STATIC="$ROOT/bin/fm-dashboard-static" \
      "$bin" 2>&1
    ) && status=0 || status=$?
    [ "$status" -ne 0 ] || fail "server should refuse env bind host $host"
    assert_contains "$out" "wildcard" "server wildcard message for $host"
  done
  pass "Rust server refuses wildcard bind hosts from env (including IPv4-mapped)"
}

# The unlock form is unauthenticated: a malformed percent escape must not be
# able to take the server process down.
test_unlock_survives_malformed_form_body() {
  local home port pid_before pid_after code
  home=$(make_home unlock-fuzz)
  port=$(next_port)
  printf '127.0.0.1:%s\n' "$port" >"$home/config/dashboard-bind"
  FM_HOME="$home" "$DASH" start >/dev/null || fail "start failed"
  wait_http "http://127.0.0.1:$port/healthz" 5 || fail "not ready"
  pid_before=$(tr -d '[:space:]' <"$home/state/dashboard/server.pid")

  # % followed by a multi-byte character, a truncated escape, and raw invalid
  # UTF-8 - each one used to slice across a char boundary.
  for body in 'token=%€' 'token=%e2%82' 'token=%' 'token=a%zz%' "$(printf 'token=%%\xff\xfe')"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 5 \
      -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-raw "$body" "http://127.0.0.1:$port/unlock" 2>/dev/null)
    [ -n "$code" ] || fail "no response to malformed unlock body: $body"
  done

  code=$(http_code "http://127.0.0.1:$port/healthz")
  [ "$code" = "200" ] || fail "healthz after malformed unlock expected 200 got $code"
  pid_after=$(tr -d '[:space:]' <"$home/state/dashboard/server.pid")
  [ "$pid_before" = "$pid_after" ] ||
    fail "server restarted after malformed unlock body (old=$pid_before new=$pid_after)"

  cleanup_dash "$home"
  pass "malformed /unlock bodies do not crash the server"
}

# stop and status are recovery paths: they must not need a Rust toolchain or a
# build tree just to report or tear down a running daemon.
test_stop_status_without_server_binary() {
  local home port out status fakeroot
  home=$(make_home no-cargo)
  port=$(next_port)
  printf '127.0.0.1:%s\n' "$port" >"$home/config/dashboard-bind"
  FM_HOME="$home" "$DASH" start >/dev/null || fail "start failed"
  wait_http "http://127.0.0.1:$port/healthz" 5 || fail "not ready"

  # A code root with the static UI and the crate but a cleaned target/, plus a
  # cargo on PATH that fails loudly if anything tries to build.
  fakeroot=$TMP_ROOT/no-cargo-root
  mkdir -p "$fakeroot/bin" "$fakeroot/stub" "$fakeroot/dashboard"
  ln -sf "$ROOT/bin/fm-dashboard-static" "$fakeroot/bin/fm-dashboard-static"
  printf '[package]\nname = "stub"\n' >"$fakeroot/dashboard/Cargo.toml"
  printf '#!/bin/sh\necho STUB-CARGO-RAN >&2\nexit 1\n' >"$fakeroot/stub/cargo"
  chmod +x "$fakeroot/stub/cargo"

  out=$(PATH="$fakeroot/stub:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" \
    "$DASH" status 2>&1) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "status should work without a server binary: $out"
  assert_contains "$out" "running" "status without a server binary"
  assert_not_contains "$out" "STUB-CARGO-RAN" "status must not trigger a build"

  out=$(PATH="$fakeroot/stub:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" \
    "$DASH" stop 2>&1) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "stop should work without a server binary: $out"
  assert_contains "$out" "stopped" "stop without a server binary"
  assert_not_contains "$out" "STUB-CARGO-RAN" "stop must not trigger a build"
  if wait_http "http://127.0.0.1:$port/healthz" 1; then
    sleep 0.5
    curl -sS -o /dev/null --connect-timeout 0.2 --max-time 0.5 \
      "http://127.0.0.1:$port/healthz" 2>/dev/null &&
      fail "stop without a server binary left the server listening"
  fi
  pass "stop and status work without a build tree or Rust toolchain"
}

# --- run -------------------------------------------------------------------

test_refuses_missing_home_shape
test_refuses_unset_home_when_root_not_home
test_refuses_wildcard_bind
test_refuses_ipv6_any_bind
test_refuses_ipv4_mapped_wildcard_bind
test_honors_bind_override
test_auth_and_snapshot_shape
test_unlock_survives_malformed_form_body
test_stop_status_without_server_binary
test_lifecycle_start_stop_status_restart
test_static_ui_present
test_server_refuses_wildcard_env

printf 'All fm-dashboard tests passed.\n'
