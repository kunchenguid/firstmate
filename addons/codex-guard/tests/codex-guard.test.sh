#!/usr/bin/env bash
# End to end: install the delete, kill and read guards and this adapter into a throwaway HOME, then run commands the way
# Codex 0.159 does (bash -lc '<snapshot wrapper>' ending in exec bash -c '<command>', BASH_ENV from config.toml).
# Only this test's own sleep is signalled, and every command the guards must block is harmless if it ran.
# shellcheck disable=SC2016 # the cases are literal commands
set -euo pipefail; unset FM_TASK_ID FM_TASK_INBOX FM_HOME XDG_DATA_HOME CODEX_HOME
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P); ROOT=$(dirname "$ADDON")
T=$(mktemp -d); SLEEP=
trap '[ -z "$SLEEP" ] || kill "$SLEEP" 2>/dev/null || true; rm -rf -- "$T"' EXIT
H=$T/home; W=$T/work
mkdir -p "$H/.codex" "$H/.claude" "$H/fm-probe" "$T/fm/state" "$T/fm/bin" "$W"
git -C "$W" init -q
printf 'model = "m"\n\n[projects."/x"]\ntrust_level = "trusted"\n' > "$H/.codex/config.toml"; cp "$H/.codex/config.toml" "$T/config.orig"
echo FIXTURE-NOT-A-SECRET > "$H/.codex/auth.json"
printf '#!/bin/sh\necho "registered: $1"\n' > "$T/fm/bin/fm-check-register.sh"; chmod +x "$T/fm/bin/fm-check-register.sh"
fail=0; ok() { echo "ok: $*"; }; no() { echo "FAIL: $*"; fail=1; }
HOME=$H "$ROOT/delete-guard/install.sh" "$T/fm" >/dev/null && HOME=$H "$ROOT/kill-guard/install.sh" >/dev/null && HOME=$H "$ROOT/read-guard/install.sh" >/dev/null

HOME=$H "$ADDON/install.sh" --dry-run >/dev/null
cmp -s "$H/.codex/config.toml" "$T/config.orig" && [ ! -e "$H/.local/share/fm-codex-guard" ] && ok "dry run writes nothing" || no "dry run wrote"
HOME=$H "$ADDON/install.sh" >/dev/null && HOME=$H "$ADDON/install.sh" > "$T/re.out"
[ "$(grep -c '^unchanged: ' "$T/re.out")" -eq 2 ] && ok "reinstall changes nothing" || no "reinstall: $(cat "$T/re.out")"
ENV=$(python3 -c 'import sys, tomllib; c = tomllib.load(open(sys.argv[1], "rb")); assert c["projects"]["/x"]["trust_level"] == "trusted"; print(c["shell_environment_policy"]["set"]["BASH_ENV"])' "$H/.codex/config.toml") \
  && [ "$ENV" = "$H/.local/share/fm-codex-guard/bash-env.sh" ] && ok "config.toml parses, keeps its tables and sets BASH_ENV" || no "config.toml: $ENV"

as_codex() { # <command>: run it as Codex runs an agent command, from the worktree root; sets rc, out, err
  local wrapper
  wrapper=$(printf '__CODEX_SNAPSHOT_OVERRIDE_SET_0="${BASH_ENV+x}"\nexec bash -c %q' "$1")
  rc=0; out=$(cd "$W" && HOME=$H BASH_ENV=$ENV FM_TASK_ID=codex-guard-test bash -lc "$wrapper" 2>"$T/err") || rc=$?; err=$(cat "$T/err")
}
blocked() { as_codex "$1"; [ "$rc" -eq 2 ] && [[ "$err" == *"$2"* && "$out" != *FIXTURE* ]] && ok "blocked: $1" || no "not blocked: $1 (rc=$rc) $out $err"; }

as_codex 'echo "env=[${BASH_ENV-}]"; printf hi'
[ "$rc" -eq 0 ] && [ "$out" = $'env=[]\nhi' ] && [ -z "$err" ] && ok "a normal command runs, without BASH_ENV for its children" || no "normal command: rc=$rc $out $err"
blocked 'rm -rf ~/fm-probe' 'BLOCKED by the fleet delete guard'
[ -d "$H/fm-probe" ] && jq -e 'select(.runtime == "codex" and .task == "codex-guard-test" and .target == "~/fm-probe")' "$T/fm/state/delete-guard.log" >/dev/null \
  && ok "delete block logged for the watcher check, runtime codex" || no "delete log: $(cat "$T/fm/state/delete-guard.log" 2>&1)"
blocked 'kill -0 1' 'PID 1 (init)'
blocked 'cat ~/.codex/auth.json' 'BLOCKED by the fleet read guard'
(cd "$W" && exec sleep 300) & SLEEP=$!
as_codex "kill $SLEEP"; sleep 0.2
[ "$rc" -eq 0 ] && ! kill -0 "$SLEEP" 2>/dev/null && ok "kill of a process the task started in its worktree runs" || no "own kill: rc=$rc $err"

cp "$H/.codex/config.toml" "$T/config.installed"
HOME=$H "$ADDON/uninstall.sh" --dry-run >/dev/null
cmp -s "$H/.codex/config.toml" "$T/config.installed" && [ -e "$ENV" ] && ok "uninstall dry run writes nothing" || no "uninstall dry run wrote"
HOME=$H "$ADDON/uninstall.sh" >/dev/null
cmp -s "$H/.codex/config.toml" "$T/config.orig" && [ ! -e "$H/.local/share/fm-codex-guard" ] && ok "uninstall restores config.toml byte for byte" || no "uninstall left changes"
printf '[shell_environment_policy]\ninherit = "core"\n' >> "$H/.codex/config.toml"; cp "$H/.codex/config.toml" "$T/config.own"
! HOME=$H "$ADDON/install.sh" 2>"$T/refuse.err" && grep -q '^refused: ' "$T/refuse.err" && cmp -s "$H/.codex/config.toml" "$T/config.own" \
  && ok "an existing shell_environment_policy is refused, config untouched" || no "existing policy: $(cat "$T/refuse.err")"
exit "$fail"
