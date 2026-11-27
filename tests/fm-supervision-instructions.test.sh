#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

# Standalone agy assertions run with a ps that finds no process, so an ambient
# antigravity acp parent never flips them to the ACP protocol. ACP assertions
# run with a ps that reports every ancestor as T3 Code's antigravity acp server.
BLIND_PS_BIN="$TMP_ROOT/blind-ps-bin"
ACP_PS_BIN="$TMP_ROOT/acp-ps-bin"
mkdir -p "$BLIND_PS_BIN" "$ACP_PS_BIN"
printf '#!/bin/sh\nexit 1\n' > "$BLIND_PS_BIN/ps"
cat > "$ACP_PS_BIN/ps" <<'SH'
#!/bin/sh
exe='/Users/u/.t3/tools/antigravity-acp/darwin-arm64/versions/abc/antigravity'
for arg in "$@"; do
  case "$arg" in
    comm=) printf '%s\n' "$exe"; exit 0 ;;
    args=) printf '%s acp --gemini-dir /tmp/g --app-data-dir antigravity-acp\n' "$exe"; exit 0 ;;
    ppid=) printf '1\n'; exit 0 ;;
  esac
done
exit 1
SH
chmod +x "$BLIND_PS_BIN/ps" "$ACP_PS_BIN/ps"

render_harness() {  # <harness> [args...]
  local harness=$1
  shift
  if [ "$harness" = agy ]; then
    PATH="$BLIND_PS_BIN:$PATH" "$RENDER" --harness agy "$@"
  else
    "$RENDER" --harness "$harness" "$@"
  fi
}

render_agy_acp() {  # [args...]
  PATH="$ACP_PS_BIN:$PATH" "$RENDER" --harness agy "$@"
}

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: Codex foreground checkpoint." "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "Mode: Claude Stop-hook-owned supervision." "renderer printed the claude snippet too"
  assert_not_contains "$out" "Mode: Pi extension background wake." "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

# A Claude home runs the host by default, so its block carries the host
# protocol with no file, exactly as with an opting-in file; an off file
# renders the plain block.
test_supervision_host_protocol_on_a_claude_home_unless_off() {
  local home config plain hosted other
  home="$TMP_ROOT/host-home"
  config="$TMP_ROOT/host-config"
  mkdir -p "$home/state" "$config"
  : > "$config/supervision-host-off"
  plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)
  assert_not_contains "$plain" "Supervision host" "a claude home opted out by config/supervision-host-off rendered the host protocol"
  rm -f "$config/supervision-host-off"
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)
  : > "$config/supervision-host"
  assert_equals "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)" "$hosted" \
    "a claude home without config/supervision-host must render exactly what an opted-in claude home renders"
  assert_contains "$hosted" "- Supervision host: on;" "an opted-in claude home did not render the host state line"
  assert_contains "$hosted" "Mode: Claude Stop-hook-owned supervision." "the host protocol replaced the claude protocol instead of adding to it"
  assert_contains "$hosted" "supervision-host: cycle boundary" "the host protocol did not tell main how to handle a park boundary"
  assert_contains "$hosted" "never run the return from it" "the host protocol did not say a handed-back wake is not the captain's return"
  [ "$(printf '%s\n' "$hosted" | grep -vF -e '- Supervision host: on;' | head -n "$(printf '%s\n' "$plain" | wc -l)")" = "$plain" ] \
    || fail "the host protocol changed the claude block it should only append to"
  other=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness pi)
  assert_not_contains "$other" "Supervision host" "a pi primary rendered the host protocol"
  rm -f "$config/supervision-host"
  other=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness pi)
  assert_not_contains "$other" "Supervision host" "a pi primary without config/supervision-host rendered the host protocol"
  pass "renderer adds the supervision-host protocol on a claude home unless config/supervision-host-off opts it out, leaving the claude block intact"
}

# Each non-Pi arm owner gets the host protocol in its own terms, and only its
# own terms; Grok's model-owned arm command becomes the host; a home with
# config/supervision-host-off, or a non-Claude home without the file, renders exactly what
# it did before, with no tag or placeholder.
test_supervision_host_protocol_on_every_arm_owner() {
  local home config harness plain hosted body
  home="$TMP_ROOT/host-owners-home"
  config="$TMP_ROOT/host-owners-config"
  mkdir -p "$home/state" "$config"
  for harness in claude cursor agy opencode omp grok codex; do
    : > "$config/supervision-host-off"
    plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_harness "$harness")
    assert_not_contains "$plain" "Supervision host" "$harness: a home opted out by config/supervision-host-off rendered the host protocol"
    assert_not_contains "$plain" "__FM_" "$harness: a placeholder leaked into the rendered block"
    if [ "$harness" != claude ]; then
      rm -f "$config/supervision-host" "$config/supervision-host-off"
      assert_equals "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_harness "$harness")" "$plain" \
        "$harness: a home without config/supervision-host must render the plain block"
    fi
    rm -f "$config/supervision-host-off"
    : > "$config/supervision-host"
    hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_harness "$harness")
    assert_contains "$hosted" "- Supervision host: on; it takes away-posture wakes and, where the dialog mirror is verified, eligible attended wakes itself, and hands the rest to you (protocol at the end of this block)." \
      "$harness: an opted-in home did not render the host state line naming both postures it takes"
    body=$(printf '%s\n' "$hosted" | sed -n '/^Supervision host: on for this home/,$p')
    [ -n "$body" ] || fail "$harness: the host protocol is missing"
    printf '%s\n' "$body" | grep -E '^\{[a-z,]+\} ' >/dev/null && fail "$harness: a harness tag leaked into the rendered protocol: $body"
    [ "$(printf '%s\n' "$body" | grep -c 'runs the supervision host')" -eq 1 ] \
      || fail "$harness: the protocol must name exactly one arm owner: $body"
    [ "$(printf '%s\n' "$body" | grep -c '^ *Only a wake the host hands back reaches you')" -eq 1 ] \
      || fail "$harness: the protocol must name exactly one wake path: $body"
    [ "$(printf '%s\n' "$body" | grep -c '^3\. ')" -eq 1 ] || fail "$harness: the protocol must say once how the park boundary arrives: $body"
    [ "$(printf '%s\n' "$body" | grep -c '^6\. ./afk. writes only the record here')" -eq 1 ] \
      || fail "$harness: the protocol must say once what /afk does here: $body"
  done
  rm -f "$config/supervision-host"
  plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok)
  assert_contains "$plain" 'exec bin/fm-watch-arm.sh`' "grok without the file must arm the plain watcher"
  : > "$config/supervision-host-off"
  plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok)
  assert_contains "$plain" 'exec bin/fm-watch-arm.sh`' "grok with an off file must arm the plain watcher"
  rm -f "$config/supervision-host-off"
  : > "$config/supervision-host"
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok)
  assert_contains "$hosted" 'exec bin/fm-supervision-host.sh park`' "grok with the file must arm the supervision host"
  assert_not_contains "$hosted" 'fm-watch-arm.sh` call' "grok with the file must re-arm the supervision host, not the plain arm"
  assert_contains "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --repair-line)" \
    'bin/fm-supervision-host.sh park as its own Grok tracked background task' "grok's repair line must name the host"
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex)
  assert_contains "$hosted" 'FM_CODEX_WATCH_CHECKPOINT_AWAY' "codex must learn that an away checkpoint holds longer"
  assert_contains "$hosted" 'checkpoint: no actionable wake within' "codex must learn how the park boundary arrives"
  pass "renderer gives each non-Pi arm owner the host protocol in its own terms, and grok arms the host"
}

# Under antigravity acp the Stop hook never parks, so both the plain block and
# the supervision-host addendum must direct a background run_command arm and
# never promise a Stop-hook park that will not start.
test_agy_acp_renders_background_arm_protocol_and_host_lines() {
  local home config out ordinary body cli_body
  home="$TMP_ROOT/agy-acp-home"
  config="$TMP_ROOT/agy-acp-config"
  mkdir -p "$home/state" "$config"
  : > "$config/supervision-host-off"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_agy_acp)
  assert_contains "$out" "primary harness: agy" "agy-acp heading missing"
  assert_contains "$out" "Mode: Antigravity ACP background-notify supervision." "antigravity acp did not select the ACP protocol"
  assert_contains "$out" 'exec bin/fm-watch-arm.sh`' "antigravity acp without the host must arm the plain watcher"
  assert_not_contains "$out" "__FM_" "agy-acp: a placeholder leaked into the rendered block"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "background run_command" "agy-acp ordinary-wake line must re-arm a background run_command"
  assert_not_contains "$ordinary" "Stop-hook park" "agy-acp ordinary-wake line must not leave continuity to the Stop-hook park"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_agy_acp --repair-line)
  assert_contains "$out" "bin/fm-watch-arm.sh as its own background run_command task" "agy-acp repair line must arm a background run_command"

  rm -f "$config/supervision-host-off"
  : > "$config/supervision-host"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_agy_acp)
  assert_contains "$out" "Mode: Antigravity ACP background-notify supervision." "the host protocol replaced the ACP protocol"
  assert_contains "$out" 'exec bin/fm-supervision-host.sh park`' "antigravity acp with the host must arm the supervision host in the background"
  assert_not_contains "$out" "__FM_" "agy-acp host: a placeholder leaked into the rendered block"
  body=$(printf '%s\n' "$out" | sed -n '/^Supervision host: on for this home/,$p')
  [ -n "$body" ] || fail "agy-acp: the host protocol is missing"
  printf '%s\n' "$body" | grep -E '^\{[a-z,-]+\} ' >/dev/null && fail "agy-acp: a harness tag leaked into the rendered protocol: $body"
  assert_contains "$body" "(\`bin/fm-supervision-host.sh park\`) in the plain arm's place" "agy-acp host protocol must name the background host arm"
  assert_contains "$body" "background-task-completed notification" "agy-acp host protocol must deliver handed-back wakes as the background task's completion"
  assert_contains "$body" "re-arm the same background host call" "agy-acp host protocol must re-arm the background host on a cycle boundary"
  assert_contains "$body" "keep it exactly the one background call above" "agy-acp host protocol must keep the host call unbundled"
  assert_not_contains "$body" "Stop-hook park" "agy-acp host protocol must not mention the disabled Stop-hook park"
  assert_not_contains "$body" "watcher\` follow-up" "agy-acp host protocol must not promise a watcher follow-up"
  assert_not_contains "$out" "the next park starts at that turn end" "agy-acp must not promise a park at turn end"
  [ "$(printf '%s\n' "$body" | grep -c 'runs the supervision host')" -eq 1 ] || fail "agy-acp: the protocol must name exactly one arm owner: $body"
  [ "$(printf '%s\n' "$body" | grep -c '^ *Only a wake the host hands back reaches you')" -eq 1 ] || fail "agy-acp: the protocol must name exactly one wake path: $body"
  [ "$(printf '%s\n' "$body" | grep -c '^3\. ')" -eq 1 ] || fail "agy-acp: the protocol must say once how the park boundary arrives: $body"
  [ "$(printf '%s\n' "$body" | grep -c '^1\. Attended')" -eq 1 ] || fail "agy-acp: the shared agy attended line is missing: $body"
  [ "$(printf '%s\n' "$body" | grep -c '^6\. ./afk. writes only the record here')" -eq 1 ] || fail "agy-acp: the shared agy /afk line is missing: $body"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_agy_acp --repair-line)
  assert_contains "$out" "bin/fm-supervision-host.sh park as its own background run_command task" "agy-acp host repair line must arm the host in the background"

  cli_body=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" render_harness agy | sed -n '/^Supervision host: on for this home/,$p')
  assert_contains "$cli_body" "The Stop-hook park runs the supervision host" "standalone agy host protocol lost its Stop-hook park owner"
  assert_contains "$cli_body" "the next park starts at that turn end" "standalone agy host protocol lost its turn-end park boundary"
  assert_not_contains "$cli_body" "background-task-completed notification" "standalone agy host protocol borrowed the ACP background wake path"
  pass "antigravity acp renders the background-arm protocol and host lines, while standalone agy keeps the Stop-hook park"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_contains "$out" 'Mode: Codex foreground checkpoint.' "codex snippet missing"
  assert_not_contains "$out" "Source \`config/x-mode.env\`" "snippet kept the repo-relative x-mode config path"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas"
}

test_quiet_mode_stanzas() {
  local home config out
  home="$TMP_ROOT/quiet-home"
  config="$TMP_ROOT/quiet-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --afk 1 --afk-mode quiet)
  assert_contains "$out" "- Quiet mode: active" "quiet stanza missing"
  assert_contains "$out" "load /quiet" "quiet stanza did not name the /quiet skill"
  assert_contains "$out" "Ordinary captain chat does NOT exit it" "quiet stanza lost the explicit-only exit rule"
  assert_not_contains "$out" "- Away mode: active" "quiet mode incorrectly rendered as away mode"
  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1 --afk-mode quiet --repair-line)
  assert_contains "$out" "Quiet mode owns watcher supervision; load /quiet" "quiet repair line did not name /quiet"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1)
  assert_contains "$out" "- Away mode: active" "omitting --afk-mode did not default to away (regression)"
  assert_not_contains "$out" "Quiet mode" "omitting --afk-mode leaked quiet-mode text"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1 --afk-mode not-a-real-mode)
  assert_contains "$out" "- Away mode: active" "unrecognized --afk-mode value did not fall back to away"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 0)
  assert_contains "$out" "- Away/quiet mode: inactive" "inactive stanza missing"
  pass "renderer's away/quiet stanzas are mode-aware, default to away, and fall back safely on garbage input"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "watcher supervision needs Stop-owned automatic recovery" "claude pre-verification repair line is not neutral"
  assert_not_contains "$out" "is broken" "claude pre-verification repair line claimed a verified mechanism failure"
  assert_not_contains "$out" "FAILED" "claude pre-verification repair line emitted a verified failure notice"
  assert_not_contains "$out" "manual background" "claude pre-verification repair line directed a manual background arm"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude pre-verification repair line directed an arm command"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --x-mode 1 --repair-line)
  assert_contains "$out" "source '$home/config/x-mode.env' first" "x-mode repair line did not source the effective cadence config"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "x-mode codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" "pi repair line does not direct the model to the extension-owned tool"
  assert_not_contains "$out" "extension command /fm-watch-arm-pi" "pi repair line still directs the model to the human slash command"
  out=$(FM_HOME="$home" "$RENDER" --harness omp --repair-line)
  assert_contains "$out" "omp tool fm_watch_arm_omp" "omp repair line does not direct the model to the extension-owned tool"
  assert_contains "$out" ".omp/extensions/fm-primary-turnend-guard.ts" "omp repair line does not name its own turn-end extension"
  assert_not_contains "$out" "fm_watch_arm_pi" "omp repair line must not borrow the Pi tool"
  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_omp_restart_guidance_depends_on_home_vs_checkout() {
  local home out
  home="$TMP_ROOT/omp-other-home"
  mkdir -p "$home/state"

  # Home is not the firstmate checkout: relaunch through the launcher.
  out=$(FM_HOME="$home" "$RENDER" --harness omp --repair-line)
  # shellcheck disable=SC2016  # backticks are literal text
  assert_contains "$out" 'relaunch through `fm <project>`' "omp repair line must direct a non-checkout home to the fm launcher"
  assert_contains "$out" "a bare omp or /resume from the firstmate checkout does not register the extensions for this home" "omp repair line omits the bare omp warning"
  assert_not_contains "$out" "restart omp inside this home" "omp repair line still tells a non-checkout home to restart omp inside it"
  out=$(FM_HOME="$home" "$RENDER" --harness omp)
  # shellcheck disable=SC2016  # backticks are literal text
  assert_contains "$out" 'exit omp and relaunch through `fm <project>`, which sets FM_HOME and --cwd' "omp protocol must direct a non-checkout home to the fm launcher"
  assert_contains "$out" "a bare omp or /resume from the firstmate checkout does not register the extensions for this home" "omp protocol omits the bare omp warning"
  assert_not_contains "$out" "restart omp inside this home" "omp protocol still tells a non-checkout home to restart omp inside it"

  # Home is the checkout itself: today's text.
  out=$(FM_HOME="$ROOT" "$RENDER" --harness omp --repair-line)
  assert_contains "$out" "restart omp inside this home" "omp repair line lost today's wording for the checkout home"
  assert_not_contains "$out" "fm <project>" "omp repair line named the launcher for the checkout home"
  out=$(env -u FM_HOME "$RENDER" --harness omp)
  assert_contains "$out" "restart omp inside this home; pass \`-e " "omp protocol lost today's wording for the checkout home"
  assert_contains "$out" "restart omp inside this home if the extensions are not loaded" "omp protocol repair step lost today's wording for the checkout home"
  assert_not_contains "$out" "fm <project>" "omp protocol named the launcher for the checkout home"
  pass "omp restart guidance names the fm launcher only when the home is not the checkout"
}

test_cross_harness_ordinary_continuation_and_repair_matrix() {
  local ordinary out

  out=$("$RENDER" --harness pi)
  assert_contains "$out" "task-level routine outcome that says the worker is still busy" "Pi instructions omitted task-level silent no-change behavior"
  assert_contains "$out" "captain outcomes are never silent" "Pi instructions allowed silent captain outcomes"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Pi extension already owns watcher continuity" "pi ordinary-wake line does not leave continuity to the extension"
  assert_not_contains "$ordinary" "fm_watch_arm_pi" "pi ordinary-wake line incorrectly calls the recovery tool"
  out=$("$RENDER" --harness pi --repair-line)
  assert_contains "$out" "fm_watch_arm_pi" "pi recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness omp)
  assert_contains "$out" "primary harness: omp" "omp heading missing"
  assert_contains "$out" "Mode: omp (Oh My Pi) extension background wake." "omp snippet missing"
  assert_contains "$out" "the omp extension already owns watcher continuity" "omp ordinary-wake line does not leave continuity to the extension"
  assert_contains "$out" ".omp/extensions/fm-primary-omp-watch.ts" "omp snippet did not substitute its watch extension path"
  assert_not_contains "$out" "__FM_OMP_EXT__" "omp snippet left a placeholder unsubstituted"
  assert_not_contains "$out" "__FM_OMP_TURNEND_EXT__" "omp snippet left the turn-end placeholder unsubstituted"
  assert_not_contains "$out" "project trust" "omp snippet must not carry Pi's trust prerequisite"
  out=$("$RENDER" --harness omp --repair-line)
  assert_contains "$out" "fm_watch_arm_omp" "omp recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness opencode)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "plugin already owns watcher continuity" "opencode ordinary-wake line does not leave continuity to the plugin"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "opencode ordinary-wake line incorrectly calls the recovery probe"
  out=$("$RENDER" --harness opencode --repair-line)
  assert_contains "$out" "manual recovery probe" "opencode recovery line lost its manual probe"

  out=$("$RENDER" --harness claude)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Stop-owned auto-arm" "claude ordinary-wake line does not leave continuity to the Stop hook"
  assert_contains "$ordinary" "bin/fm-claude-stop-autoarm.sh" "claude ordinary-wake line lost the auto-arm script name"
  assert_contains "$ordinary" "do not arm another cycle" "claude ordinary-wake line does not forbid a model re-arm"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "claude ordinary-wake line incorrectly calls the manual arm"
  out=$("$RENDER" --harness claude --repair-line)
  assert_contains "$out" "watcher supervision needs Stop-owned automatic recovery" "claude recovery line lost its neutral automatic-recovery guidance"
  assert_not_contains "$out" "is broken" "claude recovery line claimed failure before verification"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude recovery line must not create a repeatable manual arm loop"

  out=$(render_harness agy)
  assert_contains "$out" "primary harness: agy" "agy heading missing"
  assert_contains "$out" "Mode: Antigravity Stop-hook-owned supervision." "agy mode line missing"
  assert_contains "$out" "bin/fm-turnend-guard-agy.sh" "agy block lost the Stop-hook park script name"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "bin/fm-turnend-guard-agy.sh" "agy ordinary-wake line lost the Stop-hook park script name"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "agy ordinary-wake line must not call the manual arm"
  out=$(render_harness agy --repair-line)
  assert_contains "$out" "Stop-hook park" "agy recovery line lost its Stop-hook park guidance"

  out=$("$RENDER" --harness grok)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "re-arm" "grok ordinary-wake line does not tell the model to re-arm"
  assert_contains "$ordinary" "Grok tracked background task" "grok ordinary-wake line lost tracked background ownership"
  assert_contains "$ordinary" "bin/fm-watch-arm.sh" "grok ordinary-wake line lost the background arm command"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok recovery line lost its tracked background repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok recovery line lost the arm command"

  out=$("$RENDER" --harness codex)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "next foreground" "codex ordinary-wake line lost its foreground checkpoint"
  assert_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "codex ordinary-wake line lost the checkpoint command"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "codex ordinary-wake line incorrectly uses a background arm"
  out=$("$RENDER" --harness codex --repair-line)
  assert_contains "$out" "foreground checkpoint" "codex recovery line lost its checkpoint repair"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex recovery line lost the checkpoint command"

  pass "renderer preserves every harness ordinary-continuation and missing-cycle repair path"
}

# A parked Codex session reaches the renderer through the park's own
# --capable verdict, which needs a live native session, so a fixture checkout
# stands in for it and answers that one verdict.
test_codex_park_ordinary_wake_line_leaves_continuity_to_the_stop_hook() {
  local code home out ordinary
  code="$TMP_ROOT/codex-park-code"
  home="$TMP_ROOT/codex-park-home"
  mkdir -p "$code/docs" "$home/state"
  cp -R "$ROOT/bin" "$code/bin"
  cp -R "$ROOT/docs/supervision-protocols" "$code/docs/supervision-protocols"
  cat > "$code/bin/fm-codex-stop-park.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --capable ]
SH
  chmod +x "$code/bin/fm-codex-stop-park.sh"
  out=$(FM_HOME="$home" "$code/bin/fm-supervision-instructions.sh" --harness codex)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "bin/fm-codex-stop-park.sh" "a parked codex ordinary-wake line lost the Stop-hook owner"
  assert_contains "$ordinary" "do not arm another cycle" "a parked codex ordinary-wake line does not forbid a model re-arm"
  assert_not_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "a parked codex ordinary-wake line must not send the model to a foreground checkpoint"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$code/bin/fm-codex-stop-park.sh"
  ordinary=$(FM_HOME="$home" "$code/bin/fm-supervision-instructions.sh" --harness codex | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "a codex session without the park must keep the foreground checkpoint line"
  pass "a parked codex session's ordinary-wake line names the Stop hook and never the foreground checkpoint"
}

test_pi_signed_preserves_identity_with_pi_supervision_protocol() {
  local out ordinary
  out=$("$RENDER" --harness pi-signed)
  assert_contains "$out" "primary harness: pi-signed" \
    "pi-signed supervision normalized the visible runtime identity to pi"
  assert_contains "$out" "Mode: Pi extension background wake." \
    "pi-signed did not reuse Pi's authoritative supervision protocol"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Pi extension already owns watcher continuity" \
    "pi-signed ordinary-wake semantics diverged from Pi"
  out=$("$RENDER" --harness pi-signed --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" \
    "pi-signed repair semantics diverged from Pi"
  pass "pi-signed keeps its identity while sharing Pi's supervision protocol"
}

test_grok_is_background_notify() {
  local out
  out=$("$RENDER" --harness grok)
  assert_contains "$out" "Mode: Grok background-notify supervision." "grok snippet missing background-notify mode"
  assert_contains "$out" "background: true" "grok snippet missing tracked background tool instruction"
  assert_contains "$out" "synthetic_reason: task_completed" "grok snippet missing auto-wake synthetic prompt detail"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok snippet missing watcher arm"
  assert_not_contains "$out" "__FM_X_MODE_ENV" "renderer leaked an x-mode path placeholder"
  assert_not_contains "$out" "foreground checkpoint" "grok snippet must not be Codex-style foreground checkpoint"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok repair line is not background-notify shaped"
  pass "grok supervision is Claude-shaped background notify with passive Stop-hook backstop"
}

test_grok_command_sources_effective_config() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --x-mode 1)
  assert_contains "$out" "[ -f '$config/x-mode.env' ] && . '$config/x-mode.env'; exec bin/fm-watch-arm.sh" "grok arm command did not use the effective x-mode config path"
  pass "grok rendered command sources the effective x-mode config"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend -e $watch" "pi snippet did not render both effective extension launch paths"
  assert_contains "$out" "The turn-end guard extension lives at \`$turnend\`" "pi snippet did not render the turn-end guard extension path"
  assert_contains "$out" "The watcher extension lives at \`$watch\`" "pi snippet did not render the watcher extension path"
  assert_contains "$out" "MAIN must not re-drain, re-run, or acknowledge it" "pi snippet lost merged-event ownership"
  assert_contains "$out" "MAIN applies judgment about whether and how to surface, summarize, reference, or incorporate a merged sailboat outcome" "pi snippet imposed a mechanical sailboat treatment"
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "state/fm-primary-pi-watch.ts" "pi snippet kept the old generated state-relative extension path"
  pass "pi supervision snippet renders the effective extension path"
}

test_literal_paths_in_rendered_snippets() {
  local name home harness out quoted_config
  for name in normal 'R&D "double" '\''single'\'' home'; do
    home="$TMP_ROOT/$name"
    mkdir -p "$home/config" "$home/state"
    : > "$home/config/supervision-host-off"
    quoted_config="'$(printf '%s' "$home/config/x-mode.env" | sed "s/'/'\\\\''/g")'"
    for harness in pi pi-signed omp codex grok cursor opencode claude; do
      out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$RENDER" --harness "$harness" --x-mode 1)
      assert_not_contains "$out" '__FM_' "$harness: literal path leaked a placeholder"
      case "$harness" in
        pi|pi-signed)
          assert_contains "$out" "$home/.pi/extensions/fm-primary-pi-watch.ts" "Pi watch path changed"
          assert_contains "$out" "$home/.pi/extensions/fm-primary-turnend-guard.ts" "Pi turn-end path changed"
          ;;
        omp)
          assert_contains "$out" "$home/.omp/extensions/fm-primary-omp-watch.ts" "omp watch path changed"
          assert_contains "$out" "$home/.omp/extensions/fm-primary-turnend-guard.ts" "omp turn-end path changed"
          ;;
        grok)
          assert_contains "$out" "[ -f $quoted_config ] && . $quoted_config; exec bin/fm-watch-arm.sh" "quoted config path changed"
          ;;
      esac
    done
  done
  pass "snippets preserve literal ampersands, quotes and spaces in paths across primary harnesses"
}

test_literal_paths_in_rendered_snippets
test_supervision_host_protocol_on_a_claude_home_unless_off
test_supervision_host_protocol_on_every_arm_owner
test_agy_acp_renders_background_arm_protocol_and_host_lines
test_selected_harness_block_only
test_unknown_fallback
test_conditional_stanzas
test_quiet_mode_stanzas
test_repair_lines
test_omp_restart_guidance_depends_on_home_vs_checkout
test_cross_harness_ordinary_continuation_and_repair_matrix
test_codex_park_ordinary_wake_line_leaves_continuity_to_the_stop_hook
test_pi_signed_preserves_identity_with_pi_supervision_protocol
test_grok_is_background_notify
test_grok_command_sources_effective_config
test_pi_snippet_uses_effective_extension_path
