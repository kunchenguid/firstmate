#!/usr/bin/env bash
# tests/composer-claude-titled-rule-fixture.sh - the ONE shared fixture for
# task afk-composer-read-claude-herdr (incident 2026-09-05 07:02-07:07 PDT):
# the away daemon's supervisor composer read stayed "unknown" against an
# idle primary pane, so injection deferred, the away daemon's undeliverable
# path never rewakes the primary under Claude's Stop hook, and the 301s wedge
# alarm fired.
#
# Current claude draws its idle composer as a bare `❯` between two `─`
# rules (the same "separated" shape bin/fm-composer-lib.sh already proves for
# pi), but embeds the session/task title IN the top rule itself
# ("──...── First ─"), verified live via `herdr pane read w2H:p1 --ansi`.
# Structurally byte-for-byte sanitized from that live capture (the real
# session title, cost, and context figures, and unrelated scrollback above the
# composer are replaced with innocuous placeholders); everything that made the
# old `_fm_composer_pi_separator_row` misread the titled top rule as
# unrecognized, and its still-recognized plain bottom rule as an orphaned
# trailing separator, is preserved exactly.
#
# Shared by tests/fm-composer-lib.test.sh (the composer verdict must read
# `empty`) and tests/fm-daemon.test.sh (the same idle screen's footer must
# also read as NOT busy), so both consume the identical fixture rather than
# two copies that could drift apart.

# fm_test_fixture_claude_titled_rule_screen: the minimal idle screen - just
# the titled composer pair, no notification bar or footer above/below it.
fm_test_fixture_claude_titled_rule_screen() {
  local nbsp; nbsp=$(printf '\302\240')
  printf '%s\n' \
    '──────────────────────────────────────────────────────────────────────────── Test ─' \
    "❯${nbsp}" \
    '────────────────────────────────────────────────────────────────────────────────────'
}

# fm_test_fixture_claude_titled_rule_screen_with_footer: the full idle screen
# as captured live - a highlighted "N new messages" notification bar above the
# composer (real capture: "21 new messages (ctrl+End) ↓"; here reduced to
# one message per the incident's own report), and the two-line status/footer
# below it (task/branch/model summary, then the permission-mode-and-shell-
# count line the incident report names: "1 shell still running").
fm_test_fixture_claude_titled_rule_screen_with_footer() {
  local esc nbsp; esc=$(printf '\033'); nbsp=$(printf '\302\240')
  # shellcheck disable=SC2016  # the literal dollar figure is fixture text, not an expansion
  printf '%s\n' \
    '' \
    "${esc}[38;2;17;24;39m${esc}[48;2;240;240;240m 1 new message (ctrl+End) ↓ ${esc}[0m" \
    '' \
    '──────────────────────────────────────────────────────────────────────────── Test ─' \
    "❯${nbsp}" \
    '────────────────────────────────────────────────────────────────────────────────────' \
    '  Test · MAIN · model/effort · default · 50% · 5h10%/7d20% · $0.00' \
    '  ⏵⏵ bypass permissions on · 1 shell still running · ← 1 agent'
}
