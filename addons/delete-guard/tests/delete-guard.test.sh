#!/usr/bin/env bash
# End to end: install into a throwaway HOME against a fixture home built from an upstream Firstmate checkout's bin/,
# then drive the installed hook entrypoint. Usage: delete-guard.test.sh <firstmate-checkout> [git-ref, default HEAD]
# shellcheck disable=SC2016 # the cases are literal commands, never expanded here
set -euo pipefail
unset FM_TASK_ID FM_TASK_INBOX FM_HOME
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/fm/state" "$T/home/.claude" "$T/home/.pi/agent/extensions" "$T/home/.config/opencode/plugins"
git -C "$1" archive "${2:-HEAD}" bin | tar -x -C "$T/fm"
echo '{"env":{"KEEP":"1"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-hook"}]}]}}' > "$T/home/.claude/settings.json"
fail=0
ok() { echo "ok: $*"; }; no() { echo "FAIL: $*"; fail=1; }
inst() { env -u XDG_DATA_HOME HOME="$T/home" "$ADDON/install.sh" "$@" "$T/fm"; }

inst --dry-run > "$T/dry.out"
[ ! -e "$T/home/.local/share/fm-delete-guard/guard.mjs" ] && ok "dry run writes nothing" || no "dry run wrote files"
inst > "$T/install.out" && inst > "$T/reinstall.out"
grep -q 'registered: state/delete-guard.check.sh' "$T/install.out" && ok "check registered" || no "check not registered"
[ "$(grep -c '^unchanged: ' "$T/reinstall.out")" -eq 7 ] && ok "reinstall changes nothing" || no "reinstall not idempotent: $(cat "$T/reinstall.out")"
jq -e '.env.KEEP == "1" and ([.hooks.PreToolUse[].hooks[].command] | length == 2 and index("other-hook") == 0)' "$T/home/.claude/settings.json" >/dev/null && ok "claude settings merged, existing settings kept" || no "claude settings merge"
ls "$T/home/.claude/"settings.json.bak-delete-guard-* >/dev/null && ok "backup made" || no "no backup"
grep -q "$T/home/.local/share/fm-delete-guard/guard.mjs" "$T/home/.pi/agent/extensions/fm-rm-guard.ts" && ok "pi adapter replaces fm-rm-guard.ts" || no "pi adapter"

hookrun() { jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}' | HOME="$T/home" node "$T/home/.local/share/fm-delete-guard/guard.mjs" --runtime claude 2>/dev/null; } # exit 2 = blocked
blocked=('rm -rf "$HOME"' 'rm -rf ~' 'rm -rf ~/' 'rm -fr $HOME/*' 'rm -r -f /home/you' 'rm -rf $HOME/.config' 'rm -rf ~/.agents'
  'cd x && rm -rf ${HOME}' 'rm -rf /' 'rm -rf /*' 'rm -rf .' 'rm -rf *' 'rm -Rf $BUILD/*' 'find ~ -delete' 'npx rimraf $HOME'
  'rm -rf -- "$HOME"' 'HOME=$(mktemp -d) node t.js; rm -rf "$HOME"' '/usr/bin/rm -rf /home'
  'export HOME=$(mktemp -d); rm -rf "$HOME"' 'rm -rf "${HOME:?}"' 'rm -rf "$TMPHOME/"'
  'bash -c "rm -rf ~"' '\rm -rf ~' 'rm -rf /home/you/..' 'rm -rf ../..' 'rm -rf ~/.fm-guard-probe-nonexistent'
  'rm -rf -- "$d"' 'd=$(mktemp -d); d=$HOME; rm -rf "$d"' 'd=$(mktemp -d); rm -rf "$d/.."' 'd=$(mktemp -d); rm -rf "$d"/../x'
  'd=$(mktemp -d); rm -rf ${d:-/}' 'HOME=$(mktemp -d); rm -rf "$HOME"' 'd=$(mktemp -d) node t.js; rm -rf "$d"'
  'd=$(mktemp -d); read d; rm -rf "$d"' 'TMPDIR=$(mktemp -d); rm -rf "$TMPDIR"' 'TMP=$(mktemp -d /tmp/x.XXXXXX); rm -rf -- "$TMP"' '(d=$(mktemp -d)); rm -rf "$d"' $'cat > f <<EOF\nhi\nEOF\nrm -rf ~'
  'd=$(mktemp -d || echo ~); rm -rf -- "$d"' 'd=$(mktemp -d && echo ~); rm -rf -- "$d"' 'd=$(mktemp -d || mktemp -d) || d=~; rm -rf "$d"'
  $'bash <<EOF\nrm -rf ~\nEOF' $'cat <<\'EOF\' | sh\nrm -rf "$HOME"\nEOF' $'zsh <<-EOF\n\trm -rf /\n\tEOF'
  'S=~; rm -rf "$S"' 'S=/home/you; rm -rf "$S"' 'S=$HOME/x; rm -rf "$S"' 'S=~/.cache/x; S=~; rm -rf "$S"'
  '[ -n x ] && S=~/.cache/x && rm -rf "$S"' 'rm -rf "$S"' 'S=~/.cache/x; rm -rf "$S/.."' 'd=$(mktemp -d); d=~; rm -rf "$d"'
  'export T=~; rm -rf "$T"' 'declare -n T=HOME; rm -rf "$T"' 'local -n T=HOME; rm -rf "$T"' 'typeset -n T=HOME; rm -rf -- "$T"'
  'declare -rn T=HOME; rm -rf "$T"' 'export T=$(mktemp -d); T=~; rm -rf "$T"'
  '(S=~/.cache/x); rm -rf "$S"' $'if [ -n x ]; then\nS=~/.cache/x\nrm -rf "$S"\nfi'
  'd=$(mktemp -d "$(echo ~)/x.XXXX"); rm -rf -- "$d"' 'd=$(mktemp -d `echo ~`); rm -rf "$d"'
  $'d=$(mktemp -d /tmp/t1-keyiso-probe-XXXX); mkdir -p "$d/home" "$d/runtime"; dbus-run-session -- bash -ceu \'\n  d="\'$d\'"\n  export XDG_RUNTIME_DIR="$d/runtime" HOME="$d/home"\n  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"\n  mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"\n  echo -n "throwaway" | gnome-keyring-daemon --unlock --replace --components=secrets --daemonize\n  sleep 1\n  printf "sk-host-keyring-poison" | secret-tool store --label=byokit:takeone:jev service takeone account jev\n  echo "lookup: $(secret-tool lookup service takeone account jev)"\n  find "$HOME/.local/share/keyrings" -maxdepth 1 2>/dev/null\n\'; echo "probe exit: $?"; d=$(echo /tmp/t1-keyiso-probe-*/); [ -d "$d" ] && rm -rf -- "$d"; echo cleaned'
  "$(printf 'echo x;%.0s' {1..120}) rm -rf \"\$HOME\"")
allowed=(  'rm -rf ./build' 'rm -rf node_modules' 'd=$(mktemp -d); rm -rf -- "$d/x"' 'rm -rf ~/.cache/foo/bar' 'rm -f ~/.bashrc.bak'
  'rm -rf /tmp/abc' 'rm -rf $HOME/.cache/pockit' 'echo rm -rf is bad' 'git rm -r --cached x/y' 'rm -rf /home/you/.treehouse/x/y'
  'HOME=$(mktemp -d) npm test' 'd=$(mktemp -d); cd "$d" && make; rm -rf -- "$d"' 'T="$(mktemp -d)" || exit 1; rm -rf "${T}"' 'f=$(mktemp); rm -rf "$f"'
  $'cat > f <<\'EOF\'\nnever rm -rf on /, ~ or a bare . target\nEOF' $'git commit -m "guard\n\nrm -rf ~ is blocked"' 'gh pr create --body "rm -rf ~/x was blocked; rm -rf . too"'
  $'python3 - <<\'EOF\'\nprint("rm -rf ~")\nEOF'
  'SCRATCH=~/.cache/fm-scratch/lfm-doctor-real-checks/proof && rm -rf "$SCRATCH" && mkdir -p "$SCRATCH"' 'S=~/.cache/x; rm -rf "$S"'
  'd=$(mktemp -d /some/dir/maintest.XXXX); rm -rf "$d"' 'd=$(mktemp -d /tmp/x.XXXXXX); rm -rf -- "$d"' 'd=$(mktemp -p ~/.cache -d); rm -rf "$d"' 'd=$(mktemp -d -p ~); rm -rf "$d"'
  'd=$(mktemp -d -p /tmp/x 2>/dev/null || mktemp -d); rm -rf -- "$d"' 'd=$(mktemp -d || mktemp -d); rm -rf -- "$d"'
  'd=$(mktemp -d -p /tmp/x 2>/dev/null); rm -rf -- "$d"' 'd="$(mktemp -d -p /tmp/x || mktemp -d)"; rm -rf "$d"'
  $'d=$(mktemp -d -p /tmp/x 2>/dev/null || mktemp -d)\ncd "$d" && make\nrm -rf -- "$d"'
  'export T=$(mktemp -d); rm -rf -- "$T"' 'local -r d=$(mktemp -d); rm -rf "$d"' 'declare -x T=~/.cache/x; rm -rf "$T"'
  $'export T=$(mktemp -d --tmpdir=/dev/shm lfm-wt-XXXXXX); export LFM_HOME=$T/home PROJ=$T/proj; mkdir -p $LFM_HOME $PROJ; git init -q $PROJ; node bin/learn-from-mistakes-axi.mjs init --no-skill --dir $PROJ --agent claude --model m --judge-agent codex --judge-model m2 >/tmp/init-out.txt 2>&1; echo "exit=$?"; awk \'{ if (length($0)>100) print FILENAME" "FNR" ("length($0)"): "$0 }\' $LFM_HOME/config.yaml $PROJ/.learn-from-mistakes.yaml; echo "CONFIG-CHECK-DONE"; cat /tmp/init-out.txt; echo "---json---"; node bin/learn-from-mistakes-axi.mjs init --json --dir $PROJ 2>&1 | head -5; rm -rf -- "$T"'
  $'d=$(mktemp -d); REPO=/repo; CLI=$REPO/bin/cli.mjs; FAKE=$REPO/test/fake-agent/claude\nmkdir -p "$d/fakes" "$d/home" "$d/p"\nln -s "$FAKE" "$d/fakes/claude"; ln -s "$FAKE" "$d/fakes/codex"\nprintf \'agent: claude\\njudge_agent: codex\\n\' > "$d/home/config.yaml"\ncp "$REPO/examples/defects.md" "$d/p/"\nprintf \'\\n## %s\\n\\n- [tests] Fixture tests failed: EXAMPLE_FIXTURES was unset.\\n- [tests] They failed again for the same reason.\\n\' "$(date -Is)" >> "$d/p/defects.md"\nHOME="$d/home" node "$CLI" retro --project "$d/p" || true\nrm -rf -- "$d"'
  'd=$(mktemp -d ${X}/a.XXXX); rm -rf "$d"'
  $'cd /home/you/.no-mistakes/worktrees/example-review-base && grep -n \'^ROOT=\' bin/fm-test-run.sh && d=$(mktemp -d "$PWD/.review-base-XXXX") && mkdir -p "$d/bin" "$d/tests" && git show 5758e52046f49dcc7297a2f0952cfa1bbdf969b0:bin/fm-test-run.sh > "$d/bin/fm-test-run.sh" && chmod +x "$d/bin/fm-test-run.sh" && git archive 5758e52046f49dcc7297a2f0952cfa1bbdf969b0 tests | tar -x -C "$d" && (cd "$d" && bash bin/fm-test-run.sh --check-coverage; echo "base rc=$?") ; rm -rf -- "$d"')
n=0
for c in "${blocked[@]}"; do n=$((n + 1)); if hookrun "/tmp/case-$n" "$c"; then no "MISSED: $c"; fi; done
for c in "${allowed[@]}"; do n=$((n + 1)); hookrun "/tmp/case-$n" "$c" || no "FALSE BLOCK: $c"; done
[ "$fail" -eq 0 ] && ok "rule: ${#blocked[@]} blocked, ${#allowed[@]} allowed"
[ "$(wc -l < "$T/fm/state/delete-guard.log")" -eq "${#blocked[@]}" ] && ok "one log line per block" || no "log line count"
tail -n1 "$T/fm/state/delete-guard.log" | jq -e '.command | contains("rm -rf \"$HOME\"")' >/dev/null && ok "long command keeps the part around the delete" || no "long command lost its delete part"
[ ! -s "$T/fm/state/.wake-queue" ] && ok "no repeat wake for distinct agents" || no "unexpected wake"

# The check expands ~ with HOME; a fixed one keeps a throwaway HOME under /tmp from reading as a temp folder.
check() { HOME=/home/fixture/users/user-014 "$@"; }
[ -z "$(check "$T/fm/state/delete-guard.check.sh")" ] && [ "$(cut -f2 "$T/fm/state/delete-guard.counted")" = "${#blocked[@]}" ] \
  && ok "check counts blocks from agents in temp folders without a wake" || no "temp-folder blocks: $(cat "$T/fm/state/delete-guard.counted")"
[ -z "$(check "$T/fm/state/delete-guard.check.sh")" ] && ok "check quiet with nothing new" || no "check repeats old lines"

FM_TASK_ID=t1 FM_TASK_INBOX="$T/lead/state/t1.inbox" hookrun /w 'rm -rf ~' || true
grep -q 'delete-guard' "$T/fm/state/.wake-queue" 2>/dev/null && no "first block woke at once" || ok "first block waits for the check"
FM_TASK_ID=t1 FM_TASK_INBOX="$T/lead/state/t1.inbox" hookrun /w 'rm -rf "$HOME"' || true
grep -q "delete guard REPEAT: task t1 tried 2 .*home $T/lead," "$T/fm/state/.wake-queue" && ok "repeat queues an immediate wake" || no "no repeat wake"
tail -n1 "$T/fm/state/delete-guard.log" | jq -e --arg h "$T/lead" '.task == "t1" and .home == $h and .cwd == "/w" and .runtime == "claude"' >/dev/null && ok "log line names home, task, cwd, runtime" || no "log line fields"
FM_TASK_ID=t2 FM_TASK_INBOX="$T/lead/state/t2.inbox" hookrun "$T/fm/state" 'rm -rf ~' || true # cwd's firstmate home wins over an inherited inbox home
jq -e --arg h "$T/fm" '.task == "t2" and .home == $h' <(tail -n1 "$T/fm/state/delete-guard.log") >/dev/null && ok "home is the firstmate home of cwd, not an inherited inbox" || no "cwd home lost to inbox"
FM_HOME=/elsewhere hookrun "$T/fm/state" 'rm -rf ~' || true # a lead with an inherited FM_HOME, working in its own home
tail -n1 "$T/fm/state/delete-guard.log" | jq -e --arg h "$T/fm" '.home == $h and .task == ""' >/dev/null && ok "no-task block logs the home holding cwd" || no "home from cwd"
out=$(check "$T/fm/state/delete-guard.check.sh")
case "$out" in "delete guard blocked 1 recursive delete(s)"*"task t1 (claude, home $T/lead, cwd /w, "*"/home/fixture/users/user-014: rm -rf ~") ok "check wakes on a literal home target, not on its repeat or temp-folder blocks" ;; *) no "check output: $out" ;; esac

# Replay of the fixture log, one sweep per row: only the 14:22 literal /home/you/scratch-test block wakes; the
# build probes, variable targets and that task's $d repeat 15 s later are counted.
mkdir -p "$T/replay/state"; wakes=()
while IFS= read -r row; do
  printf '%s\n' "$row" >> "$T/replay/state/delete-guard.log"
  w=$(HOME=/home/you "$T/home/.local/share/fm-delete-guard/check.sh" "$T/replay"); [ -z "$w" ] || wakes+=("$w")
done < "$ADDON/tests/fixtures/delete-guard-2026-10-16.log"
[ "${#wakes[@]}" -eq 1 ] && case "${wakes[0]}" in *"task rd-stale-screen-on-return (pi, "*", 14:22Z) /home/you/scratch-test: "*) true ;; *) false ;; esac \
  && ok "replay wakes only on the 14:22 /home/you/scratch-test block" || no "replay wakes: $(printf '%s\n' "${wakes[@]}")"
[ "$(cat "$T/replay/state/delete-guard.counted")" = "$(printf '2026-10-16\t%s' $(($(wc -l < "$ADDON/tests/fixtures/delete-guard-2026-10-16.log") - 1)))" ] \
  && ok "replay counts every other block for the day" || no "replay count: $(cat "$T/replay/state/delete-guard.counted")"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
