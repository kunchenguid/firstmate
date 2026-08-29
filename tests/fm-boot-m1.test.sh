#!/usr/bin/env bash
# m1: the emitter is actually registered as a SessionStart hook.
#
# THIS GATE IS EXPECTED TO BE RED IN THIS REPO, AND THAT IS THE POINT.
#
# Its other half lives in another repo. ~/.claude/settings.json is not a file
# anyone edits: it is RENDERED from mac-config's desired state, and a render
# deletes every key it does not declare. So firstmate cannot register its own
# hook - a hand-written entry would work until the next `stone apply` and then
# silently revert, which is strictly worse than being reliably unregistered.
# Registration is a declared change in mac-config: a registry.yaml hooks entry,
# a policy.yaml hook_allowlist entry, a hook-budget raise, and the retirement of
# the now-spent forbidden-substring rule. That is a separate, dependent task.
#
# Freezing this red is the honest record of that. It is the one gate in this
# branch that is allowed to be red on arrival, and it goes green the moment the
# dependent mac-config change is applied - no further work in this repo.
# docs/declarations/2026-08-27-boot-context-hook-registration.md is the exact
# content that task applies.
#
# What it asserts, and why it is not asserting on direct invocation: a test that
# runs bin/fm-boot-context.sh itself and checks the output would go green while
# a real session still boots blind - the trap the design names explicitly, and
# the reason the existing tests/fm-captain-bootstrap-digest.test.sh does not
# settle this question. So the observable is the registration itself, read from
# the live rendered settings file, plus proof the registered command actually
# resolves to a runnable emitter.
#
# Mutation (LEDGER_MUTATE=1): the settings file is replaced by a copy with the
# hooks key emptied, and the same assertions run against it - a correct check
# fails, proving it reads the real registration rather than passing on presence
# of the script.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTINGS="${FM_BOOT_SETTINGS:-$HOME/.claude/settings.json}"

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  TMP=$(fm_test_tmproot fm-boot-m1)
  mkdir -p "$TMP"
  python3 - "$SETTINGS" "$TMP/settings.json" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
d["hooks"] = {}
open(sys.argv[2], "w").write(json.dumps(d, indent=2))
PY
  SETTINGS="$TMP/settings.json"
fi

[ -f "$SETTINGS" ] || fail "no rendered settings file at $SETTINGS"

# The registered command, if any. Printed so a red run says what is actually
# registered rather than just that something is missing.
registered=$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("PARSE-ERROR %s" % e)
    raise SystemExit(0)
for group in (d.get("hooks") or {}).get("SessionStart") or []:
    for h in group.get("hooks") or []:
        cmd = h.get("command") or ""
        if "fm-boot-context.sh" in cmd:
            print("%s\t%s" % (cmd, h.get("timeout")))
            raise SystemExit(0)
print("")
PY
)

if [ -z "$registered" ]; then
  present=$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("(unparseable)"); raise SystemExit(0)
cmds = [h.get("command", "") for g in (d.get("hooks") or {}).get("SessionStart") or []
        for h in g.get("hooks") or []]
print("; ".join(cmds) or "(no SessionStart hooks)")
PY
)
  fail "bin/fm-boot-context.sh is not registered as a SessionStart hook.
This gate is BLOCKED on the dependent mac-config task, not on work in this repo.
Apply docs/declarations/2026-08-27-boot-context-hook-registration.md in mac-config,
run 'stone apply', and this goes green with no further firstmate change.
Currently registered SessionStart commands: $present"
fi

cmd=${registered%%$'\t'*}
timeout=${registered##*$'\t'}

# A registration that points at nothing is not a registration.
target=$(printf '%s' "$cmd" | python3 -c '
import os, re, sys, shlex
line = sys.stdin.read().strip()
line = os.path.expandvars(line)
for tok in shlex.split(line):
    if tok.endswith("fm-boot-context.sh"):
        print(tok); break
')
[ -n "$target" ] || fail "registered command does not name a fm-boot-context.sh path: $cmd"
[ -x "$target" ] || fail "the registered hook command points at a non-executable path: $target"

# The command must INVOKE the emitter, not merely mention its path. Without
# this, a no-op such as `test -x ".../fm-boot-context.sh"` satisfies the gate
# while every real session still boots blind - the same class of false green
# this gate refuses direct-invocation testing to avoid. The declaration this
# gate is blocked on specifies `bash "<path>"`, matching the existing hook's
# convention, so that is the shape required here.
case "$cmd" in
  bash\ *"fm-boot-context.sh"*|*/bash\ *"fm-boot-context.sh"*|"$target"|"$target "*)
    : ;;
  *)
    fail "the registered command must INVOKE the emitter, not just name it.
Expected 'bash \"<path>/fm-boot-context.sh\"' (or the script run directly).
Got: $cmd" ;;
esac

# And it must actually emit when invoked the way the hook invokes it: a
# registration that runs something producing no additionalContext is a hook in
# name only.
probe=$(printf '{"source":"startup","cwd":"%s","session_id":"m1-probe"}' "$HOME" \
  | FIRSTMATE_ROLE=captain bash "$target" 2>/dev/null) \
  || fail "the registered command exits non-zero when invoked as a SessionStart hook"
printf '%s' "$probe" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
out = d["hookSpecificOutput"]
assert out["hookEventName"] == "SessionStart", out
assert out["additionalContext"].strip(), "empty additionalContext"
' >/dev/null 2>&1 \
  || fail "the registered command emits no SessionStart additionalContext: $target"

# The declared timeout must be the repo's convention, not the harness default of
# 600 - an unbounded boot hook is the failure mode this whole slice exists for.
[ "$timeout" = "10" ] \
  || fail "the registered hook must declare timeout 10 (got: $timeout)"

pass "m1 boot-context emitter registered as a SessionStart hook"
