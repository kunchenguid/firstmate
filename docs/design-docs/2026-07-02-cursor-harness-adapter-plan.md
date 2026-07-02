# Cursor agent harness adapter - Implementation Plan

> **For agentic workers:** Implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking. TDD where the change is testable: write the failing test, run it red, implement, run it green, commit.

**Goal:** Add `cursor` as a verified firstmate harness so the orchestrator and crewmates run on the Cursor agent (BAA/ZDR), off direct Claude, landed local-first and later upstreamed.

**Architecture:** Mirror the grok adapter across the seven grok-bearing `bin/` files plus the harness-adapters skill, with one novel piece: the turn-end `stop`-hook is idempotently merged into the operator's shared `~/.cursor/hooks.json` (grok writes standalone files it fully owns), and the hook reads Cursor's stdin JSON payload (`workspace_roots`) rather than an env var.

**Tech Stack:** Bash (POSIX-ish, macOS bash 3.2 compatible), `jq`, tmux, git worktrees, `tests/*.test.sh` behavior suite run by `no-mistakes` via `.no-mistakes.yaml`.

**Spec:** `docs/design-docs/2026-07-02-cursor-harness-adapter-design.md`

---

## File structure

Modified:
- `bin/fm-harness.sh` - detection (env marker + ancestry backstop)
- `bin/fm-lock.sh` - `HARNESS_RE` session-holder recognition
- `bin/fm-spawn.sh` - `launch_template`, `model_flag_for_harness`, `--secondmate` bare-name list, turn-end hook install
- `bin/fm-teardown.sh` - pointer/token/dirty-check cleanup
- `bin/fm-bootstrap.sh` - verified-harness allowlist
- `bin/fm-watch.sh`, `bin/fm-tmux-lib.sh` - busy signature defaults
- `.agents/skills/harness-adapters/SKILL.md` - cursor knowledge section

Created:
- `tests/fm-cursor-harness.test.sh` - detection, spawn, turn-end hook, teardown, fm-lock, hooks.json merge
- Local, gitignored (not committed to the PR): `config/crew-dispatch.json`, `config/crew-harness` in the operator's firstmate home

Key facts to resolve first (Task 0), then substituted throughout:
- `BIN` = canonical Cursor CLI command (`cursor-agent` preferred; `agent` fallback)
- `BUSY` = Cursor busy-pane signature string
- `EXITKEY`, `INTKEY` = exit / interrupt keys
- `SKILLFORM` = `/no-mistakes` invocation form

---

## Task 0: Verification trial (fills the empirical unknowns)

Not TDD - a supervised observation run. Everything downstream depends on these facts.

**Files:**
- Create (scratch, not committed): `docs/design-docs/cursor-verification-notes.md`

- [ ] **Step 1: Confirm the binary name and env markers**

Run:
```bash
command -v cursor-agent; command -v agent
env | grep -iE 'cursor|claudecode|ai_agent'
```
Record `BIN` (prefer `cursor-agent` if present, else `agent`), confirm `CURSOR_AGENT=1`, and whether `CLAUDECODE` is set.

- [ ] **Step 2: Spawn a throwaway Cursor crewmate via the raw-launch escape hatch and observe the TUI**

Use a scratch repo/worktree and run (from a firstmate home):
```bash
bin/fm-spawn.sh cursor-verify-x1 <scratch-project-dir> "<BIN> --force \"\$(cat <brief>)\""
```
Attach to the `fm-cursor-verify-x1` tmux window and record: the busy-pane line while it works (`BUSY`), the exit key (`EXITKEY`), the interrupt key (`INTKEY`), any first-run trust dialog and how it is accepted, the `/no-mistakes` invocation form (`SKILLFORM`), and whether an empty composer shows ghost/suggested text.

- [ ] **Step 3: Confirm the stop-hook contract (highest-risk, novel piece)**

Before Task 4 hardcodes it, empirically confirm Cursor's `stop`-hook API. Install a temporary logging stop hook in a scratch `CURSOR_CONFIG_DIR` and run one turn:
```bash
export CURSOR_CONFIG_DIR=$(mktemp -d)
mkdir -p "$CURSOR_CONFIG_DIR/hooks"
cat > "$CURSOR_CONFIG_DIR/hooks/log.sh" <<'SH'
#!/usr/bin/env bash
cat > /tmp/cursor-stop-payload.json
printf '{}'
SH
chmod +x "$CURSOR_CONFIG_DIR/hooks/log.sh"
printf '{"version":1,"hooks":{"stop":[{"command":"%s/hooks/log.sh","timeout":10}]}}' "$CURSOR_CONFIG_DIR" > "$CURSOR_CONFIG_DIR/hooks.json"
# run a one-shot cursor turn in the scratch config, then:
cat /tmp/cursor-stop-payload.json
```
Confirm and record: the event key is `stop`, the payload contains `workspace_roots` (array of absolute paths), the entry shape is `{"command","timeout"}`, and the hook is expected to emit JSON (`{}`) on stdout. If any differ, update Task 4 before implementing it.

- [ ] **Step 4: Record findings**

Write all resolved values (including the stop-hook schema) into `docs/design-docs/cursor-verification-notes.md`. Do not commit this scratch file. Note that the installed hook shells out to `jq` at turn-end, so `jq` is a runtime dependency (it fails safe to a no-op if absent, meaning turn-end wakes silently stop - record this in the SKILL).

- [ ] **Step 5: Tear down the trial**

```bash
bin/fm-teardown.sh cursor-verify-x1 --force
```

---

## Task 1: Detection (`bin/fm-harness.sh`)

**Files:**
- Modify: `bin/fm-harness.sh` (`detect_own()`, after the grok marker ~line 28; ancestry `case` ~line 34-47)
- Test: `tests/fm-cursor-harness.test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/fm-cursor-harness.test.sh` with a detection test:
```bash
#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

test_detects_cursor_via_env_marker() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE= "$HARNESS")
  assert_contains "$out" "cursor" "CURSOR_AGENT=1 should detect cursor"
  pass "detects cursor via CURSOR_AGENT"
}

test_claude_still_wins_when_both_set() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
  assert_contains "$out" "claude" "a genuine claude session must resolve to claude"
  pass "preference-neutral: claude wins when CLAUDECODE set"
}

test_detects_cursor_via_env_marker
test_claude_still_wins_when_both_set
```

- [ ] **Step 2: Run it red**

Run: `bash tests/fm-cursor-harness.test.sh`
Expected: FAIL - first test prints `unknown`/no `cursor`.

- [ ] **Step 3: Implement**

In `detect_own()`, add AFTER the grok marker line (`[ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }`):
```sh
  # Cursor sets CURSOR_AGENT=1 for its agent processes (verified). Placed after
  # claude/pi/grok so detection stays preference-neutral: a genuine Claude session
  # (CLAUDECODE=1), including one nested inside Cursor, still resolves to claude.
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
```
Add to BOTH ancestry `case` blocks (comm and args), mirroring the grok arm, using `BIN`:
```sh
      *cursor-agent*) echo cursor; return ;;
```

- [ ] **Step 4: Run it green**

Run: `bash tests/fm-cursor-harness.test.sh`
Expected: PASS (both detection tests).

- [ ] **Step 5: Commit**

```bash
git add bin/fm-harness.sh tests/fm-cursor-harness.test.sh
git commit -m "feat(harness): detect cursor agent (preference-neutral)"
```

---

## Task 2: Session lock recognition (`bin/fm-lock.sh`)

**Files:**
- Modify: `bin/fm-lock.sh:18` (`HARNESS_RE`)
- Test: `tests/fm-cursor-harness.test.sh`

- [ ] **Step 1: Add the failing test** (mirror `test_fm_lock_recognizes_grok_holder` from `tests/fm-grok-harness.test.sh:119`), with the fake `ps` returning the Cursor binary path/args, asserting `fm-lock.sh status` prints `lock: held by live harness pid`.

- [ ] **Step 2: Run it red** - `bash tests/fm-cursor-harness.test.sh` -> the lock test fails ("cannot locate harness process").

- [ ] **Step 3: Implement** - extend `HARNESS_RE`:
```sh
HARNESS_RE='claude|codex|opencode|grok|cursor-agent|^pi$'
```
(Use the tightened `cursor-agent` token, never a bare `agent`; if Task 0 found only `agent`, keep the env-marker-first detection and use a precise anchored `agent` alternative here, e.g. `(^|/)agent$`.)

- [ ] **Step 4: Run it green.**

- [ ] **Step 5: Commit** - `git commit -am "feat(lock): recognize cursor as session holder"`.

---

## Task 3: Spawn - launch template, model flag, secondmate list (`bin/fm-spawn.sh`)

**Files:**
- Modify: `bin/fm-spawn.sh` - `launch_template()` (~line 216), `model_flag_for_harness()` (line 282), `--secondmate` bare-name case (line 156)
- Test: `tests/fm-cursor-harness.test.sh`

- [ ] **Step 1: Write the failing test** - a spawn test (mirror `run_grok_spawn`/`make_spawn_case` from `tests/fm-grok-harness.test.sh`, using `cursor` as the harness arg and a fake `BIN`), asserting the spawn succeeds (`spawned <id> harness=cursor`) and that the launch line contains `--force` and `--model <id>` and NO `--effort`. Note: the grok test's fake `tmux` discards `send-keys` (`send-keys) exit 0`), so write a NEW tmux stub that logs the launch payload - and filter specifically to the `send-keys -t <t> -l <payload>` invocation, because `fm-spawn.sh` also sends `export GOTMPDIR=...` and a bare `Enter` (lines 714/718). Capture only the `-l` payload.

- [ ] **Step 2: Run it red.**

- [ ] **Step 3: Implement.**
`launch_template()`, add after the grok arm:
```sh
    # cursor (Cursor agent CLI): positional prompt starts the supervised session.
    # --force auto-approves every tool execution (the unattended-crewmate equivalent
    # of claude's --dangerously-skip-permissions). No effort flag: effort is encoded
    # in the model id. Turn-end does NOT ride the launch command - it is a stop-hook
    # installed below.
    cursor) printf '%s' 'cursor-agent __MODELFLAG__--force "$(cat __BRIEF__)"' ;;
```
`model_flag_for_harness()`, add `cursor` to the case list so `--model` is emitted:
```sh
    claude|codex|opencode|pi|grok|cursor)
```
`effort_flag_for_harness()`: leave cursor out of the case (no arm) so no effort flag is emitted - effort is recorded in meta only. Add a brief comment noting effort is encoded in the cursor model id.
`--secondmate` bare-name list (line 156): `''|claude|codex|opencode|pi|grok|cursor)`.

- [ ] **Step 4: Run it green.**

- [ ] **Step 5: Commit** - `git commit -am "feat(spawn): cursor launch template, model flag, secondmate name"`.

---

## Task 4: Spawn - turn-end stop-hook (`bin/fm-spawn.sh`)

The novel piece. Cursor hooks live in the shared `~/.cursor/hooks.json` (or `$CURSOR_CONFIG_DIR/hooks.json`) and receive the event payload on stdin as JSON; the hook must merge idempotently and preserve existing hooks.

**Files:**
- Modify: `bin/fm-spawn.sh` - the turn-end `case "$HARNESS" in` block (add a `cursor*)` arm after `grok*)` ~line 660)
- Test: `tests/fm-cursor-harness.test.sh`

- [ ] **Step 1: Write the failing test** (mirror `test_grok_hook_requires_registered_token`): after a cursor spawn, assert:
  - the hook script exists at `<cursor_home>/hooks/fm-turn-end.sh`;
  - `<cursor_home>/hooks.json` `.hooks.stop` contains an entry whose command is that script, AND a pre-seeded `sessionStart` hook + a pre-existing `stop` entry both survive (preservation);
  - `<worktree>/.fm-cursor-turnend` contains `token=` and does NOT contain the turn-ended path;
  - the registry entry `<cursor_home>/hooks/fm-turn-end.d/<token>` names `state/<id>.turn-ended`;
  - piping `{"workspace_roots":["<worktree>"]}` to the hook on stdin touches `state/<id>.turn-ended`, while an evil pointer to an arbitrary target does NOT.
  Use a `CURSOR_CONFIG_DIR` (or `HOME`) override pointing at the case's cursor home so the test never touches the real `~/.cursor`.

- [ ] **Step 2: Run it red.**

- [ ] **Step 3: Implement.** Add a `cursor*)` arm mirroring grok's block (`bin/fm-spawn.sh:612-660`) with these differences:
  - Resolve the hooks dir: `CURSOR_HOOKS_DIR="${CURSOR_CONFIG_DIR:-$HOME/.cursor}/hooks"`; registry `CURSOR_AUTH_DIR="$CURSOR_HOOKS_DIR/fm-turn-end.d"`.
  - Write the auth file + `$STATE/$ID.cursor-turnend-token` + `<worktree>/.fm-cursor-turnend` pointer (`token=...`), and `exclude_path '.fm-cursor-turnend'` - identical shape to grok.
  - Hook script reads Cursor's stdin JSON (not an env var) and emits `{}`:
    ```sh
    cat > "$CURSOR_HOOKS_DIR/fm-turn-end.sh" <<EOF
    #!/usr/bin/env bash
    set -u
    auth_dir=$sq_cursor_auth_dir
    payload=\$(cat 2>/dev/null || true)
    roots=\$(printf '%s' "\$payload" | jq -r '.workspace_roots[]?' 2>/dev/null) || roots=""
    while IFS= read -r ws; do
      [ -n "\$ws" ] || continue
      p="\$ws/.fm-cursor-turnend"
      [ -f "\$p" ] || continue
      first=
      IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || continue
      case "\$first" in token=*) token=\${first#token=} ;; *) continue ;; esac
      case "\$token" in fm.????????????) : ;; *) continue ;; esac
      case "\$token" in *[!A-Za-z0-9._-]*) continue ;; esac
      t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || continue
      case "\$t" in /*.turn-ended) : ;; *) continue ;; esac
      touch "\$t" 2>/dev/null || true
    done <<ROOTS
    \$roots
    ROOTS
    printf '{}'
    exit 0
    EOF
    chmod +x "$CURSOR_HOOKS_DIR/fm-turn-end.sh"
    ```
  - Idempotent merge into hooks.json (preserve existing), instead of grok's standalone `.json`:
    ```sh
    HOOKS_JSON="${CURSOR_CONFIG_DIR:-$HOME/.cursor}/hooks.json"
    [ -f "$HOOKS_JSON" ] || printf '{"version":1,"hooks":{}}' > "$HOOKS_JSON"
    cmd="$CURSOR_HOOKS_DIR/fm-turn-end.sh"
    tmp=$(mktemp)
    jq --arg cmd "$cmd" '.hooks.stop = ((.hooks.stop // []) | if any(.command == $cmd) then . else . + [{"command":$cmd,"timeout":10}] end)' "$HOOKS_JSON" > "$tmp" && mv "$tmp" "$HOOKS_JSON"
    ```
  - The entire turn-end `case "$HARNESS"` block is already wrapped in `if [ "$KIND" != secondmate ]` (fm-spawn.sh:574), so the `cursor*)` arm needs NO internal secondmate guard - grok's arm has none either.
  - Heredoc caution: the `cat > .../fm-turn-end.sh <<EOF` block (and its nested `done <<ROOTS` ... `ROOTS`) uses a plain (non-`<<-`) heredoc, so every line - the `#!/usr/bin/env bash` shebang, the nested heredoc body, and the `ROOTS` terminator - must be emitted flush-left at column 0, exactly as grok's arm does at fm-spawn.sh:637-654, or the generated script gets an invalid shebang or unterminated heredoc.

- [ ] **Step 4: Run it green.**

- [ ] **Step 5: Commit** - `git commit -am "feat(spawn): cursor turn-end stop-hook merged into hooks.json"`.

---

## Task 5: Teardown cleanup (`bin/fm-teardown.sh`)

**Files:**
- Modify: `bin/fm-teardown.sh` - dirty-check regex (line 593), the two pointer removals (lines 536, 651), and a `remove_cursor_turnend_auth()` + `$STATE/$ID.cursor-turnend-token` removals mirroring grok (lines 94, 543/544, 664/668)
- Test: `tests/fm-cursor-harness.test.sh`

- [ ] **Step 1: Write the failing test** (mirror `test_grok_teardown_removes_pointer_and_token`): after spawn+teardown, assert `<worktree>/.fm-cursor-turnend`, `<cursor_home>/hooks/fm-turn-end.d/<token>`, and `state/<id>.cursor-turnend-token` are all absent. Add a case asserting a dirty worktree containing only `?? .fm-cursor-turnend` is NOT treated as dirty.

- [ ] **Step 2: Run it red.**

- [ ] **Step 3: Implement** - add cursor arms mirroring every grok touch point:
  - dirty-check regex: `grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$|\.fm-cursor-turnend$)'`
  - both `rm -f ... .fm-grok-turnend` sites: also `rm -f "$WT/.fm-cursor-turnend"`
  - add `remove_cursor_turnend_auth()` mirroring `remove_grok_turnend_auth()` (fm-teardown.sh:94): compute the registry dir LOCALLY inside the function as `"${CURSOR_CONFIG_DIR:-$HOME/.cursor}/hooks/fm-turn-end.d"` (there is no global `$CURSOR_AUTH_DIR` in teardown), read the token from `$STATE/$ID.cursor-turnend-token`, `rm -f "<dir>/$token"`; call it at both teardown sites, then `rm -f "$STATE/$ID.cursor-turnend-token"`.
  - Leave the global hook + hooks.json entry installed (harmless no-op).

- [ ] **Step 4: Run it green.**

- [ ] **Step 5: Commit** - `git commit -am "feat(teardown): clean up cursor turn-end pointer and token"`.

---

## Task 6: Bootstrap allowlist (`bin/fm-bootstrap.sh`)

**Files:**
- Modify: `bin/fm-bootstrap.sh:318` (`verified($h)` list)
- Test: `tests/fm-cursor-harness.test.sh` (or extend `tests/fm-bootstrap.test.sh`, mirroring its grok crew-dispatch case)

- [ ] **Step 1: Write the failing test** - a `crew-dispatch.json` with a rule `{"when":"...","use":{"harness":"cursor","model":"claude-opus-4-8-thinking-max"}}` validates as `CREW_DISPATCH: active` (not `invalid ... unverified harness`).

- [ ] **Step 2: Run it red.**

- [ ] **Step 3: Implement** - `def verified($h): ["claude","codex","opencode","pi","grok","cursor"] | ...`. Leave `effort_ok` without a cursor arm (falls through to `true`); add a comment that cursor effort/model ids are not machine-validated (ZDR is a convention).

- [ ] **Step 4: Run it green.**

- [ ] **Step 5: Commit** - `git commit -am "feat(bootstrap): accept cursor as a verified harness"`.

---

## Task 7: Busy signature (`bin/fm-watch.sh`, `bin/fm-tmux-lib.sh`)

**Files:**
- Modify: `bin/fm-watch.sh:99` (`BUSY_REGEX` default), `bin/fm-tmux-lib.sh:40` (`FM_TMUX_BUSY_REGEX_DEFAULT`)

- [ ] **Step 1: Implement** - add the `BUSY` string from Task 0 as an alternation to both default regexes (only if it is not already matched by the existing `esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel` set; if Cursor uses `esc to interrupt`, no change is needed - note that in the commit).

- [ ] **Step 2: Sanity check** - `bash -n bin/fm-watch.sh bin/fm-tmux-lib.sh`.

- [ ] **Step 3: Commit** (only if changed) - `git commit -am "feat(watch): add cursor busy signature"`.

---

## Task 8: Adapter knowledge (`.agents/skills/harness-adapters/SKILL.md`)

**Files:**
- Modify: `.agents/skills/harness-adapters/SKILL.md`

- [ ] **Step 1: Add a `cursor (VERIFIED <date>)` section** with the Task 0 facts: busy signature, exit command, interrupt key, trust-dialog handling, `SKILLFORM` for `/no-mistakes`, resume (`cursor-agent resume` / `--continue`), env marker `CURSOR_AGENT=1`, autonomy `--force`, and a launch-profile table row (model via full id, no effort flag). Add `cursor` to the detection/launch-axes prose and the verified-set line.

- [ ] **Step 2: Commit** - `git commit -am "docs(harness-adapters): add verified cursor section"`.

---

## Task 9: Local configuration + run the fleet on Cursor

Local and gitignored - NOT part of the upstream PR.

**Files:**
- Create (in the operator's firstmate home): `config/crew-harness`, `config/crew-dispatch.json`

- [ ] **Step 1: Set the crew harness fallback** - `printf 'cursor\n' > config/crew-harness`.

- [ ] **Step 2: Write `config/crew-dispatch.json`** (all ZDR-safe, no Fable 5):
```json
{
  "rules": [
    { "when": "heavy, architectural, or multi-file changes", "use": { "harness": "cursor", "model": "claude-opus-4-8-thinking-max" } },
    { "when": "quick or scoped fixes", "use": { "harness": "cursor", "model": "claude-opus-4-8-thinking-high-fast" } }
  ],
  "default": { "use": { "harness": "cursor", "model": "claude-opus-4-8-thinking-high-fast" } }
}
```

- [ ] **Step 3: Launch the first mate on Cursor** - from the firstmate home: `cursor-agent --model claude-opus-4-8-high-fast`, then `bootstrap yourself`.

- [ ] **Step 4: Smoke test** - dispatch one trivial ship task, confirm a crewmate spawns on cursor, works, wakes the watcher on turn-end, and tears down cleanly.

---

## Task 10: Full behavior suite

- [ ] **Step 1: Run the suite** - `tmux -V && for t in tests/*.test.sh; do bash "$t" || echo "FAIL: $t"; done` (this is what `.no-mistakes.yaml` runs).
Expected: all pass, including `tests/fm-cursor-harness.test.sh`.

- [ ] **Step 2: Fix any failures, re-run.**

- [ ] **Step 3: Final commit if needed.**

---

## Deferred: upstream PR (Phase 2, after weeks of local use)

Once proven locally: run `no-mistakes` on the branch, open the PR (keeping the preference-neutral detection so Claude-first operators are not regressed), captain merges. Drop the scratch `cursor-verification-notes.md` and the local `config/*` from the PR.
