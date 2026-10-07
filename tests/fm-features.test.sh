#!/usr/bin/env bash
# Behavior tests for the per-home feature switches: bin/fm-features.sh and the
# gates that read bin/fm-features-lib.sh in brief, promote, procevent, trace,
# bootstrap, and session start.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-features)
SWITCHES="secondmate relay voice-ide no-mistakes local-only contributions process-events trace"

new_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home"
  printf '%s\n' "$home"
}

features() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME=$home "$ROOT/bin/fm-features.sh" "$@"
}

test_undeclared_home_keeps_every_feature() {
  local home out name
  home=$(new_home undeclared)
  out=$(features "$home" show)
  for name in $SWITCHES; do
    assert_contains "$out" "$(printf '%-15s %-3s (%s)' "$name" on default)" "undeclared $name must be on"
    features "$home" enabled "$name" || fail "undeclared $name must report enabled"
  done
  pass "a home without config/features keeps every feature on"
}

test_presets_and_single_override() {
  local home name rc
  home=$(new_home presets)
  features "$home" preset lite >/dev/null || fail "preset lite failed"
  for name in $SWITCHES; do
    features "$home" enabled "$name"; rc=$?
    expect_code 1 "$rc" "lite must switch $name off"
  done
  features "$home" set no-mistakes on >/dev/null || fail "set failed"
  features "$home" enabled no-mistakes || fail "set no-mistakes on must stick"
  features "$home" enabled secondmate; rc=$?
  expect_code 1 "$rc" "set must keep the other lite switches"
  features "$home" preset normal >/dev/null || fail "preset normal failed"
  for name in $SWITCHES; do
    features "$home" enabled "$name" || fail "normal must switch $name on"
  done
  features "$home" set bogus on >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "an unknown switch must be refused"
  pass "presets write every switch and set changes exactly one"
}

test_seed_only_touches_a_brand_new_home() {
  local fresh used configured secondmate out
  fresh=$(new_home seed-fresh)
  out=$(features "$fresh" seed)
  assert_contains "$out" "lite preset" "a brand-new home must be seeded"
  [ "$(features "$fresh" enabled relay; echo $?)" = 1 ] || fail "seeded home must be lite"

  used=$(new_home seed-used)
  mkdir -p "$used/data"
  features "$used" seed
  [ ! -e "$used/config/features" ] || fail "a home with data/ must not be seeded"

  configured=$(new_home seed-configured)
  mkdir -p "$configured/config"
  : > "$configured/config/trace-context"
  features "$configured" seed
  [ ! -e "$configured/config/features" ] || fail "a home with other config must not be seeded"

  secondmate=$(new_home seed-secondmate)
  : > "$secondmate/.fm-secondmate-home"
  features "$secondmate" seed
  [ ! -e "$secondmate/config/features" ] || fail "a secondmate home must not be seeded"
  pass "seed starts only a brand-new primary home on lite"
}

test_switched_off_modes_are_refused() {
  local home out rc
  home=$(new_home modes)
  mkdir -p "$home/data"
  FM_HOME=$home "$ROOT/bin/fm-brief.sh" on-nm repo --mode no-mistakes >/dev/null \
    || fail "an undeclared home must accept no-mistakes"
  features "$home" preset lite >/dev/null
  out=$(FM_HOME=$home "$ROOT/bin/fm-brief.sh" off-nm repo --mode no-mistakes 2>&1); rc=$?
  expect_code 1 "$rc" "brief must refuse a switched-off no-mistakes"
  assert_contains "$out" "switched off" "brief refusal must name the switch"
  out=$(FM_HOME=$home "$ROOT/bin/fm-brief.sh" off-lo repo --mode local-only 2>&1); rc=$?
  expect_code 1 "$rc" "brief must refuse a switched-off local-only"
  FM_HOME=$home "$ROOT/bin/fm-brief.sh" off-pr repo --mode direct-PR >/dev/null \
    || fail "direct-PR must stay available on lite"
  out=$(FM_HOME=$home "$ROOT/bin/fm-promote.sh" off-pr --mode direct-PR --yolo off 2>&1); rc=$?
  expect_code 1 "$rc" "promote must be refused when local-only is off"
  assert_contains "$out" "promotion is switched off" "promote refusal must name the switch"
  pass "switched-off delivery modes and promotion are refused before any work"
}

test_ship_brief_carries_engineering_discipline() {
  local home brief
  home=$(new_home discipline)
  mkdir -p "$home/data"
  FM_HOME=$home "$ROOT/bin/fm-brief.sh" disc repo --mode direct-PR >/dev/null || fail "brief failed"
  brief=$home/data/disc/brief.md
  assert_grep "# Engineering discipline" "$brief" "ship brief must carry the discipline section"
  assert_grep ".agents/skills/comment-audit/SKILL.md" "$brief" "ship brief must point at comment-audit"
  pass "ship briefs carry the engineering discipline and the comment-audit pointer"
}

test_process_event_watches_are_gated() {
  local home out rc
  home=$(new_home procevent)
  mkdir -p "$home/state"
  features "$home" preset lite >/dev/null
  out=$(FM_HOME=$home "$ROOT/bin/fm-procevent.sh" register when demo -- true 2>&1); rc=$?
  expect_code 1 "$rc" "a condition-action watch must be refused on lite"
  assert_contains "$out" "switched off" "procevent refusal must name the switch"
  pass "process-event condition-action watches follow the switch"
}

test_trace_switch_overrides_the_presence_flag() {
  local home rc
  home=$(new_home trace)
  mkdir -p "$home/config"
  : > "$home/config/trace-context"
  # shellcheck disable=SC2016  # Expands in the child bash.
  FM_TRACE_CONTEXT='' bash -c '. "$1/bin/fm-trace-context-lib.sh"; fm_trace_context_enabled "$2"' _ "$ROOT" "$home/config" \
    || fail "trace must stay on when only the presence flag is set"
  printf 'trace=off\n' > "$home/config/features"
  # shellcheck disable=SC2016  # Expands in the child bash.
  FM_TRACE_CONTEXT='' bash -c '. "$1/bin/fm-trace-context-lib.sh"; fm_trace_context_enabled "$2"' _ "$ROOT" "$home/config"; rc=$?
  expect_code 1 "$rc" "trace=off must override config/trace-context"
  pass "the trace switch overrides config/trace-context"
}

test_session_start_digest_follows_the_switches() {
  local lite normal out_lite out_normal
  lite=$(new_home ss-lite)
  normal=$(new_home ss-normal)
  mkdir -p "$lite/data" "$normal/data"
  printf -- '- mate - test\n' > "$lite/data/secondmates.md"
  printf -- '- mate - test\n' > "$normal/data/secondmates.md"
  features "$lite" preset lite >/dev/null
  out_lite=$(FM_HOME=$lite "$ROOT/bin/fm-session-start.sh" 2>&1)
  out_normal=$(FM_HOME=$normal "$ROOT/bin/fm-session-start.sh" 2>&1)
  assert_contains "$out_lite" "off: $SWITCHES" "lite digest must list the switched-off features"
  assert_not_contains "$out_lite" "data/secondmates.md"$'\n' "lite digest must omit the secondmate routes"
  assert_not_contains "$out_normal" "Feature switches (config/features)" "an undeclared home's digest must not change"
  assert_contains "$out_normal" "- mate - test" "an undeclared home must still print secondmate routes"
  pass "session start lists switched-off features and drops secondmate routes only when switched off"
}

test_bootstrap_follows_relay_and_no_mistakes_switches() {
  local on off out fakebin
  on=$(new_home boot-on)
  off=$(new_home boot-off)
  printf 'FMX_PAIRING_TOKEN=tok-features\n' > "$on/.env"
  printf 'FMX_PAIRING_TOKEN=tok-features\n' > "$off/.env"
  features "$off" preset lite >/dev/null
  fakebin=$TMP_ROOT/fakebin
  mkdir -p "$fakebin"
  printf '#!/bin/sh\necho "no-mistakes 0.0.1"\n' > "$fakebin/no-mistakes"
  chmod +x "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME=$on "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMX: X mode on" "an undeclared home must keep Relay"
  assert_contains "$out" "MISSING: no-mistakes" "an undeclared home must keep the no-mistakes floor"
  out=$(PATH="$fakebin:$PATH" FM_HOME=$off "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMX: X mode on" "relay=off must keep Relay off despite a token"
  [ ! -e "$off/config/x-mode.env" ] || fail "relay=off must not write the Relay cadence"
  assert_not_contains "$out" "MISSING: no-mistakes" "no-mistakes=off must not require the tool"
  pass "bootstrap follows the relay and no-mistakes switches"
}

test_undeclared_home_keeps_every_feature
test_presets_and_single_override
test_seed_only_touches_a_brand_new_home
test_switched_off_modes_are_refused
test_ship_brief_carries_engineering_discipline
test_process_event_watches_are_gated
test_trace_switch_overrides_the_presence_flag
test_session_start_digest_follows_the_switches
test_bootstrap_follows_relay_and_no_mistakes_switches
