#!/usr/bin/env bash
# switch.sh test: the real script against a fixture no-mistakes config and a stub
# pi on PATH. A switch edits only the two keys by name (agent,
# agent_config.<agent>.model), writes a backup first, leaves the config alone when
# the model does not answer PONG, and restores that backup.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
script=$here/../switch.sh
[ -f "$script" ] || { echo "not ok - $script is missing"; exit 1; }

# The persisted pipeline route: the route the wrapper's chain holds and the config must name.
route=claude-bridge/claude-haiku-5-5

work=$(mktemp -d) || exit 1
trap 'rm -rf -- "$work"' EXIT
stub=$work/bin
mkdir -p "$stub"
# Isolate from any live account-pool so default --agent/--model stay the pinned route.
export PI_QUOTA_FAILOVER_ACCOUNT_POOL=

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
file_has() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1: $2 lacks [$3]"; fi; }
backups() { find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").bak-pipeline-opencode-*" | wc -l; }

# The fixture config: a comment, two top-level keys and two agents. Only the agent line and the pi model may change.
config=$work/config.yaml
cat >"$config" <<'CFG'
# the no-mistakes config (fixture)
agent: claude
backend: local
agent_config:
  claude:
    model: anthropic/claude-haiku-4-5
    max_tokens: 32000
  pi:
    model: openrouter/minimax/minimax-m3.1-flash:free
CFG
cp -p "$config" "$work/config.orig"

# The stub pi: answers PONG, unless STUB_PI_FAIL is set.
cat >"$stub/pi" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_PI_FAIL:-}" ] && { echo 'pi: no route' >&2; exit 1; }
printf '%s\n' 'PONG'
STUB
chmod +x "$stub/pi"

# Codex refuses a fresh non-git working directory unless the repository check
# is explicitly skipped. Keep the probe behavior in the stub so this test never
# calls a real model or inspects a real Codex login.
cat >"$stub/codex" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *' --skip-git-repo-check '*) printf '%s\n' 'PONG' ;;
  *) echo 'Not inside a trusted directory and --skip-git-repo-check was not specified' >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/codex"
PATH="$stub:$PATH"

# 1. A dry run prints the planned edit and writes nothing.
out=$("$script" --dry-run --config "$config" 2>&1); rc=$?
is "dry run exits 0" "$rc" "0"
is "the dry run plans the pipeline route" "$(printf '%s' "$out" | sed -n 's/^dry-run: would set agent=pi and agent_config.pi.model=\([^ ]*\) in .*/\1/p')" "$route"
is "dry run wrote no backup" "$(backups "$config")" "0"
if cmp -s "$config" "$work/config.orig"; then ok "dry run left the config alone"; else no "dry run changed the config"; fi

# 2. A real switch: the two keys change, everything else stays, a backup is written.
out=$("$script" --config "$config" 2>&1); rc=$?
is "switch exits 0" "$rc" "0"
file_has "the agent key is set" "$config" '^agent: pi$'
file_has "the pi model key is set" "$config" "^    model: $route$"
file_has "the other keys, values and the comment are untouched" "$config" \
  '^    model: anthropic/claude-haiku-4-5$|^    max_tokens: 32000$|^backend: local$|^# the no-mistakes config \(fixture\)$'
is "a backup was written" "$(backups "$config")" "1"

# 3. A model that does not answer PONG: the config is left alone.
cp -p "$work/config.orig" "$config"
before=$(backups "$config")
out=$(STUB_PI_FAIL=1 "$script" --config "$config" 2>&1); rc=$?
if [ "$rc" != 0 ]; then ok "a model that does not answer fails the switch"; else no "a model that does not answer must fail the switch"; fi
if cmp -s "$config" "$work/config.orig"; then ok "the failed switch left the config alone"; else no "the failed switch changed the config"; fi
is "the failed switch wrote no backup" "$(backups "$config")" "$before"

# 4. --restore-latest brings the backup back.
out=$("$script" --config "$config" 2>&1); rc=$?
is "the switch after the failure exits 0" "$rc" "0"
out=$("$script" --restore-latest --config "$config" 2>&1); rc=$?
is "restore exits 0" "$rc" "0"
if cmp -s "$config" "$work/config.orig"; then ok "restore brought the original config back"; else no "restore did not bring the original config back"; fi

# 5. Codex's probe runs from a fresh non-git directory and must opt out of the
# repository trust check, while still switching only the requested route.
out=$("$script" --config "$config" --agent codex --model gpt-6.1-sol 2>&1); rc=$?
is "Codex probe exits 0 with the repository check skipped" "$rc" "0"
file_has "the Codex agent key is set" "$config" '^agent: codex$'
file_has "the Codex model key is set" "$config" '^    model: gpt-6.1-sol$'

echo
if [ "$fails" = 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
