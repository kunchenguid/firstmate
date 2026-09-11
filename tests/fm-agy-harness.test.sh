#!/usr/bin/env bash
# Portable agy detection, control, busy-state and composer contracts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

tmp=$(fm_test_tmproot fm-agy)
out=$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
[ "$out" = agy ] || fail "native agy marker lost to inherited Claude marker"
out=$(ANTIGRAVITY_AGENT=0 CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
[ "$out" = claude ] || fail "invalid agy marker claimed identity"
# A real renamed executable exercises ancestry without mocking ps output.
cp "$(command -v bash)" "$tmp/agy"
# shellcheck disable=SC2016  # $1 belongs to the inner bash -c process.
out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u GEMINI_CLI -u CURSOR_AGENT \
  -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE \
  -u ROVODEV_CLI "$tmp/agy" -c '"$1"; :' _ "$ROOT/bin/fm-harness.sh")
[ "$out" = agy ] || fail "real agy-named parent was not detected"
pass "agy native marker and executable ancestry work independently"

fm_control_harness_supports_kind agy ship || fail "agy ship refused"
fm_control_harness_supports_kind agy scout || fail "agy scout refused"
if fm_control_harness_supports_kind agy secondmate; then fail "agy secondmate accepted"; fi
[ "$(fm_control_interrupt_key agy)" = Escape ] || fail "wrong interrupt"
[ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "wrong interrupt repeat"
[ "$(fm_control_exit_command agy)" = /exit ] || fail "wrong exit"
fm_backend_busy_state() { printf busy; }
[ "$(fm_busy_classify herdr test agy task "$tmp" 'esc to cancel')" = 'unknown agy-unverified' ] \
  || fail "unverified busy source became trusted"
pass "agy lifecycle is worker-only and busy state remains unknown"

caps=$'styled=1\nidentity=1'
screen=$'────────────\n>\n────────────\n? for shortcuts    accept-edits · Gemini 3.8 Flash · low'
classify() { fm_composer_classify_screen "$caps" "$1" '' "${2-}"; }
[ "$(classify "$screen" $'agy\tidle')" = empty ] || fail "idle agy composer not empty"
[ "$(classify "${screen/>/> hello}" $'agy\tidle')" = pending ] || fail "typed input lost"
[ "$(classify "$screen")" = need-identity ] || fail "identity probe not requested"
[ "$(classify "$screen" probe-absent)" = unknown ] || fail "dead shell accepted"
[ "$(classify "$screen" $'agy\tblocked')" = unknown ] || fail "blocked dialog accepted"
[ "$(classify "${screen/\? for shortcuts/Keyboard: esc Close}" $'agy\tidle')" = unknown ] \
  || fail "help dialog accepted"
[ "$(classify "${screen/────────────/missing border}" $'agy\tidle')" = unknown ] \
  || fail "missing input container accepted"
pass "agy composer requires identity, container and footer together"

# Live 2026-09-10 shapes from a real spawn: the settled prompt-interactive
# composer keeps agy's palette-dim (38;5;8) mode placeholder in the input row,
# while typed input renders bold and drops the shortcuts hint from the footer.
esc=$'\033'
rule='──────────────────────────────────────────'
placeholder_row="${esc}[0m${esc}[38;5;12m>${esc}[0m ${esc}[0m${esc}[38;5;8mAccept-edits mode: file edits auto-approved (shift+tab to cycle)${esc}[0m"
bold_typed_row="${esc}[0m${esc}[1m> hello${esc}[0m"
foot_hint='? for shortcuts                accept-edits · Gemini 3.8 Flash · low'
foot_typed='accept-edits · Gemini 3.8 Flash · low'
placeholder_screen="$rule
$placeholder_row
$rule
$foot_hint"
typed_screen="$rule
$bold_typed_row
$rule
$foot_typed"
[ "$(classify "$placeholder_screen" $'agy\tidle')" = empty ] || fail "placeholder read as typed input"
[ "$(classify "$placeholder_screen" $'agy\tworking')" = unknown ] || fail "working placeholder accepted"
[ "$(classify "$typed_screen" $'agy\tidle')" = pending ] || fail "bold typed input lost"
[ "$(classify "$typed_screen" probe-absent)" = unknown ] || fail "typed input accepted without identity"
broken_foot="${typed_screen/accept-edits · /accept-edits }"
[ "$(classify "$broken_foot" $'agy\tidle')" = unknown ] || fail "typed input accepted without a footer"
plain_caps=$'styled=0\nidentity=1'
plain_classify() { fm_composer_classify_screen "$plain_caps" "$1" '' "${2-}"; }
[ "$(plain_classify "$placeholder_screen" $'agy\tidle')" = unknown ] \
  || fail "unstyled placeholder trusted without styling proof"
pass "agy palette placeholder stays ghost while typed input stays pending"

# Live 2026-09-11 shapes from a real Antigravity CLI 1.2.1 spawn: the footer
# became a constant status bar (host:pwd | ctx: meter | quota windows | model)
# that no longer changes with typed input.
bar_idle_row="${esc}[0m${esc}[38;5;12m>${esc}[0m"
bar_typed_row="${esc}[0m${esc}[1m> hello${esc}[0m"
foot_bar='marcin@ai-workspace:/tmp | ctx: 2% (21.1k/1M) | 5h: 5% (resets 15:24) · 7d: 20% | Gemini 3.8 Flash (High)'
bar_idle_screen="$rule
$bar_idle_row
$rule
$foot_bar"
bar_typed_screen="$rule
$bar_typed_row
$rule
$foot_bar"
[ "$(classify "$bar_idle_screen" $'agy\tidle')" = empty ] || fail "1.2.1 bar-footer idle not empty"
[ "$(classify "$bar_typed_screen" $'agy\tidle')" = pending ] || fail "1.2.1 bar-footer typed input lost"
[ "$(classify "$bar_typed_screen" $'agy\tworking')" = unknown ] || fail "1.2.1 working bar-footer accepted"
broken_bar="${foot_bar/| ctx: /| ctxt: }"
broken_bar_screen="$rule
$bar_idle_row
$rule
$broken_bar"
[ "$(classify "$broken_bar_screen" $'agy\tidle')" = unknown ] || fail "bar footer accepted without its ctx meter"
pass "agy 1.2.1 status-bar footer carries both idle and typed verdicts"
