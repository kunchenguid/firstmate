#!/usr/bin/env bash
# tests/fm-context-ceiling-codex-live.test.sh - live guard: the context ceiling a
# real spawn emits makes the real installed Codex compact at that size.
#
# Opt-in (FM_LIVE_CONTEXT_CEILING_CODEX=1 or FM_LIVE=1) because it submits two
# short prompts. The guard takes the -c override from the launch a real
# bin/fm-spawn.sh emitted into a fake pane for a 20000-token ceiling, runs the
# installed codex with exactly those arguments on a prompt whose context passes
# that size, and requires a `compacted` record in that session's rollout. A
# control run of the same prompt without the override must record none, so the
# compaction is proven to come from the setting rather than the model's window.
# Refresh the dated record in docs/verification/runtime-backends.md from this
# guard and tests/fm-context-ceiling-live.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_LIVE_CONTEXT_CEILING_CODEX codex jq

TMP_ROOT=$(fm_test_tmproot fm-context-ceiling-codex-live)
CODEX_VERSION=$(codex --version 2>/dev/null | head -1)
CODEX_SESSIONS="${CODEX_HOME:-$HOME/.codex}/sessions"
MODEL=${FM_LIVE_CONTEXT_CEILING_CODEX_MODEL:-gpt-5.6-luna}

# Print, one per line, the -c overrides the spawned codex worker received for
# the context ceiling.
emitted_ceiling_args() {
  local dir="$TMP_ROOT/spawn" home proj wt fakebin launchlog panelog id=live-codex-a1 out
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  launchlog="$dir/launch.log"
  panelog="$dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" wt-live-codex
  fm_test_spawn_brief "$home" "$id"
  : >"$launchlog"
  : >"$panelog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode local-only --yolo off --context-ceiling 20000 2>&1) \
    || fail "codex worker spawn failed: $out"
  cat >"$fakebin/codex" <<'SH'
#!/bin/sh
for a do printf '%s\n' "$a"; done
SH
  chmod +x "$fakebin/codex"
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(grep '^export ' "$panelog")
$(cat "$launchlog")" | awk 'prev == "-c" && /^model_auto_compact_token_limit=/ { print "-c"; print } { prev = $0 }'
}

# Run the prompt in a fresh scratch repository and print how many compacted
# records that session's rollout holds.
# Standard input is closed: codex exec reads a piped one as part of the
# prompt, so an inherited channel would change what the run measures.
compactions() {  # <label> [-c override...]
  local label=$1 scratch rollout i
  shift
  scratch=$(mktemp -d "$TMP_ROOT/$label.XXXXXX")
  git -C "$scratch" init -q
  for i in $(seq 1 1500); do
    printf 'line %s: the quick brown fox jumps over the lazy dog while the ledger records usage\n' "$i"
  done >"$scratch/big.txt"
  (cd "$scratch" && codex exec --skip-git-repo-check -m "$MODEL" -c 'model_reasoning_effort="low"' "$@" \
    --dangerously-bypass-approvals-and-sandbox \
    'Run: cat big.txt. Then run: cat big.txt again. Then reply with only the word DONE.' </dev/null) >"$scratch.out" 2>&1 \
    || fail "codex $CODEX_VERSION: the $label run failed: $(tail -5 "$scratch.out")"
  rollout=$(grep -rlF "\"cwd\":\"$scratch\"" "$CODEX_SESSIONS" 2>/dev/null | head -1)
  [ -n "$rollout" ] || rollout=$(grep -rlF "$scratch" "$CODEX_SESSIONS" 2>/dev/null | head -1)
  [ -n "$rollout" ] || fail "codex $CODEX_VERSION: no rollout recorded the $label session under $CODEX_SESSIONS"
  jq -r 'select(.type == "compacted") | .type' "$rollout" | wc -l | tr -d ' '
}

test_codex_compacts_at_the_ceiling() {
  local args with control
  args=$(emitted_ceiling_args)
  assert_equals $'-c\nmodel_auto_compact_token_limit=20000' "$args" "the spawn must emit the ceiling as one -c override"
  # shellcheck disable=SC2086 # the two emitted words are the override, one per line
  with=$(IFS=$'\n'; compactions ceiling $args)
  control=$(compactions control)
  [ "$with" -ge 1 ] || fail "codex $CODEX_VERSION: the session launched with the emitted ceiling never compacted"
  [ "$control" -eq 0 ] || fail "codex $CODEX_VERSION: the control session compacted too ($control), so the prompt does not separate the ceiling from the window"
  pass "codex $CODEX_VERSION: the emitted 20000 ceiling compacts the session ($with); the same prompt without it does not"
}

test_codex_compacts_at_the_ceiling
