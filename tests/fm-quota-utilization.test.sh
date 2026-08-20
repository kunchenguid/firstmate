#!/usr/bin/env bash
# Behavior tests for the weekly quota-utilization check.
#
# The owner CLI is exercised only through its public commands. Fixtures are
# quota-axi snapshots, never implementation source. A fixed clock makes reset
# countdown and end-of-window outcomes deterministic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
NODE_DIR=$(command -v node 2>/dev/null) && NODE_DIR=$(dirname "$NODE_DIR") || NODE_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
[ -n "$NODE_DIR" ] && BASE_PATH="$NODE_DIR:$BASE_PATH"

UTIL="$ROOT/bin/fm-quota-utilization.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-utilization)
NOW=2026-08-18T18:00:00Z

run_util() {
  FM_QUOTA_UTILIZATION_NOW="$NOW" "$UTIL" "$@"
}

write_snapshot() {
  local path=$1
  cat > "$path"
}

# Claude: idle five-hour window, binding weekly ahead of pace, plus a tighter
# named-model bound that must not replace the account widget window.
claude_ahead_weekly_snapshot() {
  cat <<'JSON'
{
  "generatedAt": "2026-08-18T18:00:00Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "source": "oauth",
      "plan": "max",
      "windows": [
        {
          "id": "five_hour",
          "label": "session",
          "kind": "session",
          "percentUsed": 3,
          "percentRemaining": 97,
          "resetsAt": "2026-08-18T22:00:00Z",
          "windowSeconds": 18000,
          "pace": {
            "status": "behind",
            "timeRemainingPercent": 22.2,
            "elapsedPercent": 77.8,
            "reservePercentPoints": 74.8
          }
        },
        {
          "id": "seven_day",
          "label": "week",
          "kind": "weekly",
          "percentUsed": 72,
          "percentRemaining": 28,
          "resetsAt": "2026-08-24T18:00:00Z",
          "windowSeconds": 604800,
          "pace": {
            "status": "ahead",
            "timeRemainingPercent": 85.7,
            "elapsedPercent": 14.3,
            "reservePercentPoints": -57.7,
            "projectedExhaustedAt": "2026-08-20T06:00:00Z"
          }
        },
        {
          "id": "model:fable",
          "label": "Fable week",
          "kind": "model",
          "percentUsed": 80,
          "percentRemaining": 20,
          "resetsAt": "2026-08-24T18:00:00Z",
          "windowSeconds": 604800,
          "pace": {
            "status": "ahead",
            "timeRemainingPercent": 85.7,
            "elapsedPercent": 14.3,
            "reservePercentPoints": -65.7
          }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "description": "Claude account windows bound every model. A model-specific window is an additional bound.",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 28,
            "boundedBy": ["five_hour", "seven_day"],
            "limitingWindowIds": ["seven_day"],
            "pace": {
              "status": "mixed",
              "aheadWindowIds": ["seven_day"],
              "behindWindowIds": ["five_hour"],
              "worstReservePercentPoints": -57.7,
              "worstReserveWindowId": "seven_day"
            },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 129600,
              "projectedExhaustedAt": "2026-08-20T06:00:00Z",
              "limitingWindowId": "seven_day",
              "projectionConfidence": "established",
              "projectionBasis": "cycle_average"
            }
          },
          {
            "scope": "model:fable",
            "status": "known",
            "effectivePercentRemaining": 20,
            "boundedBy": ["five_hour", "seven_day", "model:fable"],
            "limitingWindowIds": ["model:fable"],
            "pace": {
              "status": "ahead",
              "worstReservePercentPoints": -65.7,
              "worstReserveWindowId": "model:fable"
            },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 86400,
              "limitingWindowId": "model:fable"
            }
          }
        ]
      }
    }
  ]
}
JSON
}

codex_behind_weekly_snapshot() {
  cat <<'JSON'
{
  "generatedAt": "2026-08-18T18:00:00Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "codex",
      "label": "Codex",
      "source": "oauth",
      "plan": "pro",
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentUsed": 20,
          "percentRemaining": 80,
          "resetsAt": "2026-08-25T18:00:00Z",
          "windowSeconds": 604800,
          "pace": {
            "status": "behind",
            "timeRemainingPercent": 50,
            "elapsedPercent": 50,
            "reservePercentPoints": 30
          }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "description": "Codex account windows bound every model.",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 80,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "pace": {
              "status": "behind",
              "behindWindowIds": ["weekly"],
              "worstReservePercentPoints": 30,
              "worstReserveWindowId": "weekly"
            },
            "runway": {
              "status": "through_reset",
              "usableRunwaySeconds": 604800,
              "limitingWindowId": "weekly"
            }
          }
        ]
      }
    }
  ]
}
JSON
}

# Shaped as quota-axi 0.1.28 actually emits a failed provider: the exact cause
# slug lives in state.error beside an empty windows list, never at the top level.
# Claude: the account's session window is fully consumed while the binding
# weekly window is still behind pace, the state that makes a short window a
# legitimate secondary tie-break.
claude_exhausted_session_snapshot() {
  cat <<'JSON'
{
  "generatedAt": "2026-08-18T18:00:00Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "source": "oauth",
      "plan": "max",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "five_hour",
          "label": "session",
          "kind": "session",
          "percentUsed": 100,
          "percentRemaining": 0,
          "resetsAt": "2026-08-18T22:00:00Z",
          "windowSeconds": 18000,
          "pace": {
            "status": "ahead",
            "timeRemainingPercent": 22.2,
            "elapsedPercent": 77.8,
            "reservePercentPoints": -22.2
          }
        },
        {
          "id": "seven_day",
          "label": "week",
          "kind": "weekly",
          "percentUsed": 10,
          "percentRemaining": 90,
          "resetsAt": "2026-08-25T18:00:00Z",
          "windowSeconds": 604800,
          "pace": {
            "status": "behind",
            "timeRemainingPercent": 94.3,
            "elapsedPercent": 5.7,
            "reservePercentPoints": 4.3
          }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "description": "Claude account windows bound every model.",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 0,
            "boundedBy": ["five_hour", "seven_day"],
            "limitingWindowIds": ["five_hour"],
            "pace": {
              "status": "mixed",
              "aheadWindowIds": ["five_hour"],
              "behindWindowIds": ["seven_day"],
              "worstReservePercentPoints": -22.2,
              "worstReserveWindowId": "five_hour"
            },
            "runway": {
              "status": "exhausted_now",
              "usableRunwaySeconds": 0,
              "limitingWindowId": "five_hour"
            }
          }
        ]
      }
    }
  ]
}
JSON
}

# Cursor: a measured provider whose only window carries no percentUsed and no
# resetsAt, which quota-axi 0.1.28 emits for a spend_limit window with neither
# individualUsed nor individualRemaining and an unparseable billing cycle end.
cursor_unmeasurable_window_snapshot() {
  cat <<'JSON'
{
  "generatedAt": "2026-08-18T18:00:00Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "cursor",
      "label": "Cursor",
      "source": "api",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "spend_limit",
          "label": "spend limit",
          "kind": "credits"
        }
      ]
    }
  ]
}
JSON
}

missing_sources_snapshot() {
  cat <<'JSON'
{
  "generatedAt": "2026-08-18T18:00:00Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "cursor",
      "label": "Cursor",
      "source": "unavailable",
      "windows": [],
      "state": {
        "status": "error",
        "stale": false,
        "error": "sqlite3_unavailable",
        "sourcesTried": ["state-vscdb"]
      },
      "attempts": [
        { "source": "state-vscdb", "status": "skipped", "error": "sqlite3_unavailable" }
      ]
    },
    {
      "provider": "kimi",
      "label": "Kimi",
      "source": "unavailable",
      "windows": [],
      "state": {
        "status": "auth_required",
        "stale": false,
        "error": "kimi_code_cli_credential_expired",
        "sourcesTried": ["kimi-code-cli"]
      },
      "attempts": [
        { "source": "kimi-code-cli", "status": "failed", "error": "kimi_code_cli_credential_expired" }
      ]
    }
  ]
}
JSON
}

test_tightest_window_is_binding_weekly_not_idle_session_or_named_model() {
  local snap json
  snap="$TMP_ROOT/tightest.json"
  claude_ahead_weekly_snapshot > "$snap"
  json=$(run_util --snapshot "$snap" --json) || fail "tightest-window report failed"

  printf '%s' "$json" | jq -e '
    (.accounts | length) == 1
    and .accounts[0].provider == "claude"
    and .accounts[0].tightestWindowId == "seven_day"
    and .accounts[0].utilizationPercent == 72
    and .accounts[0].resetCountdownSeconds == 518400
    and .accounts[0].bindingWeeklyWindowId == "seven_day"
    and .accounts[0].bindingWeeklyReservePercentPoints == -57.7
    and .accounts[0].usableRunwaySeconds == 129600
    and .accounts[0].verdict == "RATION"
  ' >/dev/null || fail "tightest window did not follow all_models limiting weekly"$'\n'"$json"
  pass "tightest-window selection uses the binding weekly window, not the idle session or named-model bound"
}

test_idle_short_window_is_not_spare_when_weekly_is_ahead() {
  local snap json
  snap="$TMP_ROOT/idle-short.json"
  claude_ahead_weekly_snapshot > "$snap"
  json=$(run_util --snapshot "$snap" --json) || fail "idle-short report failed"

  printf '%s' "$json" | jq -e '
    .accounts[0].shortWindows[0].id == "five_hour"
    and .accounts[0].shortWindows[0].percentRemaining == 97
    and .accounts[0].shortWindows[0].spareCapacity == false
    and .accounts[0].verdict == "RATION"
    and .holdReadyWork == false
  ' >/dev/null || fail "idle short window was treated as spare capacity"$'\n'"$json"
  pass "a short idle window is not spare capacity when the binding weekly window is ahead of pace"
}

test_exhausted_short_window_is_not_spare_capacity() {
  local snap json
  snap="$TMP_ROOT/exhausted-short.json"
  claude_exhausted_session_snapshot > "$snap"
  json=$(run_util --snapshot "$snap" --intake) || fail "exhausted-short intake failed"

  printf '%s' "$json" | jq -e '
    .accounts[0].bindingWeeklyPaceStatus == "behind"
    and .accounts[0].shortWindows[0].id == "five_hour"
    and .accounts[0].shortWindows[0].percentRemaining == 0
    and .accounts[0].shortWindows[0].spareCapacity == false
    and .accounts[0].usableRunwaySeconds == 0
    and .holdReadyWork == false
  ' >/dev/null || fail "a fully consumed short window was offered as spare capacity"$'\n'"$json"
  pass "a fully consumed short window is not spare capacity even when weekly headroom is behind pace"
}

test_reset_countdown_uses_fixed_clock_and_limiting_reset() {
  local snap out
  snap="$TMP_ROOT/countdown.json"
  claude_ahead_weekly_snapshot > "$snap"
  out=$(run_util --snapshot "$snap" report) || fail "countdown report failed"
  assert_contains "$out" "72%" "human report omitted utilization percent"
  assert_contains "$out" "seven_day" "human report omitted tightest window id"
  assert_contains "$out" "518400s" "human report omitted reset countdown seconds"
  pass "reset countdown is seconds until the tightest window resetsAt against the fixed clock"
}

test_unmeasurable_window_reports_unknown_not_a_literal_null() {
  local snap out json status
  snap="$TMP_ROOT/unmeasurable.json"
  cursor_unmeasurable_window_snapshot > "$snap"
  out=$(run_util --snapshot "$snap" report)
  status=$?
  expect_code 0 "$status" "an unmeasurable window must not fail the check"
  assert_contains "$out" "quota: cursor default: unknown% used (spend_limit) resets in unknowns" \
    "an unmeasurable window was not reported as unknown"
  assert_not_contains "$out" "null" "the human report line rendered a literal null"
  json=$(run_util --snapshot "$snap" --json)
  printf '%s' "$json" | jq -e '
    .accounts[0].utilizationPercent == null
    and .accounts[0].resetCountdownSeconds == null
    and .holdReadyWork == false
  ' >/dev/null || fail "the JSON surface stopped carrying an explicit null"$'\n'"$json"
  pass "a window with no measurable percent or reset reports unknown in text and null in JSON"
}

test_missing_source_names_exact_cause_and_steps_aside() {
  local snap out json status
  snap="$TMP_ROOT/missing.json"
  missing_sources_snapshot > "$snap"
  out=$(run_util --snapshot "$snap" report)
  status=$?
  expect_code 0 "$status" "missing sources must not fail the check"
  assert_contains "$out" "cursor skipped: sqlite3_unavailable" "cursor gap was not named"
  assert_contains "$out" "kimi skipped: kimi_code_cli_credential_expired" "kimi gap was not named"
  json=$(run_util --snapshot "$snap" --json)
  printf '%s' "$json" | jq -e '
    .accounts == []
    and (.degraded | map(.provider) | sort) == ["cursor", "kimi"]
    and (.degraded[] | select(.provider == "cursor") | .cause) == "sqlite3_unavailable"
    and .holdReadyWork == false
  ' >/dev/null || fail "missing-source JSON did not degrade in place"$'\n'"$json"
  pass "missing sources name the exact cause in one line and step aside"
}

test_no_hold_when_every_equivalent_candidate_is_tight() {
  local snap json
  snap="$TMP_ROOT/no-hold.json"
  claude_ahead_weekly_snapshot > "$snap"
  json=$(run_util --snapshot "$snap" --intake) || fail "intake report failed"
  printf '%s' "$json" | jq -e '
    .holdReadyWork == false
    and .weakenReasoningClass == false
    and .accounts[0].verdict == "RATION"
    and .accounts[0].pressure == "ahead_of_pace"
  ' >/dev/null || fail "intake held work or weakened reasoning"$'\n'"$json"
  pass "when every equivalent candidate is tight, the check reports pressure and never holds ready work"
}

test_intake_prefers_healthier_binding_weekly_reserve() {
  local claude_snap codex_snap json
  claude_snap="$TMP_ROOT/prefer-claude.json"
  codex_snap="$TMP_ROOT/prefer-codex.json"
  claude_ahead_weekly_snapshot > "$claude_snap"
  codex_behind_weekly_snapshot > "$codex_snap"
  json=$(run_util --snapshot "$claude_snap" --snapshot "$codex_snap" --intake) \
    || fail "multi-snapshot intake failed"
  printf '%s' "$json" | jq -e '
    (.accounts | map(.provider) | sort) == ["claude", "codex"]
    and (.accounts[] | select(.provider == "codex") | .bindingWeeklyReservePercentPoints) == 30
    and (.accounts[] | select(.provider == "claude") | .bindingWeeklyReservePercentPoints) == -57.7
    and .preferredBindingWeeklyProvider == "codex"
    and .holdReadyWork == false
  ' >/dev/null || fail "intake did not prefer the healthier binding weekly reserve"$'\n'"$json"
  pass "intake prefers the healthier binding weekly reserve among equivalent-fit accounts"
}

test_end_of_window_exhausted_early_versus_expired_unused() {
  local obs table json early_cell
  obs="$TMP_ROOT/observations.jsonl"
  cat > "$obs" <<'JSONL'
{"observedAt":"2026-08-18T12:00:00Z","provider":"claude","account":"default","windowId":"seven_day","percentRemaining":0,"resetsAt":"2026-08-24T18:00:00Z"}
{"observedAt":"2026-08-18T12:00:00Z","provider":"codex","account":"default","windowId":"weekly","percentRemaining":44,"resetsAt":"2026-08-18T18:00:00Z"}
JSONL
  table=$(FM_QUOTA_UTILIZATION_NOW=2026-08-18T18:00:00Z "$UTIL" --observations "$obs" outcomes) \
    || fail "outcomes table failed"
  assert_contains "$table" "claude" "outcomes omitted claude"
  assert_contains "$table" "exhausted-early" "exhausted-early outcome missing"
  assert_contains "$table" "codex" "outcomes omitted codex"
  assert_contains "$table" "expired-unused" "expired-unused outcome missing"
  early_cell=$(printf '%s\n' "$table" | awk -F'\t' '$1 == "codex" { print "[" $6 "]"; found = 1 } END { if (!found) print "[missing]" }')
  [ "$early_cell" = "[]" ] \
    || fail "expired-unused row printed $early_cell instead of an empty exhaustedEarlySeconds cell"$'\n'"$table"
  json=$(FM_QUOTA_UTILIZATION_NOW=2026-08-18T18:00:00Z "$UTIL" --observations "$obs" outcomes --json)
  printf '%s' "$json" | jq -e '
    (.outcomes[] | select(.provider == "claude") | .kind) == "exhausted-early"
    and (.outcomes[] | select(.provider == "claude") | .exhaustedEarlySeconds) == 540000
    and (.outcomes[] | select(.provider == "codex") | .kind) == "expired-unused"
    and (.outcomes[] | select(.provider == "codex") | .unusedPercent) == 44
  ' >/dev/null || fail "end-of-window JSON did not separate unused vs early"$'\n'"$json"
  pass "end-of-window outcomes report exhausted-early time versus expired unused percent"
}

test_provider_filter_scopes_the_outcomes_table() {
  local obs table
  obs="$TMP_ROOT/observations-filtered.jsonl"
  cat > "$obs" <<'JSONL'
{"observedAt":"2026-08-18T12:00:00Z","provider":"claude","account":"default","windowId":"seven_day","percentRemaining":0,"resetsAt":"2026-08-24T18:00:00Z"}
{"observedAt":"2026-08-18T12:00:00Z","provider":"codex","account":"default","windowId":"weekly","percentRemaining":44,"resetsAt":"2026-08-18T18:00:00Z"}
JSONL
  table=$(FM_QUOTA_UTILIZATION_NOW=2026-08-25T00:00:00Z \
    "$UTIL" --provider claude --observations "$obs" outcomes) \
    || fail "provider-filtered outcomes table failed"
  assert_contains "$table" "exhausted-early" "the requested provider's outcome is missing"
  assert_not_contains "$table" "codex" "an unrequested provider's window reached the outcomes table"
  pass "--provider scopes the outcomes table to the requested provider"
}

test_end_of_window_outcome_survives_replay_after_the_window_reset() {
  local obs json
  obs="$TMP_ROOT/observations-replay.jsonl"
  cat > "$obs" <<'JSONL'
{"observedAt":"2026-08-18T12:00:00Z","provider":"claude","account":"default","windowId":"seven_day","percentRemaining":0,"resetsAt":"2026-08-24T18:00:00Z"}
{"observedAt":"2026-08-18T12:00:00Z","provider":"codex","account":"default","windowId":"weekly","percentRemaining":44,"resetsAt":"2026-08-18T18:00:00Z"}
JSONL
  json=$(FM_QUOTA_UTILIZATION_NOW=2026-08-25T00:00:00Z "$UTIL" --observations "$obs" outcomes --json) \
    || fail "post-reset outcomes replay failed"
  printf '%s' "$json" | jq -e '
    (.outcomes[] | select(.provider == "claude") | .kind) == "exhausted-early"
    and (.outcomes[] | select(.provider == "claude") | .exhaustedEarlySeconds) == 540000
    and (.outcomes[] | select(.provider == "codex") | .kind) == "expired-unused"
    and (.outcomes[] | select(.provider == "codex") | .unusedPercent) == 44
  ' >/dev/null || fail "replaying a closed window lost the exhausted-early outcome"$'\n'"$json"
  pass "end-of-window outcomes stay reproducible when replayed after the window has reset"
}

test_outcomes_mode_does_not_perform_a_live_provider_read() {
  local home fakebin log obs table
  home="$TMP_ROOT/outcomes-home"
  fakebin="$TMP_ROOT/outcomes-fakebin"
  log="$TMP_ROOT/outcomes-axi.log"
  mkdir -p "$home/data" "$fakebin"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf 'called\n' >> "$log"
printf '{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[]}\n'
SH
  chmod +x "$fakebin/quota-axi"
  obs="$TMP_ROOT/outcomes-only.jsonl"
  cat > "$obs" <<'JSONL'
{"observedAt":"2026-08-18T12:00:00Z","provider":"codex","account":"default","windowId":"weekly","percentRemaining":44,"resetsAt":"2026-08-18T18:00:00Z"}
JSONL
  table=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_QUOTA_UTILIZATION_NOW="$NOW" \
    "$UTIL" --observations "$obs" outcomes) || fail "outcomes-only run failed"
  assert_contains "$table" "expired-unused" "outcomes table lost its row"
  assert_absent "$log" "outcomes mode performed a live quota-axi read"
  pass "outcomes mode is derived from observations alone and performs no live provider read"
}

test_profile_skip_line_names_the_failing_account() {
  local home fakebin present out
  home="$TMP_ROOT/skip-home"
  fakebin="$TMP_ROOT/skip-fakebin"
  present="$TMP_ROOT/claude-present"
  mkdir -p "$home/data" "$home/config" "$fakebin" "$present"
  chmod 0700 "$present"
  printf 'paid-primary=%s\npaid-secondary=%s\n' "$present" "$TMP_ROOT/claude-absent" \
    > "$home/config/claude-account-profiles"
  chmod 0600 "$home/config/claude-account-profiles"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[]}\n'
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_QUOTA_UTILIZATION_NOW="$NOW" \
    "$UTIL" --accounts-from-config report) || fail "profile skip report failed"
  assert_contains "$out" "quota: claude paid-secondary skipped: CLAUDE_CONFIG_DIR missing" \
    "profile skip line did not name the failing account alias"
  pass "a per-profile skip line names which account home failed"
}

test_provider_filter_is_forwarded_to_the_live_reader() {
  local home fakebin log json
  home="$TMP_ROOT/filter-home"
  fakebin="$TMP_ROOT/filter-fakebin"
  log="$TMP_ROOT/filter-argv.log"
  mkdir -p "$home/data" "$fakebin"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
cat <<'JSON'
{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[{"provider":"codex","label":"Codex","source":"oauth","windows":[{"id":"weekly","label":"week","kind":"weekly","percentUsed":5,"percentRemaining":95,"resetsAt":"2026-08-25T18:00:00Z","pace":{"status":"behind","reservePercentPoints":45}}],"state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","description":"","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":95,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":45,"worstReserveWindowId":"weekly"},"runway":{"status":"through_reset","usableRunwaySeconds":604800,"limitingWindowId":"weekly"}}]}}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_QUOTA_UTILIZATION_NOW="$NOW" \
    "$UTIL" --json --provider codex) || fail "provider-filtered report failed"
  assert_grep "--provider codex" "$log" "the provider filter was not forwarded to the live reader"
  printf '%s' "$json" | jq -e '.accounts[0].provider == "codex"' >/dev/null \
    || fail "provider-filtered report lost its account"$'\n'"$json"
  pass "--provider restricts the live quota-axi read instead of filtering after the fact"
}

test_provider_filter_skips_claude_profile_reads() {
  local home fakebin log out present
  home="$TMP_ROOT/profile-filter-home"
  fakebin="$TMP_ROOT/profile-filter-fakebin"
  present="$TMP_ROOT/profile-filter-present"
  log="$TMP_ROOT/profile-filter-argv.log"
  mkdir -p "$home/data" "$home/config" "$fakebin" "$present"
  chmod 0700 "$present"
  printf 'paid-primary=%s\npaid-secondary=%s\n' "$present" "$TMP_ROOT/profile-filter-absent" \
    > "$home/config/claude-account-profiles"
  chmod 0600 "$home/config/claude-account-profiles"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
cat <<'JSON'
{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[{"provider":"codex","label":"Codex","source":"oauth","windows":[{"id":"weekly","label":"week","kind":"weekly","percentUsed":5,"percentRemaining":95,"resetsAt":"2026-08-25T18:00:00Z","pace":{"status":"behind","reservePercentPoints":45}}],"state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","description":"","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":95,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":45,"worstReserveWindowId":"weekly"},"runway":{"status":"through_reset","usableRunwaySeconds":604800,"limitingWindowId":"weekly"}}]}}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_QUOTA_UTILIZATION_NOW="$NOW" \
    "$UTIL" --provider codex --accounts-from-config report) \
    || fail "provider-filtered profile report failed"
  assert_contains "$out" "quota: codex default:" "the requested provider was not reported"
  case "$out" in
    *claude*) fail "a claude profile read leaked into a codex-only report"$'\n'"$out" ;;
  esac
  assert_no_grep "--provider claude" "$log" \
    "a claude profile read ran for a codex-only request"
  pass "--provider skips Claude profile reads and their skip lines for another provider"
}

test_multi_account_claude_profiles_do_not_mix_windows() {
  local home fakebin primary secondary json
  home="$TMP_ROOT/multi-home"
  fakebin="$TMP_ROOT/multi-fakebin"
  primary="$TMP_ROOT/claude-primary"
  secondary="$TMP_ROOT/claude-secondary"
  mkdir -p "$home/data" "$home/config" "$fakebin" "$primary" "$secondary"
  chmod 0700 "$primary" "$secondary"
  printf 'paid-primary=%s\npaid-secondary=%s\n' "$primary" "$secondary" \
    > "$home/config/claude-account-profiles"
  chmod 0600 "$home/config/claude-account-profiles"

  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
dir=${CLAUDE_CONFIG_DIR:-ambient}
case "$dir" in
  *claude-primary)
    cat <<'JSON'
{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[{"provider":"claude","windows":[{"id":"seven_day","kind":"weekly","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-08-25T18:00:00Z","pace":{"status":"behind","reservePercentPoints":40}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["seven_day"],"limitingWindowIds":["seven_day"],"pace":{"status":"behind","worstReservePercentPoints":40,"worstReserveWindowId":"seven_day"},"runway":{"status":"through_reset","usableRunwaySeconds":604800,"limitingWindowId":"seven_day"}}]}}]}
JSON
    ;;
  *claude-secondary)
    cat <<'JSON'
{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[{"provider":"claude","windows":[{"id":"seven_day","kind":"weekly","percentUsed":90,"percentRemaining":10,"resetsAt":"2026-08-19T18:00:00Z","pace":{"status":"ahead","reservePercentPoints":-40}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":10,"boundedBy":["seven_day"],"limitingWindowIds":["seven_day"],"pace":{"status":"ahead","worstReservePercentPoints":-40,"worstReserveWindowId":"seven_day"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":3600,"limitingWindowId":"seven_day"}}]}}]}
JSON
    ;;
  *)
    printf '{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[]}\n'
    ;;
esac
SH
  chmod +x "$fakebin/quota-axi"

  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_QUOTA_UTILIZATION_NOW="$NOW" \
    "$UTIL" --json --accounts-from-config) || fail "multi-account report failed"
  printf '%s' "$json" | jq -e '
    (.accounts | map(.account) | sort) == ["paid-primary", "paid-secondary"]
    and (.accounts[] | select(.account == "paid-primary") | .utilizationPercent) == 10
    and (.accounts[] | select(.account == "paid-secondary") | .utilizationPercent) == 90
    and (.accounts[] | select(.account == "paid-primary") | .resetCountdownSeconds) == 604800
    and (.accounts[] | select(.account == "paid-secondary") | .resetCountdownSeconds) == 86400
  ' >/dev/null || fail "claude profile windows mixed across accounts"$'\n'"$json"
  pass "CLAUDE_CONFIG_DIR profiles keep per-account windows separate"
}

test_quota_axi_failure_is_one_line_and_does_not_wedge() {
  local home fakebin out status
  home="$TMP_ROOT/fail-home"
  fakebin="$TMP_ROOT/fail-fakebin"
  mkdir -p "$home/data" "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
echo "quota-axi exploded" >&2
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$UTIL" report 2>/dev/null)
  status=$?
  expect_code 0 "$status" "a failed quota-axi read must step aside, not wedge"
  assert_contains "$out" "quota-axi skipped:" "failed reader did not name a one-line cause"
  pass "a failed provider reader names the cause and continues"
}

test_vendor_stderr_cannot_flood_the_skip_line() {
  local home fakebin out status lines longest
  home="$TMP_ROOT/flood-home"
  fakebin="$TMP_ROOT/flood-fakebin"
  mkdir -p "$home/data" "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'Uncaught (in promise) Error: provider read failed\n' >&2
i=0
while [ "$i" -lt 40 ]; do
  printf '    at Object.<anonymous> (/usr/lib/node_modules/quota-axi/dist/index.js:%s:17)\n' "$i" >&2
  i=$((i + 1))
done
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$UTIL" report 2>/dev/null)
  status=$?
  expect_code 0 "$status" "a noisy failing reader must still step aside"
  lines=$(printf '%s\n' "$out" | wc -l)
  [ "$lines" -eq 1 ] || fail "a noisy reader failure produced $lines lines instead of one"$'\n'"$out"
  longest=$(printf '%s\n' "$out" | awk '{ print length }' | sort -rn | head -1)
  [ "$longest" -le 200 ] \
    || fail "the skip line grew to $longest characters instead of staying bounded"
  assert_contains "$out" "quota: quota-axi skipped:" "the noisy failure did not name a cause"
  pass "a noisy provider reader is capped to one short skip line"
}

test_short_reader_cause_survives_the_cap_verbatim() {
  local home fakebin out
  home="$TMP_ROOT/slug-home"
  fakebin="$TMP_ROOT/slug-fakebin"
  mkdir -p "$home/data" "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'sqlite3_unavailable\n' >&2
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$UTIL" report 2>/dev/null)
  [ "$out" = "quota: quota-axi skipped: sqlite3_unavailable" ] \
    || fail "capping altered a short exact cause"$'\n'"$out"
  pass "a short exact reader cause passes through the cap unchanged"
}

test_codex_home_is_forwarded_to_quota_axi() {
  local home fakebin log json
  home="$TMP_ROOT/codex-home-fm"
  fakebin="$TMP_ROOT/codex-fakebin"
  mkdir -p "$home/data" "$fakebin" "$TMP_ROOT/alt-codex"
  log="$TMP_ROOT/codex-axi.log"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf 'CODEX_HOME=%s\n' "\${CODEX_HOME:-}" >> "$log"
cat <<'JSON'
{"schemaVersion":3,"generatedAt":"2026-08-18T18:00:00Z","providers":[{"provider":"codex","windows":[{"id":"weekly","kind":"weekly","percentUsed":5,"percentRemaining":95,"resetsAt":"2026-08-25T18:00:00Z","pace":{"status":"behind","reservePercentPoints":45}}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":95,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":45,"worstReserveWindowId":"weekly"},"runway":{"status":"through_reset","usableRunwaySeconds":604800,"limitingWindowId":"weekly"}}]}}]}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" CODEX_HOME="$TMP_ROOT/alt-codex" \
    FM_QUOTA_UTILIZATION_NOW="$NOW" "$UTIL" --json --provider codex) \
    || fail "codex-home report failed"
  assert_grep "CODEX_HOME=$TMP_ROOT/alt-codex" "$log" "CODEX_HOME was not forwarded to quota-axi"
  printf '%s' "$json" | jq -e '.accounts[0].provider == "codex" and .accounts[0].utilizationPercent == 5' \
    >/dev/null || fail "codex snapshot was not reported"$'\n'"$json"
  pass "CODEX_HOME is forwarded to quota-axi where the existing reader permits it"
}

test_tightest_window_is_binding_weekly_not_idle_session_or_named_model
test_idle_short_window_is_not_spare_when_weekly_is_ahead
test_exhausted_short_window_is_not_spare_capacity
test_reset_countdown_uses_fixed_clock_and_limiting_reset
test_unmeasurable_window_reports_unknown_not_a_literal_null
test_missing_source_names_exact_cause_and_steps_aside
test_no_hold_when_every_equivalent_candidate_is_tight
test_intake_prefers_healthier_binding_weekly_reserve
test_end_of_window_exhausted_early_versus_expired_unused
test_end_of_window_outcome_survives_replay_after_the_window_reset
test_provider_filter_scopes_the_outcomes_table
test_outcomes_mode_does_not_perform_a_live_provider_read
test_profile_skip_line_names_the_failing_account
test_provider_filter_is_forwarded_to_the_live_reader
test_provider_filter_skips_claude_profile_reads
test_multi_account_claude_profiles_do_not_mix_windows
test_quota_axi_failure_is_one_line_and_does_not_wedge
test_vendor_stderr_cannot_flood_the_skip_line
test_short_reader_cause_survives_the_cap_verbatim
test_codex_home_is_forwarded_to_quota_axi
