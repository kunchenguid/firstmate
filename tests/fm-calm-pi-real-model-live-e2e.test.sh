#!/usr/bin/env bash
# Opt-in credentialed Pi/Herdr proof for Calm's real-model current-step presentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CALM_PI_REAL_MODEL_E2E herdr jq pi python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name calm-hide-thinking-tools-regression)
TMP_ROOT=$(fm_test_tmproot fm-calm-pi-real-model-live-e2e)
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
SESSIONS="$TMP_ROOT/sessions"
EVIDENCE="$TMP_ROOT/evidence"
PANE=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || rc=1
  fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

mkdir -p "$PROJECT" "$HOME_DIR/config" "$SESSIONS" "$EVIDENCE"
printf 'on\n' >"$HOME_DIR/config/calm"
printf 'REAL_TOOL_OUTPUT_ALPHA\n' >"$PROJECT/.calm-probe-a"
printf 'REAL_TOOL_OUTPUT_BETA\n' >"$PROJECT/.calm-probe-b"
printf 'REAL_TOOL_OUTPUT_GAMMA\n' >"$PROJECT/.calm-probe-c"
printf 'FINAL_SOURCE_CONFIRMATION\n' >"$PROJECT/.calm-final"

pi auth check --provider openai-codex --model gpt-5.6-sol --json >/dev/null 2>&1 \
  || fail "the existing user Pi configuration is not authenticated for openai-codex/gpt-5.6-sol"

OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$PROJECT" --label calm-real-model --no-focus)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
PI_CMD=$(printf 'env FM_HOME=%q pi --approve --no-context-files --no-extensions -e %q -e %q -e %q -e %q --model openai-codex/gpt-5.6-sol --thinking xhigh --session-dir %q' \
  "$HOME_DIR" \
  "$ROOT/.pi/extensions/fm-branch-supervision.ts" \
  "$ROOT/.pi/extensions/fm-calm.ts" \
  "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" \
  "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" \
  "$SESSIONS")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "$PI_CMD" >/dev/null \
  || fail "could not launch authenticated Pi in the isolated Herdr pane"

pane_text() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" \
    --source recent --lines 160 2>/dev/null || true
}

ready=0
for _ in $(seq 1 300); do
  text=$(pane_text)
  if printf '%s' "$text" | grep -Fq '(openai-codex) gpt-5.6-sol'; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" -eq 1 ] || { printf '%s\n' "$text" >&2; fail "authenticated Pi did not reach its ready composer"; }

PROMPT='Use exactly one read call per assistant turn. Before reading .calm-probe-a, output as commentary the exact token formed by concatenating REAL_, COMMENTARY_, ONE. Before reading .calm-probe-b, output as commentary the exact token formed by concatenating REAL_, COMMENTARY_, TWO. Before reading .calm-probe-c, output as commentary the exact token formed by concatenating REAL_, COMMENTARY_, THREE. Then read .calm-final and, after confirming its content, reply with the exact token formed by concatenating REAL_, MODEL_, FINAL_, RESPONSE.'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" "$PROMPT" >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null

seen_step_numbers=
first_commentary_step=
commentary_persisted_after_transition=0
ordered_frame_count=0
settled_polls=0
final_text=
step_titles="$EVIDENCE/step-titles.txt"
: >"$step_titles"
frame=0
for _ in $(seq 1 1200); do
  text=$(pane_text)
  frame=$((frame + 1))
  printf '%s\n' "$text" >"$EVIDENCE/frame-$frame.txt"
  step_count=$( (printf '%s\n' "$text" | grep -Eo 'Step [0-9]+:' || true) | wc -l | tr -d ' ')
  printf '%s\n' "$text" | grep -Fq 'Thinking...' \
    && fail "external pane frame $frame showed Pi's thinking placeholder while Calm was on"
  printf '%s\n' "$text" | grep -Fq 'REAL_TOOL_OUTPUT_' \
    && fail "external pane frame $frame showed a tool result while Calm was on"
  if [ "$step_count" -gt 1 ]; then
    printf '%s\n' "$text" >&2
    fail "external pane frame $frame accumulated $step_count numbered step rows"
  fi
  step_line=$(printf '%s\n' "$text" | grep -E 'Step [0-9]+:' | tail -1 || true)
  if [ -n "$step_line" ]; then
    step_number=$(printf '%s\n' "$step_line" | sed -E 's/.*Step ([0-9]+):.*/\1/')
    if ! printf '%s\n' "$seen_step_numbers" | grep -Fxq "$step_number"; then
      seen_step_numbers=$(printf '%s\n%s' "$seen_step_numbers" "$step_number")
      step_title=$(printf '%s\n' "$step_line" | sed -E 's/.*Step [0-9]+:[[:space:]]*//; s/[[:space:]]+$//')
      [ "${#step_title}" -lt 8 ] || printf '%s\n' "$step_title" >>"$step_titles"
      printf 'proof - working Step %s: %s\n' "$step_number" "$step_line"
    fi
    printf '%s\n' "$step_line" | grep -Fq 'REAL_COMMENTARY_' \
      && fail "real assistant commentary was promoted into the transient step title"

    ship_line_number=$(printf '%s\n' "$text" | grep -Fn '╲▁▁▁╱' | tail -1 | cut -d: -f1)
    step_line_number=$(printf '%s\n' "$text" | grep -En 'Step [0-9]+:' | tail -1 | cut -d: -f1)
    [ -n "$ship_line_number" ] && [ "$step_line_number" -lt "$ship_line_number" ] \
      || fail "external pane frame $frame did not place the current step above the sailing ship"

    for word in ONE TWO THREE; do
      marker="REAL_COMMENTARY_$word"
      if printf '%s' "$text" | grep -Fq "$marker"; then
        marker_count=$(printf '%s\n' "$text" | grep -Fc "$marker")
        [ "$marker_count" -eq 1 ] || fail "external pane frame $frame showed $marker $marker_count times"
        marker_line_number=$(printf '%s\n' "$text" | grep -Fn "$marker" | tail -1 | cut -d: -f1)
        [ "$marker_line_number" -lt "$step_line_number" ] \
          || fail "external pane frame $frame placed $marker below the current step"
        ordered_frame_count=$((ordered_frame_count + 1))
      fi
    done
    if printf '%s' "$text" | grep -Fq 'REAL_COMMENTARY_ONE'; then
      if [ -z "$first_commentary_step" ]; then
        first_commentary_step=$step_number
      elif [ "$step_number" -gt "$first_commentary_step" ] && [ "$commentary_persisted_after_transition" -eq 0 ]; then
        commentary_persisted_after_transition=1
        printf 'proof - retained REAL_COMMENTARY_ONE once above later Step %s and above the ship\n' "$step_number"
      fi
    fi
  fi
  if printf '%s' "$text" | grep -Fq 'REAL_MODEL_FINAL_RESPONSE' && [ "$step_count" -eq 0 ]; then
    settled_polls=$((settled_polls + 1))
    final_text=$text
    [ "$settled_polls" -ge 3 ] && break
  else
    settled_polls=0
  fi
  sleep 0.1
done
[ "$settled_polls" -ge 3 ] || { printf '%s\n' "$text" >&2; fail "real model did not settle to a final response without a step row"; }
unique_steps=$(printf '%s\n' "$seen_step_numbers" | grep -Ec '^[0-9]+$' || true)
[ "$unique_steps" -ge 2 ] \
  || fail "external pane observed only $unique_steps distinct numbered steps"
[ "$ordered_frame_count" -ge 2 ] \
  || fail "external pane produced only $ordered_frame_count commentary/step/ship ordering observations"
for word in ONE TWO THREE; do
  marker="REAL_COMMENTARY_$word"
  [ "$(printf '%s\n' "$final_text" | grep -Fc "$marker")" -eq 1 ] \
    || fail "settled real-model transcript did not retain $marker exactly once"
done
printf '%s' "$final_text" | grep -Fq '╲▁▁▁╱' \
  && fail "settled real-model transcript retained the sailing animation"
printf '%s' "$final_text" | grep -Fq 'REAL_TOOL_OUTPUT_' \
  && fail "settled real-model transcript retained a tool result while Calm was on"

assert_settled_history() { # <frame> <label> [require-tool-output]
  local history=$1 label=$2 require_tool_output=${3:-0} word marker title final_count
  printf '%s\n' "$history" | grep -Eq 'Step [0-9]+:' \
    && fail "$label restored a numbered transient step"
  printf '%s\n' "$history" | grep -Fq '╲▁▁▁╱' \
    && fail "$label retained the sailing animation"
  while IFS= read -r title; do
    [ -z "$title" ] && continue
    printf '%s\n' "$history" | grep -Fq -- "$title" \
      && fail "$label resurrected superseded historical step title: $title"
  done <"$step_titles"
  for word in ONE TWO THREE; do
    marker="REAL_COMMENTARY_$word"
    [ "$(printf '%s\n' "$history" | grep -Fc "$marker")" -eq 1 ] \
      || fail "$label did not retain $marker exactly once"
  done
  final_count=$(printf '%s\n' "$history" | grep -Fc 'REAL_MODEL_FINAL_RESPONSE')
  [ "$final_count" -eq 1 ] \
    || { printf '%s\n' "$history" >&2; fail "$label retained the final response $final_count times instead of once"; }
  for marker in REAL_TOOL_OUTPUT_ALPHA REAL_TOOL_OUTPUT_BETA REAL_TOOL_OUTPUT_GAMMA; do
    if [ "$require_tool_output" -eq 1 ]; then
      printf '%s\n' "$history" | grep -Fq "$marker" \
        || fail "$label did not restore Calm-off tool output $marker"
    else
      printf '%s\n' "$history" | grep -Fq "$marker" \
        && fail "$label showed Calm-on tool output $marker"
    fi
  done
  printf '%s\n' "$history" | grep -Fq 'Thinking...' \
    && fail "$label showed Pi's thinking placeholder"
}

# Exercise the exact divergent lifecycle against the authenticated, persisted model
# history: reload once, then toggle Calm off/on twice. Explicitly expand thinking and
# tools while off so neither fallback route can hide a resurrected title.
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" /reload >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null
sleep 3
reloaded_text=$(pane_text)
assert_settled_history "$reloaded_text" "real-model reload"
printf 'proof - reload retained commentary/final output once and no historical step title\n'

expanded_fallback=0
for expected in off on off on; do
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" /calm >/dev/null
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null
  matched=0
  for _ in $(seq 1 100); do
    [ "$(cat "$HOME_DIR/config/calm" 2>/dev/null || true)" = "$expected" ] && { matched=1; break; }
    sleep 0.05
  done
  [ "$matched" -eq 1 ] || fail "real-model /calm did not persist $expected"
  sleep 0.3
  if [ "$expected" = off ]; then
    if [ "$expanded_fallback" -eq 0 ]; then
      "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" ctrl+t >/dev/null
      "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" ctrl+o >/dev/null
      expanded_fallback=1
    fi
    sleep 0.3
    toggled_text=$(pane_text)
    assert_settled_history "$toggled_text" "real-model Calm-off expanded fallback" 1
  else
    toggled_text=$(pane_text)
    assert_settled_history "$toggled_text" "real-model Calm-on redraw"
  fi
done
printf 'proof - two Calm off/on cycles restored tool output only while off and suppressed it again on, without historical step titles\n'

session_file=$(find "$SESSIONS" -type f -name '*.jsonl' \
  -exec grep -l 'REAL_MODEL_FINAL_RESPONSE' {} + 2>/dev/null | head -1)
[ -n "$session_file" ] || fail "real Pi did not persist the authenticated model session"
grep -Fq '.calm-probe-a' "$session_file" || fail "first real-model tool turn was not persisted"
grep -Fq '.calm-probe-b' "$session_file" || fail "second real-model tool turn was not persisted"
grep -Fq '.calm-probe-c' "$session_file" || fail "third real-model tool turn was not persisted"
for word in ONE TWO THREE; do
  marker="REAL_COMMENTARY_$word"
  [ "$(grep -Fo "$marker" "$session_file" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "real-model session history did not preserve $marker exactly once"
done

printf 'proof - final commentary: REAL_COMMENTARY_ONE, REAL_COMMENTARY_TWO, REAL_COMMENTARY_THREE (one each)\n'
printf 'proof - final: %s\n' "$(printf '%s\n' "$final_text" | grep -F 'REAL_MODEL_FINAL_RESPONSE' | tail -1)"
printf 'ok - real Pi %s with gpt-5.6-sol xhigh and the full Firstmate extension set externally showed one numbered step at a time across %s steps, retained commentary and the final answer once, suppressed thinking placeholders and tool results whenever Calm was on, restored tools off, and kept every superseded title hidden through reload plus two Calm cycles\n' \
  "$(pi --version)" "$unique_steps"
